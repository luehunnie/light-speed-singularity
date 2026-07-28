@tool
extends VBoxContainer

## 美术资源只读 Dock。
## 职责：展示当前选择、解析出的可替换视觉及其视觉配置文件状态列表。
## 输入输出：由 plugin.gd 传入选择数组；本 Dock 只更新自身控件，无返回值。
## 副作用：仅重建 Dock 内 Label，不访问编辑器单例、不修改场景或资源。
## 边界：无选择、多选、释放节点、无视觉目标、空状态列表都会清空旧目标信息，
##       不留“-”占位；不修改 Resolver 解析规则，不让未接入对象强行接入。

const _VisualTargetResolver: GDScript = preload("res://addons/light_speed_art_profile/target/visual_target_resolver.gd")
const _BrowserViewScript: GDScript = preload("res://addons/light_speed_art_profile/browser/art_asset_browser_view.gd")

var _resolver: RefCounted = _VisualTargetResolver.new()
var _selected_value: Label = null
var _visual_value: Label = null
var _profile_value: Label = null
var _default_state_value: Label = null
var _status_label: Label = null
var _states_box: VBoxContainer = null
var _browser_view: Control = null


## 初始化 Dock 控件树。
## 无参数无返回；副作用是创建只读 Label 容器。
func _ready() -> void:
	_ensure_ui()
	_clear_details("请先在场景树中选择一个对象。")


## 接收插件传入的当前选择并刷新展示。
## selected_nodes 是 EditorSelection 快照；无返回值；只读解析，不保留目标引用。
func show_selection(selected_nodes: Array) -> void:
	_ensure_ui()
	if selected_nodes.is_empty():
		_clear_details("请先在场景树中选择一个对象。")
		_selected_value.text = ""
		return
	if selected_nodes.size() != 1:
		_clear_details("一次只能编辑一个对象，请保留一个选中项。")
		_selected_value.text = ""
		return
	var selected: Node = selected_nodes[0] as Node
	if selected == null or not is_instance_valid(selected):
		_clear_details("选中的节点已释放，请重新选择一个对象。")
		_selected_value.text = ""
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
	custom_minimum_size = Vector2(380, 560)
	add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "光速奇点：美术资源"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	# 视觉配置区域：独立容器，承载字段、状态与提示，与下方浏览器隔离。
	# stretch_ratio=1 对浏览器 stretch_ratio=2，状态列表永远只占有限高度，不会把浏览器挤出可视区。
	var profile_section := VBoxContainer.new()
	profile_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	profile_section.size_flags_stretch_ratio = 1.0
	profile_section.add_theme_constant_override("separation", 6)
	add_child(profile_section)
	_selected_value = _add_field(profile_section, "当前对象")
	_visual_value = _add_field(profile_section, "可替换视觉")
	_profile_value = _add_field(profile_section, "视觉配置文件")
	_default_state_value = _add_field(profile_section, "默认状态")
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	profile_section.add_child(_status_label)
	var states_title := Label.new()
	states_title.text = "视觉状态"
	profile_section.add_child(states_title)
	# 状态列表置于独立 ScrollContainer：禁用横向滚动让每行按 Dock 宽度布局，
	# 内容多时在自身范围内滚动，绝不向外膨胀挤占浏览器。
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 96
	profile_section.add_child(scroll)
	_states_box = VBoxContainer.new()
	_states_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_states_box)
	# 美术资产浏览器区域：与上方视觉配置隔离，选择素材不影响当前配置。
	# stretch_ratio=2 保证其始终占据多数可视高度，刷新/目录/搜索/预览无需滚动几千像素即可到达。
	var separator := HSeparator.new()
	add_child(separator)
	_browser_view = _BrowserViewScript.new()
	_browser_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_browser_view.size_flags_stretch_ratio = 2.0
	add_child(_browser_view)


## 新增一组字段标签。
## parent 为字段所属容器；title 为字段名；返回可后续写入的值 Label。
## 值 Label 使用 clip_text + 省略号，长路径截断显示、完整内容交由 tooltip，杜绝窄 Dock 逐字符竖排。
func _add_field(parent: Control, title: String) -> Label:
	var name_label := Label.new()
	name_label.text = title
	parent.add_child(name_label)
	var value_label := Label.new()
	value_label.clip_text = true
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.text = ""
	parent.add_child(value_label)
	return value_label


