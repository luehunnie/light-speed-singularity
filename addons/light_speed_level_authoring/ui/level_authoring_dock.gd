@tool
extends VBoxContainer

# AF-08 Level Authoring Dock（Guide §2.3 / §5 / §6 / §9 / §10.3 / §23 / §89）：
# 轻量级关卡内容辅助唯一 UI 入口——关卡工具（创建 / 复制 / 运行 / 校验）、Content Palette、
# Map Layer Assist、方向快捷旋转、Stable ID 修复。
# 边界：标准地图绘制仍用 Godot TileMap、对象移动仍用 Godot 2D、对象配置仍用 Inspector（本 Dock 不做编辑器替身）。
# 可测性：全部编辑器能力经 editor_bridge（duck-typed Object：open_scene / get_current_scene_path /
#   get_edited_level_root / play_current_level）注入，headless 测试注入替身即可驱动按钮路径；
#   撤销经 set_undo_redo 注入（UndoRedo / EditorUndoRedoManager 均可，见 EditorTransaction）。


const _LevelFileService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/level_file_service.gd"
)
const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _MapLayerService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/map_layer_service.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)
const _EditorTransaction: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_transaction.gd"
)
const _CreateLevelDialog: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/create_level_dialog.gd"
)
# 正式对象两类基脚本（PlaceableToken / GridPlacedObject 派生链）。
const _PlaceableTokenScript: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _GridPlacedObjectScript: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)

# 四层角色（与 LevelValidator 冻结角色一致）。
const _LAYER_ROLES: Array[String] = ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]

var _level_file_service: _LevelFileService
var _palette_service: _PaletteService
var _registry = null
var _undo_redo: Object = null
var _editor_bridge: Object = null
var _selected_formal_nodes: Array[Node] = []

var _log_output: RichTextLabel
var _palette_list: ItemList
var _palette_type_ids: Array[StringName] = []
var _rotate_button: Button
var _create_dialog: AcceptDialog
var _create_mode_is_duplicate := false
var _duplicate_source_path := ""


func _ready() -> void:
	_level_file_service = _LevelFileService.new()
	_palette_service = _PaletteService.new()
	_registry = _PaletteService.build_registry()
	_build_ui()
	_refresh_palette()


# ===== 注入面（插件接线 / headless 测试替身）=====

# 注入撤销管理器（UndoRedo 或 EditorUndoRedoManager；null = 直发无撤销模式）。
func set_undo_redo(undo_redo: Object) -> void:
	_undo_redo = undo_redo


# 注入编辑器桥（open_scene / get_current_scene_path / get_edited_level_root / play_current_level）。
func set_editor_bridge(bridge: Object) -> void:
	_editor_bridge = bridge


# 选择变化通知（插件 EditorSelection 转发；驱动方向旋转入口可用性）。
func notify_selection_changed(selected_nodes: Array) -> void:
	_selected_formal_nodes = []
	for entry: Variant in selected_nodes:
		if _matches_formal_scripts(entry):
			_selected_formal_nodes.append(entry as Node)
	_rotate_button.disabled = _selected_formal_nodes.is_empty()


# ===== UI 构建 =====

func _build_ui() -> void:
	add_child(_section("关卡工具"))
	var tools := HBoxContainer.new()
	tools.add_child(_button("新建关卡", _on_create_new_level))
	tools.add_child(_button("复制当前关卡", _on_duplicate_current_level))
	tools.add_child(_button("运行当前关卡", _on_play_current_level))
	tools.add_child(_button("校验当前关卡", _on_validate_current_level))
	add_child(tools)

	add_child(_section("正式内容 Palette"))
	_palette_list = ItemList.new()
	_palette_list.custom_minimum_size = Vector2(0, 110)
	add_child(_palette_list)
	var palette_row := HBoxContainer.new()
	palette_row.add_child(_button("刷新", _refresh_palette))
	palette_row.add_child(_button("放置到关卡", _on_place_selected))
	palette_row.add_child(_button("撤销一步", _on_undo))
	add_child(palette_row)

	add_child(_section("地图四层辅助"))
	var layer_row := HBoxContainer.new()
	for role: String in _LAYER_ROLES:
		layer_row.add_child(_button(role.replace("Layer", ""), _make_layer_mode_handler(role)))
	add_child(layer_row)
	var map_row := HBoxContainer.new()
	map_row.add_child(_button("初始化 LegalArea", _on_initialize_legal))
	map_row.add_child(_button("清理越界", _on_clean_outside))
	map_row.add_child(_button("清理 Wall∩Legal", _on_clean_wall_legal))
	add_child(map_row)

	add_child(_section("所选对象"))
	var select_row := HBoxContainer.new()
	_rotate_button = _button("旋转方向（R 同款字段）", _on_rotate_selected)
	_rotate_button.disabled = true
	select_row.add_child(_rotate_button)
	select_row.add_child(_button("修复 Stable ID", _on_repair_stable_ids))
	add_child(select_row)

	_log_output = RichTextLabel.new()
	_log_output.custom_minimum_size = Vector2(0, 90)
	_log_output.scroll_following = true
	add_child(_log_output)


