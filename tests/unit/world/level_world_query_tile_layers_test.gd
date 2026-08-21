extends SceneTree

## LevelWorldQuery 四层快照模式定向测试（D5-B.2B）。
##
## 用真实 LevelTileLayerSnapshot（由程序化最小 TileSet + 临时 TileMapLayer 构造）固化“有快照正式运行模式”下：
## Terrain 外包矩形内空洞越界、空 Terrain 全越界、LegalArea 附加约束（不替代 Terrain）、WallLayer 为唯一墙体事实（不认旧 wall_cells）、
## 墙/发射器/水晶三类静态阻挡、动态占用与 ignored_id 忽略移动自身、光线经 LightWorldQuery 转发继承 Terrain 越界（含空洞）与 Wall 阻挡、
## LegalArea/Decoration 不影响光线传播、Decoration-only 格不参与边界/墙体/放置/占用任一判定；并固化旧 6 参无快照兼容路径（LegalArea 视为允许）。
##
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题（与 ray_execution_module_test 同款）。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不修改 assets、不生成资源文件；TileMapLayer 在快照复制 used cells 后立即释放，避免退出泄漏噪音。


const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：按顺序运行 11 组测试后统一报告并退出。
func _initialize() -> void:
	_test_01_terrain_hole_in_bounds()
	_test_02_empty_terrain_all_oob()
	_test_03_in_terrain_no_legal()
	_test_04_legal_without_terrain()
	_test_05_snapshot_wall_only()
	_test_06_static_blockers()
	_test_07_dynamic_occupancy()
	_test_08_light_inherits_terrain_and_wall()
	_test_09_legal_decoration_no_light_effect()
	_test_10_decoration_only_isolated()
	_test_11_no_snapshot_compat()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一个由真实四层快照驱动的 LevelWorldQuery，附带独立占用表与机关节点查表桩。
## [br]terrain_cells / wall_layer_cells / legal_cells / decoration_cells 为各层真实格（Vector2i 列表）。
## [br]wall_cells_param 仅作 LevelWorldQuery 构造兼容入参（有快照模式不读），用于验证快照模式忽略旧 wall_cells。
## [br]emitter_cell 为主发射源格；crystals 为已配置 crystal_id 与 cell 的普通水晶数组（默认空）。
## [br]首个粗筛边界参数取 snapshot.get_terrain_bounds()（与 core 正式接线一致，D5-B.2B）。
## [br]返回 { query, occupancy, lookup, snapshot, registry }；快照构造已复制 used cells，临时 TileMapLayer 立即释放。
func _build_snapshot_world(
		terrain_cells: Array,
		wall_layer_cells: Array,
		wall_cells_param: Array,
		legal_cells: Array,
		decoration_cells: Array,
		emitter_cell: Vector2i,
		crystals: Array = []
) -> Dictionary:
	var tile_set: TileSet = _make_min_tile_set()
	var terrain_layer: TileMapLayer = _make_layer(tile_set, terrain_cells)
	var wall_layer: TileMapLayer = _make_layer(tile_set, wall_layer_cells)
	var legal_layer: TileMapLayer = _make_layer(tile_set, legal_cells)
	var decoration_layer: TileMapLayer = _make_layer(tile_set, decoration_cells)
	var snapshot: Object = _LevelTileLayerSnapshot.new(terrain_layer, wall_layer, legal_layer, decoration_layer)
	# 快照已复制四层 used cells，临时层数据不再需要，立即释放避免退出泄漏噪音。
	terrain_layer.free()
	wall_layer.free()
	legal_layer.free()
	decoration_layer.free()

	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	for crystal: BasicCrystal in crystals:
		registry.register_crystal(crystal.get_crystal_id(), crystal.cell, crystal)
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls_arg: Array[Vector2i] = []
	for wc: Vector2i in wall_cells_param:
		walls_arg.append(wc)
	var query: _LevelWorldQuery = _LevelWorldQuery.new(
		snapshot.get_terrain_bounds(),
		walls_arg,
		emitter_cell,
		registry,
		occupancy,
		Callable(lookup, "get_node"),
		snapshot
	)
	return { "query": query, "occupancy": occupancy, "lookup": lookup, "snapshot": snapshot, "registry": registry }


## 构造最小可用 TileSet：单 atlas 源、无纹理；set_cell 引用 source 0 即可使 get_used_cells 返回该格。
func _make_min_tile_set() -> TileSet:
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	tile_set.add_source(source)
	return tile_set


