extends SceneTree

## Particle 视觉事件流集成测试（D7-4 B4a）。
## 通过 runtime_controller_fixture 驱动真实 PARTICLE 脉冲（fixture 把 LRC publish Callable 接到录制 sink），
##   验证 Runtime→Visual detached 事件合同：EMITTED/TICK_BATCH_COMMITTED/CLEARED payload 完整与 detached、
##   TICK events 保持 scheduler runtime_id 冻结顺序、R 发出 clear、以及把已发布事件喂给真实 ParticleVisualController 后
##   View 正确出现/更新/消失/全清（Start Run→fire→EMITTED、Tick commit→更新、Terrain terminate→消失、R→全清、R 后新 pulse 隔离、Ray 不创建 ParticleView）。
## 控制器同步策略：把 sink 录制的完整有序事件日志重新喂给控制器（控制器对完整有序日志幂等——EMITTED 去重、MOVE 末值胜、TERMINATE/CLEARED 删后不重建除非新 EMITTED）。
## 通过 preload 引用，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 失败路径用例会产生预期 push_error 输出，不计入失败。桩与装配见 fixtures/runtime_controller_fixture.gd。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _ParticleVisualController: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
const _ParticleViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 持有装配夹具，避免工厂/env RefCounted 在 Callable 单引用下被提前回收导致 null::method。
var _fixture: _Fixture = null


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	await process_frame
	_fixture = _Fixture.new(self)
	_run_all_tests()
	_report()
	await _fixture.wait_settled(4)
	# 使所有 Particle Tick 泵协程退出（generation 失效 + 推进帧），避免 leaked at exit。
	await _fixture.await_settle_pumps()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	_test_01_emitted_payload_complete()
	_test_02_emitted_payload_detached_from_snapshot()
	_test_03_tick_batch_committed_preserves_runtime_id_order()
	_test_04_tick_events_are_detached_dictionaries()
	_test_05_cleared_payload_old_new_generation()
	_test_06_reset_publishes_clear()
	_test_07_view_position_change_does_not_affect_snapshot()
	_test_08_start_run_fire_emitted_view_appears()
	_test_09_tick_commit_updates_view()
	_test_10_terrain_terminate_removes_view()
	_test_11_reset_clears_views()
	_test_12_new_pulse_not_cleared_by_old_clear()
	_test_13_ray_fire_creates_no_particle_view()


# ===== 同步辅助：把 sink 完整有序事件日志重新喂给控制器（控制器对完整有序日志幂等） =====

## 把 sink 录制的全部事件按顺序喂给 visual controller（用于断言前同步视觉状态）。
func _sync_to_controller(sink, controller: _ParticleVisualController) -> void:
	for ev in sink.events:
		controller.handle_event(ev)


# ===== 测试用例 =====

## 1.（spec 1）EMITTED payload 字段完整：fire 后 sink 含一条 EMITTED，含 type + 7 字段。
func _test_01_emitted_payload_complete() -> void:
	const NAME: String = "01_EMITTED_payload完整"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var emitted_events: Array = env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_EMITTED)
	if _check(NAME, emitted_events.size() == 1, "EMITTED 事件期望 1 条，实际 %d。" % [emitted_events.size()]):
		var ev: Dictionary = emitted_events[0]
		var expected_keys: Array = ["type", "runtime_id", "generation", "cell", "direction", "speed_tier", "step_started_tick", "next_move_tick"]
		for k: String in expected_keys:
			_check(NAME, ev.has(k), "EMITTED payload 应含键 %s。" % k)
		_check(NAME, ev["type"] == _ParticleVisualEvent.TYPE_EMITTED, "type 期望 EMITTED。")
		_check(NAME, ev["runtime_id"] == 0, "runtime_id 期望 0，实际 %d。" % [ev["runtime_id"]])
		_check(NAME, ev["generation"] == 1, "generation 期望 1，实际 %d。" % [ev["generation"]])
		_check(NAME, ev["cell"] == Vector2i(1, 3), "cell 期望 (1,3)，实际 %s。" % [ev["cell"]])
		_check(NAME, ev["direction"] == Vector2i.RIGHT, "direction 期望 RIGHT，实际 %s。" % [ev["direction"]])
		_check(NAME, ev["speed_tier"] == _ParticleMotionRules.SpeedTier.STANDARD, "speed_tier 期望 STANDARD。")
		_check(NAME, ev["step_started_tick"] == 0, "step_started_tick 期望 0。")
		_check(NAME, ev["next_move_tick"] == 4, "next_move_tick 期望 4（正交 STANDARD）。")


