@tool
class_name LightSpeedArtProfileVisualStatePanel
extends VBoxContainer

## 视觉状态子面板（D4.5-P1B 拆分自 profile_action_panel；AF-Artwork 再拆出库存图标区与创建绑定区）。
## 职责：枚举 Profile 状态供用户选择、展示当前纹理信息与预览、评估并执行"应用到当前状态"
##       （经注入的 EditService + UndoRedo）；装配 InventoryIconPanel 与 ProfileBindPanel 并转发注入。
## 输入输出：由 ActionPanel 注入 active visual 提供器、素材提供器、UndoRedo、EditService、
##       BindService、编辑场景根提供器、绑定后刷新提供器、共享状态 Label。
## 副作用：替换通过 EditorUndoRedoManager 走正式 Undo/Redo；仅重建自身控件，不直接改写 Profile 字段、不扫描素材。
## 边界：不静默选中第一项；切换目标清空旧状态选择；单击素材仅选择预览，不在此处替换；
##       真正替换只经"应用到当前状态" + UndoRedo；保存交由 ProfileSavePanel；
##       库存图标与创建绑定细节分别下沉两个子面板，本面板只装配 / 转发 / 刷新。

const _ART_ROOT_PREFIX: String = "res://assets/art/"

# 以 preload + 基类型持有子面板，避免引用尚未进入全局缓存的新 class_name（见 MCP 新 class_name 缓存坑）。
const _IconPanelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/dock/inventory_icon_panel.gd"
)
const _BindPanelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/dock/profile_bind_panel.gd"
)

# ActionPanel 注入：返回当前激活 ObjectVisualView 或 null；只读，不持有 active visual 生命周期。
var _active_visual_provider: Callable = Callable()
# ActionPanel 注入：返回浏览器当前选中 ArtAssetEntry 或 null；只读，不暴露内部数组。
var _browser_entry_provider: Callable = Callable()
# ActionPanel 注入：真实编辑器 UndoRedo 管理器；未注入时为 null，应用按钮会明确报失败而非静默无效。
var _editor_undo_redo = null
# ActionPanel 注入并按需更新：纹理替换编辑服务；由 ActionPanel 持有，测试可整体替换。
var _edit_service: RefCounted = null
# ActionPanel 注入：返回当前编辑场景根 Node 或 null；应用路径的同 Profile 多实例刷新使用。
var _scene_root_provider: Callable = Callable()
# ActionPanel 注入：共享操作状态 Label，应用结果（成功/跳过/失败）写入此处。
var _status_label: Label = null

var _steps_hint: Label = null
var _states_title: Label = null
var _states_box: VBoxContainer = null
var _state_list: ItemList = null
var _info_title: Label = null
var _current_state_info: Label = null
var _current_state_preview: TextureRect = null
var _apply_button: Button = null
var _apply_hint: Label = null
# 子面板以基类型 VBoxContainer 持有，原因同上。
var _icon_panel: VBoxContainer = null
var _bind_panel: VBoxContainer = null

# 用户在状态列表中明确选择的状态 ID；未选择时为空 StringName。
var _selected_state_id: StringName = &""


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 ActionPanel 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。无参数无返回；仅在控件缺失时创建子节点。
func _ensure_ui() -> void:
	if _states_box != null and is_instance_valid(_states_box):
		return
	add_theme_constant_override("separation", 6)
	# 替换步骤引导：明确"选择状态 → 选择素材 → 应用 → 保存"的完整流程，避免误以为单击/双击即替换。
	_steps_hint = Label.new()
	_steps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_steps_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
	_steps_hint.text = "替换步骤：\n1. 选择视觉状态；\n2. 在下方选择美术素材；\n3. 点击\"应用到当前状态\"；\n4. 确认效果后保存视觉配置。"
	add_child(_steps_hint)
	_states_title = Label.new()
	_states_title.text = "视觉状态（选择一个状态以替换图片）"
	add_child(_states_title)
	# 状态列表容器：show_states 在其中创建 ItemList；独立容器便于清空重建。
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
	# 库存图标区：与状态纹理并列的 Profile 级图标入口；子面板整体初始不可见，仅 Profile 存在时显示。
	_icon_panel = _IconPanelScript.new() as VBoxContainer
	_icon_panel.set_active_visual_provider(_active_visual_provider)
	_icon_panel.set_browser_entry_provider(_browser_entry_provider)
	_icon_panel.set_editor_undo_redo(_editor_undo_redo)
	_icon_panel.set_edit_service(_edit_service)
	_icon_panel.set_scene_root_provider(_scene_root_provider)
	_icon_panel.set_status_label(_status_label)
	add_child(_icon_panel)
	_icon_panel._ensure_ui()
	# 创建绑定区：Profile 缺失时可见的最小无代码创建入口。
	_bind_panel = _BindPanelScript.new() as VBoxContainer
	_bind_panel.set_active_visual_provider(_active_visual_provider)
	_bind_panel.set_browser_entry_provider(_browser_entry_provider)
	_bind_panel.set_editor_undo_redo(_editor_undo_redo)
	_bind_panel.set_scene_root_provider(_scene_root_provider)
	_bind_panel.set_status_label(_status_label)
	add_child(_bind_panel)
	_bind_panel._ensure_ui()


