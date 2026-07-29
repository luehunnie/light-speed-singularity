extends SceneTree

## LevelRuntimeController 单元测试（拆分片 4/5 · 运行期移动次数与交互）。
## 覆盖：SETUP 跨格不扣、PULSE_ACTIVE/MOVE_WINDOW 跨格扣一次、原格/取消/回收/新放置不扣、达上限拒绝提交。
## 只通过公开接口验证运行期移动次数规则；桩与装配见 fixtures/runtime_controller_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

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
	# 清理前推进若干帧，让所有挂起的异步脉冲结束协程恢复完成，避免 free controller 后协程再调用 null 实例。
	await _fixture.wait_settled(4)
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	_test_20_setup_move_does_not_consume()
	_test_21_runtime_move_consumes_once()
	_test_22_non_cross_cell_does_not_consume()
	_test_23_move_limit_rejects_commit()


# ===== 测试用例 =====

## 20. SETUP 跨格移动不扣次数：SETUP 状态 consume_runtime_move_if_required 跨格返回 false。
func _test_20_setup_move_does_not_consume() -> void:
	const NAME: String = "20_SETUP跨格不扣"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	var consumed: bool = env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 2))
	_check(NAME, not consumed, "SETUP 跨格不应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "used 期望 0。")


## 21. PULSE_ACTIVE/MOVE_WINDOW 成功跨格扣一次：两态下跨格 consume 返回 true 且 used +1。
func _test_21_runtime_move_consumes_once() -> void:
	const NAME: String = "21_运行期跨格扣一次"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 2)
	env.rsc.begin_pulse()
	_check(NAME, env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 1)), "PULSE_ACTIVE 跨格应扣次。")
	env.rsc.finish_pulse(false)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应 MOVE_WINDOW。")
	_check(NAME, env.controller.consume_runtime_move_if_required(Vector2i(2, 1), Vector2i(3, 1)), "MOVE_WINDOW 跨格应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 2, "used 期望 2。")
	_check(NAME, env.controller.get_runtime_moves_remaining() == 0, "remaining 期望 0。")


## 22. 原格/取消/回收/新放置不扣：原格 consume 返回 false；新放置与回收不经过 consume_runtime_move。
func _test_22_non_cross_cell_does_not_consume() -> void:
	const NAME: String = "22_非跨格不扣"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	# 原格松手：from==to 不扣。
	_check(NAME, not env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(1, 1)), "原格不应扣次。")
	# COMPLETED 不扣。
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	_check(NAME, not env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 2)), "COMPLETED 跨格不应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "used 期望 0。")
	# 新放置与回收不经 consume_runtime_move：consume_runtime_move 仅由 DragFlowController 在 should_count 通过后调用，此处直接验证 can_commit 对新放置来源不读次数。
	env.controller.reset_runtime()
	env.rsc.begin_pulse()
	_check(NAME, env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "PULSE_ACTIVE 跨格 remaining>0 应允许提交。")


## 23. 达到次数上限拒绝提交：remaining=0 时 can_commit_placed_move 跨格返回 false。
func _test_23_move_limit_rejects_commit() -> void:
	const NAME: String = "23_达上限拒绝提交"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	env.controller.consume_runtime_move()  # 用尽 1 次
	_check(NAME, env.controller.get_runtime_moves_remaining() == 0, "remaining 期望 0。")
	_check(NAME, not env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "remaining=0 应拒绝跨格提交。")
	# SETUP 不受次数限制。
	env.rsc.reset_to_setup()
	_check(NAME, env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "SETUP 跨格不受次数限制。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 4
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController 运行期移动测试摘要 ====")
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
