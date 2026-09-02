@tool
extends VBoxContainer

# 地图四层辅助面板（Guide §5 / §10）：层模式锁定、LegalArea 初始化 / 越界与重叠清理、
# 一键包裹全边界。D-04 起包裹输出为正式单格墙对象（WallBlock，经 PaletteService 定点放置 +
# EditorTransaction 入树，可整体选中/删除/撤销），不再是 WallLayer 匿名 tile 写入。
# D-03 的墙体作者 UI（12 样式网格 / 6 盖章按钮 / 单格涂刷 / 占位迁移 / 视口点击武装流）已删除：
# 墙体正式作者入口 = Content Palette 放置 + Inspector「墙体样式」。
# 事务 do/undo 目标方法挂本 Node（满足 Callable 引用保留）；快照恢复经 MapLayerService。


const _MapLayerService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/map_layer_service.gd"
)
const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)
const _EditorTransaction: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_transaction.gd"
)
const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _WallStyleCatalog: GDScript = preload(
	"res://gameplay/content/wall/wall_style_catalog.gd"
)

const PANEL_KEY: String = "map_assist"

# 包裹使用的正式内容类型（wall 域单格墙体定义；条目来自 FormalContentRegistry）。
const _WALL_BLOCK_TYPE_ID: StringName = &"wall_block"

# 四层角色（与 LevelValidator 冻结角色一致）。
const _LAYER_ROLES: Array[String] = ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]

var _ctx: Object = null


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "地图四层辅助"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	var layer_row := HBoxContainer.new()
	for role: String in _LAYER_ROLES:
		layer_row.add_child(_button(role.replace("Layer", ""), _make_layer_mode_handler(role)))
	add_child(layer_row)
	var map_row := HBoxContainer.new()
	map_row.add_child(_button("初始化 LegalArea", _on_initialize_legal))
	map_row.add_child(_button("清理越界", _on_clean_outside))
	map_row.add_child(_button("清理 Wall∩Legal", _on_clean_wall_legal))
	add_child(map_row)
	var wall_row := HBoxContainer.new()
	wall_row.add_child(_button("一键包裹全边界", _on_wrap_boundary))
	add_child(wall_row)
	var hint := Label.new()
	hint.text = "层绘制仍用 Godot TileMap 图块页签（本面板辅助锁定/清理）；墙体放置与逐格样式走 Content Palette + Inspector「墙体样式」，一键包裹输出为正式单格墙对象（可整体选中/删除/撤销）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint)


func refresh() -> void:
	pass


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _make_layer_mode_handler(role: String) -> Callable:
	return func() -> void: _on_layer_mode(role)


func _on_layer_mode(role: String) -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	for other: String in _LAYER_ROLES:
		var layer: TileMapLayer = _EditorPlacementQuery.find_layer(root, other)
		if layer == null:
			continue
		if other == role:
			layer.remove_meta("_edit_lock_")
		else:
			layer.set_meta("_edit_lock_", true)
	_ctx.log_message("当前层：%s（其余三层已锁定；点击层名解锁编辑，画 Tile 用底部图块页签）。" % role)


func _on_initialize_legal() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	var legal: TileMapLayer = _EditorPlacementQuery.find_layer(root, "LegalAreaLayer")
	if legal == null:
		_ctx.log_message("缺少 LegalAreaLayer。")
		return
	var before: Dictionary = _MapLayerService.snapshot_layer(legal)
	var operations: Array = [{
		"target": self,
		"do": ["run_initialize_legal", [root]],
		"undo": ["restore_layer_state", [legal, before]],
	}]
	_EditorTransaction.commit(_ctx._get_undo_redo(), "初始化 LegalArea", operations)


func _on_clean_outside() -> void:
	_clean_layers("legal_outside", "清理 LegalArea / Wall 越界")


func _on_clean_wall_legal() -> void:
	_clean_layers("wall_on_legal", "清理 Wall∩LegalArea 重叠")


# 清理事务：do 段执行清理并回填计数；undo 段按两层快照整体恢复。
func _clean_layers(mode: String, action_name: String) -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	var legal: TileMapLayer = _EditorPlacementQuery.find_layer(root, "LegalAreaLayer")
	var wall: TileMapLayer = _EditorPlacementQuery.find_layer(root, "WallLayer")
	if legal == null or wall == null:
		_ctx.log_message("缺少 LegalArea / Wall 层。")
		return
	var before := {
		"legal": _MapLayerService.snapshot_layer(legal),
		"wall": _MapLayerService.snapshot_layer(wall),
	}
	var operations: Array = [{
		"target": self,
		"do": ["run_clean", [root, mode]],
		"undo": ["restore_layers_state", [legal, wall, before]],
	}]
	_EditorTransaction.commit(_ctx._get_undo_redo(), action_name, operations)


