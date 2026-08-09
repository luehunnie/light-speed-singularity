extends SceneTree

## D5-C.2 正式模板动态消费冒烟测试。
##
## 真实加载并实例化 res://levels/templates/level_template.tscn（正式空白模板），全程不修改、不保存该资源；
## 在测试实例内存中向 Terrain/Wall/LegalArea/Decoration 四层写入少量非矩形格（仅写实例层，不触碰共享 TileSet），
## 用真实四层实例构造 LevelTileLayerSnapshot，再构造 LevelWorldQuery，验证：
##   - Terrain 格属于边界；Terrain 外包矩形中的空洞不属于边界；
##   - Legal 内可放置；Terrain 内非 Legal 不可放置；
##   - Wall 不可放置且 is_wall_cell=true（墙落在 Legal+Terrain 格上以隔离墙阻挡为决定性因素）；
##   - Decoration 不改变边界/Legal/Wall 任一事实；
## 最后重新加载一份全新实例，证明正式模板原始四层仍为空（测试未写回资源）。
##
## 不接入 core_loop_prototype 的 UI/输入/库存/运行控制器；LevelWorldQuery 的 emitter_cell 传入远离测试网格的哨兵格，
## registry/occupancy 为空实例，聚焦四层动态消费本身。
## headless extends SceneTree，由 Godot --headless --script 运行；preload 引用模块避开全局 class_name 缓存坑。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不修改 assets/templates，不生成资源文件。


const _FORMAL_SCENE_PATH: String = "res://levels/templates/level_template.tscn"

const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")

const _GROUP_COUNT: int = 9

## 测试网格所用 source id / atlas 坐标；四层各自绑定 TileSet 均含 sources/0，set_cell 仅写实例层、不修改共享 TileSet。
const _SOURCE_ID: int = 0
const _ATLAS_COORDS: Vector2i = Vector2i.ZERO
const _ALT_TILE: int = 0
## LevelWorldQuery 构造用发射源哨兵格，远离测试网格（0..5），避免静态阻挡干扰四层验证。
const _EMITTER_SENTINEL_CELL: Vector2i = Vector2i(-9, -9)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


