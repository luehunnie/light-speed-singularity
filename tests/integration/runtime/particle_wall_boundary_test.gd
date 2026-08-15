extends SceneTree

## M4-E4 Particle 墙体边界消失定向测试（FixEvidence 自动验证）。
## Human 冻结目标：Particle 接触墙体边界时即时消失，不得移动 / 插值到墙体中心。
## 覆盖链路：executor 确定性前瞻（StepResult.next_step_blocked）→ scheduler BatchEvent 透传 →
##   builder detached 拷贝 → Visual 半程边界 Tween + 接触即删 View；EMITTED 发射期前瞻（builder 参数）同路径；
##   运行体（scheduler state.cell）永不进入墙格；旧 / 其它 emission 不受影响；R（CLEARED）边界段清理；
##   正常满格传播（非 blocked）行为与既有合同完全一致。
## stale finished 用 emit_signal("finished") 直接驱动（与 particle_visual_tween_test 同法）；headless --script 运行。


const _Scheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _Executor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
const _State: GDScript = preload("res://gameplay/particle/particle_runtime_state.gd")
const _Fake: GDScript = preload("res://tests/unit/particle/fixtures/fake_particle_world_query.gd")
const _Event: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _Controller: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
const _ViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _Grid: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _Timing: GDScript = preload("res://gameplay/core/particle_tick_timing.gd")

const _GROUP_COUNT: int = 14

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _parents: Array = []


func _initialize() -> void:
	await process_frame
	_test_01_executor_lookahead_free_false()
	_test_02_executor_lookahead_wall_true()
	_test_03_executor_lookahead_out_of_bounds_true()
	_test_04_executor_terminate_keeps_flag_false()
	_test_05_scheduler_batch_event_carries_flag_and_cell_never_enters_wall()
	_test_06_builder_detaches_flag()
	_test_07_builder_emitted_carries_forward_flag()
	_test_08_visual_blocked_move_boundary_stop_tween()
	_test_09_boundary_tween_finish_removes_view_immediately()
	_test_10_terminate_after_early_removal_noop()
	_test_11_normal_move_unchanged_full_propagation()
	_test_12_emitted_blocked_boundary_and_default_backward_compatible()
	_test_13_other_emission_unaffected_and_cleared_cleanup()
	_test_14_move_replace_resets_boundary_flags()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	_parents.append(parent)
	var controller: _Controller = _Controller.new(parent)
	return { "parent": parent, "controller": controller }


# ===== 合成 detached 事件（与生产 builder 产物同构） =====

func _emitted(rid: int, gen: int, cell: Vector2i, direction: Vector2i, blocked: bool = false) -> Dictionary:
	var payload: Dictionary = {
		"type": _Event.TYPE_EMITTED, "runtime_id": rid, "generation": gen,
		"cell": cell, "direction": direction, "speed_tier": 1,
		"step_started_tick": 0, "next_move_tick": 4,
	}
	if blocked:
		payload["next_step_blocked"] = true
	return payload


func _tick(gen: int, tick: int, events: Array) -> Dictionary:
	return { "type": _Event.TYPE_TICK_BATCH_COMMITTED, "generation": gen, "tick": tick, "events": events }


func _move(rid: int, gen: int, from_cell: Vector2i, entered_cell: Vector2i, direction: Vector2i, next_move_tick: int, blocked: bool = false) -> Dictionary:
	return {
		"runtime_id": rid, "generation": gen, "outcome": _Event.OUTCOME_MOVE,
		"from_cell": from_cell, "entered_cell": entered_cell, "direction": direction,
		"speed_tier": 1, "has_crystal": false, "termination_reason": _Event.TERMINATION_NONE,
		"next_move_tick": next_move_tick, "next_step_blocked": blocked,
	}


