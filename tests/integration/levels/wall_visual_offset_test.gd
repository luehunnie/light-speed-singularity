extends SceneTree

## Wall Visual Offset 统一视觉偏移 定向集成测试（S3-02）。
## 冻结合同：墙体统一像素偏移 = wall_tileset.tres 四方向 atlas tile 的 TileData.texture_origin
##   取同一 Vector2i 值（单一 Vector2、四方向共用；不存在按方向查表的偏移来源）。
## 证明：
##   1) 默认 ZERO（TileData 引擎默认 + 仓库 wall_tileset.tres 现值 + 既有关卡场景资源链）向后兼容；
##   2) 非零统一应用后 used_cells / source·atlas / map_to_local / LevelTileLayerSnapshot /
##      LevelWorldQuery / Ray WALL 停止 / LevelValidator 全部不变（纯视觉，逻辑零影响），且与偏移取值无关；
##      四方向 texture_origin 任意时刻必须完全相等（禁止四方向偏移表）；
##   3) Reset 回 ZERO 恢复基线；磁盘真值不受内存改动污染（CACHE_MODE_IGNORE 重读仍 ZERO）、Reset/Reload 稳定。
## 不复制生产规则实现，仅经正式 API 观测；不落盘任何资源。
## headless extends SceneTree，由 Godot --script 运行；失败项收集后统一退出（任一失败 quit(1)）。

const _WALL_TILESET_PATH: String = "res://assets/art/tilesets/wall_tileset.tres"
const _TRACKED_LEVEL_PATH: String = "res://levels/campaign/ray_chapter/level_ray_001.tscn"

const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")
const _ObjectVisualProfile: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_profile.gd")

## 四方向 atlas 坐标（与 wall_tileset.tres 冻结布局一致）：(0,0)=─ (1,0)=│ (2,0)=/ (3,0)=\。
const _DIRS: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
const _DIR_NAMES: Array = ["horizontal", "vertical", "slash", "backslash"]
const _GROUP_COUNT: int = 3

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_zero_default_contract()
	_test_02_nonzero_gameplay_neutral()
	_test_03_reset_reload_stable()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 1. 默认 ZERO 合同（向后兼容） =====

## TileData 引擎默认 texture_origin=ZERO；仓库 wall_tileset.tres 四方向现值全 ZERO；
## 既有 tracked 关卡场景（level_ray_001）可实例化且 WallLayer 资源链完好——默认状态零改变。
func _test_01_zero_default_contract() -> void:
	const G: String = "01_默认ZERO合同"
	var td: TileData = TileData.new()
	_check(G, td.texture_origin == Vector2i.ZERO, "TileData 引擎默认 texture_origin 应为 ZERO，实际 %s。" % str(td.texture_origin))
	td.free()
	var ts: TileSet = load(_WALL_TILESET_PATH)
	_check(G, ts != null, "wall_tileset.tres 加载失败。")
	if ts == null:
		return
	var s: TileSetAtlasSource = ts.get_source(0) as TileSetAtlasSource
	_check(G, s != null, "wall_tileset source 0 应为 TileSetAtlasSource。")
	if s == null:
		return
	for i in range(4):
		var v: Vector2i = s.get_tile_data(_DIRS[i], 0).texture_origin
		_check(G, v == Vector2i.ZERO, "%s 方向 tile texture_origin 仓库默认应为 ZERO，实际 %s。" % [_DIR_NAMES[i], str(v)])
	_check(G, _all_origins_equal(s), "默认状态四方向 texture_origin 应彼此相等（单一 Vector2 四方向共用）。")
	var scene: PackedScene = load(_TRACKED_LEVEL_PATH)
	_check(G, scene != null, "level_ray_001.tscn 加载失败。")
	if scene != null:
		var root: Node2D = scene.instantiate() as Node2D
		var layer: TileMapLayer = root.get_node("WallLayer") as TileMapLayer
		_check(G, layer != null and layer.tile_set != null, "level_ray_001 WallLayer 存在且绑定 TileSet（资源链完好）。")
		_check(G, not layer.get_used_cells().is_empty(), "level_ray_001 WallLayer 应有真实墙格（默认状态零改变）。")
		root.free()


# ===== 2. 非零统一应用、逻辑不变 =====

