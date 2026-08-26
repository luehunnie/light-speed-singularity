@tool
extends VBoxContainer

# 关卡工具面板（Guide §5/§6/§89）：创建 / 复制 / 运行 / 校验。业务全在 LevelFileService /
# MapLayerService 服务内；本面板只做按钮与对话框接线。


const _LevelFileService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/level_file_service.gd"
)
const _MapLayerService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/map_layer_service.gd"
)
const _CreateLevelDialog: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/create_level_dialog.gd"
)

const PANEL_KEY: String = "level_tools"

var _ctx: Object = null
var _create_dialog: AcceptDialog = null
var _create_mode_is_duplicate := false
var _duplicate_source_path := ""


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "关卡工具"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	var row := HBoxContainer.new()
	row.add_child(_button("新建关卡", _on_create_new_level))
	row.add_child(_button("复制当前关卡", _on_duplicate_current_level))
	row.add_child(_button("运行当前关卡", _on_play_current_level))
	row.add_child(_button("校验当前关卡", _on_validate_current_level))
	add_child(row)
	# AF-09 GUI Gate：消除“是否要手动建场景树节点”误解（Guide §5：Create 自动生成完整结构）。
	var hint := Label.new()
	hint.text = "「新建关卡」自动生成完整场景树（四层 / RuntimeObjects / LightPathLayer / Emitter+Crystal），无需手动创建节点。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint)


func refresh() -> void:
	pass


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _on_create_new_level() -> void:
	_create_mode_is_duplicate = false
	_open_create_dialog("新建关卡")


func _on_duplicate_current_level() -> void:
	if _ctx.edited_root() == null:
		_ctx.log_message("复制当前关卡：当前没有已保存的关卡场景。")
		return
	_duplicate_source_path = _ctx._bridge_scene_path()
	if _duplicate_source_path.is_empty():
		_ctx.log_message("复制当前关卡：当前没有已保存的关卡场景。")
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
		_ctx.log_message("显示名称为空，已取消。")
		return
	var result: Dictionary
	if _create_mode_is_duplicate:
		result = _LevelFileService.duplicate_level(_duplicate_source_path, display_name, chapter)
	else:
		result = _LevelFileService.create_new_level(display_name, chapter)
	if not result.ok:
		_ctx.log_message("失败：%s" % ", ".join(result.errors))
		return
	var issue_count: int = (result.issues as Array).size()
	_ctx.log_message("已生成 %s（level_id=%s，校验问题 %d 项）。" % [result.path, result.level_id, issue_count])
	_ctx._bridge_open_scene(result.path)


func _on_play_current_level() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("运行当前关卡：当前场景不是关卡（无关卡根）。")
		return
	var issues: Dictionary = _MapLayerService.collect_issues(root)
	if not issues.valid:
		_ctx.log_message("运行前校验未通过（%d 错误 / %d 警告）：%s" % [
			issues.errors, issues.warnings, "；".join(issues.first_messages)])
		return
	_ctx.log_message("Play Current Level：校验通过，交给 LevelRuntimeHost 运行。")
	_ctx._bridge_play_current_level()


func _on_validate_current_level() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("校验当前关卡：当前场景不是关卡。")
		return
	var issues: Dictionary = _MapLayerService.collect_issues(root)
	_ctx.log_message("校验：%s（%d 错误 / %d 警告）%s" % [
		"通过" if issues.valid else "未通过", issues.errors, issues.warnings,
		"" if issues.valid else "：" + "；".join(issues.first_messages)])
