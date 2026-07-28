@tool
class_name LightSpeedArtProfileProfileSavePanel
extends VBoxContainer

## Profile 保存子面板（D4.5-P1B 拆分自 profile_action_panel）。
## 职责：共享资源提示 + 保存按钮 + 确认/取消 + 保存结果；二次确认后经 SaveService 写盘。
## 输入输出：由 ActionPanel 注入 active visual 提供器、SaveService、共享状态 Label。
## 副作用：保存通过 ProfileSaveService 写回既有 .tres；不调用替换服务。
## 边界：保存独立于 Undo/Redo，仅把当前内存状态写回既有 .tres；不创建新路径；不修改 Profile 字段；
##       纹理替换交由 VisualStatePanel。

# ActionPanel 注入：返回当前激活 ObjectVisualView 或 null；只读。
var _active_visual_provider: Callable = Callable()
# ActionPanel 注入并按需更新：Profile 保存服务；由 ActionPanel 持有，测试可整体替换。
var _save_service: RefCounted = null
# ActionPanel 注入：共享操作状态 Label，保存结果（成功/失败/取消）写入此处。
var _status_label: Label = null

var _save_hint: Label = null
var _shared_hint: Label = null
var _save_button: Button = null
var _save_confirm: Label = null
var _confirm_save_button: Button = null
var _cancel_save_button: Button = null


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 ActionPanel 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。无参数无返回；仅在控件缺失时创建子节点。
func _ensure_ui() -> void:
	if _save_button != null and is_instance_valid(_save_button):
		return
	add_theme_constant_override("separation", 6)
	# 保存语义说明：明确保存只写已应用修改，不代替"应用到当前状态"。
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


## ActionPanel 注入 active visual 提供器；cb 无参数，返回 ObjectVisualView 或 null。无返回值。
func set_active_visual_provider(cb: Callable) -> void:
	_active_visual_provider = cb


## ActionPanel 注入 Profile 保存服务；测试可经 ActionPanel 属性 setter 整体替换后立即生效。无返回值。
func set_save_service(save_service: RefCounted) -> void:
	_save_service = save_service


## ActionPanel 注入共享操作状态 Label；保存结果写入此处。无返回值。
func set_status_label(label: Label) -> void:
	_status_label = label


## 刷新共享资源提示。
## profile 为当前资源；无返回；resource_path 非空提示共享影响，为空提示暂不支持保存。不声称精确引用数。
func refresh_shared_hint(profile: ObjectVisualProfile) -> void:
	if _shared_hint == null:
		return
	if profile == null:
		_shared_hint.text = ""
		return
	if profile.resource_path == "":
		_shared_hint.text = "当前视觉配置尚未保存为独立资源，暂不支持正式保存。"
	else:
		_shared_hint.text = "当前视觉配置是共享资源。保存后，所有引用该配置的对象都会使用新的图片。"


## 保存按钮回调：先显示确认提示与确认按钮，不立即写盘，也不调用替换服务。
## 无返回；正式保存在用户点击"确认保存"后发生。
func _on_save_pressed() -> void:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		_write_status("未选择视觉目标，无法保存。")
		return
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		_write_status("该视觉节点未配置视觉配置文件。")
		return
	var path: String = profile.resource_path
	if path == "":
		_write_status("当前视觉配置尚未保存为独立资源，暂不支持正式保存。")
		return
	# 显示确认提示与确认按钮；不在测试中弹真实阻塞对话框。
	_save_confirm.text = "即将保存共享视觉配置：\n%s\n该操作会把当前状态图片写入项目资源文件。" % path
	_save_confirm.visible = true
	_confirm_save_button.visible = true
	_cancel_save_button.visible = true
	_write_status("请确认是否保存。")


## 确认保存回调：执行写盘并报告结果。
## 无返回；保存独立于 Undo/Redo，仅把当前内存状态写回既有 .tres；不调用替换服务。
func _on_confirm_save_pressed() -> void:
	_hide_save_confirm()
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		_write_status("未选择视觉目标，无法保存。")
		return
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		_write_status("该视觉节点未配置视觉配置文件。")
		return
	var result: Dictionary = _save_service.save(profile)
	if result.get("ok", false):
		_write_status("已保存：%s" % String(result.get("path", "")))
	else:
		_write_status(result.reason)


## 取消保存回调：隐藏确认 UI，不写盘。无返回。
func _on_cancel_save_pressed() -> void:
	_hide_save_confirm()
	_write_status("已取消保存。")


## 清空保存面板状态：隐藏确认 UI 并清空共享提示；clear_action 时由 ActionPanel 调用。无返回值。
func clear_save() -> void:
	_hide_save_confirm()
	refresh_shared_hint(null)


## 隐藏保存确认 UI。无返回。
func _hide_save_confirm() -> void:
	if _save_confirm != null:
		_save_confirm.visible = false
	if _confirm_save_button != null:
		_confirm_save_button.visible = false
	if _cancel_save_button != null:
		_cancel_save_button.visible = false


## 经注入提供器取得当前激活视觉目标；提供器未注入或失效返回 null。
func _get_active_visual() -> ObjectVisualView:
	if not _active_visual_provider.is_valid():
		return null
	return _active_visual_provider.call() as ObjectVisualView


## 写入共享操作状态 Label；未注入时静默跳过（仅在面板未完成接线时）。无返回值。
func _write_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
