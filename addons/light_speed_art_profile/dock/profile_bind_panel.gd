@tool
class_name LightSpeedArtProfileProfileBindPanel
extends VBoxContainer

## 创建绑定子面板（AF-Artwork 拆分自 visual_state_panel）。
## 职责：Profile 缺失时的最小无代码创建入口——展示引导文案与前置校验原因，
##       点击后经注入的 BindService + UndoRedo 创建最小 Profile 并绑定到当前 View。
## 输入输出：由 VisualStatePanel 注入 active visual 提供器、素材提供器、UndoRedo、BindService、
##       编辑场景根提供器、绑定后刷新提供器、共享状态 Label。
## 副作用：创建经 BindService 写盘 + UndoRedo 绑定；仅重建自身控件，不迁移既有场景。
## 边界：所有前置校验委托 BindService（can_create_and_bind）；成功后经刷新提供器
##       回调 show_for_view 重建状态列表；本面板不直接读写 Profile。

# 创建绑定区默认引导文案；条件不满足时被具体原因覆盖。
const _BIND_DEFAULT_HINT: String = (
	"该视觉节点缺少视觉配置文件：从美术浏览器选择一张图片后点击下方按钮，将创建最小配置并绑定。"
)

# VisualStatePanel 注入：返回当前激活 ObjectVisualView 或 null；只读。
var _active_visual_provider: Callable = Callable()
# VisualStatePanel 注入：返回浏览器当前选中 ArtAssetEntry 或 null；只读。
var _browser_entry_provider: Callable = Callable()
# VisualStatePanel 注入：真实编辑器 UndoRedo 管理器；未注入时为 null，创建按钮会明确报失败。
var _editor_undo_redo = null
# VisualStatePanel 注入并按需更新：创建并绑定服务；由编排层持有，测试可整体替换。
var _bind_service: RefCounted = null
# VisualStatePanel 注入：返回当前编辑场景根 Node 或 null；创建路径推导使用。
var _scene_root_provider: Callable = Callable()
# VisualStatePanel 注入：绑定成功后回调 show_for_view(view) 的提供器；用于刷新状态列表。
var _refresh_for_view_provider: Callable = Callable()
# VisualStatePanel 注入：共享操作状态 Label，创建结果写入此处。
var _status_label: Label = null

var _bind_hint: Label = null
var _create_bind_button: Button = null


## 初始化面板控件树。无参数无返回；_ready 在编辑器入树时触发，测试由 VisualStatePanel 显式调用 _ensure_ui。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。无参数无返回；仅在控件缺失时创建子节点，整体初始不可见。
func _ensure_ui() -> void:
	if _bind_hint != null and is_instance_valid(_bind_hint):
		return
	add_theme_constant_override("separation", 6)
	_bind_hint = Label.new()
	_bind_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bind_hint.add_theme_color_override("font_color", Color(0.9, 0.75, 0.5))
	_bind_hint.text = _BIND_DEFAULT_HINT
	_bind_hint.visible = false
	add_child(_bind_hint)
	_create_bind_button = Button.new()
	_create_bind_button.text = "创建并绑定视觉配置"
	_create_bind_button.disabled = true
	_create_bind_button.visible = false
	_create_bind_button.pressed.connect(Callable(self, "_on_create_bind_pressed"))
	add_child(_create_bind_button)


## VisualStatePanel 注入 active visual 提供器；cb 无参数，返回 ObjectVisualView 或 null。无返回值。
func set_active_visual_provider(cb: Callable) -> void:
	_active_visual_provider = cb


## VisualStatePanel 注入浏览器素材提供器；cb 无参数，返回 ArtAssetEntry 或 null。无返回值。
func set_browser_entry_provider(cb: Callable) -> void:
	_browser_entry_provider = cb


## VisualStatePanel 注入真实编辑器 UndoRedo 管理器；传入 null 表示清空引用。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo


## VisualStatePanel 注入创建并绑定服务；测试可整体替换后立即生效。无返回值。
func set_bind_service(bind_service: RefCounted) -> void:
	_bind_service = bind_service


