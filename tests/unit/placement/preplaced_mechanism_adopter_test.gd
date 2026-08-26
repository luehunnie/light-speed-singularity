extends SceneTree

## PreplacedMechanismAdopter 定向自动测试（AF-10 第一批）。
## 只通过公开接口观察收编数量/占用登记/只读映射；安全失败路径（非法格/占用冲突/重复收编）验证
## 不进映射、mechanism_id 复位、不污染占用表；并用真实 InventoryController+PlacementController 证明
## 预置收编不扣玩家库存、不进玩家放置映射。由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _Adopter: GDScript = preload(
	"res://gameplay/placement/preplaced_mechanism_adopter.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
const _PlacementController: GDScript = preload(
	"res://gameplay/placement/placement_controller.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _MirrorScene: PackedScene = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn"
)
const _AcceleratorScene: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.tscn"
)
const _DeceleratorScene: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_decelerator.tscn"
)
const _CrystalScene: PackedScene = preload(
	"res://gameplay/crystals/basic_crystal.tscn"
)


## 格合法性门桩：denied 中的格返回非法；成员持有避免 Callable 不保留 RefCounted 的回收坑。
class _CellGate extends RefCounted:
	var denied_cells: Array[Vector2i] = []

	func is_adoptable(cell: Vector2i) -> bool:
		return not denied_cells.has(cell)


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _gate: _CellGate = null


func _initialize() -> void:
	await process_frame
	_gate = _CellGate.new()
	_test_01_adopt_mirror_registers_occupancy_and_map()
	_test_02_generic_contract_covers_speed_mechanisms()
	_test_03_non_mechanism_children_skipped()
	_test_04_illegal_cell_rejected_safely()
	_test_05_occupancy_conflict_rolls_back()
	_test_06_repeated_adoption_rejected()
	_test_07_adoption_never_touches_player_inventory_or_map()
	_test_08_readonly_accessors()
	_test_09_null_container_reports_error()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 构造已挂树的 RuntimeObjects 容器与一个位于 cell 的真实镜面实例；泵帧让 PlaceableToken @onready 生效。
func _make_mirror(container: Node2D, cell: Vector2i) -> Node2D:
	var mirror: Node2D = _MirrorScene.instantiate() as Node2D
	mirror.position = _GridCoordinateRules.cell_to_world(cell)
	container.add_child(mirror)
	return mirror


func _make_adopter(occupancy: _OccupancyRegistry) -> _Adopter:
	return _Adopter.new(occupancy, Callable(_gate, "is_adoptable"))


func _free_tree(nodes: Array) -> void:
	for node: Variant in nodes:
		if is_instance_valid(node):
			(node as Node).free()
	await process_frame


# ===== 用例 =====

## 1. 镜面收编：占用表登记、ID 前缀、mechanism_id 写入、position 吸附格中心。
func _test_01_adopt_mirror_registers_occupancy_and_map() -> void:
	const NAME: String = "01_镜面收编成功"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	var mirror: Node2D = _make_mirror(container, Vector2i(2, 2))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 1, "收编数量期望 1。")
	var mechanism_id: StringName = occupancy.get_mechanism_at(Vector2i(2, 2))
	_check(NAME, mechanism_id != &"", "占用表应能查到预置镜面。")
	_check(NAME, String(mechanism_id).begins_with("preplaced_"), "预置 ID 前缀期望 preplaced_，实际 %s。" % [mechanism_id])
	_check(NAME, adopter.has_preplaced(mechanism_id), "收编映射应含该 ID。")
	_check(NAME, adopter.get_preplaced_node(mechanism_id) == mirror, "收编映射节点应为原镜面实例。")
	_check(NAME, (mirror as PlaceableToken).mechanism_id == mechanism_id, "节点 mechanism_id 应被写入收编 ID。")
	_check(
		NAME,
		(mirror as Node2D).position == _GridCoordinateRules.cell_to_world(Vector2i(2, 2)),
		"position 应吸附格中心。"
	)
	_free_tree(made)


## 2. 通用契约：加/减速器（非镜面）同批可收编，不写死镜面类型。
func _test_02_generic_contract_covers_speed_mechanisms() -> void:
	const NAME: String = "02_通用契约含加减速器"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	var accelerator: Node2D = _AcceleratorScene.instantiate() as Node2D
	accelerator.position = _GridCoordinateRules.cell_to_world(Vector2i(1, 5))
	container.add_child(accelerator)
	var decelerator: Node2D = _DeceleratorScene.instantiate() as Node2D
	decelerator.position = _GridCoordinateRules.cell_to_world(Vector2i(2, 5))
	container.add_child(decelerator)
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 2, "加/减速器应各收编 1，合计 2。")
	_check(NAME, occupancy.get_mechanism_at(Vector2i(1, 5)) != &"", "加速器格应可查询。")
	_check(NAME, occupancy.get_mechanism_at(Vector2i(2, 5)) != &"", "减速器格应可查询。")
	_free_tree(made)


