@tool
extends VBoxContainer

# Objective Condition / Group Editor 面板（Guide §13/§15/§16，AF-09）：
# 目标条件（目标下拉只列 objective_target 域正式对象；条件下拉只列已声明条件类型，
# form_condition 的 allowed_forms 用形态勾选）与跨目标组（Simultaneous / Sequence、≥2 成员、
# Required、完成 Window）。应用 = 整域校验 + 一次 meta 事务（可撤销）。
# 不做 Objective Graph（Non-goal）；成员多选 = 目标列表多选。


const _ObjectiveData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/objective_data_service.gd"
)
const _ObjectiveConditionDefinition: GDScript = preload(
	"res://gameplay/objectives/objective_condition_definition.gd"
)
const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)

const PANEL_KEY: String = "objective"

const _FORM_NAMES: Array[String] = ["光线 RAY", "光粒 PARTICLE"]

var _ctx: Object = null
var _conditions: Dictionary = {}
var _groups: Array = []
var _target_options: OptionButton
var _condition_list: ItemList
var _condition_type_options: OptionButton
var _color_options: OptionButton
var _form_checks: Array[CheckBox] = []
var _group_list: ItemList
var _group_type_options: OptionButton
var _required_check: CheckBox
var _window_spin: SpinBox
var _member_list: ItemList
var _targets: Array[Dictionary] = []


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "Objective（目标条件与组）"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	var target_row := HBoxContainer.new()
	target_row.add_child(_label("目标"))
	_target_options = OptionButton.new()
	_target_options.item_selected.connect(func(_i): _reload_condition_widgets())
	target_row.add_child(_target_options)
	_condition_type_options = OptionButton.new()
	target_row.add_child(_condition_type_options)
	for form: String in _FORM_NAMES:
		var check := CheckBox.new()
		check.text = form
		_form_checks.append(check)
		target_row.add_child(check)
	_color_options = OptionButton.new()
	_color_options.custom_minimum_size = Vector2(72, 0)
	target_row.add_child(_color_options)
	target_row.add_child(_button("添加条件", _on_add_condition))
	add_child(target_row)
	_condition_list = ItemList.new()
	_condition_list.custom_minimum_size = Vector2(0, 56)
	add_child(_condition_list)
	var condition_row := HBoxContainer.new()
	condition_row.add_child(_button("移除所选条件", _on_remove_condition))
	add_child(condition_row)
	var group_row := HBoxContainer.new()
	group_row.add_child(_label("组类型"))
	_group_type_options = OptionButton.new()
	for name_entry: String in _ObjectiveData.GROUP_TYPE_NAMES:
		_group_type_options.add_item(name_entry)
	_required_check = CheckBox.new()
	_required_check.text = "Required"
	group_row.add_child(_required_check)
	_window_spin = _spin("Window秒", 0.1, 600.0, 30.0)
	group_row.add_child(_window_spin)
	group_row.add_child(_button("添加组（成员=多选）", _on_add_group))
	add_child(group_row)
	_member_list = ItemList.new()
	_member_list.custom_minimum_size = Vector2(0, 56)
	_member_list.select_mode = ItemList.SELECT_MULTI
	add_child(_member_list)
	_group_list = ItemList.new()
	_group_list.custom_minimum_size = Vector2(0, 56)
	add_child(_group_list)
	var apply_row := HBoxContainer.new()
	apply_row.add_child(_button("移除所选组", _on_remove_group))
	apply_row.add_child(_button("应用", _on_apply))
	add_child(apply_row)


func refresh() -> void:
	var root: Node2D = _ctx.edited_root()
	_conditions = _ObjectiveData.read_conditions(root) if root != null else {}
	_groups = _ObjectiveData.read_groups(root) if root != null else []
	_targets = _target_entries()
	_target_options.clear()
	for target: Dictionary in _targets:
		_target_options.add_item("%s（%s）" % [target.display_name, target.stable_id])
		_target_options.set_item_metadata(-1, target.stable_id)
	if _target_options.item_count > 0 and _target_options.selected < 0:
		_target_options.select(0)
	_condition_type_options.clear()
	for option: Dictionary in _ObjectiveData.get_condition_type_options():
		_condition_type_options.add_item(option.display_name)
		_condition_type_options.set_item_metadata(-1, option.condition_type_id)
	if _condition_type_options.item_count > 0 and _condition_type_options.selected < 0:
		_condition_type_options.select(0)
	_color_options.clear()
	for option: Dictionary in _ObjectiveData.get_target_color_options():
		_color_options.add_item(option.name)
		_color_options.set_item_metadata(-1, option.value)
	if _color_options.item_count > 0 and _color_options.selected < 0:
		_color_options.select(0)
	_member_list.clear()
	for target: Dictionary in _targets:
		_member_list.add_item("%s（%s）" % [target.display_name, target.stable_id])
		_member_list.set_item_metadata(-1, target.stable_id)
	_reload_condition_widgets()
	_reload_group_list()


func _target_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry: Dictionary in _ctx.get_object_index():
		if entry.domain == &"objective_target":
			entries.append(entry)
	return entries


