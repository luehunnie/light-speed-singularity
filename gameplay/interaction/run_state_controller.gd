class_name RunStateController
extends RefCounted

## 运行状态控制器。
##
## 职责：
## 持有当前关卡的唯一运行状态事实（_current_state），提供同步状态查询、最小合法状态转换与状态变化信号。
## 权限查询全部转发到 RuntimeStateRules，不在本类复制任何状态权限判断；脉冲结束目标状态由
## RuntimeStateRules.get_post_pulse_state 推导，完成状态判断不在此处复制。
## 本类只验证最小合法状态转换并发出 state_changed 信号，不接管任何业务副作用。
##
## 在当前系统中的位置：
## gameplay/interaction 下独立的 RefCounted 控制器，已接入 core_loop_prototype，是当前运行状态的唯一所有者。
## core_loop_prototype 不再持有 current_run_state，核心不直接写状态，而是通过 begin_runtime()、begin_pulse()、finish_pulse()、
## reset_to_setup() 请求转换；脉冲生成、异步脉冲结束与完整 R 运行编排由 LevelRuntimeController 负责，本类仅拥有运行状态事实并执行合法状态转换。
## RunState 枚举（D7-2 起五态）的权威仍属于 RuntimeInteractionTypes，本类不定义第二份枚举；新增 begin_runtime() 负责 SETUP→READY_TO_FIRE。
##
## 主要依赖：
## RuntimeInteractionTypes（RunState 枚举契约）与 RuntimeStateRules（纯状态规则单一来源），均通过 preload 引用。
## 不依赖 Autoload、场景节点、core_loop_prototype、Diagnostics 或任何尚未实现的模块。
##
## 明确不负责：
## 输入、Space/R 监听、光传播、脉冲计时、pulse_generation、is_level_completed 维护、拖拽取消、UI 刷新、
## 库存、占用、水晶、Diagnostics、场景树、节点路径、文件读写。
## R 的完整运行期重置由 LevelRuntimeController 负责；RunStateController 只负责重置到 SETUP 的合法状态转换。
##
## 关键状态生命周期：
## 初始状态默认 SETUP；begin_runtime 将 SETUP 推进到 READY_TO_FIRE（D7-2 新增，须经 Runtime Validation Gate）；begin_pulse 将 READY_TO_FIRE/MOVE_WINDOW 推进到 PULSE_ACTIVE；
## finish_pulse 按 level_completed 将 PULSE_ACTIVE 推进到 MOVE_WINDOW 或 COMPLETED；
## reset_to_setup 从任意合法状态回到 SETUP（幂等：已为 SETUP 时不发信号）。
##
## 关键边界：
## - RunState 枚举权威仍在 RuntimeInteractionTypes，本类不重新定义枚举；D7-2 已纳入 READY_TO_FIRE（数值 4，旧 0~3 不变）。
## - 信号在 _current_state 更新之后发出；非法转换不发信号、不改状态。
## - 构造函数对非法初始值只做防御性回退到 SETUP，不发信号，不是业务状态自愈。
## - reset_to_setup 的幂等行为在公开方法中显式处理，不走 _try_transition 的转换集合。
## - 不公开通用 set_state；_can_transition 只允许冻结的转换集合，不允许任意跳转或同态转换。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与 gameplay/interaction 下既有模块的引用方式保持一致，避开 MCP run_project 不重建全局类型缓存的问题。
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _RuntimeStateRules: GDScript = preload(
	"res://gameplay/interaction/runtime_state_rules.gd"
)


## 当前运行状态发生变化时发出。
## [br]职责：通知外部观察者状态已真实切换，用于驱动 UI/拖拽/光路等下游反应（下游反应由各自模块负责）。
## [br]参数：previous_state 为切换前的运行状态；new_state 为切换后的运行状态。
## [br]时序：先更新 _current_state，再发出本信号；非法转换与幂等 SETUP 重置不发本信号。
## [br]边界：本信号只携带状态事实，不携带完成标志、拖拽来源或任何业务负载。
signal state_changed(
	previous_state: RuntimeInteractionTypes.RunState,
	new_state: RuntimeInteractionTypes.RunState
)


## 唯一运行状态事实。
## [br]职责：持有当前关卡的 RunState，是本类的唯一可变状态。
## [br]合法取值：RuntimeInteractionTypes.RunState 的五个成员之一；由构造函数与受控转换维护不变量。
## [br]边界：不公开直接写入；外部只能通过查询接口读取、通过转换接口变更。
var _current_state: RuntimeInteractionTypes.RunState


