extends SceneTree

## RunStateController 批次 4A 定向自动测试。
##
## 职责：
## 只通过 RunStateController 的公开接口（构造、查询、begin_pulse / finish_pulse / reset_to_setup、
## state_changed 信号）观察其行为，验证四态事实、最小合法转换、信号次数/参数/字段更新时序与非法调用拒绝。
## 不读取 Controller 私有字段，不复制其内部状态转换实现，不创建场景、不注册 Autoload、不使用 class_name、
## 不依赖 GUT/WAT 等测试框架、不读取场景树中的游戏节点、不写入项目资源目录、不调用核心脚本。
##
## 在当前系统中的位置：
## tests/unit 下独立 extends SceneTree 的 headless 测试脚本，由 Godot --script 命令行直接运行；
## 通过 preload 引用 Controller 与枚举契约，避开 MCP run_project 不重建全局 class_name 缓存的问题。
##
## 主要依赖：
## RunStateController（res://gameplay/interaction/run_state_controller.gd）与
## RuntimeInteractionTypes（RunState 枚举契约，res://gameplay/interaction/runtime_interaction_types.gd）。
##
## 明确不负责：
## 人工回归、第七项启动自检接入、玩法业务副作用验证、场景内节点交互、文档同步。
##
## 关键边界：
## - 全部失败项收集后统一退出；任一失败 quit(1)，全过 quit(0)。
## - 预期 push_error（非法调用拒绝）不计为测试失败，仅在摘要中记录其数量。
## - 信号字段更新时序通过回调内查询 get_current_state() 验证：信号在 _current_state 更新后发出。
## - 测试 1-11 共享一条状态生命周期链（SETUP→PULSE_ACTIVE→MOVE_WINDOW→PULSE_ACTIVE→COMPLETED→SETUP），
##   每组开始前清空信号记录器，避免跨组计数污染。
## - 测试 12 单独构造以 MOVE_WINDOW 为初始状态的 Controller，验证合法自定义初值。
## - 测试 13-16 独立构造 Controller，补齐 GPT-5.6sol 指出的覆盖缺口：
##   13 PULSE_ACTIVE 重置、14 MOVE_WINDOW 重置、15 MOVE_WINDOW 非法 finish（分别覆盖 false/true 两参数）、
##   16 COMPLETED 非法 finish；同时强化 06/07 的回调内 state_during_callback 时序断言。
## - 非法构造值因静态类型不允许自然传入（RunState 枚举为强类型参数），只做静态审查，不使用 Variant/强转换规避。


## 以 preload 引用 Controller 与枚举契约，不依赖全局 class_name 缓存。
const _RunStateController: GDScript = preload(
	"res://gameplay/interaction/run_state_controller.gd"
)
const _Types: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)


## 单次 state_changed 信号记录：previous/new 与回调内查询到的当前状态。
## 用于同时验证信号参数与字段更新时序（信号在状态字段更新后发出，回调内查询应已是新状态）。
class _Emission:
	extends RefCounted
	var previous_state: int
	var new_state: int
	var state_during_callback: int


## 信号记录器：只通过 state_changed 公开信号观察 Controller，不读取其私有字段。
## 在回调内查询 Controller 当前状态以验证“先更新字段、后发信号”的时序约定。
class _SignalRecorder:
	extends RefCounted
	var _controller: RefCounted
	var emissions: Array[_Emission] = []

	func _init(controller: RefCounted) -> void:
		_controller = controller

	## state_changed 信号回调：记录 previous/new，并在回调内查询当前状态以验证字段先于信号更新。
	func on_changed(previous_state: int, new_state: int) -> void:
		var emission: _Emission = _Emission.new()
		emission.previous_state = previous_state
		emission.new_state = new_state
		## 回调内立即查询当前状态；若字段先于信号更新，此处应已等于 new_state。
		emission.state_during_callback = _controller.get_current_state()
		emissions.append(emission)

	## 返回已记录的信号次数。
	func count() -> int:
		return emissions.size()

	## 清空记录，用于每组测试开始前重置计数，避免跨组污染。
	func clear() -> void:
		emissions.clear()


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行的断言总数。
var _checks: int = 0
## 预期非法转换拒绝输出数量（由测试 4/8/11 的非法调用产生，对应 push_error）。
var _expected_rejection_count: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_run_all_tests()
	_report()
	## 全部断言通过则退出码 0，任一失败退出码 1。
	quit(0 if _failures.is_empty() else 1)


