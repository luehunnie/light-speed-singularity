@tool
extends VBoxContainer

# 地图四层辅助面板（Guide §5 / §10）：层模式锁定、LegalArea 初始化 / 越界与重叠清理。
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

const PANEL_KEY: String = "map_assist"

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
	# AF-09 GUI Gate：本面板只辅助编辑既有四层，不创建节点（Guide §2.3：地图绘制仍用 Godot TileMapLayer）。
	var hint := Label.new()
	hint.text = "本面板只辅助编辑已存在的四层，不创建场景树节点；层节点由「新建关卡」自动生成。"
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