## 构造函数，初始化唯一运行状态。
## [br]职责：把 _current_state 设置为给定初始状态，非法值时安全回退到 SETUP。
## [br]参数：initial_state 为可选初始 RunState，默认 SETUP；必须为五个合法枚举值之一。
## [br]返回：无；构造结果体现在 _current_state。
## [br]副作用：只写入 _current_state；不发出 state_changed 信号（构造不属于状态变化）。
## [br]失败条件：initial_state 不属于 RunState 五个成员时 push_error 并回退到 SETUP，不抛异常、不发信号。
## [br]边界：这只是构造防御，不是业务状态自动修复；合法初始值直接采用，不做转换校验。
func _init(initial_state: RuntimeInteractionTypes.RunState = RuntimeInteractionTypes.RunState.SETUP) -> void:
	if not _is_valid_state(initial_state):
		push_error("RunStateController 构造传入非法 RunState 初始值，已安全回退为 SETUP。")
		_current_state = _RuntimeInteractionTypes.RunState.SETUP
		return
	_current_state = initial_state


## 查询当前运行状态。
## [br]职责：同步返回 _current_state，无副作用。
## [br]返回：当前 RunState。
## [br]副作用：无；不写日志、不发信号、不调用任何规则。
## [br]边界：纯读取，调用方可在任意状态安全调用。
func get_current_state() -> RuntimeInteractionTypes.RunState:
	return _current_state


## 查询当前是否允许发射普通脉冲。
## [br]职责：转发到 RuntimeStateRules.can_fire_light，不复制权限判断。
## [br]返回：true 表示 READY_TO_FIRE、PULSE_ACTIVE 或 MOVE_WINDOW 可发射（M4-E3 起 PULSE_ACTIVE 开放 repeated fire，唯一额外节流为 0.5 秒 cooldown，由调用方预检）；false 表示 SETUP 或 COMPLETED 拒绝。
## [br]副作用：无；纯查询，不发信号、不写日志。
## [br]边界：只判定发射权限，不执行发射流程，不改变状态。
func can_fire_light() -> bool:
	return _RuntimeStateRules.can_fire_light(_current_state)


## 查询当前是否允许请求进入正式运行就绪态。
## [br]职责：转发到 RuntimeStateRules.can_begin_runtime，不复制权限判断。
## [br]返回：true 表示当前为 SETUP，可请求 begin_runtime；其他状态返回 false。
## [br]副作用：无；纯查询，不发信号、不写日志。
## [br]边界：只判定 begin_runtime 的状态前提；不代表 Gate 校验通过，不切换状态。
func can_begin_runtime() -> bool:
	return _RuntimeStateRules.can_begin_runtime(_current_state)


## 查询当前是否允许粗粒度布局编辑（非 COMPLETED 冻结门）。
## [br]职责：转发到 RuntimeStateRules.can_edit_layout。
## [br]返回：true 表示当前不是 COMPLETED；false 表示 COMPLETED 已冻结整个关卡交互。
## [br]副作用：无；纯查询。
## [br]边界：只是粗粒度冻结门，不是拿取/移动/回收的唯一守卫，不代表内部配置编辑权限。
func can_edit_layout() -> bool:
	return _RuntimeStateRules.can_edit_layout(_current_state)


## 查询当前是否允许人工编辑内部配置。
## [br]职责：转发到 RuntimeStateRules.can_edit_configuration。
## [br]返回：true 仅表示当前处于 SETUP；其他状态返回 false。
## [br]副作用：无；纯查询。
## [br]边界：只用于内部配置权限，不代表布局编辑权限，不控制拖拽放置/移动/回收。
func can_edit_configuration() -> bool:
	return _RuntimeStateRules.can_edit_configuration(_current_state)


## 查询当前是否处于普通脉冲活动窗口。
## [br]职责：转发到 RuntimeStateRules.is_pulse_active。
## [br]返回：true 表示当前为 PULSE_ACTIVE；其他状态返回 false。
## [br]副作用：无；纯查询。
## [br]边界：通关目标可在 PULSE_ACTIVE 期间已成立，脉冲活动仍以运行状态为准；不清理光路、不刷新 UI。
func is_current_pulse_active() -> bool:
	return _RuntimeStateRules.is_pulse_active(_current_state)


