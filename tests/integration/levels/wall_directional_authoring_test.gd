extends SceneTree

## Wall Directional Authoring 定向集成测试。
## 基于 wall_tileset.tres 真实资源 + 真实 LevelTileLayerSnapshot / LevelWorldQuery / RayExecutionModule /
##   LevelValidator，固化四种视觉方向（─ │ / \）在 used_cells、静态阻挡、光线 WALL 停止、Validator 规则上
##   完全等价；证明 gameplay 不按 source/atlas/alternative 区分方向，不存在方向特异分支。
## 不复制生产规则实现，仅通过正式 API 观测四方向行为一致性。
## headless extends SceneTree，由 Godot --script 运行；失败项收集后统一退出（任一失败 quit(1)）。

const _WALL_TILESET_PATH: String = "res://assets/art/tilesets/wall_tileset.tres"

const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")
const _ObjectVisualProfile: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_profile.gd")

## 四方向 atlas 坐标（与 wall_tileset.tres 冻结布局一致）：(0,0)=─ (1,0)=│ (2,0)=/ (3,0)=\。
const _DIRS: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
const _DIR_NAMES: Array = ["horizontal", "vertical", "slash", "backslash"]
const _GROUP_COUNT: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_tileset_contract()
	_test_02_used_cells_equivalence()
	_test_03_worldquery_equivalence()
	_test_04_ray_equivalence()
	_test_05_validator_equivalence()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 1. TileSet 合同 =====

## wall_tileset.tres 可加载、tile_size 64×64、source 0 四方向 tile 齐、无方向 gameplay custom data。
func _test_01_tileset_contract() -> void:
	const G: String = "01_TileSet合同"
	var ts: TileSet = load(_WALL_TILESET_PATH)
	_check(G, ts != null, "wall_tileset.tres 加载失败。")
	if ts == null:
		return
	_check(G, ts.tile_size == Vector2i(64, 64), "tile_size 应为 64×64，实际 %s。" % str(ts.tile_size))
	_check(G, ts.has_source(0), "应存在 source 0。")
	var s: TileSetAtlasSource = ts.get_source(0) as TileSetAtlasSource
	_check(G, s != null, "source 0 应为 TileSetAtlasSource。")
	if s == null:
		return
	for i in range(4):
		_check(G, s.has_tile(_DIRS[i]), "%s 方向 atlas %s 应存在 tile。" % [_DIR_NAMES[i], str(_DIRS[i])])
		_check(G, s.has_alternative_tile(_DIRS[i], 0), "%s 方向 atlas %s alt 0 应存在。" % [_DIR_NAMES[i], str(_DIRS[i])])
	# 无方向 gameplay custom data：custom data 层数为 0（方向 metadata 必以 custom data 层形式出现）。
	_check(G, ts.get_custom_data_layers_count() == 0, "不应存在 custom data 层（含方向 metadata），实际 %d。" % ts.get_custom_data_layers_count())


# ===== 2. used_cells 等价 =====

## 四方向 tile 分别 set_cell 后 get_used_cells 含四格；逐格 erase_cell 后该格消失、其余保留。
func _test_02_used_cells_equivalence() -> void:
	const G: String = "02_used_cells等价"
	var ts: TileSet = load(_WALL_TILESET_PATH)
	var layer: TileMapLayer = TileMapLayer.new()
	layer.tile_set = ts
	var cells: Array = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]
	for i in range(4):
		layer.set_cell(cells[i], 0, _DIRS[i], 0)
	var used: Array = layer.get_used_cells()
	for i in range(4):
		_check(G, used.has(cells[i]), "get_used_cells 应含 %s 方向格 %s。" % [_DIR_NAMES[i], str(cells[i])])
	# 逐格 erase：被擦除格消失，其后未擦除格仍在（四方向不因 atlas 不同漏格或残留）。
	for i in range(4):
		layer.erase_cell(cells[i])
		var after: Array = layer.get_used_cells()
		_check(G, not after.has(cells[i]), "erase_cell 后 %s 方向格 %s 应消失。" % [_DIR_NAMES[i], str(cells[i])])
		for j in range(i + 1, 4):
			_check(G, after.has(cells[j]), "擦除 %s 后未擦除的 %s 方向格 %s 应仍在。" % [_DIR_NAMES[i], _DIR_NAMES[j], str(cells[j])])
	layer.free()


# ===== 3. LevelWorldQuery 等价 =====

