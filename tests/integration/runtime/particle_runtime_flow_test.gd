extends SceneTree

## Particle Runtime 核心接线流程测试（D7-4 B3b-1；B3b-2.1 接口边界收口后迁移）。
## 覆盖统一 request_fire 对 RAY/PARTICLE 的 dispatch：PARTICLE 经 LevelRuntimeController → ParticleScheduler.begin_generation(_pulse_generation)
##   + emit_particle（初速 STANDARD）创建光粒；generation 唯一真值为 LRC._pulse_generation；B3b-2.1 MF-1 起 Tick 推进经可控泵 resume_one_tick()
##   （正式 0.1s 自动泵 / 测试可控泵调用同一 _on_particle_tick callback，无 public 手动 mutation 入口）；
##   R 使旧 generation 永久失效并清空旧光粒；scheduler 初始化失败最小安全失败；RAY 原路径零回归。
##   B3b-1.1 / B3b-2.1 MF-3 只读状态边界收口：get_particle_state_snapshot 直接转发 scheduler detached Dictionary（八字段值类型副本），外部修改零影响真实 state；
##   不存在 runtime_id 返回 null；R 后旧 snapshot 不再存在；public API 不暴露可调用 apply_move/terminate 的内部 state 引用。
## 不覆盖（留 B4）：Particle visual、Q 切换、真实 0.1 秒异步整轮、Mirror/Barrier。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。
## 失败路径用例会产生预期 push_error 输出，不计入失败。桩与装配见 fixtures/runtime_controller_fixture.gd。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 持有装配夹具，避免工厂/env RefCounted 在 Callable 单引用下被提前回收导致 null::method。
var _fixture: _Fixture = null


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 get_tree() 可用。
	await process_frame
	_fixture = _Fixture.new(self)
	_run_all_tests()
	_report()
	# 推进若干帧让挂起的异步协程恢复完成，避免 free controller 后协程再访问 null 实例。
	await _fixture.wait_settled(4)
	# B3b-2：使所有 Particle Tick 泵协程退出（generation 失效 + 推进帧），避免 leaked at exit。
	await _fixture.await_settle_pumps()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	_test_01_setup_rejects_particle_fire()
	_test_02_start_run_enters_ready()
	_test_03_ready_particle_fire_success_and_pulse_active()
	_test_04_scheduler_generation_matches_lrc()
	_test_05_emitted_particle_initial_state()
	_test_06_diagonal_particle_can_be_created()
	_test_07_particle_does_not_build_fire_request()
	_test_08_invalid_direction_rejected_before_begin_pulse()
	_test_09_pulse_active_rejects_fire()
	_test_10_reset_returns_to_setup()
	_test_11_reset_clears_active_particles()
	_test_12_reset_invalidates_old_generation_advance()
	_test_13_reset_requires_begin_runtime_to_refire()
	_test_14_orthogonal_standard_first_move_at_tick_4()
	_test_15_diagonal_standard_first_move_at_tick_6()
	_test_16_scheduler_init_failure_safe_fails()
	_test_17_ray_path_still_works()
	# B3b-1.1 只读状态边界收口：snapshot 字段、detached、null、R 失效、raw accessor 不再泄漏。
	_test_18_snapshot_fields_complete_and_correct()
	_test_19_nonexistent_runtime_id_returns_null()
	_test_20_snapshot_detached_modifications_do_not_affect_real()
	_test_21_snapshot_modifications_do_not_block_real_propagation()
	_test_22_no_public_path_to_apply_move_terminate()


# ===== 测试用例 =====