## SceneTree 初始化入口：加载实例 → 写四层 → 构造快照/查询 → 逐组验证 → 重新加载证明未写回 → 报告退出。
func _initialize() -> void:
	# --script 模式下首帧前等待一帧，确保后续资源访问处于稳定帧（与 level_template_contract_test 同款）。
	await process_frame

	var scene: PackedScene = load(_FORMAL_SCENE_PATH) as PackedScene
	var inst_a: Node2D = _safe_instance(scene)

	# 写入前基线：正式模板实例四层均为空（与 D5-C.1 用例 04 一致，确认起点无预置格）。
	_test_01_scene_loadable(scene, inst_a)
	_test_02_initial_four_layers_empty(inst_a)

	# 在测试实例内存中向四层写入少量非矩形格（仅实例层，不触碰共享 TileSet，不保存场景）。
	# Terrain：3×3 环、中心 (1,1) 为空洞（外包矩形 3×3=9，used=8 < 9，不规则）。
	# LegalArea：Terrain 子集 {(0,0),(2,2)}。
	# Wall：一格 (0,0)，落在 Terrain+Legal 上以隔离“墙是决定性阻挡”。
	# Decoration：独立格 (5,5)，位于 Terrain 之外。
	var layers: Dictionary = _collect_direct_tilemap_layers(inst_a)
	var terrain_cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]
	var legal_cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(2, 2)]
	var wall_cells: Array[Vector2i] = [Vector2i(0, 0)]
	var decoration_cells: Array[Vector2i] = [Vector2i(5, 5)]
	_paint(layers, "TerrainLayer", terrain_cells)
	_paint(layers, "LegalAreaLayer", legal_cells)
	_paint(layers, "WallLayer", wall_cells)
	_paint(layers, "DecorationLayer", decoration_cells)

	_test_03_written_layer_shapes(layers)

	# 用真实四层实例构造 LevelTileLayerSnapshot（先 validate_layers 再 new 两段式）。
	var terrain_layer: TileMapLayer = layers.get("TerrainLayer") as TileMapLayer
	var wall_layer: TileMapLayer = layers.get("WallLayer") as TileMapLayer
	var legal_layer: TileMapLayer = layers.get("LegalAreaLayer") as TileMapLayer
	var decoration_layer: TileMapLayer = layers.get("DecorationLayer") as TileMapLayer
	var snapshot: Object = null
	if _LevelTileLayerSnapshot.validate_layers(terrain_layer, wall_layer, legal_layer, decoration_layer):
		snapshot = _LevelTileLayerSnapshot.new(terrain_layer, wall_layer, legal_layer, decoration_layer)

	# 用快照构造 LevelWorldQuery（emitter 哨兵远离测试网格；registry/occupancy 空）。
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls_arg: Array[Vector2i] = []
	var query: _LevelWorldQuery = null
	if snapshot != null:
		query = _LevelWorldQuery.new(
			snapshot.get_terrain_bounds(),
			walls_arg,
			_EMITTER_SENTINEL_CELL,
			registry,
			occupancy,
			Callable(lookup, "get_node"),
			snapshot
		)

	_test_04_snapshot_from_real_layers(snapshot)
	_test_05_boundary_terrain_and_hole(query)
	_test_06_legal_placement(query)
	_test_07_wall_not_placeable(query)
	_test_08_decoration_inert(query, snapshot)

	# 释放实例 A（快照已复制 used cells；query/registry/occupancy 为 RefCounted 自动释放）。
	if inst_a != null:
		inst_a.free()

	# 重新加载全新实例证明未写回资源：正式模板原始四层仍为空。
	_test_09_reload_original_layers_empty()

	# 实例从未挂入 SceneTree，root 不应残留子节点（单独记为清理检查，不计入 9 个契约组）。
	_check_residual_clean()

	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 通用辅助 =====

## 实例化场景为 Node2D，失败返回 null（不挂入 SceneTree，不触发 _ready）。
func _safe_instance(scene: PackedScene) -> Node2D:
	if scene == null:
		return null
	var n: Node = scene.instantiate()
	if n == null:
		return null
	if not (n is Node2D):
		n.free()
		return null
	return n as Node2D


## 收集 root 直属子节点中的 TileMapLayer，返回 {String 节点名: TileMapLayer}（键统一为 String，避免 StringName/String 哈希错配）。
func _collect_direct_tilemap_layers(root_node: Node) -> Dictionary:
	var out: Dictionary = {}
	if root_node == null:
		return out
	for c in root_node.get_children():
		if c is TileMapLayer:
			var nm: String = c.name
			out[nm] = c
	return out


## 读取某层 used_cells 到 {Vector2i: true} 字典；层缺失返回空字典。
func _used_cells_set(layers: Dictionary, layer_name: String) -> Dictionary:
	var out: Dictionary = {}
	var layer: TileMapLayer = layers.get(layer_name) as TileMapLayer
	if layer == null:
		return out
	for cell: Vector2i in layer.get_used_cells():
		out[cell] = true
	return out