## VisualStatePanel 注入编辑场景根提供器；cb 无参数，返回 Node 或 null。无返回值。
func set_scene_root_provider(cb: Callable) -> void:
	_scene_root_provider = cb


## VisualStatePanel 注入绑定后刷新提供器；cb 收一个 view 参数回调 show_for_view。无返回值。
func set_refresh_for_view_provider(cb: Callable) -> void:
	_refresh_for_view_provider = cb


## VisualStatePanel 注入共享操作状态 Label；创建结果写入此处。无返回值。
func set_status_label(label: Label) -> void:
	_status_label = label


## 设置创建绑定区可见性。visible_flag 为目标状态；无返回。
func set_section_visible(visible_flag: bool) -> void:
	if _bind_hint != null and is_instance_valid(_bind_hint):
		_bind_hint.visible = visible_flag
	if _create_bind_button != null and is_instance_valid(_create_bind_button):
		_create_bind_button.visible = visible_flag


## 刷新创建并绑定按钮启用条件与提示。无返回；只读评估（含 BindService 前置校验）。
## Undo/Redo 后由统一刷新钩子（ActionPanel version_changed）经 clear_states / show_states 调用。
func refresh_create_bind_controls() -> void:
	if _create_bind_button == null:
		return
	var verdict: Dictionary = _evaluate_create_bind()
	_create_bind_button.disabled = not verdict.ok
	if verdict.ok:
		_bind_hint.text = _BIND_DEFAULT_HINT
	elif verdict.has("reason"):
		_bind_hint.text = verdict.reason


## 计算创建并绑定按钮是否可启用；返回 {ok, reason}。只读，无副作用。
func _evaluate_create_bind() -> Dictionary:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return {ok = false, reason = "请先选择一个视觉目标。"}
	if view.visual_profile != null:
		return {ok = false, reason = "该视觉节点已有视觉配置文件。"}
	if _bind_service == null:
		return {ok = false, reason = "创建绑定服务未注入。"}
	var entry = _get_selected_art_entry()
	if entry == null:
		return {ok = false, reason = "请从美术浏览器选择一张图片作为默认状态纹理。"}
	var texture: Texture2D = entry.texture
	if texture == null or not is_instance_valid(texture):
		return {ok = false, reason = "所选素材纹理不可用。"}
	if entry.resource_path == "" or not entry.resource_path.begins_with("res://assets/art/"):
		return {ok = false, reason = "素材必须位于 res://assets/art/。"}
	var scene_root: Node = get_scene_root()
	if scene_root == null:
		return {ok = false, reason = "无法确定当前编辑场景。"}
	var check: Dictionary = _bind_service.can_create_and_bind(view, scene_root)
	if not check.get("ok", false):
		return {ok = false, reason = String(check.get("reason", "无法创建。"))}
	return {ok = true, reason = ""}


## 创建并绑定按钮回调：经 BindService 创建最小 Profile 并 UndoRedo 绑定。无返回；成功后经
## _refresh_for_view_provider 重建状态列表并交由编排层监听新 Profile。
func _on_create_bind_pressed() -> void:
	var view: ObjectVisualView = _get_active_visual()
	if view == null:
		return
	var entry = _get_selected_art_entry()
	if entry == null:
		return
	if _editor_undo_redo == null:
		if _status_label != null:
			_status_label.text = "创建失败：编辑器撤销管理器未注入。"
		return
	var scene_root: Node = get_scene_root()
	if scene_root == null:
		if _status_label != null:
			_status_label.text = "创建失败：无法确定当前编辑场景。"
		return
	var result: Dictionary = _bind_service.create_and_bind(
		_editor_undo_redo, view, scene_root, entry.texture, "创建并绑定视觉配置")
	if not result.get("ok", false):
		if _status_label != null:
			_status_label.text = "创建失败：%s" % String(result.get("reason", "未知原因。"))
		refresh_create_bind_controls()
		return
	if _status_label != null:
		_status_label.text = "已创建 %s 并绑定，可使用 Ctrl+Z 撤销；记得保存场景。" % String(result.get("path", ""))
	if _refresh_for_view_provider.is_valid():
		_refresh_for_view_provider.call(view)


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
