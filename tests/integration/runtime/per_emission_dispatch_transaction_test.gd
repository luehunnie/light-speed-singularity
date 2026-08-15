extends SceneTree

## M4-E2.1 per-emission dispatch transaction 集成测试。
## 覆盖 spec 第八节 6~20（Ray immutable snapshot / dispatch 显式失败 rollback / joined failure 不影响旧 emission / 四 emission 混合 / reset 旧 timer）。
##   - immutable snapshot：dispatch 后修改 FixedEmitter 不影响已发 Ray（driver 不再重读 _fixed_emitter）；
##   - dispatch failure（未知 form / Ray build 失败 / Particle emit 失败）：显式 -1 + rollback，不留 Registry zombie，不清视觉；
##   - joined failure：旧 Ray/Particle emission 生命周期不受新 dispatch 失败影响（不 finish 整个 pulse、不 mark_finished 旧 emission、不全局 clear visual）；
##   - 四 emission 混合（Ray A + Particle B + Ray C + Particle D）：active==4，两种顺序逐个 finish，中途 PULSE_ACTIVE，最后一个才 MOVE_WINDOW；
##   - reset 旧 Ray timer：旧 epoch completion 经 generation 守卫永久 no-op，不清新 epoch Ray visual。
## 经 fixtures/runtime_controller_fixture.gd 装配真实控制器；白盒反射 _dispatch_emission / _finish_emission seam（非 public player API；E3 才开放 repeated fire）。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)；失败路径用例的 push_error 输出不计入失败。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _GROUP_COUNT: int = 7

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
	await _test_01_ray_immutable_snapshot_not_reread_from_fixed_emitter()
	_test_02_dispatch_failure_leaves_no_zombie_no_visual()
	_test_03_joined_failure_does_not_affect_old_emission()
	await _test_04_two_rays_driver_completion_independent_and_out_of_order()
	_test_05_four_emission_mixed_two_finish_orders()
	_test_06_reset_old_ray_timer_does_not_clear_new_epoch_visual()
	_test_07_unknown_form_does_not_enter_ray_execution()


# ===== immutable snapshot =====

## 6.（item 6）Ray immutable snapshot：dispatch Ray（snapshot RIGHT）后把 FixedEmitter 改成 LEFT，已发 Ray 视觉路径不变（driver 用传入 direction，不重读 _fixed_emitter）。
##    LEFT from (1,3) 仅 1 段（(0,3) 后越界）；RIGHT from (1,3) 14 段。若 driver 重读 emitter（LEFT），emission2 视觉会是 1 段而非 14 段。
func _test_01_ray_immutable_snapshot_not_reread_from_fixed_emitter() -> void:
	const NAME: String = "01_Ray_immutable_snapshot不重读emitter"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "Ray emission1 request_fire 应成功。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 14, "emission1 (RIGHT) 期望 14 段。")
	# dispatch 后修改 FixedEmitter 方向为 LEFT（emitter 现为 LEFT）。
	_check(NAME, env.fixed_emitter.try_set_direction(Vector2i.LEFT), "FixedEmitter 应可改方向为 LEFT。")
	_check(NAME, env.fixed_emitter.get_direction() == Vector2i.LEFT, "FixedEmitter 现为 LEFT。")
	# 白盒 dispatch emission2 传入 immutable snapshot RIGHT（与 emitter 当前 LEFT 不同）。
	var eid2: int = _dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT)
	_check(NAME, eid2 > 0, "白盒 dispatch emission2 (传入 RIGHT) 应成功，实际 %d。" % eid2)
	# 关键：emission2 用传入的 RIGHT（14 段），不是 emitter 的 LEFT（会只有 1 段）。
	_check(NAME, env.light_visual_controller.get_emission_segment_count(eid2) == 14, "immutable snapshot：emission2 应使用传入 RIGHT（14 段），非 emitter LEFT（1 段），实际 %d。" % [env.light_visual_controller.get_emission_segment_count(eid2)])
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "两 Ray 各 14 段总期望 28。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "两 emission 并存 active 期望 2。")


