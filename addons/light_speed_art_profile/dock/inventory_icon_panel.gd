@tool
class_name LightSpeedArtProfileInventoryIconPanel
extends VBoxContainer

## 库存图标子面板（AF-Artwork 拆分自 visual_state_panel）。
## 职责：展示 Profile 级 inventory_icon 的路径与预览，评估并执行"应用到库存图标 / 清除库存图标"
##       （经注入的 EditService + UndoRedo 显式事务）。
## 输入输出：由 VisualStatePanel 注入 active visual 提供器、素材提供器、UndoRedo、EditService、
##       编辑场景根提供器、共享状态 Label。
## 副作用：替换 / 清除通过 EditorUndoRedoManager 走正式 Undo/Redo；仅重建自身控件，
##       不直接改写 Profile 字段、不保存资源。
## 边界：清除也是一次可撤销事务；不扫描素材；单击素材仅选择预览；保存交由 ProfileSavePanel。

const _ART_ROOT_PREFIX: String = "res://assets/art/"

# VisualStatePanel 注入：返回当前激活 ObjectVisualView 或 null；只读，不持有 active visual 生命周期。
var _active_visual_provider: Callable = Callable()
# VisualStatePanel 注入：返回浏览器当前选中 ArtAssetEntry 或 null；只读，不暴露内部数组。
var _browser_entry_provider: Callable = Callable()
# VisualStatePanel 注入：真实编辑器 UndoRedo 管理器；未注入时为 null，按钮路径会明确报失败而非静默无效。
var _editor_undo_redo = null
# VisualStatePanel 注入并按需更新：纹理替换编辑服务；由编排层持有，测试可整体替换。
var _edit_service: RefCounted = null
# VisualStatePanel 注入：返回当前编辑场景根 Node 或 null；同 Profile 多实例刷新使用。
var _scene_root_provider: Callable = Callable()
# VisualStatePanel 注入：共享操作状态 Label，应用 / 清除结果写入此处。
var _status_label: Label = null

var _icon_title: Label = null
var _icon_info: Label = null
var _icon_preview: TextureRect = null
var _apply_icon_button: Button = null
var _clear_icon_button: Button = null
var _icon_hint: Label = null


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 VisualStatePanel 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。无参数无返回；仅在控件缺失时创建子节点，整体初始不可见。
func _ensure_ui() -> void:
	if _icon_title != null and is_instance_valid(_icon_title):
		return
	add_theme_constant_override("separation", 6)
	_icon_title = Label.new()
	_icon_title.text = "库存图标（道具栏显示）"
	_icon_title.visible = false
	add_child(_icon_title)
	_icon_info = Label.new()
	_icon_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_icon_info.text = "未设置。"
	_icon_info.visible = false
	add_child(_icon_info)
	_icon_preview = TextureRect.new()
	_icon_preview.custom_minimum_size = Vector2(0, 48)
	_icon_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_icon_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_preview.visible = false
	add_child(_icon_preview)
	_apply_icon_button = Button.new()
	_apply_icon_button.text = "应用到库存图标"
	_apply_icon_button.disabled = true
	_apply_icon_button.visible = false
	_apply_icon_button.pressed.connect(Callable(self, "_on_apply_icon_pressed"))
	add_child(_apply_icon_button)
	_clear_icon_button = Button.new()
	_clear_icon_button.text = "清除库存图标"
	_clear_icon_button.disabled = true
	_clear_icon_button.visible = false
	_clear_icon_button.pressed.connect(Callable(self, "_on_clear_icon_pressed"))
	add_child(_clear_icon_button)
	_icon_hint = Label.new()
	_icon_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_icon_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_icon_hint.visible = false
	add_child(_icon_hint)


## VisualStatePanel 注入 active visual 提供器；cb 无参数，返回 ObjectVisualView 或 null。无返回值。
func set_active_visual_provider(cb: Callable) -> void:
	_active_visual_provider = cb


## VisualStatePanel 注入浏览器素材提供器；cb 无参数，返回 ArtAssetEntry 或 null。无返回值。
func set_browser_entry_provider(cb: Callable) -> void:
	_browser_entry_provider = cb


## VisualStatePanel 注入真实编辑器 UndoRedo 管理器；传入 null 表示清空引用。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo


## VisualStatePanel 注入纹理替换编辑服务；测试可整体替换后立即生效。无返回值。
func set_edit_service(edit_service: RefCounted) -> void:
	_edit_service = edit_service


## VisualStatePanel 注入编辑场景根提供器；cb 无参数，返回 Node 或 null。无返回值。
func set_scene_root_provider(cb: Callable) -> void:
	_scene_root_provider = cb


## VisualStatePanel 注入共享操作状态 Label；应用 / 清除结果写入此处。无返回值。
func set_status_label(label: Label) -> void:
	_status_label = label