## 查询当前是否处于运行期移动状态（会消耗运行期移动次数的状态）。
## [br]职责：转发到 RuntimeStateRules.is_runtime_move_state。
## [br]返回：true 表示当前处于 READY_TO_FIRE、PULSE_ACTIVE 或 MOVE_WINDOW；SETUP 与 COMPLETED 返回 false。
## [br]副作用：无；纯查询。
## [br]边界：只判定状态归属，是否真正扣次由 RuntimeMoveRules 与调用方决定，本函数不执行状态切换。
func is_runtime_move_state() -> bool:
	return _RuntimeStateRules.is_runtime_move_state(_current_state)


## 请求进入正式运行就绪态（READY_TO_FIRE）。
## [br]职责：在 SETUP 下切换到 READY_TO_FIRE，作为经 Runtime Validation Gate 通过后的正式运行就绪入口。
## [br]返回：true 表示成功切换并已发出 state_changed；false 表示被拒绝。
## [br]副作用：成功时先更新 _current_state 再发出 state_changed；失败时不改状态、不发信号。
## [br]失败条件：当前状态不是 SETUP 时 push_error 并返回 false（含 READY_TO_FIRE 重复请求，以及 PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 来源）。
## [br]边界：本类只负责 SETUP→READY_TO_FIRE 的合法状态转换；不执行 Gate 校验（Gate 由调用方在请求前调用）、
## [br]不执行发射流程、不清理光路、不维护 pulse_generation 或 is_level_completed。
func begin_runtime() -> bool:
	if _current_state != _RuntimeInteractionTypes.RunState.SETUP:
		push_error("RunStateController.begin_runtime 被拒绝：当前状态 %s 不允许进入 READY_TO_FIRE，仅允许 SETUP。" % _state_label(_current_state))
		return false
	return _try_transition(_RuntimeInteractionTypes.RunState.READY_TO_FIRE)


## 开始一次普通脉冲，将状态推进到 PULSE_ACTIVE。
## [br]职责：在 READY_TO_FIRE 或 MOVE_WINDOW 下切换到 PULSE_ACTIVE。
## [br]返回：true 表示成功切换并已发出 state_changed；false 表示被拒绝。
## [br]副作用：成功时先更新 _current_state 再发出 state_changed；失败时不改状态、不发信号。
## [br]失败条件：当前状态不是 READY_TO_FIRE 或 MOVE_WINDOW 时 push_error 并返回 false（SETUP 须先经 begin_runtime 进入 READY_TO_FIRE）。
## [br]边界：只负责状态切换，不执行发射流程、不清理光路、不维护 pulse_generation 或 is_level_completed。
func begin_pulse() -> bool:
	if _current_state != _RuntimeInteractionTypes.RunState.READY_TO_FIRE and _current_state != _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
		push_error("RunStateController.begin_pulse 被拒绝：当前状态 %s 不允许开始脉冲，仅允许 READY_TO_FIRE 或 MOVE_WINDOW。" % _state_label(_current_state))
		return false
	return _try_transition(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE)


## 结束当前普通脉冲，按完成事实推进到 MOVE_WINDOW 或 COMPLETED。
## [br]职责：在 PULSE_ACTIVE 下依据 level_completed 推导目标状态并切换。
## [br]参数：level_completed 表示脉冲结算后关卡完成条件是否已成立。
## [br]返回：true 表示成功切换并已发出 state_changed；false 表示被拒绝。
## [br]副作用：成功时先更新 _current_state 再发出 state_changed；失败时不改状态、不发信号。
## [br]失败条件：当前状态不是 PULSE_ACTIVE 时 push_error 并返回 false。
## [br]边界：目标状态由 RuntimeStateRules.get_post_pulse_state 推导，不复制完成状态判断；
## [br]不维护 is_level_completed，不清理光路视觉，不取消拖拽。
func finish_pulse(level_completed: bool) -> bool:
	if _current_state != _RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
		push_error("RunStateController.finish_pulse 被拒绝：当前状态 %s 不是 PULSE_ACTIVE，无法结束脉冲。" % _state_label(_current_state))
		return false
	var target: RuntimeInteractionTypes.RunState = _RuntimeStateRules.get_post_pulse_state(level_completed)
	return _try_transition(target)


## 将状态重置回 SETUP。
## [br]职责：从任意合法状态回到 SETUP，用于 R 完整重置的最终状态回归。
## [br]返回：true 表示已处于 SETUP 或成功回到 SETUP。
## [br]副作用：仅在当前不是 SETUP 时先更新 _current_state 再发出 state_changed；
## [br]已是 SETUP 时不改状态、不发信号（幂等）。
## [br]失败条件：不会失败；当前状态始终为合法 RunState。
## [br]边界：本类不执行完整 R 运行期重置；该编排（删除玩家机关、占用注销、库存恢复、运行期移动次数归零、
## [br]光路/水晶/完成状态重置、ObjectiveController 重置与 UI 一致性刷新）由 LevelRuntimeController 负责。
## [br]本类只负责 reset_to_setup() 的合法状态转换并发出 state_changed；幂等行为在本公开方法中显式处理，不走 _try_transition。
func reset_to_setup() -> bool:
	if _current_state == _RuntimeInteractionTypes.RunState.SETUP:
		return true
	var previous: RuntimeInteractionTypes.RunState = _current_state
	_current_state = _RuntimeInteractionTypes.RunState.SETUP
	state_changed.emit(previous, _current_state)
	return true


