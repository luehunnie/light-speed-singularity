class_name RuntimeStateRules
extends RefCounted

## 运行状态纯规则共享模块（批次 4B-F2；D7-2 扩展五态权限合同）。
## 职责：集中持有依赖 RunState 的纯状态权限规则与脉冲结束状态计算，
## 作为正式玩法层与启动自检共用的唯一规则来源，避免状态权限判断分散在关卡控制器内部导致下游自检与未来模块各自复制一份。
## 本模块只计算状态结果，不执行任何状态切换：不调用 _set_run_state、不刷新 UI、不取消拖拽、不写 current_run_state、
## 不读写真实玩法状态、不访问 Node、场景树、信号、文件、时间或随机数。
## 调用方（core_loop_prototype / LevelRuntimeController）仍负责状态切换事务、UI 刷新、拖拽取消、发射流程、R 重置与关卡完成逻辑；
## 本模块仅在调用方查询时提供纯判断与脉冲结束目标状态推导，状态切换事务仍由调用方负责。
## 依赖：通过 preload 引用 res://gameplay/interaction/runtime_interaction_types.gd 取得 RunState 枚举，
## 不定义第二份 RunState，不依赖 Diagnostics，不依赖 RuntimeMoveRules，不修改 RunState 数值。
## D7-2 权限合同（五态）：SETUP 仅可 begin_runtime 不可发射；READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW 属运行期移动状态；
## READY_TO_FIRE 与 MOVE_WINDOW 允许发射；PULSE_ACTIVE 与 COMPLETED 拒绝发射；COMPLETED 冻结布局与配置。
## 未来扩展保护：can_edit_configuration 当前只表示机关内部人工配置（主发射源方向、机关内部模式等），
## 不代表“运行期所有可操作属性永久锁死”——未来主发射器八方向运行控制、RAY/PARTICLE 形态切换等运行期可操作属性
## 将使用专用权限规则（由关卡配置决定是否可用），本批不实现，不得在注释或架构中把本函数定义成永久锁死的底层公共规则。
## 已知临时边界：is_configuration_locked 未进入本模块公共接口，仍由 core_loop 以薄包装形式临时持有，待 F3 迁移自检后删除。

const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)


## 查询当前运行状态是否允许发射普通脉冲（纯判断，无副作用）。
## [br]职责：判定 Space 发射权限。
## [br]输入：state 是当前运行状态。
## [br]返回：true 表示 READY_TO_FIRE 或 MOVE_WINDOW 可以发射；false 表示 SETUP、PULSE_ACTIVE 或 COMPLETED 必须拒绝 Space。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：只负责发射权限判定，不执行发射流程，不清理光路视觉，不改变 current_run_state；
## D7-2 起 SETUP 不再允许直接 Space 发射，必须先经 Runtime Validation Gate 进入 READY_TO_FIRE；
## 完成标签已显示但脉冲尚未视觉结束时，状态仍是 PULSE_ACTIVE，因此重复 Space 仍被拒绝，该事实由调用方传入的 state 体现。
static func can_fire_light(
		state: _RuntimeInteractionTypes.RunState
) -> bool:
	return state == _RuntimeInteractionTypes.RunState.READY_TO_FIRE or state == _RuntimeInteractionTypes.RunState.MOVE_WINDOW


## 查询当前运行状态是否允许请求进入正式运行（纯判断，无副作用）。
## [br]职责：判定 begin_runtime 入口权限，即是否可从当前状态请求 SETUP→READY_TO_FIRE。
## [br]输入：state 是当前运行状态。
## [br]返回：true 仅表示当前处于 SETUP；其他状态全部返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：只判定 begin_runtime 的状态前提，不执行 Gate 校验、不切换状态；
## [br]READY_TO_FIRE 已成立时重复请求返回 false（幂等由 RunStateController.begin_runtime 拒绝重复 READY 体现）。
## [br]本函数不代表“是否允许开始运行”的最终事实——最终是否进入 READY_TO_FIRE 由 Runtime Validation Gate 校验结果与 RunStateController 共同决定。
static func can_begin_runtime(
		state: _RuntimeInteractionTypes.RunState
	) -> bool:
	return state == _RuntimeInteractionTypes.RunState.SETUP