## 2.（spec 2/3）EMITTED payload detached：payload 是 Dictionary（非内部 state 对象）；篡改 payload 全字段后 scheduler snapshot 不变。
func _test_02_emitted_payload_detached_from_snapshot() -> void:
	const NAME: String = "02_EMITTED_payload_detached"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var emitted_events: Array = env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_EMITTED)
	if not _check(NAME, emitted_events.size() == 1, "前置：EMITTED 期望 1 条。"):
		return
	var ev: Dictionary = emitted_events[0]
	_check(NAME, ev is Dictionary, "EMITTED payload 必须为 Dictionary（非内部 state 对象）。")
	# 篡改 payload 全字段。
	ev["runtime_id"] = 999
	ev["generation"] = 999
	ev["cell"] = Vector2i(-5, -5)
	ev["direction"] = Vector2i.LEFT
	ev["speed_tier"] = _ParticleMotionRules.SpeedTier.FAST
	ev["step_started_tick"] = 999
	ev["next_move_tick"] = 999
	# scheduler snapshot 必须仍反映真实原值（payload 与内部 state 脱离）。
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "真实光粒应仍存在（payload 篡改不应回收光粒）。"):
		_check(NAME, snapshot["runtime_id"] == 0, "snapshot runtime_id 仍期望 0。")
		_check(NAME, snapshot["cell"] == Vector2i(1, 3), "snapshot cell 仍期望 (1,3)，实际 %s。" % [snapshot["cell"]])
		_check(NAME, snapshot["direction"] == Vector2i.RIGHT, "snapshot direction 仍期望 RIGHT。")
		_check(NAME, snapshot["speed_tier"] == _ParticleMotionRules.SpeedTier.STANDARD, "snapshot speed_tier 仍期望 STANDARD。")


## 3.（spec 4）TICK_BATCH_COMMITTED 顺序保持 scheduler runtime_id 冻结顺序（builder 层：输入 BatchEvent 顺序 → 输出 events 顺序）。
##    注：当前 Runtime 单脉冲只发一颗光粒，故每 Tick 至多 1 事件；多事件顺序合同在 builder 层用合成 BatchEvent 数组验证。
func _test_03_tick_batch_committed_preserves_runtime_id_order() -> void:
	const NAME: String = "03_TICK顺序保持runtime_id"
	# 合成两个 BatchEvent（rid 0 / rid 5），按该顺序喂 builder，输出 events 须保持同序。
	var ev_a = _ParticleScheduler.BatchEvent.new()
	ev_a.runtime_id = 0
	ev_a.outcome = 0  # MOVE
	ev_a.entered_cell = Vector2i(2, 3)
	var ev_b = _ParticleScheduler.BatchEvent.new()
	ev_b.runtime_id = 5
	ev_b.outcome = 0
	ev_b.entered_cell = Vector2i(4, 4)
	# 顺序 [ev_a, ev_b] → 输出 [0, 5]。
	var payload_ab: Dictionary = _ParticleVisualEvent.build_tick_committed(1, 4, [ev_a, ev_b])
	_check(NAME, payload_ab["events"].size() == 2, "[a,b] events 期望 2。")
	if payload_ab["events"].size() == 2:
		_check(NAME, payload_ab["events"][0]["runtime_id"] == 0, "[a,b] 首事件 runtime_id 期望 0。")
		_check(NAME, payload_ab["events"][1]["runtime_id"] == 5, "[a,b] 次事件 runtime_id 期望 5。")
	# 反序 [ev_b, ev_a] → 输出保持输入反序 [5, 0]（证明 builder 不重排，顺序由 scheduler 冻结）。
	var payload_ba: Dictionary = _ParticleVisualEvent.build_tick_committed(1, 4, [ev_b, ev_a])
	if payload_ba["events"].size() == 2:
		_check(NAME, payload_ba["events"][0]["runtime_id"] == 5, "[b,a] 首事件 runtime_id 期望 5（保持输入顺序）。")
		_check(NAME, payload_ba["events"][1]["runtime_id"] == 0, "[b,a] 次事件 runtime_id 期望 0。")


