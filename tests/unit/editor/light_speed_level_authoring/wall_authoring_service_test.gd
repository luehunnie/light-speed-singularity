extends SceneTree

# D-04 墙体作者测试（纠正 D-03 被否决 UX 后的编辑器侧合同）：
# 12 样式目录冻结（catalog token/标签/素材路径）、Palette 正式 4 条目与 wall 域、
# Palette 墙体放置（wall 分支首格扫描 / 多格锚点 / 定点放置合法性规则）、
# 一键包裹全链（面板事务产出正式墙对象 + Undo/Redo + 二次包裹拒绝）、
# core_loop 场景迁移契约（WallLayer 清空 / WallBlock(5,3) / 快照单真值）、
# 运行墙真值合并（WallLayer 旧格 + 墙对象 footprint 并入同一快照事实）。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _MapLayerService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/map_layer_service.gd"
)
const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _WallStyleCatalog: GDScript = preload(
	"res://gameplay/content/wall/wall_style_catalog.gd"
)
const _LevelTileLayerSnapshot: GDScript = preload(
	"res://gameplay/world/level_tile_layer_snapshot.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _MapAssistPanel: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/panels/map_assist_panel.gd"
)
const _CoreLoopScene: PackedScene = preload(
	"res://levels/prototypes/core_loop_prototype.tscn"
)

# 冻结样式 token 序（四直 → 四外角 → 四内角；与 Inspector 墙体样式枚举值序一致）。
const _FROZEN_TOKENS: Array[String] = [
	"straight_up", "straight_down", "straight_left", "straight_right",
	"large_bend_lu", "large_bend_ru", "large_bend_ld", "large_bend_rd",
	"small_bend_tl", "small_bend_tr", "small_bend_bl", "small_bend_br",
]

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_catalog_and_palette_entries()
	_test_02_palette_wall_place_rules()
	_test_03_place_wall_at_rejections()
	await _test_04_wrap_panel_full_chain()
	_test_05_real_scene_migration_contract()
	_test_06_runtime_wall_truth_merge()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 1. 样式目录冻结 + Palette 正式 4 条目 =====

func _test_01_catalog_and_palette_entries() -> void:
	const NAME: String = "01_目录与Palette条目"
	_check(NAME, _WallStyleCatalog.STYLE_ORDER == _FROZEN_TOKENS, "STYLE_ORDER 应冻结为 12 token 序。")
	for i: int in _FROZEN_TOKENS.size():
		var token: String = _FROZEN_TOKENS[i]
		_check(NAME, not str(_WallStyleCatalog.STYLE_LABELS[token]).is_empty(), "%s 应有中文标签。" % token)
		var path: String = _WallStyleCatalog.STYLE_TEXTURE_PATHS[token]
		_check(NAME, ResourceLoader.exists(path), "%s 贴图资源应存在：%s。" % [token, path])
		_check(NAME, _WallStyleCatalog.index_of(token) == i and _WallStyleCatalog.token_at(i) == token,
			"%s token↔序号应互查一致。" % token)
	var registry: Object = _PaletteService.build_registry()
	_check(NAME, registry != null, "正式内容 Registry 应构建成功（wall 定义合法）。")
	if registry == null:
		return
	var wall_entries: Array[Dictionary] = []
	for entry: Dictionary in _PaletteService.build_palette_entries(registry):
		if entry["domain"] == StringName(&"wall"):
			wall_entries.append(entry)
	_check(NAME, wall_entries.size() == 4, "Palette wall 域应恰 4 条目，实际 %d。" % wall_entries.size())
	var by_id: Dictionary = {}
	for entry: Dictionary in wall_entries:
		by_id[entry["type_id"]] = entry
		_check(NAME, entry["category"] == StringName(&"wall"), "%s 分组应为 wall。" % entry["type_id"])
	var expected_ids: Dictionary = {
		&"wall_block": "单格墙体",
		&"wall_straight_h": "三格横墙",
		&"wall_straight_v": "三格竖墙",
		&"wall_corner_l": "三格L墙",
	}
	for id: Variant in expected_ids:
		_check(NAME, by_id.has(id), "Palette 应含条目 %s。" % id)
		if by_id.has(id):
			_check(NAME, str(by_id[id]["display_name"]) == expected_ids[id],
				"%s 显示名应为 %s，实际 %s。" % [id, expected_ids[id], by_id[id]["display_name"]])
		var definition: Object = registry.get_definition(id)
		_check(NAME, definition != null and definition.preplaceable, "%s 应可预放置。" % id)
	_check(NAME, _offsets_of(registry, &"wall_straight_h") ==
		[Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)], "三格横墙 footprint 应为 ±x 三格。")
	_check(NAME, _offsets_of(registry, &"wall_straight_v") ==
		[Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)], "三格竖墙 footprint 应为 ±y 三格。")
	_check(NAME, _offsets_of(registry, &"wall_corner_l") ==
		[Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)], "三格L墙 footprint 应为拐角+右+下（ES 默认）。")
	_check(NAME, _offsets_of(registry, &"wall_block") == [Vector2i.ZERO], "单格墙 footprint 应为单格。")


