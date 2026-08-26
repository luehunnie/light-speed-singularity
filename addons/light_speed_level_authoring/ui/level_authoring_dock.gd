@tool
extends VBoxContainer

# AF-08/09 Level Authoring Dock（Guide §2.3）：轻量关卡内容辅助唯一 UI 入口（多入口单 Dock）。
# AF-09 起按 AF-08 记录的拆分触发条件改为面板组合根：本文件只做面板装配、共享上下文与
# 选择/拾取转发；全部编辑器能力在 ui/panels/ 各职责面板与 authoring/ 服务内。
# 边界：标准地图绘制仍用 Godot TileMap、对象移动仍用 Godot 2D、对象配置仍用 Inspector。
# 可测性：编辑器桥（open_scene / get_current_scene_path / get_edited_level_root /
#   play_current_level）与撤销管理器注入，headless 测试注入替身即可驱动全部按钮路径。
# 2D Pick（Guide §26 P0）：拾取 = 编辑器点选视口对象触发 EditorSelection（既有信号链），
#   面板先 arm_pick 进入待拾取态，下一次选择即回填对应槽位（不自绘视口覆盖层）。


const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _EditorTransaction: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_transaction.gd"
)
const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
# 正式对象两类基脚本（PlaceableToken / GridPlacedObject 派生链；与 StableIdService 口径一致）。
const _PlaceableTokenScript: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _GridPlacedObjectScript: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)

# 面板装配表（顺序即 Dock 自上而下顺序）。
const _PANEL_SCRIPTS: Array[GDScript] = [
	preload("res://addons/light_speed_level_authoring/ui/panels/level_tools_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/map_assist_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/content_palette_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/inventory_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/objective_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/control_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/rules_panel.gd"),
	preload("res://addons/light_speed_level_authoring/ui/panels/presentation_panel.gd"),
]

var _undo_redo: Object = null
var _editor_bridge: Object = null
var _registry = null
var _object_index: Array[Dictionary] = []
var _pick_slot: String = ""
var _pick_receiver: Object = null

var _panels: Dictionary = {}
var _log_output: RichTextLabel
# 日志环形缓冲（上限 200 行）：headless 测试观察面——RichTextLabel 脱树/无帧时不解析文本，
# UI 显示与 get_log_text() 读同一份事实。
var _log_lines: PackedStringArray = PackedStringArray()
var _selected_formal_nodes: Array[Node] = []


func _ready() -> void:
	_build_ui()
	refresh_all()


# ===== 注入面（插件接线 / headless 测试替身）=====

func set_undo_redo(undo_redo: Object) -> void:
	_undo_redo = undo_redo


func set_editor_bridge(bridge: Object) -> void:
	_editor_bridge = bridge


# 选择变化通知（EditorSelection 转发）：先供 2D Pick 待拾取面板消费，未消费再广播给面板。
func notify_selection_changed(selected_nodes: Array) -> void:
	var formal := _filter_formal(selected_nodes)
	_selected_formal_nodes = formal
	if _pick_receiver != null and not formal.is_empty():
		var entry := _index_entry_for(formal[0])
		if entry == {}:
			entry = {"stable_id": str(formal[0].get("stable_instance_id")), "type_id": &"",
				"display_name": "", "node": formal[0]}
		_pick_receiver.call("receive_pick", _pick_slot, entry)
		_disarm_pick()
		return
	for panel: Variant in _panels.values():
		if panel.has_method("on_selection_changed"):
			panel.call("on_selection_changed", formal)


# ===== 共享上下文（面板 duck-typed 调用面）=====

func log_message(message: String) -> void:
	_log_lines.append(message)
	if _log_lines.size() > 200:
		_log_lines.remove_at(0)
	_log_output.append_text("%s\n" % message)


# 只读日志文本（headless 测试观察面）。
func get_log_text() -> String:
	return "\n".join(_log_lines)


func edited_root() -> Node2D:
	if _editor_bridge == null or not _editor_bridge.has_method("get_edited_level_root"):
		return null
	var root: Variant = _editor_bridge.call("get_edited_level_root")
	return root if root is Node2D else null


func get_registry():
	if _registry == null:
		_registry = _PaletteService.build_registry()
	return _registry


# 正式对象索引（缓存到下一次 refresh_all；面板复用同一份，避免逐面板重复扫描）。
func get_object_index() -> Array[Dictionary]:
	return _object_index


# 面板通用 meta 事务：do=set_meta 新值 / undo=恢复旧值（旧值缺省时撤销为移除该 meta）。
func commit_meta(key: String, new_value: Variant, action_name: String) -> bool:
	var root := edited_root()
	if root == null:
		log_message("请先打开一个关卡场景。")
		return false
	var operations: Array = [{
		"target": root,
		"do": ["set_meta", [key, new_value.duplicate(true)]],
		"undo": (["remove_meta", [key]] if not root.has_meta(key)
				else ["set_meta", [key, root.get_meta(key).duplicate(true)]]),
	}]
	return _EditorTransaction.commit(_undo_redo, action_name, operations)