func _section(title: String) -> Label:
	var label := Label.new()
	label.text = title
	label.modulate = Color(0.8, 0.85, 1.0)
	return label


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _make_layer_mode_handler(role: String) -> Callable:
	return func() -> void: _on_layer_mode(role)


func _log(message: String) -> void:
	_log_output.append_text("%s\n" % message)


# ===== 关卡工具 =====

func _on_create_new_level() -> void:
	_create_mode_is_duplicate = false
	_open_create_dialog("新建关卡")


func _on_duplicate_current_level() -> void:
	_duplicate_source_path = _bridge_call("get_current_scene_path")
	if _duplicate_source_path.is_empty():
		_log("复制当前关卡：当前没有已保存的关卡场景。")
		return
	_create_mode_is_duplicate = true
	_open_create_dialog("复制为新关卡")


func _open_create_dialog(title: String) -> void:
	if _create_dialog == null:
		_create_dialog = _CreateLevelDialog.new()
		_create_dialog.confirmed_level.connect(_on_create_dialog_confirmed)
		add_child(_create_dialog)
	_create_dialog.title = title
	_create_dialog.popup_centered()


func _on_create_dialog_confirmed(display_name: String, chapter: String) -> void:
	if display_name.is_empty():
		_log("显示名称为空，已取消。")
		return
	var result: Dictionary
	if _create_mode_is_duplicate:
		result = _level_file_service.duplicate_level(_duplicate_source_path, display_name, chapter)
	else:
		result = _level_file_service.create_new_level(display_name, chapter)
	if not result.ok:
		_log("失败：%s" % ", ".join(result.errors))
		return
	var issue_count: int = (result.issues as Array).size()
	_log("已生成 %s（level_id=%s，校验问题 %d 项）。" % [result.path, result.level_id, issue_count])
	_bridge_call_void("open_scene", [result.path])


func _on_play_current_level() -> void:
	var root := _edited_level_root()
	if root == null:
		_log("运行当前关卡：当前场景不是关卡（无关卡根）。")
		return
	var issues: Dictionary = _MapLayerService.collect_issues(root)
	if not issues.valid:
		_log("运行前校验未通过（%d 错误 / %d 警告）：%s" % [
			issues.errors, issues.warnings, "；".join(issues.first_messages)])
		return
	_log("Play Current Level：校验通过，交给 LevelRuntimeHost 运行。")
	_bridge_call_void("play_current_level")


func _on_validate_current_level() -> void:
	var root := _edited_level_root()
	if root == null:
		_log("校验当前关卡：当前场景不是关卡。")
		return
	var issues: Dictionary = _MapLayerService.collect_issues(root)
	_log("校验：%s（%d 错误 / %d 警告）%s" % [
		"通过" if issues.valid else "未通过", issues.errors, issues.warnings,
		"" if issues.valid else "：" + "；".join(issues.first_messages)])


# ===== Content Palette =====

func _refresh_palette() -> void:
	_palette_list.clear()
	_palette_type_ids = []
	if _registry == null:
		_registry = _PaletteService.build_registry()
		if _registry == null:
			_log("正式内容声明发现失败（见 Output 错误），Palette 不可用。")
			return
	for entry: Dictionary in _PaletteService.build_palette_entries(_registry):
		_palette_type_ids.append(entry.type_id)
		_palette_list.add_item("%s（%s）" % [entry.display_name, entry.category])


func _on_place_selected() -> void:
	var selected_indices := _palette_list.get_selected_items()
	if selected_indices.is_empty():
		_log("请先在 Palette 中选择一个正式类型。")
		return
	var root := _edited_level_root()
	if root == null:
		_log("放置失败：当前场景不是关卡（缺少关卡根）。")
		return
	var type_id: StringName = _palette_type_ids[selected_indices[0]]
	var result: Dictionary = _palette_service.place(_registry, type_id, root, false)
	if not result.ok:
		_log("放置失败：%s" % result.reason)
		return
	var placed: Node = result.node
	var container: Node = result.container
	var operations: Array = [{
		"target": container,
		"do": ["add_child", [placed]],
		"undo": ["remove_child", [placed]],
		"do_properties": [["owner", root]],
		"undo_properties": [["owner", null]],
	}]
	_EditorTransaction.commit(_undo_redo, "Palette 放置 %s" % type_id, operations)
	_log("已放置 %s 于 %s（稳定 ID %s）。" % [type_id, result.cell, result.stable_instance_id])


func _on_undo() -> void:
	if _undo_redo == null:
		_log("未注入撤销管理器。")
		return
	_undo_redo.undo()


# ===== Map Layer Assist =====

func _on_layer_mode(role: String) -> void:
	var root := _edited_level_root()
	if root == null:
		_log("请先打开一个关卡场景。")
		return
	for other: String in _LAYER_ROLES:
		var layer: TileMapLayer = _EditorPlacementQuery.find_layer(root, other)
		if layer == null:
			continue
		if other == role:
			layer.remove_meta("_edit_lock_")
		else:
			layer.set_meta("_edit_lock_", true)
	_log("当前层：%s（其余三层已锁定；点击层名解锁编辑，画 Tile 用底部图块页签）。" % role)


