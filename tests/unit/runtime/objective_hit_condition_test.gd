extends SceneTree

## AF-04 / P0-6 定向测试 1/3：ObjectiveHitContext + 条件三件套（Definition / Configuration / Evaluator）+ ObjectiveTarget。
## 覆盖：命中事实构造校验（Ray/Particle 双形态 / speed_tier 域 / 非法拒绝）、条件类型注册表可枚举（Editor/Validator 不硬编码名单）、
## 配置 Schema 拒绝（未知类型 / 空参数 / 越界 / 去重）、求值器 SATISFIED / NOT_SATISFIED（Base Success 与 FormCondition 两形态）、
## Target 组合语义（AND / 同类型最多一次 / 空条件 Base Success）、求值器源码纯度扫描（不得查询 Runtime / 扫 World）。
## 纯 RefCounted 域测试：不建水晶、不进场景树节点、不读引擎时钟。


const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")
const _ObjectiveConditionConfiguration: GDScript = preload("res://gameplay/objectives/objective_condition_configuration.gd")
const _ObjectiveConditionEvaluator: GDScript = preload("res://gameplay/objectives/objective_condition_evaluator.gd")
const _ObjectiveTarget: GDScript = preload("res://gameplay/objectives/objective_target.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	_test_01_hit_context_ray()
	_test_02_hit_context_particle()
	_test_03_hit_context_rejects_invalid()
	_test_04_condition_registry_enumerable()
	_test_05_condition_registry_unknown()
	_test_06_configuration_validation()
	_test_07_configuration_dedup()
	_test_08_evaluator_form_condition()
	_test_09_evaluator_safe_fail()
	_test_10_evaluator_source_purity()
	_test_11_target_base_success()
	_test_12_target_form_condition()
	_test_13_target_rejects_duplicate_type()
	_test_14_target_rejects_invalid()
	_test_15_target_success_lifecycle()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造 Ray 命中事实（D 向 = (1,0)，emission 7，gen 3）。
func _ray_hit(cell: Vector2i) -> _ObjectiveHitContext:
	var hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_ray(cell, Vector2i(1, 0), 7, 3)
	return hit


## 构造 Particle 命中事实（STANDARD 档）。
func _particle_hit(cell: Vector2i) -> _ObjectiveHitContext:
	var hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_particle(cell, Vector2i(0, 1), 9, 4, 1)
	return hit


## 1. Ray 命中事实：字段只读且 speed_tier 为哨兵。
func _test_01_hit_context_ray() -> void:
	const NAME: String = "01_Ray命中事实"
	var hit: _ObjectiveHitContext = _ray_hit(Vector2i(2, 3))
	_check(NAME, hit != null, "Ray 命中应构造成功。")
	if hit == null:
		return
	_check(NAME, hit.get_cell() == Vector2i(2, 3), "cell 应为 (2,3)。")
	_check(NAME, hit.get_incoming_direction() == Vector2i(1, 0), "入射方向应为 (1,0)。")
	_check(NAME, hit.get_light_form() == _LightEmissionTypes.LightForm.RAY, "形态应为 RAY。")
	_check(NAME, hit.get_emission_id() == 7, "emission_id 应为 7。")
	_check(NAME, hit.get_runtime_generation() == 3, "runtime_generation 应为 3。")
	_check(NAME, hit.get_speed_tier() == _ObjectiveHitContext.RAY_SPEED_TIER_NONE, "Ray 命中 speed_tier 应为哨兵 -1。")


## 2. Particle 命中事实：speed_tier 域内值合法（SLOW/STANDARD/FAST），三档均可构造。
func _test_02_hit_context_particle() -> void:
	const NAME: String = "02_Particle命中事实"
	var hit: _ObjectiveHitContext = _particle_hit(Vector2i(4, 5))
	_check(NAME, hit != null, "Particle 命中应构造成功。")
	if hit == null:
		return
	_check(NAME, hit.get_light_form() == _LightEmissionTypes.LightForm.PARTICLE, "形态应为 PARTICLE。")
	_check(NAME, hit.get_speed_tier() == 1, "速度档位应为 STANDARD=1。")
	var slow_hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_particle(Vector2i(0, 0), Vector2i(1, 0), 1, 1, 0)
	_check(NAME, slow_hit != null, "档位 SLOW=0 应合法。")
	var fast_hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_particle(Vector2i(0, 0), Vector2i(1, 0), 1, 1, 2)
	_check(NAME, fast_hit != null, "档位 FAST=2 应合法。")


## 3. 非法命中拒绝：非法方向 / 非法速度档位。
func _test_03_hit_context_rejects_invalid() -> void:
	const NAME: String = "03_命中事实非法拒绝"
	_check(NAME, _ObjectiveHitContext.create_for_ray(Vector2i(0, 0), Vector2i(2, 0), 1, 1) == null, "非法方向 (2,0) 应拒绝。")
	_check(NAME, _ObjectiveHitContext.create_for_ray(Vector2i(0, 0), Vector2i.ZERO, 1, 1) == null, "零方向应拒绝。")
	_check(NAME, _ObjectiveHitContext.create_for_particle(Vector2i(0, 0), Vector2i(1, 0), 1, 1, -1) == null, "PARTICLE 档位 -1 应拒绝。")
	_check(NAME, _ObjectiveHitContext.create_for_particle(Vector2i(0, 0), Vector2i(1, 0), 1, 1, 3) == null, "PARTICLE 档位 3 应拒绝。")


## 4. 条件类型注册表可枚举：form_condition 已声明且五要素齐备（显示名 / 参数 / 可作用目标类型）。
func _test_04_condition_registry_enumerable() -> void:
	const NAME: String = "04_条件注册表可枚举"
	var declared: Array = _ObjectiveConditionDefinition.get_all_declared()
	_check(NAME, declared.size() >= 1, "注册表应至少声明一种条件类型。")
	var found: bool = false
	for definition_variant: Variant in declared:
		var definition: _ObjectiveConditionDefinition = definition_variant as _ObjectiveConditionDefinition
		if definition.get_condition_type_id() == _ObjectiveConditionDefinition.TYPE_FORM_CONDITION:
			found = true
			_check(NAME, definition.get_display_name() != "", "form_condition 应有显示名。")
			_check(NAME, definition.get_applicable_target_domains().has(&"objective_target"), "form_condition 应可作用于 objective_target 域。")
			_check(NAME, definition.get_param_ids().has(_ObjectiveConditionDefinition.PARAM_ALLOWED_FORMS), "form_condition 应声明 allowed_forms 参数。")
			_check(NAME, definition.is_applicable_to_target_domain(&"objective_target"), "对 objective_target 域应适用。")
	_check(NAME, found, "注册表应包含 form_condition。")
	_check(NAME, _ObjectiveConditionDefinition.get_valid_light_forms() == [0, 1], "合法光形态集合应为 [RAY, PARTICLE]。")


## 5. 未知条件类型：注册表查找返回 null（Editor/Validator 据此拒绝，不硬编码名单）。
func _test_05_condition_registry_unknown() -> void:
	const NAME: String = "05_未知条件类型拒绝"
	_check(NAME, _ObjectiveConditionDefinition.get_by_type_id(&"not_a_condition") == null, "未知类型应返回 null。")
	_check(NAME, _ObjectiveConditionDefinition.get_by_type_id(&"") == null, "空类型应返回 null。")
	_check(NAME, _ObjectiveConditionDefinition.get_by_type_id(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION) != null, "form_condition 应可查得。")


## 6. 配置校验：未知类型 / 空 allowed_forms / 越界形态值拒绝。
func _test_06_configuration_validation() -> void:
	const NAME: String = "06_配置Schema拒绝"
	var forms: Array = [0]
	_check(NAME, _ObjectiveConditionConfiguration.create(&"not_a_condition", forms) == null, "未知类型应拒绝。")
	_check(NAME, _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, []) == null, "空 allowed_forms 应拒绝。")
	_check(NAME, _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, [5]) == null, "越界形态值 5 应拒绝。")
	var both: Array = [0, 1]
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, both)
	_check(NAME, configuration != null, "[RAY, PARTICLE] 应构造成功。")
	if configuration != null:
		_check(NAME, configuration.get_allowed_forms() == [0, 1], "allowed_forms 读回应为 [0,1]。")