func _terminate(rid: int, gen: int, from_cell: Vector2i, blocked_cell: Vector2i) -> Dictionary:
	return {
		"runtime_id": rid, "generation": gen, "outcome": _Event.OUTCOME_TERMINATE,
		"from_cell": from_cell, "entered_cell": blocked_cell, "direction": Vector2i.RIGHT,
		"speed_tier": 1, "has_crystal": false, "termination_reason": _Event.TERMINATION_WALL,
		"next_move_tick": 0, "next_step_blocked": false,
	}


func _cleared(old_gen: int, new_gen: int) -> Dictionary:
	return { "type": _Event.TYPE_CLEARED, "old_generation": old_gen, "new_generation": new_gen, "reason": _Event.REASON_RESET }


# ===== 测试用例 =====

## 1. executor 前瞻：MOVE 进入自由格且再下一格自由 → next_step_blocked=false。
func _test_01_executor_lookahead_free_false() -> void:
	const G: String = "01_前瞻_自由格false"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 5, 5))
	var ex: _Executor = _Executor.new()
	var s: _State = _State.create_emitted(1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "应判 MOVE。")
	_check(G, r.next_step_blocked == false, "再下一格 (2,0) 自由，前瞻期望 false，实际 %s。" % str(r.next_step_blocked))


## 2. executor 前瞻：MOVE 进入自由格但再下一格为墙 → next_step_blocked=true。
func _test_02_executor_lookahead_wall_true() -> void:
	const G: String = "02_前瞻_墙格true"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 5, 5))
	q.add_wall(Vector2i(2, 0))
	var ex: _Executor = _Executor.new()
	var s: _State = _State.create_emitted(1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "本格 (1,0) 自由应判 MOVE。")
	_check(G, r.entered_cell == Vector2i(1, 0), "entered_cell 期望 (1,0)。")
	_check(G, r.next_step_blocked == true, "再下一格 (2,0) 为墙，前瞻期望 true，实际 %s。" % str(r.next_step_blocked))


## 3. executor 前瞻：再下一格越界 → next_step_blocked=true。
func _test_03_executor_lookahead_out_of_bounds_true() -> void:
	const G: String = "03_前瞻_越界true"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 2, 5))
	var ex: _Executor = _Executor.new()
	var s: _State = _State.create_emitted(1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "本格 (1,0) 在界内应判 MOVE。")
	_check(G, r.next_step_blocked == true, "再下一格 (2,0) 越界，前瞻期望 true，实际 %s。" % str(r.next_step_blocked))