# ===== dispatch failure（no zombie / no visual）=====

## 7/8/13.（items 7,8,13）dispatch 显式失败 + rollback：未知 form / Ray build 失败（ZERO direction）/ Particle emit 失败（ZERO direction）均返回 -1，不留 Registry active zombie，不创建视觉。
##    白盒直接进 PULSE_ACTIVE（begin_pulse）后调用 _dispatch_emission；失败 emission 经 _rollback_emission（mark_finished + clear_emission）回滚。
func _test_02_dispatch_failure_leaves_no_zombie_no_visual() -> void:
	const NAME: String = "02_dispatch失败无zombie无视觉"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, true)
	env.rsc.begin_runtime()
	env.rsc.begin_pulse()  # 白盒直接进 PULSE_ACTIVE（无既有 emission）。
	# 未知 form：不落入 Ray 分支，返回 -1。
	var eid_unknown: int = int(env.controller.call("_dispatch_emission", 1, 99, Vector2i(1, 3), Vector2i.RIGHT))
	_check(NAME, eid_unknown == -1, "未知 form dispatch 应返回 -1，实际 %d。" % eid_unknown)
	_check(NAME, env.controller.get_active_emission_count() == 0, "未知 form rollback 后 active 期望 0（无 zombie）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "未知 form 不创建视觉。")
	_check(NAME, env.light_world_query_spy.total_query_calls() == 0, "未知 form 不进入 Ray 执行（查询 0）。")
	# Ray build 失败（ZERO direction）：driver 防御性校验失败返回 false → rollback。
	var eid_ray_fail: int = int(env.controller.call("_dispatch_emission", 1, _LightEmissionTypes.LightForm.RAY, Vector2i(1, 3), Vector2i.ZERO))
	_check(NAME, eid_ray_fail == -1, "Ray ZERO direction dispatch 应返回 -1，实际 %d。" % eid_ray_fail)
	_check(NAME, env.controller.get_active_emission_count() == 0, "Ray 失败 rollback 后 active 期望 0（无 zombie）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "Ray 失败不创建视觉。")
	# emission_id 形成不复用空洞：两次失败 allocate 后下一次成功 allocate 继续 +1（不回拨）。next emission_id >= 3。
	var eid_ok: int = _dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT)
	_check(NAME, eid_ok >= 3, "失败空洞后新 emission_id 不回拨（期望 >=3），实际 %d。" % eid_ok)
	_check(NAME, env.controller.get_active_emission_count() == 1, "成功 dispatch 后 active 期望 1。")


# ===== joined failure（不影响旧 emission）=====

## 11/12/14.（items 11,12,14）joined dispatch failure 不影响旧 emission：旧 Ray/Particle 仍活动、视觉/光粒保持、RunState 保持 PULSE_ACTIVE；失败不清全局视觉、不 mark_finished 旧 emission、不 finish 整个 pulse。
func _test_03_joined_failure_does_not_affect_old_emission() -> void:
	const NAME: String = "03_joined失败不影响旧emission"
	# 子 case A：旧 Ray + joined Particle emit 失败。
	var envA: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	envA.rsc.begin_runtime()
	_check(NAME, envA.controller.request_fire(), "旧 Ray emission1 request_fire 应成功。")
	_check(NAME, envA.light_visual_controller.get_segment_count() == 14, "旧 Ray 视觉 14 段。")
	var seg_before_a: int = envA.light_visual_controller.get_segment_count()
	# joined Particle emit 失败（ZERO direction）。
	var eid_p_fail: int = _dispatch_particle(envA, 1, Vector2i(1, 3), Vector2i.ZERO)
	_check(NAME, eid_p_fail == -1, "joined Particle ZERO direction 应失败 -1。")
	_check(NAME, envA.controller.get_active_emission_count() == 1, "joined Particle 失败后旧 Ray 仍活动（active 1）。")
	_check(NAME, envA.light_visual_controller.get_segment_count() == seg_before_a, "joined Particle 失败不清旧 Ray 视觉（仍 %d）。" % [envA.light_visual_controller.get_segment_count()])
	_check(NAME, envA.controller.get_particle_active_count() == 0, "joined Particle 失败未 emit 光粒（active 0）。")
	_check(NAME, envA.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "旧 Ray 仍 active，保持 PULSE_ACTIVE。")
	# 子 case B：旧 Particle + joined Ray build 失败。
	var envB: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	envB.rsc.begin_runtime()
	_check(NAME, envB.controller.request_fire(), "旧 Particle emission1 request_fire 应成功。")
	_check(NAME, envB.controller.get_particle_active_count() == 1, "旧 Particle 光粒 active 1。")
	# joined Ray build 失败（ZERO direction）。
	var eid_r_fail: int = _dispatch_ray(envB, 1, Vector2i(1, 3), Vector2i.ZERO)
	_check(NAME, eid_r_fail == -1, "joined Ray ZERO direction 应失败 -1。")
	_check(NAME, envB.controller.get_active_emission_count() == 1, "joined Ray 失败后旧 Particle emission 仍活动（active 1）。")
	_check(NAME, envB.controller.get_particle_active_count() == 1, "joined Ray 失败不影响旧光粒（仍 active 1）。")
	_check(NAME, envB.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "旧 Particle 仍 active，保持 PULSE_ACTIVE。")


# ===== 两 Ray driver completion（独立 + 乱序）=====

## 9/10.（items 9,10）两 Ray 经新 RayEmissionDriver dispatch，completion 各自结束；乱序手动 finish emission2 不清 emission1 视觉；最后 emission1 经自身 timer completion 聚合转态。
func _test_04_two_rays_driver_completion_independent_and_out_of_order() -> void:
	const NAME: String = "04_两Ray_driver_completion独立乱序"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # emission1 RAY（driver dispatch，14 段）。
	_check(NAME, _dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT) > 0, "emission2 RAY driver dispatch 成功。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "两 Ray 各 14 段总期望 28。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "registry active 期望 2。")
	# 乱序：手动 finish emission2（先）—— 只清 emission2 视觉。
	env.controller.call("_finish_emission", 1, 2)
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 0, "emission2 清后段期望 0。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 14, "emission1 视觉段仍 14（乱序 completion 不互相清视觉）。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "emission2 finished，active 期望 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission1 仍 active，保持 PULSE_ACTIVE。")
	# 让 emission1 的 driver-completion timer 真实触发（0.0s）→ _finish_emission(1,1) → 聚合 MOVE_WINDOW。
	await _fixture.wait_settled()
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "emission1 自身 completion 后总段期望 0。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "两 Ray 全部 finish，active 期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 Ray completion 才 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


