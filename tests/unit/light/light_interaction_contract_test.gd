extends SceneTree

## LightInteractionContract / Context / Result 定向合同测试（AF-02 / Guide §19-§24、§36.2）。
## 覆盖：Context 共享事实与 Particle-only 事实、非法构造拒绝、不可变意图（无写入口）；
##   Result 构造器 / Decision 不变量 / SpeedDelta ±1 域 / OutputEvent / 不合法 Result 校验；
##   正式分发：透明语义（未声明形态 / 非契约节点 / null / 已释放）、校验失败安全降级、机关单次调用、
##   Context 类型不匹配拒绝、真实机关（SingleCellMirror / 加速器 / 减速器）经正式入口的对称行为。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；真实机关场景 instantiate 不入树，用后 free。


const _Contract: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_contract.gd"
)
const _Result: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _RayContext: GDScript = preload(
	"res://gameplay/light/interaction/ray_interaction_context.gd"
)
const _ParticleContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)
const _ParticleMotionRules: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)
const _SingleCellMirrorScene: PackedScene = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn"
)
const _SingleCellMirrorScript: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)
const _AcceleratorScene: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.tscn"
)
const _DeceleratorScene: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_decelerator.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_contexts_shared_facts()
	_test_02_context_invalid_construction()
	_test_03_result_builders_and_effects()
	_test_04_result_validation_legal()
	_test_05_result_validation_illegal()
	_test_06_dispatch_transparency()
	_test_07_dispatch_degrade_and_single_call()
	_test_08_real_mechanisms()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造合法 RAY Context。
func _ray_ctx(cell: Vector2i, incoming: Vector2i) -> Variant:
	return _RayContext.create(cell, incoming, 9, 3)


## 构造合法 PARTICLE Context（STANDARD / runtime 5）。
func _particle_ctx(cell: Vector2i, incoming: Vector2i) -> Variant:
	return _ParticleContext.create(
		cell, incoming, 9, 3, _ParticleMotionRules.SpeedTier.STANDARD, 5)


## 1. Context 共享事实与 Particle-only 事实：五项 Shared Facts 逐一读回；两形态形态值正确；particle 附加字段正确。
func _test_01_contexts_shared_facts() -> void:
	const G: String = "01_Context事实"
	var ray = _ray_ctx(Vector2i(2, 3), Vector2i(1, 0))
	_check(G, ray != null, "RAY Context 合法输入不应返回 null。")
	if ray:
		_check(G, ray.get_cell() == Vector2i(2, 3), "RAY cell 应读回 (2,3)。")
		_check(G, ray.get_incoming_direction() == Vector2i(1, 0), "RAY 入射方向应读回 (1,0)。")
		_check(G, ray.get_light_form() == _LightEmissionTypes.LightForm.RAY, "RAY 形态值应为 RAY。")
		_check(G, ray.get_emission_id() == 9, "RAY emission_id 应读回 9。")
		_check(G, ray.get_runtime_generation() == 3, "RAY runtime_generation 应读回 3。")
	var particle = _particle_ctx(Vector2i(4, 5), Vector2i(1, 1))
	_check(G, particle != null, "PARTICLE Context 合法输入不应返回 null。")
	if particle:
		_check(G, particle.get_light_form() == _LightEmissionTypes.LightForm.PARTICLE, "PARTICLE 形态值应为 PARTICLE。")
		_check(G, particle.get_speed_tier() == _ParticleMotionRules.SpeedTier.STANDARD, "speed_tier 应读回 STANDARD。")
		_check(G, particle.get_particle_runtime_id() == 5, "particle_runtime_id 应读回 5。")


