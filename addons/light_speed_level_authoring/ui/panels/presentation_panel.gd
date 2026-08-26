@tool
extends VBoxContainer

# Presentation / Text Editor 面板（Guide §78/§80，AF-09）：关卡级集中玩家文案
# （Title / Intro / Objective 覆盖文案 / Hint / Completion）与 Tutorial / Hint Trigger 列表
# （文本 + 正式触发器下拉 + 显示样式 + 纯视觉持续时间；不提供自由脚本 / 表达式）。
# 应用 = 整域校验 + 一次 meta 事务（可撤销）。对象自身 Editor Note 不进本面板（Guide §78）。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)

const PANEL_KEY: String = "presentation"

# 文案五键（Guide §78 冻结域；Label → 单行，其余多行）。
const _TEXT_FIELDS: Array[String] = ["title", "intro", "objective", "hint", "completion"]
const _FIELD_TITLES: Array[String] = ["标题 Title", "介绍 Intro", "目标文案 Objective", "提示 Hint", "完成文案 Completion"]

var _ctx: Object = null
var _text_inputs: Dictionary = {}
var _triggers: Array = []
var _trigger_list: ItemList
var _trigger_text: LineEdit
var _trigger_options: OptionButton
var _style_input: LineEdit
var _duration_spin: SpinBox


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "Presentation / Text"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	for index: int in _TEXT_FIELDS.size():
		var row := HBoxContainer.new()
		row.add_child(_label(_FIELD_TITLES[index]))
		if index == 0:
			var input := LineEdit.new()
			input.custom_minimum_size = Vector2(0, 0)
			input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(input)
			_text_inputs[_TEXT_FIELDS[index]] = input
		else:
			var input := TextEdit.new()
			input.custom_minimum_size = Vector2(0, 40)
			row.add_child(input)
			_text_inputs[_TEXT_FIELDS[index]] = input
		add_child(row)
	_trigger_list = ItemList.new()
	_trigger_list.custom_minimum_size = Vector2(0, 52)
	add_child(_trigger_list)
	var trigger_row := HBoxContainer.new()
	_trigger_text = LineEdit.new()
	_trigger_text.placeholder_text = "提示文本"
	_trigger_text.custom_minimum_size = Vector2(120, 0)
	trigger_row.add_child(_trigger_text)
	_trigger_options = OptionButton.new()
	for trigger_id: String in _BusinessData.TUTORIAL_TRIGGER_IDS:
		_trigger_options.add_item(trigger_id)
		_trigger_options.set_item_metadata(-1, trigger_id)
	if _trigger_options.item_count > 0:
		_trigger_options.select(0)
	trigger_row.add_child(_trigger_options)
	_style_input = LineEdit.new()
	_style_input.text = "toast"
	_style_input.custom_minimum_size = Vector2(72, 0)
	trigger_row.add_child(_style_input)
	_duration_spin = SpinBox.new()
	_duration_spin.min_value = 0.5
	_duration_spin.max_value = 120.0
	_duration_spin.step = 0.5
	_duration_spin.value = 4.0
	_duration_spin.suffix = "秒"
	_duration_spin.custom_minimum_size = Vector2(84, 0)
	trigger_row.add_child(_duration_spin)
	trigger_row.add_child(_button("添加触发", _on_add_trigger))
	add_child(trigger_row)
	var apply_row := HBoxContainer.new()
	apply_row.add_child(_button("移除所选触发", _on_remove_trigger))
	apply_row.add_child(_button("应用", _on_apply))
	add_child(apply_row)


func refresh() -> void:
	var root: Node2D = _ctx.edited_root()
	var presentation: Dictionary = _BusinessData.read_presentation(root) if root != null \
			else _BusinessData.read_presentation(null)
	for field: String in _TEXT_FIELDS:
		var input: Control = _text_inputs[field]
		if input is LineEdit:
			(input as LineEdit).text = presentation.get(field, "")
		else:
			(input as TextEdit).text = presentation.get(field, "")
	_triggers = _BusinessData.read_tutorials(root) if root != null else []
	_reload_trigger_list()


func _reload_trigger_list() -> void:
	_trigger_list.clear()
	for entry: Variant in _triggers:
		_trigger_list.add_item("[%s] %s（%s · %.1f秒）" % [entry.get("trigger_id", ""),
			(str(entry.get("text", "")).left(24)), entry.get("display_style", ""),
			float(entry.get("duration_seconds", 0.0))])


func _on_add_trigger() -> void:
	if _trigger_text.text.is_empty():
		_ctx.log_message("教学触发文本为空。")
		return
	if _trigger_options.selected < 0:
		_ctx.log_message("没有已正式声明的触发器。")
		return
	_triggers.append({
		"text": _trigger_text.text,
		"trigger_id": str(_trigger_options.get_item_metadata(_trigger_options.selected)),
		"display_style": _style_input.text,
		"duration_seconds": float(_duration_spin.value),
	})
	_reload_trigger_list()


func _on_remove_trigger() -> void:
	var selected := _trigger_list.get_selected_items()
	if selected.is_empty():
		_ctx.log_message("请先选择一条教学触发。")
		return
	_triggers.remove_at(selected[0])
	_reload_trigger_list()


func _on_apply() -> void:
	var presentation := {}
	for field: String in _TEXT_FIELDS:
		var input: Control = _text_inputs[field]
		presentation[field] = (input as LineEdit).text if input is LineEdit else (input as TextEdit).text
	var problems: PackedStringArray = _BusinessData.validate_presentation(presentation)
	problems.append_array(_BusinessData.validate_tutorials(_triggers))
	if not problems.is_empty():
		_ctx.log_message("Presentation 校验未通过：%s" % "；".join(problems))
		return
	var committed: bool = _ctx.commit_meta(_BusinessData.META_PRESENTATION, presentation, "配置 Presentation 文案")
	if committed and _ctx.commit_meta(_BusinessData.META_TUTORIALS, _triggers, "配置教学触发"):
		_ctx.log_message("Presentation 已应用（Ctrl+S 保存关卡生效）。")


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button