## 设置库存图标区可见性。visible_flag 为目标状态；无返回；不改动控件内容。
func set_section_visible(visible_flag: bool) -> void:
	for control in [_icon_title, _icon_info, _icon_preview, _apply_icon_button, _clear_icon_button, _icon_hint]:
		if control != null and is_instance_valid(control):
			control.visible = visible_flag


## 刷新库存图标区：当前图标路径 / 预览 / 两个按钮启用条件。无返回；只读评估。
## Undo/Redo 后由统一刷新钩子（ActionPanel version_changed）经 show_states 调用。
func refresh_icon_section() -> void:
	if _icon_info == null:
		return
	var view: ObjectVisualView = _get_active_visual()
	var profile: ObjectVisualProfile = null
	if view != null:
		profile = view.visual_profile
	if profile == null:
		_icon_info.text = "未设置。"
		_icon_preview.texture = null
	else:
		var icon: Texture2D = profile.inventory_icon
		if icon == null:
			_icon_info.text = "未设置（道具栏显示占位符）。"
			_icon_preview.texture = null
		elif icon.resource_path == "":
			_icon_info.text = "<内存资源>"
			_icon_preview.texture = icon
		else:
			_icon_info.text = icon.resource_path
			_icon_preview.texture = icon
	var apply_verdict: Dictionary = _evaluate_icon_apply()
	_apply_icon_button.disabled = not apply_verdict.ok
	_icon_hint.text = apply_verdict.reason
	_clear_icon_button.disabled = not _evaluate_clear_icon()


## 计算应用库存图标按钮是否可启用；返回 {ok, reason}。只读，无副作用。
func _evaluate_icon_apply() -> Dictionary:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return {ok = false, reason = "请先选择一个视觉目标。"}
	if view.visual_profile == null:
		return {ok = false, reason = "该视觉节点未配置视觉配置文件。"}
	var entry = _get_selected_art_entry()
	if entry == null:
		return {ok = false, reason = "请从美术浏览器选择一张图片。"}
	var texture: Texture2D = entry.texture
	if texture == null or not is_instance_valid(texture):
		return {ok = false, reason = "所选素材纹理不可用。"}
	if entry.resource_path == "" or not entry.resource_path.begins_with(_ART_ROOT_PREFIX):
		return {ok = false, reason = "素材必须位于 res://assets/art/。"}
	return {ok = true, reason = "条件满足，可应用到库存图标。"}


## 计算清除库存图标按钮是否可启用：已有图标才可清除。只读，无副作用。
func _evaluate_clear_icon() -> bool:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return false
	var profile: ObjectVisualProfile = view.visual_profile
	return profile != null and profile.inventory_icon != null


## 应用库存图标按钮回调：经 UndoRedo 替换 Profile.inventory_icon。无返回；不自动保存。
func _on_apply_icon_pressed() -> void:
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
	var result: Dictionary = _edit_service.replace_inventory_icon_with_undo_redo(
		_editor_undo_redo, view, entry.texture, "替换库存图标", get_scene_root())
	if not result.get("ok", false):
		if _status_label != null:
			_status_label.text = "应用失败：%s" % String(result.get("reason", "未知原因。"))
		return
	if result.get("skipped", false):
		if _status_label != null:
			_status_label.text = "所选图片与当前库存图标相同，没有创建修改。"
	else:
		if _status_label != null:
			_status_label.text = "已将 %s 应用到库存图标，可使用 Ctrl+Z 撤销。" % entry.file_name
	refresh_icon_section()


## 清除库存图标按钮回调：经 UndoRedo 把 Profile.inventory_icon 置空（显式清除事务）。无返回。
func _on_clear_icon_pressed() -> void:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return
	if _editor_undo_redo == null:
		if _status_label != null:
			_status_label.text = "清除失败：编辑器撤销管理器未注入。"
		return
	var result: Dictionary = _edit_service.replace_inventory_icon_with_undo_redo(
		_editor_undo_redo, view, null, "清除库存图标", get_scene_root())
	if not result.get("ok", false):
		if _status_label != null:
			_status_label.text = "清除失败：%s" % String(result.get("reason", "未知原因。"))
		return
	if result.get("skipped", false):
		if _status_label != null:
			_status_label.text = "当前没有库存图标，无需清除。"
	else:
		if _status_label != null:
			_status_label.text = "已清除库存图标，可使用 Ctrl+Z 撤销。"
	refresh_icon_section()


## 经注入提供器取得当前激活视觉目标；提供器未注入或失效返回 null。
func _get_active_visual() -> ObjectVisualView:
	if not _active_visual_provider.is_valid():
		return null
	return _active_visual_provider.call() as ObjectVisualView


## 经注入提供器取得浏览器当前选中 Entry；无提供器或失效时返回 null。
func _get_selected_art_entry():
	if not _browser_entry_provider.is_valid():
		return null
	return _browser_entry_provider.call()


## 经注入提供器取得当前编辑场景根；未注入或失效返回 null。只读。
func get_scene_root() -> Node:
	if not _scene_root_provider.is_valid():
		return null
	return _scene_root_provider.call() as Node