## 7. 配置去重：重复形态值合并为单值。
func _test_07_configuration_dedup() -> void:
	const NAME: String = "07_配置参数去重"
	var duplicated: Array = [0, 0]
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, duplicated)
	_check(NAME, configuration != null, "重复值应可构造。")
	if configuration != null:
		_check(NAME, configuration.get_allowed_forms() == [0], "重复值应去重为 [0]。")
		_check(NAME, configuration.allows_light_form(0), "RAY 应被允许。")
		_check(NAME, not configuration.allows_light_form(1), "PARTICLE 不应被允许。")


## 8. 求值器：FormCondition 四象限 + 双形态 OR 参数。
func _test_08_evaluator_form_condition() -> void:
	const NAME: String = "08_求值器四象限"
	var ray_only: Array = [0]
	var ray_configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, ray_only)
	var particle_only: Array = [1]
	var particle_configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, particle_only)
	var both: Array = [0, 1]
	var both_configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, both)
	var ray_hit: _ObjectiveHitContext = _ray_hit(Vector2i.ZERO)
	var particle_hit: _ObjectiveHitContext = _particle_hit(Vector2i.ZERO)
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(ray_configuration, ray_hit) == _ObjectiveConditionEvaluator.Verdict.SATISFIED, "RAY 条件 × RAY 命中应 SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(ray_configuration, particle_hit) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "RAY 条件 × PARTICLE 命中应 NOT_SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(particle_configuration, particle_hit) == _ObjectiveConditionEvaluator.Verdict.SATISFIED, "PARTICLE 条件 × PARTICLE 命中应 SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(particle_configuration, ray_hit) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "PARTICLE 条件 × RAY 命中应 NOT_SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(both_configuration, ray_hit) == _ObjectiveConditionEvaluator.Verdict.SATISFIED, "双形态条件 × RAY 命中应 SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(both_configuration, particle_hit) == _ObjectiveConditionEvaluator.Verdict.SATISFIED, "双形态条件 × PARTICLE 命中应 SATISFIED。")