## 3. 非机关子节点跳过：水晶与普通 Node2D 不收编、不报错。
func _test_03_non_mechanism_children_skipped() -> void:
	const NAME: String = "03_非机关子节点跳过"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	var crystal: Node2D = _CrystalScene.instantiate() as Node2D
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(0, 7))
	container.add_child(crystal)
	var plain: Node2D = Node2D.new()
	plain.position = _GridCoordinateRules.cell_to_world(Vector2i(1, 7))
	container.add_child(plain)
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 0, "水晶/普通 Node2D 不应被收编。")
	_check(NAME, occupancy.get_mechanism_at(Vector2i(0, 7)) == &"", "水晶格不应登记机关占用。")
	_check(NAME, adopter.get_preplaced_count() == 0, "收编映射应为空。")
	_free_tree(made)


## 4. 非法格拒绝：validity Callable 拒绝的格不收编，节点 mechanism_id 保持为空。
func _test_04_illegal_cell_rejected_safely() -> void:
	const NAME: String = "04_非法格安全失败"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	_gate.denied_cells.append(Vector2i(0, 9))
	var mirror: Node2D = _make_mirror(container, Vector2i(0, 9))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 0, "非法格预置机关不应收编。")
	_check(NAME, occupancy.get_mechanism_at(Vector2i(0, 9)) == &"", "非法格不应登记占用。")
	_check(NAME, (mirror as PlaceableToken).mechanism_id == &"", "被拒节点 mechanism_id 应保持为空。")
	_gate.denied_cells.clear()
	_free_tree(made)


## 5. 占用冲突回滚：目标格已被其他机关占用时收编失败，不进映射、mechanism_id 复位。
func _test_05_occupancy_conflict_rolls_back() -> void:
	const NAME: String = "05_占用冲突回滚"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	var mirror: Node2D = _make_mirror(container, Vector2i(4, 4))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	occupancy.register_single_cell(&"other_1", Vector2i(4, 4))
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 0, "占用冲突预置机关不应收编。")
	_check(NAME, occupancy.get_mechanism_at(Vector2i(4, 4)) == &"other_1", "既有占用不应被覆盖。")
	_check(NAME, (mirror as PlaceableToken).mechanism_id == &"", "冲突节点 mechanism_id 应复位为空。")
	_check(NAME, adopter.get_preplaced_count() == 0, "收编映射应为空。")
	_free_tree(made)


## 6. 重复收编拒绝：同一容器二次扫描时已配置机关被拒，数量 0、映射不变。
func _test_06_repeated_adoption_rejected() -> void:
	const NAME: String = "06_重复收编拒绝"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	_make_mirror(container, Vector2i(6, 6))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 1, "首次收编期望 1。")
	_check(NAME, adopter.adopt_all(container) == 0, "二次收编期望 0（已配置机关被拒）。")
	_check(NAME, adopter.get_preplaced_count() == 1, "映射数量应保持 1。")
	_check(NAME, occupancy.is_consistent(), "占用表应保持一致。")
	_free_tree(made)


## 7. 收编不动玩家域：真实 InventoryController(3)+PlacementController 共存时，收编后库存仍满、玩家映射为空。
func _test_07_adoption_never_touches_player_inventory_or_map() -> void:
	const NAME: String = "07_预置不扣库存不进玩家映射"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	_make_mirror(container, Vector2i(8, 8))
	_make_mirror(container, Vector2i(9, 8))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var inventory: _InventoryController = _InventoryController.new(3)
	var controller: _PlacementController = _PlacementController.new(occupancy, inventory, Callable())
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(container) == 2, "两个预置镜面应收编。")
	_check(NAME, inventory.get_remaining() == 3, "预置收编后库存应保持 3，实际 %d。" % [inventory.get_remaining()])
	_check(NAME, controller.get_placed_count() == 0, "玩家放置映射应保持 0。")
	_check(NAME, inventory.is_consistent_with_placed_count(0), "库存一致性 remaining+0==3 应成立。")
	_free_tree(made)


## 8. 只读访问器：未知 ID 返回 null/false，ID 快照数量正确。
func _test_08_readonly_accessors() -> void:
	const NAME: String = "08_只读访问器"
	var made: Array = []
	var container: Node2D = Node2D.new()
	root.add_child(container)
	made.append(container)
	_make_mirror(container, Vector2i(2, 9))
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	adopter.adopt_all(container)
	_check(NAME, adopter.get_preplaced_node(&"preplaced_999") == null, "未知 ID 应返回 null。")
	_check(NAME, not adopter.has_preplaced(&""), "空 ID 不应命中。")
	_check(NAME, adopter.get_preplaced_ids().size() == 1, "ID 快照数量期望 1。")
	_free_tree(made)


## 9. 空容器：push_error 可诊断并返回 0，不崩溃。
func _test_09_null_container_reports_error() -> void:
	const NAME: String = "09_空容器安全失败"
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _make_adopter(occupancy)
	_check(NAME, adopter.adopt_all(null) == 0, "空容器应收编 0。")


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== 预置机关收编器定向测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