## 4. executor TERMINATE 分支 next_step_blocked 恒 false（撞墙 / 越界终止）。
func _test_04_executor_terminate_keeps_flag_false() -> void:
	const G: String = "04_TERMINATE前瞻false"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 5, 5))
	q.add_wall(Vector2i(1, 0))
	var ex: _Executor = _Executor.new()
	var s_wall: _State = _State.create_emitted(1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r_wall = ex.evaluate_step(s_wall, q)
	_check(G, r_wall.outcome == _Executor.Outcome.TERMINATE, "墙格应判 TERMINATE。")
	_check(G, r_wall.next_step_blocked == false, "TERMINATE 前瞻应恒 false，实际 %s。" % str(r_wall.next_step_blocked))
	var q2: _Fake = _Fake.new()
	q2.set_bounds(Rect2i(0, 0, 1, 1))
	var s_oob: _State = _State.create_emitted(1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r_oob = ex.evaluate_step(s_oob, q2)
	_check(G, r_oob.outcome == _Executor.Outcome.TERMINATE, "越界应判 TERMINATE。")
	_check(G, r_oob.next_step_blocked == false, "越界 TERMINATE 前瞻应恒 false。")


## 5. scheduler 链路：BatchEvent 透传前瞻；运行体 cell 永不进入墙格；最终 TERMINATE(WALL)。
func _test_05_scheduler_batch_event_carries_flag_and_cell_never_enters_wall() -> void:
	const G: String = "05_scheduler透传与运行体不进墙"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 8, 8))
	q.add_wall(Vector2i(3, 0))
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	var rid: int = s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, rid >= 0, "emit 应成功。")
	var wall_cell: Vector2i = Vector2i(3, 0)
	var seen_blocked_move: bool = false
	var seen_terminate: bool = false
	for i in range(16):
		var events: Array = s.advance_one_tick(0)
		var snap: Variant = s.get_particle_state_snapshot(rid)
		if snap != null:
			# 运行体 cell 真值永不等于墙格（终止前停在墙前相邻格）。
			_check(G, snap["cell"] != wall_cell, "Tick %d：运行体 cell %s 不得进入墙格 %s。" % [i + 1, snap["cell"], wall_cell])
		for ev in events:
			if ev.outcome == _Executor.Outcome.MOVE:
				if ev.entered_cell == Vector2i(2, 0):
					seen_blocked_move = true
					_check(G, ev.next_step_blocked == true, "进入墙前相邻格 (2,0) 的 MOVE 应携带 next_step_blocked=true。")
					_check(G, ev.next_move_tick == s.get_current_tick() + 4, "blocked MOVE 的 next_move_tick 仍为 authoritative 整步（4 ticks），不得改变 Tick 真值。")
				else:
					_check(G, ev.next_step_blocked == false, "非墙前 MOVE 前瞻应 false（entered=%s）。" % ev.entered_cell)
			elif ev.outcome == _Executor.Outcome.TERMINATE:
				seen_terminate = true
				_check(G, ev.termination_reason == _Executor.TerminationReason.WALL, "最终终止原因期望 WALL。")
				_check(G, ev.entered_cell == wall_cell, "TERMINATE entered_cell 期望墙格（未进入事实格）。")
				_check(G, ev.next_step_blocked == false, "TERMINATE 前瞻应恒 false。")
	_check(G, seen_blocked_move, "应观察到进入墙前相邻格的 blocked MOVE。")
	_check(G, seen_terminate, "应观察到最终 TERMINATE(WALL)。")
	_check(G, s.is_drained(), "终止后 scheduler 应 drained。")


## 6. builder detached 拷贝：build_tick_committed 的 nested 事件携带 next_step_blocked。
func _test_06_builder_detaches_flag() -> void:
	const G: String = "06_builder_detach透传"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 8, 8))
	q.add_wall(Vector2i(3, 0))
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var found_blocked: bool = false
	for i in range(16):
		var events: Array = s.advance_one_tick(0)
		var payload: Dictionary = _Event.build_tick_committed(s.get_current_generation(), s.get_current_tick(), events)
		for detached in payload["events"]:
			if detached["outcome"] == _Event.OUTCOME_MOVE and detached["entered_cell"] == Vector2i(2, 0):
				found_blocked = true
				_check(G, detached.get("next_step_blocked", null) == true, "detached MOVE 应携带 next_step_blocked=true。")
			elif detached["outcome"] == _Event.OUTCOME_TERMINATE:
				_check(G, detached.get("next_step_blocked", null) == false, "detached TERMINATE 前瞻应 false。")
	_check(G, found_blocked, "builder 链路应观察到 blocked MOVE detached 事件。")


## 7. builder EMITTED 参数：build_emitted(snapshot, true) 携带前瞻；默认 false（既有合同不变）。
func _test_07_builder_emitted_carries_forward_flag() -> void:
	const G: String = "07_builder_EMITTED前瞻"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var snap: Dictionary = s.get_particle_state_snapshot(0)
	var blocked_payload: Dictionary = _Event.build_emitted(snap, true)
	_check(G, blocked_payload.get("next_step_blocked", null) == true, "build_emitted(snapshot, true) 应携带 next_step_blocked=true。")
	var default_payload: Dictionary = _Event.build_emitted(snap)
	_check(G, default_payload.get("next_step_blocked", null) == false, "build_emitted 默认前瞻 false（既有调用行为不变）。")