## 9. 求值器安全失败：非法输入（非配置 / 非命中）按 NOT_SATISFIED，不崩溃。
func _test_09_evaluator_safe_fail() -> void:
	const NAME: String = "09_求值器安全失败"
	var foreign: RefCounted = RefCounted.new()
	var ray_hit: _ObjectiveHitContext = _ray_hit(Vector2i.ZERO)
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(foreign, ray_hit) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "非配置输入应 NOT_SATISFIED。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(null, ray_hit) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "null 配置应 NOT_SATISFIED。")
	var forms: Array = [0]
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, forms)
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, foreign) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "非命中输入应 NOT_SATISFIED。")


## 10. 求值器源码纯度：不得出现 Runtime / World 访问标识（冻结 Guide B §25.3）。
func _test_10_evaluator_source_purity() -> void:
	const NAME: String = "10_求值器源码纯度"
	var source: String = FileAccess.get_file_as_string("res://gameplay/objectives/objective_condition_evaluator.gd")
	for forbidden: String in ["ParticleScheduler", "LevelWorldQuery", "LevelRuntimeController", "get_tree", "get_node", "get_parent", "add_child", "find_children", "ray_world", "light_world"]:
		_check(NAME, source.find(forbidden) == -1, "求值器源码不得包含 %s。" % [forbidden])


## 11. Target Base Success：空条件列表，任何形态命中均通过。
func _test_11_target_base_success() -> void:
	const NAME: String = "11_Target空条件BaseSuccess"
	var target: _ObjectiveTarget = _ObjectiveTarget.create(&"t_base", Vector2i(1, 1), true, [])
	_check(NAME, target != null, "空条件目标应构造成功。")
	if target == null:
		return
	_check(NAME, target.get_condition_count() == 0, "条件数应为 0。")
	_check(NAME, target.get_target_id() == &"t_base", "目标 ID 应读回。")
	_check(NAME, target.get_cell() == Vector2i(1, 1), "目标格应读回。")
	_check(NAME, target.is_required(), "required 应读回 true。")
	_check(NAME, target.evaluate_hit(_ray_hit(Vector2i(1, 1))), "Base Success 应接受 RAY 命中。")
	_check(NAME, target.evaluate_hit(_particle_hit(Vector2i(1, 1))), "Base Success 应接受 PARTICLE 命中。")


