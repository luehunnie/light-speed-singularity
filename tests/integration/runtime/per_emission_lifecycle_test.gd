extends SceneTree

## M4-E2 per-emission 并发生命周期集成测试。
## 覆盖 spec 第十三节 7~27：真实 LRC 内部并发编排产生多 emission（经白盒反射 _dispatch_emission seam，不新增 public player API）。
##   - Particle/Particle：两 PARTICLE emission 各自 runtime_id、正确映射、第一颗 terminate 只 finish 自己、RunState 保持 PULSE_ACTIVE、最后一颗才 MOVE_WINDOW。
##   - Ray/Ray：两 Ray emission 独立视觉 ownership、Ray1 finish 只清自身视觉、Ray2 不受影响、最后才转态、乱序同样正确。
##   - Particle + Ray 混合：两形态同 generation 可登记、Particle 先结束不影响 Ray、Ray 先结束不影响 Particle、最后结束才聚合。
##   - R 多 emission：active 多 emission 时 R 推进 generation、Registry 清空、Particle 清空、Ray visuals 全清、旧 Ray timer / 旧 Particle 回调永久 no-op。
##   - 同 generation 第二 Particle 不启动第二 pump（pump 单链）。
## 这不是玩家 Q 路径；_dispatch_emission 是 LRC private orchestration seam，仅测试白盒调用（E3 才开放 repeated fire）。
## 经 fixtures/runtime_controller_fixture.gd 装配真实控制器；可控泵 resume 同步驱动 Tick。由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _GROUP_COUNT: int = 9

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture: _Fixture = null


func _initialize() -> void:
	await process_frame
	_fixture = _Fixture.new(self)
	await _run_all_tests()
	_report()
	await _fixture.wait_settled(4)
	await _fixture.await_settle_pumps()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


func _run_all_tests() -> void:
	await _test_01_particle_particle_first_terminate_keeps_pulse_active()
	await _test_02_particle_particle_last_terminate_aggregates()
	await _test_03_ray_ray_first_finish_keeps_other_visual()
	await _test_04_ray_ray_out_of_order_completion()
	await _test_05_particle_ray_particle_first_does_not_affect_ray()
	await _test_06_particle_ray_ray_first_does_not_affect_particle()
	await _test_07_reset_clears_multi_emission_and_invalidates_stale()
	await _test_08_same_generation_second_particle_no_second_pump()
	await _test_09_two_emissions_share_one_pump_chain()


# ===== Particle / Particle =====

## 7~12.（spec 十三.7~12）两 PARTICLE emission 经 seam 并发：两 runtime_id 映射正确；第一颗 terminate 后 emission1 finished、emission2 仍 active、RunState 保持 PULSE_ACTIVE。
##   emitter(14,3) RIGHT（近东边界）→ emission1 runtime0 @ (14,3) tick8 越界 terminate；seam 注入 emission2 runtime1 @ (12,5) RIGHT tick16 才越界。
func _test_01_particle_particle_first_terminate_keeps_pulse_active() -> void:
	const NAME: String = "01_ParticleParticle第一颗terminate保持PULSE_ACTIVE"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "emission1 request_fire 应返回 true。")
	# seam 注入第二 PARTICLE emission（emission2, runtime1 @ (12,5) RIGHT）。
	_check(NAME, _dispatch_particle(env, 1, Vector2i(12, 5), Vector2i.RIGHT) > 0, "seam 应成功 dispatch emission2。")
	var registry: Variant = env.controller.get("_active_emission_registry")
	_check(NAME, env.controller.get_active_emission_count() == 2, "两 emission 并存 active_count 期望 2。")
	_check(NAME, env.controller.get_particle_active_count() == 2, "两颗光粒 active 期望 2。")
	_check(NAME, registry.find_emission_for_runtime(0) == 1, "runtime0 应映射到 emission1。")
	_check(NAME, registry.find_emission_for_runtime(1) == 2, "runtime1 应映射到 emission2。")
	# 推进 8 Tick：runtime0 @ (14,3) tick8 越界 terminate；runtime1 @ (12,5) tick8 MOVE 到 (14,5)（未 terminate）。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_active_count() == 1, "runtime0 terminate 后 active 期望 1（只剩 runtime1），实际 %d。" % [env.controller.get_particle_active_count()])
	_check(NAME, registry.find_emission_for_runtime(0) == 0, "runtime0 应已解绑（find 返回 0）。")
	_check(NAME, registry.find_emission_for_runtime(1) == 2, "runtime1 仍映射 emission2。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "emission1 finished，active_count 期望 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission2 仍 active，应保持 PULSE_ACTIVE，实际 %s。" % [_state_label(env.rsc.get_current_state())])


## 13~15.（spec 十三.13~15）第二颗 terminate 后 active 1→0，最后才聚合结算到 MOVE_WINDOW。
func _test_02_particle_particle_last_terminate_aggregates() -> void:
	const NAME: String = "02_ParticleParticle最后颗terminate聚合结算"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_dispatch_particle(env, 1, Vector2i(12, 5), Vector2i.RIGHT)
	# 推进到 runtime0 terminate（tick8）：active 2→1，仍 PULSE_ACTIVE。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_active_emission_count() == 1, "tick8 后 active 期望 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "tick8 后应仍 PULSE_ACTIVE。")
	# 继续推进到 runtime1 terminate（tick16）：active 1→0，聚合结算 MOVE_WINDOW。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_active_emission_count() == 0, "最后颗 terminate 后 active 期望 0。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "光粒全清。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后颗 terminate 才聚合到 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


# ===== Ray / Ray =====

## 16~19.（spec 十三.16~19）两 Ray emission 独立视觉 ownership：Ray1 finish 只清自身视觉段，Ray2 视觉与 active 状态不受影响。
##   经白盒 _finish_emission(gen, eid) 直接结算单 emission（绕过 0.0s Ray timer，确定性验证 per-emission 视觉隔离）。
func _test_03_ray_ray_first_finish_keeps_other_visual() -> void:
	const NAME: String = "03_RayRay第一发finish只清自身视觉"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 RAY（14 段，(1,3)→(15,3)）。
	_check(NAME, _dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT) > 0, "seam 应成功 dispatch emission2。")
	# 两 Ray 共用 FixedEmitter (1,3) RIGHT，路径几何相同，各 14 段；per-emission 分桶 ownership。
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "两 Ray 各 14 段，总期望 28，实际 %d。" % [env.light_visual_controller.get_segment_count()])
	_check(NAME, env.light_visual_controller.get_emission_count() == 2, "visual emission 数期望 2。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "registry active 期望 2。")
	# 手动结算 emission1（模拟 Ray1 completion）：只清 emission1 的 14 段。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "emission1 清后总段期望 14（只剩 emission2），实际 %d。" % [env.light_visual_controller.get_segment_count()])
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 0, "emission1 视觉段期望 0。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 14, "emission2 视觉段仍 14（不受 emission1 清理影响）。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "emission1 finished，active 期望 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission2 仍 active，应保持 PULSE_ACTIVE。")
	# 结算 emission2：才聚合转态。
	env.controller.call("_finish_emission", 1, 2)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "emission2 清后总段期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 Ray finish 才 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


