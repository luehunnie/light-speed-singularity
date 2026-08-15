class_name RuntimeStateCheck
extends RefCounted

## 运行状态纯规则启动期自检模块（Diagnostics 批次 4B-F3；D7-2 扩展五态）。
##
## 职责：
## 把原核心闭环原型中的 _run_post_pulse_state_self_check() 测试案例抽离为独立、
## 无副作用、不访问场景树的纯函数式自检；覆盖 RuntimeStateRules 的脉冲结束目标状态推导
## 与五条 RunState 下的五条纯权限规则（can_fire_light / can_edit_layout /
## can_edit_configuration / configuration_locked / pulse_active），共 27 项案例。
## 本模块只验证正式规则接口的事实输出，不复制任何状态判断规则，不执行任何状态切换事务。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；由核心闭环原型以薄包装形式构造
## SelfCheckCallable 并交由 SelfCheckRunner 执行，保持原 Debug 硬断言失败语义。
##
## 主要依赖：
## RuntimeStateRules（玩法层共享纯规则，单一来源）与 RuntimeInteractionTypes（RunState
## 共享枚举契约），以及 SelfCheckResult 数据契约。不依赖场景树、节点、时间 API、文件系统或真实玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、状态切换事务编排。
## 本模块只如实报告规则接口的检查事实，不修改任何玩法状态，不决定实际状态切换，不复制规则实现。
##
## 关键边界：
## - run() 只读：只调用 RuntimeStateRules 的公开静态纯函数与 RuntimeInteractionTypes 的枚举常量，
##   不读取 core_loop.current_run_state、不读取 level_completed 或 pulse_generation 实例字段、
##   不访问 core_loop 私有字段、不访问场景树、不创建 Node、不执行 _set_run_state、不触发 UI/拖拽/状态事务。
## - 只验证纯状态规则：所有 RunState 输入均为本模块显式构造的测试数据，不来自真实运行状态。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能执行全部 27 项案例并汇总全部失败。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 不使用文件系统、系统时间或随机数。
## - configuration_locked 期望通过 not _RuntimeStateRules.can_edit_configuration(state) 验证，
##   不要求 RuntimeStateRules 新增 is_configuration_locked 接口。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。
## - D7-2 新增 READY_TO_FIRE（数值 4）案例，SETUP 的 can_fire_light 期望由 true 改为 false（SETUP 不再允许直接发射）。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与核心闭环原型中的引用方式保持一致，避开 MCP run_project 不重建全局类型缓存的问题。
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _RuntimeStateRules: GDScript = preload(
	"res://gameplay/interaction/runtime_state_rules.gd"
)