# ===== 2. Palette 放置：wall 分支首格扫描（不要求 LegalArea）与多格锚点 =====

func _test_02_palette_wall_place_rules() -> void:
	const NAME: String = "02_Palette墙体放置"
	var registry: Object = _PaletteService.build_registry()
	var root := _make_level(_rect_cells(0, 0, 5, 5), [])
	var palette: Object = _PaletteService.new()
	# wall 分支：无 LegalArea 也可放置（专用合法性规则），首个合法空格 (0,0)；add_to_tree=false 不入树。
	var result: Dictionary = palette.place(registry, &"wall_block", root, false)
	_check(NAME, bool(result["ok"]), "空地放置单格墙应成功（无 LegalArea 亦合法）。")
	_check(NAME, result["cell"] == Vector2i(0, 0), "首格扫描应取 (0,0)，实际 %s。" % str(result["cell"]))
	_check(NAME, not (result["node"] as Node).is_inside_tree(), "add_to_tree=false 时节点不入树（编辑事务提交）。")
	_check(NAME, str(result["stable_instance_id"]).begins_with("fci_"), "应分配稳定实例 ID。")
	_check(NAME, result["container"] == root.get_node("RuntimeObjects"), "容器应为 RuntimeObjects 正式角色。")
	var block: Node = result["node"]
	_check(NAME, block.has_method("get_wall_cells") and block.call("get_wall_cells") == [Vector2i(0, 0)],
		"单格墙占格应为锚格自身。")
	# 多格锚点：横墙锚点须整体入界 → 首格右移一位；竖墙锚点须整体入界 → 首格下移一行。
	var h: Dictionary = palette.place(registry, &"wall_straight_h", root, false)
	_check(NAME, bool(h["ok"]) and h["cell"] == Vector2i(1, 0), "横墙首锚应为 (1,0)（左臂入界）。")
	var v: Dictionary = palette.place(registry, &"wall_straight_v", root, false)
	_check(NAME, bool(v["ok"]) and v["cell"] == Vector2i(0, 1), "竖墙首锚应为 (0,1)（上臂入界）。")
	(h["node"] as Node).free()
	(v["node"] as Node).free()
	# 正式入树后占用生效：下一次单格墙首格扫描跳过 (0,0)。
	block.set("position", _GridCoordinateRules.cell_to_world(Vector2i(0, 0)))
	root.get_node("RuntimeObjects").add_child(block)
	block.owner = root
	var again: Dictionary = palette.place(registry, &"wall_block", root, false)
	_check(NAME, bool(again["ok"]) and again["cell"] == Vector2i(1, 0),
		"已占用格应被跳过（对象占用进合法性）。")
	(again["node"] as Node).free()
	block.free()
	root.free()


# ===== 3. 定点放置（place_wall_at）：合法性规则四分支 =====