## 20~21.（spec 十三.20~21）Ray completion 乱序同样正确：先 finish emission2，emission1 视觉与 active 保持；再 finish emission1 才转态。
func _test_04_ray_ray_out_of_order_completion() -> void:
	const NAME: String = "04_RayRay乱序completion正确"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1。
	_dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT)  # emission2。
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "前置两 Ray 总段期望 28。")
	# 乱序：先 finish emission2。
	env.controller.call("_finish_emission", 1, 2)
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 0, "emission2 清后段期望 0。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 14, "emission1 视觉段仍 14（乱序 completion 不受影响）。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "emission2 finished，active 期望 1（emission1 仍活动）。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission1 仍 active，保持 PULSE_ACTIVE。")
	# 再 finish emission1：才聚合转态。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "全部清后总段期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 finish 才 MOVE_WINDOW。")


# ===== Particle + Ray 混合 =====

## 22~24.（spec 十三.22~24）Particle 与 Ray 同 generation 可登记；Particle 先结束不影响 Ray（Ray 视觉/active 保持，RunState 保持 PULSE_ACTIVE）。
##   FixedEmitter=RAY（emission1 Ray 经 request_fire 正常执行）；seam 注入 emission2 PARTICLE。
func _test_05_particle_ray_particle_first_does_not_affect_ray() -> void:
	const NAME: String = "05_ParticleRayParticle先结束不影响Ray"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 RAY（14 段）。
	_check(NAME, _dispatch_particle(env, 1, Vector2i(14, 3), Vector2i.RIGHT) > 0, "seam 应成功 dispatch emission2 PARTICLE。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "Ray+Particle 两 emission active 期望 2。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "Ray emission1 有 14 段，Particle emission2 无 Ray 段，总期望 14。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "Particle emission2 有 1 颗光粒。")
	# 推进到 PARTICLE 光粒越界 terminate（emission2 @ (14,3) tick8）：emission2 finished，emission1 Ray 不受影响。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_active_emission_count() == 1, "Particle emission2 finished，active 期望 1（只剩 Ray emission1）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "Ray 视觉不受 Particle 结束影响，仍 14 段。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "Ray emission1 仍 active，保持 PULSE_ACTIVE。")
	# 结算 Ray emission1：才聚合转态。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "Ray 清后总段期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 Ray finish 才 MOVE_WINDOW。")


## 25.（spec 十三.25）Ray 先结束不影响 Particle：手动结算 Ray emission1，Particle emission2 光粒仍 active、RunState 保持 PULSE_ACTIVE；最后 Particle 结束才聚合。
func _test_06_particle_ray_ray_first_does_not_affect_particle() -> void:
	const NAME: String = "06_ParticleRayRay先结束不影响Particle"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 RAY。
	_dispatch_particle(env, 1, Vector2i(14, 3), Vector2i.RIGHT)  # emission2 PARTICLE。
	# 手动结算 Ray emission1（先结束）：Ray 视觉清，Particle 不受影响。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "Ray 清后视觉段期望 0。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "Ray finished，active 期望 1（Particle emission2 仍活动）。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "Particle 光粒不受 Ray 结束影响，仍 1 颗。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "Particle emission2 仍 active，保持 PULSE_ACTIVE。")
	# 推进到 Particle 光粒越界 terminate：才聚合转态。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_active_emission_count() == 0, "Particle 结束后 active 期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 Particle 结束才 MOVE_WINDOW。")


# ===== R 多 emission =====

## 26.（spec 十三.26）多 emission active 时 R：generation 推进；Registry 清空；Particle 清空；Ray visuals 全清；旧 Ray timer completion / 旧 Particle terminate 回调永久 no-op（wait_settled 后状态不变）。
func _test_07_reset_clears_multi_emission_and_invalidates_stale() -> void:
	const NAME: String = "07_R多emission清空并失效旧回调"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 RAY。
	_dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT)  # emission2 RAY。
	_dispatch_particle(env, 1, Vector2i(14, 3), Vector2i.RIGHT)  # emission3 PARTICLE。
	_check(NAME, env.controller.get_active_emission_count() == 3, "前置三 emission active 期望 3。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "前置两 Ray 各 14 段期望 28。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "前置一颗粒子期望 1。")
	# R：推进 generation + 清 registry + 清 particle + 清全部 Ray 视觉。
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_runtime_generation() == 2, "R 后 generation 期望 2。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "R 后 registry 清空 active 期望 0。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "R 后 particle 清空期望 0。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "R 后 Ray visuals 全清期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应 SETUP。")
	# 推进帧让旧 Ray timer(0.0s) 与旧 Particle 泵链恢复：经 generation 守卫永久 no-op，不清新光路 / 不改新状态 / 不进 COMPLETED。
	await _fixture.wait_settled(6)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "旧回调 no-op，状态应仍 SETUP，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "旧 Ray timer 不应重建光路，段仍 0。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "旧回调不应重建 emission。")