# ===== 四 emission 混合（两种 finish 顺序）=====

## 15-19.（items 15-19）四 emission 混合并存（Ray A=1 + Particle B=2 + Ray C=3 + Particle D=4）：active==4；两种顺序逐个 finish，中途一直 PULSE_ACTIVE，最后一个才 MOVE_WINDOW。
##    白盒 _finish_emission 确定性结算（Ray/Particle 共用同一聚合入口；真实 TERMINATE 路径由 per_emission_lifecycle 覆盖）。
func _test_05_four_emission_mixed_two_finish_orders() -> void:
	const NAME: String = "05_四emission混合两种finish顺序"
	# 顺序一：A(1) → B(2) → C(3) → D(4)。
	var env1: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env1.rsc.begin_runtime()
	_check(NAME, env1.controller.request_fire(), "Ray A request_fire 应成功。")  # A=1 RAY
	_check(NAME, _dispatch_particle(env1, 1, Vector2i(14, 3), Vector2i.RIGHT) > 0, "Particle B dispatch 成功。")  # B=2
	_check(NAME, _dispatch_ray(env1, 1, Vector2i(1, 3), Vector2i.RIGHT) > 0, "Ray C dispatch 成功。")  # C=3
	_check(NAME, _dispatch_particle(env1, 1, Vector2i(12, 5), Vector2i.RIGHT) > 0, "Particle D dispatch 成功。")  # D=4
	_check(NAME, env1.controller.get_active_emission_count() == 4, "四 emission 并存 active 期望 4，实际 %d。" % [env1.controller.get_active_emission_count()])
	_check(NAME, env1.light_visual_controller.get_segment_count() == 28, "两 Ray 各 14 段总期望 28。")
	_check(NAME, env1.controller.get_particle_active_count() == 2, "两 Particle 光粒 active 期望 2。")
	# 逐个 finish（顺序一）：中途一直 PULSE_ACTIVE，active 递减。
	env1.controller.call("_finish_emission", 1, 1)  # finish A
	_check(NAME, env1.controller.get_active_emission_count() == 3 and env1.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "finish A 后 active 3 + PULSE_ACTIVE。")
	env1.controller.call("_finish_emission", 1, 2)  # finish B
	_check(NAME, env1.controller.get_active_emission_count() == 2 and env1.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "finish B 后 active 2 + PULSE_ACTIVE。")
	env1.controller.call("_finish_emission", 1, 3)  # finish C
	_check(NAME, env1.controller.get_active_emission_count() == 1 and env1.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "finish C 后 active 1 + PULSE_ACTIVE。")
	env1.controller.call("_finish_emission", 1, 4)  # finish D（最后）
	_check(NAME, env1.controller.get_active_emission_count() == 0, "最后 finish D 后 active 期望 0。")
	_check(NAME, env1.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后一个 emission 才 MOVE_WINDOW，实际 %s。" % [_state_label(env1.rsc.get_current_state())])
	# 顺序二（新 env）：D(4) → C(3) → B(2) → A(1)（逆序）。
	var env2: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env2.rsc.begin_runtime()
	env2.controller.request_fire()  # A=1
	_dispatch_particle(env2, 1, Vector2i(14, 3), Vector2i.RIGHT)  # B=2
	_dispatch_ray(env2, 1, Vector2i(1, 3), Vector2i.RIGHT)  # C=3
	_dispatch_particle(env2, 1, Vector2i(12, 5), Vector2i.RIGHT)  # D=4
	_check(NAME, env2.controller.get_active_emission_count() == 4, "顺序二前置四 emission active 期望 4。")
	env2.controller.call("_finish_emission", 1, 4)  # finish D
	_check(NAME, env2.controller.get_active_emission_count() == 3 and env2.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "逆序 finish D 后 active 3 + PULSE_ACTIVE。")
	env2.controller.call("_finish_emission", 1, 3)  # finish C
	_check(NAME, env2.controller.get_active_emission_count() == 2 and env2.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "逆序 finish C 后 active 2 + PULSE_ACTIVE。")
	env2.controller.call("_finish_emission", 1, 2)  # finish B
	_check(NAME, env2.controller.get_active_emission_count() == 1 and env2.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "逆序 finish B 后 active 1 + PULSE_ACTIVE。")
	env2.controller.call("_finish_emission", 1, 1)  # finish A（最后）
	_check(NAME, env2.controller.get_active_emission_count() == 0, "逆序最后 finish A 后 active 期望 0。")
	_check(NAME, env2.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "逆序最后 emission 才 MOVE_WINDOW，实际 %s。" % [_state_label(env2.rsc.get_current_state())])


# ===== reset 旧 Ray timer → 新 epoch visual 不受影响 =====

## 20.（item 20）旧 epoch Ray completion timer 恢复时新 epoch Ray visual 不受影响：旧 timer → _finish_emission(old_gen, old_eid) 经 generation 守卫永久 no-op，不清新 epoch emission visual。
func _test_06_reset_old_ray_timer_does_not_clear_new_epoch_visual() -> void:
	const NAME: String = "06_reset旧timer不清新epoch视觉"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()  # epoch gen=1
	env.controller.request_fire()  # emission1 RAY gen=1（14 段），其 completion timer(0.0s) 待触发。
	_check(NAME, env.controller.get_runtime_generation() == 1, "epoch1 generation 期望 1。")
	env.controller.reset_runtime()  # → epoch gen=2，SETUP，旧 timer(1) 待过期，视觉全清。
	_check(NAME, env.controller.get_runtime_generation() == 2, "reset 后 generation 期望 2。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "reset 后旧 Ray 视觉全清。")
	env.rsc.begin_runtime()  # → epoch gen=3，READY
	_check(NAME, env.controller.get_runtime_generation() == 3, "begin_runtime 后 generation 期望 3。")
	env.controller.request_fire()  # emission2 RAY gen=3（14 段），新 timer(3) 待触发。
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 14, "新 epoch emission2 视觉 14 段。")
	var seg_before: int = env.light_visual_controller.get_segment_count()
	# 模拟旧 epoch1 Ray timer 恢复（直接调 _finish_emission(gen=1, eid=1)）：generation 守卫 no-op。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_segment_count() == seg_before, "旧 timer(gen=1) 经守卫 no-op，不清新 epoch emission2 视觉（仍 %d）。" % [env.light_visual_controller.get_segment_count()])
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 14, "emission2 视觉仍 14 段（旧 timer 不影响新视觉）。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "新 epoch emission2 仍活动（active 1），旧 timer 未误 finish。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "新 epoch 脉冲仍 PULSE_ACTIVE（旧 timer 未改状态）。")