func _test_03_place_wall_at_rejections() -> void:
	const NAME: String = "03_定点放置规则"
	var registry: Object = _PaletteService.build_registry()
	var root := _make_level(_rect_cells(0, 0, 5, 5), _rect_cells(0, 0, 5, 5))
	root.get_node("WallLayer").set_cell(Vector2i(2, 2), 0, Vector2i.ZERO)
	var palette: Object = _PaletteService.new()
	# 全图 LegalArea：墙对象允许与 LegalArea 同格（Validator 警告级，与迁移保留的 (5,3) 口径一致）。
	# add_to_tree=true 入 RuntimeObjects，后续用例以该占用验证对象占格拒绝。
	var on_legal: Dictionary = palette.place_wall_at(registry, &"wall_block", root, Vector2i(0, 0), true)
	_check(NAME, bool(on_legal["ok"]), "LegalArea 格应允许放置墙对象。")
	# WallLayer 旧墙格：拒绝（旧墙兼容输入，不重叠成双真值）。
	var on_wall: Dictionary = palette.place_wall_at(registry, &"wall_block", root, Vector2i(2, 2), false)
	_check(NAME, not bool(on_wall["ok"]) and str(on_wall["reason"]).contains("WallLayer"),
		"WallLayer 旧墙格应拒绝，实际 %s。" % on_wall["reason"])
	# 对象占用格：拒绝。
	var on_object: Dictionary = palette.place_wall_at(registry, &"wall_block", root, Vector2i(0, 0), false)
	_check(NAME, not bool(on_object["ok"]) and str(on_object["reason"]).contains("占用"),
		"已占用格应拒绝，实际 %s。" % on_object["reason"])
	# Terrain 外：拒绝。
	var outside: Dictionary = palette.place_wall_at(registry, &"wall_block", root, Vector2i(9, 9), false)
	_check(NAME, not bool(outside["ok"]), "Terrain 外应拒绝。")
	# 非墙域类型：拒绝走墙体定点入口。
	var not_wall: Dictionary = palette.place_wall_at(registry, &"basic_single_cell_mirror", root, Vector2i(4, 4), false)
	_check(NAME, not bool(not_wall["ok"]) and str(not_wall["reason"]).contains("非墙体域"),
		"非墙域类型应拒绝定点墙体放置。")
	root.free()


# ===== 4. 一键包裹全链：正式墙对象 + Undo/Redo + 二次包裹拒绝 =====

func _test_04_wrap_panel_full_chain() -> void:
	const NAME: String = "04_包裹面板全链"
	var root := _make_level(_rect_cells(0, 0, 5, 5), _rect_cells(2, 2, 3, 3))
	var ctx := _PanelContext.new()
	ctx.root = root
	var undo: UndoRedo = UndoRedo.new()
	ctx.undo = undo
	var panel: Control = _MapAssistPanel.new()
	panel.setup(ctx)
	panel.call("_on_wrap_boundary")
	var runtime: Node2D = root.get_node("RuntimeObjects")
	var walls: Array[Node] = _wall_nodes_of(runtime)
	_check(NAME, walls.size() == 8, "2×2 LegalArea 包裹应产出 8 个正式墙对象，实际 %d。" % walls.size())
	var cells: Dictionary = {}
	for node: Node in walls:
		cells[_cells_key(node.call("get_wall_cells"))] = node
		_check(NAME, node.owner == root, "墙对象 owner 应为关卡根（场景保存归属）。")
	_check(NAME, cells.size() == 8, "8 墙对象占格应互不重复（多格原子占用）。")
	# 样式 token → Inspector 枚举序写回（直墙·下=1 / 直墙·右=3）。
	var top: Node = _wall_at(runtime, Vector2i(2, 1))
	_check(NAME, top != null and int(top.get("wall_style")) == _WallStyleCatalog.index_of("straight_down"),
		"(2,1) 包裹墙样式应为直墙·下。")
	var left: Node = _wall_at(runtime, Vector2i(1, 2))
	_check(NAME, left != null and int(left.get("wall_style")) == _WallStyleCatalog.index_of("straight_right"),
		"(1,2) 包裹墙样式应为直墙·右。")
	# 入树后视觉就位：贴图按样式目录解析（视觉/阻挡同位置）。
	# headless --script 下 _initialize 不泵帧、_ready 不触发：add_child 后 await 一帧（repo 既有约定）。
	get_root().add_child(root)
	await process_frame
	var top_ready: Node = _wall_at(runtime, Vector2i(2, 1))
	_check(NAME, top_ready.is_node_ready() and (top_ready.get("_wall_sprite") as Sprite2D).texture != null,
		"包裹墙入树后应就绪并持有贴图。")
	_check(NAME, ((top_ready.get("_wall_sprite") as Sprite2D).texture as Resource).resource_path
		== _WallStyleCatalog.texture_path_at(int(top_ready.get("wall_style"))),
		"包裹墙贴图路径应与样式目录一致。")
	# Undo/Redo：一个操作=一个撤销步（整体移除/恢复）。
	undo.undo()
	_check(NAME, _wall_nodes_of(runtime).is_empty(), "Undo 应整体移除包裹墙对象。")
	undo.redo()
	_check(NAME, _wall_nodes_of(runtime).size() == 8, "Redo 应整体恢复包裹墙对象。")
	# 二次包裹：候选格已被墙对象占用 → 整次拒绝（零部分写入）。
	panel.call("_on_wrap_boundary")
	_check(NAME, _contains(ctx.logs, "拒绝"), "二次包裹应因对象占用被拒绝并提示。")
	_check(NAME, _wall_nodes_of(runtime).size() == 8, "拒绝后不得新增墙对象。")
	get_root().remove_child(root)
	root.free()
	panel.free()
	undo.free()