## 经真实 LevelTileLayerSnapshot + LevelWorldQuery：四方向墙格均 is_wall_cell / 静态阻挡 / 不可放置。
func _test_03_worldquery_equivalence() -> void:
	const G: String = "03_LevelWorldQuery等价"
	# 四方向墙格落 y=0 行（各一方向）；y=1 行作 LegalArea 自由格对照。
	var terrain: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
		Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
	var wall_specs: Array = []
	for i in range(4):
		wall_specs.append([Vector2i(i, 0), _DIRS[i]])
	var legal: Array = [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
	var q: _LevelWorldQuery = _build_query(terrain, wall_specs, legal, Vector2i(-9, -9))
	for i in range(4):
		var c: Vector2i = Vector2i(i, 0)
		_check(G, q.is_wall_cell(c) == true, "%s 方向墙 %s 期望 is_wall_cell=true。" % [_DIR_NAMES[i], str(c)])
		_check(G, q.is_static_blocked_for_placement(c) == true, "%s 方向墙 %s 期望静态阻挡=true。" % [_DIR_NAMES[i], str(c)])
		_check(G, q.is_valid_placement_cell(c) == false, "%s 方向墙 %s 期望不可放置。" % [_DIR_NAMES[i], str(c)])
	# 对照：LegalArea 内非墙自由格可放置，证明阻挡来自墙体而非整体不可放置。
	_check(G, q.is_valid_placement_cell(Vector2i(0, 1)) == true, "自由合法格 (0,1) 期望可放置。")


# ===== 4. Ray 等价 =====

## 四方向墙均令光线 StopReason.WALL 停止；墙格不进入传播 steps（无反射、不改向）。
func _test_04_ray_equivalence() -> void:
	const G: String = "04_Ray等价"
	var row: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)]
	for i in range(4):
		# 第 i 方向 atlas 在 (3,0) 立墙；光线自 (0,0) 向右传播。
		var q: _LevelWorldQuery = _build_query(row, [[Vector2i(3, 0), _DIRS[i]]], [], Vector2i(-9, -9))
		var res: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 0), Vector2i.RIGHT, 64, _LightWorldQuery.new(q))
		_check(G, res.stop_reason == _RayExecutionResult.StopReason.WALL, "%s 方向墙期望 WALL 停止，实际 %s。" % [_DIR_NAMES[i], str(res.stop_reason)])
		var wall_in_steps: bool = false
		for st in res.steps:
			if st.cell == Vector2i(3, 0):
				wall_in_steps = true
		_check(G, not wall_in_steps, "%s 方向墙格 (3,0) 不应进入 steps。" % _DIR_NAMES[i])
		_check(G, res.steps.size() == 2, "%s 方向墙期望 steps=2((1,0)(2,0))，实际 %d。" % [_DIR_NAMES[i], res.steps.size()])


# ===== 5. Validator 等价 =====