## ActionPanel 注入 active visual 提供器；同时转发两个子面板。无返回值。
func set_active_visual_provider(cb: Callable) -> void:
	_active_visual_provider = cb
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_active_visual_provider(cb)
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_active_visual_provider(cb)


## ActionPanel 注入浏览器素材提供器；同时转发两个子面板。无返回值。
func set_browser_entry_provider(cb: Callable) -> void:
	_browser_entry_provider = cb
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_browser_entry_provider(cb)
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_browser_entry_provider(cb)


## ActionPanel 注入真实编辑器 UndoRedo 管理器；同时转发两个子面板。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_editor_undo_redo(undo_redo)
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_editor_undo_redo(undo_redo)


## ActionPanel 注入纹理替换编辑服务；同时转发库存图标子面板。无返回值。
func set_edit_service(edit_service: RefCounted) -> void:
	_edit_service = edit_service
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_edit_service(edit_service)


## ActionPanel 注入创建并绑定服务；转发创建绑定子面板。无返回值。
func set_bind_service(bind_service: RefCounted) -> void:
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_bind_service(bind_service)


## ActionPanel 注入编辑场景根提供器；同时转发两个子面板。无返回值。
func set_scene_root_provider(cb: Callable) -> void:
	_scene_root_provider = cb
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_scene_root_provider(cb)
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_scene_root_provider(cb)


## ActionPanel 注入绑定后刷新提供器；转发创建绑定子面板。无返回值。
func set_refresh_for_view_provider(cb: Callable) -> void:
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_refresh_for_view_provider(cb)


## ActionPanel 注入共享操作状态 Label；同时转发两个子面板。无返回值。
func set_status_label(label: Label) -> void:
	_status_label = label
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.set_status_label(label)
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.set_status_label(label)


## 只读边界：返回用户明确选择的状态 ID；未选择返回空 StringName。
func get_selected_state_id() -> StringName:
	return _selected_state_id


## 仅清空状态选择（保留 active visual）；切换视觉目标时由 ActionPanel 调用，避免旧 state_id 误用。无返回值。
func clear_state_selection() -> void:
	_selected_state_id = &""
	_refresh_apply_controls()


## 清空状态列表控件并重算应用按钮；profile 为空时由 ActionPanel 调用（改显创建绑定区）。无返回值。
func clear_states() -> void:
	_clear_states()
	_icon_panel.set_section_visible(false)
	_bind_panel.set_section_visible(true)
	_bind_panel.refresh_create_bind_controls()
	_refresh_apply_controls()


## 清空本面板全部状态：选择、列表、信息、预览、应用按钮、库存图标区与创建绑定区；clear_action 时由 ActionPanel 调用。无返回值。
func clear_visual_state() -> void:
	_selected_state_id = &""
	_clear_states()
	if _apply_button != null:
		_apply_button.disabled = true
	if _apply_hint != null:
		_apply_hint.text = ""
	if _current_state_info != null:
		_current_state_info.text = "未选择状态。"
	if _current_state_preview != null:
		_current_state_preview.texture = null
	_icon_panel.set_section_visible(false)
	_bind_panel.set_section_visible(false)


## 浏览器选择变化时重算应用按钮与图标 / 创建绑定区启用条件。无返回；只读评估，不修改 Entry 或 Profile。
func refresh_apply_controls() -> void:
	_refresh_apply_controls()
	refresh_icon_section()
	refresh_create_bind_controls()


## 兼容转发：刷新库存图标区（见 InventoryIconPanel.refresh_icon_section）。无返回值。
func refresh_icon_section() -> void:
	if _icon_panel != null and is_instance_valid(_icon_panel):
		_icon_panel.refresh_icon_section()


