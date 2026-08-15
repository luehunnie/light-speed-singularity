extends SceneTree

## ParticleVisualController Tween 生命周期专项测试（D7-4 B4b-2）。
## 覆盖 spec 十四的 Tween 20 项：EMITTED 立即起 Tween、首段 duration=next_move_tick-step_started_tick、
##   MOVE commit cancel 旧 Tween + 校准 entered_cell + 新 duration=next_move_tick-envelope.tick、rotation 更新、
##   TERMINATE cancel + 不 snap 非法格、CLEARED 全清、stale CLEARED/MOVE/TERMINATE 不污染新 Tween/View、
##   generation advance kill 旧 Tween、stale finished（CLEAR/MOVE replace/generation advance）经四重守卫 no-op、
##   FAST 仍单 24×16 主体（无持续 Ray/trail）、duration 不依赖 ParticleMotionRules。
## stale finished 用 emit_signal("finished") 直接驱动（不真实等待秒），经 introspection（serial/target/duration/last_completed_serial/is_valid）验证。
## 通过 preload 引用避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _Controller: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
const _Event: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _ViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _Grid: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _Timing: GDScript = preload("res://gameplay/core/particle_tick_timing.gd")


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _parents: Array = []


func _initialize() -> void:
	await process_frame
	_test_01_emitted_creates_tween()
	_test_02_first_duration_from_authoritative_timing()
	_test_03_first_target_cell_is_cell_plus_direction()
	_test_04_visual_does_not_call_motion_rules()
	_test_05_move_cancels_old_tween()
	_test_06_move_calibrates_committed_cell()
	_test_07_move_new_duration_from_envelope_tick()
	_test_08_move_updates_rotation()
	_test_09_terminate_cancels_tween_and_removes_view()
	_test_10_terminate_does_not_snap_to_illegal_cell()
	_test_11_cleared_kills_all_tweens_and_views()
	_test_12_stale_cleared_does_not_kill_new_tween()
	_test_13_stale_move_does_not_replace_new_tween()
	_test_14_stale_terminate_does_not_delete_new_view()
	_test_15_generation_advance_kills_old_tween()
	_test_16_stale_finished_after_clear_noop()
	_test_17_stale_finished_after_move_replace_noop()
	_test_18_stale_finished_after_generation_advance_noop()
	_test_19_fast_still_single_24x16_no_ray_trail()
	_test_20_view_body_24x16_across_directions()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	_parents.append(parent)
	var controller: _Controller = _Controller.new(parent)
	return { "parent": parent, "controller": controller }


# ===== 合成 detached 事件（显式 generation + authoritative timing） =====

func _emitted(rid: int, gen: int, cell: Vector2i, direction: Vector2i, step_started_tick: int = 0, next_move_tick: int = 4) -> Dictionary:
	return {
		"type": _Event.TYPE_EMITTED, "runtime_id": rid, "generation": gen,
		"cell": cell, "direction": direction, "speed_tier": 1,
		"step_started_tick": step_started_tick, "next_move_tick": next_move_tick,
	}


func _tick(gen: int, tick: int, events: Array) -> Dictionary:
	return { "type": _Event.TYPE_TICK_BATCH_COMMITTED, "generation": gen, "tick": tick, "events": events }


func _move(rid: int, gen: int, from_cell: Vector2i, entered_cell: Vector2i, direction: Vector2i, next_move_tick: int = 8) -> Dictionary:
	return {
		"runtime_id": rid, "generation": gen, "outcome": _Event.OUTCOME_MOVE,
		"from_cell": from_cell, "entered_cell": entered_cell, "direction": direction,
		"speed_tier": 1, "has_crystal": false, "termination_reason": _Event.TERMINATION_NONE,
		"next_move_tick": next_move_tick,
	}


