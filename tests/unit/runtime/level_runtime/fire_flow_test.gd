extends SceneTree

## LevelRuntimeController 单元测试（拆分片 1/5 · 发射请求与基础运行流程；D7-2 经 READY_TO_FIRE 发射）。
## 覆盖：READY/MOVE_WINDOW 发射成功、SETUP/COMPLETED/拖拽中/0.5s cooldown 未到拒绝发射（M4-E3 起 PULSE_ACTIVE 状态权限允许 repeated fire，拒绝来自 cooldown）、非法方向先于 begin_pulse 拒绝、generation 递增、RayExecution 单次与视觉→水晶顺序。
## D7-2 起 SETUP 不可直接发射，发射用例先 begin_runtime 进入 READY_TO_FIRE 再 request_fire；test 10 锁定 SETUP→request_fire 完整入口拒绝（无 Ray/光段/完成标签副作用）。
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
	_test_01_ready_fire_success()
	_test_02_move_window_fire_success()
	_test_03_pulse_active_rejects_fire()
	_test_04_completed_rejects_fire()
	_test_05_dragging_rejects_fire()
	_test_06_invalid_direction_rejected_before_begin_pulse()
	_test_07_generation_incremented_after_fire()
	_test_08_ray_execution_called_once()
	_test_09_visual_before_crystal_order()
	_test_10_setup_rejects_fire_entry()


# ===== 测试用例 =====

## 1. READY 发射成功：begin_runtime 进 READY 后 request_fire 返回 true，进入 PULSE_ACTIVE，generation 递增，完成标签按事实显示。
func _test_01_ready_fire_success() -> void:
	const NAME: String = "01_READY发射成功"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "READY request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_runtime_generation() == 1, "generation 期望 1。")
	_check(NAME, env.sink.complete_label_visible == true, "完成标签应已显示（水晶在光路）。")


## 2. MOVE_WINDOW 发射成功：先完成一次未完成脉冲到 MOVE_WINDOW，再次发射返回 true。M4-E1：同一 epoch 内第二次 fire 不递增 generation。
##    M4-E3：同 epoch 第二次 fire 受 0.5s cooldown 硬门——经 fixture 可控时钟 advance 到 0.500 使 cooldown ready。
func _test_02_move_window_fire_success() -> void:
	const NAME: String = "02_MOVE_WINDOW发射成功"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# 同步推进到 MOVE_WINDOW（未完成）。
	env.rsc.finish_pulse(false)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应进入 MOVE_WINDOW。")
	# M4-E3：advance 到 0.500 使首次 fire 的 cooldown ready（0.499 边界由 repeated_fire_cooldown_test 覆盖）。
	env.fire_cooldown_clock.advance_seconds(0.5)
	var gen_before: int = env.controller.get_runtime_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "MOVE_WINDOW request_fire 应返回 true。")
	_check(NAME, env.controller.get_runtime_generation() == gen_before, "M4-E1：同 epoch 内 fire 不再递增 generation（期望 == gen_before）。")


## 3. PULSE_ACTIVE 中 cooldown 未到拒绝 repeated fire（M4-E3 语义更新）：首次 fire 成功进入 PULSE_ACTIVE 后立即再 fire，
##    状态权限已允许（repeated fire 开放），拒绝来自 0.5s cooldown 硬门；generation 不变、active 不变。
func _test_03_pulse_active_rejects_fire() -> void:
	const NAME: String = "03_PULSE_ACTIVEcooldown未到拒绝"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var gen_before: int = env.controller.get_runtime_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "PULSE_ACTIVE cooldown 未到时 request_fire 应返回 false。")
	_check(NAME, env.controller.get_runtime_generation() == gen_before, "generation 不应变化。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "被拒重试不得创建第二个 emission（active 期望 1）。")


## 4. COMPLETED 拒绝发射：进入 COMPLETED 后 request_fire 返回 false。
func _test_04_completed_rejects_fire() -> void:
	const NAME: String = "04_COMPLETED拒绝发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应进入 COMPLETED。")
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "COMPLETED request_fire 应返回 false。")


