extends SceneTree

## C-08 多格 footprint 事务定向测试：PlacementController 放置/移动/回收按实例 get_occupied_offsets 展开
## 绝对占格并经 OccupancyRegistry.register_cells/move_cells 原子提交（单格机关默认 [ZERO] 行为不变）；
## PreplacedMechanismAdopter 多格收编（逐格合法性 + 冲突回滚）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _MultiTokenScript: GDScript = preload("res://tests/unit/placement/fixtures/multi_cell_token_fixture.gd")
const _Adopter: GDScript = preload("res://gameplay/placement/preplaced_mechanism_adopter.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")

const _TOTAL: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_place_multi_cell_registers_footprint()
	_test_02_place_footprint_conflict_invalid()
	_test_03_move_multi_cell_atomic()
	_test_04_move_target_conflict_invalid()
	_test_05_recycle_clears_all_cells()
	_test_06_adopter_multi_cell_and_conflict_rollback()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 可配置 footprint 的放置桩节点（不入树；cell 由 position 派生，与正式契约一致）。
class _FootToken extends Node2D:
	var mechanism_id: StringName = &""
	var offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 0)]
	var cell: Vector2i:
		get:
			return _GridCoordinateRules.world_to_cell(position)
		set(next_cell):
			position = _GridCoordinateRules.cell_to_world(next_cell)
	func configure(id: StringName, c: Vector2i) -> void:
		mechanism_id = id
		cell = c
	func set_cell(c: Vector2i) -> void:
		cell = c
	func get_occupied_offsets(_p_orientation: int = 0) -> Array[Vector2i]:
		return offsets


## 多格桩工厂：可选返回单格桩（offsets [ZERO]）以混合场景；节点挂 root 由树退出统一释放。
class _FootFactory:
	var tree: SceneTree = null
	var created_tokens: Array[Variant] = []
	var single_cell: bool = false
	func create(mechanism_id: StringName, cell: Vector2i, _orientation: Variant) -> Variant:
		var token: _FootToken = _FootToken.new()
		if single_cell:
			token.offsets = [Vector2i.ZERO]
		token.configure(mechanism_id, cell)
		if tree != null and tree.root != null:
			tree.root.add_child(token)
		created_tokens.append(token)
		return token


## 构造 (controller, factory, occupancy) 三件套；装配与共享夹具 make_controller 同构（16×16 空图）。
func _make_env() -> Array:
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var inventory: _InventoryController = _InventoryController.new(_TOTAL)
	var factory: _FootFactory = _FootFactory.new()
	factory.tree = self
	var pc: _PlacementController = _PlacementController.new(occupancy, inventory, Callable(factory, "create"))
	var walls: Array[Vector2i] = []
	var lwq: Variant = _LevelWorldQuery.new(
		Rect2i(0, 0, 16, 16), walls, Vector2i(-1, -1),
		_LevelObjectRegistry.new(), occupancy, Callable(pc, "get_placed_node"))
	pc.set_level_world_query(lwq)
	return [pc, factory, occupancy]


## 1. 多格放置：footprint 两格全部登记，anchor 对齐请求格。
func _test_01_place_multi_cell_registers_footprint() -> void:
	const G: String = "01_多格放置"
	var env: Array = _make_env()
	var pc: _PlacementController = env[0]
	var occupancy: _OccupancyRegistry = env[2]
	var result: Variant = pc.place_from_inventory(&"mirror2", Vector2i(3, 3), 0)
	_check(G, result.is_success(), "双格放置应成功（%s）。" % result.error_message)
	var mid: StringName = result.mechanism_id
	_check(G, occupancy.get_mechanism_at(Vector2i(3, 3)) == mid, "锚格 (3,3) 应登记。")
	_check(G, occupancy.get_mechanism_at(Vector2i(4, 3)) == mid, "第二格 (4,3) 应登记。")
	_check(G, occupancy.occupied_cells_by_id[mid].size() == 2, "反向索引应含 2 格。")
	_check(G, pc.get_placed_node(mid).cell == Vector2i(3, 3), "桩节点锚格应保持 (3,3)。")


## 2. footprint 第二格冲突：INVALID、既有占用不被覆盖、新节点无残留映射。
func _test_02_place_footprint_conflict_invalid() -> void:
	const G: String = "02_放置冲突"
	var env: Array = _make_env()
	var pc: _PlacementController = env[0]
	var occupancy: _OccupancyRegistry = env[2]
	var first: Variant = pc.place_from_inventory(&"mirror2", Vector2i(3, 3), 0)
	_check(G, first.is_success(), "首次双格放置应成功。")
	var second: Variant = pc.place_from_inventory(&"mirror2", Vector2i(4, 3), 0)
	_check(G, second.status == _PlacementController.Status.INVALID, "第二格 (4,3) 冲突应 INVALID。")
	_check(G, occupancy.get_mechanism_at(Vector2i(4, 3)) == first.mechanism_id, "既有占用不得被覆盖。")
	_check(G, not pc.has_placed(second.mechanism_id), "失败放置不得残留映射。")


