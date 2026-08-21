class_name ControlDispatchReport
extends RefCounted

## ControlDispatchReport（Guide §29 / §31 / §32）：一次派发的 detached 诊断报告。
## 由 ControlDispatcher 构造填写，外部只读；承载执行 / 冲突 / 安全 no-op / 丢弃事件
## 与级联截断事实，全部为 machine-readable 字典条目（稳定键 + 原因码）。
## 值对象边界：不持有 Node / Registry / Dispatcher 引用，可跨层安全传递。


## 实际执行的命令清单（{target_stable_id, action_id}；回滚组不落记录）。
var executed: Array = []

## 冲突清单（{target_stable_id, action_ids, reason}；冲突组全部不执行，目标保持批次前状态，§29）。
var conflicts: Array = []

## 安全 no-op 清单（{target_stable_id, action_id, reason}；§32 Runtime 错误策略）。
var no_ops: Array = []

## 被丢弃的级联事件清单（{source_stable_id, event_id, reason}；§31 未声明事件不得偷偷返回）。
var dropped_events: Array = []

## 级联是否触达深度上限被安全截断。
var cascade_capped: bool = false

## 级联批次数（含首批）。
var batch_count: int = 0


## 记录一条执行。
func record_executed(target_stable_id: String, action_id: StringName) -> void:
	executed.append({"target_stable_id": target_stable_id, "action_id": action_id})


## 记录一条冲突（action_ids 为冲突组动作 ID 集合）。
func record_conflict(target_stable_id: String, action_ids: Array, reason: StringName) -> void:
	conflicts.append({
		"target_stable_id": target_stable_id,
		"action_ids": action_ids,
		"reason": reason,
	})


## 记录一条安全 no-op。
func record_no_op(target_stable_id: String, action_id: StringName, reason: StringName) -> void:
	no_ops.append({
		"target_stable_id": target_stable_id,
		"action_id": action_id,
		"reason": reason,
	})


## 记录一条被丢弃的级联事件。
func record_dropped_event(source_stable_id: String, event_id: StringName, reason: StringName) -> void:
	dropped_events.append({
		"source_stable_id": source_stable_id,
		"event_id": event_id,
		"reason": reason,
	})