## 运行全部 16 组测试：1-11 共享一条状态生命周期链，12-16 独立构造。
func _run_all_tests() -> void:
	## 共享 Controller 与记录器，覆盖 SETUP→PULSE_ACTIVE→MOVE_WINDOW→PULSE_ACTIVE→COMPLETED→SETUP 链。
	var controller: RefCounted = _RunStateController.new()
	var recorder: _SignalRecorder = _SignalRecorder.new(controller)
	controller.state_changed.connect(Callable(recorder, "on_changed"))

	_test_01_initial(controller, recorder)
	_test_02_setup_fire(controller, recorder)
	_test_03_pulse_active_permissions(controller, recorder)
	_test_04_illegal_repeat_fire(controller, recorder)
	_test_05_finish_unfinished(controller, recorder)
	_test_06_move_window_refire(controller, recorder)
	_test_07_finish_completed(controller, recorder)
	_test_08_completed_illegal_fire(controller, recorder)
	_test_09_reset_to_setup(controller, recorder)
	_test_10_setup_idempotent_reset(controller, recorder)
	_test_11_illegal_finish_in_setup(controller, recorder)

	## 测试 12 独立构造以 MOVE_WINDOW 为初始状态的 Controller，验证合法自定义初值与构造期不发信号。
	var controller_move: RefCounted = _RunStateController.new(_Types.RunState.MOVE_WINDOW)
	var recorder_move: _SignalRecorder = _SignalRecorder.new(controller_move)
	controller_move.state_changed.connect(Callable(recorder_move, "on_changed"))
	_test_12_custom_initial_move_window(controller_move, recorder_move)

	## 测试 13-16 各自独立构造 Controller，补齐 GPT-5.6sol 指出的覆盖缺口；
	## 独立链避免与共享链的当前状态相互干扰。
	_test_13_reset_from_pulse_active()
	_test_14_reset_from_move_window()
	_test_15_illegal_finish_in_move_window()
	_test_16_illegal_finish_in_completed()