## 3. 多格移动：两格原子迁移，旧格释放、新格登记、锚格对齐目标。
func _test_03_move_multi_cell_atomic() -> void:
	const G: String = "03_多格移动"
	var env: Array = _make_env()
	var pc: _PlacementController = env[0]
	var occupancy: _OccupancyRegistry = env[2]
	var placed: Variant = pc.place_from_inventory(&"mirror2", Vector2i(3, 3), 0)
	var mid: StringName = placed.mechanism_id
	var moved: Variant = pc.move_placed(mid, Vector2i(6, 3))
	_check(G, moved.is_success() and moved.consumes_runtime_move, "双格跨格移动应成功且计次。")
	_check(G, occupancy.get_mechanism_at(Vector2i(6, 3)) == mid and occupancy.get_mechanism_at(Vector2i(7, 3)) == mid,
		"新占格 (6,3)/(7,3) 应登记。")
	_check(G, occupancy.get_mechanism_at(Vector2i(3, 3)) == &"" and occupancy.get_mechanism_at(Vector2i(4, 3)) == &"",
		"旧占格 (3,3)/(4,3) 应释放。")
	_check(G, pc.get_placed_node(mid).cell == Vector2i(6, 3), "桩节点锚格应对齐 (6,3)。")


## 4. 多格移动目标第二格被占：INVALID，占用与节点保持原状。
func _test_04_move_target_conflict_invalid() -> void:
	const G: String = "04_移动冲突"
	var env: Array = _make_env()
	var pc: _PlacementController = env[0]
	var factory: _FootFactory = env[1]
	var occupancy: _OccupancyRegistry = env[2]
	var placed: Variant = pc.place_from_inventory(&"mirror2", Vector2i(3, 3), 0)
	var mid: StringName = placed.mechanism_id
	factory.single_cell = true
	var blocker: Variant = pc.place_from_inventory(&"blocker", Vector2i(8, 3), 0)
	_check(G, blocker.is_success(), "单格占位机关放置应成功。")
	var moved: Variant = pc.move_placed(mid, Vector2i(7, 3))
	_check(G, moved.status == _PlacementController.Status.INVALID, "目标第二格 (8,3) 被占应 INVALID。")
	_check(G, occupancy.get_mechanism_at(Vector2i(3, 3)) == mid, "源占用保持原状。")
	_check(G, pc.get_placed_node(mid).cell == Vector2i(3, 3), "节点保持原格。")


## 5. 多格回收：footprint 全部释放、反向索引与映射清除。
func _test_05_recycle_clears_all_cells() -> void:
	const G: String = "05_多格回收"
	var env: Array = _make_env()
	var pc: _PlacementController = env[0]
	var occupancy: _OccupancyRegistry = env[2]
	var placed: Variant = pc.place_from_inventory(&"mirror2", Vector2i(3, 3), 0)
	var mid: StringName = placed.mechanism_id
	var recycled: Variant = pc.recycle_placed(mid)
	_check(G, recycled.is_success(), "双格回收应成功。")
	_check(G, occupancy.get_mechanism_at(Vector2i(3, 3)) == &"" and occupancy.get_mechanism_at(Vector2i(4, 3)) == &"",
		"回收后两格占用均应释放。")
	_check(G, not occupancy.occupied_cells_by_id.has(mid), "反向索引应清除。")
	_check(G, not pc.has_placed(mid), "映射应清除。")


## 6. 预置收编多格：footprint 两格登记；第二格冲突回滚（id 复位、位置还原、零占用残留）。
func _test_06_adopter_multi_cell_and_conflict_rollback() -> void:
	const G: String = "06_预置收编多格"
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: Variant = _Adopter.new(occupancy)
	var container: Node = Node.new()
	var token: Variant = _MultiTokenScript.new()
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(2, 2))
	container.add_child(token)
	_check(G, adopter.adopt_all(container) == 1, "双格预置机关应收编成功。")
	var mid: StringName = token.mechanism_id
	_check(G, mid != &"", "收编应写入 mechanism_id。")
	_check(G, occupancy.get_mechanism_at(Vector2i(2, 2)) == mid and occupancy.get_mechanism_at(Vector2i(3, 2)) == mid,
		"footprint 两格 (2,2)/(3,2) 应登记。")
	_check(G, adopter.get_preplaced_node(mid) == token, "收编映射应指向原节点。")

	var occupancy2: _OccupancyRegistry = _OccupancyRegistry.new()
	occupancy2.register_single_cell(&"enemy", Vector2i(3, 2))
	var adopter2: Variant = _Adopter.new(occupancy2)
	var container2: Node = Node.new()
	var token2: Variant = _MultiTokenScript.new()
	var original_position: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(2, 2))
	token2.position = original_position
	container2.add_child(token2)
	_check(G, adopter2.adopt_all(container2) == 0, "第二格冲突收编应失败。")
	_check(G, token2.mechanism_id == &"", "失败收编应复位 mechanism_id。")
	_check(G, token2.position == original_position, "失败收编应还原 position。")
	_check(G, occupancy2.get_mechanism_at(Vector2i(2, 2)) == &"", "失败收编不得残留锚格占用。")
	_check(G, adopter2.get_preplaced_count() == 0, "失败收编不得进映射。")

	container.free()
	container2.free()


func _report() -> void:
	print("C-08 multi-cell footprint: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