## 2. Context 非法构造拒绝：非法方向 / 非法形态（经基类防线）/ 非法 speed_tier / 负 runtime_id 一律 null。
func _test_02_context_invalid_construction() -> void:
	const G: String = "02_Context非法构造"
	_check(G, _RayContext.create(Vector2i(0, 0), Vector2i.ZERO, 1, 1) == null, "ZERO 入射方向应拒绝构造。")
	_check(G, _RayContext.create(Vector2i(0, 0), Vector2i(2, 0), 1, 1) == null, "非八方向入射应拒绝构造。")
	_check(G, _ParticleContext.create(
		Vector2i(0, 0), Vector2i(1, 0), 1, 1, 99, 1) == null, "非法 speed_tier 应拒绝构造。")
	_check(G, _ParticleContext.create(
		Vector2i(0, 0), Vector2i(1, 0), 1, 1, 0, -1) == null, "负 particle_runtime_id 应拒绝构造。")
	_check(G, _ParticleContext.create(
		Vector2i(0, 0), Vector2i(0, 0), 1, 1, 0, 1) == null, "非法方向应先于其它校验拒绝（PARTICLE）。")


## 3. Result 构造器与效果读取：三 Decision 构造、REDIRECT 携带方向、SpeedDelta/OutputEvent 读取、空效果默认。
func _test_03_result_builders_and_effects() -> void:
	const G: String = "03_Result构造"
	var cont = _Result.continue_result()
	_check(G, cont.decision == _Result.Decision.CONTINUE, "continue_result 应为 CONTINUE。")
	_check(G, cont.redirect_direction == Vector2i.ZERO, "CONTINUE 不携带方向。")
	_check(G, cont.get_speed_delta() == 0, "无效果时 speed_delta 应为 0。")
	_check(G, cont.get_output_event_ids().is_empty(), "无效果时 event_ids 应为空。")
	var block = _Result.block_result()
	_check(G, block.decision == _Result.Decision.BLOCK, "block_result 应为 BLOCK。")
	var redir = _Result.redirect_result(Vector2i(1, 1))
	_check(G, redir.decision == _Result.Decision.REDIRECT, "redirect_result 应为 REDIRECT。")
	_check(G, redir.redirect_direction == Vector2i(1, 1), "REDIRECT 应携带出射方向。")
	var sped = _Result.continue_result().add_speed_delta(1)
	_check(G, sped.get_speed_delta() == 1, "SpeedDelta(+1) 应可读回。")
	var evd = _Result.continue_result().add_output_event(&"speed_matched")
	_check(G, evd.get_output_event_ids() == [&"speed_matched"], "OutputEvent 应可读回事件 ID。")
	_check(G, evd.get_speed_delta() == 0, "仅事件时 speed_delta 应为 0。")


## 4. validate 合法域：三 Decision 基础形态、PARTICLE ±1、RAY 无速度效果、RAY/PARTICLE 携带事件均合法。
func _test_04_result_validation_legal() -> void:
	const G: String = "04_validate合法"
	var ray_form: int = _LightEmissionTypes.LightForm.RAY
	var particle_form: int = _LightEmissionTypes.LightForm.PARTICLE
	_check(G, _Result.continue_result().validate(ray_form).is_empty(), "CONTINUE(RAY) 应合法。")
	_check(G, _Result.block_result().validate(particle_form).is_empty(), "BLOCK(PARTICLE) 应合法。")
	_check(G, _Result.redirect_result(Vector2i(-1, 1)).validate(ray_form).is_empty(), "REDIRECT 合法方向(RAY) 应合法。")
	_check(G, _Result.continue_result().add_speed_delta(1).validate(particle_form).is_empty(), "+1(PARTICLE) 应合法。")
	_check(G, _Result.continue_result().add_speed_delta(-1).validate(particle_form).is_empty(), "-1(PARTICLE) 应合法。")
	_check(G, _Result.continue_result().add_output_event(&"evt").validate(ray_form).is_empty(), "事件(RAY) 应合法。")
	_check(G, _Result.redirect_result(Vector2i(1, -1)).add_speed_delta(1).validate(particle_form).is_empty(),
		"REDIRECT + SpeedDelta(PARTICLE) 应合法。")