func _on_initialize_legal() -> void:
	var root := _edited_level_root()
	if root == null:
		_log("请先打开一个关卡场景。")
		return
	var legal: TileMapLayer = _EditorPlacementQuery.find_layer(root, "LegalAreaLayer")
	if legal == null:
		_log("缺少 LegalAreaLayer。")
		return
	var before: Dictionary = _MapLayerService.snapshot_layer(legal)
	var operations: Array = [{
		"target": self,
		"do": ["run_initialize_legal", [root]],
		"undo": ["restore_layer_state", [legal, before]],
	}]
	_EditorTransaction.commit(_undo_redo, "初始化 LegalArea", operations)


func _on_clean_outside() -> void:
	_clean_layers("legal_outside", "清理 LegalArea / Wall 越界")


func _on_clean_wall_legal() -> void:
	_clean_layers("wall_on_legal", "清理 Wall∩LegalArea 重叠")


# 清理事务：do 段执行清理并回填计数；undo 段按两层快照整体恢复。
func _clean_layers(mode: String, action_name: String) -> void:
	var root := _edited_level_root()
	if root == null:
		_log("请先打开一个关卡场景。")
		return
	var legal: TileMapLayer = _EditorPlacementQuery.find_layer(root, "LegalAreaLayer")
	var wall: TileMapLayer = _EditorPlacementQuery.find_layer(root, "WallLayer")
	if legal == null or wall == null:
		_log("缺少 LegalArea / Wall 层。")
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
	_EditorTransaction.commit(_undo_redo, action_name, operations)


# ===== 事务 do/undo 目标方法（Node 目标满足 Callable 引用保留）=====

func run_initialize_legal(root: Node2D) -> void:
	_log("初始化 LegalArea：补 %d 格。" % _MapLayerService.initialize_legal_from_terrain(root).size())


func run_clean(root: Node2D, mode: String) -> void:
	if mode == "legal_outside":
		_log("清理越界：LegalArea %d 格，Wall %d 格。" % [
			_MapLayerService.clean_legal_outside_terrain(root).size(),
			_MapLayerService.clean_wall_outside_terrain(root).size()])
	else:
		_log("清理 Wall∩LegalArea：移除 LegalArea %d 格（保留 Wall 事实）。" % [
			_MapLayerService.clean_legal_on_wall(root).size()])


func restore_layer_state(layer: TileMapLayer, snapshot: Dictionary) -> void:
	_MapLayerService.restore_layer(layer, snapshot)


func restore_layers_state(legal: TileMapLayer, wall: TileMapLayer, before: Dictionary) -> void:
	_MapLayerService.restore_layer(legal, before["legal"])
	_MapLayerService.restore_layer(wall, before["wall"])


# ===== 所选对象 =====

func _on_rotate_selected() -> void:
	if _selected_formal_nodes.is_empty():
		return
	var node: Node = _selected_formal_nodes[0]
	var method := ""
	var field := ""
	if node.has_method("cycle_direction"):
		method = "cycle_direction"
		field = "direction"
	elif node.has_method("toggle_orientation"):
		method = "toggle_orientation"
		field = "orientation"
	else:
		_log("所选对象不支持方向旋转（单方向 / 无方向机制自动禁用）。")
		return
	var old_value: Variant = node.get(field)
	var operations: Array = [{
		"target": node,
		"do": [method, []],
		"undo": ["set", [field, old_value]],
	}]
	_EditorTransaction.commit(_undo_redo, "旋转方向", operations)


func _on_repair_stable_ids() -> void:
	var root := _edited_level_root()
	if root == null:
		_log("请先打开一个关卡场景。")
		return
	var audit: Dictionary = _StableIdService.audit(root)
	var assigned: int = _StableIdService.assign_missing(root)
	var message := "Stable ID：共 %d 正式对象，补发 %d，重复 %d。" % [audit.total, assigned, audit.duplicates.size()]
	if not (audit.duplicates as Array).is_empty():
		message += "（重复 ID 需人工确认保留者：%s）" % ", ".join(audit.duplicates)
	_log(message)


# ===== 桥接小工具 =====

func _matches_formal_scripts(candidate: Variant) -> bool:
	# 正式对象 = PlaceableToken / GridPlacedObject（含 Crystal、Emitter 派生链）之一的 Node2D。
	if not (candidate is Node2D):
		return false
	var node: Node2D = candidate
	return node is _PlaceableTokenScript or node is _GridPlacedObjectScript


func _edited_level_root() -> Node2D:
	if _editor_bridge == null or not _editor_bridge.has_method("get_edited_level_root"):
		return null
	var root: Variant = _editor_bridge.call("get_edited_level_root")
	if root is Node2D:
		return root
	return null


func _bridge_call(method: String) -> String:
	if _editor_bridge == null or not _editor_bridge.has_method(method):
		return ""
	var value: Variant = _editor_bridge.call(method)
	return str(value) if value != null else ""


func _bridge_call_void(method: String, args: Array = []) -> void:
	if _editor_bridge != null and _editor_bridge.has_method(method):
		_editor_bridge.callv(method, args)