## (a) Terrain 内四方向墙不产生 wall_outside_terrain；(b) Terrain 外任一方向墙均 wall_outside_terrain；
## (c) 固定对象落任一方向墙均 fixed_object_on_wall；(b)(c) 四方向 issue code 集合完全一致——无方向特异 Issue。
func _test_05_validator_equivalence() -> void:
	const G: String = "05_Validator等价"
	var cells_3x3: Array = _cells_3x3()
	# (a) 四方向墙全在 Terrain 内、不压 LegalArea/Emitter/Crystal。
	var in_specs: Array = [[Vector2i(3, 0), _DIRS[0]], [Vector2i(3, 1), _DIRS[1]], [Vector2i(2, 2), _DIRS[2]], [Vector2i(0, 2), _DIRS[3]]]
	var terrain_a: Array = _extend_terrain(cells_3x3, [Vector2i(3, 0), Vector2i(3, 1), Vector2i(0, 2)])
	var root_a: Node2D = _make_valid_level(terrain_a, in_specs, Vector2i(1, 0))
	var res_a: _LevelValidationResult = _LevelValidator.new().validate(root_a)
	_check(G, not _has_code(res_a, "wall_outside_terrain"), "Terrain 内四方向墙不应产生 wall_outside_terrain。")
	_check(G, res_a.get_error_count() == 0, "Terrain 内四方向墙 fixture 期望 0 ERROR，实际 %d。" % res_a.get_error_count())
	root_a.free()
	# (b) Terrain 外墙：四方向各自均产生 wall_outside_terrain(7,7)，且 code 集合一致。
	var sig_b: PackedStringArray = PackedStringArray()
	for i in range(4):
		var root: Node2D = _make_valid_level(cells_3x3, [[Vector2i(7, 7), _DIRS[i]]], Vector2i(1, 0))
		var res: _LevelValidationResult = _LevelValidator.new().validate(root)
		_check(G, _has_cell_issue(res, "wall_outside_terrain", Vector2i(7, 7)), "%s 方向外墙期望 wall_outside_terrain(7,7)。" % _DIR_NAMES[i])
		sig_b.append(_code_set(res))
		root.free()
	for i in range(1, 4):
		_check(G, sig_b[i] == sig_b[0], "外墙四方向 Validator code 集合应一致（方向 %s 与 horizontal 不同）。" % _DIR_NAMES[i])
	# (c) 固定对象落墙上：四方向各自均产生 fixed_object_on_wall(2,2)，且 code 集合一致。
	var sig_c: PackedStringArray = PackedStringArray()
	for i in range(4):
		var root: Node2D = _make_valid_level(cells_3x3, [[Vector2i(2, 2), _DIRS[i]]], Vector2i(2, 2))
		var res: _LevelValidationResult = _LevelValidator.new().validate(root)
		_check(G, _has_cell_issue(res, "fixed_object_on_wall", Vector2i(2, 2)), "%s 方向墙期望 fixed_object_on_wall(2,2)。" % _DIR_NAMES[i])
		sig_c.append(_code_set(res))
		root.free()
	for i in range(1, 4):
		_check(G, sig_c[i] == sig_c[0], "墙对象四方向 Validator code 集合应一致（方向 %s 与 horizontal 不同）。" % _DIR_NAMES[i])


# ===== 通用：快照世界构造（WorldQuery / Ray 共用） =====

## 构造真实快照驱动 LevelWorldQuery：wall 层绑定真实 wall_tileset 按 specs[cell,atlas] 绘方向墙；
## 其余层用最小 TileSet；walls 兼容入参为空（有快照下不读）。临时层在快照复制后立即释放。
func _build_query(terrain_cells: Array, wall_specs: Array, legal_cells: Array, emitter_cell: Vector2i) -> _LevelWorldQuery:
	var min_ts: TileSet = _make_min_tile_set()
	var terrain_layer: TileMapLayer = _make_layer("", min_ts, terrain_cells)
	var wall_layer: TileMapLayer = _make_wall_layer("", wall_specs)
	var legal_layer: TileMapLayer = _make_layer("", min_ts, legal_cells)
	var deco_layer: TileMapLayer = _make_layer("", min_ts, [])
	var snapshot: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(terrain_layer, wall_layer, legal_layer, deco_layer)
	terrain_layer.free()
	wall_layer.free()
	legal_layer.free()
	deco_layer.free()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls_arg: Array[Vector2i] = []
	return _LevelWorldQuery.new(
		snapshot.get_terrain_bounds(), walls_arg, emitter_cell, registry, occupancy,
		Callable(lookup, "get_node"), snapshot)


# ===== 通用：Validator fixture（复用既有测试 fixture 范式，不复制生产规则） =====

## 组装结构合法关卡根：六角色齐备；Wall 层绑定真实 wall_tileset 按 specs 绘方向墙；
## LegalArea 固定 (0,0) 避 legal_area_empty；RuntimeObjects 含合法 Emitter@(0,0)+Crystal@(crystal_cell)。
func _make_valid_level(terrain_cells: Array, wall_specs: Array, crystal_cell: Vector2i) -> Node2D:
	var min_ts: TileSet = _make_min_tile_set()
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	root.add_child(_make_layer("TerrainLayer", min_ts, terrain_cells))
	root.add_child(_make_wall_layer("WallLayer", wall_specs))
	root.add_child(_make_layer("LegalAreaLayer", min_ts, [Vector2i(0, 0)]))
	root.add_child(_make_layer("DecorationLayer", min_ts, []))
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	_add_valid_emitter(runtime, Vector2i(0, 0))
	_add_valid_crystal(runtime, crystal_cell, &"crystal_dir")
	var light: Node2D = Node2D.new()
	light.name = &"LightPathLayer"
	root.add_child(light)
	return root


# ===== 层 / 对象构造辅助 =====