## 1. SETUP 直接 Particle request_fire 拒绝：未 begin_runtime 时 request_fire 返回 false，不进入 PULSE_ACTIVE。
func _test_01_setup_rejects_particle_fire() -> void:
	const NAME: String = "01_SETUP拒绝Particle发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "SETUP Particle request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "应保持 SETUP。")
	_check(NAME, env.controller.get_runtime_generation() == 0, "generation 不应递增，期望 0。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "不应创建光粒。")


## 2. Start Run → READY：begin_runtime 后状态为 READY_TO_FIRE。
func _test_02_start_run_enters_ready() -> void:
	const NAME: String = "02_StartRun进入READY"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "begin_runtime 后应 READY_TO_FIRE。")


## 3. READY Particle request_fire 成功：返回 true，进入 PULSE_ACTIVE，generation 递增。
func _test_03_ready_particle_fire_success_and_pulse_active() -> void:
	const NAME: String = "03_READY发射成功进入PULSE_ACTIVE"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "READY Particle request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_runtime_generation() == 1, "generation 期望 1。")


## 4. scheduler generation == LRC pulse_generation：PARTICLE 发射后镜像与真值相等。
func _test_04_scheduler_generation_matches_lrc() -> void:
	const NAME: String = "04_scheduler_generation等于LRC"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_particle_generation() == env.controller.get_runtime_generation(), "scheduler generation 镜像 %d 应等于 LRC pulse_generation %d。" % [env.controller.get_particle_generation(), env.controller.get_runtime_generation()])
	# 光粒 snapshot.generation 也必须等于 pulse_generation（rid 0 为 fresh 调度器首次 emit）。
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "应存在 rid 0 光粒 snapshot。"):
		_check(NAME, snapshot["generation"] == env.controller.get_runtime_generation(), "光粒 generation %d 应等于 pulse_generation %d。" % [snapshot["generation"], env.controller.get_runtime_generation()])


## 5. emitted Particle 初始 state：count==1、speed==STANDARD、cell==emitter cell、direction==emitter active direction、active==true。
func _test_05_emitted_particle_initial_state() -> void:
	const NAME: String = "05_emitted光粒初始state"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_particle_active_count() == 1, "活动光粒期望 1，实际 %d。" % [env.controller.get_particle_active_count()])
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "应存在 rid 0 光粒 snapshot。"):
		_check(NAME, snapshot["active"] == true, "光粒应 active。")
		_check(NAME, snapshot["speed_tier"] == _ParticleMotionRules.SpeedTier.STANDARD, "初速期望 STANDARD，实际 %d。" % [snapshot["speed_tier"]])
		_check(NAME, snapshot["cell"] == Vector2i(1, 3), "光粒 cell 期望 emitter cell (1,3)，实际 %s。" % [snapshot["cell"]])
		_check(NAME, snapshot["direction"] == Vector2i.RIGHT, "光粒 direction 期望 emitter active direction RIGHT，实际 %s。" % [snapshot["direction"]])


## 6. 斜向 Particle 可以创建：DOWN_RIGHT 方向发射，光粒存在且方向为 (1,1)。
func _test_06_diagonal_particle_can_be_created() -> void:
	const NAME: String = "06_斜向光粒可创建"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(2, 2), Vector2i(1, 1), null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "斜向 Particle request_fire 应返回 true。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "斜向光粒期望 1。")
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "应存在 rid 0 斜向光粒 snapshot。"):
		_check(NAME, snapshot["direction"] == Vector2i(1, 1), "斜向光粒 direction 期望 (1,1)，实际 %s。" % [snapshot["direction"]])
		_check(NAME, snapshot["next_move_tick"] == 6, "斜向 STANDARD next_move_tick 期望 6，实际 %d。" % [snapshot["next_move_tick"]])


