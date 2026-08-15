extends SceneTree

## Particle Runtime 异步生命周期测试（D7-4 B3b-2；B3b-2.1 接口边界收口后迁移为可控泵驱动）。
## 覆盖 PARTICLE request_fire → PULSE_ACTIVE → 可控泵 resume → _on_particle_tick → scheduler.advance_one_tick → BatchEvent → Crystal 命中 → drain → 复用现有 pulse 完成逻辑 → MOVE_WINDOW/COMPLETED。
##   重点证明三件事：① pump resume 驱动恰好一个整数 Tick（不证明真实墙钟 0.1 秒）；② generation await cancellation 成立（R 后旧链 callback no-op）；③ drain/finish 自动发生。
##   并覆盖 Terrain 外 / 墙体 terminate → drain、Crystal 命中复用 ObjectiveController、"Objective 已满足但未 drain 仍 PULSE_ACTIVE"、同 Tick 多光粒推进、R 后新 pulse 隔离（第一 Tick 精确 ==1）。
## 整数传播逻辑（due-batch / 顺序 / terminate reason）由 scheduler 单元测试覆盖，本片不重复；正交/斜向 due=4/6 由 B3b-1 flow_test test_14/15 覆盖。
## B3b-2.1 MF-1/MF-2：测试经 fixture 注入 tests/** 可控泵替身，resume_one_tick() 驱动技术 timer seam——不真实等待 0.1 秒（cadence 唯一来源为正式泵常量，测试不触碰）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。
## 失败路径用例会产生预期 push_error 输出，不计入失败。桩与装配见 fixtures/runtime_controller_fixture.gd。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
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
	# 推进若干帧让挂起的异步协程恢复完成（PARTICLE 经可控泵已同步完成；此为防御性收尾）。
	await _fixture.wait_settled(4)
	# 使所有 Particle Tick 泵协程退出（generation 失效 + 推进帧），避免 leaked at exit。
	await _fixture.await_settle_pumps()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组；可控泵 resume 同步驱动 Tick，用例无需 await。
func _run_all_tests() -> void:
	_test_01_fire_starts_pump_and_cell_advances()
	_test_02_current_tick_integer_increments()
	_test_03_single_tick_chain_per_pulse()
	_test_04_terrain_out_of_bounds_terminates()
	_test_05_wall_terminates()
	_test_06_drain_active_count_zero()
	_test_07_drain_unfinished_enters_move_window()
	_test_08_particle_hits_crystal_activates_objective()
	_test_09_objective_satisfied_but_not_drained_stays_pulse_active()
	_test_10_drain_objective_satisfied_enters_completed()
	_test_11_multi_particle_event_order_preserved()
	_test_12_r_during_await_invalidates_old_chain()
	_test_13_new_pulse_isolated_after_reset()


# ===== 测试用例 =====

## 1. fire 后泵已就绪并推进：emitter(1,3) RIGHT，6 次 resume 后光粒到 (2,3)（tick4 MOVE），证明 pump resume 驱动整数 Tick。
func _test_01_fire_starts_pump_and_cell_advances() -> void:
	const NAME: String = "01_fire启动泵并推进"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "PARTICLE request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")
	_check(NAME, env.particle_tick_pump.is_started(), "fire 后可控泵应已就绪（run 已被调用）。")
	for i in 6:
		env.particle_tick_pump.resume_one_tick()
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "光粒应仍存在（未越界）。"):
		_check(NAME, snapshot["cell"] == Vector2i(2, 3), "tick4 后光粒应到 (2,3)，实际 %s。" % [snapshot["cell"]])
	_check(NAME, env.controller.get_particle_active_count() == 1, "光粒应仍 active（未 drain）。")


