@tool
class_name LightSpeedArtProfileProfileActionPanel
extends VBoxContainer

## 美术 Profile 操作子面板（D4.5-C1-Fix）：状态选择 + 应用替换 + 保存确认。
## 职责：枚举 Profile 状态供用户选择、评估并执行“应用到当前状态”（经 EditService + UndoRedo）、
##       二次确认后保存 Profile（经 SaveService）；提供替换步骤与单击/保存语义说明。
## 输入输出：由 Dock 注入 active visual 与浏览器素材提供器；用户交互产生替换 / 保存；无返回值。
## 副作用：替换通过 EditorUndoRedoManager 走正式 Undo/Redo；保存通过 ProfileSaveService 写盘；
##         仅重建自身控件，不直接改写 Profile 字段、不扫描素材。
## 边界：不暴露内部数组 / 控件；不静默选中第一项；切换目标清空旧状态选择；
##       单击素材仅选择预览，不在此处替换；真正替换只经“应用到当前状态” + UndoRedo。

const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _SaveServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/profile_save_service.gd"
)

const _ART_ROOT_PREFIX: String = "res://assets/art/"

var _edit_service: RefCounted = _EditServiceScript.new()
var _save_service: RefCounted = _SaveServiceScript.new()

# Dock 注入：返回浏览器当前选中 ArtAssetEntry 或 null；只读，不暴露内部数组。
var _browser_entry_provider: Callable = Callable()

var _steps_hint: Label = null
var _states_title: Label = null
var _states_box: VBoxContainer = null
var _state_list: ItemList = null
var _info_title: Label = null
var _current_state_info: Label = null
var _current_state_preview: TextureRect = null
var _apply_button: Button = null
var _apply_hint: Label = null
var _save_hint: Label = null
var _shared_hint: Label = null
var _save_button: Button = null
var _save_confirm: Label = null
var _confirm_save_button: Button = null
var _cancel_save_button: Button = null
var _operation_status: Label = null

# 当前激活的正式视觉目标；未确定时为 null。
var _active_visual: ObjectVisualView = null
# 用户在状态列表中明确选择的状态 ID；未选择时为空 StringName。
var _selected_state_id: StringName = &""
# Dock 注入的真实编辑器 UndoRedo 管理器；未注入时为 null，应用按钮会明确报失败而非静默无效。
var _editor_undo_redo = null
# 当前已连接 changed 信号的 Profile；切换目标 / 清空时断开旧连接，避免泄漏或重复连接。
var _watched_profile: ObjectVisualProfile = null


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 Dock 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。无参数无返回；仅在控件缺失时创建子节点。
func _ensure_ui() -> void:
	if _states_box != null and is_instance_valid(_states_box):
		return
	add_theme_constant_override("separation", 6)
	# 替换步骤引导：明确“选择状态 → 选择素材 → 应用 → 保存”的完整流程，避免误以为单击/双击即替换。
	_steps_hint = Label.new()
	_steps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_steps_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
	_steps_hint.text = "替换步骤：\n1. 选择视觉状态；\n2. 在下方选择美术素材；\n3. 点击\"应用到当前状态\"；\n4. 确认效果后保存视觉配置。"
	add_child(_steps_hint)
	_states_title = Label.new()
	_states_title.text = "视觉状态（选择一个状态以替换图片）"
	add_child(_states_title)
	# 状态列表容器：_show_states 在其中创建 ItemList；独立容器便于清空重建。
	_states_box = VBoxContainer.new()
	_states_box.add_theme_constant_override("separation", 6)
	add_child(_states_box)
	_info_title = Label.new()
	_info_title.text = "当前状态纹理"
	add_child(_info_title)
	_current_state_info = Label.new()
	_current_state_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_current_state_info.text = "未选择状态。"
	add_child(_current_state_info)
	_current_state_preview = TextureRect.new()
	_current_state_preview.custom_minimum_size = Vector2(0, 64)
	_current_state_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_current_state_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_current_state_preview)
	# 应用按钮紧跟状态选择与当前纹理信息，便于用户在看到目标纹理后立即应用。
	_apply_button = Button.new()
	_apply_button.text = "应用到当前状态"
	_apply_button.disabled = true
	_apply_button.pressed.connect(Callable(self, "_on_apply_pressed"))
	add_child(_apply_button)
	_apply_hint = Label.new()
	_apply_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_apply_hint)
	# 保存语义说明：明确保存只写已应用修改，不代替“应用到当前状态”。
	_save_hint = Label.new()
	_save_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_save_hint.text = "保存只会写入已经应用的修改，不能代替\"应用到当前状态\"。"
	add_child(_save_hint)
	_shared_hint = Label.new()
	_shared_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shared_hint.add_theme_color_override("font_color", Color(0.85, 0.8, 0.55))
	add_child(_shared_hint)
	_save_button = Button.new()
	_save_button.text = "保存视觉配置"
	_save_button.pressed.connect(Callable(self, "_on_save_pressed"))
	add_child(_save_button)
	_save_confirm = Label.new()
	_save_confirm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_confirm.visible = false
	add_child(_save_confirm)
	var confirm_box := HBoxContainer.new()
	confirm_box.add_theme_constant_override("separation", 8)
	_confirm_save_button = Button.new()
	_confirm_save_button.text = "确认保存"
	_confirm_save_button.visible = false
	_confirm_save_button.pressed.connect(Callable(self, "_on_confirm_save_pressed"))
	confirm_box.add_child(_confirm_save_button)
	_cancel_save_button = Button.new()
	_cancel_save_button.text = "取消"
	_cancel_save_button.visible = false
	_cancel_save_button.pressed.connect(Callable(self, "_on_cancel_save_pressed"))
	confirm_box.add_child(_cancel_save_button)
	add_child(confirm_box)
	_operation_status = Label.new()
	_operation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_operation_status)