## 12. Target FormCondition：仅匹配形态通过（Guide B §25.2 Ray/Particle 形态目标示例）。
func _test_12_target_form_condition() -> void:
	const NAME: String = "12_Target光形态条件"
	var forms: Array = [_LightEmissionTypes.LightForm.RAY]
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, forms)
	var conditions: Array = [configuration]
	var target: _ObjectiveTarget = _ObjectiveTarget.create(&"t_ray", Vector2i(2, 2), true, conditions)
	_check(NAME, target != null, "形态条件目标应构造成功。")
	if target == null:
		return
	_check(NAME, target.get_condition_count() == 1, "条件数应为 1。")
	_check(NAME, target.evaluate_hit(_ray_hit(Vector2i(2, 2))), "RAY 形态目标应接受 RAY 命中。")
	_check(NAME, not target.evaluate_hit(_particle_hit(Vector2i(2, 2))), "RAY 形态目标应拒绝 PARTICLE 命中。")
	_check(NAME, not target.evaluate_hit(null), "null 命中应拒绝。")


## 13. 同类型条件最多一次：重复类型构造拒绝。
func _test_13_target_rejects_duplicate_type() -> void:
	const NAME: String = "13_同类型条件最多一次"
	var forms_a: Array = [0]
	var forms_b: Array = [1]
	var first: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, forms_a)
	var second: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, forms_b)
	var conditions: Array = [first, second]
	_check(NAME, _ObjectiveTarget.create(&"t_dup", Vector2i(3, 3), true, conditions) == null, "同类型两次应拒绝构造。")


## 14. 非法成员拒绝：空 ID / 非条件对象。
func _test_14_target_rejects_invalid() -> void:
	const NAME: String = "14_Target非法拒绝"
	_check(NAME, _ObjectiveTarget.create(&"", Vector2i(0, 0), true, []) == null, "空目标 ID 应拒绝。")
	var foreign: Array = [RefCounted.new()]
	_check(NAME, _ObjectiveTarget.create(&"t_bad", Vector2i(0, 0), true, foreign) == null, "非条件对象成员应拒绝。")


## 15. 成功生命周期：登记 / 读回 / 重置。
func _test_15_target_success_lifecycle() -> void:
	const NAME: String = "15_成功生命周期"
	var target: _ObjectiveTarget = _ObjectiveTarget.create(&"t_life", Vector2i(4, 4), false, [])
	_check(NAME, target != null, "目标应构造成功。")
	if target == null:
		return
	_check(NAME, not target.has_success(), "初始应无成功记录。")
	_check(NAME, target.get_last_success_at() == _ObjectiveTarget.NO_SUCCESS, "初始成功时间应为哨兵。")
	_check(NAME, not target.is_required(), "required=false 应读回。")
	target.register_success(12.5)
	_check(NAME, target.has_success(), "登记后应有成功记录。")
	_check(NAME, target.get_last_success_at() == 12.5, "成功时间应读回 12.5。")
	target.register_success(20.0)
	_check(NAME, target.get_last_success_at() == 20.0, "重复登记应刷新时间。")
	target.reset_runtime()
	_check(NAME, not target.has_success(), "重置后应无成功记录。")
	_check(NAME, target.get_last_success_at() == _ObjectiveTarget.NO_SUCCESS, "重置后成功时间应为哨兵。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 15
	var passed_checks: int = _checks - _failures.size()
	print("objective_hit_condition_test： %d/%d 组通过，%d/%d 断言通过。" % [group_count - _failures.size(), group_count, passed_checks, _checks])
	if not _failures.is_empty():
		for failure: String in _failures:
			print("  失败：%s" % [failure])
