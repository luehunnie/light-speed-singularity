class_name ParticleVisualEvent
extends RefCounted

## Particle 视觉 detached 事件纯构造器（D7-4 B4a）。
## 职责：把 Particle gameplay Runtime 的 detached 只读数据（scheduler snapshot Dictionary / BatchEvent 数组）换算为
##   纯值 Dictionary 事件 payload，供 LevelRuntimeController 极薄转发到 ParticleVisualController。
##   本模块是 gameplay→visual 的唯一数据换算边界——visual 永远只收到 detached 值数据，无法反向触及
##   ParticleScheduler / ParticleRuntimeState / _active_states / BatchEvent 原对象 / 任何 gameplay Node。
## 位置：gameplay/visuals/particles 下；纯函数模块，不持有任何 gameplay 状态、不引用 scheduler/state/world query/Node。
## 依赖：通过 preload 引用 ParticleStepExecutor（仅读 Outcome / TerminationReason 常量做字符串翻译，绝不调任何 gameplay 方法）——
##   这是 gameplay→visual 唯一常量桥接点；除此之外不引用 ParticleScheduler / ParticleRuntimeState / world query / visual Node。
## 不负责（硬边界）：创建/移动/销毁视觉节点、Tween、cell_to_world、rotation、维护 runtime_id→View 映射、
##   改 gameplay state、激活 Crystal、推进 Tick、判断 drain、维护 RunState、解释事件（解释由 VisualController 完成）。
## 边界：所有 build_* 入参均为 detached 值（scheduler snapshot Dictionary / BatchEvent 原对象只读字段读取），
##   产出为每次新建的 Dictionary（值类型副本）；BatchEvent 原对象绝不进入返回 payload——逐字段拷贝进新建事件 Dictionary；
##   外部修改产出 payload 零影响 gameplay（payload 与 scheduler snapshot / _active_states 完全脱离）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ParticleStepExecutor: GDScript = preload(
	"res://gameplay/particle/particle_step_executor.gd"
)


# ===== 事件类型稳定字符串（供 VisualController 据此分支；不建复杂枚举） =====

## EMITTED 事件：一颗光粒成功发射。
const TYPE_EMITTED: String = "EMITTED"
## TICK_BATCH_COMMITTED 事件：一个整数 Tick 的 gameplay commit 完成。
const TYPE_TICK_BATCH_COMMITTED: String = "TICK_BATCH_COMMITTED"
## CLEARED 事件：R/reset 清空，visual 据此清全部 View。
const TYPE_CLEARED: String = "CLEARED"


# ===== outcome / termination_reason 稳定字符串（翻译自 ParticleStepExecutor 枚举，使 visual 层不依赖 gameplay 整型枚举） =====

const OUTCOME_MOVE: String = "MOVE"
const OUTCOME_TERMINATE: String = "TERMINATE"

const TERMINATION_NONE: String = "NONE"
const TERMINATION_INACTIVE: String = "INACTIVE"
const TERMINATION_OUT_OF_TERRAIN: String = "OUT_OF_TERRAIN"
const TERMINATION_WALL: String = "WALL"
const TERMINATION_MECHANISM_BLOCK: String = "MECHANISM_BLOCK"


# ===== CLEARED reason 最小稳定语义（spec：不为未来所有清理原因设计复杂枚举） =====

## R/reset 清理原因（本批唯一 reason 值）。
const REASON_RESET: String = "RESET"


# ===== EMITTED =====

## 由 scheduler detached snapshot 构造一次 EMITTED payload（数据来源唯一复用 snapshot，不重新读 raw state）。
## [br]输入：snapshot 为 ParticleScheduler.get_particle_state_snapshot(rid) 的 detached Dictionary（须含
##   runtime_id/generation/cell/direction/speed_tier/step_started_tick/next_move_tick 七字段）；
##   next_step_blocked 为 M4-E4 发射期确定性前瞻（发射格 + direction 是否墙 / 越界，由 LRC 经 world query 只读判定后传入；
##   本模块不读 world，bool 为纯值输入），默认 false——调用方不传时行为与既有合同完全一致。
## [br]返回：每次新建的 Dictionary，含 type=EMITTED + 上述七字段 + next_step_blocked（值类型副本）。
## [br]副作用：无；纯函数，不读实例字段、不写 gameplay、不持有 snapshot 引用（仅逐字段拷贝）。
## [br]边界：外部修改返回 Dictionary 零影响 snapshot 与真实 state；payload 不含 active 字段（视觉不关心活动性，活动性由 TICK 事件体现）。
static func build_emitted(snapshot: Dictionary, next_step_blocked: bool = false) -> Dictionary:
	return {
		"type": TYPE_EMITTED,
		"runtime_id": snapshot["runtime_id"],
		"generation": snapshot["generation"],
		"cell": snapshot["cell"],
		"direction": snapshot["direction"],
		"speed_tier": snapshot["speed_tier"],
		"step_started_tick": snapshot["step_started_tick"],
		"next_move_tick": snapshot["next_move_tick"],
		"next_step_blocked": next_step_blocked,
	}


# ===== TICK_BATCH_COMMITTED =====