## Dock 注入浏览器素材提供器；cb 无参数，返回 ArtAssetEntry 或 null。无返回值。
func set_browser_entry_provider(cb: Callable) -> void:
	_browser_entry_provider = cb


## Dock 注入真实编辑器 UndoRedo 管理器；应用替换时使用，不在面板内自行查找编辑器单例。
## undo_redo 为 EditorPlugin.get_undo_redo() 返回值；传入 null 表示清空引用，应用按钮会明确报失败。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo


## 只读边界：返回当前激活视觉目标；未选择或失效返回 null。
func get_active_visual_target() -> ObjectVisualView:
	if _active_visual == null or not is_instance_valid(_active_visual):
		return null
	return _active_visual


## 只读边界：返回用户明确选择的状态 ID；未选择返回空 StringName。
func get_selected_state_id() -> StringName:
	return _selected_state_id


## 仅清空状态选择（保留 active visual）；切换视觉目标时由 Dock 调用，避免旧 state_id 误用。
func clear_state_selection() -> void:
	_selected_state_id = &""
	_refresh_apply_controls()


## 清空全部操作状态：active visual、状态选择、应用 / 保存确认 UI。无返回值。
func clear_action() -> void:
	_watch_profile(null)
	_active_visual = null
	_selected_state_id = &""
	_clear_states()
	if _apply_button != null:
		_apply_button.disabled = true
	if _apply_hint != null:
		_apply_hint.text = ""
	if _operation_status != null:
		_operation_status.text = ""
	if _current_state_info != null:
		_current_state_info.text = "未选择状态。"
	if _current_state_preview != null:
		_current_state_preview.texture = null
	_hide_save_confirm()
	_refresh_shared_hint(null)


## 按 active visual 展示其 Profile 的状态列表与编辑控件；profile 缺失时清空状态。无返回值。
func show_for_view(view: ObjectVisualView) -> void:
	_ensure_ui()
	if not is_instance_valid(view):
		clear_action()
		return
	_active_visual = view
	var profile: ObjectVisualProfile = view.visual_profile
	# 监听 Profile changed：应用后的 Undo/Redo 会 emit_changed，借此即时刷新当前状态纹理路径。
	_watch_profile(profile)
	if profile == null:
		_clear_states()
		_refresh_shared_hint(null)
		_refresh_apply_controls()
		return
	_show_states(profile)
	_refresh_shared_hint(profile)