## 7. PARTICLE 不构造 FireRequest：发射后无 Ray 执行（Ray 必经查询签名为 0）、无光路视觉段。
func _test_07_particle_does_not_build_fire_request() -> void:
	const NAME: String = "07_PARTICLE不构造FireRequest"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, true, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# M4-E4 前：PARTICLE 发射零世界查询即可证明未走 Ray；M4-E4 起 LRC 发射期前瞻合法只读 is_in_bounds/is_wall_cell（至多各 1 次），
	# 故改用 Ray 必经签名证明：RayExecutionModule.execute 每步必查 has_crystal_at + get_light_mechanism_at（发射即刻执行第一步），
	# 二者为 0 且总查询 <=2 即证明 Ray/FireRequest 路径从未启动（本测试用可控泵，Tick 未推进，executor 亦未查询）。
	_check(NAME, env.light_world_query_spy != null, "应注入 Ray 查询 spy。")
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.has_crystal_at_calls == 0 and env.light_world_query_spy.get_light_mechanism_at_calls == 0,
			"PARTICLE 发射不应触发 Ray 必经查询（has_crystal_at/get_light_mechanism_at 应为 0，实际 %d/%d）。" % [env.light_world_query_spy.has_crystal_at_calls, env.light_world_query_spy.get_light_mechanism_at_calls])
		_check(NAME, env.light_world_query_spy.total_query_calls() <= 2,
			"PARTICLE 发射世界查询应仅 M4-E4 前瞻至多 2 次（is_in_bounds+is_wall_cell），实际 %d。" % env.light_world_query_spy.total_query_calls())
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "PARTICLE 发射不应创建光路视觉段，期望 0，实际 %d。" % [env.light_visual_controller.get_segment_count()])


## 8. 非法方向先于 begin_pulse 拒绝（PARTICLE）：direction=ZERO 时 request_fire 返回 false 且未进入 PULSE_ACTIVE。
func _test_08_invalid_direction_rejected_before_begin_pulse() -> void:
	const NAME: String = "08_非法方向先于begin_pulse拒绝"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.ZERO, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "非法方向 Particle request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "不得进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：begin_runtime 已推进 generation 到 1（fire 被拒不再变化）。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "不应创建光粒。")


## 9. PULSE_ACTIVE 中 cooldown 未到拒绝 repeated fire（M4-E3 语义更新）：状态权限已允许，拒绝来自 0.5s cooldown；generation 不变、光粒不翻倍。
func _test_09_pulse_active_rejects_fire() -> void:
	const NAME: String = "09_PULSE_ACTIVEcooldown未到拒绝"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var gen_before: int = env.controller.get_runtime_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "PULSE_ACTIVE cooldown 未到时再 fire 应返回 false。")
	_check(NAME, env.controller.get_runtime_generation() == gen_before, "generation 不应变化。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "光粒数量不应翻倍，期望 1。")


## 10. R 后回 SETUP：PARTICLE 发射 → R 后状态 SETUP。
func _test_10_reset_returns_to_setup() -> void:
	const NAME: String = "10_R后回SETUP"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	env.controller.reset_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应回 SETUP。")


## 11. R 后 active Particle == 0：R 清空旧活动光粒。
func _test_11_reset_clears_active_particles() -> void:
	const NAME: String = "11_R后active光粒为0"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_particle_active_count() == 1, "前置应有 1 颗光粒。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_particle_active_count() == 0, "R 后活动光粒期望 0，实际 %d。" % [env.controller.get_particle_active_count()])
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "rid 0 旧光粒 snapshot 应为 null（已移出活动索引）。")


## 12. R 后旧 generation 推进永久 no-op：R 后连续可控泵 resume，光粒数量恒 0、current_tick 不推进、旧链 callback 永久 no-op。
func _test_12_reset_invalidates_old_generation_advance() -> void:
	const NAME: String = "12_R后旧generation推进永久no-op"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.controller.reset_runtime()
	# R 后旧泵链（expected=旧 generation）仍挂在可控泵上；连续 resume 8 次，旧链 callback 每次经 _on_particle_tick 首行 generation mismatch 永久 no-op。
	# 旧光粒已被 begin_generation 清空，不可被推进或复活；current_tick 保持 0。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_active_count() == 0, "8 次 resume 后活动光粒仍期望 0。")
	_check(NAME, env.controller.get_particle_tick() == 0, "R 后旧链不得推进 current_tick，期望 0，实际 %d。" % [env.controller.get_particle_tick()])
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "rid 0 旧光粒 snapshot 应为 null。")