# ===== 5. 当前 core_loop 场景迁移契约 =====

func _test_05_real_scene_migration_contract() -> void:
	const NAME: String = "05_场景迁移契约"
	var root: Node2D = _CoreLoopScene.instantiate() as Node2D
	var wall_layer: TileMapLayer = root.get_node("WallLayer")
	_check(NAME, wall_layer != null, "旧 WallLayer 层应保留（兼容输入）。")
	_check(NAME, wall_layer.get_used_cells().is_empty(), "旧 WallLayer 应零墙格（无双真值）。")
	var runtime: Node2D = root.get_node("RuntimeObjects")
	var walls: Array[Node] = _wall_nodes_of(runtime)
	_check(NAME, walls.size() == 1, "RuntimeObjects 应恰 1 个正式墙对象，实际 %d。" % walls.size())
	if walls.is_empty():
		root.free()
		return
	var block: Node = walls[0]
	_check(NAME, block.get("position") == _GridCoordinateRules.cell_to_world(Vector2i(5, 3)),
		"迁移墙应保持 (5,3) 位置，实际 %s。" % str(block.get("position")))
	_check(NAME, str(block.get("stable_instance_id")) == "fci_0000002", "迁移墙应持稳定实例 ID。")
	_check(NAME, int(block.get("wall_style")) == _WallStyleCatalog.index_of("straight_up"),
		"迁移墙应默认直墙·上（匹配现有直墙素材）。")
	# D-05 Git Gate：Human 未提交残留（move_limit/emitter_rules）不随本提交走，
	# 残留存在性断言属工作区事实而非提交事实，已从提交边界移除。
	var legal: TileMapLayer = root.get_node("LegalAreaLayer")
	_check(NAME, legal.get_cell_source_id(Vector2i(1, 5)) != -1, "(1,5) 应仍为 LegalArea（既有断言前提）。")
	# 墙格单真值：节点 footprint 是唯一墙事实来源。
	var cells: Array[Vector2i] = _WallStyleCatalog.collect_wall_cells(root)
	cells.sort()
	_check(NAME, cells == [Vector2i(5, 3)], "collect_wall_cells 应恰 (5,3)，实际 %s。" % str(cells))
	root.free()


# ===== 6. 运行墙真值合并：WallLayer 旧格 + 墙对象 footprint 同一快照事实 =====