## 8. Visual blocked MOVE：半程边界 Tween——duration=半步、目标=格边界面中点、View 校准在墙前相邻格中心。
func _test_08_visual_blocked_move_boundary_stop_tween() -> void:
	const G: String = "08_Visual半程边界Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(0, 0), Vector2i.RIGHT))
	# 墙前相邻格 (2,0)：MOVE 校准 (2,0)，下一格 (3,0) 为墙（blocked=true）。
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(1, 0), Vector2i(2, 0), Vector2i.RIGHT, 8, true)]))
	_check(G, c.has_view(0), "blocked MOVE 后 View 应存在（接触边界前不消失）。")
	_check(G, c.is_view_boundary_stop(0), "blocked MOVE 应启用边界截断标记。")
	_check(G, c.is_view_remove_on_finish(0), "blocked MOVE 应标记完成即删。")
	var expected_half: float = (8 - 4) * _Timing.TICK_SECONDS * 0.5
	_check(G, is_equal_approx(c.get_view_tween_duration_seconds(0), expected_half), "边界段 duration 期望半步 %f，实际 %f。" % [expected_half, c.get_view_tween_duration_seconds(0)])
	var view: _ViewScript = c.get_view(0)
	if _check(G, view != null, "View 应存在。"):
		var boundary_world: Vector2 = (
			_Grid.cell_to_world(Vector2i(2, 0)) + _Grid.cell_to_world(Vector2i(3, 0))) * 0.5
		_check(G, view.get_tween_target_world().is_equal_approx(boundary_world), "Tween 目标应为格边界面中点 %s，实际 %s。" % [boundary_world, view.get_tween_target_world()])
		_check(G, not view.get_tween_target_world().is_equal_approx(_Grid.cell_to_world(Vector2i(3, 0))), "Tween 目标不得为墙格中心。")
		_check(G, view.position.is_equal_approx(_Grid.cell_to_world(Vector2i(2, 0))), "View 应校准在墙前相邻格中心 (2,0)。")
	_check(G, c.get_view_tween_target_cell(0) == Vector2i(3, 0), "target_cell 诊断应为阻挡格 (3,0)。")


## 9. 边界段 finished（接触边界时刻）→ View 立即删除；持引用 View 位置不在墙格中心。
func _test_09_boundary_tween_finish_removes_view_immediately() -> void:
	const G: String = "09_接触边界即删View"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(0, 0), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(1, 0), Vector2i(2, 0), Vector2i.RIGHT, 8, true)]))
	var view: _ViewScript = c.get_view(0)
	var tween: Tween = c.get_view_tween(0)
	if _check(G, tween != null and view != null, "前置：边界 Tween 与 View 应存在。"):
		tween.emit_signal("finished")
		_check(G, not c.has_view(0), "边界段 finished 后 View 应立即删除（接触边界即时消失）。")
		_check(G, c.get_view_count() == 0, "View 数期望 0。")
		if _check(G, is_instance_valid(view), "本帧 View 仍 valid（queue_free 延至帧末）。"):
			_check(G, not view.position.is_equal_approx(_Grid.cell_to_world(Vector2i(3, 0))), "View 位置不得为墙格中心 (3,0)。")


## 10. 早删后整步 TERMINATE 到达 → 安全 no-op（不复活 / 不报错）。
func _test_10_terminate_after_early_removal_noop() -> void:
	const G: String = "10_整步TERMINATE_noop"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(0, 0), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(1, 0), Vector2i(2, 0), Vector2i.RIGHT, 8, true)]))
	var tween: Tween = c.get_view_tween(0)
	tween.emit_signal("finished")
	# 整步结束 Tick 的 TERMINATE 事件晚于边界删除到达。
	c.handle_event(_tick(1, 8, [_terminate(0, 1, Vector2i(2, 0), Vector2i(3, 0))]))
	_check(G, not c.has_view(0), "TERMINATE 到达不得复活已删 View。")
	_check(G, c.get_view_count() == 0, "View 数仍期望 0。")


