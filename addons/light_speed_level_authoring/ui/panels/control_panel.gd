@tool
extends VBoxContainer

# Control Connection Editor 面板（Guide §26 / §32，AF-09）：连接的无代码配置。
# Source / Target 经 2D Pick（点“拾取”后在 2D 视口点选正式对象，EditorSelection 链回填稳定 ID，
# 不使用 Node.name / NodePath / 坐标作身份）；Event / Action 下拉只列对端 Definition 已声明条目
# （不硬编码名单）；Params 按动作 schema 生成 Typed 输入（BOOL → CheckBox / INT → SpinBox）。
# 添加 = 整域校验（含五元组去重）+ 一次 meta 事务（可撤销）。


const _ControlData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/control_data_service.gd"
)

const PANEL_KEY: String = "control"

var _ctx: Object = null
var _connections: Array = []
var _connection_list: ItemList
var _source_label: Label
var _target_label: Label
var _source_entry: Dictionary = {}
var _target_entry: Dictionary = {}
var _event_options: OptionButton
var _action_options: OptionButton
var _params_row: HBoxContainer
var _param_widgets: Array = []


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "Control（连接）"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	_connection_list = ItemList.new()
	_connection_list.custom_minimum_size = Vector2(0, 64)
	add_child(_connection_list)
	var source_row := HBoxContainer.new()
	source_row.add_child(_button("2D 拾取 Source", func(): _ctx.arm_pick("source", self)))
	_source_label = _label("（未拾取）")
	source_row.add_child(_source_label)
	_event_options = OptionButton.new()
	source_row.add_child(_event_options)
	add_child(source_row)
	var target_row := HBoxContainer.new()
	target_row.add_child(_button("2D 拾取 Target", func(): _ctx.arm_pick("target", self)))
	_target_label = _label("（未拾取）")
	target_row.add_child(_target_label)
	_action_options = OptionButton.new()
	_action_options.item_selected.connect(func(_i): _rebuild_param_widgets())
	target_row.add_child(_action_options)
	add_child(target_row)
	_params_row = HBoxContainer.new()
	add_child(_params_row)
	var action_row := HBoxContainer.new()
	action_row.add_child(_button("添加连接", _on_add_connection))
	action_row.add_child(_button("移除所选", _on_remove_connection))
	action_row.add_child(_button("应用", _on_apply))
	add_child(action_row)


# 2D Pick 回填（Dock 选择转发；slot = source / target）。
func receive_pick(slot: String, entry: Dictionary) -> void:
	if slot == "source":
		_source_entry = entry
		_source_label.text = "%s（%s）" % [entry.get("display_name", ""), entry.get("stable_id", "")]
		_reload_event_options()
	elif slot == "target":
		_target_entry = entry
		_target_label.text = "%s（%s）" % [entry.get("display_name", ""), entry.get("stable_id", "")]
		_reload_action_options()


func refresh() -> void:
	var root: Node2D = _ctx.edited_root()
	_connections = _ControlData.read_connections(root) if root != null else []
	_reload_connection_list()


func _reload_connection_list() -> void:
	_connection_list.clear()
	for connection: Variant in _connections:
		_connection_list.add_item("%s·%s → %s·%s" % [
			connection.get("source_stable_id", ""), connection.get("event_id", ""),
			connection.get("target_stable_id", ""), connection.get("action_id", "")])


# Source / Target 变更后重载对端声明下拉。
func _reload_event_options() -> void:
	_event_options.clear()
	for option: Dictionary in _ControlData.get_event_options(_source_entry.get("type_id", &""), _ctx.get_registry()):
		_event_options.add_item(option.display_name)
		_event_options.set_item_metadata(-1, option.event_id)


func _reload_action_options() -> void:
	_action_options.clear()
	for option: Dictionary in _ControlData.get_action_options(_target_entry.get("type_id", &""), _ctx.get_registry()):
		_action_options.add_item(option.display_name)
		_action_options.set_item_metadata(-1, option)
	if _action_options.item_count > 0:
		_action_options.select(0)
	_rebuild_param_widgets()


# 按所选动作 schema 生成 Typed 参数输入（BOOL → CheckBox / INT → SpinBox）。
func _rebuild_param_widgets() -> void:
	for widget: Node in _param_widgets:
		widget.queue_free()
	_param_widgets = []
	if _action_options.selected < 0:
		return
	var option: Dictionary = _action_options.get_item_metadata(_action_options.selected)
	var label := _label("Params:")
	_params_row.add_child(label)
	_param_widgets.append(label)
	for schema_entry: Variant in option.get("param_schema", []):
		var param_id: String = schema_entry.get("param_id")
		if String(schema_entry.get("value_type")) == "BOOL":
			var check := CheckBox.new()
			check.text = param_id
			_params_row.add_child(check)
			_param_widgets.append(check)
		else:
			var spin := SpinBox.new()
			spin.min_value = -9999
			spin.max_value = 9999
			spin.suffix = param_id
			spin.custom_minimum_size = Vector2(110, 0)
			_params_row.add_child(spin)
			_param_widgets.append(spin)


func _collect_params() -> Dictionary:
	var params := {}
	if _action_options.selected < 0:
		return params
	var option: Dictionary = _action_options.get_item_metadata(_action_options.selected)
	var schema: Array = option.get("param_schema", [])
	var index := 0
	for schema_entry: Variant in schema:
		var param_id: String = schema_entry.get("param_id")
		var widget: Control = _param_widgets[index + 1]
		if widget is CheckBox:
			params[param_id] = (widget as CheckBox).button_pressed
		elif widget is SpinBox:
			params[param_id] = int((widget as SpinBox).value)
		index += 1
	return params


func _on_add_connection() -> void:
	if _source_entry.is_empty() or _target_entry.is_empty():
		_ctx.log_message("请先 2D 拾取 Source 与 Target。")
		return
	if _event_options.selected < 0 or _action_options.selected < 0:
		_ctx.log_message("Source / Target 没有已声明的事件 / 动作（声明由机关定义提供）。")
		return
	var event_id: String = _event_options.get_item_metadata(_event_options.selected)
	var action_option: Dictionary = _action_options.get_item_metadata(_action_options.selected)
	_connections.append({
		"source_stable_id": str(_source_entry.get("stable_id", "")),
		"event_id": event_id,
		"target_stable_id": str(_target_entry.get("stable_id", "")),
		"action_id": str(action_option.get("action_id", "")),
		"params": _collect_params(),
	})
	_reload_connection_list()


func _on_remove_connection() -> void:
	var selected := _connection_list.get_selected_items()
	if selected.is_empty():
		_ctx.log_message("请先选择一条连接。")
		return
	_connections.remove_at(selected[0])
	_reload_connection_list()


func _on_apply() -> void:
	var problems: PackedStringArray = _ControlData.validate_connections(_connections, _ctx.get_object_index(), _ctx.get_registry())
	if not problems.is_empty():
		_ctx.log_message("Control 连接校验未通过：%s" % "；".join(problems))
		return
	if _ctx.commit_meta(_ControlData.META_CONNECTIONS, _connections, "配置 Control 连接"):
		_ctx.log_message("Control 连接已应用（%d 条，Ctrl+S 保存关卡生效）。" % _connections.size())


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button