## 由 scheduler 本 Tick 产出的 BatchEvent 数组构造一次 TICK_BATCH_COMMITTED payload。
## [br]输入：generation 为本 Tick 所属 generation；tick 为本 Tick 绝对整数；batch_events 为 scheduler.advance_one_tick
##   返回的有序 BatchEvent 数组（runtime_id 升序；可能为空）。
## [br]返回：每次新建的 Dictionary，含 type/generation/tick + events 数组；events 顺序严格保持 batch_events 的 runtime_id 冻结顺序；
##   每个 event 为 detached Dictionary（runtime_id/generation/outcome/from_cell/entered_cell/direction/speed_tier/has_crystal/termination_reason/next_move_tick）。
## [br]副作用：无；纯函数；逐条把 BatchEvent 原对象字段拷贝进新建 Dictionary，BatchEvent 原对象绝不进入 payload。
## [br]边界：batch_events 为空时返回 events=[] 的 payload（仍发出事件，由 VisualController 自然 no-op）；outcome/termination_reason
##   翻译为稳定字符串，visual 层无需依赖 gameplay 整型枚举；next_move_tick MOVE 时为 authoritative 下一传播步结束 Tick，TERMINATE 时为 0。
static func build_tick_committed(generation: int, tick: int, batch_events: Array) -> Dictionary:
	var detached_events: Array = []
	for event in batch_events:
		detached_events.append(_detach_batch_event(event))
	return {
		"type": TYPE_TICK_BATCH_COMMITTED,
		"generation": generation,
		"tick": tick,
		"events": detached_events,
	}


# ===== CLEARED =====

## 构造一次 CLEARED payload（R/reset 清空时发布；只用于 visual 清理，不改 scheduler/RunState）。
## [br]输入：old_generation 为清空前 generation；new_generation 为清空后 generation；reason 为最小稳定语义（默认 RESET）。
## [br]返回：每次新建的 Dictionary，含 type/old_generation/new_generation/reason。
## [br]副作用：无；纯函数。
## [br]边界：reason 本批只需最小稳定语义（RESET），不为未来所有清理原因设计复杂枚举。
static func build_cleared(
		old_generation: int,
		new_generation: int,
		reason: String = REASON_RESET
) -> Dictionary:
	return {
		"type": TYPE_CLEARED,
		"old_generation": old_generation,
		"new_generation": new_generation,
		"reason": reason,
	}


# ===== 内部：BatchEvent 原对象 → detached 事件 Dictionary =====

## 把单个 BatchEvent 原对象的字段逐字段拷贝为 detached Dictionary（原对象绝不进入返回值）。
## outcome / termination_reason 翻译为稳定字符串；runtime_id 升序顺序由调用方 build_tick_committed 的遍历顺序保证。
## D7-4 B4b-1 MF-1：next_move_tick 逐字段拷贝——MOVE 时为 authoritative 下一传播步结束 Tick，TERMINATE 时为 0（不伪造）；
##   Visual 据此 + TICK envelope.tick 得 step duration，绝不自行重算 Tick（不依赖 gameplay 运动规则）。
## M4-E4：next_step_blocked 逐字段拷贝——MOVE 时为 executor 确定性前瞻（下一格墙 / 越界），TERMINATE 时为 false；
##   Visual 据此把本段插值截到两格边界并在接触时即时消失（不 Tween 到墙格中心）。
static func _detach_batch_event(event) -> Dictionary:
	return {
		"runtime_id": event.runtime_id,
		"generation": event.generation,
		"outcome": _outcome_to_string(event.outcome),
		"from_cell": event.from_cell,
		"entered_cell": event.entered_cell,
		"direction": event.direction,
		"speed_tier": event.speed_tier,
		"has_crystal": event.has_crystal,
		"termination_reason": _termination_reason_to_string(event.termination_reason),
		"next_move_tick": event.next_move_tick,
		"next_step_blocked": event.next_step_blocked,
	}


## Outcome 整型 → 稳定字符串（未知值安全映射为 TERMINATE，使 View 被移除，保守无残留）。
static func _outcome_to_string(outcome: int) -> String:
	if outcome == _ParticleStepExecutor.Outcome.MOVE:
		return OUTCOME_MOVE
	# TERMINATE 或任何未知值统一按 TERMINATE 处理（保守移除 View）。
	return OUTCOME_TERMINATE


## TerminationReason 整型 → 稳定字符串（未知值映射为 NONE）。
static func _termination_reason_to_string(reason: int) -> String:
	match reason:
		_ParticleStepExecutor.TerminationReason.NONE:
			return TERMINATION_NONE
		_ParticleStepExecutor.TerminationReason.INACTIVE:
			return TERMINATION_INACTIVE
		_ParticleStepExecutor.TerminationReason.OUT_OF_TERRAIN:
			return TERMINATION_OUT_OF_TERRAIN
		_ParticleStepExecutor.TerminationReason.WALL:
			return TERMINATION_WALL
		_ParticleStepExecutor.TerminationReason.MECHANISM_BLOCK:
			return TERMINATION_MECHANISM_BLOCK
		_:
			return TERMINATION_NONE
