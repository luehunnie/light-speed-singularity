@tool
class_name LightSpeedArtProfileProfileActionPanel
extends VBoxContainer

## 美术 Profile 操作面板编排器（D4.5-P1B 拆分）：编排 VisualStatePanel 与 ProfileSavePanel。
## 职责：持有 EditService / SaveService，注入 active target、素材提供器、UndoRedo；
##       协调 Profile changed；持有共享操作状态 Label；不直接构造大量控件。
## 输入输出：由 Dock 注入 active visual 与浏览器素材提供器；用户交互产生替换 / 保存；无返回值。
## 副作用：替换 / 保存委托子面板内服务走正式 Undo/Redo 与写盘；仅重建自身编排控件（子面板 + 状态 Label）。
## 边界：不暴露内部子面板控件；切换目标清空旧状态选择；不静默选中第一项；
##       单击素材仅选择预览；真正替换只经"应用到当前状态" + UndoRedo。

const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _SaveServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/profile_save_service.gd"
)
const _VisualStatePanelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/dock/visual_state_panel.gd"
)
const _SavePanelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/dock/profile_save_panel.gd"
)

# 服务由本编排器持有；通过属性 setter 在测试整体替换时同步转发给对应子面板。
var _edit_service_ref: RefCounted = _EditServiceScript.new()
var _save_service_ref: RefCounted = _SaveServiceScript.new()

# Dock 注入：返回浏览器当前选中 ArtAssetEntry 或 null；只读，转发给 VisualStatePanel。
var _browser_entry_provider: Callable = Callable()

# 当前激活的正式视觉目标；未确定时为 null。
var _active_visual: ObjectVisualView = null
# Dock 注入的真实编辑器 UndoRedo 管理器；未注入时为 null，转发给 VisualStatePanel。
var _editor_undo_redo = null
# 当前已连接 changed 信号的 Profile；切换目标 / 清空时断开旧连接，避免泄漏或重复连接。
var _watched_profile: ObjectVisualProfile = null

# 子面板以基类型 VBoxContainer 持有，避免引用尚未进入全局缓存的新 class_name（见 MCP 新 class_name 缓存坑）。
var _visual_state_panel: VBoxContainer = null
var _save_panel: VBoxContainer = null
# 共享操作状态 Label：应用 / 保存两条路径统一写入此处，保持单行底部状态不变。
var _operation_status: Label = null


## EditService 属性：读取返回当前服务；赋值时同步转发给 VisualStatePanel，供测试整体替换后立即生效。
var _edit_service: RefCounted:
	get:
		return _edit_service_ref
	set(value):
		_edit_service_ref = value
		if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
			_visual_state_panel.set_edit_service(value)


## SaveService 属性：读取返回当前服务；赋值时同步转发给 ProfileSavePanel，供测试整体替换后立即生效。
var _save_service: RefCounted:
	get:
		return _save_service_ref
	set(value):
		_save_service_ref = value
		if _save_panel != null and is_instance_valid(_save_panel):
			_save_panel.set_save_service(value)


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 Dock 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性编排 UI：两个子面板 + 共享状态 Label；重复调用安全。无参数无返回。
func _ensure_ui() -> void:
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		return
	add_theme_constant_override("separation", 6)
	# 共享状态 Label 先创建后回填给两个子面板，确保应用 / 保存写入同一底部状态行；视觉顺序由 add_child 决定。
	_operation_status = Label.new()
	_operation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_visual_state_panel = _VisualStatePanelScript.new() as VBoxContainer
	_visual_state_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_visual_state_panel.set_active_visual_provider(Callable(self, "get_active_visual_target"))
	_visual_state_panel.set_browser_entry_provider(_browser_entry_provider)
	_visual_state_panel.set_editor_undo_redo(_editor_undo_redo)
	_visual_state_panel.set_edit_service(_edit_service_ref)
	_visual_state_panel.set_status_label(_operation_status)
	add_child(_visual_state_panel)
	_visual_state_panel._ensure_ui()
	_save_panel = _SavePanelScript.new() as VBoxContainer
	_save_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_panel.set_active_visual_provider(Callable(self, "get_active_visual_target"))
	_save_panel.set_save_service(_save_service_ref)
	_save_panel.set_status_label(_operation_status)
	add_child(_save_panel)
	_save_panel._ensure_ui()
	add_child(_operation_status)


## Dock 注入浏览器素材提供器；同时转发给已存在的 VisualStatePanel。无返回值。
func set_browser_entry_provider(cb: Callable) -> void:
	_browser_entry_provider = cb
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		_visual_state_panel.set_browser_entry_provider(cb)


## Dock 注入真实编辑器 UndoRedo 管理器；同时转发给已存在的 VisualStatePanel。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		_visual_state_panel.set_editor_undo_redo(undo_redo)


## 只读边界：返回当前激活视觉目标；未选择或失效返回 null。
func get_active_visual_target() -> ObjectVisualView:
	if _active_visual == null or not is_instance_valid(_active_visual):
		return null
	return _active_visual


## 只读边界：返回用户明确选择的状态 ID；未选择返回空 StringName。
func get_selected_state_id() -> StringName:
	if _visual_state_panel == null or not is_instance_valid(_visual_state_panel):
		return &""
	return _visual_state_panel.get_selected_state_id()


## 仅清空状态选择（保留 active visual）；切换视觉目标时由 Dock 调用，避免旧 state_id 误用。无返回值。
func clear_state_selection() -> void:
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		_visual_state_panel.clear_state_selection()


## 清空全部操作状态：active visual、状态选择、子面板编辑 / 保存 UI、共享状态行。无返回值。
func clear_action() -> void:
	_watch_profile(null)
	_active_visual = null
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		_visual_state_panel.clear_visual_state()
	if _save_panel != null and is_instance_valid(_save_panel):
		_save_panel.clear_save()
	if _operation_status != null:
		_operation_status.text = ""


## 按 active visual 展示其 Profile 的状态列表与保存控件；profile 缺失时清空状态。无返回值。
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
		_visual_state_panel.clear_states()
		_save_panel.refresh_shared_hint(null)
		return
	_visual_state_panel.show_states(profile)
	_save_panel.refresh_shared_hint(profile)


## 浏览器选择变化时重算应用按钮启用条件。无返回；只读评估。
func refresh_apply_controls() -> void:
	if _visual_state_panel != null and is_instance_valid(_visual_state_panel):
		_visual_state_panel.refresh_apply_controls()


## 由 Dock 在多目标 / 无目标场景调用以刷新共享提示。profile 为当前资源或 null；无返回。
func refresh_shared_hint_for(profile: ObjectVisualProfile) -> void:
	if _save_panel != null and is_instance_valid(_save_panel):
		_save_panel.refresh_shared_hint(profile)


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
		_visual_state_panel.update_current_state_info(_active_visual.visual_profile)