func _test_06_runtime_wall_truth_merge() -> void:
	const NAME: String = "06_运行墙真值合并"
	var root: Node2D = _CoreLoopScene.instantiate() as Node2D
	# 仅 WallLayer（现已空）的快照：无墙格。
	var layer_only: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(
		root.get_node("TerrainLayer"), root.get_node("WallLayer"),
		root.get_node("LegalAreaLayer"), root.get_node("DecorationLayer"))
	_check(NAME, layer_only.get_wall_cells_copy().is_empty(), "WallLayer 已空时快照应无墙格。")
	# 合并墙对象 footprint 后：(5,3) 成为墙事实（is_wall_cell 单一真值，Ray/Particle 同源消费）。
	var merged: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(
		root.get_node("TerrainLayer"), root.get_node("WallLayer"),
		root.get_node("LegalAreaLayer"), root.get_node("DecorationLayer"),
		_WallStyleCatalog.collect_wall_cells(root))
	_check(NAME, merged.has_wall_cell(Vector2i(5, 3)), "合并快照应以墙对象 footprint 为墙事实。")
	_check(NAME, not merged.has_wall_cell(Vector2i(1, 5)), "非墙格 (1,5) 应不为墙。")
	root.free()
	# 兼容混合：旧 WallLayer 格与正式墙对象并存时同一快照双来源合一。
	var fixture := _make_level(_rect_cells(0, 0, 5, 5), [])
	fixture.get_node("WallLayer").set_cell(Vector2i(2, 2), 0, Vector2i.ZERO)
	var registry: Object = _PaletteService.build_registry()
	var placed: Dictionary = _PaletteService.new().place_wall_at(
		registry, &"wall_block", fixture, Vector2i(4, 4), true)
	_check(NAME, bool(placed["ok"]), "混合 fixture 放置应成功。")
	var mixed: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(
		fixture.get_node("TerrainLayer"), fixture.get_node("WallLayer"),
		fixture.get_node("LegalAreaLayer"), fixture.get_node("DecorationLayer"),
		_WallStyleCatalog.collect_wall_cells(fixture))
	_check(NAME, mixed.has_wall_cell(Vector2i(2, 2)) and mixed.has_wall_cell(Vector2i(4, 4)),
		"旧墙格与新墙对象占格应并入同一墙事实。")
	_check(NAME, mixed.get_wall_cells_copy().size() == 2, "合并后应恰 2 墙格（无双真值重复）。")
	fixture.free()


# ===== fixture 与断言辅助 =====

class _PanelContext:
	var root: Node2D = null
	var undo: Object = null
	var logs: PackedStringArray = PackedStringArray()
	func edited_root() -> Node2D:
		return root
	func log_message(message: String) -> void:
		logs.append(message)
	func _get_undo_redo() -> Object:
		return undo


func _offsets_of(registry: Object, type_id: StringName) -> Array:
	return registry.get_definition(type_id).static_footprint_offsets


func _wall_nodes_of(container: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in container.get_children():
		if child.has_method("get_wall_cells"):
			out.append(child)
	return out


func _wall_at(container: Node, cell: Vector2i) -> Node:
	for node: Node in _wall_nodes_of(container):
		if (node.call("get_wall_cells") as Array)[0] == cell:
			return node
	return null


func _cells_key(cells: Array) -> String:
	var parts: Array[String] = []
	for cell: Variant in cells:
		parts.append(str(cell))
	parts.sort()
	return "[" + ",".join(parts) + "]"


func _contains(logs: PackedStringArray, needle: String) -> bool:
	for message: Variant in logs:
		if str(message).contains(needle):
			return true
	return false


## 最小关卡根：Terrain/Legal/Decoration 用无纹理 min TileSet，WallLayer 绑真实 wall_tileset，
## 含 RuntimeObjects 正式角色（Palette 放置容器）。
func _make_level(terrain_cells: Array, legal_cells: Array) -> Node2D:
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	var terrain: TileMapLayer = _make_layer()
	terrain.name = &"TerrainLayer"
	for cell: Variant in terrain_cells:
		terrain.set_cell(cell, 0, Vector2i.ZERO)
	root.add_child(terrain)
	var wall: TileMapLayer = TileMapLayer.new()
	wall.name = &"WallLayer"
	wall.tile_set = load("res://assets/art/tilesets/wall_tileset.tres")
	root.add_child(wall)
	var legal: TileMapLayer = _make_layer()
	legal.name = &"LegalAreaLayer"
	for cell: Variant in legal_cells:
		legal.set_cell(cell, 0, Vector2i.ZERO)
	root.add_child(legal)
	var deco: TileMapLayer = _make_layer()
	deco.name = &"DecorationLayer"
	root.add_child(deco)
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	return root


## 无纹理 min TileSet 层（atlas source 0 存在即可记录格）。
func _make_layer() -> TileMapLayer:
	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	ts.add_source(source)
	var layer: TileMapLayer = TileMapLayer.new()
	layer.tile_set = ts
	return layer


func _rect_cells(x0: int, y0: int, x1: int, y1: int) -> Array:
	var cells: Array = []
	for x: int in range(x0, x1 + 1):
		for y: int in range(y0, y1 + 1):
			cells.append(Vector2i(x, y))
	return cells


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("wall_authoring_service_test: %d checks, %d failures" % [_checks, _failures.size()])