## 执行一次受控状态转换。
## [br]职责：校验 _current_state → new_state 属于冻结转换集合，通过则更新状态并发出信号。
## [br]参数：new_state 为目标 RunState。
## [br]返回：true 表示成功；false 表示转换非法。
## [br]副作用：成功时先更新 _current_state 再发出 state_changed；失败时不改状态、不发信号。
## [br]失败条件：_can_transition 判定非法时 push_error 并返回 false。
## [br]边界：不允许通过同态转换（相同状态）掩盖非法语义调用；→SETUP 不在本方法转换集合内，
## [br]仅 reset_to_setup 可回到 SETUP；不公开通用 set_state。
func _try_transition(new_state: RuntimeInteractionTypes.RunState) -> bool:
	if not _can_transition(_current_state, new_state):
		push_error("RunStateController 状态转换被拒绝：%s → %s 不是合法转换。" % [_state_label(_current_state), _state_label(new_state)])
		return false
	var previous: RuntimeInteractionTypes.RunState = _current_state
	_current_state = new_state
	state_changed.emit(previous, new_state)
	return true


## 校验给定值是否为合法 RunState 枚举成员。
## [br]职责：封闭枚举成员判定，供构造函数防御性校验使用。
## [br]参数：state 为待校验的 RunState 值。
## [br]返回：true 表示属于五个合法成员之一；false 表示非法。
## [br]副作用：无；纯判断。
## [br]边界：因 GDScript 枚举底层为整数，需显式成员判定，不接受任意整数。
func _is_valid_state(state: RuntimeInteractionTypes.RunState) -> bool:
	return state == _RuntimeInteractionTypes.RunState.SETUP or state == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE or state == _RuntimeInteractionTypes.RunState.MOVE_WINDOW or state == _RuntimeInteractionTypes.RunState.COMPLETED or state == _RuntimeInteractionTypes.RunState.READY_TO_FIRE


## 校验 previous → new 是否属于冻结的最小合法转换集合。
## [br]职责：只允许 SETUP→READY_TO_FIRE、READY_TO_FIRE/MOVE_WINDOW→PULSE_ACTIVE、PULSE_ACTIVE→MOVE_WINDOW/COMPLETED。
## [br]参数：previous 为切换前 RunState；new_state 为目标 RunState。
## [br]返回：true 表示属于冻结集合；false 表示非法。
## [br]副作用：无；纯判断。
## [br]边界：→SETUP 不在集合内，仅 reset_to_setup 可回到 SETUP；不允许任意跳转、不允许同态转换。
func _can_transition(
		previous: RuntimeInteractionTypes.RunState,
		new_state: RuntimeInteractionTypes.RunState
) -> bool:
	if previous == _RuntimeInteractionTypes.RunState.SETUP and new_state == _RuntimeInteractionTypes.RunState.READY_TO_FIRE:
		return true
	if previous == _RuntimeInteractionTypes.RunState.READY_TO_FIRE and new_state == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
		return true
	if previous == _RuntimeInteractionTypes.RunState.MOVE_WINDOW and new_state == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
		return true
	if previous == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE and new_state == _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
		return true
	if previous == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE and new_state == _RuntimeInteractionTypes.RunState.COMPLETED:
		return true
	return false


## 将 RunState 映射为稳定的人类可读名称，用于错误信息。
## [br]职责：只做枚举值到字符串的映射，不包含任何状态规则。
## [br]参数：state 为待映射的 RunState。
## [br]返回：对应状态名字符串；未知值返回“未知状态”。
## [br]副作用：无；不修改输入，不访问场景树/文件/时间/随机数。
## [br]边界：仅 match 映射，不依赖 str(enum) 的不稳定行为；不使用 Callable、Variant、Dictionary 或无类型容器。
func _state_label(state: RuntimeInteractionTypes.RunState) -> String:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return "SETUP"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return "COMPLETED"
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			return "READY_TO_FIRE"
		_:
			return "未知状态"
