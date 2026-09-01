extends SceneTree

## 光形式转换 FORM_CHANGE 正式结果契约 + 执行链路定向测试（阶段C-01 光形式转换器）。
## 覆盖：LightInteractionResult.FORM_CHANGE 构造/校验（合法八方向+合法 target_form；非法方向/非法目标/越权携带 target_form 拒绝）；
##   RayMechanismAdapter FORM_CHANGE 映射；ParticleMechanismAdapter 映射（continue_motion=false + 载荷透传 + 无速度效果）；
##   RayExecutionModule FORM_CHANGE → MECHANISM_BLOCK 终止 + 转换载荷 + steps 末格为转换器格（普通 BLOCK 载荷恒 -1 回归）；
##   ParticleStepExecutor TERMINATE(MECHANISM_BLOCK) 携带载荷（普通阻挡载荷恒 -1 / ZERO 回归）。
## headless extends SceneTree，由 Godot --script 运行；机关为 Node fixture（不进场景树，_ready 不触发），用后 free；
## 全部失败项收集后统一退出（任一失败 quit(1)）。

const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _Contract: GDScript = preload("res://gameplay/light/interaction/light_interaction_contract.gd")
const _RayAdapter: GDScript = preload("res://gameplay/light/ray_mechanism_adapter.gd")
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")
const _RayContext: GDScript = preload("res://gameplay/light/interaction/ray_interaction_context.gd")
const _ParticleAdapter: GDScript = preload("res://gameplay/particle/particle_mechanism_adapter.gd")
const _ParticleContext: GDScript = preload("res://gameplay/light/interaction/particle_interaction_context.gd")
const _RayModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _Executor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
const _State: GDScript = preload("res://gameplay/particle/particle_runtime_state.gd")
const _Converter: GDScript = preload("res://gameplay/mechanisms/converter/light_form_converter.gd")

const _GROUP_COUNT: int = 8

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 跨组共享的真实转换器节点（G5-G7 集成用；收尾统一 free）。
var _shared_converter: Variant = null


func _initialize() -> void:
	_shared_converter = _Converter.new()
	_test_01_form_change_ctor_and_validate_legal()
	_test_02_form_change_validate_illegal()
	_test_03_ray_adapter_maps_form_change()
	_test_04_particle_adapter_maps_form_change()
	_test_05_ray_module_stops_with_payload()
	_test_06_ray_module_plain_block_keeps_payload_sentinel()
	_test_07_executor_terminate_carries_payload()
	_test_08_contract_dispatch_both_forms()
	_shared_converter.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## 构造 RAY 交互 Context。
func _ray_ctx(incoming: Vector2i) -> Variant:
	return _RayContext.create(Vector2i(2, 0), incoming, 1, 0)


## 构造 PARTICLE 交互 Context（tier 取 STANDARD）。
func _particle_ctx(incoming: Vector2i) -> Variant:
	return _ParticleContext.create(Vector2i(2, 0), incoming, 1, 0, 1, 7)


## 构造普通阻挡型伪造机关（正式契约面；用于"载荷哨兵回归"对照）。
class _FakeBlockMechanism:
	extends RefCounted

	const _Res: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY", &"PARTICLE"]

	func interact_ray(_context: Variant) -> _Res:
		return _Res.block_result()

	func interact_particle(_context: Variant) -> _Res:
		return _Res.block_result()


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 光形式转换 FORM_CHANGE 契约+执行链路测试摘要 ====")
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

## 01. FORM_CHANGE 合法构造：RAY/PARTICLE 双目标 × 合法八方向 → validate 零问题；字段回读正确。
func _test_01_form_change_ctor_and_validate_legal() -> void:
	const G: String = "01_FORM_CHANGE合法构造"
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		var vec: Vector2i = _DirectionDomain.to_vector(token)
		for target: int in [_LightEmissionTypes.LightForm.RAY, _LightEmissionTypes.LightForm.PARTICLE]:
			var result: Variant = _Result.form_change_result(target, vec)
			_check(G, result.decision == _Result.Decision.FORM_CHANGE, "%s→%d decision 应为 FORM_CHANGE。" % [token, target])
			_check(G, result.target_form == target, "%s→%d target_form 回读。" % [token, target])
			_check(G, result.redirect_direction == vec, "%s→%d 出射方向回读。" % [token, target])
			var problems: PackedStringArray = result.validate(_LightEmissionTypes.LightForm.RAY)
			_check(G, problems.is_empty(), "%s→%d validate 应零问题（实际 %s）。" % [token, target, problems])

