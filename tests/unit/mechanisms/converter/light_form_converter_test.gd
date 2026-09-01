extends SceneTree

## 光形式转换器（LightFormConverter）机关合同定向测试（阶段C-01；需求文档 关卡预置 v0.1 / 玩家道具 v0.1 共用核心）。
## 覆盖：八向朝向 × 八向入射全扫描（RAY→PARTICLE / PARTICLE→RAY 双向；每朝向恰 1 背面 BLOCK + 7 向 FORM_CHANGE，
##   出射恒为本机关朝向——§8.2 方向表）；载荷最小携带（目标形态+输出方向，无速度/颜色/事件效果）；
##   cycle_direction 八次闭合回原向且单步为 CLOCKWISE_ORDER 下一项；非法方向 set_direction/apply_configuration 拒绝保持原向；
##   Typed Configuration 合法应用；运行期零写入不变量（R 不变量：direction 恒为 authored 值）。
## headless extends SceneTree，由 Godot --script 运行；机关为 Node fixture（不进场景树，_ready 不触发），用后 free；
## 失败路径用例会产生预期 push_error 输出，不计入失败。全部失败项收集后统一退出（任一失败 quit(1)）。

const _Converter: GDScript = preload("res://gameplay/mechanisms/converter/light_form_converter.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _Contract: GDScript = preload("res://gameplay/light/interaction/light_interaction_contract.gd")
const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _MechanismConfiguration: GDScript = preload("res://gameplay/content/configuration/mechanism_configuration.gd")
const _MechanismFieldDefinition: GDScript = preload("res://gameplay/content/configuration/mechanism_field_definition.gd")

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_contract_forms_declaration()
	_test_02_ray_seven_direction_sweep()
	_test_03_particle_seven_direction_sweep()
	_test_04_minimal_payload_only()
	_test_05_cycle_direction_closure()
	_test_06_invalid_direction_guards()
	_test_07_apply_configuration_and_zero_write()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## 构造 RAY 交互 Context（cell/emission/generation 为任意合法快照值）。
func _ray_ctx(incoming: Vector2i) -> Variant:
	return preload("res://gameplay/light/interaction/ray_interaction_context.gd").create(Vector2i(2, 0), incoming, 1, 0)


## 构造 PARTICLE 交互 Context（tier STANDARD）。
func _particle_ctx(incoming: Vector2i) -> Variant:
	return preload("res://gameplay/light/interaction/particle_interaction_context.gd").create(Vector2i(2, 0), incoming, 1, 0, 1, 7)


## 构造仅含 direction 字段 schema 的 Typed Configuration（field_id/enum_max 与 Definition 一致）。
func _direction_configuration() -> Variant:
	var field: Variant = _MechanismFieldDefinition.new()
	field.field_id = &"direction"
	field.display_name = "转换朝向"
	field.enum_max = 7
	return _MechanismConfiguration.from_type_defaults([field])


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 光形式转换器机关合同测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)


# ===== 测试 =====

## 01. 契约声明：RAY+PARTICLE 双形态；direction_to_vector 与 CLOCKWISE_ORDER 逐值对齐且无零向量。
func _test_01_contract_forms_declaration() -> void:
	const G: String = "01_契约声明"
	var converter: Variant = _Converter.new()
	_check(G, converter.get_light_interaction_forms() == [&"RAY", &"PARTICLE"], "形态声明应为 RAY+PARTICLE。")
	for value: int in range(8):
		var vec: Vector2i = _Converter.direction_to_vector(value as _Converter.ConverterDirection)
		var expected: Vector2i = _DirectionDomain.to_vector(_DirectionDomain.CLOCKWISE_ORDER[value])
		_check(G, vec == expected and vec != Vector2i.ZERO, "枚举 %d 向量 %s 应与 CLOCKWISE_ORDER[%d] %s 对齐且非零。" % [value, vec, value, expected])
	converter.free()