## 兼容转发：刷新创建绑定区（见 ProfileBindPanel.refresh_create_bind_controls）。无返回值。
func refresh_create_bind_controls() -> void:
	if _bind_panel != null and is_instance_valid(_bind_panel):
		_bind_panel.refresh_create_bind_controls()


## 枚举 Profile states 建立可选择的状态列表（ItemList）。
## profile 为当前资源；无返回；不调用会修改资源的方法；切换目标先清空再按当前顺序重建。
## 不静默选中第一项；仅当旧选择仍存在时恢复高亮；ItemList 设最小高度保证 unlit/lit 可见。
func show_states(profile: ObjectVisualProfile) -> void:
	_clear_states()
	_bind_panel.set_section_visible(false)
	_icon_panel.set_section_visible(true)
	refresh_icon_section()
	# 新 Profile 不含旧选中状态时清除选择，避免悬空 state_id。
	if _selected_state_id != &"" and not profile.has_state(_selected_state_id):
		_selected_state_id = &""
	if profile.states.is_empty():
		var empty_label := Label.new()
		empty_label.text = "<无状态>"
		_states_box.add_child(empty_label)
		update_current_state_info(profile)
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
	update_current_state_info(profile)
	_refresh_apply_controls()


## 状态列表选中回调：记录 state_id 并刷新当前状态信息与应用按钮。
## index 为选中项索引；无返回；不修改 Profile。
func _on_state_selected(index: int) -> void:
	if _state_list == null or not is_instance_valid(_state_list):
		return
	if index < 0 or index >= _state_list.item_count:
		return
	_selected_state_id = _state_list.get_item_metadata(index) as StringName
	var view: ObjectVisualView = _get_active_visual()
	if view != null and view.visual_profile != null:
		update_current_state_info(view.visual_profile)
	_refresh_apply_controls()


## 更新当前状态纹理信息与小预览。
## profile 为当前资源；无返回；按 _selected_state_id 取 world_texture 展示路径与预览，只读不修改。
## 由 ActionPanel 在 Profile changed 后调用，故为公共方法。
func update_current_state_info(profile: ObjectVisualProfile) -> void:
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
	var view: ObjectVisualView = _get_active_visual()
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


## 经注入提供器取得当前激活视觉目标；提供器未注入或失效返回 null。
func _get_active_visual() -> ObjectVisualView:
	if not _active_visual_provider.is_valid():
		return null
	return _active_visual_provider.call() as ObjectVisualView


## 经 Dock 注入的提供器取得浏览器当前选中 Entry；无提供器或失效时返回 null。
func _get_selected_art_entry():
	if not _browser_entry_provider.is_valid():
		return null
	return _browser_entry_provider.call()


## 应用按钮回调：通过注入的 EditorUndoRedoManager 走正式 Undo/Redo 替换当前状态纹理。
## 重新获取 active target / state_id / art entry；无 manager 或服务失败时明确写入共享状态 Label；
## 成功 / 跳过 / 失败三态各有文案；成功后刷新状态列表当前纹理信息并保持当前状态选择。不自动保存。
func _on_apply_pressed() -> void:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return
	var entry = _get_selected_art_entry()
	if entry == null:
		return
	if _editor_undo_redo == null:
		if _status_label != null:
			_status_label.text = "应用失败：编辑器撤销管理器未注入，无法替换。"
		return
	var action_name := "替换视觉状态 %s 的图片" % String(_selected_state_id)
	var result: Dictionary = _edit_service.replace_with_undo_redo(
		_editor_undo_redo, view, _selected_state_id, entry.texture, action_name,
		get_scene_root())
	if not result.get("ok", false):
		if _status_label != null:
			_status_label.text = "应用失败：%s" % String(result.get("reason", "未知原因。"))
		return
	if result.get("skipped", false):
		if _status_label != null:
			_status_label.text = "所选素材与当前纹理相同，没有创建修改。"
	else:
		if _status_label != null:
			_status_label.text = "已将 %s 应用到状态 %s，可使用 Ctrl+Z 撤销。" % [entry.file_name, String(_selected_state_id)]
	# 刷新状态列表以显示新纹理文件名，并保持当前状态选择高亮。
	show_states(view.visual_profile)


## 清空状态列表控件。无参数无返回；副作用仅释放面板内状态控件。
func _clear_states() -> void:
	_state_list = null
	if _states_box == null:
		return
	for child: Node in _states_box.get_children():
		child.queue_free()


## 经注入提供器取得当前编辑场景根；未注入或失效返回 null。只读。
func get_scene_root() -> Node:
	if not _scene_root_provider.is_valid():
		return null
	return _scene_root_provider.call() as Node