## 02. FORM_CHANGE 非法校验：ZERO 方向 / 非法 target_form 拒绝；其余 Decision 携带 target_form 拒绝；CONTINUE 携带方向拒绝（回归）。
func _test_02_form_change_validate_illegal() -> void:
	const G: String = "02_FORM_CHANGE非法校验"
	var bad_dir: Variant = _Result.form_change_result(_LightEmissionTypes.LightForm.PARTICLE, Vector2i.ZERO)
	_check(G, not bad_dir.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "FORM_CHANGE 携带 ZERO 方向应被拒绝。")
	var bad_target: Variant = _Result.form_change_result(2, Vector2i(1, 0))
	_check(G, not bad_target.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "FORM_CHANGE target_form=2 应被拒绝。")
	var bad_target_negative: Variant = _Result.form_change_result(-1, Vector2i(1, 0))
	_check(G, not bad_target_negative.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "FORM_CHANGE target_form=-1 应被拒绝。")
	var carry_on_continue: Variant = _Result.continue_result()
	carry_on_continue.target_form = _LightEmissionTypes.LightForm.RAY
	_check(G, not carry_on_continue.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "CONTINUE 携带 target_form 应被拒绝。")
	_check(G, _Result.continue_result().validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "CONTINUE 零载荷 validate 应零问题（回归）。")
	_check(G, _Result.block_result().validate(_LightEmissionTypes.LightForm.PARTICLE).is_empty(), "BLOCK 零载荷 validate 应零问题（回归）。")

## 03. RayMechanismAdapter：转换器 RAY 响应映射为 Kind.FORM_CHANGE + target_form/出射方向；无 COLOR_CHANGE 效果。
func _test_03_ray_adapter_maps_form_change() -> void:
	const G: String = "03_Ray适配器映射"
	_shared_converter.set_direction(_Converter.ConverterDirection.DOWN)
	var adapted: Variant = _RayAdapter.evaluate(_shared_converter, _ray_ctx(Vector2i(1, 0)))
	_check(G, adapted.kind == _RayMechanismResult.Kind.FORM_CHANGE, "适配应映射为 Kind.FORM_CHANGE。")
	_check(G, adapted.target_form == _LightEmissionTypes.LightForm.PARTICLE, "RAY 入射目标形态应为 PARTICLE。")
	_check(G, adapted.outgoing_direction == Vector2i(0, 1), "出射方向应为本机关朝向 (0,1)。")
	_check(G, adapted.color_change == _RayColor.ColorValue.NONE, "FORM_CHANGE 不应携带颜色变更（NONE 哨兵）。")

## 04. ParticleMechanismAdapter：转换器 PARTICLE 响应映射为 continue_motion=false + 载荷；speed_delta=0；普通机关回归不受影响。
func _test_04_particle_adapter_maps_form_change() -> void:
	const G: String = "04_Particle适配器映射"
	_shared_converter.set_direction(_Converter.ConverterDirection.UP_RIGHT)
	var effect: Variant = _ParticleAdapter.adapt(_shared_converter, _particle_ctx(Vector2i(1, 0)))
	_check(G, not effect.continue_motion, "FORM_CHANGE 应终止本步传播（continue_motion=false）。")
	_check(G, effect.form_change_target == _LightEmissionTypes.LightForm.RAY, "PARTICLE 入射目标形态应为 RAY。")
	_check(G, effect.form_change_direction == Vector2i(1, -1), "出射方向应为本机关朝向 (1,-1)。")
	_check(G, effect.speed_delta == 0, "FORM_CHANGE 不应携带速度增量。")
	# 回归：普通 BLOCK 机关载荷恒 -1 / ZERO。
	var plain: Variant = _ParticleAdapter.adapt(_FakeBlockMechanism.new(), _particle_ctx(Vector2i(1, 0)))
	_check(G, not plain.continue_motion and plain.form_change_target == -1 and plain.form_change_direction == Vector2i.ZERO,
		"普通 BLOCK 载荷应恒 -1 / ZERO（回归）。")

## 构造正式 LightWorldQuery（真实两段查询链）：occupancy 单格登记机关 + resolver 提供节点解析，
##   与生产 LevelWorldQuery→LightWorldQuery 形状一致（RayExecutionModule 对 world_query 参数有真实类型约束）。
func _world_with_mechanism(mechanism: Variant, cell: Vector2i) -> Variant:
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var mechanism_id: StringName = &"mech1"
	occupancy.register_single_cell(mechanism_id, cell)
	var walls: Array[Vector2i] = []
	var resolver: Callable = func(queried_id: StringName) -> Variant:
		return mechanism if queried_id == mechanism_id else null
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(-8, -8, 16, 16), walls, Vector2i.ZERO, registry, occupancy, resolver)
	return _LightWorldQuery.new(level_query)