## 执行运行状态纯规则自检。
## [br]本函数无参数，只读、无业务修复、不执行任何状态切换事务。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"runtime_state_rules"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]职责：只验证 RuntimeStateRules 的纯状态规则，使用显式 RunState 测试数据，
## [br]不读取 core_loop.current_run_state，不读取 level_completed 或 pulse_generation 实例字段，
## [br]不修改任何真实状态，get_post_pulse_state 使用固定 bool 测试输入。
## [br]输入：无；所有测试状态与布尔输入均为本函数内显式构造的常量。
## [br]返回：SelfCheckResult，见上方字段说明。
## [br]副作用：只调用 RuntimeStateRules 与 RuntimeInteractionTypes 的公开静态纯函数；
## [br]不访问场景树、不创建 Node、不读写真实玩法状态、不执行状态切换、不写文件、不写日志、不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能执行全部 27 项案例；
## [br]不使用 assert、push_error 或 push_warning。
## [br]边界条件：覆盖 27 项案例（2 项脉冲结束目标状态 +
## [br]五个 RunState × 五条规则），不新增 is_runtime_move_state、R 重置、状态切换事务或 UI 刷新测试；
## [br]D7-2 起 READY_TO_FIRE 已为正式状态，纳入五态权限矩阵自检；configuration_locked 期望通过
## [br]not _RuntimeStateRules.can_edit_configuration(state) 验证，不复制状态判断规则。
static func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()

	# --- 脉冲结束目标状态推导：get_post_pulse_state（2 项）---
	# 使用固定 bool 测试输入，不读取真实 is_level_completed。
	_expect_state(
			details,
			"post_pulse_state(false) 目标状态",
			_RuntimeStateRules.get_post_pulse_state(false),
			_RuntimeInteractionTypes.RunState.MOVE_WINDOW
		)
	_expect_state(
			details,
			"post_pulse_state(true) 目标状态",
			_RuntimeStateRules.get_post_pulse_state(true),
			_RuntimeInteractionTypes.RunState.COMPLETED
		)

	# --- 五个 RunState 分别验证五条纯权限规则（5 × 5 = 25 项）---
	# 显式构造测试状态，不读取 core_loop.current_run_state；
	# 每行期望值严格对应五态权限合同（M4-E3 起：SETUP 不可发射；READY/PULSE/MOVE 可发射（PULSE 为 repeated fire，0.5s cooldown 由调用方预检）；COMPLETED 不可发射）。
	_check_state_rules(
			details,
			_RuntimeInteractionTypes.RunState.SETUP,
			"SETUP",
			false,  # can_fire_light
			true,   # can_edit_layout
			true,   # can_edit_configuration
			false,  # configuration_locked
			false   # pulse_active
		)
	_check_state_rules(
			details,
			_RuntimeInteractionTypes.RunState.READY_TO_FIRE,
			"READY_TO_FIRE",
			true,   # can_fire_light
			true,   # can_edit_layout
			false,  # can_edit_configuration
			true,   # configuration_locked
			false   # pulse_active
		)
	_check_state_rules(
			details,
			_RuntimeInteractionTypes.RunState.PULSE_ACTIVE,
			"PULSE_ACTIVE",
			true,   # can_fire_light（M4-E3 repeated fire 开放；0.5s cooldown 硬门由调用方预检）
			true,   # can_edit_layout
			false,  # can_edit_configuration
			true,   # configuration_locked
			true    # pulse_active
		)
	_check_state_rules(
			details,
			_RuntimeInteractionTypes.RunState.MOVE_WINDOW,
			"MOVE_WINDOW",
			true,   # can_fire_light
			true,   # can_edit_layout
			false,  # can_edit_configuration
			true,   # configuration_locked
			false   # pulse_active
		)
	_check_state_rules(
			details,
			_RuntimeInteractionTypes.RunState.COMPLETED,
			"COMPLETED",
			false,  # can_fire_light
			false,  # can_edit_layout
			false,  # can_edit_configuration
			true,   # configuration_locked
			false   # pulse_active
		)

	var summary: String = "运行状态规则自检：脉冲结束目标状态与五个 RunState 的五条纯权限规则共 27 项。"
	return SelfCheckResult.new(&"runtime_state_rules", details.is_empty(), summary, details, 0)


## 对单个 RunState 验证五条纯权限规则的期望布尔值，把不一致项追加到 details。
## [br]职责：只整理 can_fire_light / can_edit_layout / can_edit_configuration /
## [br]configuration_locked / pulse_active 五项检查结果，不包含正式状态规则，不复制规则实现。
## [br]输入：details 为累积明细的 PackedStringArray；state 为显式测试 RunState；
## [br]state_name 为人类可读状态名；expect_fire / expect_edit_layout / expect_edit_config /
## [br]expect_locked / expect_pulse 为该状态下的五条期望布尔。
## [br]返回：无返回值；失败时向 details 追加中文明细。
## [br]副作用：仅可能在 details 末尾追加字符串；不修改输入 state，不访问场景树/文件/时间/随机数，
## [br]不读取或修改真实 current_run_state，不执行状态切换。
## [br]失败：任一实际值与期望不符即追加一项明细，不抛异常，不因首项失败提前停止后续检查。
## [br]边界：只调用 RuntimeStateRules 纯规则与 _expect_bool 整理结果；
## [br]configuration_locked 通过 not _RuntimeStateRules.can_edit_configuration(state) 验证；
## [br]不使用 Callable、Variant、Dictionary 或无类型容器。
static func _check_state_rules(
		details: PackedStringArray,
		state: _RuntimeInteractionTypes.RunState,
		state_name: String,
		expect_fire: bool,
		expect_edit_layout: bool,
		expect_edit_config: bool,
		expect_locked: bool,
		expect_pulse: bool
) -> void:
	_expect_bool(
			details,
			"%s.can_fire_light" % [state_name],
			_RuntimeStateRules.can_fire_light(state),
			expect_fire
		)
	_expect_bool(
			details,
			"%s.can_edit_layout" % [state_name],
			_RuntimeStateRules.can_edit_layout(state),
			expect_edit_layout
		)
	_expect_bool(
			details,
			"%s.can_edit_configuration" % [state_name],
			_RuntimeStateRules.can_edit_configuration(state),
			expect_edit_config
		)
	_expect_bool(
			details,
			"%s.configuration_locked" % [state_name],
			not _RuntimeStateRules.can_edit_configuration(state),
			expect_locked
		)
	_expect_bool(
			details,
			"%s.pulse_active" % [state_name],
			_RuntimeStateRules.is_pulse_active(state),
			expect_pulse
		)