## 用给定 TileSet 与格列表构造未入树的 TileMapLayer 并逐格 set_cell。
func _make_layer(tile_set: TileSet, cells: Array) -> TileMapLayer:
	var layer: TileMapLayer = TileMapLayer.new()
	layer.tile_set = tile_set
	for cell: Vector2i in cells:
		layer.set_cell(cell, 0, Vector2i.ZERO, 0)
	return layer


## 1. Terrain 外包矩形内的空洞：is_in_bounds=false。3×3 Terrain 挖去中心 (1,1)，外包含 (1,1) 但 has_terrain_cell 为 false。
func _test_01_terrain_hole_in_bounds() -> void:
	const NAME: String = "01_Terrain外包空洞"
	var terrain: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]
	var world: Dictionary = _build_snapshot_world(terrain, [], [], [], [], Vector2i(-9, -9))
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_in_bounds(Vector2i(1, 1)) == false, "外包矩形内空洞 (1,1) 期望越界 false。")
	_check(NAME, q.is_in_bounds(Vector2i(0, 0)) == true, "真实 Terrain (0,0) 期望 true。")
	_check(NAME, q.is_in_bounds(Vector2i(2, 2)) == true, "真实 Terrain (2,2) 期望 true。")
	_check(NAME, q.is_in_bounds(Vector2i(3, 0)) == false, "外包之外 (3,0) 期望 false。")


## 2. 空 Terrain：任意格均越界。空 Terrain 外包为 Rect2i(0,0,0,0)，has_point 对任意格恒 false。
func _test_02_empty_terrain_all_oob() -> void:
	const NAME: String = "02_空Terrain全越界"
	var world: Dictionary = _build_snapshot_world([], [], [], [], [], Vector2i(-9, -9))
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_in_bounds(Vector2i(0, 0)) == false, "空 Terrain 下 (0,0) 期望越界 false。")
	_check(NAME, q.is_in_bounds(Vector2i(5, 5)) == false, "空 Terrain 下 (5,5) 期望越界 false。")
	_check(NAME, q.is_in_bounds(Vector2i(-1, -1)) == false, "空 Terrain 下 (-1,-1) 期望越界 false。")


## 3. Terrain 内但无 LegalArea：不可放置。LegalArea 为附加约束，Terrain 内仍须存在 LegalArea Tile。
func _test_03_in_terrain_no_legal() -> void:
	const NAME: String = "03_Terrain内无LegalArea"
	var world: Dictionary = _build_snapshot_world([Vector2i(1, 1)], [], [], [], [], Vector2i(-9, -9))
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_in_bounds(Vector2i(1, 1)) == true, "(1,1) 在 Terrain 内期望 true。")
	_check(NAME, q.is_legal_placement_cell(Vector2i(1, 1)) == false, "(1,1) 无 LegalArea 期望不可放置 false。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 1)) == false, "(1,1) 综合判定期望 false。")


## 4. LegalArea 有 Tile、Terrain 无 Tile：仍不可放置。LegalArea 不替代 Terrain，越界优先短路。
func _test_04_legal_without_terrain() -> void:
	const NAME: String = "04_LegalArea有Tile但Terrain无Tile"
	var world: Dictionary = _build_snapshot_world([Vector2i(0, 0), Vector2i(2, 0)], [], [], [Vector2i(1, 0)], [], Vector2i(-9, -9))
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_in_bounds(Vector2i(1, 0)) == false, "(1,0) Terrain 无 Tile 期望越界 false（LegalArea 不替代 Terrain）。")
	_check(NAME, q.is_legal_placement_cell(Vector2i(1, 0)) == false, "(1,0) 越界即不可放置 false。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 0)) == false, "(1,0) 综合判定期望 false。")


## 5. 快照模式只认 WallLayer，不认旧 wall_cells。WallLayer 真实墙在 (3,3)；构造兼容入参 wall_cells 传 (7,7)，有快照下应被忽略。
func _test_05_snapshot_wall_only() -> void:
	const NAME: String = "05_快照只认WallLayer"
	var world: Dictionary = _build_snapshot_world(
		[Vector2i(3, 3), Vector2i(7, 7)],
		[Vector2i(3, 3)],
		[Vector2i(7, 7)],
		[Vector2i(3, 3), Vector2i(7, 7)],
		[],
		Vector2i(-9, -9)
	)
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_wall_cell(Vector2i(3, 3)) == true, "WallLayer 真实墙 (3,3) 期望 true。")
	_check(NAME, q.is_wall_cell(Vector2i(7, 7)) == false, "旧 wall_cells 兼容入参 (7,7) 有快照下期望 false。")