## 02. RAY 入射全扫描：8 朝向 × 8 入射 = 每朝向 1 背面 BLOCK + 7 向 FORM_CHANGE(PARTICLE, 朝向)（§8.2）。
func _test_02_ray_seven_direction_sweep() -> void:
	const G: String = "02_RAY七向扫描"
	var converter: Variant = _Converter.new()
	for orientation_value: int in range(8):
		converter.set_direction(orientation_value as _Converter.ConverterDirection)
		var out: Vector2i = _Converter.direction_to_vector(orientation_value as _Converter.ConverterDirection)
		var form_change_count: int = 0
		for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
			var incoming: Vector2i = _DirectionDomain.to_vector(token)
			var result: Variant = _Contract.dispatch_ray(converter, _ray_ctx(incoming))
			if incoming == _DirectionDomain.opposite(out):
				_check(G, result.decision == _Result.Decision.BLOCK,
					"朝向 %d 背面入射 %s 应 BLOCK（§8.2）。" % [orientation_value, token])
				_check(G, result.target_form == -1 and result.redirect_direction == Vector2i.ZERO,
					"背面 BLOCK 不得携带转换载荷。")
			else:
				form_change_count += 1
				_check(G, result.decision == _Result.Decision.FORM_CHANGE,
					"朝向 %d 七向入射 %s 应 FORM_CHANGE（实际 %s）。" % [orientation_value, token, result.decision])
				_check(G, result.target_form == _LightEmissionTypes.LightForm.PARTICLE,
					"朝向 %d 入射 %s RAY 目标形态应为 PARTICLE。" % [orientation_value, token])
				_check(G, result.redirect_direction == out,
					"朝向 %d 入射 %s 出射应恒为本机关朝向 %s。" % [orientation_value, token, out])
		_check(G, form_change_count == 7, "朝向 %d FORM_CHANGE 方向数期望 7，实际 %d。" % [orientation_value, form_change_count])
	converter.free()

## 03. PARTICLE 入射全扫描：8 朝向 × 8 入射 = 每朝向 1 背面 BLOCK + 7 向 FORM_CHANGE(RAY, 朝向)（§8.2）。
func _test_03_particle_seven_direction_sweep() -> void:
	const G: String = "03_PARTICLE七向扫描"
	var converter: Variant = _Converter.new()
	for orientation_value: int in range(8):
		converter.set_direction(orientation_value as _Converter.ConverterDirection)
		var out: Vector2i = _Converter.direction_to_vector(orientation_value as _Converter.ConverterDirection)
		for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
			var incoming: Vector2i = _DirectionDomain.to_vector(token)
			var result: Variant = _Contract.dispatch_particle(converter, _particle_ctx(incoming))
			if incoming == _DirectionDomain.opposite(out):
				_check(G, result.decision == _Result.Decision.BLOCK,
					"朝向 %d 背面入射 %s 应 BLOCK（§8.2）。" % [orientation_value, token])
			else:
				_check(G, result.decision == _Result.Decision.FORM_CHANGE
					and result.target_form == _LightEmissionTypes.LightForm.RAY
					and result.redirect_direction == out,
					"朝向 %d 入射 %s 应 FORM_CHANGE(RAY, %s)（实际 %s/%s）。"
					% [orientation_value, token, out, result.decision, result.target_form])
	converter.free()

## 04. 载荷最小携带：FORM_CHANGE 结果无任何 Typed Effects（速度/颜色/事件零携带——转换规则由执行适配层生成）。
func _test_04_minimal_payload_only() -> void:
	const G: String = "04_载荷最小携带"
	var converter: Variant = _Converter.new()
	var result: Variant = _Contract.dispatch_ray(converter, _ray_ctx(Vector2i(0, -1)))
	_check(G, result.effects.is_empty(), "FORM_CHANGE 结果不得携带任何 Typed Effects。")
	_check(G, result.get_speed_delta() == 0, "FORM_CHANGE 不得携带速度增量。")
	_check(G, result.get_output_event_ids().is_empty(), "FORM_CHANGE 不得携带输出事件。")
	_check(G, result.get_color_change() == -1, "FORM_CHANGE 不得携带颜色变更（NONE 哨兵 -1）。")
	converter.free()