## 13. R 后必须重新 Start Run 才能再次发射：R → SETUP 直接 fire 被拒；再 begin_runtime → READY 后 fire 成功。
func _test_13_reset_requires_begin_runtime_to_refire() -> void:
	const NAME: String = "13_R后需重新StartRun才能再发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.controller.reset_runtime()
	# R 后 SETUP 直接 fire 必须被拒。
	var ok_setup: bool = env.controller.request_fire()
	_check(NAME, not ok_setup, "R 后 SETUP 直接 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "应保持 SETUP。")
	# 重新 Start Run → READY 后 fire 成功。
	env.rsc.begin_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "重新 begin_runtime 后应 READY_TO_FIRE。")
	var ok_refire: bool = env.controller.request_fire()
	_check(NAME, ok_refire, "重新 Start Run 后 request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应再次进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "再次发射应创建 1 颗光粒。")


## 14. 正交 STANDARD 前 3 Tick 不移动、第 4 Tick 移动：emit(1,3) RIGHT，next_move_tick=4。
func _test_14_orthogonal_standard_first_move_at_tick_4() -> void:
	const NAME: String = "14_正交STANDARD前3不移动第4移动"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, snapshot != null, "前置应存在 rid 0 光粒 snapshot。"):
		return
	# Tick 1~3：resume 推进整数 Tick 但光粒 due=4 未到，cell 不变（每 Tick 后重新取只读快照确认真实 cell 未动）。
	for i in 3:
		env.particle_tick_pump.resume_one_tick()
		var cur: Variant = env.controller.get_particle_state_snapshot(0)
		_check(NAME, cur != null and cur["cell"] == Vector2i(1, 3), "第 %d Tick 后 cell 应仍为 (1,3)。" % [i + 1])
	_check(NAME, env.controller.get_particle_tick() == 3, "3 次 resume 后 current_tick 期望 3，实际 %d。" % [env.controller.get_particle_tick()])
	# 第 4 Tick：resume 推进到 due=4，光粒 MOVE 前进一格到 (2,3)（经只读快照确认；事件细节由 scheduler 单元测试覆盖）。
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 4, "第 4 次 resume 后 current_tick 期望 4，实际 %d。" % [env.controller.get_particle_tick()])
	var after: Variant = env.controller.get_particle_state_snapshot(0)
	_check(NAME, after != null and after["cell"] == Vector2i(2, 3), "第 4 Tick 后光粒 cell 期望 (2,3)，实际 %s。" % [after["cell"] if after != null else "null"])
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "光粒仍 active（next_move_tick=8 未 drain），应仍 PULSE_ACTIVE。")


## 15. 斜向 STANDARD 前 5 Tick 不移动、第 6 Tick 移动：emit(2,2) DOWN_RIGHT，next_move_tick=6。
func _test_15_diagonal_standard_first_move_at_tick_6() -> void:
	const NAME: String = "15_斜向STANDARD前5不移动第6移动"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(2, 2), Vector2i(1, 1), null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, snapshot != null, "前置应存在 rid 0 斜向光粒 snapshot。"):
		return
	# Tick 1~5：resume 推进整数 Tick 但光粒 due=6 未到，cell 不变（每 Tick 后重新取只读快照确认真实 cell 未动）。
	for i in 5:
		env.particle_tick_pump.resume_one_tick()
		var cur: Variant = env.controller.get_particle_state_snapshot(0)
		_check(NAME, cur != null and cur["cell"] == Vector2i(2, 2), "第 %d Tick 后 cell 应仍为 (2,2)。" % [i + 1])
	_check(NAME, env.controller.get_particle_tick() == 5, "5 次 resume 后 current_tick 期望 5，实际 %d。" % [env.controller.get_particle_tick()])
	# 第 6 Tick：resume 推进到 due=6，光粒 MOVE 前进一斜格到 (3,3)。
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 6, "第 6 次 resume 后 current_tick 期望 6，实际 %d。" % [env.controller.get_particle_tick()])
	var after: Variant = env.controller.get_particle_state_snapshot(0)
	_check(NAME, after != null and after["cell"] == Vector2i(3, 3), "第 6 Tick 后光粒 cell 期望 (3,3)，实际 %s。" % [after["cell"] if after != null else "null"])


