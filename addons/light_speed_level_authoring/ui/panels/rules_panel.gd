@tool
extends VBoxContainer

# General Rules / Main Emitter Level Rules 面板（Guide §87/§88，AF-09）：
# Move Limit（Enable + Maximum Count，不用 -1 Sentinel，禁用时 Count 只读）；
# Allowed Forms（集合即玩家可选范围：1 值无切换、多值可 Cycle，§88.1 不再设 can_switch_form）；
# Allowed Directions（八方向勾选子集，两形态各自独立）；Initial Form / Direction 写发射器节点
# 字段（typed 初始配置）。应用 = 整域校验（含 initial ∈ allowed 一致性）+ meta/属性事务。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)

const PANEL_KEY: String = "rules"

const _FORM_NAMES: Array[String] = ["光线 RAY", "光粒 PARTICLE"]
const _DIRECTION_NAMES: Array[String] = ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]

var _ctx: Object = null
var _move_enabled_check: CheckBox
var _move_limit_spin: SpinBox
var _form_checks: Array[CheckBox] = []
var _ray_checks: Array[CheckBox] = []
var _particle_checks: Array[CheckBox] = []
var _initial_form_options: OptionButton
var _initial_ray_options: OptionButton
var _initial_particle_options: OptionButton


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "General Rules / 发射器规则（运行期移动次数上限在此设置）"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	var move_row := HBoxContainer.new()
	_move_enabled_check = CheckBox.new()
	_move_enabled_check.text = "Move Limit"
	_move_enabled_check.toggled.connect(func(on): _move_limit_spin.editable = on)
	move_row.add_child(_move_enabled_check)
	_move_limit_spin = _spin("上限", 1, 9999, 10)
	_move_limit_spin.editable = false
	move_row.add_child(_move_limit_spin)
	move_row.add_child(_button("应用 Rules", _on_apply))
	add_child(move_row)
	var forms_row := HBoxContainer.new()
	forms_row.add_child(_label("Allowed Forms"))
	for form: String in _FORM_NAMES:
		var check := CheckBox.new()
		check.text = form
		_form_checks.append(check)
		forms_row.add_child(check)
	add_child(forms_row)
	add_child(_direction_row("光线方向", _ray_checks))
	add_child(_direction_row("光粒方向", _particle_checks))
	var initial_row := HBoxContainer.new()
	initial_row.add_child(_label("Initial"))
	_initial_form_options = _option(_FORM_NAMES)
	initial_row.add_child(_initial_form_options)
	_initial_ray_options = _option(_DIRECTION_NAMES)
	initial_row.add_child(_initial_ray_options)
	_initial_particle_options = _option(_DIRECTION_NAMES)
	initial_row.add_child(_initial_particle_options)
	initial_row.add_child(_button("应用 Emitter", _on_apply_emitter))
	add_child(initial_row)


func refresh() -> void:
	var root: Node2D = _ctx.edited_root()
	var move_limit: Dictionary = _BusinessData.read_move_limit(root) if root != null \
			else {"enabled": false, "max_count": 1}
	_move_enabled_check.set_pressed_no_signal(bool(move_limit["enabled"]))
	_move_limit_spin.value = int(move_limit["max_count"])
	_move_limit_spin.editable = bool(move_limit["enabled"])
	var rules: Dictionary = _BusinessData.read_emitter_rules(root) if root != null \
			else _BusinessData.read_emitter_rules(null)
	for index: int in _form_checks.size():
		_form_checks[index].set_pressed_no_signal((rules["allowed_forms"] as Array).has(index))
	for index: int in _ray_checks.size():
		_ray_checks[index].set_pressed_no_signal((rules["allowed_ray_directions"] as Array).has(index))
		_particle_checks[index].set_pressed_no_signal((rules["allowed_particle_directions"] as Array).has(index))
	_sync_initial_from_node()