## 11. 正常 MOVE（非 blocked）行为与既有合同一致：满格传播、无边界标记。
func _test_11_normal_move_unchanged_full_propagation() -> void:
	const G: String = "11_正常MOVE不变"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(0, 0), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(0, 0), Vector2i(1, 0), Vector2i.RIGHT, 8, false)]))
	_check(G, c.is_view_boundary_stop(0) == false, "非 blocked MOVE 不应启用边界截断。")
	_check(G, c.is_view_remove_on_finish(0) == false, "非 blocked MOVE 不应标记完成即删。")
	var expected_full: float = (8 - 4) * _Timing.TICK_SECONDS
	_check(G, is_equal_approx(c.get_view_tween_duration_seconds(0), expected_full), "正常段 duration 仍为整步 %f，实际 %f。" % [expected_full, c.get_view_tween_duration_seconds(0)])
	var view: _ViewScript = c.get_view(0)
	if _check(G, view != null, "View 应存在。"):
		_check(G, view.get_tween_target_world().is_equal_approx(_Grid.cell_to_world(Vector2i(2, 0))), "正常段目标仍为下一格中心 (2,0)。")
	# 无 next_step_blocked 键的旧式事件（向后兼容）同样走满格传播。
	var env2: Dictionary = _make_controller()
	var c2: _Controller = env2["controller"]
	c2.handle_event(_emitted(0, 1, Vector2i(0, 0), Vector2i.RIGHT))
	var legacy_move: Dictionary = _move(0, 1, Vector2i(0, 0), Vector2i(1, 0), Vector2i.RIGHT, 8, false)
	legacy_move.erase("next_step_blocked")
	c2.handle_event(_tick(1, 4, [legacy_move]))
	_check(G, c2.is_view_boundary_stop(0) == false, "缺键旧式 MOVE 应默认满格传播（向后兼容）。")
	_check(G, is_equal_approx(c2.get_view_tween_duration_seconds(0), (8 - 4) * _Timing.TICK_SECONDS), "缺键旧式 MOVE duration 仍整步。")


## 12. EMITTED 前瞻：发射前方为墙 → 半程边界 + 接触即删；缺键 EMITTED 默认满格。
func _test_12_emitted_blocked_boundary_and_default_backward_compatible() -> void:
	const G: String = "12_EMITTED前瞻与缺键默认"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 0), Vector2i.RIGHT, true))
	_check(G, c.is_view_boundary_stop(0), "blocked EMITTED 应启用边界截断。")
	var expected_half: float = (4 - 0) * _Timing.TICK_SECONDS * 0.5
	_check(G, is_equal_approx(c.get_view_tween_duration_seconds(0), expected_half), "blocked EMITTED duration 期望半步 %f。" % expected_half)
	var view: _ViewScript = c.get_view(0)
	if _check(G, view != null, "View 应存在。"):
		var boundary_world: Vector2 = (
			_Grid.cell_to_world(Vector2i(2, 0)) + _Grid.cell_to_world(Vector2i(3, 0))) * 0.5
		_check(G, view.get_tween_target_world().is_equal_approx(boundary_world), "EMITTED 边界段目标应为格边界面中点。")
	var tween: Tween = c.get_view_tween(0)
	if _check(G, tween != null, "前置：边界 Tween 应存在。"):
		tween.emit_signal("finished")
		_check(G, not c.has_view(0), "blocked EMITTED 接触边界后 View 应立即删除。")
	var env2: Dictionary = _make_controller()
	var c2: _Controller = env2["controller"]
	c2.handle_event(_emitted(1, 1, Vector2i(0, 0), Vector2i.RIGHT))
	_check(G, c2.is_view_boundary_stop(1) == false, "缺键 EMITTED 默认满格传播。")
	_check(G, is_equal_approx(c2.get_view_tween_duration_seconds(1), 4 * _Timing.TICK_SECONDS), "缺键 EMITTED duration 仍整步。")


