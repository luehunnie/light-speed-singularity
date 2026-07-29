extends SceneTree

## LevelRuntimeController 单元测试（拆分片 2/5 · Pulse 异步完成、generation 与过期回调）。
## 覆盖：未完成脉冲进 MOVE_WINDOW、完成脉冲进 COMPLETED、COMPLETED 前取消拖拽、旧 generation 回调不结束新脉冲、R 使旧异步回调失效。
## 异步用例注入极短脉冲持续时间 0.0 并 await process_frame 推进；生产默认 1.0 秒不变。
## 桩与装配见 fixtures/runtime_controller_fixture.gd；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 持有装配夹具，避免工厂/env RefCounted 在 Callable 单引用下被提前回收导致 null::method。
var _fixture: _Fixture = null


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。含异步用例，需 await 推进帧。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 get_tree() 可用。
	await process_frame
	_fixture = _Fixture.new(self)
	await _run_all_tests()
	_report()
	# 清理前推进若干帧，让所有挂起的异步脉冲结束协程恢复完成，避免 free controller 后协程再调用 null 实例。
	await _fixture.wait_settled(4)
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组；异步用例 await process_frame 推进。
func _run_all_tests() -> void:
	await _test_10_unfinished_pulse_enters_move_window()
	await _test_11_completed_pulse_enters_completed()
	await _test_12_cancel_drag_before_completed()
	await _test_13_stale_generation_cannot_finish_new_pulse()
	await _test_14_reset_invalidates_stale_callback()


# ===== 测试用例 =====

## 10. 未完成脉冲结束进入 MOVE_WINDOW：无水晶发射后等待异步结束，状态变 MOVE_WINDOW，光路被清理，刷新 UI。
func _test_10_unfinished_pulse_enters_move_window() -> void:
	const NAME: String = "10_未完成进入MOVE_WINDOW"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	var refresh_before: int = env.sink.refresh_calls
	await _fixture.wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "应进入 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "脉冲结束应清光路。")
	_check(NAME, env.sink.refresh_calls > refresh_before, "应刷新运行 UI。")
	_check(NAME, env.sink.complete_label_visible == false, "未完成不应显示完成标签。")


## 11. 完成脉冲结束进入 COMPLETED：水晶在光路，发射后等待异步结束，状态变 COMPLETED，完成标签保持显示。
func _test_11_completed_pulse_enters_completed() -> void:
	const NAME: String = "11_完成进入COMPLETED"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	await _fixture.wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "应进入 COMPLETED，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.sink.complete_label_visible == true, "完成标签应保持显示。")
	_check(NAME, env.objective_controller.is_completed(), "目标应已完成。")


## 12. COMPLETED 前取消拖拽：发射进 PULSE_ACTIVE 后置拖拽中，异步结束进 COMPLETED 时 controller 调用 cancel_current_drag。
func _test_12_cancel_drag_before_completed() -> void:
	const NAME: String = "12_COMPLETED前取消拖拽"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	# PULSE_ACTIVE 中模拟已开始拖拽（PULSE_ACTIVE 允许拖起），异步结束进 COMPLETED 前由控制器取消。
	env.drag._stub_dragging = true
	await _fixture.wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "应进入 COMPLETED。")
	_check(NAME, env.drag.cancel_calls >= 1, "COMPLETED 前应取消拖拽，实际 %d。" % [env.drag.cancel_calls])
	_check(NAME, not env.drag.is_dragging(), "取消后应不再拖拽。")


## 13. 旧 generation 回调不能结束新脉冲：发射 gen=1 → R gen=2 → 再发射 gen=3，旧回调不污染，新回调决定 MOVE_WINDOW。
func _test_13_stale_generation_cannot_finish_new_pulse() -> void:
	const NAME: String = "13_旧generation不结束新脉冲"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()  # gen=1, PULSE_ACTIVE
	env.controller.reset_runtime()  # gen=2, SETUP，旧回调(1)将过期
	env.controller.request_fire()  # gen=3, PULSE_ACTIVE，新回调(3)
	await _fixture.wait_settled()
	# 旧回调(1) 已过期返回；新回调(3) 结束未完成脉冲 -> MOVE_WINDOW。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "应由新回调进入 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_pulse_generation() == 3, "generation 期望 3。")


## 14. R 使旧异步回调失效：发射 gen=1 → R gen=2 → 等待，旧回调不把 SETUP 改成 MOVE_WINDOW/COMPLETED。
func _test_14_reset_invalidates_stale_callback() -> void:
	const NAME: String = "14_R使旧回调失效"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()  # gen=1, PULSE_ACTIVE，水晶已激活
	env.controller.reset_runtime()  # gen=2, SETUP，旧回调(1)将过期
	await _fixture.wait_settled()
	# 旧回调(1) 过期返回：不清新光路、不改新状态、不进 COMPLETED。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "旧回调不应改状态，应保持 SETUP，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, not env.objective_controller.is_completed(), "R 后应未完成，旧回调不应触发完成。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "光路应已被 R 清理，旧回调不应重建。")


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
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController 异步脉冲测试摘要 ====")
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