## 5. validate 不合法域：未知 Decision、REDIRECT 缺方向、CONTINUE 带方向、delta 越域、RAY 带速度、空事件、重复效果、未知效果种类。
func _test_05_result_validation_illegal() -> void:
	const G: String = "05_validate非法"
	var ray_form: int = _LightEmissionTypes.LightForm.RAY
	var particle_form: int = _LightEmissionTypes.LightForm.PARTICLE
	var bad_decision = _Result.continue_result()
	bad_decision.decision = 99
	_check(G, not bad_decision.validate(ray_form).is_empty(), "未知 Decision 应不合法。")
	_check(G, not _Result.redirect_result(Vector2i.ZERO).validate(ray_form).is_empty(), "REDIRECT ZERO 方向应不合法。")
	_check(G, not _Result.redirect_result(Vector2i(2, 0)).validate(ray_form).is_empty(), "REDIRECT 非八方向应不合法。")
	var cont_with_dir = _Result.continue_result()
	cont_with_dir.redirect_direction = Vector2i(1, 0)
	_check(G, not cont_with_dir.validate(ray_form).is_empty(), "CONTINUE 携带方向应不合法。")
	_check(G, not _Result.continue_result().add_speed_delta(0).validate(particle_form).is_empty(), "delta=0 应不合法（无操作效果不该出现）。")
	_check(G, not _Result.continue_result().add_speed_delta(2).validate(particle_form).is_empty(), "delta=+2 应不合法。")
	_check(G, not _Result.continue_result().add_speed_delta(-2).validate(particle_form).is_empty(), "delta=-2 应不合法。")
	_check(G, not _Result.continue_result().add_speed_delta(1).validate(ray_form).is_empty(), "RAY 携带 SpeedDelta 应不合法。")
	_check(G, not _Result.continue_result().add_output_event(&"").validate(ray_form).is_empty(), "空 event_id 应不合法。")
	_check(G, not _Result.continue_result().add_speed_delta(1).add_speed_delta(-1).validate(particle_form).is_empty(),
		"重复 SpeedDelta 应不合法。")
	var bad_effect = _Result.continue_result()
	var effect = _Result.TypedEffect.new()
	effect.type = 99
	effect.delta = 0
	effect.event_id = &""
	bad_effect.effects.append(effect)
	_check(G, not bad_effect.validate(particle_form).is_empty(), "未知效果种类应不合法。")


## 6. 分发透明语义：null / 已释放 / 非 Object / 非契约节点 / 未声明形态 一律透明 CONTINUE 且不调用机关入口。
func _test_06_dispatch_transparency() -> void:
	const G: String = "06_透明语义"
	var ctx_p = _particle_ctx(Vector2i(0, 0), Vector2i(1, 0))
	var ctx_r = _ray_ctx(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, _Contract.dispatch_ray(null, ctx_r).decision == _Result.Decision.CONTINUE, "null 机关 RAY 应透明。")
	_check(G, _Contract.dispatch_particle(null, ctx_p).decision == _Result.Decision.CONTINUE, "null 机关 PARTICLE 应透明。")
	var freed: Node = Node.new()
	freed.free()
	_check(G, _Contract.dispatch_particle(freed, ctx_p).decision == _Result.Decision.CONTINUE, "已释放机关应透明。")
	_check(G, _Contract.dispatch_particle(5, ctx_p).decision == _Result.Decision.CONTINUE, "非 Object 应透明。")
	var plain: RefCounted = RefCounted.new()
	_check(G, _Contract.dispatch_particle(plain, ctx_p).decision == _Result.Decision.CONTINUE, "非契约节点应透明。")
	_check(G, _Contract.dispatch_ray(plain, ctx_r).decision == _Result.Decision.CONTINUE, "非契约节点 RAY 应透明。")
	# 未声明形态：仅声明 RAY 的机关对 PARTICLE 透明且不调 interact_particle。
	var ray_only: _RayOnlyFake = _RayOnlyFake.new()
	_check(G, _Contract.supports_form(ray_only, _LightEmissionTypes.LightForm.RAY), "仅 RAY 机关应声明支持 RAY。")
	_check(G, not _Contract.supports_form(ray_only, _LightEmissionTypes.LightForm.PARTICLE), "仅 RAY 机关不应支持 PARTICLE。")
	var out_p = _Contract.dispatch_particle(ray_only, ctx_p)
	_check(G, out_p.decision == _Result.Decision.CONTINUE, "未声明 PARTICLE 应透明 CONTINUE。")
	_check(G, ray_only.call_count == 0, "未声明形态不得调用 interact_particle。")
	_check(G, _Contract.supports_form(null, _LightEmissionTypes.LightForm.RAY) == false, "null supports_form 应 false。")


