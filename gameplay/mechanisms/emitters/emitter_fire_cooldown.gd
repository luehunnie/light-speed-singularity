class_name EmitterFireCooldown
extends RefCounted

## 主发射器统一发射 cooldown（M4-E1）。
## 职责：作为主发射器“0.5 秒发射间隔”的纯职责组件——记录上次成功发射时刻、回答当前是否 ready、
##   成功发射后开始 0.5 秒 cooldown、R 重置后 ready。RAY/PARTICLE 共用同一实例（形态无关，不因形态切换重置）。
## 位置：gameplay/mechanisms/emitters 下；纯组件，由 LevelRuntimeController 唯一持有（on_fire_success/reset 由 LRC 在成功发射 / R 重置时调用）。
## 依赖：零 gameplay 脚本依赖；生产读单调时钟 Time.get_ticks_msec()；测试经 _init 注入可控时钟 Callable（时间 seam），不真实 sleep。
## 不负责（硬边界——本组件绝不做以下任何一项）：
##   - 依赖场上活动 emission 数量（cooldown 与 active emission 完全独立）；
##   - 依赖 Particle / Ray / 调度器 / 视觉；
##   - 修改 RunStateController / 决定 PULSE_ACTIVE / 决定 COMPLETED；
##   - 因形态切换重置（形态切换不消费 / 不重置 cooldown）；
##   - 创建 Timer / 推进 Tick / 维护 generation / 维护 emission_id。
## 设计要点：只有“成功发射”才调用 on_fire_success 开始新 cooldown；失败 / 拒绝发射不调用（自然不消费 cooldown）。
##   M4-E3 起 cooldown 已接为 request_fire 零副作用预检硬门（FireRequestPreflight，发射权限之外唯一节流；
##   PULSE_ACTIVE repeated fire 开放，0.5s 到期即可再发射）；is_ready 同时供 GUI / 诊断读取，仍是唯一事实来源。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## 主发射器统一发射间隔（冻结 0.5 秒；RAY/PARTICLE 共用）。
const FIRE_INTERVAL_SECONDS: float = 0.5

## 可控时间 seam：测试注入 () -> float 的时钟 Callable 驱动 ready 判定，不真实 sleep。
## 生产留空（默认 Callable()）→ _now 直接读 Time.get_ticks_msec() / 1000.0 单调秒。
var _time_clock: Callable
## 上次成功发射后 ready 再次可发的单调时刻（秒）；0.0 表示 ready（初始 / reset 后）。
var _ready_at: float = 0.0


## 构造 cooldown；time_clock 为可选时间 seam（生产留空读单调时钟，测试注入可控时钟）。
## [br]输入：time_clock 签名 () -> float，返回单调秒；留空（默认）则生产用 Time.get_ticks_msec() / 1000.0。
## [br]副作用：仅写 _time_clock；不读时钟、不写 _ready_at（初始即 ready）。
func _init(time_clock: Callable = Callable()) -> void:
	_time_clock = time_clock


## 取当前单调秒：注入时钟优先，否则生产读 Time.get_ticks_msec() / 1000.0。
func _now() -> float:
	if _time_clock.is_valid():
		return float(_time_clock.call())
	return Time.get_ticks_msec() / 1000.0


## 当前是否 ready（距上次成功发射已满 0.5 秒，或从未成功发射 / 已 reset）。
## [br]返回：true 表示可再次发射（按 cooldown 维度）；false 表示仍在 0.5 秒 cooldown 内。
## [br]副作用：无；纯查询。
## [br]边界：只回答 cooldown 维度，不代表 RunState 发射权限（SETUP/COMPLETED 仍不可发射，由 LRC 判定）。
func is_ready() -> bool:
	return _now() >= _ready_at


## 成功发射后开始新的 0.5 秒 cooldown；仅由 LRC 在一次成功 request_fire 后调用。
## [br]副作用：_ready_at = _now() + FIRE_INTERVAL_SECONDS。
## [br]边界：不查 RunState、不查 active emission、不查形态；失败 / 拒绝发射不调用本方法（调用方语义保证）。
func on_fire_success() -> void:
	_ready_at = _now() + FIRE_INTERVAL_SECONDS


## R 完整重置后恢复 ready；由 LRC 在 reset_runtime 调用。
## [br]副作用：_ready_at = 0.0。
## [br]边界：不重置注入时钟（时钟跨 R 复用）；幂等（已 ready 时仍 ready）。
func reset() -> void:
	_ready_at = 0.0


## 上次成功发射后 ready 再次可发的单调时刻（只读诊断 / 测试；0.0 = ready）。
func get_ready_at() -> float:
	return _ready_at