## 05. cycle_direction：单步 = CLOCKWISE_ORDER 下一项；八次闭合回原向（玩家道具右键正式入口）。
func _test_05_cycle_direction_closure() -> void:
	const G: String = "05_顺时针轮转闭合"
	var converter: Variant = _Converter.new()
	for start: int in range(8):
		converter.set_direction(start)
		converter.cycle_direction()
		var expected_next: int = (start + 1) % 8
		_check(G, converter.direction == expected_next,
			"起点 %d 顺时针下一步期望 %d，实际 %d。" % [start, expected_next, converter.direction])
	for i: int in range(8):
		converter.cycle_direction()
	_check(G, converter.direction == 0, "自 RIGHT 八次循环后应闭合回 RIGHT（实际 %d）。" % converter.direction)
	converter.free()

## 06. 非法方向守卫：set_direction 越界保持原向；apply_configuration 越界 / 缺字段拒绝且朝向不变。
func _test_06_invalid_direction_guards() -> void:
	const G: String = "06_非法方向守卫"
	var converter: Variant = _Converter.new()
	converter.set_direction(_Converter.ConverterDirection.DOWN)
	converter.set_direction(8 as _Converter.ConverterDirection)
	_check(G, converter.direction == _Converter.ConverterDirection.DOWN, "set_direction(8) 应保持原向 DOWN（预期 push_error）。")
	converter.set_direction(-1 as _Converter.ConverterDirection)
	_check(G, converter.direction == _Converter.ConverterDirection.DOWN, "set_direction(-1) 应保持原向 DOWN（预期 push_error）。")
	var configuration: Variant = _direction_configuration()
	_check(G, converter.apply_configuration(configuration), "默认配置（type defaults）应成功应用。")
	_check(G, converter.direction == _Converter.ConverterDirection.RIGHT, "默认应用后朝向应为字段默认值 RIGHT（0）。")
	_check(G, converter.apply_configuration(null), "null 配置应按契约视为 no-op 成功（加速器同语义）。")
	# 越界值经 apply_override 无法写入（Schema 校验拒绝），机关侧守卫为纵深防御：直写私有值字典构造越界配置。
	var bad_configuration: Variant = _direction_configuration()
	bad_configuration._values_by_field_id[&"direction"] = 9
	_check(G, not converter.apply_configuration(bad_configuration), "apply_configuration 方向越界 9 应拒绝。")
	_check(G, converter.direction == _Converter.ConverterDirection.RIGHT, "越界拒绝后朝向应保持当前 authored 值 RIGHT 不变。")
	var missing_field_configuration: Variant = _MechanismConfiguration.from_type_defaults([])
	_check(G, not converter.apply_configuration(missing_field_configuration), "缺 direction 字段配置应拒绝。")
	_check(G, converter.direction == _Converter.ConverterDirection.RIGHT, "缺字段拒绝后朝向应保持当前 authored 值 RIGHT 不变。")
	converter.free()

## 07. Typed Configuration 合法应用 + 运行期零写入不变量：交互后 direction 恒为 authored 值。
func _test_07_apply_configuration_and_zero_write() -> void:
	const G: String = "07_配置应用与零写入"
	var converter: Variant = _Converter.new()
	var configuration: Variant = _direction_configuration()
	configuration.apply_override(&"direction", 5)
	_check(G, converter.apply_configuration(configuration), "合法 direction=5 配置应成功应用。")
	_check(G, converter.direction == 5, "应用后 direction 应为 5（实际 %d）。" % converter.direction)
	_check(G, _Converter.direction_to_vector(5) == Vector2i(-1, -1), "枚举 5 应对应 UP_LEFT (-1,-1)。")
	# 运行期零写入（R 不变量）：全部交互后 direction 恒为 authored 值。
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		_Contract.dispatch_ray(converter, _ray_ctx(_DirectionDomain.to_vector(token)))
		_Contract.dispatch_particle(converter, _particle_ctx(_DirectionDomain.to_vector(token)))
	_check(G, converter.direction == 5, "运行期交互后 direction 应保持 authored 值 5（实际 %d）。" % converter.direction)
	_check(G, converter.get_light_interaction_forms() == [&"RAY", &"PARTICLE"], "运行期交互后形态声明应保持稳定。")
	converter.free()