## 7. 校验失败降级与单次调用：机关返回 null / 非正式类型 / 不合法 Result → 透明 CONTINUE；合法机关恰被调用一次。
func _test_07_dispatch_degrade_and_single_call() -> void:
	const G: String = "07_降级与单次"
	var ctx_p = _particle_ctx(Vector2i(0, 0), Vector2i(1, 0))
	# 返回 null。
	var null_ret: _NullReturnFake = _NullReturnFake.new()
	_check(G, _Contract.dispatch_particle(null_ret, ctx_p).decision == _Result.Decision.CONTINUE, "返回 null 应降级透明。")
	_check(G, null_ret.call_count == 1, "null 返回机关仍应被调用一次。")
	# 返回非正式类型。
	var wrong_ret: _WrongReturnFake = _WrongReturnFake.new()
	_check(G, _Contract.dispatch_particle(wrong_ret, ctx_p).decision == _Result.Decision.CONTINUE, "返回非正式类型应降级透明。")
	# 返回不合法 Result（REDIRECT ZERO）。
	var illegal: _IllegalResultFake = _IllegalResultFake.new()
	_check(G, _Contract.dispatch_particle(illegal, ctx_p).decision == _Result.Decision.CONTINUE, "不合法 Result 应降级透明。")
	_check(G, illegal.call_count == 1, "不合法机关应被调用一次（单次求值）。")
	# Context 类型不匹配：dispatch_particle 收 RAY Context → 透明 + 不调用。
	var mirror_like: _FullFake = _FullFake.new()
	var wrong_ctx_out = _Contract.dispatch_particle(mirror_like, _ray_ctx(Vector2i(0, 0), Vector2i(1, 0)))
	_check(G, wrong_ctx_out.decision == _Result.Decision.CONTINUE, "Context 类型不匹配应透明降级。")
	_check(G, mirror_like.particle_call_count == 0, "Context 不匹配时不得调用机关。")
	# 合法路径：单次调用 + REDIRECT 透传 + SpeedDelta 透传。
	var full: _FullFake = _FullFake.new()
	full.redirect_to = Vector2i(0, -1)
	full.delta = -1
	var out = _Contract.dispatch_particle(full, ctx_p)
	_check(G, out.decision == _Result.Decision.REDIRECT, "合法机关 REDIRECT 应透传。")
	_check(G, out.redirect_direction == Vector2i(0, -1), "REDIRECT 方向应透传。")
	_check(G, out.get_speed_delta() == -1, "SpeedDelta 应透传。")
	_check(G, full.particle_call_count == 1, "机关应恰被调用一次（不重求值）。")


