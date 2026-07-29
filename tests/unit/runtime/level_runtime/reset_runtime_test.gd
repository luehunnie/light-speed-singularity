extends SceneTree

## LevelRuntimeController 单元测试（拆分片 3/5 · R 重置顺序及运行状态恢复）。
## 覆盖：R 重置目标、清玩家机关协调库存、清光路、清移动次数、回 SETUP、reset 后可再次发射。
## 只通过公开接口验证 R 完整重置顺序；桩与装配见 fixtures/runtime_controller_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"


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
	_test_15_reset_resets_objective()
	_test_16_reset_clears_placed_and_reconciles_inventory()
	_test_17_reset_clears_light_path()
	_test_18_reset_clears_runtime_moves()
	_test_19_reset_returns_to_setup()
	await _test_24_refire_after_reset()


# ===== 测试用例 =====

## 15. R 重置目标：激活水晶后 R，水晶未激活、完成标签隐藏。
func _test_15_reset_resets_objective() -> void:
	const NAME: String = "15_R重置目标"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	_check(NAME, env.objective_controller.is_completed(), "发射后应先完成。")
	env.controller.reset_runtime()
	_check(NAME, not env.objective_controller.is_completed(), "R 后应未完成。")
	_check(NAME, env.sink.complete_label_visible == false, "R 后应隐藏完成标签。")


## 16. R 清玩家机关并协调库存：放置机关后 R，映射/占用清空，库存恢复满。
func _test_16_reset_clears_placed_and_reconciles_inventory() -> void:
	const NAME: String = "16_R清机关协调库存"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	var placed := env.placement_controller.place_from_inventory(_TOKEN_TYPE, Vector2i(10, 10), 1)
	_check(NAME, placed.is_success(), "前置放置应成功。")
	_check(NAME, env.inventory_controller.get_remaining() == 2, "放置后库存期望 2，实际 %d。" % [env.inventory_controller.get_remaining()])
	env.controller.reset_runtime()
	_check(NAME, env.placement_controller.get_placed_count() == 0, "R 后应无玩家机关。")
	_check(NAME, not env.occupancy.has_mechanism(placed.mechanism_id), "R 后占用应清除。")
	_check(NAME, env.inventory_controller.get_remaining() == 3, "R 后库存应恢复满，实际 %d。" % [env.inventory_controller.get_remaining()])


## 17. R 清光路：发射后 R，光路段数归 0。
func _test_17_reset_clears_light_path() -> void:
	const NAME: String = "17_R清光路"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	_check(NAME, env.light_visual_controller.get_segment_count() > 0, "发射后应有光路。")
	env.controller.reset_runtime()
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "R 后光路应清空。")


## 18. R 清移动次数：扣次后 R，runtime_moves_used 归 0。
func _test_18_reset_clears_runtime_moves() -> void:
	const NAME: String = "18_R清移动次数"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	env.controller.consume_runtime_move()
	_check(NAME, env.controller.get_runtime_moves_used() == 1, "扣次后 used 期望 1。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "R 后 used 期望 0。")
	_check(NAME, env.controller.get_runtime_moves_remaining() == 1, "R 后 remaining 期望 1。")


## 19. R 回到 SETUP：从 PULSE_ACTIVE R 后状态 SETUP。
func _test_19_reset_returns_to_setup() -> void:
	const NAME: String = "19_R回SETUP"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	env.controller.reset_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应回 SETUP。")


## 24. reset 后可再次发射：R 后 SETUP，再次 request_fire 返回 true 并进入 PULSE_ACTIVE。
func _test_24_refire_after_reset() -> void:
	const NAME: String = "24_reset后可再发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	await _fixture.wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	env.controller.reset_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "R 后再次发射应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController 重置顺序测试摘要 ====")
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
