@tool
extends VBoxContainer

## 美术资源 Dock（D4.5-C1-Fix 编辑版）。
## 职责：展示当前选择、Resolver 解析出的可替换视觉集合、Profile 字段与多目标选择器，
##       把状态选择 / 应用 / 保存委托给 ProfileActionPanel，把素材浏览委托给 ArtAssetBrowserView。
## 输入输出：由 plugin.gd 传入选择数组；用户交互产生替换 / 保存；本 Dock 无返回值。
## 副作用：仅重建 Dock 内控件；替换与保存均交由子面板内的服务走正式 Undo/Redo 与写盘。
## 边界：Dock 只做 UI 编排与只读边界暴露，不直接改写 Profile 字段、不扫描素材、不重新加载图片；
##       解析规则全部在 Resolver；多目标返回结果而非 null；切换目标 / Profile 清除旧状态选择，不静默选中第一项；
##       不暴露内部数组或控件节点给外部；reason_code 不直接显示给用户，由本 Dock / 子面板映射为中文提示。
## 布局：根 VBox[标题, VSplitContainer]，VSplit 上半为 Profile 编辑器 ScrollContainer（独立滚动），
##       下半为美术资产浏览器；分隔线可拖动，上下区域都保留最小高度，互不挤占可见区。

const _VisualTargetResolver: GDScript = preload("res://addons/light_speed_art_profile/target/visual_target_resolver.gd")
const _VisualTargetResult: GDScript = preload("res://addons/light_speed_art_profile/target/visual_target_result.gd")
const _BrowserViewScript: GDScript = preload("res://addons/light_speed_art_profile/browser/art_asset_browser_view.gd")
# 子面板与新增服务通过 preload 引用，规避新 class_name 全局缓存未重建时的类型解析问题。
const _ActionPanelScript: GDScript = preload("res://addons/light_speed_art_profile/dock/profile_action_panel.gd")
const _TilesetPanelScript: GDScript = preload("res://addons/light_speed_art_profile/tileset/tileset_replace_panel.gd")

var _resolver: RefCounted = _VisualTargetResolver.new()

var _selected_value: Label = null
var _component_value: Label = null
var _visual_value: Label = null
var _profile_value: Label = null
var _default_state_value: Label = null
var _status_label: Label = null
var _target_selector_label: Label = null
var _target_selector: OptionButton = null
# 以基类型 VBoxContainer 持有子面板，避免引用尚未进入全局缓存的新 class_name（见 MCP 新 class_name 缓存坑）。
var _action_panel: VBoxContainer = null
# TileSet 图集整套替换子面板（TileSet 美术工作流 v1）；同样以基类型鸭子类型调用。
var _tileset_panel: VBoxContainer = null
# ObjectVisual 专属字段控件（标题+值成对登记）：TileMapLayer 模式下整体隐藏，实现两区互斥。
var _objectvisual_field_controls: Array = []
var _browser_view: LightSpeedArtProfileArtAssetBrowserView = null
# 由 plugin.gd 注入的真实编辑器 UndoRedo 管理器；子面板创建时一并转交，不在此处自行查找编辑器单例。
var _editor_undo_redo = null


## 初始化 Dock 控件树。
## 无参数无返回；副作用是创建标题、上下可拖动分隔的 VSplit、Profile 字段、操作子面板与浏览器。
func _ready() -> void:
	_ensure_ui()
	_action_panel.clear_action()
	# 初始互斥状态：无选择即隐藏 TileSet 面板，等待 plugin 首个选择快照再切换。
	if _tileset_panel != null and is_instance_valid(_tileset_panel):
		_tileset_panel.visible = false
	_clear_details("请先在场景树中选择一个对象。")