## 16. scheduler 镜像不一致最小安全失败（M4-E1）：毒化 scheduler 镜像到高位，request_fire 内 _begin_particle_pulse 的 generation 一致性校验（scheduler.get_current_generation() != current_generation）失败 → safe-fail，退到 MOVE_WINDOW，不留 PULSE_ACTIVE 半状态。
func _test_16_scheduler_init_failure_safe_fails() -> void:
	const NAME: String = "16_scheduler镜像不一致最小安全失败"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	# 毒化：把 scheduler 镜像提前绑到高位 999，使 request_fire 内 generation 一致性校验（current_generation=1 != 999）必失败 → safe-fail。
	var scheduler: Variant = env.controller.get("_particle_scheduler")
	if not _check(NAME, scheduler != null, "应能取到 _particle_scheduler。"):
		return
	scheduler.begin_generation(999)
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "scheduler 初始化失败时 request_fire 应返回 false。")
	_check(NAME, not env.rsc.is_current_pulse_active(), "不得留下 PULSE_ACTIVE 半状态。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "应经 finish_pulse(false) 安全退到 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_particle_active_count() == 0, "失败不应留下活动光粒，期望 0。")


## 17. RAY request_fire 原路径仍工作（零回归）：RAY env 发射后进入 PULSE_ACTIVE、产生光路视觉段、Ray 执行查询世界。
func _test_17_ray_path_still_works() -> void:
	const NAME: String = "17_RAY原路径仍工作"
	# 默认 light_form=RAY + observe_ray_queries=true 注入 spy。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, true)
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "RAY request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "RAY 应进入 PULSE_ACTIVE。")
	_check(NAME, env.light_visual_controller.get_segment_count() > 0, "RAY 应产生光路视觉段，实际 %d。" % [env.light_visual_controller.get_segment_count()])
	_check(NAME, env.light_world_query_spy != null, "应注入 Ray 查询 spy。")
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.total_query_calls() > 0, "RAY 应执行 RayExecutionModule 查询世界，期望 >0，实际 %d。" % [env.light_world_query_spy.total_query_calls()])
	_check(NAME, env.controller.get_particle_active_count() == 0, "RAY 发射不应创建光粒，期望 0。")


# ===== B3b-1.1 只读状态边界收口（snapshot detached copy） =====