## 6. WallLayer、发射器、水晶分别阻挡放置。三类静态阻挡相互独立，自由合法格仍可放置。
func _test_06_static_blockers() -> void:
	const NAME: String = "06_静态阻挡三源"
	var terrain: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3)]
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = Vector2i(3, 3)
	crystal.crystal_id = &"crystal_static_3_3"
	var world: Dictionary = _build_snapshot_world(terrain, [Vector2i(1, 1)], [], terrain, [], Vector2i(2, 2), [crystal])
	var q: _LevelWorldQuery = world["query"]
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 1)) == false, "墙格 (1,1) 期望不可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(2, 2)) == false, "发射器格 (2,2) 期望不可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(3, 3)) == false, "水晶格 (3,3) 期望不可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(0, 0)) == true, "自由合法格 (0,0) 期望可放置。")
	crystal.free()


## 7. 动态占用阻挡，ignored_id 可忽略移动自身。他人占用不可忽略，自身原格占用可忽略。
func _test_07_dynamic_occupancy() -> void:
	const NAME: String = "07_动态占用与ignored_id"
	var terrain: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3)]
	var world: Dictionary = _build_snapshot_world(terrain, [], [], terrain, [], Vector2i(-9, -9))
	var q: _LevelWorldQuery = world["query"]
	var occ: _OccupancyRegistry = world["occupancy"]
	occ.register_single_cell(&"m1", Vector2i(1, 1))
	occ.register_single_cell(&"m2", Vector2i(2, 2))
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 1)) == false, "(1,1) 被 m1 占用期望不可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 1), &"m1") == true, "(1,1) ignored_id=m1 移动自身期望可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(2, 2), &"m1") == false, "(2,2) 被 m2 占用，m1 不能忽略期望不可放置。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(3, 3)) == true, "自由格 (3,3) 期望可放置。")


## 8. 光线继承 Terrain 越界与 WallLayer 阻挡。经 LightWorldQuery 转发，RayExecutionModule 据此区分 WALL / OUT_OF_BOUNDS（含外包内空洞）。
func _test_08_light_inherits_terrain_and_wall() -> void:
	const NAME: String = "08_光线继承Terrain越界与Wall"
	var row: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)]
	# A. WallLayer 阻挡：墙在 (3,0)；从 (0,0) 向右进入 (1,0)(2,0) 后在 (3,0) 墙体停止。
	var world_a: Dictionary = _build_snapshot_world(row, [Vector2i(3, 0)], [], [], [], Vector2i(-9, -9))
	var res_a: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 0), Vector2i.RIGHT, 128, _LightWorldQuery.new(world_a["query"]), 7, 1)
	_check(NAME, res_a.stop_reason == _RayExecutionResult.StopReason.WALL, "A 墙体停止期望 WALL，实际 %s。" % [res_a.stop_reason])
	_check(NAME, res_a.steps.size() == 2, "A 墙体停止 steps 期望 2((1,0)(2,0))，实际 %d。" % [res_a.steps.size()])
	# B. Terrain 外包越界：无墙，从 (0,0) 向右进入 (1,0)..(4,0) 后在 (5,0) 越界（外包 Rect2i(0,0,5,1)）。
	var world_b: Dictionary = _build_snapshot_world(row, [], [], [], [], Vector2i(-9, -9))
	var res_b: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 0), Vector2i.RIGHT, 128, _LightWorldQuery.new(world_b["query"]), 7, 1)
	_check(NAME, res_b.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "B 外包越界期望 OUT_OF_BOUNDS，实际 %s。" % [res_b.stop_reason])
	_check(NAME, res_b.steps.size() == 4, "B 外包越界 steps 期望 4((1,0)..(4,0))，实际 %d。" % [res_b.steps.size()])
	# C. Terrain 空洞越界：外包内 (3,0) 无 Terrain Tile；从 (0,0) 向右进入 (1,0)(2,0) 后在空洞 (3,0) 越界（非外包矩形边界）。
	var hole_row: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(4, 0)]
	var world_c: Dictionary = _build_snapshot_world(hole_row, [], [], [], [], Vector2i(-9, -9))
	var res_c: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 0), Vector2i.RIGHT, 128, _LightWorldQuery.new(world_c["query"]), 7, 1)
	_check(NAME, res_c.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "C 空洞越界期望 OUT_OF_BOUNDS，实际 %s。" % [res_c.stop_reason])
	_check(NAME, res_c.steps.size() == 2, "C 空洞越界 steps 期望 2((1,0)(2,0))，实际 %d。" % [res_c.steps.size()])