## 注入编辑器 UndoRedo 管理器并转发给操作子面板；由 plugin.gd 在启用/禁用时调用。
## undo_redo 为 EditorPlugin.get_undo_redo() 返回的真实管理器，传入 null 表示清空引用。无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo
	if _action_panel != null and is_instance_valid(_action_panel):
		_action_panel.set_editor_undo_redo(undo_redo)
	if _tileset_panel != null and is_instance_valid(_tileset_panel):
		_tileset_panel.set_editor_undo_redo(undo_redo)


## 注入当前编辑场景根提供器并转发给操作子面板；由 plugin.gd 在启用时调用。
## cb 无参数，返回当前编辑场景根 Node 或 null；同 Profile 多实例刷新与创建绑定使用。无返回值。
func set_scene_root_provider(cb: Callable) -> void:
	if _action_panel != null and is_instance_valid(_action_panel):
		_action_panel.set_scene_root_provider(cb)


## 接收插件传入的当前选择并刷新展示。
## selected_nodes 是 EditorSelection 快照；无返回值；只读解析，切换对象时清除旧编辑状态。
## 路由：单选真实 TileMapLayer（is 判定覆盖脚本子类）优先进入 TileSet 替换模式，
##       隐藏 ObjectVisual 专属区且不走 Resolver 的 UNSUPPORTED 路径；
##       其余选择（含父 Node2D 猜子节点、空选、多选）恢复 ObjectVisual 区并清空 TileSet 面板。
func show_selection(selected_nodes: Array) -> void:
	_ensure_ui()
	_clear_target_selector()
	_action_panel.clear_action()
	var single: Node = selected_nodes[0] as Node if selected_nodes.size() == 1 else null
	# is 判定同时覆盖继承 TileMapLayer 的脚本子类；只认选中节点自身，不把 Node2D 父节点当 TileMap。
	var tilemap_mode: bool = single != null and is_instance_valid(single) and single is TileMapLayer
	_set_objectvisual_area_visible(not tilemap_mode)
	# TileSet 面板与 ObjectVisual 区互斥显示；非 TileMapLayer 选择清空其目标与一次性确认 token。
	if _tileset_panel != null and is_instance_valid(_tileset_panel):
		_tileset_panel.visible = tilemap_mode
		_tileset_panel.show_selection_node(single if tilemap_mode else null)
	if tilemap_mode:
		_selected_value.text = single.name
		_clear_details("已选择 TileMapLayer；在下方 TileSet 区域输入新纹理路径并分析影响。")
		return
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
	_apply_result(selected, _resolver.resolve(selected))


## 按 Resolver 结果状态分发展示。
## selected 为当前单选节点；result 为只读 VisualTargetResult；无返回值。
func _apply_result(selected: Node, result: RefCounted) -> void:
	var status: int = result.get_status()
	match status:
		_VisualTargetResult.Status.SINGLE_TARGET:
			_show_single_target(selected, result)
		_VisualTargetResult.Status.MULTIPLE_TARGETS:
			_show_multiple_targets(selected, result)
		_VisualTargetResult.Status.NO_TARGET:
			_show_no_target(selected, result)
		_:
			_show_unsupported(selected, result)


## 展示唯一目标：当前对象、所属组件、视觉及其 Profile 与状态列表。
## 若选中节点是 EmissionPreview，追加冻结的预览定位提示；只读枚举 visual_profile.states。
func _show_single_target(selected: Node, result: RefCounted) -> void:
	_set_component_field(result.get_component_root())
	var primary: ObjectVisualView = result.get_primary_target() as ObjectVisualView
	if not is_instance_valid(primary):
		_clear_details("解析出的视觉节点已释放，请重新选择一个对象。")
		return
	_set_visual_fields(primary)
	_action_panel.show_for_view(primary)
	if primary.visual_profile == null:
		_status_label.text = "该视觉节点尚未配置视觉配置文件；可在下方选择素材后创建并绑定。"
	elif selected is EmissionPreview:
		_status_label.text = "该节点用于发射方向预览。已为你定位到所属发射器的正式视觉。"
	else:
		_status_label.text = "选择一个状态与素材后可替换图片；替换可 Ctrl+Z 撤销。"