func _reload_condition_widgets() -> void:
	_condition_list.clear()
	var target_id := _selected_target_id()
	for entry: Variant in (_conditions.get(target_id, []) as Array):
		var type_id := str(entry.get("condition_type_id", ""))
		if type_id == String(_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION):
			_condition_list.add_item("%s（颜色 %s）" % [type_id, _color_display_name(int(entry.get("target_color", -1)))])
			continue
		var forms: Array = []
		for form_variant: Variant in entry.get("allowed_forms", []):
			forms.append(str(int(form_variant)))
		_condition_list.add_item("%s（形态 %s）" % [type_id, "|".join(forms)])


## 目标颜色值 → 显示名（红/绿/蓝；越界值显示原始数字，与校验错误清单一致）。
func _color_display_name(color_value: int) -> String:
	var names: Array[String] = _ObjectiveData.TARGET_COLOR_NAMES
	var colors: Array[int] = _ObjectiveConditionDefinition.get_valid_target_colors()
	if colors.has(color_value):
		return names[colors.find(color_value)]
	return str(color_value)


func _reload_group_list() -> void:
	_group_list.clear()
	for group: Variant in _groups:
		_group_list.add_item("%s · %s%s · %d成员 · %.1fs" % [
			_ObjectiveData.GROUP_TYPE_NAMES[int(group.get("group_type", 0))],
			"Required" if bool(group.get("required", false)) else "Optional",
			(group.get("member_ids", []) as Array).size(),
			float(group.get("window_seconds", 0.0))])


func _selected_target_id() -> String:
	if _target_options.selected < 0:
		return ""
	return str(_target_options.get_item_metadata(_target_options.selected))


func _selected_condition_index() -> int:
	var selected := _condition_list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _selected_group_index() -> int:
	var selected := _group_list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _on_add_condition() -> void:
	var target_id := _selected_target_id()
	if target_id.is_empty():
		_ctx.log_message("场景内没有 objective_target 域目标（先放置水晶类目标）。")
		return
	if _condition_type_options.selected < 0:
		_ctx.log_message("没有已声明的条件类型。")
		return
	var type_id: String = _condition_type_options.get_item_metadata(_condition_type_options.selected)
	var bucket: Array = _conditions.get(target_id, [])
	for entry: Variant in bucket:
		if str(entry.get("condition_type_id")) == type_id:
			_ctx.log_message("目标 %s 已挂条件 %s（同类型单目标最多一次）。" % [target_id, type_id])
			return
	if type_id == String(_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION):
		if _color_options.selected < 0:
			_ctx.log_message("color_condition 需选择目标颜色。")
			return
		bucket.append({
			"condition_type_id": type_id,
			"target_color": int(_color_options.get_item_metadata(_color_options.selected)),
		})
		_conditions[target_id] = bucket
		_reload_condition_widgets()
		return
	var allowed: Array[int] = []
	for index: int in _form_checks.size():
		if _form_checks[index].button_pressed:
			allowed.append(index)
	if allowed.is_empty():
		_ctx.log_message("form_condition 需勾选至少一个允许光形态。")
		return
	bucket.append({"condition_type_id": type_id, "allowed_forms": allowed})
	_conditions[target_id] = bucket
	_reload_condition_widgets()


func _on_remove_condition() -> void:
	var index := _selected_condition_index()
	if index < 0:
		_ctx.log_message("请先选择一条条件。")
		return
	var target_id := _selected_target_id()
	var bucket: Array = _conditions.get(target_id, [])
	bucket.remove_at(index)
	if bucket.is_empty():
		_conditions.erase(target_id)
	else:
		_conditions[target_id] = bucket
	_reload_condition_widgets()


func _on_add_group() -> void:
	var members: Array = []
	for index: int in _member_list.get_selected_items():
		members.append(str(_member_list.get_item_metadata(index)))
	if members.size() < 2:
		_ctx.log_message("Composite Group 至少 2 成员（在目标列表多选）。")
		return
	_groups.append({
		"group_type": _group_type_options.selected,
		"member_ids": members,
		"required": _required_check.button_pressed,
		"window_seconds": float(_window_spin.value),
	})
	_reload_group_list()


func _on_remove_group() -> void:
	var index := _selected_group_index()
	if index < 0:
		_ctx.log_message("请先选择一个组。")
		return
	_groups.remove_at(index)
	_reload_group_list()


func _on_apply() -> void:
	var object_index: Array[Dictionary] = _ctx.get_object_index()
	var problems: PackedStringArray = _ObjectiveData.validate_conditions(_conditions, object_index)
	problems.append_array(_ObjectiveData.validate_groups(_groups, object_index))
	if not problems.is_empty():
		_ctx.log_message("Objective 校验未通过：%s" % "；".join(problems))
		return
	var committed: bool = _ctx.commit_meta(_ObjectiveData.META_CONDITIONS, _conditions, "配置 Objective 条件")
	if committed and _ctx.commit_meta(_ObjectiveData.META_GROUPS, _groups, "配置 Objective 组"):
		_ctx.log_message("Objective 已应用（%d 目标条件 / %d 组，Ctrl+S 保存关卡生效）。" % [_conditions.size(), _groups.size()])


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _spin(suffix: String, min_value: float, max_value: float, value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = 0.1
	spin.value = value
	spin.suffix = suffix
	spin.custom_minimum_size = Vector2(110, 0)
	return spin
