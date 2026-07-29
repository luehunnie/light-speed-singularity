extends SceneTree

## LevelRuntimeController 单元测试（拆分片 1/5 · 发射请求与基础运行流程）。
## 覆盖：SETUP/MOVE_WINDOW 发射成功、PULSE_ACTIVE/COMPLETED/拖拽中拒绝发射、非法方向先于 begin_pulse 拒绝、generation 递增、RayExecution 单次与视觉→水晶顺序。
## 只通过公开接口验证发射请求编排；桩与装配见 fixtures/runtime_controller_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。
## 失败路径用例会产生预期 push_error/print_debug 输出，不计入失败。

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
	_test_01_setup_fire_success()
	_test_02_move_window_fire_success()
	_test_03_pulse_active_rejects_fire()
	_test_04_completed_rejects_fire()
	_test_05_dragging_rejects_fire()
	_test_06_invalid_direction_rejected_before_begin_pulse()
	_test_07_generation_incremented_after_fire()
	_test_08_ray_execution_called_once()
	_test_09_visual_before_crystal_order()


# ===== 测试用例 =====

## 1. SETUP 发射成功：返回 true，进入 PULSE_ACTIVE，generation 递增，完成标签按事实显示。
func _test_01_setup_fire_success() -> void:
	const NAME: String = "01_SETUP发射成功"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "SETUP request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_pulse_generation() == 1, "generation 期望 1。")
	_check(NAME, env.sink.complete_label_visible == true, "完成标签应已显示（水晶在光路）。")


## 2. MOVE_WINDOW 发射成功：先完成一次未完成脉冲到 MOVE_WINDOW，再次发射返回 true。
func _test_02_move_window_fire_success() -> void:
	const NAME: String = "02_MOVE_WINDOW发射成功"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	# 同步推进到 MOVE_WINDOW（未完成）。
	env.rsc.finish_pulse(false)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应进入 MOVE_WINDOW。")
	var gen_before: int = env.controller.get_pulse_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "MOVE_WINDOW request_fire 应返回 true。")
	_check(NAME, env.controller.get_pulse_generation() == gen_before + 1, "generation 应递增。")


## 3. PULSE_ACTIVE 拒绝发射：进入 PULSE_ACTIVE 后再次 request_fire 返回 false，generation 不变。
func _test_03_pulse_active_rejects_fire() -> void:
	const NAME: String = "03_PULSE_ACTIVE拒绝发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	var gen_before: int = env.controller.get_pulse_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "PULSE_ACTIVE request_fire 应返回 false。")
	_check(NAME, env.controller.get_pulse_generation() == gen_before, "generation 不应变化。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE。")


## 4. COMPLETED 拒绝发射：进入 COMPLETED 后 request_fire 返回 false。
func _test_04_completed_rejects_fire() -> void:
	const NAME: String = "04_COMPLETED拒绝发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应进入 COMPLETED。")
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "COMPLETED request_fire 应返回 false。")


## 5. 拖拽中拒绝发射：stub.is_dragging=true 时 request_fire 返回 false，不进入 PULSE_ACTIVE。
func _test_05_dragging_rejects_fire() -> void:
	const NAME: String = "05_拖拽中拒绝发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.drag._stub_dragging = true
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "拖拽中 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "应保持 SETUP。")
	_check(NAME, env.controller.get_pulse_generation() == 0, "generation 不应递增。")


## 6. 非法发射方向在 begin_pulse 前拒绝：direction=ZERO 时 build_fire_request 返回 null，request_fire 返回 false 且未进入 PULSE_ACTIVE。
func _test_06_invalid_direction_rejected_before_begin_pulse() -> void:
	const NAME: String = "06_非法方向先于begin_pulse拒绝"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.ZERO, Vector2i(5, 3))
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "非法方向 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "不得进入 PULSE_ACTIVE（begin_pulse 未被调用）。")
	_check(NAME, env.controller.get_pulse_generation() == 0, "generation 不应递增。")


## 7. 发射后 generation 递增：每次成功发射 generation +1。
func _test_07_generation_incremented_after_fire() -> void:
	const NAME: String = "07_发射后generation递增"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	_check(NAME, env.controller.get_pulse_generation() == 0, "初始 generation 期望 0。")
	env.controller.request_fire()
	_check(NAME, env.controller.get_pulse_generation() == 1, "首次发射后 generation 期望 1。")
	env.rsc.finish_pulse(false)
	env.controller.request_fire()
	_check(NAME, env.controller.get_pulse_generation() == 2, "二次发射后 generation 期望 2。")


## 8. RayExecutionModule 只调用一次：发射后光路段数等于传播步数（ emitter(1,3) RIGHT 到边界 x=15，共 14 步）。
func _test_08_ray_execution_called_once() -> void:
	const NAME: String = "08_RayExecutionModule只调用一次"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	# emitter(1,3) RIGHT：光进入 (2,3)..(15,3)，共 14 步；每步一段光路视觉。
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "光路段数期望 14，实际 %d。" % [env.light_visual_controller.get_segment_count()])


## 9. 每 step 保持视觉→水晶顺序：静态验证 _apply_ray_execution_result 中 show_step 早于 try_activate_crystal_at。
func _test_09_visual_before_crystal_order() -> void:
	const NAME: String = "09_视觉早于水晶顺序"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var obj_idx: int = body.find("_objective_controller.try_activate_crystal_at")
		_check(NAME, show_idx != -1, "应调用 show_step。")
		_check(NAME, obj_idx != -1, "应调用 try_activate_crystal_at。")
		_check(NAME, show_idx < obj_idx, "视觉创建必须早于水晶激活（show @ %d < objective @ %d）。" % [show_idx, obj_idx])


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController 发射流程测试摘要 ====")
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