## 13. 其它 emission 不受影响 + R（CLEARED）边界段清理。
func _test_13_other_emission_unaffected_and_cleared_cleanup() -> void:
	const G: String = "13_其它emission与R清理"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	# rid 0 走向墙（blocked）；rid 1 同 generation 正常传播。
	c.handle_event(_emitted(0, 1, Vector2i(1, 0), Vector2i.RIGHT))
	c.handle_event(_emitted(1, 1, Vector2i(0, 2), Vector2i.DOWN))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(1, 0), Vector2i(2, 0), Vector2i.RIGHT, 8, true)]))
	c.handle_event(_tick(1, 4, [_move(1, 1, Vector2i(0, 2), Vector2i(0, 3), Vector2i.DOWN, 8, false)]))
	var blocked_tween: Tween = c.get_view_tween(0)
	blocked_tween.emit_signal("finished")
	_check(G, not c.has_view(0), "blocked rid 0 接触边界后删除。")
	_check(G, c.has_view(1), "正常 rid 1 View 不受 rid 0 边界删除影响。")
	_check(G, c.get_view_tween(1) != null, "rid 1 Tween 不受影响。")
	_check(G, c.get_view_count() == 1, "View 数期望 1（仅 rid 1）。")
	# 新 blocked 粒 + R 清理：边界段 Tween 被 kill、View 全清。
	c.handle_event(_emitted(2, 1, Vector2i(4, 4), Vector2i.LEFT))
	c.handle_event(_tick(1, 4, [_move(2, 1, Vector2i(4, 4), Vector2i(3, 4), Vector2i.LEFT, 8, true)]))
	var stale_boundary_tween: Tween = c.get_view_tween(2)
	c.handle_event(_cleared(1, 2))
	_check(G, c.get_view_count() == 0, "R/CLEARED 后全部 View 清除。")
	_check(G, stale_boundary_tween.is_valid() == false, "R/CLEARED 应 kill 边界段 Tween。")
	stale_boundary_tween.emit_signal("finished")
	_check(G, c.get_view_count() == 0, "kill 后边界段 finished 不复活 View。")


## 14. MOVE 替换边界段：标记复位（record 跨 Tween 复用不泄漏上一段边界态）。
func _test_14_move_replace_resets_boundary_flags() -> void:
	const G: String = "14_MOVE替换复位边界标记"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(1, 0), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(1, 0), Vector2i(2, 0), Vector2i.RIGHT, 8, true)]))
	var boundary_tween: Tween = c.get_view_tween(0)
	# 合成场景：墙被移除后的正常 MOVE 到来（正常流不可达，验证标记复位健壮性）。
	c.handle_event(_tick(1, 8, [_move(0, 1, Vector2i(2, 0), Vector2i(3, 0), Vector2i.RIGHT, 12, false)]))
	_check(G, boundary_tween.is_valid() == false, "旧边界段应被 kill。")
	_check(G, c.is_view_boundary_stop(0) == false, "MOVE 替换后边界截断标记应复位。")
	_check(G, c.is_view_remove_on_finish(0) == false, "MOVE 替换后完成即删标记应复位。")
	_check(G, is_equal_approx(c.get_view_tween_duration_seconds(0), (12 - 8) * _Timing.TICK_SECONDS), "替换段 duration 仍整步。")
	var view: _ViewScript = c.get_view(0)
	if _check(G, view != null, "View 应存在。"):
		_check(G, view.get_tween_target_world().is_equal_approx(_Grid.cell_to_world(Vector2i(4, 0))), "替换段目标为下一格中心 (4,0)。")


# ===== 断言、报告与清理 =====

func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


func _cleanup() -> void:
	for parent in _parents:
		if is_instance_valid(parent):
			(parent as Node2D).free()
	_parents.clear()


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== M4-E4 Particle 墙体边界消失定向测试摘要 ====")
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