## 查询当前运行状态是否处于非冻结状态（粗粒度冻结门，纯判断，无副作用）。
## [br]职责：判定关卡整体布局编辑是否未被 COMPLETED 冻结。
## [br]输入：state 是当前运行状态。
## [br]返回：true 表示当前不是 COMPLETED（关卡未冻结）；false 表示 COMPLETED 已冻结整个关卡交互。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：本函数只是粗粒度冻结门（非 COMPLETED 返回 true），不是拿取、移动、回收的唯一守卫，
## 也不代表内部配置编辑权限；拿取/回收/拖起/跨格提交的细粒度权限由 RuntimeMoveRules 与调用方各自负责。
## 本函数不执行状态切换，不取消拖拽，不刷新 UI。
static func can_edit_layout(
		state: _RuntimeInteractionTypes.RunState
) -> bool:
	return state != _RuntimeInteractionTypes.RunState.COMPLETED


## 查询当前运行状态是否允许人工编辑内部配置（纯判断，无副作用）。
## [br]职责：判定主发射源方向、机关内部模式等内部配置编辑权限。
## [br]输入：state 是当前运行状态。
## [br]返回：true 仅表示当前处于 SETUP；其他状态全部返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：本权限只用于内部配置，不代表布局编辑权限，不得用于控制拖拽放置、移动或回收；
## 本函数不执行状态切换，不刷新 UI，不取消拖拽。
static func can_edit_configuration(
		state: _RuntimeInteractionTypes.RunState
) -> bool:
	return state == _RuntimeInteractionTypes.RunState.SETUP


## 查询当前运行状态是否处于普通脉冲活动窗口（纯判断，无副作用）。
## [br]职责：判定当前是否处于 PULSE_ACTIVE。
## [br]输入：state 是当前运行状态。
## [br]返回：true 表示 state 为 PULSE_ACTIVE；其他状态返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：通关目标可在 PULSE_ACTIVE 期间已成立，脉冲活动仍以运行状态为准，该事实由调用方传入的 state 体现；
## 本函数不执行状态切换，不清理光路视觉，不刷新 UI。
static func is_pulse_active(
		state: _RuntimeInteractionTypes.RunState
) -> bool:
	return state == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE


## 查询当前运行状态是否处于运行期移动状态（纯判断，无副作用）。
## [br]职责：判定当前是否处于会消耗运行期移动次数的状态（READY_TO_FIRE、PULSE_ACTIVE 或 MOVE_WINDOW）。
## [br]输入：state 是当前运行状态。
## [br]返回：true 表示当前处于 READY_TO_FIRE、PULSE_ACTIVE 或 MOVE_WINDOW；SETUP 与 COMPLETED 返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入枚举。
## [br]失败：不会失败；任意 RunState 输入均返回确定布尔结果。
## [br]边界：运行期移动次数只在 READY_TO_FIRE、PULSE_ACTIVE 和 MOVE_WINDOW 中扣除，SETUP 移动不计次，COMPLETED 冻结全部布局交互；
## 是否真正扣次由 RuntimeMoveRules 与调用方在占用原子更新成功后决定，本函数只判定状态归属，不执行状态切换。
static func is_runtime_move_state(
		state: _RuntimeInteractionTypes.RunState
) -> bool:
	return state == _RuntimeInteractionTypes.RunState.READY_TO_FIRE or state == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE or state == _RuntimeInteractionTypes.RunState.MOVE_WINDOW


## 决定有效普通脉冲结束后应进入的目标状态（纯计算，无副作用）。
## [br]职责：在 PULSE_ACTIVE 结束后按关卡完成事实二选一推导目标运行状态。
## [br]输入：level_completed 表示脉冲结算后关卡完成条件是否已经成立。
## [br]返回：level_completed 为 true 时返回 COMPLETED，否则返回 MOVE_WINDOW。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入布尔。
## [br]失败：不会失败；任意 bool 输入均返回确定 RunState。
## [br]边界：只负责 PULSE_ACTIVE 结束后的二选一状态推导，不处理 R、非法发射、拖拽或移动次数；
## 本函数不执行 _set_run_state，不刷新 UI，不取消拖拽，目标状态的实际切换事务由调用方在 _finish_current_pulse 中负责。
static func get_post_pulse_state(
		level_completed: bool
) -> _RuntimeInteractionTypes.RunState:
	return _RuntimeInteractionTypes.RunState.COMPLETED if level_completed else _RuntimeInteractionTypes.RunState.MOVE_WINDOW