## 浏览器选择变化时重算应用按钮启用条件。无返回值；只读评估，不修改 Entry 或 Profile。
func refresh_apply_controls() -> void:
	_refresh_apply_controls()


## 由 Dock 在多目标 / 无目标场景调用以刷新共享提示。profile 为当前资源或 null；无返回。
func refresh_shared_hint_for(profile: ObjectVisualProfile) -> void:
	_refresh_shared_hint(profile)


## 枚举 Profile states 建立可选择的状态列表（ItemList）。
## profile 为当前资源；无返回；不调用会修改资源的方法；切换目标先清空再按当前顺序重建。
## 不静默选中第一项；仅当旧选择仍存在时恢复高亮；ItemList 设最小高度保证 unlit/lit 可见。
func _show_states(profile: ObjectVisualProfile) -> void:
	_clear_states()
	# 新 Profile 不含旧选中状态时清除选择，避免悬空 state_id。
	if _selected_state_id != &"" and not profile.has_state(_selected_state_id):
		_selected_state_id = &""
	if profile.states.is_empty():
		var empty_label := Label.new()
		empty_label.text = "<无状态>"
		_states_box.add_child(empty_label)
		_update_current_state_info(profile)
		_refresh_apply_controls()
		return
	_state_list = ItemList.new()
	_state_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 垂直不展开：在上方 ScrollContainer 内保持最小高度，按内容定位而非无限撑高。
	_state_list.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# 最小高度保证至少可见 unlit/lit 两项，不被上方字段挤没。
	_state_list.custom_minimum_size.y = 96
	_state_list.item_selected.connect(Callable(self, "_on_state_selected"))
	_states_box.add_child(_state_list)
	for state: VisualStateTexture in profile.states:
		var id_text := "<null>"
		var is_default := false
		var texture_filename := "缺失纹理"
		var full_path := ""
		if state != null:
			id_text = String(state.state_id)
			is_default = state.state_id == profile.default_state_id
			if state.world_texture != null:
				var rpath: String = state.world_texture.resource_path
				if rpath == "":
					texture_filename = "<内存资源>"
					full_path = "<内存资源>"
				else:
					full_path = rpath
					texture_filename = rpath.get_file()
		var row_text := id_text
		if is_default:
			row_text += "  [默认]"
		row_text += "  " + texture_filename
		var idx: int = _state_list.add_item(row_text)
		_state_list.set_item_metadata(idx, StringName(id_text))
		if full_path != "":
			_state_list.set_item_tooltip(idx, full_path)
		# 仅恢复仍存在的旧选择高亮，不静默选中第一项。
		if _selected_state_id != &"" and StringName(id_text) == _selected_state_id:
			_state_list.select(idx)
	_update_current_state_info(profile)
	_refresh_apply_controls()


## 状态列表选中回调：记录 state_id 并刷新当前状态信息与应用按钮。
## index 为选中项索引；无返回；不修改 Profile。
func _on_state_selected(index: int) -> void:
	if _state_list == null or not is_instance_valid(_state_list):
		return
	if index < 0 or index >= _state_list.item_count:
		return
	_selected_state_id = _state_list.get_item_metadata(index) as StringName
	var view: ObjectVisualView = get_active_visual_target()
	if view != null and view.visual_profile != null:
		_update_current_state_info(view.visual_profile)
	_refresh_apply_controls()


