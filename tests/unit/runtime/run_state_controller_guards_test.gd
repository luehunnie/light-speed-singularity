extends SceneTree

## RunStateController 非法转换 / reset / enum 合同定向测试（D7-2 五态；由 run_state_controller_test.gd 按职责拆分）。
## 职责：begin_runtime / begin_pulse / finish_pulse 非法来源拒绝、五态 reset 与幂等、enum 数值合同（0/1/2/3/4）。
## 合法转换链与五态权限矩阵见 run_state_controller_lifecycle_test.gd；信号记录与名称映射复用 run_state_test_support.gd。
## 每组独立构造并按五态机前置到目标状态，清空记录器后隔离拒绝/reset 信号；保留原 02~23 编号以追溯合同。
## 非法构造值因 RunState 枚举为强类型参数自然不可传入，只做静态审查，不使用 Variant/强转换规避。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；预期 push_error 仅记数，不计为失败。

const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _Types: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Support: GDScript = preload("res://tests/unit/runtime/fixtures/run_state_test_support.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 预期非法转换拒绝输出数量（对应 push_error）。
var _expected_rejection_count: int = 0

func _initialize() -> void:
	_run_all_tests()
	_report()
	quit(0 if _failures.is_empty() else 1)

## 运行全部测试组：非法 begin_pulse / begin_runtime / finish_pulse 来源、reset 与幂等、enum 数值合同。
func _run_all_tests() -> void:
	# 非法 begin_pulse 来源（SETUP / PULSE_ACTIVE / COMPLETED）。
	_test_02_setup_begin_pulse_rejected()
	_test_07_pulse_repeat_begin_pulse_rejected()
	# 非法 begin_runtime 来源（READY / PULSE_ACTIVE / COMPLETED / MOVE_WINDOW）。
	_test_04_repeat_begin_runtime_rejected()
	_test_06_begin_runtime_from_pulse_rejected()
	_test_11_completed_rejections()
	_test_23_illegal_begin_runtime_in_move_window()
	# 非法 finish_pulse 来源（SETUP / READY / MOVE_WINDOW / COMPLETED）。
	_test_14_illegal_finish_in_setup()
	_test_15_illegal_finish_in_ready()
	_test_21_illegal_finish_in_move_window()
	_test_22_illegal_finish_in_completed()
	# reset 与幂等（COMPLETED / SETUP / READY / PULSE / MOVE）。
	_test_12_reset_completed_to_setup()
	_test_13_setup_idempotent_reset()
	_test_16_reset_from_ready()
	_test_17_reset_from_pulse()
	_test_18_reset_from_move()
	# enum 数值合同（0/1/2/3/4）。
	_test_20_enum_numeric_values()

## 校验最近一次 state_changed 信号：恰好 1 次、previous/new 与回调内时序正确（字段先于信号更新）。
func _check_signal(name: String, r: _Support._SignalRecorder, expected_previous: int, expected_new: int) -> void:
	if _check(name, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Support._Emission = r.emissions[0]
		_check(name, e.previous_state == expected_previous, "信号 previous 期望 %s，实际 %s。" % [_Support.state_label(expected_previous), _Support.state_label(e.previous_state)])
		_check(name, e.new_state == expected_new, "信号 new 期望 %s，实际 %s。" % [_Support.state_label(expected_new), _Support.state_label(e.new_state)])
		_check(name, e.state_during_callback == expected_new, "回调内当前状态期望 %s，实际 %s。" % [_Support.state_label(expected_new), _Support.state_label(e.state_during_callback)])

## 2. SETUP 直接 begin_pulse 被拒：D7-2 起 SETUP→PULSE_ACTIVE 禁止，返回 false、状态不变、不新增信号（预期 push_error）。
func _test_02_setup_begin_pulse_rejected() -> void:
	const NAME: String = "02_SETUP拒绝直接发射"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_expected_rejection_count += 1
	_check(NAME, c.begin_pulse() == false, "SETUP begin_pulse 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态应保持 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 4. 重复 begin_runtime 被拒：READY 下再次调用返回 false、状态不变、不新增信号；前置 SETUP→READY（预期 push_error）。
func _test_04_repeat_begin_runtime_rejected() -> void:
	const NAME: String = "04_重复begin_runtime拒绝"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE, "前置状态期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.begin_runtime() == false, "READY 下 begin_runtime 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE, "状态应保持 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 6. PULSE 下 begin_runtime 被拒：非 SETUP 来源不可进入 READY，返回 false、状态不变、不新增信号；前置 SETUP→READY→PULSE。
func _test_06_begin_runtime_from_pulse_rejected() -> void:
	const NAME: String = "06_PULSE拒绝begin_runtime"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE, "前置状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.begin_runtime() == false, "PULSE 下 begin_runtime 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 7. PULSE 重复 begin_pulse 被拒：返回 false、状态不变、不新增信号（禁止 PULSE_ACTIVE 内重复发射）；前置 SETUP→READY→PULSE。
func _test_07_pulse_repeat_begin_pulse_rejected() -> void:
	const NAME: String = "07_PULSE拒绝重复发射"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE, "前置状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.begin_pulse() == false, "PULSE 下 begin_pulse 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 11. COMPLETED 拒绝 begin_pulse 与 begin_runtime：均返回 false、保持 COMPLETED、不新增信号；前置 SETUP→READY→PULSE→COMPLETED。
func _test_11_completed_rejections() -> void:
	const NAME: String = "11_COMPLETED拒绝发射与进运行"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(true) == true, "前置 finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED, "前置状态期望 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.begin_pulse() == false, "COMPLETED begin_pulse 期望返回 false。")
	_expected_rejection_count += 1
	_check(NAME, c.begin_runtime() == false, "COMPLETED begin_runtime 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED, "状态应保持 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 14. SETUP 非法 finish：finish_pulse(false) 返回 false、状态不变、不新增信号（预期 push_error）。
func _test_14_illegal_finish_in_setup() -> void:
	const NAME: String = "14_SETUP非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态应保持 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 15. READY 非法 finish：READY 不是 PULSE_ACTIVE、无法 finish；返回 false、状态不变、不新增信号；前置 SETUP→READY。
func _test_15_illegal_finish_in_ready() -> void:
	const NAME: String = "15_READY非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE, "前置状态期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "READY 下 finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE, "状态应保持 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 21. MOVE_WINDOW 非法 finish：finish_pulse 仅 PULSE_ACTIVE 合法，MOVE_WINDOW 必须拒绝 false 与 true 两参数；前置 SETUP→READY→PULSE→MOVE。
func _test_21_illegal_finish_in_move_window() -> void:
	const NAME: String = "21_MOVE_WINDOW非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(false) == true, "前置 finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "前置状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "MOVE_WINDOW 下 finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "状态应保持 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(true) == false, "MOVE_WINDOW 下 finish_pulse(true) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "状态应保持 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 22. COMPLETED 非法 finish：finish_pulse 仅 PULSE_ACTIVE 合法，COMPLETED 必须拒绝；前置 SETUP→READY→PULSE→COMPLETED。
func _test_22_illegal_finish_in_completed() -> void:
	const NAME: String = "22_COMPLETED非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(true) == true, "前置 finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED, "前置状态期望 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "COMPLETED 下 finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED, "状态应保持 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 23. MOVE_WINDOW 非法 begin_runtime：begin_runtime 仅 SETUP 合法，运行期移动状态不可回退到 READY；前置 SETUP→READY→PULSE→MOVE。
func _test_23_illegal_begin_runtime_in_move_window() -> void:
	const NAME: String = "23_MOVE_WINDOW拒绝begin_runtime"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(false) == true, "前置 finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "前置状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_expected_rejection_count += 1
	_check(NAME, c.begin_runtime() == false, "MOVE_WINDOW 下 begin_runtime 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "状态应保持 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])

## 12. COMPLETED→SETUP：reset_to_setup 成功，previous=COMPLETED、new=SETUP、回调内已为 SETUP；前置 SETUP→READY→PULSE→COMPLETED。
func _test_12_reset_completed_to_setup() -> void:
	const NAME: String = "12_COMPLETED重置SETUP"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(true) == true, "前置 finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED, "前置状态期望 COMPLETED，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态期望 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check_signal(NAME, r, _Types.RunState.COMPLETED, _Types.RunState.SETUP)

## 13. SETUP 幂等重置：fresh 构造（SETUP）下 reset_to_setup 返回 true，状态仍 SETUP，不新增信号。
func _test_13_setup_idempotent_reset() -> void:
	const NAME: String = "13_SETUP幂等重置"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态应保持 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "幂等不应发信号，实际新增 %d。" % [r.count()])

## 16. READY 重置：SETUP→READY→reset→SETUP，previous=READY、new=SETUP、回调内已为 SETUP。
func _test_16_reset_from_ready() -> void:
	const NAME: String = "16_READY重置"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.READY_TO_FIRE, "前置状态期望 READY_TO_FIRE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态期望 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check_signal(NAME, r, _Types.RunState.READY_TO_FIRE, _Types.RunState.SETUP)

## 17. PULSE 重置：SETUP→READY→PULSE→reset→SETUP，previous=PULSE、new=SETUP、回调内已为 SETUP。
func _test_17_reset_from_pulse() -> void:
	const NAME: String = "17_PULSE重置"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE, "前置状态期望 PULSE_ACTIVE，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态期望 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check_signal(NAME, r, _Types.RunState.PULSE_ACTIVE, _Types.RunState.SETUP)

## 18. MOVE 重置：SETUP→READY→PULSE→MOVE→reset→SETUP，previous=MOVE、new=SETUP、回调内已为 SETUP。
func _test_18_reset_from_move() -> void:
	const NAME: String = "18_MOVE重置"
	var c: RefCounted = _RunStateController.new()
	var r: _Support._SignalRecorder = _Support.wire(c)
	_check(NAME, c.begin_runtime() == true, "前置 begin_runtime 期望返回 true。")
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(false) == true, "前置 finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW, "前置状态期望 MOVE_WINDOW，实际 %s。" % [_Support.state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP, "状态期望 SETUP，实际 %s。" % [_Support.state_label(c.get_current_state())])
	_check_signal(NAME, r, _Types.RunState.MOVE_WINDOW, _Types.RunState.SETUP)

## 20. enum 数值证明：旧 RunState 0~3 不变，READY_TO_FIRE=4（D7-2 核心不变量）。
func _test_20_enum_numeric_values() -> void:
	const NAME: String = "20_enum数值证明"
	_check(NAME, _Types.RunState.SETUP == 0, "SETUP 期望 0，实际 %d。" % [_Types.RunState.SETUP])
	_check(NAME, _Types.RunState.PULSE_ACTIVE == 1, "PULSE_ACTIVE 期望 1，实际 %d。" % [_Types.RunState.PULSE_ACTIVE])
	_check(NAME, _Types.RunState.MOVE_WINDOW == 2, "MOVE_WINDOW 期望 2，实际 %d。" % [_Types.RunState.MOVE_WINDOW])
	_check(NAME, _Types.RunState.COMPLETED == 3, "COMPLETED 期望 3，实际 %d。" % [_Types.RunState.COMPLETED])
	_check(NAME, _Types.RunState.READY_TO_FIRE == 4, "READY_TO_FIRE 期望 4，实际 %d。" % [_Types.RunState.READY_TO_FIRE])

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表；返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok

## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== RunStateController 非法转换/reset/enum 合同测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	print("预期非法转换拒绝输出数量：%d" % _expected_rejection_count)
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