func _terminate(rid: int, gen: int, from_cell: Vector2i, blocked_cell: Vector2i) -> Dictionary:
	return {
		"runtime_id": rid, "generation": gen, "outcome": _Event.OUTCOME_TERMINATE,
		"from_cell": from_cell, "entered_cell": blocked_cell, "direction": Vector2i.RIGHT,
		"speed_tier": 1, "has_crystal": false, "termination_reason": _Event.TERMINATION_WALL,
		"next_move_tick": 0,
	}


func _cleared(old_gen: int, new_gen: int) -> Dictionary:
	return { "type": _Event.TYPE_CLEARED, "old_generation": old_gen, "new_generation": new_gen, "reason": _Event.REASON_RESET }


# ===== 测试用例 =====

## 1. EMITTED 立即创建 Tween：get_view_tween != null、serial==1。
func _test_01_emitted_creates_tween() -> void:
	const NAME: String = "01_EMITTED立即起Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	_check(NAME, c.has_view(0), "EMITTED 后应存在 rid 0 View。")
	_check(NAME, c.get_view_tween(0) != null, "EMITTED 后应立即创建 Tween（get_view_tween 非 null）。")
	_check(NAME, c.get_view_tween_serial(0) == 1, "首段 Tween serial 期望 1，实际 %d。" % [c.get_view_tween_serial(0)])


## 2. 首段 duration = (next_move_tick - step_started_tick) * TICK_SECONDS。
func _test_02_first_duration_from_authoritative_timing() -> void:
	const NAME: String = "02_首段duration来自authoritative_timing"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT, 0, 4))
	var expected: float = 4 * _Timing.TICK_SECONDS
	_check(NAME, is_equal_approx(c.get_view_tween_duration_seconds(0), expected), "首段 duration 期望 (4-0)*0.1=%f，实际 %f。" % [expected, c.get_view_tween_duration_seconds(0)])
	# 斜向更长 duration（next_move_tick=6）。
	var env2: Dictionary = _make_controller()
	var c2: _Controller = env2["controller"]
	c2.handle_event(_emitted(0, 1, Vector2i(2, 2), Vector2i(1, 1), 0, 6))
	var expected_diag: float = 6 * _Timing.TICK_SECONDS
	_check(NAME, is_equal_approx(c2.get_view_tween_duration_seconds(0), expected_diag), "斜向首段 duration 期望 (6-0)*0.1=%f，实际 %f。" % [expected_diag, c2.get_view_tween_duration_seconds(0)])


## 3. 首段视觉目标格 = cell + direction（纯视觉几何）。
func _test_03_first_target_cell_is_cell_plus_direction() -> void:
	const NAME: String = "03_首段目标格=cell+direction"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	_check(NAME, c.get_view_tween_target_cell(0) == Vector2i(2, 3) + Vector2i.RIGHT, "首段目标格期望 (3,3)，实际 %s。" % [str(c.get_view_tween_target_cell(0))])
	var env2: Dictionary = _make_controller()
	var c2: _Controller = env2["controller"]
	c2.handle_event(_emitted(0, 1, Vector2i(5, 5), Vector2i(1, 1)))
	_check(NAME, c2.get_view_tween_target_cell(0) == Vector2i(5, 5) + Vector2i(1, 1), "斜向首段目标格期望 (6,6)，实际 %s。" % [str(c2.get_view_tween_target_cell(0))])


## 4. Visual 不调 ParticleMotionRules / ticks_for（源码 forbidden 令牌扫描）。
func _test_04_visual_does_not_call_motion_rules() -> void:
	const NAME: String = "04_Visual不调MotionRules"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/particles/particle_visual_controller.gd")
	for token: String in ["ParticleMotionRules", "ticks_for", "ParticleScheduler", "ParticleRuntimeState"]:
		_check(NAME, src.find(token) == -1, "控制器源码不应含 gameplay forbidden 令牌：%s" % token)
	# duration 仅来自 authoritative next_move_tick - tick（源码含 next_move_tick，不含 ticks_for / 自维 Tick 表）。
	_check(NAME, src.find("next_move_tick") != -1, "控制器应读 event 的 authoritative next_move_tick。")