## 展示多目标：当前对象、所属组件、目标选择器；默认不静默选第一个。
# 每个条目显示相对组件根的节点路径，节点名称仅用于展示；目标节点存入 OptionButton 元数据。
func _show_multiple_targets(selected: Node, result: RefCounted) -> void:
	_set_component_field(result.get_component_root())
	_visual_value.text = "（多个）"
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
	_action_panel.clear_action()
	_action_panel.refresh_shared_hint_for(null)
	var component_root: Node = result.get_component_root()
	var targets: Array = result.get_targets()
	_target_selector_label.visible = true
	_target_selector.visible = true
	_target_selector.clear()
	for index in range(targets.size()):
		var target: ObjectVisualView = targets[index] as ObjectVisualView
		if not is_instance_valid(target):
			continue
		var display_path: String = "(自身)"
		if component_root != null and is_instance_valid(component_root):
			display_path = String(component_root.get_path_to(target))
		var idx: int = _target_selector.item_count
		_target_selector.add_item(display_path)
		_target_selector.set_item_metadata(idx, target)
	# 默认不选第一个，等待用户明确选择；不修改场景或资源。
	_target_selector.select(-1)
	if selected is EmissionPreview:
		_status_label.text = "该节点用于发射方向预览。已为你定位到所属发射器的正式视觉，请从上方选择一个正式视觉。"
	else:
		_status_label.text = "该组件包含多个可替换视觉，请先选择一个正式视觉。"


## 用户在多目标选择器中选定一个目标后展示其 Profile 与状态。
## index 为 OptionButton 选中索引；无返回值；切换目标清除旧状态选择，不修改场景或资源。
func _on_target_selected(index: int) -> void:
	if index < 0 or index >= _target_selector.item_count:
		return
	var target: ObjectVisualView = _target_selector.get_item_metadata(index) as ObjectVisualView
	if not is_instance_valid(target):
		return
	# 切换视觉目标：清除旧状态选择，避免把上一目标的 state_id 误用到新目标。
	_action_panel.clear_state_selection()
	_set_visual_fields(target)
	_action_panel.show_for_view(target)
	_status_label.text = "选择一个状态与素材后可替换图片；替换可 Ctrl+Z 撤销。"


## 展示无目标（组件无正式视觉）：只读提示，不展示内部 reason_code。
func _show_no_target(selected: Node, result: RefCounted) -> void:
	_set_component_field(result.get_component_root())
	_visual_value.text = ""
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
	_action_panel.clear_action()
	_action_panel.refresh_shared_hint_for(null)
	_status_label.text = "当前组件尚未接入统一视觉配置，暂时不能在此面板替换美术。"


## 展示不支持（无组件边界等）：只读中文提示，不展示内部 reason_code。
func _show_unsupported(selected: Node, result: RefCounted) -> void:
	_component_value.text = ""
	_component_value.tooltip_text = ""
	_visual_value.text = ""
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
	_action_panel.clear_action()
	_action_panel.refresh_shared_hint_for(null)
	_status_label.text = "当前节点不属于可编辑的关卡组件。请直接选择一个视觉节点，或选择继承 GridPlacedObject 的组件。"


## 只读边界：返回当前激活的 ObjectVisualView；未选择具体视觉目标时返回 null。
func get_active_visual_target() -> ObjectVisualView:
	if _action_panel == null or not is_instance_valid(_action_panel):
		return null
	return _action_panel.get_active_visual_target()


## 只读边界：返回用户在状态列表中明确选择的状态 ID；未选择返回空 StringName。
func get_selected_state_id() -> StringName:
	if _action_panel == null or not is_instance_valid(_action_panel):
		return &""
	return _action_panel.get_selected_state_id()