## 向实例层逐格 set_cell（仅写实例层数据，不修改共享 TileSet，不保存场景）。
func _paint(layers: Dictionary, layer_name: String, cells: Array[Vector2i]) -> void:
	var layer: TileMapLayer = layers.get(layer_name) as TileMapLayer
	if layer == null:
		return
	for cell: Vector2i in cells:
		layer.set_cell(cell, _SOURCE_ID, _ATLAS_COORDS, _ALT_TILE)


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 实例从未入树，root 不应有残留子节点；单独记为清理检查，不计入契约组。
func _check_residual_clean() -> void:
	_check("R_清理检查_无SceneTree残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % root.get_child_count())


## 输出测试摘要：契约组数、清理检查、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var passed: int = _checks - _failures.size()
	print("==== 正式模板动态消费冒烟（D5-C.2）测试摘要 ====")
	print("契约组数：%d" % _GROUP_COUNT)
	print("清理检查：1")
	print("断言总数（含清理）：%d" % _checks)
	print("通过断言：%d" % passed)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for f: String in _failures:
			print(f)


# ===== 用例 =====

## 1. 正式模板可加载并实例化为 Node2D（亦即正式模板动态消费 headless smoke 起点）。
func _test_01_scene_loadable(scene: PackedScene, root_node: Node2D) -> void:
	const G: String = "01_正式模板可加载实例化"
	_check(G, scene != null, "level_template.tscn 加载失败。")
	_check(G, root_node != null, "正式模板实例化返回 null。")


## 2. 写入前基线：实例四层 get_used_cells() 均为空（正式空白模板不应预置任何格）。
func _test_02_initial_four_layers_empty(root_node: Node2D) -> void:
	const G: String = "02_写入前四层均为空"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	_check(G, layers.size() == 4, "根直属 TileMapLayer 应为 4 个，实际 %d 个。" % layers.size())
	for n: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		var layer: TileMapLayer = layers.get(n) as TileMapLayer
		if layer == null:
			_check(G, false, "%s 缺失，无法校验初始 used_cells。" % n)
			continue
		var used: Array = layer.get_used_cells()
		_check(G, used.is_empty(), "%s 写入前 get_used_cells() 应为空，实际 %d 格：%s。" % [n, used.size(), used])


## 3. 写入形状校验：四层 used_cells 与预期一致；Terrain 不规则（used < 外包矩形面积）含空洞；Legal/Wall ⊆ Terrain；Decoration 独立于 Terrain。
func _test_03_written_layer_shapes(layers: Dictionary) -> void:
	const G: String = "03_四层写入形状符合预期"
	var terrain_set: Dictionary = _used_cells_set(layers, "TerrainLayer")
	var legal_set: Dictionary = _used_cells_set(layers, "LegalAreaLayer")
	var wall_set: Dictionary = _used_cells_set(layers, "WallLayer")
	var deco_set: Dictionary = _used_cells_set(layers, "DecorationLayer")

	# Terrain：8 格，中心空洞 (1,1) 不存在；外包矩形 3×3=9，used=8 < 9 → 不规则。
	_check(G, terrain_set.size() == 8, "Terrain 应为 8 格，实际 %d 格。" % terrain_set.size())
	_check(G, not terrain_set.has(Vector2i(1, 1)), "Terrain 空洞 (1,1) 应不存在。")
	_check(G, terrain_set.size() < 9, "Terrain 应不规则（used < 外包矩形面积 9），实际 %d。" % terrain_set.size())

	# LegalArea：2 格且全在 Terrain 内（Legal 是 Terrain 子集）。
	_check(G, legal_set.size() == 2, "LegalArea 应为 2 格，实际 %d 格。" % legal_set.size())
	for c: Vector2i in [Vector2i(0, 0), Vector2i(2, 2)]:
		_check(G, legal_set.has(c) and terrain_set.has(c), "Legal 格 %s 应存在且位于 Terrain 内。" % c)

	# Wall：1 格 (0,0) 且在 Terrain 内。
	_check(G, wall_set.size() == 1, "Wall 应为 1 格，实际 %d 格。" % wall_set.size())
	_check(G, wall_set.has(Vector2i(0, 0)) and terrain_set.has(Vector2i(0, 0)), "Wall 格 (0,0) 应存在且位于 Terrain 内。")

	# Decoration：1 格 (5,5)，独立于 Terrain（不在 Terrain 内）。
	_check(G, deco_set.size() == 1, "Decoration 应为 1 格，实际 %d 格。" % deco_set.size())
	_check(G, deco_set.has(Vector2i(5, 5)) and not terrain_set.has(Vector2i(5, 5)), "Decoration 格 (5,5) 应存在且独立于 Terrain。")


## 4. 用真实四层实例构造 LevelTileLayerSnapshot：bounds 与四层 has_*_cell 查询符合写入形状。
func _test_04_snapshot_from_real_layers(snapshot: Object) -> void:
	const G: String = "04_真实四层实例构造快照"
	_check(G, snapshot != null, "LevelTileLayerSnapshot 构造失败（validate_layers 应已通过）。")
	if snapshot == null:
		return
	_check(G, snapshot.get_terrain_bounds() == Rect2i(0, 0, 3, 3), "Terrain 外包矩形应为 Rect2i(0,0,3,3)，实际 %s。" % [snapshot.get_terrain_bounds()])
	_check(G, snapshot.has_terrain_cell(Vector2i(0, 0)) == true, "Terrain (0,0) 期望 true。")
	_check(G, snapshot.has_terrain_cell(Vector2i(1, 1)) == false, "空洞 (1,1) 不应是 Terrain。")
	_check(G, snapshot.has_legal_cell(Vector2i(0, 0)) == true, "Legal (0,0) 期望 true。")
	_check(G, snapshot.has_legal_cell(Vector2i(2, 0)) == false, "(2,0) 是 Terrain 但非 Legal，期望 false。")
	_check(G, snapshot.has_wall_cell(Vector2i(0, 0)) == true, "Wall (0,0) 期望 true。")
	_check(G, snapshot.has_decoration_cell(Vector2i(5, 5)) == true, "Decoration (5,5) 期望 true。")
	_check(G, snapshot.has_decoration_cell(Vector2i(0, 0)) == false, "(0,0) 不应是 Decoration。")


## 5. 边界：Terrain 格属于边界；外包矩形内空洞不属于边界；外包之外不属于边界。
func _test_05_boundary_terrain_and_hole(query: _LevelWorldQuery) -> void:
	const G: String = "05_边界Terrain格与外包空洞"
	if query == null:
		_check(G, false, "query 缺失，跳过本组。")
		return
	_check(G, query.is_in_bounds(Vector2i(0, 0)) == true, "Terrain (0,0) 应在边界内。")
	_check(G, query.is_in_bounds(Vector2i(2, 2)) == true, "Terrain (2,2) 应在边界内。")
	_check(G, query.is_in_bounds(Vector2i(1, 1)) == false, "外包矩形内空洞 (1,1) 应越界 false。")
	_check(G, query.is_in_bounds(Vector2i(3, 0)) == false, "外包之外 (3,0) 应越界 false。")


## 6. Legal 放置：Legal 内可放置；Terrain 内非 Legal 不可放置。
func _test_06_legal_placement(query: _LevelWorldQuery) -> void:
	const G: String = "06_Legal内可放置_Terrain内非Legal不可放置"
	if query == null:
		_check(G, false, "query 缺失，跳过本组。")
		return
	# Legal 内可放置：(2,2) Terrain+Legal+无墙+无占用。
	_check(G, query.is_legal_placement_cell(Vector2i(2, 2)) == true, "(2,2) 在 Legal 内期望 true。")
	_check(G, query.is_valid_placement_cell(Vector2i(2, 2)) == true, "(2,2) 综合判定期望可放置 true。")
	# Terrain 内非 Legal 不可放置：(2,0) Terrain 但无 Legal Tile。
	_check(G, query.is_legal_placement_cell(Vector2i(2, 0)) == false, "(2,0) Terrain 但非 Legal 期望 false。")
	_check(G, query.is_valid_placement_cell(Vector2i(2, 0)) == false, "(2,0) 综合判定期望 false。")


## 7. Wall 不可放置且 is_wall_cell=true。(0,0) 同时 Terrain+Legal，仅因墙不可放置，隔离墙为决定性阻挡。
func _test_07_wall_not_placeable(query: _LevelWorldQuery) -> void:
	const G: String = "07_Wall不可放置且is_wall_cell"
	if query == null:
		_check(G, false, "query 缺失，跳过本组。")
		return
	_check(G, query.is_wall_cell(Vector2i(0, 0)) == true, "Wall 格 (0,0) is_wall_cell 期望 true。")
	_check(G, query.is_legal_placement_cell(Vector2i(0, 0)) == true, "(0,0) 在 Legal 内（用于隔离墙阻挡）。")
	_check(G, query.is_valid_placement_cell(Vector2i(0, 0)) == false, "(0,0) Legal+Terrain 但被墙阻挡，期望不可放置 false。")
	_check(G, query.is_wall_cell(Vector2i(2, 2)) == false, "(2,2) 非 Wall（对照）期望 false。")


## 8. Decoration 独立性：仅装饰格 (5,5) 不入边界、不计墙、不授 Legal、不可放置；不改变任一事实。
func _test_08_decoration_inert(query: _LevelWorldQuery, snapshot: Object) -> void:
	const G: String = "08_Decoration不改变边界LegalWall事实"
	if query == null or snapshot == null:
		_check(G, false, "query/snapshot 缺失，跳过本组。")
		return
	# 快照层：仅装饰格 (5,5) 只出现在 Decoration 层。
	_check(G, snapshot.has_terrain_cell(Vector2i(5, 5)) == false, "Decoration 不入 Terrain 层。")
	_check(G, snapshot.has_legal_cell(Vector2i(5, 5)) == false, "Decoration 不入 Legal 层。")
	_check(G, snapshot.has_wall_cell(Vector2i(5, 5)) == false, "Decoration 不入 Wall 层。")
	_check(G, snapshot.has_decoration_cell(Vector2i(5, 5)) == true, "Decoration (5,5) 仅在 Decoration 层。")
	# 查询层：仅装饰格不扩展边界、不计墙、不授 Legal、不可放置。
	_check(G, query.is_in_bounds(Vector2i(5, 5)) == false, "Decoration 不扩展边界，(5,5) 期望越界 false。")
	_check(G, query.is_wall_cell(Vector2i(5, 5)) == false, "Decoration 不计墙，(5,5) 期望 false。")
	_check(G, query.is_legal_placement_cell(Vector2i(5, 5)) == false, "Decoration 不授 Legal，(5,5) 期望 false。")
	_check(G, query.is_valid_placement_cell(Vector2i(5, 5)) == false, "Decoration-only (5,5) 期望不可放置 false。")


## 9. 重新加载全新实例：正式模板原始四层仍为空，证明测试写入未写回资源（PackedScene/磁盘未变）。
func _test_09_reload_original_layers_empty() -> void:
	const G: String = "09_重新加载正式模板四层仍为空"
	var scene_b: PackedScene = load(_FORMAL_SCENE_PATH) as PackedScene
	_check(G, scene_b != null, "重新加载 level_template.tscn 失败。")
	var inst_b: Node2D = _safe_instance(scene_b)
	_check(G, inst_b != null, "重新实例化返回 null。")
	if inst_b == null:
		return
	var layers_b: Dictionary = _collect_direct_tilemap_layers(inst_b)
	for n: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		var layer: TileMapLayer = layers_b.get(n) as TileMapLayer
		if layer == null:
			_check(G, false, "%s 重新加载后缺失。" % n)
			continue
		var used: Array = layer.get_used_cells()
		_check(G, used.is_empty(), "%s 重新加载后应为空（证明未写回资源），实际 %d 格：%s。" % [n, used.size(), used])
	inst_b.free()


# ===== 机关节点只读查表桩 =====

## 供 LevelWorldQuery 的 get_placed_node_by_id Callable 解析 placed 字典的只读桩；不暴露可写引用，本测试不登记任何机关。
class _PlacedLookup:
	var placed: Dictionary = {}
	func get_node(mechanism_id: StringName) -> Variant:
		if not placed.has(mechanism_id):
			return null
		return placed[mechanism_id]