## 2. current_tick 整数递增：fire 后 3 次 resume→current_tick==3，再 2 次 resume→==5；证明 pump resume 每次恰好推进一个整数 Tick。
func _test_02_current_tick_integer_increments() -> void:
	const NAME: String = "02_current_tick整数递增"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	for i in 3:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 3, "3 次 resume 后 current_tick 期望 3，实际 %d。" % [env.controller.get_particle_tick()])
	for i in 2:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 5, "再 2 次 resume 后 current_tick 期望 5，实际 %d。" % [env.controller.get_particle_tick()])


## 3. 一个 pulse 只有一条 Tick 链：5 次 resume 后 current_tick==5（不是 10）；双链会翻倍，故 ==5 证明单链。
func _test_03_single_tick_chain_per_pulse() -> void:
	const NAME: String = "03_单条Tick链"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	for i in 5:
		env.particle_tick_pump.resume_one_tick()
	# 单链：5 次 resume = 5 Tick。若存在第二条链，每次 resume 会 advance 两次，current_tick 应为 10。
	_check(NAME, env.controller.get_particle_tick() == 5, "单链下 current_tick 期望 5，实际 %d（若为 10 则存在重复链）。" % [env.controller.get_particle_tick()])
	_check(NAME, env.particle_tick_pump.active_chain_count() == 1, "应只有 1 条活动 pump 链，实际 %d。" % [env.particle_tick_pump.active_chain_count()])


## 4. Terrain 外最终 TERMINATE → drain：emitter(14,3) RIGHT，8 次 resume 后第 8 Tick 尝试 (16,3) 越界 → 终止 → drain → MOVE_WINDOW（terminate reason 由 scheduler 单元测试 test_22 覆盖）。
func _test_04_terrain_out_of_bounds_terminates() -> void:
	const NAME: String = "04_地形外最终terminate"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# 正交 STANDARD due=4：tick1~3 无移动，tick4 MOVE 到 (15,3)，tick5~7 无移动，tick8 尝试 (16,3) 越界 → terminate → drain → finish。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_active_count() == 0, "越界 terminate 后 active 期望 0。")
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "rid 0 应已移出活动索引，snapshot 为 null。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "drain 未完成应进 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


## 5. 墙体最终 TERMINATE → drain：emitter(1,3) RIGHT + wall(2,3)，4 次 resume 后第 4 Tick 尝试 (2,3) 墙 → 终止 → drain → MOVE_WINDOW。
func _test_05_wall_terminates() -> void:
	const NAME: String = "05_墙体最终terminate"
	var walls: Array[Vector2i] = [Vector2i(2, 3)]
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE, walls)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	for i in 4:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_active_count() == 0, "墙体 terminate 后 active 期望 0。")
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "rid 0 应已移出活动索引，snapshot 为 null。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "drain 未完成应进 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


## 6. drain 后 active count=0：越界 terminate 后光粒移出 _active_states，active_count==0。
func _test_06_drain_active_count_zero() -> void:
	const NAME: String = "06_drain后active为0"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_particle_active_count() == 1, "前置应有 1 颗活动光粒。")
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_active_count() == 0, "越界 terminate 后 active 期望 0，实际 %d。" % [env.controller.get_particle_active_count()])
	_check(NAME, env.controller.get_particle_state_snapshot(0) == null, "rid 0 应已移出活动索引，snapshot 为 null。")


## 7. drain + Objective 未完成 → MOVE_WINDOW：emitter(14,3) RIGHT 无水晶，resume 至 drain → MOVE_WINDOW。
##   B3b-2.1 第十九项加强：drain 前最后一条活动光粒仍在时保持 PULSE_ACTIVE；drain Tick 才 finish；drain 后额外 resume 不再增加 Tick。
func _test_07_drain_unfinished_enters_move_window() -> void:
	const NAME: String = "07_drain未完成进MOVE_WINDOW"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# drain 前最后一条光粒仍 active：推进到 tick7（tick4 已 MOVE 到 (15,3)，tick8 才越界），此时仍 PULSE_ACTIVE。
	for i in 7:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 7, "drain 前推进到 tick7，期望 7。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "drain 前最后一条光粒仍在时应 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "drain 前应仍有 1 颗活动光粒。")
	# drain Tick（tick8 越界 terminate）才 finish → MOVE_WINDOW。
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "drain Tick 应 finish 进 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, not env.objective_controller.is_completed(), "无水晶应未完成。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "drain 后 active 期望 0。")
	# drain 后额外 resume 不再增加 Tick（泵链已停，callback 因非 PULSE_ACTIVE 返回 false）。
	var tick_after_drain: int = env.controller.get_particle_tick()
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == tick_after_drain, "drain 后额外 resume 不应增加 Tick，期望 %d，实际 %d。" % [tick_after_drain, env.controller.get_particle_tick()])