## 统一偏移 (7,-3) 与 (-5,11) 两种取值：四方向 tile 同值读回；used/source·atlas/map_to_local/
## 快照/WorldQuery/Ray/Validator 指纹与 ZERO 基线完全一致——纯视觉、与取值无关、无方向特异分支。
func _test_02_nonzero_gameplay_neutral() -> void:
	const G: String = "02_非零统一逻辑不变"
	var ts: TileSet = load(_WALL_TILESET_PATH)
	var baseline: Dictionary = _logic_fingerprint(ts)
	for offset: Vector2i in [Vector2i(7, -3), Vector2i(-5, 11)]:
		_apply_unified_origin(ts, offset)
		var s: TileSetAtlasSource = ts.get_source(0) as TileSetAtlasSource
		_check(G, _all_origins_equal(s), "偏移 %s 下四方向 texture_origin 应完全相等（禁止四方向偏移表）。" % str(offset))
		for i in range(4):
			var v: Vector2i = s.get_tile_data(_DIRS[i], 0).texture_origin
			_check(G, v == offset, "%s 方向 texture_origin 应读回 %s，实际 %s（统一应用）。" % [_DIR_NAMES[i], str(offset), str(v)])
		var fp: Dictionary = _logic_fingerprint(ts)
		_check(G, fp == baseline, "偏移 %s 下逻辑指纹应与 ZERO 基线一致，差异键：%s。" % [str(offset), str(_diff_keys(fp, baseline))])
	_apply_unified_origin(ts, Vector2i.ZERO)


# ===== 3. Reset / Reload 稳定 =====

