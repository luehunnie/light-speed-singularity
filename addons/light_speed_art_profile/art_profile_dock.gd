@tool
extends VBoxContainer

## 美术 Profile 只读 Dock。
## 职责：展示当前选择、解析出的正式视觉节点及 Profile 状态列表。
## 输入输出：由 plugin.gd 传入选择数组；本 Dock 只更新自身控件，无返回值。
## 副作用：仅重建 Dock 内 Label，不访问编辑器单例、不修改场景或资源。
## 边界：无选择、多选、释放节点、无 Profile、空状态列表都会清空旧目标信息。

const _VisualTargetResolver: GDScript = preload("res://addons/light_speed_art_profile/visual_target_resolver.gd")

var _resolver: RefCounted = _VisualTargetResolver.new()
var _selected_value: Label = null
var _visual_value: Label = null
var _profile_value: Label = null
var _default_state_value: Label = null
var _status_label: Label = null
var _states_box: VBoxContainer = null


## 初始化 Dock 控件树。
## 无参数无返回；副作用是创建只读 Label 容器。
func _ready() -> void:
	_ensure_ui()
	_clear_details("未选择节点。")


## 接收插件传入的当前选择并刷新展示。
## selected_nodes 是 EditorSelection 快照；无返回值；只读解析，不保留目标引用。
func show_selection(selected_nodes: Array) -> void:
	_ensure_ui()
	if selected_nodes.is_empty():
		_clear_details("未选择节点。")
		_selected_value.text = "<无>"
		return
	if selected_nodes.size() != 1:
		_clear_details("当前为多选，请只选择一个节点。")
		_selected_value.text = "多选：%d 个节点" % selected_nodes.size()
		return
	var selected: Node = selected_nodes[0] as Node
	if selected == null or not is_instance_valid(selected):
		_clear_details("选中节点已释放。")
		_selected_value.text = "<已释放>"
		return
	_selected_value.text = selected.name
	var visual: ObjectVisualView = _resolver.resolve(selected)
	if visual == null:
		_show_unsupported(selected)
		return
	_show_visual_profile(visual)


## 创建一次性 UI 结构；重复调用安全。
## 无参数无返回；仅在控件缺失时创建 Dock 子节点。
func _ensure_ui() -> void:
	if _states_box != null and is_instance_valid(_states_box):
		return
	custom_minimum_size = Vector2(360, 420)
	add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "光速奇点：美术 Profile"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	_selected_value = _add_field("当前选中节点")
	_visual_value = _add_field("解析视觉节点")
	_profile_value = _add_field("Profile 资源路径")
	_default_state_value = _add_field("default_state_id")
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)
	var states_title := Label.new()
	states_title.text = "状态列表"
	add_child(states_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_states_box = VBoxContainer.new()
	_states_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_states_box)


## 新增一组字段标签。
## title 为字段名；返回可后续写入的值 Label。
func _add_field(title: String) -> Label:
	var name_label := Label.new()
	name_label.text = title
	add_child(name_label)
	var value_label := Label.new()
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.text = "-"
	add_child(value_label)
	return value_label


## 展示不支持或未解析的选择目标。
## selected 为当前单选节点；无返回值；清空旧视觉与状态信息。
func _show_unsupported(selected: Node) -> void:
	_visual_value.text = "-"
	_profile_value.text = "-"
	_default_state_value.text = "-"
	_clear_states()
	if selected is EmissionPreview:
		_status_label.text = "不支持的目标：EmissionPreview 是编辑器预览，不是正式 ObjectVisualView。"
	else:
		_status_label.text = "未找到唯一直属正式 ObjectVisualView；无视觉、歧义或仅有孙级视觉都会返回空。"


## 展示解析出的正式视觉及其 Profile。
## visual 为正式 ObjectVisualView；无返回值；只读枚举 visual_profile.states。
func _show_visual_profile(visual: ObjectVisualView) -> void:
	if not is_instance_valid(visual):
		_clear_details("解析出的视觉节点已释放。")
		return
	_visual_value.text = visual.name
	var profile: ObjectVisualProfile = visual.visual_profile
	if profile == null:
		_profile_value.text = "-"
		_default_state_value.text = "-"
		_clear_states()
		_status_label.text = "视觉节点未配置 ObjectVisualProfile。"
		return
	_profile_value.text = _resource_path(profile)
	_default_state_value.text = String(profile.default_state_id)
	_show_states(profile)
	_status_label.text = "已只读展示当前 ObjectVisualProfile。"


## 枚举 Profile 的真实 states 数组。
## profile 为当前资源；无返回值；不调用会修改资源的方法。
func _show_states(profile: ObjectVisualProfile) -> void:
	_clear_states()
	if profile.states.is_empty():
		var empty_label := Label.new()
		empty_label.text = "<无状态>"
		_states_box.add_child(empty_label)
		return
	for index: int in range(profile.states.size()):
		var state: VisualStateTexture = profile.states[index]
		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if state == null:
			label.text = "[%d] <null>\n  world_texture: -\n  缺失纹理: 是\n  默认状态: 否" % index
		else:
			var is_default: bool = state.state_id == profile.default_state_id
			var missing_texture: bool = state.world_texture == null
			label.text = "[%d] state_id: %s\n  world_texture: %s\n  缺失纹理: %s\n  默认状态: %s" % [
				index,
				String(state.state_id),
				_resource_path(state.world_texture),
				"是" if missing_texture else "否",
				"是" if is_default else "否",
			]
		_states_box.add_child(label)


## 清空目标与状态展示。
## message 为提示文本；无返回值；保留当前选择字段由调用方按需覆盖。
func _clear_details(message: String) -> void:
	_ensure_ui()
	_visual_value.text = "-"
	_profile_value.text = "-"
	_default_state_value.text = "-"
	_status_label.text = message
	_clear_states()


## 清空状态列表控件。
## 无参数无返回；副作用仅释放 Dock 内状态 Label。
func _clear_states() -> void:
	if _states_box == null:
		return
	for child: Node in _states_box.get_children():
		child.queue_free()


## 取得资源路径显示文本。
## resource 可为空；返回资源路径、内存资源标记或 '-'；无副作用。
func _resource_path(resource: Resource) -> String:
	if resource == null:
		return "-"
	if resource.resource_path == "":
		return "<内存资源>"
	return resource.resource_path