## 4.（spec 5）TICK events 全部为 detached 值（Dictionary，非 BatchEvent 原对象）。
func _test_04_tick_events_are_detached_dictionaries() -> void:
	const NAME: String = "04_TICK_events为detached值"
	# 用真实 fire + 推进到 MOVE 取一条 TICK_BATCH_COMMITTED。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.particle_tick_pump.resume_one_tick()  # tick1 (empty)
	env.particle_tick_pump.resume_one_tick()  # tick2 (empty)
	env.particle_tick_pump.resume_one_tick()  # tick3 (empty)
	env.particle_tick_pump.resume_one_tick()  # tick4 (MOVE)
	var tick_events: Array = env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_TICK_BATCH_COMMITTED)
	# 至少存在一条非空 TICK（tick4 MOVE）。
	var non_empty: Array = []
	for tev in tick_events:
		if tev["events"].size() > 0:
			non_empty.append(tev)
	if _check(NAME, not non_empty.is_empty(), "应存在至少一条非空 TICK_BATCH_COMMITTED（tick4 MOVE）。"):
		var tick_payload: Dictionary = non_empty[0]
		_check(NAME, tick_payload.has("generation") and tick_payload.has("tick"), "TICK payload 应含 generation/tick。")
		_check(NAME, tick_payload["tick"] == 4, "非空 TICK 的 tick 期望 4，实际 %d。" % [tick_payload["tick"]])
		for detached_event in tick_payload["events"]:
			_check(NAME, detached_event is Dictionary, "TICK 每 event 必须为 Dictionary（非 BatchEvent 原对象）。")
			_check(NAME, not (detached_event is _ParticleScheduler.BatchEvent), "TICK event 不得是 BatchEvent 原对象。")
			for k: String in ["runtime_id", "generation", "outcome", "from_cell", "entered_cell", "direction", "speed_tier", "has_crystal", "termination_reason", "next_move_tick"]:
				_check(NAME, detached_event.has(k), "TICK event 应含键 %s。" % k)


## 5.（spec 6）CLEARED payload old/new generation 正确：reset 后 CLEARED 的 old=reset 前 gen、new=reset 后 gen。
func _test_05_cleared_payload_old_new_generation() -> void:
	const NAME: String = "05_CLEARED_old_new_generation"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # gen → 1
	var gen_before: int = env.controller.get_runtime_generation()
	_check(NAME, gen_before == 1, "前置：fire 后 generation 期望 1。")
	env.controller.reset_runtime()  # gen → 2
	var cleared_events: Array = env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_CLEARED)
	if _check(NAME, cleared_events.size() >= 1, "reset 后应至少发出一条 CLEARED。"):
		var ev: Dictionary = cleared_events[cleared_events.size() - 1]
		_check(NAME, ev["old_generation"] == 1, "CLEARED old_generation 期望 1，实际 %d。" % [ev["old_generation"]])
		_check(NAME, ev["new_generation"] == 2, "CLEARED new_generation 期望 2，实际 %d。" % [ev["new_generation"]])
		_check(NAME, ev["reason"] == _ParticleVisualEvent.REASON_RESET, "CLEARED reason 期望 RESET。")


## 6.（spec 7）R 后发出 clear：reset 后 sink 含 CLEARED 事件（视觉据此清全部 View）。
func _test_06_reset_publishes_clear() -> void:
	const NAME: String = "06_R后发出clear"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_CLEARED).is_empty(), "reset 前不应有 CLEARED。")
	env.controller.reset_runtime()
	_check(NAME, env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_CLEARED).size() == 1, "reset 后 CLEARED 期望 1 条，实际 %d。" % [env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_CLEARED).size()])


## 7.（spec 21）View 位置变化不反向改变 gameplay snapshot：sync 出 View 后手动改 View.position，snapshot cell 不变。
func _test_07_view_position_change_does_not_affect_snapshot() -> void:
	const NAME: String = "07_View位置变化不改snapshot"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	var view: _ParticleViewScript = controller.get_view(0)
	if not _check(NAME, view != null, "sync 后应存在 rid 0 View。"):
		return
	# 手动篡改 View.position（视觉副本）。
	view.position = Vector2(9999, 9999)
	view.rotation = 12.34
	# gameplay snapshot 须仍反映真实 cell/direction（视觉改动零影响 gameplay）。
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(NAME, snapshot != null, "snapshot 应仍存在。"):
		_check(NAME, snapshot["cell"] == Vector2i(1, 3), "snapshot cell 仍期望 (1,3)，实际 %s。" % [snapshot["cell"]])
		_check(NAME, snapshot["direction"] == Vector2i.RIGHT, "snapshot direction 仍期望 RIGHT。")


