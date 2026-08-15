extends SceneTree

## Particle 视觉 generation / stale-event 防护专项测试（D7-4 B4b-1 MF-3）。
## 覆盖 GPT-5.6sol B4a 三 must-fix 中的 MF-2/MF-3：VisualController generation high-watermark 与 stale-event 行为。
## 用合成 detached 事件 Dictionary（带显式 generation，模仿 ParticleVisualEvent.build_* 产出形态）直接驱动控制器，
##   验证：旧 CLEARED 不清新 View、旧 EMITTED 不复活、旧 TICK MOVE/TERMINATE 不动新 View、envelope 正确但 nested 错位被忽略、
##   重复 CLEARED 幂等、future EMITTED 自动推进 watermark 全清旧 View、MOVE detached event 携带 authoritative next_move_tick、
##   duration = next_move_tick - envelope.tick、以及控制器源码不存在 gameplay 调度器/规则/状态 forbidden 令牌。
## 通过 preload 引用，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ParticleVisualController: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _ParticleViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 持有本组创建的父节点引用，cleanup 前统一 free，避免 leaked at exit。
var _parents: Array = []


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	await process_frame
	_test_01_stale_cleared_does_not_clear_new_view()
	_test_02_stale_emitted_does_not_revive_old_view()
	_test_03_stale_tick_move_does_not_move_new_view()
	_test_04_stale_tick_terminate_does_not_delete_new_view()
	_test_05_tick_envelope_ok_nested_gen_wrong_ignored()
	_test_06_duplicate_cleared_idempotent()
	_test_07_future_emitted_advances_watermark_clears_old()
	_test_08_move_detached_event_carries_next_move_tick()
	_test_09_duration_derived_from_next_move_tick_minus_tick()
	_test_10_controller_source_has_no_gameplay_forbidden_tokens()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 构造独立父节点与控制器，返回 { parent, controller }；父节点不加入场景树，cleanup 统一 free。
func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	_parents.append(parent)
	var controller: _ParticleVisualController = _ParticleVisualController.new(parent)
	return { "parent": parent, "controller": controller }


# ===== 合成 detached 事件（显式 generation，模仿 ParticleVisualEvent.build_* 产出形态） =====

func _emitted(runtime_id: int, generation: int, cell: Vector2i, direction: Vector2i) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_EMITTED,
		"runtime_id": runtime_id,
		"generation": generation,
		"cell": cell,
		"direction": direction,
		"speed_tier": 1,
		"step_started_tick": 0,
		"next_move_tick": 4,
	}


func _tick(generation: int, tick: int, events: Array) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_TICK_BATCH_COMMITTED,
		"generation": generation,
		"tick": tick,
		"events": events,
	}


func _move_event(runtime_id: int, generation: int, from_cell: Vector2i, entered_cell: Vector2i, direction: Vector2i, next_move_tick: int = 8) -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"generation": generation,
		"outcome": _ParticleVisualEvent.OUTCOME_MOVE,
		"from_cell": from_cell,
		"entered_cell": entered_cell,
		"direction": direction,
		"speed_tier": 1,
		"has_crystal": false,
		"termination_reason": _ParticleVisualEvent.TERMINATION_NONE,
		"next_move_tick": next_move_tick,
	}


func _terminate_event(runtime_id: int, generation: int, from_cell: Vector2i) -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"generation": generation,
		"outcome": _ParticleVisualEvent.OUTCOME_TERMINATE,
		"from_cell": from_cell,
		"entered_cell": from_cell,
		"direction": Vector2i.RIGHT,
		"speed_tier": 1,
		"has_crystal": false,
		"termination_reason": _ParticleVisualEvent.TERMINATION_WALL,
		"next_move_tick": 0,
	}


func _cleared(old_generation: int, new_generation: int) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_CLEARED,
		"old_generation": old_generation,
		"new_generation": new_generation,
		"reason": _ParticleVisualEvent.REASON_RESET,
	}


# ===== 测试用例 =====