## 只读边界：返回浏览器当前选中 ArtAssetEntry；无选择或失效时返回 null。不暴露内部数组。
func get_selected_art_entry() -> LightSpeedArtProfileArtAssetEntry:
	if _browser_view == null or not is_instance_valid(_browser_view):
		return null
	return _browser_view.get_selected_entry() as LightSpeedArtProfileArtAssetEntry


## 写入所属组件字段；节点名称仅用于展示，完整路径写入 tooltip。
func _set_component_field(component_root: Node) -> void:
	if component_root == null or not is_instance_valid(component_root):
		_component_value.text = ""
		_component_value.tooltip_text = ""
		return
	_component_value.text = component_root.name
	# 仅在节点位于场景树时取完整路径写入 tooltip，避免对游离节点调用 get_path 报错。
	if component_root.is_inside_tree():
		_component_value.tooltip_text = String(component_root.get_path())
	else:
		_component_value.tooltip_text = ""


## 写入可替换视觉、视觉配置文件、默认状态字段；profile 缺失时清空对应字段。不修改 status。
func _set_visual_fields(visual: ObjectVisualView) -> void:
	_visual_value.text = visual.name
	var profile: ObjectVisualProfile = visual.visual_profile
	if profile == null:
		_profile_value.text = ""
		_profile_value.tooltip_text = ""
		_default_state_value.text = ""
		return
	_profile_value.text = _resource_path(profile)
	_profile_value.tooltip_text = _profile_value.text
	_default_state_value.text = String(profile.default_state_id)


## 创建一次性 UI 结构；重复调用安全。
## 无参数无返回；仅在控件缺失时创建 Dock 子节点：标题 + VSplit(上半滚动, 下半浏览器)。
func _ensure_ui() -> void:
	if _action_panel != null and is_instance_valid(_action_panel):
		return
	# 仅约束宽度，不强制高度：避免 Dock 内容被固定大像素撑出可见区。
	custom_minimum_size = Vector2(360, 0)
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "光速奇点：美术资源"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	# VSplit：上为 Profile 编辑器独立滚动区，下为美术浏览器；分隔线可拖动，两区都保留最小高度。
	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(split)
	# 上半区：独立滚动，承载字段、多目标选择器、状态与编辑控件，绝不向外膨胀挤占浏览器。
	var upper_scroll := ScrollContainer.new()
	upper_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	upper_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upper_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	upper_scroll.custom_minimum_size.y = 240
	split.add_child(upper_scroll)
	var profile_section := VBoxContainer.new()
	profile_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_section.add_theme_constant_override("separation", 6)
	upper_scroll.add_child(profile_section)
	# 主上下文字段置于顶部，便于用户确认正在编辑的对象与视觉。
	_selected_value = _add_field(profile_section, "当前对象")
	_visual_value = _add_field(profile_section, "可替换视觉", true)
	# 多目标选择器：默认隐藏，仅 MULTIPLE_TARGETS 时显示。
	_target_selector_label = Label.new()
	_target_selector_label.text = "该组件包含多个可替换视觉，请选择："
	_target_selector_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target_selector_label.visible = false
	profile_section.add_child(_target_selector_label)
	_target_selector = OptionButton.new()
	_target_selector.visible = false
	_target_selector.item_selected.connect(Callable(self, "_on_target_selected"))
	profile_section.add_child(_target_selector)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	profile_section.add_child(_status_label)
	# 操作子面板：状态选择 + 应用 + 保存确认 + 操作引导；浏览器素材经只读提供器注入。
	# 以基类型 VBoxContainer 持有，方法调用走鸭子类型；不引用新 class_name 以规避缓存坑。
	_action_panel = _ActionPanelScript.new() as VBoxContainer
	_action_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action_panel.set_browser_entry_provider(Callable(self, "get_selected_art_entry"))
	# 把已注入的 UndoRedo 管理器转交给子面板；若插件尚未注入（测试场景）则保持 null，由子面板明确报失败。
	_action_panel.set_editor_undo_redo(_editor_undo_redo)
	profile_section.add_child(_action_panel)
	_action_panel._ensure_ui()
	# TileSet 图集替换面板：同一滚动区内最小装配，业务与守卫全部在面板/服务内。
	_tileset_panel = _TilesetPanelScript.new() as VBoxContainer
	_tileset_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tileset_panel.set_editor_undo_redo(_editor_undo_redo)
	profile_section.add_child(_tileset_panel)
	# 诊断字段置于底部：所属组件 / 视觉配置文件 / 默认状态，不挤占顶部状态选择区。
	_component_value = _add_field(profile_section, "所属组件", true)
	_profile_value = _add_field(profile_section, "视觉配置文件", true)
	_default_state_value = _add_field(profile_section, "默认状态", true)
	# 下半区：美术资产浏览器，保留自身最小高度，与上方视觉配置隔离。
	_browser_view = _BrowserViewScript.new() as LightSpeedArtProfileArtAssetBrowserView
	_browser_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_browser_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 浏览器选中变化时重算应用按钮启用条件（只读回调，不修改 Entry）。
	_browser_view.selection_changed.connect(Callable(self, "_on_browser_selection_changed"))
	split.add_child(_browser_view)