# ===== 未知 form 不进入 Ray（强化观测）=====

## 8.（item 8 强化）未知 form 不进入 RayExecutionModule：observe_ray_queries spy 直观测，未知 form dispatch 后 Ray 执行查询次数 ==0（不凭光段 0 推断）。
func _test_07_unknown_form_does_not_enter_ray_execution() -> void:
	const NAME: String = "07_未知form不进入Ray执行"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, true)
	env.rsc.begin_runtime()
	env.rsc.begin_pulse()  # 白盒进 PULSE_ACTIVE。
	var spy_before: int = env.light_world_query_spy.total_query_calls()
	_check(NAME, spy_before == 0, "前置 Ray 执行查询期望 0。")
	# 未知 form dispatch（不落入 Ray 分支）。
	var eid: int = int(env.controller.call("_dispatch_emission", 1, 99, Vector2i(1, 3), Vector2i.RIGHT))
	_check(NAME, eid == -1, "未知 form dispatch 返回 -1。")
	_check(NAME, env.light_world_query_spy.total_query_calls() == 0, "未知 form 不进入 RayExecutionModule（查询仍 0），实际 %d。" % [env.light_world_query_spy.total_query_calls()])
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "未知 form 不创建 Ray 视觉。")
	# 对照：合法 RAY dispatch 后查询 >0（证明 spy 非恒 0，反证未知 form 的 ==0 有意义）。
	_dispatch_ray(env, 1, Vector2i(1, 3), Vector2i.RIGHT)
	_check(NAME, env.light_world_query_spy.total_query_calls() > 0, "合法 RAY dispatch 后 Ray 执行查询 >0（反证 spy 有效）。")


# ===== seam 辅助 =====

## 经白盒反射调用 LRC private _dispatch_emission seam 创建一次 RAY emission（不消费 cooldown；非 public player API）。
func _dispatch_ray(env: _Fixture._Env, generation: int, cell: Vector2i, direction: Vector2i) -> int:
	return int(env.controller.call("_dispatch_emission", generation, _LightEmissionTypes.LightForm.RAY, cell, direction))


## 经白盒反射调用 LRC private _dispatch_emission seam 创建一次 PARTICLE emission（不消费 cooldown）。
func _dispatch_particle(env: _Fixture._Env, generation: int, cell: Vector2i, direction: Vector2i) -> int:
	return int(env.controller.call("_dispatch_emission", generation, _LightEmissionTypes.LightForm.PARTICLE, cell, direction))


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
	print("==== M4-E2.1 per-emission dispatch transaction 测试摘要 ====")
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