## 1.（spec 四 特别覆盖）CLEARED(1→2) → EMITTED(gen3) → 迟到 CLEARED(1→2)：gen3 View 仍存在（旧 CLEARED 不清新 View）。
func _test_01_stale_cleared_does_not_clear_new_view() -> void:
	const NAME: String = "01_旧CLEARED不清新View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_cleared(1, 2))  # wm: -1 → 2（首事件推进，清空空映射）
	controller.handle_event(_emitted(0, 3, Vector2i(2, 3), Vector2i.RIGHT))  # gen3 > wm2 → 推进 wm3 + 创建 view0@gen3
	controller.handle_event(_cleared(1, 2))  # new2 <= wm3 → stale → 忽略
	_check(NAME, controller.has_view(0), "迟到旧 CLEARED(1→2) 不应清掉 gen3 View。")
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.get_current_visual_generation() == 3, "watermark 期望 3，实际 %d。" % [controller.get_current_visual_generation()])
	_check(NAME, controller.get_view_generation(0) == 3, "view0 登记 generation 期望 3。")


## 2.（spec 七.2）CLEARED 推进 generation 后 → 再送旧 EMITTED → 旧 View 不复活。
func _test_02_stale_emitted_does_not_revive_old_view() -> void:
	const NAME: String = "02_旧EMITTED不复活"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 3, Vector2i(2, 3), Vector2i.RIGHT))  # wm3, view0@gen3
	controller.handle_event(_cleared(3, 4))  # 4 > 3 → 推进 wm4 + 清旧 View
	_check(NAME, not controller.has_view(0), "前置：CLEARED(3→4) 后 view0 应被清。")
	controller.handle_event(_emitted(0, 3, Vector2i(9, 9), Vector2i.RIGHT))  # gen3 < wm4 → stale → 不复活
	_check(NAME, not controller.has_view(0), "旧 gen3 EMITTED 不应复活 view0。")
	_check(NAME, controller.get_view_count() == 0, "View 数期望 0，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.get_current_visual_generation() == 4, "watermark 期望 4。")


## 3.（spec 七.3）新 generation View 已存在 → 送旧 generation TICK MOVE → 新 View 不移动。
func _test_03_stale_tick_move_does_not_move_new_view() -> void:
	const NAME: String = "03_旧TICK_MOVE不动新View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 5, Vector2i(2, 3), Vector2i.RIGHT))  # wm5, view0@gen5 @ (2,3)
	# 旧 generation envelope（gen3 != wm5）→ 整批忽略。
	controller.handle_event(_tick(3, 4, [_move_event(0, 3, Vector2i(2, 3), Vector2i(5, 3), Vector2i.RIGHT)]))
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "旧 TICK MOVE 后 view0 应仍存在。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(2, 3))), "旧 gen TICK MOVE 不应移动新 View，位置期望 cell_to_world((2,3))，实际 %s。" % [view.position])
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1。")


## 4.（spec 七.4）新 generation View 已存在 → 送旧 generation TICK TERMINATE → 新 View 不删除。
func _test_04_stale_tick_terminate_does_not_delete_new_view() -> void:
	const NAME: String = "04_旧TICK_TERMINATE不删新View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 5, Vector2i(2, 3), Vector2i.RIGHT))  # wm5, view0@gen5
	# 旧 generation envelope（gen3 != wm5）→ 整批忽略。
	controller.handle_event(_tick(3, 4, [_terminate_event(0, 3, Vector2i(2, 3))]))
	_check(NAME, controller.has_view(0), "旧 gen TICK TERMINATE 不应删除新 View。")
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1，实际 %d。" % [controller.get_view_count()])


## 5.（spec 七.5）TICK envelope generation 正确，但 nested event generation 错误 → 该 nested event 被忽略（正确 gen 的仍生效）。
func _test_05_tick_envelope_ok_nested_gen_wrong_ignored() -> void:
	const NAME: String = "05_envelope正确nested错位被忽略"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 5, Vector2i(2, 3), Vector2i.RIGHT))  # wm5, view0@gen5 @ (2,3)
	# envelope gen5 == wm5（通过）；正确 gen MOVE 先生效 → (5,3)；错位 gen3 MOVE 后到 → 须被忽略（否则会盖到 (9,9)）。
	controller.handle_event(_tick(5, 4, [
		_move_event(0, 5, Vector2i(2, 3), Vector2i(5, 3), Vector2i.RIGHT),  # 正确 gen → 生效
		_move_event(0, 3, Vector2i(2, 3), Vector2i(9, 9), Vector2i.RIGHT),  # 错位 gen → 忽略
	]))
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "view0 应仍存在。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(5, 3))), "正确 gen MOVE 生效到 (5,3)；错位 gen MOVE 被忽略，位置期望 cell_to_world((5,3))，实际 %s。" % [view.position])