## 更新当前状态纹理信息与小预览。
## profile 为当前资源；无返回；按 _selected_state_id 取 world_texture 展示路径与预览，只读不修改。
func _update_current_state_info(profile: ObjectVisualProfile) -> void:
	if _current_state_info == null:
		return
	if _selected_state_id == &"":
		_current_state_info.text = "未选择状态。"
		_current_state_preview.texture = null
		return
	var state: VisualStateTexture = _edit_service.find_state(profile, _selected_state_id) as VisualStateTexture
	if state == null:
		_current_state_info.text = "状态不存在。"
		_current_state_preview.texture = null
		return
	if state.world_texture == null:
		_current_state_info.text = "状态 %s：缺失纹理。" % String(_selected_state_id)
		_current_state_preview.texture = null
		return
	var rpath: String = state.world_texture.resource_path
	if rpath == "":
		_current_state_info.text = "状态 %s：<内存资源>。" % String(_selected_state_id)
	else:
		_current_state_info.text = "状态 %s：%s" % [String(_selected_state_id), rpath]
	_current_state_preview.texture = state.world_texture


## 评估应用按钮启用条件并刷新按钮状态与提示。无返回；只读评估，不修改 Profile。
func _refresh_apply_controls() -> void:
	if _apply_button == null:
		return
	var verdict: Dictionary = _evaluate_apply()
	_apply_button.disabled = not verdict.ok
	_apply_hint.text = verdict.reason


## 计算应用按钮是否可启用；返回 {ok: bool, reason: String}。只读，无副作用。
func _evaluate_apply() -> Dictionary:
	var view: ObjectVisualView = get_active_visual_target()
	if view == null:
		return {ok = false, reason = "请先选择一个视觉目标。"}
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		return {ok = false, reason = "该视觉节点未配置视觉配置文件。"}
	if _selected_state_id == &"":
		return {ok = false, reason = "请选择一个视觉状态。"}
	if not profile.has_state(_selected_state_id):
		return {ok = false, reason = "目标状态已不存在。"}
	var entry = _get_selected_art_entry()
	if entry == null:
		return {ok = false, reason = "请从美术浏览器选择一张图片。"}
	var texture: Texture2D = entry.texture
	if texture == null or not is_instance_valid(texture):
		return {ok = false, reason = "所选素材纹理不可用。"}
	if entry.resource_path == "" or not entry.resource_path.begins_with(_ART_ROOT_PREFIX):
		return {ok = false, reason = "素材必须位于 res://assets/art/。"}
	return {ok = true, reason = "条件满足，可应用替换。"}


## 经 Dock 注入的提供器取得浏览器当前选中 Entry；无提供器或失效时返回 null。
func _get_selected_art_entry():
	if not _browser_entry_provider.is_valid():
		return null
	return _browser_entry_provider.call()


## 应用按钮回调：通过注入的 EditorUndoRedoManager 走正式 Undo/Redo 替换当前状态纹理。
## 重新获取 active target / state_id / art entry；无 manager 或服务失败时明确写入 operation_status；
## 成功 / 跳过 / 失败三态各有文案；成功后刷新状态列表当前纹理信息并保持当前状态选择。不自动保存。
func _on_apply_pressed() -> void:
	var view: ObjectVisualView = get_active_visual_target()
	if view == null:
		return
	var entry = _get_selected_art_entry()
	if entry == null:
		return
	if _editor_undo_redo == null:
		_operation_status.text = "应用失败：编辑器撤销管理器未注入，无法替换。"
		return
	var action_name := "替换视觉状态 %s 的图片" % String(_selected_state_id)
	var result: Dictionary = _edit_service.replace_with_undo_redo(
		_editor_undo_redo, view, _selected_state_id, entry.texture, action_name)
	if not result.get("ok", false):
		_operation_status.text = "应用失败：%s" % String(result.get("reason", "未知原因。"))
		return
	if result.get("skipped", false):
		_operation_status.text = "所选素材与当前纹理相同，没有创建修改。"
	else:
		_operation_status.text = "已将 %s 应用到状态 %s，可使用 Ctrl+Z 撤销。" % [entry.file_name, String(_selected_state_id)]
	# 刷新状态列表以显示新纹理文件名，并保持当前状态选择高亮。
	_show_states(view.visual_profile)