## 5. MOVE commit cancel 旧 Tween：旧 Tween is_valid()==false、record.tween 为新实例、serial 递增。
func _test_05_move_cancels_old_tween() -> void:
	const NAME: String = "05_MOVE取消旧Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	var tween_a: Tween = c.get_view_tween(0)
	if not _check(NAME, tween_a != null, "前置：EMITTED 后应有 Tween A。"):
		return
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(2, 3), Vector2i(3, 3), Vector2i.RIGHT, 8)]))
	var tween_b: Tween = c.get_view_tween(0)
	_check(NAME, tween_a.is_valid() == false, "MOVE 后旧 Tween A 应被 kill（is_valid==false）。")
	_check(NAME, tween_b != null and tween_b != tween_a, "MOVE 后 record.tween 应为新 Tween B（≠ A）。")
	_check(NAME, c.get_view_tween_serial(0) == 2, "MOVE 后 serial 期望 2，实际 %d。" % [c.get_view_tween_serial(0)])


## 6. MOVE 校准 committed cell：View.position == cell_to_world(entered_cell)。
func _test_06_move_calibrates_committed_cell() -> void:
	const NAME: String = "06_MOVE校准committed_cell"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(2, 3), Vector2i(5, 7), Vector2i.RIGHT, 8)]))
	var view: _ViewScript = c.get_view(0)
	if _check(NAME, view != null, "MOVE 后 View 应存在。"):
		_check(NAME, view.position.is_equal_approx(_Grid.cell_to_world(Vector2i(5, 7))), "MOVE 后 View 应校准到 cell_to_world((5,7))，实际 %s。" % [view.position])


## 7. MOVE 新 duration = (next_move_tick - envelope.tick) * TICK_SECONDS。
func _test_07_move_new_duration_from_envelope_tick() -> void:
	const NAME: String = "07_MOVE新duration=envelope_tick"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT, 0, 4))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(2, 3), Vector2i(3, 3), Vector2i.RIGHT, 9)]))
	var expected: float = (9 - 4) * _Timing.TICK_SECONDS
	_check(NAME, is_equal_approx(c.get_view_tween_duration_seconds(0), expected), "MOVE 新 duration 期望 (9-4)*0.1=%f，实际 %f。" % [expected, c.get_view_tween_duration_seconds(0)])


## 8. MOVE 更新 rotation：新 direction（DOWN）后 rotation = angle(DOWN)。
func _test_08_move_updates_rotation() -> void:
	const NAME: String = "08_MOVE更新rotation"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(2, 3), Vector2i(3, 3), Vector2i.DOWN, 8)]))
	var view: _ViewScript = c.get_view(0)
	if _check(NAME, view != null, "MOVE 后 View 应存在。"):
		_check(NAME, is_equal_approx(view.rotation, Vector2(Vector2i.DOWN).angle()), "MOVE 改 DOWN 后 rotation 期望 angle(DOWN)，实际 %f。" % [view.rotation])


## 9. TERMINATE cancel Tween + 删 View：tween killed、has_view false。
func _test_09_terminate_cancels_tween_and_removes_view() -> void:
	const NAME: String = "09_TERMINATE取消Tween并删View"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	var tween_a: Tween = c.get_view_tween(0)
	c.handle_event(_tick(1, 4, [_terminate(0, 1, Vector2i(2, 3), Vector2i(3, 3))]))
	_check(NAME, c.has_view(0) == false, "TERMINATE 后 rid 0 View 应删除。")
	_check(NAME, c.get_view_count() == 0, "TERMINATE 后 View 数期望 0。")
	if _check(NAME, tween_a != null, "前置：EMITTED 后应有 Tween A。"):
		_check(NAME, tween_a.is_valid() == false, "TERMINATE 后 Tween A 应被 kill。")