## 8. Particle 命中 Crystal → 复用 ObjectiveController 激活：crystal(2,3)，4 次 resume 后 tick4 MOVE 到 (2,3) has_crystal → 激活。
func _test_08_particle_hits_crystal_activates_objective() -> void:
	const NAME: String = "08_命中Crystal复用Objective激活"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(2, 3), 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, not env.objective_controller.is_completed(), "命中前应未完成。")
	for i in 4:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.objective_controller.is_completed(), "第 4 Tick 命中 (2,3) 水晶后应完成。")
	_check(NAME, env.objective_controller.get_activated_count() == 1, "应激活 1 颗水晶，实际 %d。" % [env.objective_controller.get_activated_count()])


## 9. Crystal 已满足但光粒未 drain → 仍 PULSE_ACTIVE：crystal(2,3)，6 次 resume 后水晶已激活但光粒仍 active。
func _test_09_objective_satisfied_but_not_drained_stays_pulse_active() -> void:
	const NAME: String = "09_目标满足未drain仍PULSE_ACTIVE"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(2, 3), 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	for i in 6:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.objective_controller.is_completed(), "tick4 命中水晶后目标应已满足。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "未 drain 前不得提前进 COMPLETED，应仍 PULSE_ACTIVE，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_particle_active_count() == 1, "光粒应仍 active（未 drain）。")


## 10. drain + 目标满足 → COMPLETED：emitter(14,3) RIGHT + crystal(15,3)，resume 至泵停 → tick4 激活水晶，tick8 越界 drain → COMPLETED。
func _test_10_drain_objective_satisfied_enters_completed() -> void:
	const NAME: String = "10_drain目标满足进COMPLETED"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, Vector2i(15, 3), 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	while env.particle_tick_pump.resume_one_tick():
		pass
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "drain + 目标满足应进 COMPLETED，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.objective_controller.is_completed(), "目标应已完成。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "drain 后 active 期望 0。")


## 11. 同 Tick 多光粒推进（确定性）：反射注入第二颗 rid1，4 次 resume 后第 4 Tick 两颗同 due 各推进一格（同 Tick 顺序稳定性由 scheduler 单元测试 test_23 覆盖）。
func _test_11_multi_particle_event_order_preserved() -> void:
	const NAME: String = "11_同Tick多光粒推进"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# 反射注入第二颗光粒 rid1 at (1,1) RIGHT（与 rid0 同 due=4）；request_fire 只 emit 1 颗。
	var scheduler: Variant = env.controller.get("_particle_scheduler")
	if not _check(NAME, scheduler != null, "应能取到 _particle_scheduler。"):
		return
	var rid1: int = scheduler.emit_particle(Vector2i(1, 1), Vector2i.RIGHT)
	_check(NAME, rid1 == 1, "第二颗光粒 runtime_id 期望 1，实际 %d。" % [rid1])
	_check(NAME, env.controller.get_particle_active_count() == 2, "应有 2 颗活动光粒。")
	for i in 4:
		env.particle_tick_pump.resume_one_tick()
	# 两颗各推进一格：rid0 (1,3)→(2,3)，rid1 (1,1)→(2,1)。
	var s0: Variant = env.controller.get_particle_state_snapshot(0)
	var s1: Variant = env.controller.get_particle_state_snapshot(1)
	_check(NAME, s0 != null and s0["cell"] == Vector2i(2, 3), "rid0 应推进到 (2,3)，实际 %s。" % [s0["cell"] if s0 != null else "null"])
	_check(NAME, s1 != null and s1["cell"] == Vector2i(2, 1), "rid1 应推进到 (2,1)，实际 %s。" % [s1["cell"] if s1 != null else "null"])
	_check(NAME, env.controller.get_particle_active_count() == 2, "两颗应仍 active（next_move_tick=8 未 drain）。")