## 8. 真实机关对称行为：SingleCellMirror RAY/PARTICLE 双 REDIRECT 同公式；加速器 PARTICLE +1 / RAY 透明；减速器 -1。
func _test_08_real_mechanisms() -> void:
	const G: String = "08_真实机关"
	var mirror: Variant = _SingleCellMirrorScene.instantiate()
	mirror.set_orientation(_SingleCellMirrorScript.MirrorOrientation.SLASH)
	_check(G, _Contract.supports_form(mirror, _LightEmissionTypes.LightForm.RAY), "镜面应声明 RAY。")
	_check(G, _Contract.supports_form(mirror, _LightEmissionTypes.LightForm.PARTICLE), "镜面应声明 PARTICLE。")
	# SLASH：入射 RIGHT(1,0) → (-0,-1)=UP(0,-1)。
	var ray_out = _Contract.dispatch_ray(mirror, _ray_ctx(Vector2i(3, 3), Vector2i(1, 0)))
	_check(G, ray_out.decision == _Result.Decision.REDIRECT, "镜面 RAY 应 REDIRECT。")
	_check(G, ray_out.redirect_direction == Vector2i(0, -1), "镜面 RAY SLASH 入射 RIGHT 应出射 UP(0,-1)。")
	var particle_out = _Contract.dispatch_particle(mirror, _particle_ctx(Vector2i(3, 3), Vector2i(1, 0)))
	_check(G, particle_out.decision == _Result.Decision.REDIRECT, "镜面 PARTICLE 应 REDIRECT（对称）。")
	_check(G, particle_out.redirect_direction == Vector2i(0, -1), "镜面 PARTICLE 出射应与 RAY 同公式（对称合同）。")
	_check(G, particle_out.get_speed_delta() == 0, "镜面不改速。")
	mirror.free()
	# 加速器（默认朝 RIGHT）：PARTICLE 同向 +1；异向 0；RAY 透明。
	var accel: Variant = _AcceleratorScene.instantiate()
	_check(G, not _Contract.supports_form(accel, _LightEmissionTypes.LightForm.RAY), "加速器不应声明 RAY。")
	var accel_hit = _Contract.dispatch_particle(accel, _particle_ctx(Vector2i(1, 1), Vector2i(1, 0)))
	_check(G, accel_hit.decision == _Result.Decision.CONTINUE, "加速器应 CONTINUE。")
	_check(G, accel_hit.get_speed_delta() == 1, "加速器同向应请求 +1。")
	var accel_miss = _Contract.dispatch_particle(accel, _particle_ctx(Vector2i(1, 1), Vector2i(0, 1)))
	_check(G, accel_miss.decision == _Result.Decision.CONTINUE, "加速器异向应 CONTINUE。")
	_check(G, accel_miss.get_speed_delta() == 0, "加速器异向应无 SpeedDelta。")
	var accel_ray = _Contract.dispatch_ray(accel, _ray_ctx(Vector2i(1, 1), Vector2i(1, 0)))
	_check(G, accel_ray.decision == _Result.Decision.CONTINUE, "加速器 RAY 未声明应透明（Guide §21 示例）。")
	accel.free()
	# 减速器（默认朝 RIGHT）：同向 -1。
	var decel: Variant = _DeceleratorScene.instantiate()
	var decel_hit = _Contract.dispatch_particle(decel, _particle_ctx(Vector2i(1, 1), Vector2i(1, 0)))
	_check(G, decel_hit.decision == _Result.Decision.CONTINUE, "减速器应 CONTINUE。")
	_check(G, decel_hit.get_speed_delta() == -1, "减速器同向应请求 -1。")
	decel.free()


## 仅声明 RAY 的伪造机关（§21 未声明形态语义）。
class _RayOnlyFake:
	extends RefCounted

	var call_count: int = 0

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY"]

	func interact_particle(particle_context: Variant) -> Variant:
		call_count += 1
		return null


## 返回 null 的伪造机关。
class _NullReturnFake:
	extends RefCounted

	var call_count: int = 0

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"PARTICLE"]

	func interact_particle(particle_context: Variant) -> Variant:
		call_count += 1
		return null


## 返回非正式类型的伪造机关。
class _WrongReturnFake:
	extends RefCounted

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"PARTICLE"]

	func interact_particle(particle_context: Variant) -> Variant:
		return Dictionary()


## 返回不合法 Result（REDIRECT ZERO）的伪造机关。
class _IllegalResultFake:
	extends RefCounted

	const _ResultScript: GDScript = preload(
		"res://gameplay/light/interaction/light_interaction_result.gd"
	)

	var call_count: int = 0

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"PARTICLE"]

	func interact_particle(particle_context: Variant) -> Variant:
		call_count += 1
		return _ResultScript.redirect_result(Vector2i.ZERO)


## 双形态可编程伪造机关（合法路径透传断言用）。
class _FullFake:
	extends RefCounted

	const _ResultScript: GDScript = preload(
		"res://gameplay/light/interaction/light_interaction_result.gd"
	)

	var redirect_to: Vector2i = Vector2i.ZERO
	var delta: int = 0
	var particle_call_count: int = 0

	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY", &"PARTICLE"]

	func interact_ray(ray_context: Variant) -> Variant:
		return _ResultScript.redirect_result(redirect_to)

	func interact_particle(particle_context: Variant) -> Variant:
		particle_call_count += 1
		var result: Variant = _ResultScript.redirect_result(redirect_to)
		if delta != 0:
			result.add_speed_delta(delta)
		return result


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 8
	var passed_checks: int = _checks - _failures.size()
	print("==== LightInteractionContract AF-02 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