## 8.（spec 23）Start Run → Particle fire → EMITTED visual 出现：sync 后 controller 有 1 个 View。
func _test_08_start_run_fire_emitted_view_appears() -> void:
	const NAME: String = "08_StartRun_fire_EMITTED视觉出现"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	# Start Run 前不应有 View。
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 0, "Start Run 前 View 数期望 0。")
	env.controller.request_fire()
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 1, "fire 后 View 数期望 1，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.has_view(0), "应存在 rid 0 View。")
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "rid 0 View 不应为 null。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(1, 3))), "View 初始位置期望 cell_to_world((1,3))，实际 %s。" % [view.position])


## 9.（spec 24）Tick commit 后 visual 更新：fire + 推进到 tick4 MOVE → View snap 到 entered_cell。
func _test_09_tick_commit_updates_view() -> void:
	const NAME: String = "09_Tick_commit后visual更新"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	# 推进到 tick4（正交 STANDARD 首次 MOVE 到 (2,3)）。
	for i in 4:
		env.particle_tick_pump.resume_one_tick()
	_sync_to_controller(env.particle_visual_sink, controller)
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "tick4 后 rid 0 View 应仍存在。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(2, 3))), "tick4 MOVE 后 View 位置期望 cell_to_world((2,3))，实际 %s。" % [view.position])


## 10.（spec 25）Terrain/Wall terminate 后 visual 消失：emitter(14,3) RIGHT，推进到越界 terminate → View 消失。
func _test_10_terrain_terminate_removes_view() -> void:
	const NAME: String = "10_Terrain_terminate后visual消失"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	# 推进 8 次：tick4 MOVE 到 (15,3)，tick8 越界 (16,3) → TERMINATE → drain。
	for i in 8:
		env.particle_tick_pump.resume_one_tick()
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 0, "越界 terminate drain 后 View 数期望 0，实际 %d。" % [controller.get_view_count()])
	_check(NAME, not controller.has_view(0), "越界 terminate 后 rid 0 View 应已消失。")


## 11.（spec 26）R 后 visual 全清：fire → sync（有 View）→ reset → sync（View 全清）。
func _test_11_reset_clears_views() -> void:
	const NAME: String = "11_R后visual全清"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 1, "前置：fire 后 View 数期望 1。")
	env.controller.reset_runtime()
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 0, "R 后 View 数期望 0，实际 %d。" % [controller.get_view_count()])


## 12.（spec 27）R 后新 pulse 不被旧 clear/event 删除：fire gen1 → reset（clear gen1）→ re-start → fire gen2 → sync → gen2 View 存在。
func _test_12_new_pulse_not_cleared_by_old_clear() -> void:
	const NAME: String = "12_R后新pulse不被旧clear删除"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # gen1, rid 0
	env.controller.reset_runtime()  # CLEARED(1→2)，gen1 视图被清
	# 重新 Start Run + fire gen2（runtime_id 单调 → rid 1）。
	env.rsc.begin_runtime()
	env.controller.request_fire()  # gen3, rid 1
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	# gen2 新光粒（rid 1）View 应存在；rid 0 旧光粒 View 应被 CLEARED 清除。
	_check(NAME, controller.has_view(1), "R 后新 pulse 的 rid 1 View 应存在（不被旧 CLEARED 删除）。")
	_check(NAME, not controller.has_view(0), "rid 0 旧光粒 View 应已被 CLEARED 清除。")
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1（仅 rid 1），实际 %d。" % [controller.get_view_count()])


## 13.（spec 28）Ray fire 不创建 ParticleView：RAY env fire 后 sink 无任何 Particle 事件，controller 0 View。
func _test_13_ray_fire_creates_no_particle_view() -> void:
	const NAME: String = "13_Ray_fire不创建ParticleView"
	# 默认 light_form=RAY。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(3, 3), 1, true)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# RAY 不发布任何 EMITTED/TICK/CLEARED Particle 事件。
	var sink_events: int = env.particle_visual_sink.event_count()
	_check(NAME, sink_events == 0, "RAY 发射不应发布任何 Particle 视觉事件，期望 0，实际 %d。" % [sink_events])
	var controller: _ParticleVisualController = _ParticleVisualController.new(env.visual_parent)
	_sync_to_controller(env.particle_visual_sink, controller)
	_check(NAME, controller.get_view_count() == 0, "RAY 发射不应创建 ParticleView，期望 0，实际 %d。" % [controller.get_view_count()])
	# 等待 RAY 异步脉冲结束协程恢复（PULSE_VISUAL_DURATION=0.0 在 fixture，几乎即刻）。
	await _fixture.wait_settled(2)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 13
	var passed_checks: int = _checks - _failures.size()
	print("==== Particle 视觉事件流集成测试摘要（D7-4 B4a）====")
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