## 5. 拖拽中拒绝发射：stub.is_dragging=true 时 request_fire 返回 false，不进入 PULSE_ACTIVE。
##    先进 READY（允许发射）以隔离拖拽拒绝路径，避免与 SETUP 不可发射混淆。
func _test_05_dragging_rejects_fire() -> void:
	const NAME: String = "05_拖拽中拒绝发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.rsc.begin_runtime()
	env.drag._stub_dragging = true
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "拖拽中 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "应保持 READY_TO_FIRE。")
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：begin_runtime 已推进 generation 到 1（fire 被拒不再变化）。")


## 6. 非法发射方向在 begin_pulse 前拒绝：direction=ZERO 时 build_fire_request 返回 null，request_fire 返回 false 且未进入 PULSE_ACTIVE。
##    先进 READY 使 can_fire_light 通过，确保到达方向校验而非被 SETUP 不可发射截断。
func _test_06_invalid_direction_rejected_before_begin_pulse() -> void:
	const NAME: String = "06_非法方向先于begin_pulse拒绝"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.ZERO, Vector2i(5, 3))
	env.rsc.begin_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "非法方向 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE, "不得进入 PULSE_ACTIVE（begin_pulse 未被调用）。")
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：begin_runtime 已推进 generation 到 1（fire 被拒不再变化）。")


## 7. M4-E1 generation 新语义：fire 不再递增 generation——仅 begin_runtime（进入新 epoch）与 R 推进。同 epoch 多次 fire 共享同一 generation。
func _test_07_generation_incremented_after_fire() -> void:
	const NAME: String = "07_generation不再每fire递增"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	_check(NAME, env.controller.get_runtime_generation() == 0, "初始 generation 期望 0。")
	env.rsc.begin_runtime()
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：begin_runtime 进入新 epoch 推进 generation 到 1。")
	env.controller.request_fire()
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：首次 fire 不再递增 generation（仍 1）。")
	env.rsc.finish_pulse(false)
	# M4-E3：advance 到 0.500 使 cooldown ready，第二次 fire 才能真实启动。
	env.fire_cooldown_clock.advance_seconds(0.5)
	env.controller.request_fire()
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：同 epoch 二次 fire 仍不递增 generation（仍 1，证明 #1 generation 不再因普通 Fire 自增）。")
	# R 才推进 generation（证明 #2 reset 失效旧 generation）。
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_runtime_generation() == 2, "M4-E1：R 推进 generation 到 2（reset 失效旧 generation）。")


## 8. RayExecutionModule 只调用一次：发射后光路段数等于传播步数（ emitter(1,3) RIGHT 到边界 x=15，共 14 步）。
##    observe_ray_queries=true 注入 spy：成功路径直接观测 RayExecutionModule.execute 确实查询了世界，使 SETUP 拒绝路径的 ==0 断言具备反证意义（spy 不是恒 0）。
func _test_08_ray_execution_called_once() -> void:
	const NAME: String = "08_RayExecutionModule只调用一次"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, true)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	# emitter(1,3) RIGHT：光进入 (2,3)..(15,3)，共 14 步；每步一段光路视觉。
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "光路段数期望 14，实际 %d。" % [env.light_visual_controller.get_segment_count()])
	# 直接观测 Ray 执行（成功路径反证）：spy 计数 >0 才能证明计数器有效，SETUP 拒绝路径的 ==0 才有意义。
	_check(NAME, env.light_world_query_spy != null, "应注入 Ray 查询 spy。")
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.is_in_bounds_calls > 0, "Ray 执行应至少查询一次边界（实际 %d）。" % [env.light_world_query_spy.is_in_bounds_calls])
		_check(NAME, env.light_world_query_spy.total_query_calls() > 0, "Ray 执行总查询次数应 >0（实际 %d）。" % [env.light_world_query_spy.total_query_calls()])