## 比较一个布尔实际值与期望值，不一致时向 details 追加稳定中文明细。
## [br]职责：只整理单项布尔检查结果，不包含任何状态规则。
## [br]输入：details 为累积明细的 PackedStringArray；case_name 为案例名；
## [br]actual 为规则返回的布尔实际值；expected 为该案例期望的布尔值。
## [br]返回：无返回值；仅通过 details.append 产生副作用。
## [br]副作用：actual != expected 时向 details 追加一行中文明细，包含 case_name、expected 与 actual；
## [br]不修改 actual/expected，不访问场景树/文件/时间/随机数，不读取或修改真实 current_run_state。
## [br]失败：本函数不会失败，任意布尔输入均安全比较；不抛异常，不提前停止后续检查。
## [br]边界：仅做相等比较与字符串追加，不包含玩法规则；
## [br]不使用 Callable、Variant、Dictionary 或无类型容器。
static func _expect_bool(
		details: PackedStringArray,
		case_name: String,
		actual: bool,
		expected: bool
) -> void:
	if actual != expected:
		details.append("运行状态规则自检：%s 期望 %s，实际 %s。" % [case_name, expected, actual])


## 比较一个 RunState 实际值与期望值，不一致时向 details 追加稳定中文明细。
## [br]职责：只整理单项状态检查结果，不包含任何状态规则。
## [br]输入：details 为累积明细的 PackedStringArray；case_name 为案例名；
## [br]actual 为规则返回的 RunState 实际值；expected 为该案例期望的 RunState 值。
## [br]返回：无返回值；仅通过 details.append 产生副作用。
## [br]副作用：actual != expected 时向 details 追加一行中文明细，包含 case_name、期望状态名与实际状态名；
## [br]不修改 actual/expected，不访问场景树/文件/时间/随机数，不读取或修改真实 current_run_state。
## [br]失败：本函数不会失败，任意 RunState 输入均安全比较；不抛异常，不提前停止后续检查。
## [br]边界：仅做相等比较与字符串追加，不包含玩法规则；
## [br]不使用 Callable、Variant、Dictionary 或无类型容器。
static func _expect_state(
		details: PackedStringArray,
		case_name: String,
		actual: _RuntimeInteractionTypes.RunState,
		expected: _RuntimeInteractionTypes.RunState
) -> void:
	if actual != expected:
		details.append("运行状态规则自检：%s 期望 %s，实际 %s。" % [case_name, _state_label(expected), _state_label(actual)])


## 把 RunState 枚举值映射为稳定的人类可读中文名，用于失败明细。
## [br]职责：只做枚举值到字符串的映射，不包含任何状态规则。
## [br]输入：state 为待映射的 RunState 枚举值。
## [br]返回：对应的状态名字符串；未知值返回“未知状态”。
## [br]副作用：无；不修改输入 state，不访问场景树/文件/时间/随机数。
## [br]失败：本函数不会失败；未知枚举值返回固定字符串，不抛异常。
## [br]边界：仅做 match 映射，不依赖 str(enum) 的不稳定行为；
## [br]不使用 Callable、Variant、Dictionary 或无类型容器。
static func _state_label(state: _RuntimeInteractionTypes.RunState) -> String:
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