## 1. 初始状态：确认默认 SETUP 与五项权限查询的初始返回值，且构造期不发信号。
func _test_01_initial(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "01_初始状态"
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"初始状态期望 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, c.can_fire_light() == true, "can_fire_light 期望 true。")
	_check(NAME, c.can_edit_layout() == true, "can_edit_layout 期望 true。")
	_check(NAME, c.can_edit_configuration() == true, "can_edit_configuration 期望 true。")
	_check(NAME, c.is_current_pulse_active() == false, "is_current_pulse_active 期望 false。")
	_check(NAME, c.is_runtime_move_state() == false, "is_runtime_move_state 期望 false。")
	## 构造不属于状态变化，不应发出 state_changed。
	_check(NAME, r.count() == 0, "构造期不应发信号，实际 %d。" % [r.count()])


## 2. SETUP 发射：begin_pulse 成功，SETUP→PULSE_ACTIVE，恰好一次信号，参数与回调内时序正确。
func _test_02_setup_fire(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "02_SETUP发射"
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(c.get_current_state())])
	## 恰好一次信号。
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.SETUP, "信号 previous 期望 SETUP，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.PULSE_ACTIVE, "信号 new 期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.new_state)])
		## 回调内查询到的当前状态应已是 PULSE_ACTIVE，证明字段先于信号更新。
		_check(NAME, e.state_during_callback == _Types.RunState.PULSE_ACTIVE,
			"回调内当前状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.state_during_callback)])


## 3. PULSE_ACTIVE 权限：五项权限查询在 PULSE_ACTIVE 下的期望返回值。
func _test_03_pulse_active_permissions(c: RefCounted, _r: _SignalRecorder) -> void:
	const NAME: String = "03_PULSE_ACTIVE权限"
	_check(NAME, c.can_fire_light() == false, "can_fire_light 期望 false。")
	_check(NAME, c.can_edit_layout() == true, "can_edit_layout 期望 true。")
	_check(NAME, c.can_edit_configuration() == false, "can_edit_configuration 期望 false。")
	_check(NAME, c.is_current_pulse_active() == true, "is_current_pulse_active 期望 true。")
	_check(NAME, c.is_runtime_move_state() == true, "is_runtime_move_state 期望 true。")


## 4. 非法重复发射：在 PULSE_ACTIVE 调用 begin_pulse，返回 false、状态不变、不新增信号。
## 该调用会产生预期 push_error，计入预期拒绝输出，不计为测试失败。
func _test_04_illegal_repeat_fire(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "04_非法重复发射"
	r.clear()
	## 预期拒绝：begin_pulse 在 PULSE_ACTIVE 被拒，Controller 内部 push_error。
	_expected_rejection_count += 1
	var ok: bool = c.begin_pulse()
	_check(NAME, ok == false, "begin_pulse 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态应保持 PULSE_ACTIVE，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])


## 5. 未完成脉冲：finish_pulse(false) 成功，PULSE_ACTIVE→MOVE_WINDOW，一次正确信号。
## 随后确认 MOVE_WINDOW 的五项权限查询。
func _test_05_finish_unfinished(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "05_未完成脉冲"
	r.clear()
	_check(NAME, c.finish_pulse(false) == true, "finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"状态期望 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.PULSE_ACTIVE, "信号 previous 期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.MOVE_WINDOW, "信号 new 期望 MOVE_WINDOW，实际 %s。" % [_state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.MOVE_WINDOW, "回调内当前状态期望 MOVE_WINDOW，实际 %s。" % [_state_label(e.state_during_callback)])
	## MOVE_WINDOW 权限确认。
	_check(NAME, c.can_fire_light() == true, "MOVE_WINDOW can_fire_light 期望 true。")
	_check(NAME, c.can_edit_layout() == true, "MOVE_WINDOW can_edit_layout 期望 true。")
	_check(NAME, c.can_edit_configuration() == false, "MOVE_WINDOW can_edit_configuration 期望 false。")
	_check(NAME, c.is_current_pulse_active() == false, "MOVE_WINDOW is_current_pulse_active 期望 false。")
	_check(NAME, c.is_runtime_move_state() == true, "MOVE_WINDOW is_runtime_move_state 期望 true。")


## 6. MOVE_WINDOW 再发射：begin_pulse 成功，MOVE_WINDOW→PULSE_ACTIVE，一次正确信号。
## 明确验证信号时序：previous 为 MOVE_WINDOW、new 为 PULSE_ACTIVE、回调内 get_current_state() 已是 PULSE_ACTIVE。
func _test_06_move_window_refire(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "06_MOVE_WINDOW再发射"
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.MOVE_WINDOW, "信号 previous 期望 MOVE_WINDOW，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.PULSE_ACTIVE, "信号 new 期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.new_state)])
		## 回调内查询到的当前状态应已是 PULSE_ACTIVE，证明字段先于信号更新。
		_check(NAME, e.state_during_callback == _Types.RunState.PULSE_ACTIVE,
			"回调内当前状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.state_during_callback)])


## 7. 完成脉冲：finish_pulse(true) 成功，PULSE_ACTIVE→COMPLETED，一次正确信号。
## 随后确认 COMPLETED 的五项权限查询（全部冻结）。
func _test_07_finish_completed(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "07_完成脉冲"
	r.clear()
	_check(NAME, c.finish_pulse(true) == true, "finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED,
		"状态期望 COMPLETED，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.PULSE_ACTIVE, "信号 previous 期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.COMPLETED, "信号 new 期望 COMPLETED，实际 %s。" % [_state_label(e.new_state)])
		## 回调内查询到的当前状态应已是 COMPLETED，证明字段先于信号更新。
		_check(NAME, e.state_during_callback == _Types.RunState.COMPLETED,
			"回调内当前状态期望 COMPLETED，实际 %s。" % [_state_label(e.state_during_callback)])
	## COMPLETED 权限确认：全部冻结。
	_check(NAME, c.can_fire_light() == false, "COMPLETED can_fire_light 期望 false。")
	_check(NAME, c.can_edit_layout() == false, "COMPLETED can_edit_layout 期望 false。")
	_check(NAME, c.can_edit_configuration() == false, "COMPLETED can_edit_configuration 期望 false。")
	_check(NAME, c.is_current_pulse_active() == false, "COMPLETED is_current_pulse_active 期望 false。")
	_check(NAME, c.is_runtime_move_state() == false, "COMPLETED is_runtime_move_state 期望 false。")


## 8. COMPLETED 非法发射：begin_pulse 返回 false、状态仍为 COMPLETED、不新增信号。
## 该调用会产生预期 push_error，计入预期拒绝输出，不计为测试失败。
func _test_08_completed_illegal_fire(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "08_COMPLETED非法发射"
	r.clear()
	## 预期拒绝：begin_pulse 在 COMPLETED 被拒，Controller 内部 push_error。
	_expected_rejection_count += 1
	var ok: bool = c.begin_pulse()
	_check(NAME, ok == false, "begin_pulse 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED,
		"状态应保持 COMPLETED，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])


## 9. R 状态重置：reset_to_setup 成功，COMPLETED→SETUP，一次正确信号。
func _test_09_reset_to_setup(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "09_R状态重置"
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"状态期望 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.COMPLETED, "信号 previous 期望 COMPLETED，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.SETUP, "信号 new 期望 SETUP，实际 %s。" % [_state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.SETUP, "回调内当前状态期望 SETUP，实际 %s。" % [_state_label(e.state_during_callback)])


## 10. SETUP 幂等重置：再次 reset_to_setup 返回 true，状态仍为 SETUP，不新增信号。
func _test_10_setup_idempotent_reset(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "10_SETUP幂等重置"
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"状态应保持 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	## 幂等：已是 SETUP 时不发信号。
	_check(NAME, r.count() == 0, "幂等不应发信号，实际新增 %d。" % [r.count()])


## 11. 非法结束脉冲：在 SETUP 调用 finish_pulse(false)，返回 false、状态不变、不新增信号。
## 该调用会产生预期 push_error，计入预期拒绝输出，不计为测试失败。
func _test_11_illegal_finish_in_setup(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "11_非法结束脉冲"
	r.clear()
	## 预期拒绝：finish_pulse 在 SETUP 被拒，Controller 内部 push_error。
	_expected_rejection_count += 1
	var ok: bool = c.finish_pulse(false)
	_check(NAME, ok == false, "finish_pulse 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"状态应保持 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])


## 12. 有效自定义初始状态：以 MOVE_WINDOW 为合法初始状态构造 Controller，
## 确认初始状态为 MOVE_WINDOW、构造期不发信号、可 begin_pulse 推进到 PULSE_ACTIVE。
func _test_12_custom_initial_move_window(c: RefCounted, r: _SignalRecorder) -> void:
	const NAME: String = "12_自定义初始MOVE_WINDOW"
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"初始状态期望 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	## 构造不属于状态变化，不应发出 state_changed。
	_check(NAME, r.count() == 0, "构造期不应发信号，实际 %d。" % [r.count()])
	r.clear()
	_check(NAME, c.begin_pulse() == true, "begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()])


## 13. PULSE_ACTIVE 重置：独立构造 Controller，SETUP→PULSE_ACTIVE→reset_to_setup→SETUP。
## 补齐 GPT-5.6sol 缺口：原测试 09 只覆盖 COMPLETED→SETUP，此处覆盖从 PULSE_ACTIVE 重置。
## 确认返回 true、状态变 SETUP、恰好一次信号、previous 为 PULSE_ACTIVE、new 为 SETUP、回调内已为 SETUP。
func _test_13_reset_from_pulse_active() -> void:
	const NAME: String = "13_PULSE_ACTIVE重置"
	var c: RefCounted = _RunStateController.new()
	var r: _SignalRecorder = _SignalRecorder.new(c)
	c.state_changed.connect(Callable(r, "on_changed"))
	## 推进到 PULSE_ACTIVE，随后清空记录器以隔离 reset 信号。
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.PULSE_ACTIVE,
		"前置状态期望 PULSE_ACTIVE，实际 %s。" % [_state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"状态期望 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.PULSE_ACTIVE, "信号 previous 期望 PULSE_ACTIVE，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.SETUP, "信号 new 期望 SETUP，实际 %s。" % [_state_label(e.new_state)])
		## 回调内查询到的当前状态应已是 SETUP，证明字段先于信号更新。
		_check(NAME, e.state_during_callback == _Types.RunState.SETUP,
			"回调内当前状态期望 SETUP，实际 %s。" % [_state_label(e.state_during_callback)])


## 14. MOVE_WINDOW 重置：独立构造 Controller，SETUP→PULSE_ACTIVE→MOVE_WINDOW→reset_to_setup→SETUP。
## 补齐 GPT-5.6sol 缺口：覆盖从 MOVE_WINDOW 重置的信号时序。
## 确认返回 true、previous 为 MOVE_WINDOW、new 为 SETUP、回调内已为 SETUP。
func _test_14_reset_from_move_window() -> void:
	const NAME: String = "14_MOVE_WINDOW重置"
	var c: RefCounted = _RunStateController.new()
	var r: _SignalRecorder = _SignalRecorder.new(c)
	c.state_changed.connect(Callable(r, "on_changed"))
	## 推进到 MOVE_WINDOW，随后清空记录器以隔离 reset 信号。
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(false) == true, "前置 finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"前置状态期望 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	r.clear()
	_check(NAME, c.reset_to_setup() == true, "reset_to_setup 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.SETUP,
		"状态期望 SETUP，实际 %s。" % [_state_label(c.get_current_state())])
	if _check(NAME, r.count() == 1, "信号次数期望 1，实际 %d。" % [r.count()]):
		var e: _Emission = r.emissions[0]
		_check(NAME, e.previous_state == _Types.RunState.MOVE_WINDOW, "信号 previous 期望 MOVE_WINDOW，实际 %s。" % [_state_label(e.previous_state)])
		_check(NAME, e.new_state == _Types.RunState.SETUP, "信号 new 期望 SETUP，实际 %s。" % [_state_label(e.new_state)])
		_check(NAME, e.state_during_callback == _Types.RunState.SETUP,
			"回调内当前状态期望 SETUP，实际 %s。" % [_state_label(e.state_during_callback)])


## 15. MOVE_WINDOW 非法 finish：在 MOVE_WINDOW 调用 finish_pulse(false) 与 finish_pulse(true)。
## 补齐 GPT-5.6sol 缺口：原测试 11 只覆盖 SETUP 下非法 finish，此处覆盖 MOVE_WINDOW 下两个参数。
## 确认两次都返回 false、状态仍为 MOVE_WINDOW、不新增信号；push_error 属预期拒绝输出。
func _test_15_illegal_finish_in_move_window() -> void:
	const NAME: String = "15_MOVE_WINDOW非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _SignalRecorder = _SignalRecorder.new(c)
	c.state_changed.connect(Callable(r, "on_changed"))
	## 推进到 MOVE_WINDOW 作为非法 finish 的前置状态。
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(false) == true, "前置 finish_pulse(false) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"前置状态期望 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	r.clear()
	## 预期拒绝：finish_pulse(false) 在 MOVE_WINDOW 被拒，Controller 内部 push_error。
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"状态应保持 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])
	## 预期拒绝：finish_pulse(true) 在 MOVE_WINDOW 同样被拒，覆盖另一参数。
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(true) == false, "finish_pulse(true) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.MOVE_WINDOW,
		"状态应保持 MOVE_WINDOW，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])


## 16. COMPLETED 非法 finish：在 COMPLETED 调用 finish_pulse(false)。
## 补齐 GPT-5.6sol 缺口：覆盖 COMPLETED 下非法 finish 的拒绝行为。
## 确认返回 false、状态仍为 COMPLETED、不新增信号；push_error 属预期拒绝输出。
func _test_16_illegal_finish_in_completed() -> void:
	const NAME: String = "16_COMPLETED非法finish"
	var c: RefCounted = _RunStateController.new()
	var r: _SignalRecorder = _SignalRecorder.new(c)
	c.state_changed.connect(Callable(r, "on_changed"))
	## 推进到 COMPLETED 作为非法 finish 的前置状态。
	_check(NAME, c.begin_pulse() == true, "前置 begin_pulse 期望返回 true。")
	_check(NAME, c.finish_pulse(true) == true, "前置 finish_pulse(true) 期望返回 true。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED,
		"前置状态期望 COMPLETED，实际 %s。" % [_state_label(c.get_current_state())])
	r.clear()
	## 预期拒绝：finish_pulse(false) 在 COMPLETED 被拒，Controller 内部 push_error。
	_expected_rejection_count += 1
	_check(NAME, c.finish_pulse(false) == false, "finish_pulse(false) 期望返回 false。")
	_check(NAME, c.get_current_state() == _Types.RunState.COMPLETED,
		"状态应保持 COMPLETED，实际 %s。" % [_state_label(c.get_current_state())])
	_check(NAME, r.count() == 0, "不应新增信号，实际新增 %d。" % [r.count()])


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 把 RunState 值映射为稳定的人类可读名称，用于失败明细。
func _state_label(state: int) -> String:
	match state:
		_Types.RunState.SETUP:
			return "SETUP"
		_Types.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_Types.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_Types.RunState.COMPLETED:
			return "COMPLETED"
		_:
			return "未知(%d)" % [state]


## 输出测试摘要：测试组数、断言数、通过/失败、预期拒绝输出数量与全部失败明细。
func _report() -> void:
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== RunStateController 批次 4A 测试摘要 ====")
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