## 9. 每 step 保持视觉→水晶顺序：M4-E2.1 起 _apply_ray_execution_result 迁入 RayEmissionDriver，扫描其源码确认 show_step 早于 try_activate_crystal_at（不再扫 LRC——Ray 执行细节已拆出）。
func _test_09_visual_before_crystal_order() -> void:
	const NAME: String = "09_视觉早于水晶顺序"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/ray_emission_driver.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result（应在 RayEmissionDriver 内）。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var obj_idx: int = body.find("_objective_controller.try_activate_crystal_at")
		_check(NAME, show_idx != -1, "应调用 show_step。")
		_check(NAME, obj_idx != -1, "应调用 try_activate_crystal_at。")
		_check(NAME, show_idx < obj_idx, "视觉创建必须早于水晶激活（show @ %d < objective @ %d）。" % [show_idx, obj_idx])


## 10. SETUP 拒绝正式发射入口：未 begin_runtime（仍 SETUP）时 request_fire 必须被完整拒绝。
##     锁定完整入口 SETUP→LevelRuntimeController.request_fire()→被拒绝，而非仅重复 can_fire_light(SETUP)==false。
##     七项独立观测：返回 false、RunState 仍 SETUP、pulse_generation 不递增、Ray 执行调用次数 ==0（spy 直观测，不凭光段 0 推断）、
##     正式光段数 ==0、ObjectiveController/底层完成事实仍 false（含水晶激活数 0）、完成标签回调未发生。
##     request_fire 在 can_fire_light 为 false 时先于 clear_path/begin_pulse/generation 递增/Ray 执行/完成标签返回 false（见生产 request_fire step 2）。
func _test_10_setup_rejects_fire_entry() -> void:
	const NAME: String = "10_SETUP拒绝正式发射入口"
	# observe_ray_queries=true：注入 spy 以直接观测 RayExecutionModule.execute 是否被调用，不再单凭光段数 0 推断。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3), 1, true)
	# 前置：初始 SETUP，未调用 begin_runtime；generation、光段、Ray 查询、完成事实均为 0/false。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	_check(NAME, env.controller.get_runtime_generation() == 0, "前置 generation 期望 0。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "前置光段数期望 0。")
	_check(NAME, env.light_world_query_spy != null, "前置应已注入 Ray 查询 spy。")
	# 前置完成事实基线：required_count==1 使后续 is_completed==false 具判定意义（排除空 Registry 的平凡 false）。
	if _check(NAME, env.objective_controller.get_required_count() == 1, "前置应有 1 颗水晶登记（使 is_completed==false 具判定意义）。"):
		_check(NAME, env.objective_controller.get_activated_count() == 0, "前置已激活水晶期望 0。")
		_check(NAME, env.objective_controller.is_completed() == false, "前置完成事实期望 false。")
	# 正式发射入口拒绝。
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "SETUP request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "状态应保持 SETUP。")
	_check(NAME, env.controller.get_runtime_generation() == 0, "generation 不应递增。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "正式光段数期望 0（实际 %d）。" % [env.light_visual_controller.get_segment_count()])
	# 直接观测 1：RayExecutionModule.execute 从未被调用（光段 0 不能单独冒充，因 Ray 执行后也可能无步）。
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.total_query_calls() == 0, "Ray 执行查询次数期望 0（实际 %d）。" % [env.light_world_query_spy.total_query_calls()])
	# 直接观测 2：底层 ObjectiveController 完成事实与水晶激活保持未完成。
	_check(NAME, env.objective_controller.is_completed() == false, "Objective 完成事实应保持 false。")
	_check(NAME, env.objective_controller.get_activated_count() == 0, "水晶激活数应保持 0。")
	# 完成标签/完成回调没有发生。
	_check(NAME, env.sink.complete_label_visible == null, "不应产生完成标签副作用（complete_label_visible 应仍为 null）。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 10
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