# 面板通用属性事务（发射器初始配置等节点字段写入）。
func commit_properties(target: Object, do_properties: Array, undo_properties: Array, action_name: String) -> bool:
	return _EditorTransaction.commit(_undo_redo, action_name,
			[{"target": target, "do": [], "undo": [], "do_properties": do_properties,
				"undo_properties": undo_properties}])


# 2D Pick 待拾取态（slot 由面板自定；receiver 须实现 receive_pick(slot, entry: Dictionary)）。
func arm_pick(slot: String, receiver: Object) -> void:
	_pick_slot = slot
	_pick_receiver = receiver
	log_message("2D 拾取中：请在 2D 视口点击一个正式对象（%s）。再次点击拾取按钮可取消。" % slot)


func _disarm_pick() -> void:
	_pick_slot = ""
	_pick_receiver = null


# 全面板刷新（重扫对象索引；面板从 meta 重载 widgets）。
func refresh_all() -> void:
	_object_index = _BusinessData.build_object_index(edited_root(), get_registry())
	for panel: Variant in _panels.values():
		if panel.has_method("refresh"):
			panel.call("refresh")


# ===== 桥接小工具（面板调用面）=====

func _bridge_scene_path() -> String:
	if _editor_bridge == null or not _editor_bridge.has_method("get_current_scene_path"):
		return ""
	var value: Variant = _editor_bridge.call("get_current_scene_path")
	return str(value) if value != null else ""


func _bridge_open_scene(path: String) -> void:
	if _editor_bridge != null and _editor_bridge.has_method("open_scene"):
		_editor_bridge.callv("open_scene", [path])


func _bridge_play_current_level() -> void:
	if _editor_bridge != null and _editor_bridge.has_method("play_current_level"):
		_editor_bridge.call("play_current_level")


# 撤销管理器访问（面板事务用；null = 直发无撤销模式）。
func _get_undo_redo() -> Object:
	return _undo_redo


func _on_undo_pressed() -> void:
	if _undo_redo == null:
		log_message("未注入撤销管理器。")
		return
	# UndoRedo（headless/游戏模式）直接 undo；EditorUndoRedoManager（真实编辑器）无 undo()，
	# 须定位当前关卡历史的内层 UndoRedo 再撤销（否则编辑器内按钮静默报错失效）。
	if _undo_redo.has_method("undo"):
		_undo_redo.undo()
		return
	if not _undo_redo.has_method("get_history_undo_redo"):
		log_message("撤销失败：撤销管理器无 undo 能力（类型 %s）。"
			% _undo_redo.get_class())
		return
	var root := edited_root()
	if root == null:
		log_message("撤销失败：当前场景不是关卡（无法定位编辑历史）。")
		return
	var history_id: int = _undo_redo.get_object_history_id(root)
	_undo_redo.get_history_undo_redo(history_id).undo()


# 最近一次选择的正式对象（快照副本；面板“使用当前所选”入口）。
func _last_selected_formal() -> Array[Node]:
	return _selected_formal_nodes.duplicate()


# 场景内主发射器节点（Rules 面板 Initial 配置入口；无则 null）。
func _find_emitter_node() -> Node:
	return _BusinessData.find_emitter(edited_root())


# ===== 装配 =====

func _build_ui() -> void:
	# AF-09 GUI Gate：八面板总高远超 Dock 可视高度，必须经 ScrollContainer 滚动可达
	#（鼠标滚轮 + 滚动条），否则 Rules/Presentation 等下半部控件不可点击；刷新行与日志固定在滚动区外常驻可见。
	var scroll := ScrollContainer.new()
	scroll.name = "PanelScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	add_child(scroll)
	for panel_script: GDScript in _PANEL_SCRIPTS:
		var panel: Control = panel_script.new()
		_panels[panel.get("PANEL_KEY")] = panel
		content.add_child(panel)
		panel.call("setup", self)
	var refresh_row := HBoxContainer.new()
	var refresh_button := Button.new()
	refresh_button.text = "刷新业务面板"
	refresh_button.pressed.connect(refresh_all)
	refresh_row.add_child(refresh_button)
	add_child(refresh_row)
	_log_output = RichTextLabel.new()
	_log_output.custom_minimum_size = Vector2(0, 90)
	_log_output.scroll_following = true
	add_child(_log_output)


# 按面板键取面板（测试与跨面板协作入口）。
func get_panel(key: String) -> Control:
	return _panels.get(key)


# ===== 小工具 =====

# 过滤出正式对象（PlaceableToken / GridPlacedObject 派生链 Node2D）。
func _filter_formal(selected_nodes: Array) -> Array[Node]:
	var formal: Array[Node] = []
	for entry: Variant in selected_nodes:
		if entry is Node2D and ((entry as Node2D) is _PlaceableTokenScript
				or (entry as Node2D) is _GridPlacedObjectScript):
			formal.append(entry)
	return formal


# 对象索引中该节点的条目（无条目返回空字典）。
func _index_entry_for(node: Node) -> Dictionary:
	for entry: Dictionary in _object_index:
		if entry.node == node:
			return entry
	return {}
