class_name ControlConnectionSet
extends RefCounted

## 控制连接集合（Guide §26.1）：Dispatcher 与 Preflight 共用的作者期连接索引。
## 只做收集 / 去重 / 事件到连接的只读检索，不理解事件与动作语义；
## 连接的作者期非法性（目标不存在 / 无能力 / Self-target / 成环等）由 Preflight 判定。


## 已收录连接（登记序）。
var _connections: Array = []

## (source_stable_id, event_id) → Array[ControlConnection] 索引。
var _by_event: Dictionary = {}


## 收录一条连接：结构非法（null）或与既有连接五元组完全重复时拒绝。
## [br]返回是否收录成功；拒绝时 push_error，零索引污染。
func add_connection(connection: Variant) -> bool:
	if connection == null or not (connection is ControlConnection):
		push_error("ControlConnectionSet：拒绝非 ControlConnection 条目。")
		return false
	if _find_duplicate(connection) != null:
		push_error(
			"ControlConnectionSet：拒绝重复连接（%s / %s → %s / %s / %s）。" % [
				connection.source_stable_id,
				connection.event_id,
				connection.target_stable_id,
				connection.action_id,
				connection.get_params_key(),
			]
		)
		return false
	_connections.append(connection)
	var index_key: String = _event_key(connection.source_stable_id, connection.event_id)
	if not _by_event.has(index_key):
		_by_event[index_key] = []
	(_by_event[index_key] as Array).append(connection)
	return true


## 取某来源实例某事件订阅的全部连接副本（登记序；无订阅返回空）。
## [br]Dispatcher 事件解析入口：Source 不解析 Target，解析只发生在此处之后的批次管线。
func get_connections_for_event(source_stable_id: String, event_id: StringName) -> Array:
	var bucket: Variant = _by_event.get(_event_key(source_stable_id, event_id), null)
	if bucket == null:
		return []
	return (bucket as Array).duplicate()


## 全部连接副本（登记序）。
func get_all_connections() -> Array:
	return _connections.duplicate()


## 已收录连接数。
func get_count() -> int:
	return _connections.size()


## 事件索引键。
static func _event_key(source_stable_id: String, event_id: StringName) -> String:
	return "%s|%s" % [source_stable_id, event_id]


## 找与候选连接五元组完全一致的既有连接（未重复返回 null）。
func _find_duplicate(connection: ControlConnection) -> Variant:
	for existing: ControlConnection in _connections:
		if (
			existing.source_stable_id == connection.source_stable_id
			and existing.event_id == connection.event_id
			and existing.target_stable_id == connection.target_stable_id
			and existing.action_id == connection.action_id
			and existing.get_params_key() == connection.get_params_key()
		):
			return existing
	return null