## 05. RayExecutionModule：转换器格 FORM_CHANGE → MECHANISM_BLOCK 终止 + 载荷写入 + steps 末格为转换器格。
func _test_05_ray_module_stops_with_payload() -> void:
	const G: String = "05_Ray模块FORM_CHANGE终止"
	_shared_converter.set_direction(_Converter.ConverterDirection.DOWN)
	var world: Variant = _world_with_mechanism(_shared_converter, Vector2i(2, 0))
	var result: Variant = _RayModule.execute(Vector2i(0, 0), Vector2i(1, 0), 16, world, 1, 0)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK, "FORM_CHANGE 应以 MECHANISM_BLOCK 终止。")
	_check(G, result.form_change_target == _LightEmissionTypes.LightForm.PARTICLE, "载荷 target 应为 PARTICLE。")
	_check(G, result.form_change_direction == Vector2i(0, 1), "载荷出射方向应为 (0,1)。")
	_check(G, result.steps.size() == 2, "传播应记录 2 格（含转换器格）。")
	if _check(G, result.steps.size() == 2, "steps 非空才可取末格。"):
		_check(G, result.steps[1].cell == Vector2i(2, 0), "steps 末格应为转换器格 (2,0)。")

## 06. RayExecutionModule：普通 BLOCK 机关（光屏障合同形状）传播终止且载荷恒 -1 / ZERO（回归）。
func _test_06_ray_module_plain_block_keeps_payload_sentinel() -> void:
	const G: String = "06_Ray模块普通BLOCK回归"
	var world: Variant = _world_with_mechanism(_FakeBlockMechanism.new(), Vector2i(2, 0))
	var result: Variant = _RayModule.execute(Vector2i(0, 0), Vector2i(1, 0), 16, world, 1, 0)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK, "普通 BLOCK 应以 MECHANISM_BLOCK 终止（回归）。")
	_check(G, result.form_change_target == -1 and result.form_change_direction == Vector2i.ZERO, "普通 BLOCK 载荷应恒 -1 / ZERO（回归）。")

## 07. ParticleStepExecutor：转换器格 TERMINATE(MECHANISM_BLOCK) 携带载荷且 entered_cell=转换器格；普通阻挡载荷恒 -1（回归）。
func _test_07_executor_terminate_carries_payload() -> void:
	const G: String = "07_执行器TERMINATE载荷"
	_shared_converter.set_direction(_Converter.ConverterDirection.UP)
	var q: Variant = _world_with_mechanism(_shared_converter, Vector2i(2, 0))
	var executor: _Executor = _Executor.new()
	var state: Variant = _State.create_emitted(1, 0, Vector2i(1, 0), Vector2i(1, 0), 0, 1)
	var r: Variant = executor.evaluate_step(state, q)
	_check(G, r.outcome == _Executor.Outcome.TERMINATE, "转换器格应 TERMINATE。")
	_check(G, r.termination_reason == _Executor.TerminationReason.MECHANISM_BLOCK, "终止原因应为 MECHANISM_BLOCK。")
	_check(G, r.entered_cell == Vector2i(2, 0), "entered_cell 应为转换器格 (2,0)。")
	_check(G, r.form_change_target == _LightEmissionTypes.LightForm.RAY, "载荷 target 应为 RAY。")
	_check(G, r.form_change_direction == Vector2i(0, -1), "载荷出射方向应为 (0,-1)。")
	# 回归：普通阻挡载荷恒 -1 / ZERO。
	var q2: Variant = _world_with_mechanism(_FakeBlockMechanism.new(), Vector2i(2, 0))
	var state2: Variant = _State.create_emitted(2, 0, Vector2i(1, 0), Vector2i(1, 0), 0, 1)
	var r2: Variant = executor.evaluate_step(state2, q2)
	_check(G, r2.outcome == _Executor.Outcome.TERMINATE and r2.form_change_target == -1 and r2.form_change_direction == Vector2i.ZERO,
		"普通阻挡载荷应恒 -1 / ZERO（回归）。")

## 08. 正式 Contract 分发双形态：转换器声明 RAY+PARTICLE；分发层校验后 Result 决策为 FORM_CHANGE（正面入射）。
func _test_08_contract_dispatch_both_forms() -> void:
	const G: String = "08_Contract双形态分发"
	_check(G, _shared_converter.get_light_interaction_forms() == [&"RAY", &"PARTICLE"], "形态声明应为 RAY+PARTICLE。")
	_shared_converter.set_direction(_Converter.ConverterDirection.RIGHT)
	var ray_result: Variant = _Contract.dispatch_ray(_shared_converter, _ray_ctx(Vector2i(0, -1)))
	_check(G, ray_result.decision == _Result.Decision.FORM_CHANGE, "RAY 正面入射分发应为 FORM_CHANGE。")
	_check(G, ray_result.target_form == _LightEmissionTypes.LightForm.PARTICLE, "RAY 入射目标应为 PARTICLE。")
	var particle_result: Variant = _Contract.dispatch_particle(_shared_converter, _particle_ctx(Vector2i(0, -1)))
	_check(G, particle_result.decision == _Result.Decision.FORM_CHANGE, "PARTICLE 正面入射分发应为 FORM_CHANGE。")
	_check(G, particle_result.target_form == _LightEmissionTypes.LightForm.RAY, "PARTICLE 入射目标应为 RAY。")