# 从场景发射器节点回填 Initial 下拉（无发射器时保持缺省）。
func _sync_initial_from_node() -> void:
	var emitter: Node = _ctx._find_emitter_node()
	if emitter == null:
		return
	_initial_form_options.select(int(emitter.get("default_light_form")))
	_initial_ray_options.select(int(emitter.get("ray_default_direction")))
	_initial_particle_options.select(int(emitter.get("particle_default_direction")))


func _direction_row(title: String, checks: Array[CheckBox]) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_label(title))
	for direction: String in _DIRECTION_NAMES:
		var check := CheckBox.new()
		check.text = direction
		check.toggle_mode = true
		checks.append(check)
		row.add_child(check)
	return row


func _collect_rules() -> Dictionary:
	var forms: Array = []
	for index: int in _form_checks.size():
		if _form_checks[index].button_pressed:
			forms.append(index)
	var ray: Array = []
	var particle: Array = []
	for index: int in _ray_checks.size():
		if _ray_checks[index].button_pressed:
			ray.append(index)
		if _particle_checks[index].button_pressed:
			particle.append(index)
	return {
		"allowed_forms": forms,
		"allowed_ray_directions": ray,
		"allowed_particle_directions": particle,
	}


func _on_apply() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	var move_limit := {
		"enabled": _move_enabled_check.button_pressed,
		"max_count": int(_move_limit_spin.value),
	}
	var rules := _collect_rules()
	var problems: PackedStringArray = _BusinessData.validate_move_limit(move_limit)
	problems.append_array(_BusinessData.validate_emitter_rules(root, rules))
	if not problems.is_empty():
		_ctx.log_message("Rules 校验未通过：%s" % "；".join(problems))
		return
	var committed: bool = _ctx.commit_meta(_BusinessData.META_MOVE_LIMIT, move_limit, "配置 Move Limit")
	if committed and _ctx.commit_meta(_BusinessData.META_EMITTER_RULES, rules, "配置发射器关卡规则"):
		_ctx.log_message("General Rules / 发射器规则已应用（Ctrl+S 保存关卡生效）。")


# 应用 Initial Form / Direction：写入场景发射器节点字段（typed 初始配置，属性事务可撤销）。
func _on_apply_emitter() -> void:
	var emitter: Node = _ctx._find_emitter_node()
	if emitter == null:
		_ctx.log_message("场景内没有主发射器（EmitterConfigNode）。")
		return
	var rules := _collect_rules()
	var initial_form: int = _initial_form_options.selected
	if not initial_form in (rules["allowed_forms"] as Array):
		_ctx.log_message("Initial Form 不在 Allowed Forms 内（§88.1：initial 必须属于 allowed 集合）。")
		return
	if initial_form == 0 and not _initial_ray_options.selected in (rules["allowed_ray_directions"] as Array):
		_ctx.log_message("Initial 光线方向不在 Allowed Directions 内（§88.2）。")
		return
	if initial_form == 1 and not _initial_particle_options.selected in (rules["allowed_particle_directions"] as Array):
		_ctx.log_message("Initial 光粒方向不在 Allowed Directions 内（§88.2）。")
		return
	var do_properties: Array = [
		["default_light_form", _initial_form_options.selected],
		["ray_default_direction", _initial_ray_options.selected],
		["particle_default_direction", _initial_particle_options.selected],
	]
	var undo_properties: Array = [
		["default_light_form", emitter.get("default_light_form")],
		["ray_default_direction", emitter.get("ray_default_direction")],
		["particle_default_direction", emitter.get("particle_default_direction")],
	]
	if _ctx.commit_properties(emitter, do_properties, undo_properties, "配置发射器初始形态与方向"):
		_ctx.log_message("发射器初始配置已写入节点字段（Ctrl+S 保存关卡生效）。")


func _option(names: Array) -> OptionButton:
	var options := OptionButton.new()
	for name_entry: String in names:
		options.add_item(name_entry)
	if options.item_count > 0:
		options.select(0)
	return options


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
	spin.value = value
	spin.suffix = suffix
	spin.custom_minimum_size = Vector2(96, 0)
	return spin