## 12. R 后旧泵链 callback 永久 no-op（generation cancellation）：fire gen1 → R gen2 → 连续 resume，旧链 callback 经 _on_particle_tick 首行 generation mismatch 永久 no-op，current_tick 保持 0。
func _test_12_r_during_await_invalidates_old_chain() -> void:
	const NAME: String = "12_R后旧链callback永久no-op"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var gen_before: int = env.controller.get_runtime_generation()
	_check(NAME, gen_before == 1, "前置 generation 期望 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	_check(NAME, env.particle_tick_pump.active_chain_count() == 1, "fire 后应有 1 条活动 pump 链。")
	# 立即 R（旧链仍挂起）：递增 generation + 清空光粒 + 回 SETUP。
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_runtime_generation() == 2, "R 后 generation 期望 2。")
	# 连续 resume 触发旧链 callback：_on_particle_tick(1) 首行 generation(1)!=_pulse_generation(2) → 返回 false，不 advance / 不 finish / 不切状态。
	for i in 5:
		env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应保持 SETUP，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_particle_tick() == 0, "旧链不得推进 current_tick，期望 0，实际 %d。" % [env.controller.get_particle_tick()])
	_check(NAME, env.controller.get_particle_active_count() == 0, "R 后活动光粒期望 0。")
	_check(NAME, env.particle_tick_pump.active_chain_count() == 0, "旧链 resume 后应已停止，活动链期望 0，实际 %d。" % [env.particle_tick_pump.active_chain_count()])


## 13. R 后重新 Start Run + fire，新 pulse 不受旧链影响：fire gen1 → R gen2 → 重新 begin_runtime + fire gen3 → 第一 Tick 精确 ==1（证明旧链未额外推进新 pulse）→ 自动 drain → MOVE_WINDOW，gen==3。
func _test_13_new_pulse_isolated_after_reset() -> void:
	const NAME: String = "13_R后新pulse隔离"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.controller.reset_runtime()
	env.rsc.begin_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "重新 begin_runtime 后应 READY_TO_FIRE。")
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "重新 Start Run 后 request_fire 应返回 true。")
	_check(NAME, env.controller.get_runtime_generation() == 3, "新 pulse generation 期望 3，实际 %d。" % [env.controller.get_runtime_generation()])
	# 第一 Tick 精确 ==1：旧链（gen1）与新链（gen3）并存，resume 触发两者——旧链 gen mismatch no-op，新链恰好推进一次。
	# 若旧链额外推进了新 pulse，current_tick 应为 2；==1 证明旧链未污染新 pulse（B3b-2.1 第十八项）。
	env.particle_tick_pump.resume_one_tick()
	_check(NAME, env.controller.get_particle_tick() == 1, "新 pulse 第一 Tick 必须精确 ==1（证明旧链未额外推进），实际 %d。" % [env.controller.get_particle_tick()])
	# 继续推进至 drain（gen3 光粒 (14,3) RIGHT：tick4→(15,3)，tick8 越界 terminate → drain → MOVE_WINDOW）。
	while env.particle_tick_pump.resume_one_tick():
		pass
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "新 pulse 应自动 drain 进 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_runtime_generation() == 3, "generation 应仍为 3。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "新 pulse drain 后 active 期望 0。")


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
	var group_count: int = 13
	var passed_checks: int = _checks - _failures.size()
	print("==== Particle Runtime 异步生命周期测试摘要（D7-4 B3b-2.1）====")
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