## 9. LegalArea 与 Decoration 不影响光线传播。LegalArea 仅一处、Decoration 在路径上，光线仍贯穿至外包越界。
func _test_09_legal_decoration_no_light_effect() -> void:
	const NAME: String = "09_LegalArea/Decoration不影响光线"
	var row: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)]
	var world: Dictionary = _build_snapshot_world(row, [], [], [Vector2i(2, 0)], [Vector2i(1, 0)], Vector2i(-9, -9))
	var res: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 0), Vector2i.RIGHT, 128, _LightWorldQuery.new(world["query"]), 7, 1)
	_check(NAME, res.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "期望外包越界 OUT_OF_BOUNDS，实际 %s。" % [res.stop_reason])
	_check(NAME, res.steps.size() == 4, "期望贯穿 4 格 ((1,0)..(4,0))，实际 %d。" % [res.steps.size()])


## 10. Decoration-only 格不影响边界、墙体、放置或占用。仅装饰格 (5,5) 不入任何判定；与 Terrain 重叠的装饰格照常按 Terrain 判定。
func _test_10_decoration_only_isolated() -> void:
	const NAME: String = "10_Decoration-only格隔离"
	var world: Dictionary = _build_snapshot_world(
		[Vector2i(0, 0), Vector2i(1, 1)], [], [], [Vector2i(0, 0), Vector2i(1, 1)], [Vector2i(5, 5), Vector2i(1, 1)], Vector2i(-9, -9)
	)
	var q: _LevelWorldQuery = world["query"]
	# 仅装饰格 (5,5)：不影响边界、不计墙体、不可放置、不产生占用。
	_check(NAME, q.is_in_bounds(Vector2i(5, 5)) == false, "Decoration-only (5,5) 不影响边界，期望越界 false。")
	_check(NAME, q.is_wall_cell(Vector2i(5, 5)) == false, "Decoration 不计墙体，(5,5) 期望 false。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(5, 5)) == false, "Decoration-only (5,5) 期望不可放置 false。")
	_check(NAME, q.has_mechanism_at(Vector2i(5, 5)) == false, "Decoration 不产生占用，(5,5) 期望 false。")
	# 与 Terrain 重叠的装饰 (1,1)：边界/墙体/放置照常按 Terrain 判定，装饰不阻挡。
	_check(NAME, q.is_in_bounds(Vector2i(1, 1)) == true, "Terrain+Decoration (1,1) 在 Terrain 内期望 true。")
	_check(NAME, q.is_wall_cell(Vector2i(1, 1)) == false, "Terrain+Decoration (1,1) 非墙期望 false。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(1, 1)) == true, "Terrain+Decoration (1,1) 装饰不阻挡，期望可放置 true。")


## 11. 旧六参数无快照构造仍保持 map_bounds + wall_cells 兼容，LegalArea 视为允许。
func _test_11_no_snapshot_compat() -> void:
	const NAME: String = "11_无快照六参兼容"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls: Array[Vector2i] = [Vector2i(5, 5)]
	var q: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10),
		walls,
		Vector2i(0, 0),
		registry,
		occupancy,
		Callable(lookup, "get_node")
	)
	_check(NAME, q.is_in_bounds(Vector2i(9, 9)) == true, "兼容 map_bounds (9,9) 期望 true。")
	_check(NAME, q.is_in_bounds(Vector2i(10, 0)) == false, "兼容 map_bounds (10,0) 期望越界 false。")
	_check(NAME, q.is_wall_cell(Vector2i(5, 5)) == true, "兼容 wall_cells (5,5) 期望 true。")
	_check(NAME, q.is_wall_cell(Vector2i(3, 3)) == false, "兼容 wall_cells (3,3) 期望 false。")
	_check(NAME, q.is_legal_placement_cell(Vector2i(3, 3)) == true, "无快照兼容 LegalArea 视为允许，(3,3) 期望 true。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(3, 3)) == true, "无快照 (3,3) 综合期望可放置 true。")
	_check(NAME, q.is_valid_placement_cell(Vector2i(5, 5)) == false, "无快照墙格 (5,5) 期望不可放置 false。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 11
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelWorldQuery 四层快照 D5-B.2B 测试摘要 ====")
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


## 机关节点只读查表桩：供 LevelWorldQuery 的 get_placed_node_by_id Callable 解析 placed 字典，不暴露可写引用。
class _PlacedLookup:
	var placed: Dictionary = {}
	func get_node(mechanism_id: StringName) -> Variant:
		if not placed.has(mechanism_id):
			return null
		return placed[mechanism_id]