## 10. TERMINATE 不把 View snap 到 entered_cell（非法/阻挡格）：held View ref 位置仍为旧格，非 entered_cell。
func _test_10_terminate_does_not_snap_to_illegal_cell() -> void:
	const NAME: String = "10_TERMINATE不snap非法格"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	var view: _ViewScript = c.get_view(0)
	var old_pos: Vector2 = view.position
	var blocked_cell: Vector2i = Vector2i(3, 3)  # 尝试但未进入的阻挡格
	c.handle_event(_tick(1, 4, [_terminate(0, 1, Vector2i(2, 3), blocked_cell)]))
	# View 已被 queue_free（record 删除），但本帧仍 valid（test 持引用）；位置应保持旧格，未被 snap 到非法格中心。
	if _check(NAME, is_instance_valid(view), "TERMINATE 后本帧 View 仍应 valid（queue_free 延至帧末）。"):
		_check(NAME, view.position.is_equal_approx(old_pos), "TERMINATE 不应移动 View，位置应保持旧格 %s，实际 %s。" % [old_pos, view.position])
		_check(NAME, not view.position.is_equal_approx(_Grid.cell_to_world(blocked_cell)), "TERMINATE 不应把 View snap 到非法/阻挡格中心 (%s)。" % [blocked_cell])


## 11. CLEARED kill 全部 Tween/View：view_count==0、所有 Tween killed。
func _test_11_cleared_kills_all_tweens_and_views() -> void:
	const NAME: String = "11_CLEARED全清Tween和View"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	c.handle_event(_emitted(1, 1, Vector2i(4, 4), Vector2i.DOWN))
	var ta: Tween = c.get_view_tween(0)
	var tb: Tween = c.get_view_tween(1)
	c.handle_event(_cleared(1, 2))
	_check(NAME, c.get_view_count() == 0, "CLEARED 后 View 数期望 0。")
	if _check(NAME, ta != null and tb != null, "前置：两 Tween 应存在。"):
		_check(NAME, ta.is_valid() == false and tb.is_valid() == false, "CLEARED 后两 Tween 均应 kill。")


## 12. stale CLEARED 不 kill 新 Tween：新 gen EMITTED 后，旧 CLEARED 不清新 View/Tween。
func _test_12_stale_cleared_does_not_kill_new_tween() -> void:
	const NAME: String = "12_旧CLEARED不清新Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 3, Vector2i(2, 3), Vector2i.RIGHT))  # wm3
	c.handle_event(_cleared(1, 2))  # new2 <= wm3 stale
	_check(NAME, c.has_view(0), "旧 CLEARED(1→2) 不应清掉 gen3 View。")
	_check(NAME, c.get_view_tween(0) != null, "旧 CLEARED 不应 kill 新 Tween。")
	_check(NAME, c.get_view_tween_serial(0) == 1, "新 Tween serial 仍期望 1（未被清新事件影响）。")


## 13. stale MOVE 不替换新 Tween：旧 gen envelope 整批忽略，新 Tween 不动。
func _test_13_stale_move_does_not_replace_new_tween() -> void:
	const NAME: String = "13_旧MOVE不换新Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 5, Vector2i(2, 3), Vector2i.RIGHT))  # wm5
	var tween_before: Tween = c.get_view_tween(0)
	c.handle_event(_tick(3, 4, [_move(0, 3, Vector2i(2, 3), Vector2i(9, 9), Vector2i.RIGHT, 8)]))  # 旧 gen3 envelope
	_check(NAME, c.get_view_tween(0) == tween_before, "旧 gen MOVE 不应替换新 Tween。")
	_check(NAME, c.get_view_tween_serial(0) == 1, "serial 仍期望 1（未被旧 MOVE 递增）。")


## 14. stale TERMINATE 不删新 View：旧 gen envelope 整批忽略。
func _test_14_stale_terminate_does_not_delete_new_view() -> void:
	const NAME: String = "14_旧TERMINATE不删新View"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 5, Vector2i(2, 3), Vector2i.RIGHT))  # wm5
	c.handle_event(_tick(3, 4, [_terminate(0, 3, Vector2i(2, 3), Vector2i(3, 3))]))  # 旧 gen3
	_check(NAME, c.has_view(0), "旧 gen TERMINATE 不应删新 View。")
	_check(NAME, c.get_view_tween(0) != null, "旧 gen TERMINATE 不应 kill 新 Tween。")


