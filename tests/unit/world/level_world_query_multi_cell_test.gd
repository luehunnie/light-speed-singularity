extends SceneTree

## LevelWorldQuery 多格放置合法性定向测试（D7-R4）。
## 固化 is_valid_placement_cell_set 的最小多格判定：非空、格间无重复、每格满足单格判定链
## （Terrain 内 → LegalArea 内 → 非 Wall → 无固定对象 → 无动态占用），任一格非法则整体非法；
## ignored_id 允许移动/旋转中的多格机关忽略自身既有占用；与单格 is_valid_placement_cell 等价退化。
## 使用旧 6 参无快照兼容路径（map_bounds + wall_cells）构造，不生成资源文件；
## headless extends SceneTree，由 Godot --script 运行，任一失败 quit(1)。

const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0

## 持有机关节点解析桩，避免 RefCounted 仅被 Callable 单引用而提前回收（GDScript Callable 不保留 RefCounted 坑）。
var _lookup_holder: Variant = null


func _initialize() -> void:
	_test_01_valid_cell_set_true()
	_test_02_empty_set_false()
	_test_03_duplicate_cell_false()
	_test_04_out_of_bounds_cell_false()
	_test_05_wall_cell_false()
	_test_06_emitter_cell_false()
	_test_07_occupied_by_other_false()
	_test_08_ignored_id_allows_own_cells()
	_test_09_single_cell_equivalence()
	_test_10_multi_cell_registry_integration()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 装配 =====

## 构造无快照兼容路径的 LevelWorldQuery：16×16 地图、单墙 (8,8)、发射器 (0,8)、独立占用表与空水晶 Registry。
## 返回 { query, occupancy }；lookup 返回 null（本测试不解析机关节点）。
func _build_world() -> Dictionary:
	var walls: Array[Vector2i] = [Vector2i(8, 8)]
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _NullLookup = _NullLookup.new()
	_lookup_holder = lookup
	var query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 16, 16),
		walls,
		Vector2i(0, 8),
		registry,
		occupancy,
		Callable(lookup, "lookup")
	)
	return {"query": query, "occupancy": occupancy}


## 机关节点解析桩：恒返回 null，仅供构造注入。
class _NullLookup:
	func lookup(_p_mechanism_id: StringName) -> Variant:
		return null


# ===== 测试用例 =====

## 1. 全部格合法的两格集合整体合法。
func _test_01_valid_cell_set_true() -> void:
	const NAME: String = "01_合法格集"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(4, 3)]) == true, "两格均合法的集合应整体合法。")
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3)]) == true, "单元素合法集合应合法。")


## 2. 空集合非法。
func _test_02_empty_set_false() -> void:
	const NAME: String = "02_空集合非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([]) == false, "空集合应返回 false。")


## 3. 集合内重复格非法。
func _test_03_duplicate_cell_false() -> void:
	const NAME: String = "03_重复格非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(3, 3)]) == false, "重复格集合应返回 false。")


## 4. 任一格出界则整体非法。
func _test_04_out_of_bounds_cell_false() -> void:
	const NAME: String = "04_出界整体非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(16, 3)]) == false, "含出界格的集合应整体非法。")
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(-1, 3)]) == false, "含负出界格的集合应整体非法。")


## 5. 任一格为墙则整体非法。
func _test_05_wall_cell_false() -> void:
	const NAME: String = "05_墙体整体非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(8, 8)]) == false, "含墙格的集合应整体非法。")


## 6. 任一格为发射器格则整体非法（静态固定对象）。
func _test_06_emitter_cell_false() -> void:
	const NAME: String = "06_发射器整体非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(0, 8)]) == false, "含发射器格的集合应整体非法。")


## 7. 任一格被其他机关占用则整体非法（多格占用经 register_cells 登记）。
func _test_07_occupied_by_other_false() -> void:
	const NAME: String = "07_他机关占用整体非法"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	var occupancy: _OccupancyRegistry = world["occupancy"]
	_check(NAME, occupancy.register_cells(&"w1", [Vector2i(4, 4), Vector2i(5, 4)]) == true, "前置多格登记应成功。")
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(3, 3), Vector2i(4, 4)]) == false, "含他机关占用格的集合应整体非法。")
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(4, 4), Vector2i(5, 4)], &"w2") == false, "ignored_id 为其他 ID 仍应非法。")


## 8. ignored_id 忽略自身既有占用：旋转保持锚点的多格机关在新朝向格集上应合法。
func _test_08_ignored_id_allows_own_cells() -> void:
	const NAME: String = "08_忽略自身占用"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	var occupancy: _OccupancyRegistry = world["occupancy"]
	# 双格平面镜 v0.6 §2.1 语义：TOP 占 (x-1,y),(x,y)，BOTTOM 占 (x,y),(x+1,y)，旋转锚点 (x,y) 不变。
	_check(NAME, occupancy.register_cells(&"w1", [Vector2i(4, 5), Vector2i(5, 5)]) == true, "前置 TOP 朝向登记应成功。")
	var bottom_cells: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	_check(NAME, query.is_valid_placement_cell_set(bottom_cells, &"w1") == true, "旋转后共享锚点格集（忽略自身）应合法。")
	_check(NAME, query.is_valid_placement_cell_set(bottom_cells) == false, "不忽略自身时锚点格仍被自身占用应非法。")


## 9. 单元素格集与 is_valid_placement_cell 结果一致（等价退化）。
func _test_09_single_cell_equivalence() -> void:
	const NAME: String = "09_单元素等价"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	for cell: Vector2i in [Vector2i(3, 3), Vector2i(8, 8), Vector2i(0, 8), Vector2i(20, 20)]:
		_check(
			NAME,
			query.is_valid_placement_cell_set([cell]) == query.is_valid_placement_cell(cell),
			"格 %s 的单元素集合应与单格判定一致。" % [cell]
		)


## 10. 端到端最小路径：格集合法 → register_cells → move_cells 旋转 → 新格集对自身合法、对他机关非法。
func _test_10_multi_cell_registry_integration() -> void:
	const NAME: String = "10_格集与占用表集成"
	var world: Dictionary = _build_world()
	var query: _LevelWorldQuery = world["query"]
	var occupancy: _OccupancyRegistry = world["occupancy"]
	var top_cells: Array[Vector2i] = [Vector2i(4, 5), Vector2i(5, 5)]
	var bottom_cells: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	_check(NAME, query.is_valid_placement_cell_set(top_cells) == true, "初始格集应合法。")
	_check(NAME, occupancy.register_cells(&"w1", top_cells) == true, "初始登记应成功。")
	_check(NAME, query.is_valid_placement_cell_set(bottom_cells, &"w1") == true, "旋转目标格集（忽略自身）应合法。")
	_check(NAME, occupancy.move_cells(&"w1", top_cells, bottom_cells) == true, "旋转原子迁移应成功。")
	_check(NAME, query.is_valid_placement_cell_set(bottom_cells, &"w1") == true, "迁移后自身格集仍应合法（忽略自身）。")
	_check(NAME, query.is_valid_placement_cell_set([Vector2i(6, 5), Vector2i(6, 6)]) == false, "他机关视角目标格应非法。")


# ===== 支撑 =====

## 记录断言：失败项收集到 _failures，全部通过时 _checks 递增。
func _check(group_name: String, condition: bool, reason: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append("[%s] %s" % [group_name, reason])


## 统一报告：输出通过/失败统计与全部失败项。
func _report() -> void:
	print("level_world_query_multi_cell_test: %d checks, %d failures" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL " + failure)