## 展示不支持或未解析的选择目标。
## selected 为当前单选节点；无返回值；清空视觉配置、默认状态与状态列表，不留占位符。
## 仅做只读子节点计数以挑选提示文案，不修改 Resolver 解析规则。
func _show_unsupported(selected: Node) -> void:
	_visual_value.text = ""
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
	_clear_states()
	if selected is EmissionPreview:
		_status_label.text = "该节点仅用于发射方向预览，不属于正式美术资源。请选择 Emitter 或 EmitterVisual。"
		return
	if _count_direct_visuals(selected) > 1:
		_status_label.text = "该对象包含多个可替换视觉，请直接选择需要编辑的视觉节点。"
		return
	_status_label.text = "当前对象暂不支持美术替换。请选择一个已接入统一视觉配置的对象，或直接选择其视觉节点。"


## 展示解析出的可替换视觉及其视觉配置文件。
## visual 为正式 ObjectVisualView；无返回值；只读枚举 visual_profile.states。
func _show_visual_profile(visual: ObjectVisualView) -> void:
	if not is_instance_valid(visual):
		_clear_details("解析出的视觉节点已释放，请重新选择一个对象。")
		return
	_visual_value.text = visual.name
	var profile: ObjectVisualProfile = visual.visual_profile
	if profile == null:
		_profile_value.text = ""
		_profile_value.tooltip_text = ""
		_default_state_value.text = ""
		_clear_states()
		_status_label.text = "该视觉节点尚未配置视觉配置文件。"
		return
	_profile_value.text = _resource_path(profile)
	_profile_value.tooltip_text = _profile_value.text
	_default_state_value.text = String(profile.default_state_id)
	_show_states(profile)
	_status_label.text = "以下为只读展示，如需修改请直接编辑对应的视觉配置文件资源。"


## 枚举视觉配置文件的真实 states 数组，每个 VisualStateTexture 建立独立 HBox 行。
## profile 为当前资源；无返回值；不调用会修改资源的方法；切换目标先清空再按当前顺序重建。
func _show_states(profile: ObjectVisualProfile) -> void:
	_clear_states()
	if profile.states.is_empty():
		var empty_label := Label.new()
		empty_label.text = "<无状态>"
		_states_box.add_child(empty_label)
		return
	for state: VisualStateTexture in profile.states:
		_add_state_row(state, profile)


## 为单个 VisualStateTexture 构建一行：state_id + 默认标记 + 纹理文件名。
## 完整资源路径写入 tooltip；缺失纹理显示明确提示；不修改任何状态资源。
func _add_state_row(state: VisualStateTexture, profile: ObjectVisualProfile) -> void:
	var state_id_text := "<null>"
	var is_default := false
	var texture_filename := "缺失纹理"
	var full_path := ""

	if state != null:
		state_id_text = String(state.state_id)
		is_default = state.state_id == profile.default_state_id
		if state.world_texture != null:
			var rpath: String = state.world_texture.resource_path
			if rpath == "":
				texture_filename = "<内存资源>"
				full_path = "<内存资源>"
			else:
				full_path = rpath
				texture_filename = rpath.get_file()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var id_label := Label.new()
	id_label.text = state_id_text
	id_label.clip_text = true
	id_label.custom_minimum_size.x = 64
	row.add_child(id_label)

	var default_marker := Label.new()
	default_marker.text = "[默认]" if is_default else ""
	default_marker.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	row.add_child(default_marker)

	var tex_label := Label.new()
	tex_label.text = texture_filename
	tex_label.clip_text = true
	tex_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	tex_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(tex_label)

	# 完整路径放 tooltip，行与文件名均可悬停查看，避免长路径撑爆窄 Dock。
	if full_path != "":
		row.tooltip_text = full_path
		tex_label.tooltip_text = full_path

	_states_box.add_child(row)


## 只读统计直属正式视觉子节点数量（与 Resolver 同语义，仅用于挑选提示文案）。
## selected 为当前单选节点；返回直属 ObjectVisualView 数量；不递归、不计 EmissionPreview。
func _count_direct_visuals(selected: Node) -> int:
	if selected == null or not is_instance_valid(selected):
		return 0
	var count := 0
	for child: Node in selected.get_children():
		if child is EmissionPreview:
			continue
		if child is ObjectVisualView:
			count += 1
	return count


## 清空目标与状态展示。
## message 为提示文本；无返回值；保留当前选择字段由调用方按需覆盖。
func _clear_details(message: String) -> void:
	_ensure_ui()
	_visual_value.text = ""
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
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
## resource 可为空；返回资源路径、内存资源标记或空串；无副作用。
func _resource_path(resource: Resource) -> String:
	if resource == null:
		return ""
	if resource.resource_path == "":
		return "<内存资源>"
	return resource.resource_path