## 浏览器选中变化回调：委托子面板重算应用按钮启用条件。无返回；只读评估。
func _on_browser_selection_changed() -> void:
	if _action_panel != null and is_instance_valid(_action_panel):
		_action_panel.refresh_apply_controls()


## 新增一组字段标签。
## parent 为字段所属容器；title 为字段名；hideable 标记 ObjectVisual 专属字段（随模式互斥整体隐藏）；
## 返回可后续写入的值 Label。
## 值 Label 使用 clip_text + 省略号，长路径截断显示、完整内容交由 tooltip，杜绝窄 Dock 逐字符竖排。
func _add_field(parent: Control, title: String, hideable: bool = false) -> Label:
	var name_label := Label.new()
	name_label.text = title
	parent.add_child(name_label)
	var value_label := Label.new()
	value_label.clip_text = true
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.text = ""
	parent.add_child(value_label)
	if hideable:
		_objectvisual_field_controls.append(name_label)
		_objectvisual_field_controls.append(value_label)
	return value_label


## ObjectVisual 专属区互斥可见性：TileMapLayer 模式下整体隐藏（字段对 + 操作子面板），
## 其余选择恢复显示；目标选择器由 _clear_target_selector 单独管理。
## visible_now 为目标可见状态；无返回值；只改 Dock 内控件 visible，不改数据、不触发信号。
func _set_objectvisual_area_visible(visible_now: bool) -> void:
	for control: Control in _objectvisual_field_controls:
		if is_instance_valid(control):
			control.visible = visible_now
	if _action_panel != null and is_instance_valid(_action_panel):
		_action_panel.visible = visible_now


## 清空目标与状态展示。
## message 为提示文本；无返回值；保留当前选择字段由调用方按需覆盖。
func _clear_details(message: String) -> void:
	_ensure_ui()
	_component_value.text = ""
	_component_value.tooltip_text = ""
	_visual_value.text = ""
	_profile_value.text = ""
	_profile_value.tooltip_text = ""
	_default_state_value.text = ""
	_status_label.text = message
	_action_panel.clear_action()


## 清空多目标选择器：清条目并隐藏，避免上一选择残留。
## 无参数无返回；不释放选择器控件本身。
func _clear_target_selector() -> void:
	if _target_selector == null or not is_instance_valid(_target_selector):
		return
	_target_selector.clear()
	_target_selector.select(-1)
	_target_selector.visible = false
	if _target_selector_label != null and is_instance_valid(_target_selector_label):
		_target_selector_label.visible = false


## 取得资源路径显示文本。
## resource 可为空；返回资源路径、内存资源标记或空串；无副作用。
func _resource_path(resource: Resource) -> String:
	if resource == null:
		return ""
	if resource.resource_path == "":
		return "<内存资源>"
	return resource.resource_path