## 15. generation advance kill 旧 Tween：future EMITTED 推进 watermark，旧 Tween killed。
func _test_15_generation_advance_kills_old_tween() -> void:
	const NAME: String = "15_generation_advance取消旧Tween"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 2, Vector2i(2, 3), Vector2i.RIGHT))  # wm2
	var old_tween: Tween = c.get_view_tween(0)
	c.handle_event(_emitted(5, 7, Vector2i(1, 1), Vector2i.UP))  # gen7 > wm2 → 推进 + 清旧
	_check(NAME, not c.has_view(0), "generation advance 后旧 rid 0 View 应清。")
	if _check(NAME, old_tween != null, "前置：旧 Tween 应存在。"):
		_check(NAME, old_tween.is_valid() == false, "generation advance 后旧 Tween 应 kill。")
	_check(NAME, c.has_view(5) and c.get_view_tween(5) != null, "新 gen7 rid 5 应有新 View/Tween。")


## 16. stale finished（CLEAR 后）no-op：CLEAR 后 emit 旧 Tween.finished 不复活 View、不报错。
func _test_16_stale_finished_after_clear_noop() -> void:
	const NAME: String = "16_CLEAR后旧finished_noop"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	var tween_a: Tween = c.get_view_tween(0)
	c.handle_event(_cleared(1, 2))
	if _check(NAME, tween_a != null, "前置：应有 Tween A。"):
		tween_a.emit_signal("finished")  # CLEAR 后 record 已删 → handler no-op
	_check(NAME, not c.has_view(0), "CLEAR 后 emit 旧 finished 不应复活 View。")
	_check(NAME, c.get_view_count() == 0, "View 数仍期望 0。")


## 17. stale finished（MOVE replace 后）经 serial 守卫 no-op；当前 Tween finished 被接受。
func _test_17_stale_finished_after_move_replace_noop() -> void:
	const NAME: String = "17_MOVE_replace后旧finished经serial守卫noop"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT))
	var tween_a: Tween = c.get_view_tween(0)
	# 当前 Tween A 自然完成 → serial 匹配 → ledger 记 1。
	tween_a.emit_signal("finished")
	_check(NAME, c.get_view_last_completed_serial(0) == 1, "当前 Tween A finished 应被接受，last_completed_serial 期望 1，实际 %d。" % [c.get_view_last_completed_serial(0)])
	# MOVE 替换为 B（serial 2）→ A 被 kill。
	c.handle_event(_tick(1, 4, [_move(0, 1, Vector2i(2, 3), Vector2i(3, 3), Vector2i.RIGHT, 8)]))
	var tween_b: Tween = c.get_view_tween(0)
	# stale A.finished（serial=1 ≠ 当前 2）→ no-op，ledger 不被旧 A 改动。
	tween_a.emit_signal("finished")
	_check(NAME, c.get_view_last_completed_serial(0) == 1, "stale A finished 不应改 ledger，仍期望 1，实际 %d。" % [c.get_view_last_completed_serial(0)])
	# 当前 B.finished（serial=2）→ ledger 记 2。
	tween_b.emit_signal("finished")
	_check(NAME, c.get_view_last_completed_serial(0) == 2, "当前 B finished 应被接受，last_completed_serial 期望 2，实际 %d。" % [c.get_view_last_completed_serial(0)])


