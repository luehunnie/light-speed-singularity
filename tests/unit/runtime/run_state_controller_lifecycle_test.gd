extends SceneTree

## RunStateController 生命周期 / 权限合同定向测试（D7-2 五态；由 run_state_controller_test.gd 按职责拆分而来）。
## 职责：合法转换链与五态权限矩阵 + state_changed 成功语义（参数 / 次数 / 字段先于信号更新时序）。
## 覆盖：初始 SETUP、SETUP→READY_TO_FIRE、READY→PULSE、PULSE→MOVE、MOVE→PULSE、PULSE→COMPLETED、
##       五态（SETUP/READY/PULSE/MOVE/COMPLETED）权限矩阵、合法自定义初始 MOVE_WINDOW、构造期不发信号。
## 共享一条合法转换链（SETUP→READY→PULSE→MOVE→PULSE→COMPLETED），每组开始前清空信号记录器避免跨组污染；自定义初始用例独立构造。
## 非法转换 / reset / enum 合同见 run_state_controller_guards_test.gd。
## 不读取 Controller 私有字段，不复制其内部状态转换实现；信号记录与名称映射复用 run_state_test_support.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。

const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _Types: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Support: GDScript = preload("res://tests/unit/runtime/fixtures/run_state_test_support.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行的断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_run_all_tests()
	_report()
	## 全部断言通过则退出码 0，任一失败退出码 1。
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组：01/03/05/08/09/10 共享合法转换链，19 独立构造。
func _run_all_tests() -> void:
	## 共享 Controller 与记录器，覆盖 SETUP→READY→PULSE→MOVE→PULSE→COMPLETED 合法链。
	var controller: RefCounted = _RunStateController.new()
	var recorder: _Support._SignalRecorder = _Support.wire(controller)

	_test_01_initial_setup(controller, recorder)
	_test_03_begin_runtime_to_ready(controller, recorder)
	_test_05_ready_to_pulse(controller, recorder)
	_test_08_pulse_to_move(controller, recorder)
	_test_09_move_to_pulse(controller, recorder)
	_test_10_pulse_to_completed(controller, recorder)

	## 自定义初始状态：独立构造，避免与共享链状态相互干扰。
	_test_19_custom_initial_move_window()


## 对单个状态验证六项权限查询的期望布尔（D7-2 五态权限矩阵），把不一致项追加到失败列表。
## fire=can_fire_light, layout=can_edit_layout, config=can_edit_configuration,
## begin_rt=can_begin_runtime, pulse=is_current_pulse_active, move=is_runtime_move_state。
func _check_permissions(
		name: String,
		c: RefCounted,
		fire: bool,
		layout: bool,
		config: bool,
		begin_rt: bool,
		pulse: bool,
		move: bool
) -> void:
	_check(name, c.can_fire_light() == fire, "can_fire_light 期望 %s。" % [fire])
	_check(name, c.can_edit_layout() == layout, "can_edit_layout 期望 %s。" % [layout])
	_check(name, c.can_edit_configuration() == config, "can_edit_configuration 期望 %s。" % [config])
	_check(name, c.can_begin_runtime() == begin_rt, "can_begin_runtime 期望 %s。" % [begin_rt])
	_check(name, c.is_current_pulse_active() == pulse, "is_current_pulse_active 期望 %s。" % [pulse])
	_check(name, c.is_runtime_move_state() == move, "is_runtime_move_state 期望 %s。" % [move])


## 1. 初始状态：确认默认 SETUP 与六项权限矩阵初始值，且构造期不发信号。
##    SETUP 权限：fire=false（D7-2 起禁止直接发射）、layout=true、config=true、begin_runtime=true、pulse=false、runtime_move=false。
func _test_01_initial_setup(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "01_初始SETUP"
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"初始状态期望 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check_permissions(NAME, c, false, true, true, true, false, false)
	## 构造不属于状态变化，不应发出 state_changed。
	_check(NAME, r.count() == 0, "构造期不应发信号，实际 %d。" % [r.count()])


## 3. begin_runtime 成功：SETUP→READY_TO_FIRE，恰好一次信号，参数与回调内时序正确；并校验 READY 六项权限。
##    READY 权限：fire=true、layout=true、config=false、begin_runtime=false、pulse=false、runtime_move=true。
func _test_03_begin_runtime_to_ready(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "03_SETUP进READY"
	r.clear()
	_check(NAME, c.begin_runtime() == true, "begin_runtime 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE,
		"状态期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.SETUP, "信号 previous 期望 SETUP，实际 %s。" % [_Support.state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.READY_TO_FIRE, "信号 new 期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.READY_TO_FIRE,
			"回调内当前状态期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(e.state_during_callback)])
	## READY 六项权限矩阵。
	_check_permissions(NAME, c, true, true, false, false, false, true)


## 5. READY→PULSE：begin_pulse 成功，READY_TO_FIRE→PULSE_ACTIVE，一次正确信号；并校验 PULSE 六项权限。
##    PULSE 权限：fire=false、layout=true、config=false、begin_runtime=false、pulse=true、runtime_move=true。
func _test_05_ready_to_pulse(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "05_READY进PULSE"
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.READY_TO_FIRE, "信号 previous 期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.PULSE_ACTIVE, "信号 new 期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.PULSE_ACTIVE,
			"回调内当前状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.state_during_callback)])
	## PULSE 六项权限矩阵。
	_check_permissions(NAME, c, false, true, false, false, true, true)


## 8. PULSE→MOVE：finish_pulse(false) 成功，PULSE_ACTIVE→MOVE_WINDOW，一次正确信号；并校验 MOVE 六项权限。
##    MOVE 权限：fire=true、layout=true、config=false、begin_runtime=false、pulse=false、runtime_move=true。
func _test_08_pulse_to_move(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "08_PULSE进MOVE"
	r.clear()
	_check(NAME, c.finish_pulse(false) == true, "finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.PULSE_ACTIVE, "信号 previous 期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.MOVE_WINDOW, "信号 new 期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.MOVE_WINDOW,
			"回调内当前状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(e.state_during_callback)])
	## MOVE 六项权限矩阵。
	_check_permissions(NAME, c, true, true, false, false, false, true)


## 9. MOVE→PULSE：begin_pulse 成功，MOVE_WINDOW→PULSE_ACTIVE，一次正确信号（覆盖 MOVE 作为 begin_pulse 合法来源）。
func _test_09_move_to_pulse(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "09_MOVE再进PULSE"
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.MOVE_WINDOW, "信号 previous 期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.PULSE_ACTIVE, "信号 new 期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.PULSE_ACTIVE,
			"回调内当前状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.state_during_callback)])


## 10. PULSE→COMPLETED：finish_pulse(true) 成功，PULSE_ACTIVE→COMPLETED，一次正确信号；并校验 COMPLETED 六项权限（全冻结）。
##     COMPLETED 权限：fire=false、layout=false、config=false、begin_runtime=false、pulse=false、runtime_move=false。
func _test_10_pulse_to_completed(c: RefCounted, r: _Support._SignalRecorder) -> void:
	const NAME: String = "10_PULSE进COMPLETED"
	r.clear()
	_check(NAME, c.finish_pulse(true) == true, "finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED,
		"状态期望 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.PULSE_ACTIVE, "信号 previous 期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.COMPLETED, "信号 new 期望 COMPLETED，实际 %s。" % [_Support.state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.COMPLETED,
			"回调内当前状态期望 COMPLETED，实际 %s。" % [_Support.state_label(e.state_during_callback)])
	## COMPLETED 六项权限矩阵：全部冻结。
	_check_permissions(NAME, c, false, false, false, false, false, false)


## 19. 有效自定义初始状态：以 MOVE_WINDOW 为合法初始状态构造 Controller，
##     确认初始状态为 MOVE_WINDOW、构造期不发信号、可 begin_pulse 推进到 PULSE_ACTIVE。
func _test_19_custom_initial_move_window() -> void:
	const NAME: String = "19_自定义初始MOVE_WINDOW"
	var c: RefCounted = _RunStateController.new(_Types.RunState.MOVE_WINDOW)
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"初始状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	## 构造不属于状态变化，不应发出 state_changed。
	_check(NAME, r.count() == 0, "构造期不应发信号，实际 %d。" % [r.count()])
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()])


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== RunStateController 生命周期/权限合同测试摘要 ====")
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