## 保存按钮回调：先显示确认提示与确认按钮，不立即写盘，也不调用替换服务。
## 无返回；正式保存在用户点击“确认保存”后发生。
func _on_save_pressed() -> void:
	var view: ObjectVisualView = get_active_visual_target()
	if view == null:
		_operation_status.text = "未选择视觉目标，无法保存。"
		return
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		_operation_status.text = "该视觉节点未配置视觉配置文件。"
		return
	var path: String = profile.resource_path
	if path == "":
		_operation_status.text = "当前视觉配置尚未保存为独立资源，暂不支持正式保存。"
		return
	# 显示确认提示与确认按钮；不在测试中弹真实阻塞对话框。
	_save_confirm.text = "即将保存共享视觉配置：\n%s\n该操作会把当前状态图片写入项目资源文件。" % path
	_save_confirm.visible = true
	_confirm_save_button.visible = true
	_cancel_save_button.visible = true
	_operation_status.text = "请确认是否保存。"


## 确认保存回调：执行写盘并报告结果。
## 无返回；保存独立于 Undo/Redo，仅把当前内存状态写回既有 .tres；不调用替换服务。
func _on_confirm_save_pressed() -> void:
	_hide_save_confirm()
	var view: ObjectVisualView = get_active_visual_target()
	if view == null:
		_operation_status.text = "未选择视觉目标，无法保存。"
		return
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		_operation_status.text = "该视觉节点未配置视觉配置文件。"
		return
	var result: Dictionary = _save_service.save(profile)
	if result.get("ok", false):
		_operation_status.text = "已保存：%s" % String(result.get("path", ""))
	else:
		_operation_status.text = result.reason


## 取消保存回调：隐藏确认 UI，不写盘。无返回。
func _on_cancel_save_pressed() -> void:
	_hide_save_confirm()
	_operation_status.text = "已取消保存。"


## 隐藏保存确认 UI。无返回。
func _hide_save_confirm() -> void:
	if _save_confirm != null:
		_save_confirm.visible = false
	if _confirm_save_button != null:
		_confirm_save_button.visible = false
	if _cancel_save_button != null:
		_cancel_save_button.visible = false


## 刷新共享资源提示。
## profile 为当前资源；无返回；resource_path 非空提示共享影响，为空提示暂不支持保存。不声称精确引用数。
func _refresh_shared_hint(profile: ObjectVisualProfile) -> void:
	if _shared_hint == null:
		return
	if profile == null:
		_shared_hint.text = ""
		return
	if profile.resource_path == "":
		_shared_hint.text = "当前视觉配置尚未保存为独立资源，暂不支持正式保存。"
	else:
		_shared_hint.text = "当前视觉配置是共享资源。保存后，所有引用该配置的对象都会使用新的图片。"


## 监听指定 Profile 的 changed 信号以在 Undo/Redo 后即时刷新当前状态纹理路径。
## profile 为 null 时仅断开旧监听；切换目标先断开旧 Profile，避免重复连接或泄漏旧信号。无返回值。
func _watch_profile(profile: ObjectVisualProfile) -> void:
	if _watched_profile != null and is_instance_valid(_watched_profile) and _watched_profile.changed.is_connected(_on_profile_changed):
		_watched_profile.changed.disconnect(_on_profile_changed)
	_watched_profile = profile
	if profile != null and not profile.changed.is_connected(_on_profile_changed):
		profile.changed.connect(_on_profile_changed)


## Profile changed 回调：Undo/Redo 触发 emit_changed 后，刷新当前状态纹理路径与小预览。无返回值。
func _on_profile_changed() -> void:
	if is_instance_valid(_active_visual) and _active_visual.visual_profile != null:
		_update_current_state_info(_active_visual.visual_profile)


## 清空状态列表控件。无参数无返回；副作用仅释放面板内状态控件。
func _clear_states() -> void:
	_state_list = null
	if _states_box == null:
		return
	for child: Node in _states_box.get_children():
		child.queue_free()