## 非零后 Reset 回 ZERO：指纹恢复基线；CACHE_MODE_IGNORE 绕缓存重读磁盘真值仍全 ZERO
##（内存改动从不落盘）；缓存实例同回 ZERO（无泄漏）；TileSet 形状（tile_size/四 tile）不变。
func _test_03_reset_reload_stable() -> void:
	const G: String = "03_Reset与Reload稳定"
	var ts: TileSet = load(_WALL_TILESET_PATH)
	var baseline: Dictionary = _logic_fingerprint(ts)
	_apply_unified_origin(ts, Vector2i(7, -3))
	_apply_unified_origin(ts, Vector2i.ZERO)
	var s: TileSetAtlasSource = ts.get_source(0) as TileSetAtlasSource
	_check(G, _all_origins_equal(s), "Reset 后四方向 texture_origin 应相等。")
	for i in range(4):
		var v: Vector2i = s.get_tile_data(_DIRS[i], 0).texture_origin
		_check(G, v == Vector2i.ZERO, "Reset 后 %s 方向应为 ZERO，实际 %s。" % [_DIR_NAMES[i], str(v)])
	_check(G, _logic_fingerprint(ts) == baseline, "Reset 后逻辑指纹应恢复基线。")
	var fresh: TileSet = ResourceLoader.load(_WALL_TILESET_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as TileSet
	var fs: TileSetAtlasSource = fresh.get_source(0) as TileSetAtlasSource
	_check(G, _all_origins_equal(fs), "磁盘重读四方向 texture_origin 应相等。")
	for i in range(4):
		var v2: Vector2i = fs.get_tile_data(_DIRS[i], 0).texture_origin
		_check(G, v2 == Vector2i.ZERO, "磁盘真值 %s 方向应仍为 ZERO（内存改动不落盘），实际 %s。" % [_DIR_NAMES[i], str(v2)])
	_check(G, fresh.tile_size == Vector2i(64, 64) and fs.get_tiles_count() == 4, "重读 TileSet 形状应不变（64×64、四方向 tile 齐）。")


# ===== 通用：统一偏移应用 / 四方向同值判定 =====

## 把同一 Vector2i 写入四方向 atlas tile 的 texture_origin（唯一写入口；单一值四方向共用）。
func _apply_unified_origin(ts: TileSet, offset: Vector2i) -> void:
	var s: TileSetAtlasSource = ts.get_source(0) as TileSetAtlasSource
	for atlas: Vector2i in _DIRS:
		s.get_tile_data(atlas, 0).texture_origin = offset


## 四方向 texture_origin 是否完全相等（守卫：禁止演化为按方向分表）。
func _all_origins_equal(s: TileSetAtlasSource) -> bool:
	var first: Vector2i = s.get_tile_data(_DIRS[0], 0).texture_origin
	for i in range(1, 4):
		if s.get_tile_data(_DIRS[i], 0).texture_origin != first:
			return false
	return true


# ===== 通用：逻辑指纹（视觉偏移下的 gameplay 不变性观测） =====

## 汇总墙体全部逻辑观测面：四方向 used cells + 逐格 source/atlas + map_to_local 采样 +
## 快照 wall 格 + WorldQuery 三标志 + Ray 停止与步数 + Validator code 签名。纯视觉偏移下应逐键一致。
## 布局镜像 wall_directional_authoring_test：墙=行0 四格各一方向，Terrain=两行四列，LegalArea=(0,1)。
func _logic_fingerprint(ts: TileSet) -> Dictionary:
	var fp: Dictionary = {}
	var wall_cells: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	var layer: TileMapLayer = _make_wall_layer(ts)
	for i in range(4):
		layer.set_cell(wall_cells[i], 0, _DIRS[i], 0)
	var used: Array = layer.get_used_cells()
	used.sort()
	fp["used"] = used.duplicate()
	var details: PackedStringArray = PackedStringArray()
	for i in range(4):
		var c: Vector2i = wall_cells[i]
		details.append("%d,%d,%s|%s" % [layer.get_cell_source_id(c), layer.get_cell_alternative_tile(c), str(layer.get_cell_atlas_coords(c)), str(layer.map_to_local(c))])
	fp["cells"] = ",".join(details)
	var terrain: Array = []
	for x in range(4):
		terrain.append(Vector2i(x, 0))
		terrain.append(Vector2i(x, 1))
	var terrain_layer: TileMapLayer = _make_layer(_make_min_tile_set(), terrain)
	var legal_layer: TileMapLayer = _make_layer(_make_min_tile_set(), [Vector2i(0, 1)])
	var deco_layer: TileMapLayer = _make_layer(_make_min_tile_set(), [])
	var snapshot: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(terrain_layer, layer, legal_layer, deco_layer)
	terrain_layer.free()
	legal_layer.free()
	deco_layer.free()
	var wall_copy: Array = snapshot.get_wall_cells_copy()
	wall_copy.sort()
	fp["snapshot_walls"] = wall_copy.duplicate()
	# 快照构造即复制格值；层已释放（镜像 wall_directional_authoring_test 生命周期）。
	var q: _LevelWorldQuery = _build_query(snapshot)
	for i in range(4):
		var c: Vector2i = wall_cells[i]
		fp["wall_%d" % i] = q.is_wall_cell(c)
		fp["blocked_%d" % i] = q.is_static_blocked_for_placement(c)
		fp["placeable_%d" % i] = q.is_valid_placement_cell(c)
	fp["free_placeable"] = q.is_valid_placement_cell(Vector2i(0, 1))
	var res: _RayExecutionResult = _RayExecutionModule.execute(Vector2i(0, 1), Vector2i(0, -1), 64, _LightWorldQuery.new(q), 7, 1)
	fp["ray_stop"] = res.stop_reason
	fp["ray_steps"] = res.steps.size()
	fp["validator_sig"] = _validator_code_signature(ts)
	layer.free()
	return fp


## Validator 观测：真实 LevelValidator 校验含真实 wall_tileset 四方向墙的合法关卡，返回 code 排序签名。
func _validator_code_signature(ts: TileSet) -> String:
	var root: Node2D = _make_valid_level(ts)
	var res: _LevelValidationResult = _LevelValidator.new().validate(root)
	var codes: PackedStringArray = PackedStringArray()
	for issue in res.get_issues():
		codes.append(str(issue.get_code()))
	codes.sort()
	root.free()
	return "\n".join(codes)


# ===== 通用：世界构造（WorldQuery / Ray 共用） =====

## 以快照构造真实 LevelWorldQuery（Registry/Occupancy/Callable 查表桩齐备；墙事实全在快照内）。
func _build_query(snapshot) -> _LevelWorldQuery:
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls_arg: Array[Vector2i] = []
	return _LevelWorldQuery.new(
		snapshot.get_terrain_bounds(), walls_arg, Vector2i(-9, -9), registry, occupancy,
		Callable(lookup, "get_node"), snapshot)


# ===== 通用：Validator fixture（复用既有测试 fixture 范式，不复制生产规则） =====

## 组装结构合法关卡根：四角色齐备；Wall 层绑定给定（真实 wall_tileset）TileSet 绘四方向墙；
## LegalArea 固定 (0,0)；RuntimeObjects 含合法 Emitter@(0,0)+Crystal@(1,1)；墙 (5,0)/(3,1) 全在 Terrain 内。
func _make_valid_level(ts: TileSet) -> Node2D:
	var min_ts: TileSet = _make_min_tile_set()
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	var terrain_cells: Array = []
	for x in range(6):
		terrain_cells.append(Vector2i(x, 0))
	for x in range(5):
		terrain_cells.append(Vector2i(x, 1))
	var terrain: TileMapLayer = _make_layer(min_ts, terrain_cells)
	terrain.name = &"TerrainLayer"
	root.add_child(terrain)
	var wall: TileMapLayer = _make_wall_layer(ts)
	wall.name = &"WallLayer"
	wall.set_cell(Vector2i(5, 0), 0, _DIRS[0], 0)
	wall.set_cell(Vector2i(3, 1), 0, _DIRS[1], 0)
	root.add_child(wall)
	var legal: TileMapLayer = _make_layer(min_ts, [Vector2i(0, 0)])
	legal.name = &"LegalAreaLayer"
	root.add_child(legal)
	var deco: TileMapLayer = _make_layer(min_ts, [])
	deco.name = &"DecorationLayer"
	root.add_child(deco)
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	_add_valid_emitter(runtime, Vector2i(0, 0))
	_add_valid_crystal(runtime, Vector2i(1, 1), &"crystal_dir")
	var light: Node2D = Node2D.new()
	light.name = &"LightPathLayer"
	root.add_child(light)
	return root


# ===== 层 / 对象构造辅助 =====

## 最小可用 TileSet：单 atlas 源、无纹理。
func _make_min_tile_set() -> TileSet:
	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	ts.add_source(source)
	return ts


## 普通 TileMapLayer：绑定给定 TileSet，逐格 set_cell 用 atlas(0,0)。
func _make_layer(ts: TileSet, cells: Array) -> TileMapLayer:
	var l: TileMapLayer = TileMapLayer.new()
	l.tile_set = ts
	for c: Vector2i in cells:
		l.set_cell(c, 0, Vector2i.ZERO, 0)
	return l


## 方向墙层：绑定给定（真实 wall_tileset）TileSet。
func _make_wall_layer(ts: TileSet) -> TileMapLayer:
	var l: TileMapLayer = TileMapLayer.new()
	l.tile_set = ts
	return l


## 真实 EmitterConfigNode：名 Emitter、position 居中目标格、绑 Profile。
func _new_emitter(cell: Vector2i) -> _EmitterConfigNode:
	var e: _EmitterConfigNode = _EmitterConfigNode.new()
	e.name = &"Emitter"
	e.position = _GridCoordinateRules.cell_to_world(cell)
	e.visual_profile = _ObjectVisualProfile.new()
	return e


## 真实 BasicCrystal：名 BasicCrystal、position 居中目标格、显式 crystal_id、直属 VisualView+Profile。
func _new_crystal(cell: Vector2i, crystal_id: StringName) -> _BasicCrystal:
	var c: _BasicCrystal = _BasicCrystal.new()
	c.name = &"BasicCrystal"
	c.position = _GridCoordinateRules.cell_to_world(cell)
	c.crystal_id = crystal_id
	var view: _ObjectVisualView = _ObjectVisualView.new()
	view.name = &"VisualView"
	view.visual_profile = _ObjectVisualProfile.new()
	c.add_child(view)
	return c


## 在 RuntimeObjects 直属下放置合法 Emitter / Crystal。
func _add_valid_emitter(runtime: Node2D, cell: Vector2i) -> void:
	runtime.add_child(_new_emitter(cell))


func _add_valid_crystal(runtime: Node2D, cell: Vector2i, crystal_id: StringName) -> void:
	runtime.add_child(_new_crystal(cell, crystal_id))


# ===== 断言 / 记录辅助 =====

## 两指纹差异键列表（失败信息定位用）。
func _diff_keys(a: Dictionary, b: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for key: Variant in a:
		if not b.has(key) or a[key] != b[key]:
			out.append(str(key))
	return out


## 单项断言：累计计数，失败追加“[组名] 原因”。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed: int = _checks - _failures.size()
	print("==== Wall Visual Offset 统一视觉偏移 测试摘要 ====")
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