## 6.（spec 七.6）重复 CLEARED 幂等；且重复 clear 不清掉同 generation 新 EMITTED 的 View。
func _test_06_duplicate_cleared_idempotent() -> void:
	const NAME: String = "06_重复CLEARED幂等"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 2, Vector2i(2, 3), Vector2i.RIGHT))  # wm2, view0
	controller.handle_event(_emitted(1, 2, Vector2i(4, 4), Vector2i.DOWN))  # view1
	controller.handle_event(_cleared(2, 3))  # 3 > 2 → 推进 wm3 + 全清
	_check(NAME, controller.get_view_count() == 0, "首次 CLEARED(2→3) 后 View 数期望 0。")
	controller.handle_event(_cleared(2, 3))  # new3 <= wm3 → 重复忽略
	_check(NAME, controller.get_view_count() == 0, "重复 CLEARED(2→3) 后 View 数仍期望 0。")
	controller.handle_event(_cleared(3, 3))  # new3 <= wm3 → 忽略
	_check(NAME, controller.get_view_count() == 0, "CLEARED(3→3) new==wm 仍忽略，View 数 0。")
	# 重复 clear 不清掉同 generation 新 EMITTED 的 View。
	controller.handle_event(_emitted(5, 3, Vector2i(1, 1), Vector2i.RIGHT))  # wm3（已），view5@gen3
	controller.handle_event(_cleared(2, 3))  # new3 <= wm3 → 忽略 → view5 仍在
	_check(NAME, controller.has_view(5), "重复 stale CLEARED 不应清掉同 gen 新 EMITTED 的 view5。")
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1。")
	_check(NAME, controller.get_current_visual_generation() == 3, "watermark 期望 3。")