## 18. snapshot 八字段完整且值正确：emit(1,3) RIGHT STANDARD 后 snapshot 恰含 8 键且各值与真实 state 一致。
func _test_18_snapshot_fields_complete_and_correct() -> void:
	const NAME: String = "18_snapshot字段完整且值正确"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, snapshot != null, "应存在 rid 0 光粒 snapshot。"):
		return
	# 键集合完整：恰好 8 字段。
	var expected_keys: Array = ["runtime_id", "generation", "cell", "direction", "speed_tier", "step_started_tick", "next_move_tick", "active"]
	if _check(NAME, snapshot is Dictionary, "snapshot 应为 Dictionary。"):
		for k: String in expected_keys:
			_check(NAME, snapshot.has(k), "snapshot 应含键 %s。" % k)
		_check(NAME, snapshot.keys().size() == expected_keys.size(), "snapshot 键数期望 %d，实际 %d。" % [expected_keys.size(), snapshot.keys().size()])
	# 值正确（覆盖 runtime_id/generation/cell/direction/speed_tier/step_started_tick/next_move_tick/active）。
	_check(NAME, snapshot["runtime_id"] == 0, "runtime_id 期望 0，实际 %d。" % [snapshot["runtime_id"]])
	_check(NAME, snapshot["generation"] == 1, "generation 期望 1（=pulse_generation），实际 %d。" % [snapshot["generation"]])
	_check(NAME, snapshot["cell"] == Vector2i(1, 3), "cell 期望 (1,3)，实际 %s。" % [snapshot["cell"]])
	_check(NAME, snapshot["direction"] == Vector2i.RIGHT, "direction 期望 RIGHT，实际 %s。" % [snapshot["direction"]])
	_check(NAME, snapshot["speed_tier"] == _ParticleMotionRules.SpeedTier.STANDARD, "speed_tier 期望 STANDARD，实际 %d。" % [snapshot["speed_tier"]])
	_check(NAME, snapshot["step_started_tick"] == 0, "step_started_tick 期望 0（emitted at tick 0），实际 %d。" % [snapshot["step_started_tick"]])
	_check(NAME, snapshot["next_move_tick"] == 4, "next_move_tick 期望 4（正交 STANDARD），实际 %d。" % [snapshot["next_move_tick"]])
	_check(NAME, snapshot["active"] == true, "active 期望 true。")


## 19. 不存在 runtime_id → null：未发射时 rid 0/999 均为 null；发射后 rid 0 非空但 rid 999 仍为 null。
func _test_19_nonexistent_runtime_id_returns_null() -> void:
	const NAME: String = "19_不存在runtime_id返回null"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "未发射时 rid 0 snapshot 应为 null。")
	_check(NAME, env.controller.get_particle_state_snapshot(999) == null, "未发射时 rid 999 snapshot 应为 null。")
	env.controller.request_fire()
	_check(NAME, env.controller.get_particle_state_snapshot(0) != null, "发射后 rid 0 snapshot 应非 null。")
	_check(NAME, env.controller.get_particle_state_snapshot(999) == null, "发射后 rid 999 snapshot 应为 null。")


## 20. snapshot detached：篡改 snapshot 全部八字段后，重新取只读快照仍反映真实原值（外部修改零影响真实 state）。
func _test_20_snapshot_detached_modifications_do_not_affect_real() -> void:
	const NAME: String = "20_snapshot修改不影响真实state"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, snapshot != null, "前置应存在 rid 0 光粒 snapshot。"):
		return
	# 篡改 snapshot 全部字段（含 spec 列出的 cell/direction/speed_tier/generation/active 及其余键）。
	snapshot["runtime_id"] = 999
	snapshot["generation"] = 999
	snapshot["cell"] = Vector2i(-5, -5)
	snapshot["direction"] = Vector2i.LEFT
	snapshot["speed_tier"] = _ParticleMotionRules.SpeedTier.FAST
	snapshot["step_started_tick"] = 999
	snapshot["next_move_tick"] = 999
	snapshot["active"] = false
	# 重新取只读快照——必须仍反映真实原值，证明 snapshot 与内部 state 脱离。
	var fresh: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, fresh != null, "真实光粒应仍存在（snapshot 篡改不应回收光粒）。"):
		return
	_check(NAME, fresh["runtime_id"] == 0, "runtime_id 仍期望 0，实际 %d。" % [fresh["runtime_id"]])
	_check(NAME, fresh["generation"] == 1, "generation 仍期望 1，实际 %d。" % [fresh["generation"]])
	_check(NAME, fresh["cell"] == Vector2i(1, 3), "cell 仍期望 (1,3)，实际 %s。" % [fresh["cell"]])
	_check(NAME, fresh["direction"] == Vector2i.RIGHT, "direction 仍期望 RIGHT，实际 %s。" % [fresh["direction"]])
	_check(NAME, fresh["speed_tier"] == _ParticleMotionRules.SpeedTier.STANDARD, "speed_tier 仍期望 STANDARD，实际 %d。" % [fresh["speed_tier"]])
	_check(NAME, fresh["step_started_tick"] == 0, "step_started_tick 仍期望 0，实际 %d。" % [fresh["step_started_tick"]])
	_check(NAME, fresh["next_move_tick"] == 4, "next_move_tick 仍期望 4，实际 %d。" % [fresh["next_move_tick"]])
	_check(NAME, fresh["active"] == true, "active 仍期望 true。")