## 最小可用 TileSet：单 atlas 源、无纹理；set_cell 引用 source 0 即可使 get_used_cells 返回该格。
func _make_min_tile_set() -> TileSet:
	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	ts.add_source(source)
	return ts


## 普通 TileMapLayer（name 为空则不命名）：绑定给定 TileSet，逐格 set_cell 用 atlas(0,0)。
func _make_layer(name: String, ts: TileSet, cells: Array) -> TileMapLayer:
	var l: TileMapLayer = TileMapLayer.new()
	if name.length() > 0:
		l.name = StringName(name)
	l.tile_set = ts
	for c: Vector2i in cells:
		l.set_cell(c, 0, Vector2i.ZERO, 0)
	return l


## 方向墙层：绑定真实 wall_tileset，按 specs[cell, atlas] 逐格绘制不同方向。
func _make_wall_layer(name: String, specs: Array) -> TileMapLayer:
	var l: TileMapLayer = TileMapLayer.new()
	if name.length() > 0:
		l.name = StringName(name)
	l.tile_set = load(_WALL_TILESET_PATH)
	for spec in specs:
		l.set_cell(spec[0], 0, spec[1], 0)
	return l


## 3×3 实心 Terrain 格（含 (0,0) 以匹配 LegalArea 与 Emitter）。
func _cells_3x3() -> Array:
	return [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]


## 在 3×3 基础上追加额外 Terrain 格（供四方向墙有足够在界落点）。
func _extend_terrain(base: Array, extra: Array) -> Array:
	var out: Array = base.duplicate()
	for c: Vector2i in extra:
		out.append(c)
	return out


## 新建非空 ObjectVisualProfile（校验器只判 != null）。
func _new_profile() -> _ObjectVisualProfile:
	return _ObjectVisualProfile.new()


## 真实 EmitterConfigNode：名 Emitter、position 居中目标格、绑 Profile。
func _new_emitter(cell: Vector2i) -> _EmitterConfigNode:
	var e: _EmitterConfigNode = _EmitterConfigNode.new()
	e.name = &"Emitter"
	e.position = _GridCoordinateRules.cell_to_world(cell)
	e.visual_profile = _new_profile()
	return e


## 真实 BasicCrystal：名 BasicCrystal、position 居中目标格、显式 crystal_id、直属 VisualView+Profile。
func _new_crystal(cell: Vector2i, crystal_id: StringName) -> _BasicCrystal:
	var c: _BasicCrystal = _BasicCrystal.new()
	c.name = &"BasicCrystal"
	c.position = _GridCoordinateRules.cell_to_world(cell)
	c.crystal_id = crystal_id
	var view: _ObjectVisualView = _ObjectVisualView.new()
	view.name = &"VisualView"
	view.visual_profile = _new_profile()
	c.add_child(view)
	return c


## 在 RuntimeObjects 直属下放置合法 Emitter。
func _add_valid_emitter(runtime: Node2D, cell: Vector2i) -> void:
	runtime.add_child(_new_emitter(cell))


## 在 RuntimeObjects 直属下放置合法 Crystal。
func _add_valid_crystal(runtime: Node2D, cell: Vector2i, crystal_id: StringName) -> void:
	runtime.add_child(_new_crystal(cell, crystal_id))


# ===== 断言 / 记录辅助 =====

## 结果中是否存在指定 code 的 issue。
func _has_code(result, code: String) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			return true
	return false


## 结果中是否存在指定 code 且 cell 匹配的 cell 级 issue。
func _has_cell_issue(result, code: String, cell: Vector2i) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code and issue.has_cell() and issue.get_cell() == cell:
			return true
	return false


## 结果 issue 的 code 排序签名（用于四方向 Validator 输出一致性比对，证明无方向特异 Issue）。
func _code_set(result) -> String:
	var codes: PackedStringArray = PackedStringArray()
	for issue in result.get_issues():
		codes.append(str(issue.get_code()))
	codes.sort()
	return "\n".join(codes)


## 单项断言：累计计数，失败追加“[组名] 原因”。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed: int = _checks - _failures.size()
	print("==== Wall Directional Authoring 定向集成 测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for f: String in _failures:
			print(f)


## 机关节点只读查表桩：供 LevelWorldQuery 的 get_placed_node_by_id Callable 解析，不暴露可写引用。
class _PlacedLookup:
	var placed: Dictionary = {}
	func get_node(mechanism_id: StringName) -> Variant:
		if not placed.has(mechanism_id):
			return null
		return placed[mechanism_id]