# ===== 事务 do/undo 目标方法（Node 目标满足 Callable 引用保留）=====

func run_initialize_legal(root: Node2D) -> void:
	_ctx.log_message("初始化 LegalArea：补 %d 格。" % _MapLayerService.initialize_legal_from_terrain(root).size())


func run_clean(root: Node2D, mode: String) -> void:
	if mode == "legal_outside":
		_ctx.log_message("清理越界：LegalArea %d 格，Wall %d 格。" % [
			_MapLayerService.clean_legal_outside_terrain(root).size(),
			_MapLayerService.clean_wall_outside_terrain(root).size()])
	else:
		_ctx.log_message("清理 Wall∩LegalArea：移除 LegalArea %d 格（保留 Wall 事实）。" % [
			_MapLayerService.clean_legal_on_wall(root).size()])


func restore_layer_state(layer: TileMapLayer, snapshot: Dictionary) -> void:
	_MapLayerService.restore_layer(layer, snapshot)


func restore_layers_state(legal: TileMapLayer, wall: TileMapLayer, before: Dictionary) -> void:
	_MapLayerService.restore_layer(legal, before["legal"])
	_MapLayerService.restore_layer(wall, before["wall"])


# ===== D-04 一键包裹（输出正式墙体对象）=====

# 规划（MapLayerService.plan_wall_wrap）→ 逐格 PaletteService.place_wall_at（不入树、带样式）
# → 单个 EditorTransaction 提交全部 add_child+owner（一个操作=一个撤销步；undo=逐节点 remove_child）。
# 任一格放置失败即释放全部已建节点（零残留）；事务提交失败同样回滚。
func _on_wrap_boundary() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	var plan: Dictionary = _MapLayerService.plan_wall_wrap(root)
	if not bool(plan["ok"]):
		_log_rejection(plan["reasons"])
		return
	var cells: Array = plan["cells"]
	if cells.is_empty():
		_ctx.log_message("一键包裹：LegalArea 外侧相邻 Terrain 格为 0（无可包裹边界）。")
		return
	var registry: Object = _PaletteService.build_registry()
	if registry == null:
		_ctx.log_message("一键包裹：内容 Registry 构建失败（见错误输出），已取消。")
		return
	var palette: Object = _PaletteService.new()
	var container: Node2D = null
	var placed_nodes: Array[Node] = []
	var details: PackedStringArray = PackedStringArray()
	for entry: Variant in cells:
		var cell: Vector2i = (entry as Dictionary)["cell"]
		var result: Dictionary = palette.place_wall_at(
			registry, _WALL_BLOCK_TYPE_ID, root, cell, false)
		if not bool(result["ok"]):
			_free_all(placed_nodes)
			_ctx.log_message("一键包裹在格 %s 失败：%s（已回滚全部已建节点）。" % [cell, result["reason"]])
			return
		var node: Node = result["node"]
		# 包裹规划的样式 token → Inspector 墙体样式枚举序（视觉与 D-03 冻结边界口径一致）。
		node.set("wall_style", _WallStyleCatalog.index_of((entry as Dictionary)["style"]))
		container = result["container"]
		placed_nodes.append(node)
		details.append("%s=%s" % [cell, (entry as Dictionary)["style"]])
	var operations: Array = []
	for node: Node in placed_nodes:
		operations.append({
			"target": container,
			"do": ["add_child", [node]],
			"undo": ["remove_child", [node]],
		})
		operations.append({
			"target": node,
			"do_properties": [["owner", root]],
		})
	var action_name: String = "一键包裹全边界（正式墙体 ×%d）" % placed_nodes.size()
	if _EditorTransaction.commit(_ctx._get_undo_redo(), action_name, operations, root):
		_ctx.log_message("%s：%s。" % [action_name, "；".join(details)])
	else:
		_free_all(placed_nodes)
		_ctx.log_message("一键包裹事务提交失败（见错误输出），已回滚全部已建节点。")


# 释放全部已建节点（失败回滚路径；节点未入树故 free 即时生效、零残留）。
func _free_all(nodes: Array[Node]) -> void:
	for node: Node in nodes:
		node.free()


func _log_rejection(reasons: PackedStringArray) -> void:
	for reason: Variant in reasons:
		_ctx.log_message(str(reason))
	_ctx.log_message("整次操作已拒绝（零部分写入）。")