# ===== Driver pump 单链 =====

## 27.（spec 十三.27）同 generation 第二 Particle 不启动第二 pump：seam 注入第二 PARTICLE emission 后 pump 仍只 1 条活动链。
func _test_08_same_generation_second_particle_no_second_pump() -> void:
	const NAME: String = "07_同generation第二Particle不启第二pump"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 + pump chain 1。
	_check(NAME, env.particle_tick_pump.active_chain_count() == 1, "emission1 后 pump 链期望 1。")
	_dispatch_particle(env, 1, Vector2i(1, 1), Vector2i.RIGHT)  # emission2（同 generation）。
	_check(NAME, env.particle_tick_pump.active_chain_count() == 1, "同 generation 第二 Particle 不应启动第二 pump，链仍期望 1，实际 %d。" % [env.particle_tick_pump.active_chain_count()])
	_check(NAME, env.controller.get_particle_active_count() == 2, "两颗粒子并存期望 2。")


## 28.（spec 十三.28）drain 后 pump 正确停止：单 Particle 越界 drain 后 pump 链归 0；额外 resume 不再推进。
func _test_09_two_emissions_share_one_pump_chain() -> void:
	const NAME: String = "08_drain后pump停止"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# 推进到越界 drain（tick8）：最后光粒 terminate → drain → 泵停。
	while env.particle_tick_pump.resume_one_tick():
		pass
	_check(NAME, env.controller.get_particle_active_count() == 0, "drain 后光粒期望 0。")
	_check(NAME, env.particle_tick_pump.active_chain_count() == 0, "drain 后 pump 链期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "drain 聚合结算 MOVE_WINDOW。")
	var tick_after: int = env.controller.get_particle_tick()
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == tick_after, "drain 后额外 resume 不应推进 Tick。")


# ===== seam 辅助 =====

## 经白盒反射调用 LRC private _dispatch_emission seam 创建一次 PARTICLE emission（不消费 cooldown；非 public player API）。
func _dispatch_particle(env: _Fixture._Env, generation: int, cell: Vector2i, direction: Vector2i) -> int:
	return int(env.controller.call("_dispatch_emission", generation, _LightEmissionTypes.LightForm.PARTICLE, cell, direction))


## 经白盒反射调用 LRC private _dispatch_emission seam 创建一次 RAY emission（不消费 cooldown）。
func _dispatch_ray(env: _Fixture._Env, generation: int, cell: Vector2i, direction: Vector2i) -> int:
	return int(env.controller.call("_dispatch_emission", generation, _LightEmissionTypes.LightForm.RAY, cell, direction))


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _state_label(state: int) -> String:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return "SETUP"
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			return "READY_TO_FIRE"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return "COMPLETED"
		_:
			return "未知(%d)" % [state]


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== M4-E2 per-emission 并发生命周期测试摘要 ====")
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