## 7.（spec 七.7）future generation EMITTED → 自动推进 visual high-watermark → 旧 views 全清。
func _test_07_future_emitted_advances_watermark_clears_old() -> void:
	const NAME: String = "07_future_EMITTED推进watermark全清"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, 2, Vector2i(2, 3), Vector2i.RIGHT))  # wm2, view0
	controller.handle_event(_emitted(1, 2, Vector2i(4, 4), Vector2i.DOWN))  # view1
	_check(NAME, controller.get_view_count() == 2, "前置：两颗光粒后期望 2 View。")
	controller.handle_event(_emitted(2, 7, Vector2i(1, 1), Vector2i.UP))  # gen7 > wm2 → 推进 wm7 + 清旧 + 创建 view2
	_check(NAME, controller.get_view_count() == 1, "future EMITTED 后旧 View 应全清，View 数期望 1，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.has_view(2) and not controller.has_view(0) and not controller.has_view(1), "仅保留 view2。")
	_check(NAME, controller.get_current_visual_generation() == 7, "watermark 期望 7。")
	_check(NAME, controller.get_view_generation(2) == 7, "view2 登记 generation 期望 7。")


## 8.（spec 七.8）MOVE detached event 携带 authoritative next_move_tick（经真实 builder，原 BatchEvent 不外泄）。
func _test_08_move_detached_event_carries_next_move_tick() -> void:
	const NAME: String = "08_MOVE_detached携带next_move_tick"
	var be = _ParticleScheduler.BatchEvent.new()
	be.runtime_id = 0
	be.generation = 1
	be.outcome = 0  # MOVE
	be.from_cell = Vector2i(1, 0)
	be.entered_cell = Vector2i(2, 0)
	be.direction = Vector2i.RIGHT
	be.speed_tier = 1  # STANDARD
	be.has_crystal = false
	be.next_move_tick = 8
	var payload: Dictionary = _ParticleVisualEvent.build_tick_committed(1, 4, [be])
	if _check(NAME, payload["events"].size() == 1, "events 期望 1 条。"):
		var detached = payload["events"][0]  # 故意不标 Dictionary 类型，使 `is BatchEvent` 为运行期判定（与 event_flow 集成测试一致）。
		_check(NAME, detached is Dictionary, "detached MOVE event 必须为 Dictionary。")
		_check(NAME, not (detached is _ParticleScheduler.BatchEvent), "detached MOVE event 不得是 BatchEvent 原对象。")
		_check(NAME, detached.has("next_move_tick"), "MOVE detached event 应含 next_move_tick。")
		_check(NAME, detached["next_move_tick"] == 8, "MOVE detached next_move_tick 期望 8，实际 %d。" % [detached["next_move_tick"]])


## 9.（spec 七.9）duration 事实可由 event.next_move_tick - payload.tick 得出（正交 8-4=4；斜向 12-6=6）。
func _test_09_duration_derived_from_next_move_tick_minus_tick() -> void:
	const NAME: String = "09_duration=next_move_tick-tick"
	# 正交 STANDARD：envelope tick=4，next_move_tick=8 → duration=4。
	var be_ortho = _ParticleScheduler.BatchEvent.new()
	be_ortho.outcome = 0  # MOVE
	be_ortho.entered_cell = Vector2i(2, 0)
	be_ortho.direction = Vector2i.RIGHT
	be_ortho.next_move_tick = 8
	var payload_ortho: Dictionary = _ParticleVisualEvent.build_tick_committed(1, 4, [be_ortho])
	var duration_ortho: int = int(payload_ortho["events"][0]["next_move_tick"]) - int(payload_ortho["tick"])
	_check(NAME, duration_ortho == 4, "正交 duration 期望 8-4=4，实际 %d。" % duration_ortho)
	# 斜向 STANDARD：envelope tick=6，next_move_tick=12 → duration=6。
	var be_diag = _ParticleScheduler.BatchEvent.new()
	be_diag.outcome = 0  # MOVE
	be_diag.entered_cell = Vector2i(2, 2)
	be_diag.direction = Vector2i(1, 1)
	be_diag.next_move_tick = 12
	var payload_diag: Dictionary = _ParticleVisualEvent.build_tick_committed(1, 6, [be_diag])
	var duration_diag: int = int(payload_diag["events"][0]["next_move_tick"]) - int(payload_diag["tick"])
	_check(NAME, duration_diag == 6, "斜向 duration 期望 12-6=6，实际 %d。" % duration_diag)


## 10.（spec 七.10）VisualController 源码/依赖中不存在 gameplay forbidden 令牌。
func _test_10_controller_source_has_no_gameplay_forbidden_tokens() -> void:
	const NAME: String = "10_控制器源码无gameplay令牌"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/particles/particle_visual_controller.gd")
	var forbidden_tokens: Array = [
		"ParticleMotionRules", "ticks_for", "ParticleScheduler", "ParticleRuntimeState",
	]
	for token: String in forbidden_tokens:
		_check(NAME, src.find(token) == -1, "控制器源码不应含 gameplay forbidden 令牌：%s" % token)
	# 控制器只 preload 视觉层与 builder（无 gameplay/particle 调度器/状态/规则依赖）。
	var forbidden_paths: Array = [
		"res://gameplay/particle/particle_scheduler", "res://gameplay/particle/particle_runtime_state",
		"res://gameplay/particle/particle_motion_rules",
	]
	for p: String in forbidden_paths:
		_check(NAME, src.find(p) == -1, "控制器源码不应 preload gameplay 调度器/状态/规则路径：%s" % p)


# ===== 断言、报告与清理 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 释放本组创建的全部父节点（连同其 ParticleView 子节点）。
func _cleanup() -> void:
	for parent in _parents:
		if is_instance_valid(parent):
			(parent as Node2D).free()
	_parents.clear()


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== Particle 视觉 stale-event 防护专项测试摘要（D7-4 B4b-1 MF-3）====")
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