## 18. stale finished（generation advance 后）no-op：future EMITTED 推进 gen 后 emit 旧 Tween.finished 不污染新 record。
func _test_18_stale_finished_after_generation_advance_noop() -> void:
	const NAME: String = "18_generation_advance后旧finished_noop"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	c.handle_event(_emitted(0, 2, Vector2i(2, 3), Vector2i.RIGHT))  # wm2
	var tween_a: Tween = c.get_view_tween(0)
	c.handle_event(_emitted(5, 7, Vector2i(1, 1), Vector2i.UP))  # gen7 推进，旧 record 删除
	if _check(NAME, tween_a != null, "前置：旧 Tween A 应存在。"):
		tween_a.emit_signal("finished")  # record 已删 + generation 已变 → handler no-op
	_check(NAME, not c.has_view(0), "generation advance 后 emit 旧 finished 不应复活 rid 0。")
	_check(NAME, c.has_view(5), "新 gen7 rid 5 View 不应被旧 finished 影响。")
	_check(NAME, c.get_view_last_completed_serial(5) == 0, "新 rid 5 的 ledger 不应被旧 rid 0 finished 污染（期望 0）。")


## 19. FAST 仍单 24×16 主体（无持续 Ray/trail）：短 duration（authoritative）、单 View、body 24×16。
func _test_19_fast_still_single_24x16_no_ray_trail() -> void:
	const NAME: String = "19_FAST单24x16无Ray_trail"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	# FAST 表现为更短 authoritative duration（next_move_tick=2 而非 4）；speed_tier 字段 visual 不用于 duration。
	c.handle_event(_emitted(0, 1, Vector2i(2, 3), Vector2i.RIGHT, 0, 2))
	_check(NAME, c.get_view_count() == 1, "FAST 仍单 View（期望 1，无持续 Ray/trail）。")
	var expected: float = 2 * _Timing.TICK_SECONDS
	_check(NAME, is_equal_approx(c.get_view_tween_duration_seconds(0), expected), "FAST duration 更短（authoritative 2 ticks=%f）。" % [expected])
	var view: _ViewScript = c.get_view(0)
	if _check(NAME, view != null, "FAST View 应存在。"):
		_check(NAME, view.get_body_size() == Vector2(24, 16), "FAST 主体仍 24×16，实际 %s。" % [view.get_body_size()])
	# FAST 不连成 Ray：visual_parent 子节点全部为 ParticleView（无 LightSegmentView 式光路段）。
	var parent: Node2D = env["parent"]
	var non_particle_children: int = 0
	for child in parent.get_children():
		if not (child is _ViewScript):
			non_particle_children += 1
	_check(NAME, non_particle_children == 0, "FAST 不应创建 Ray/段视觉，visual_parent 非 ParticleView 子节点数期望 0，实际 %d。" % [non_particle_children])


## 20. View body 24×16（八方向不变）。
func _test_20_view_body_24x16_across_directions() -> void:
	const NAME: String = "20_View主体24x16"
	var env: Dictionary = _make_controller()
	var c: _Controller = env["controller"]
	var dirs: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i(1, 1), Vector2i(-1, -1)]
	for i in dirs.size():
		var d: Vector2i = dirs[i]
		var rid: int = i * 7
		c.handle_event(_emitted(rid, 1, Vector2i(i, 0), d))
		var view: _ViewScript = c.get_view(rid)
		if _check(NAME, view != null, "方向 %s View 应存在。" % [str(d)]):
			var body: ColorRect = view.get_node_or_null("Body")
			if _check(NAME, body != null, "方向 %s Body 应存在。" % [str(d)]):
				_check(NAME, is_equal_approx(body.offset_right - body.offset_left, 24.0), "方向 %s Body 长 24。" % [str(d)])
				_check(NAME, is_equal_approx(body.offset_bottom - body.offset_top, 16.0), "方向 %s Body 宽 16。" % [str(d)])
			_check(NAME, view.get_body_size() == Vector2(24, 16), "方向 %s get_body_size 期望 (24,16)。" % [str(d)])


# ===== 断言、报告与清理 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _cleanup() -> void:
	for parent in _parents:
		if is_instance_valid(parent):
			(parent as Node2D).free()
	_parents.clear()


func _report() -> void:
	var group_count: int = 20
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleVisualController Tween 生命周期专项测试摘要（D7-4 B4b-2）====")
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