## 21. 篡改 snapshot 后推进 Tick，真实光粒仍按原状态正常传播：前 3 Tick 无移动，第 4 Tick MOVE 到 (2,3)。
func _test_21_snapshot_modifications_do_not_block_real_propagation() -> void:
	const NAME: String = "21_篡改snapshot后真实光粒仍正常传播"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if not _check(NAME, snapshot != null, "前置应存在 rid 0 光粒 snapshot。"):
		return
	# 篡改 snapshot 关键字段（cell/direction/speed_tier/active）为完全不同的值。
	snapshot["cell"] = Vector2i(99, 99)
	snapshot["direction"] = Vector2i.LEFT
	snapshot["speed_tier"] = _ParticleMotionRules.SpeedTier.FAST
	snapshot["active"] = false
	# resume 推进 3 Tick：真实光粒仍 due=4，故 cell 不变（snapshot 篡改零影响真实 due）。
	for i in 3:
		env.particle_tick_pump.resume_one_tick()
		var cur: Variant = env.controller.get_particle_state_snapshot(0)
		_check(NAME, cur != null and cur["cell"] == Vector2i(1, 3), "第 %d Tick 后真实 cell 应仍为 (1,3)（due=4 未被 snapshot 篡改影响）。" % [i + 1])
	# 第 4 Tick：真实光粒按原状态 MOVE 到 (2,3)。
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 4, "第 4 次 resume 后 current_tick 期望 4，实际 %d。" % [env.controller.get_particle_tick()])
	# 推进后只读快照反映真实传播结果，而非被篡改值。
	var fresh: Variant = env.controller.get_particle_state_snapshot(0)
	_check(NAME, fresh != null and fresh["cell"] == Vector2i(2, 3), "snapshot 应反映真实传播 (2,3)，非被篡改值，实际 %s。" % [fresh["cell"] if fresh != null else "null"])
	_check(NAME, fresh != null and fresh["active"] == true, "真实光粒仍 active，未被 snapshot 篡改影响。")


## 22. public LRC API 不再泄漏可调用 apply_move/terminate 的内部 state 引用：snapshot 为 Dictionary（无方法表），raw accessor 已移除。
func _test_22_no_public_path_to_apply_move_terminate() -> void:
	const NAME: String = "22_public_API不再泄漏apply_move_terminate"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	# snapshot 必须是 Dictionary（值类型容器），而非内部 ParticleRuntimeState 对象。
	_check(NAME, snapshot is Dictionary, "snapshot 必须是 Dictionary，不得是内部 state 对象引用。")
	# raw accessor 已从 public API 移除；新只读快照 API 存在。
	_check(NAME, not env.controller.has_method("get_particle_state"), "LRC public API 不应再暴露 raw get_particle_state。")
	_check(NAME, env.controller.has_method("get_particle_state_snapshot"), "LRC 应暴露 get_particle_state_snapshot。")
	# Dictionary 无方法表，apply_move/terminate 既非方法也非键——内部 state 引用未泄漏。
	if snapshot is Dictionary:
		_check(NAME, not snapshot.has("apply_move"), "snapshot 不得含 apply_move 入口。")
		_check(NAME, not snapshot.has("terminate"), "snapshot 不得含 terminate 入口。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## RunState 值映射为人类可读名称，用于失败明细。
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


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 22
	var passed_checks: int = _checks - _failures.size()
	print("==== Particle Runtime 核心接线流程测试摘要（D7-4 B3b-1）====")
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
