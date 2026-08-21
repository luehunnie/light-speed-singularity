class_name ControlDispatcher
extends RefCounted

## Control Dispatcher（Guide §26.1 / §29-§32）与 Reset 集成（§33 / P1-2）。
## 批次管线（§29 冻结）：Events → resolve Connections → Commands → group by Target Stable ID
##   → dedupe → conflict resolution → Target Resolution → atomic commit → 收集新 Events → Batch N+1。
## Target 正式契约面（Definition 声明的运行期镜像，同光域 forms 镜像惯例）：
##   get_control_action_definitions() -> Array（ControlActionDefinition 实例；非空 = 具备 Target 能力）
##   get_control_runtime_state() -> Variant（当前 Typed Runtime State）
##   apply_control_action(action_id, params) -> ControlActionResult（纯计算，不自行提交、不递归调用 Dispatcher）
##   commit_control_runtime_state(state) -> bool（唯一提交写点）
##   get_output_event_ids() -> Array[StringName]（可选 Source 面；缺席 = 未声明任何可发事件）
##   reset_control_runtime_state()（可选 Reset Hook §33；缺席 = 无临时状态）
## 冲突语义（§30 冻结，Dispatcher 不硬编码机关对）：相同 Action ID + 相同 Params → duplicate；
##   显式互斥（动作声明）→ conflict；相同 Action ID + 不同 Params → conflict
##   （v1 裁定：全部动作按状态设置型处理，非状态型差异参数场景由真实冻结玩法倒逼再开放）。
## 运行期错误策略（§32）：invalid command → safe no-op → Diagnostic → 其它合法命令继续；
##   绝不 fallback 到 Node.name / NodePath / 坐标 / 同类型对象。
## 原子性（§29）：以 Target 组为单位——执行中任一 apply 失败则整组回滚到批次前状态。
## 级联安全（§31 Batch N→N+1）：深度上限 MAX_CASCADE_BATCHES，超限安全停止并记录 Diagnostic。
## Reset（§33）：本类只提供“遍历登记实例、调用可选 Hook”的集成入口；编排者仍是未来 LevelRuntimeHost。


const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _ControlConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)
const _ControlOutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)
const _ControlActionResult: GDScript = preload(
	"res://gameplay/control/control_action_result.gd"
)
const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)
const _ControlDispatchReport: GDScript = preload(
	"res://gameplay/control/dispatch/control_dispatch_report.gd"
)

## 级联批次深度上限（防事件环无限级联；超出按安全停止记录 Diagnostic）。
const MAX_CASCADE_BATCHES: int = 32

## 契约面入口名（正式契约面的一部分）。
const TARGET_FACE_ACTIONS: String = "get_control_action_definitions"
const TARGET_FACE_GET_STATE: String = "get_control_runtime_state"
const TARGET_FACE_APPLY: String = "apply_control_action"
const TARGET_FACE_COMMIT: String = "commit_control_runtime_state"
const SOURCE_FACE_EVENTS: String = "get_output_event_ids"
const RESET_FACE: String = "reset_control_runtime_state"

## no-op / 冲突 / 丢弃原因码（machine-readable Diagnostic）。
const REASON_TARGET_NOT_FOUND: StringName = &"target_not_found"
const REASON_TARGET_NO_CAPABILITY: StringName = &"target_no_capability"
const REASON_ACTION_UNKNOWN: StringName = &"action_unknown"
const REASON_ACTION_PARAMS_INVALID: StringName = &"action_params_invalid"
const REASON_APPLY_INVALID_RESULT: StringName = &"apply_invalid_result"
const REASON_MUTEX_DECLARED: StringName = &"mutex_declared"
const REASON_SAME_ACTION_DIFFERENT_PARAMS: StringName = &"same_action_different_params"
const REASON_EVENT_NOT_DECLARED: StringName = &"event_not_declared"


## 作者期连接集合（事件 → 连接解析的唯一来源；ControlConnectionSet）。
var _connection_set: Variant = null
## 正式对象索引（Target 稳定 ID → 实例解析的唯一来源；FormalObjectRegistry）。
var _object_registry: Variant = null


## 构造：注入连接集合与正式对象索引（二者均为正式真相，不做 Callable 旁路）。
func _init(connection_set: Variant, object_registry: Variant) -> void:
	_connection_set = connection_set
	_object_registry = object_registry


## 派发一批 Typed Output Events（§29 完整管线 + §31 级联循环）。
## [br]输入：events 为 Array[ControlOutputEvent]；非法成员按 no-op 事件丢弃并记录。
## [br]返回：ControlDispatchReport（detached 诊断报告）；本调用对非法输入安全，不中断其它合法命令。
func dispatch_events(events: Array) -> _ControlDispatchReport:
	var report: _ControlDispatchReport = _ControlDispatchReport.new()
	var incoming: Array = []
	for event: Variant in events:
		if event == null or not (event is _ControlOutputEvent):
			report.record_no_op("", &"", REASON_EVENT_NOT_DECLARED)
			continue
		incoming.append(event)
	var batch_index: int = 0
	while not incoming.is_empty():
		batch_index += 1
		if batch_index > MAX_CASCADE_BATCHES:
			report.cascade_capped = true
			break
		incoming = _dispatch_single_batch(incoming, report)
	report.batch_count = mini(batch_index, MAX_CASCADE_BATCHES)
	return report


## Reset 集成入口（§33 可选 Runtime State Reset Contract）：遍历登记实例，
## [br]对实现了 reset_control_runtime_state() 的对象调用其 Hook（只清理本实例临时状态）。
## [br]返回被 Reset 的实例数；无状态对象（未实现 Hook）按 §33 不强制。
func reset_control_targets() -> int:
	var reset_count: int = 0
	for stable_id: String in _all_registered_ids():
		var instance: Variant = _resolve_instance(stable_id)
		if instance == null or not (instance is Object) or not is_instance_valid(instance):
			continue
		if instance.has_method(RESET_FACE):
			instance.call(RESET_FACE)
			reset_count += 1
	return reset_count


## 单批次执行：解析 → 分组 → 去重 / 冲突 → 原子提交；返回级联收集的新事件。
func _dispatch_single_batch(events: Array, report: _ControlDispatchReport) -> Array:
	var commands_by_target: Dictionary = {}
	for event: Variant in events:
		var connections: Array = _connection_set.get_connections_for_event(
			event.source_stable_id, event.event_id
		)
		for connection: Variant in connections:
			if not commands_by_target.has(connection.target_stable_id):
				commands_by_target[connection.target_stable_id] = []
			(commands_by_target[connection.target_stable_id] as Array).append(connection)
	var cascade_events: Array = []
	for target_stable_id: String in _sorted_keys(commands_by_target):
		var connections: Array = commands_by_target[target_stable_id]
		_execute_target_group(target_stable_id, connections, cascade_events, report)
	return cascade_events


## 执行单个 Target 组（§29 组内管线 + §29 atomic commit / §32 运行期错误策略）。
func _execute_target_group(
		target_stable_id: String,
		connections: Array,
		cascade_events: Array,
		report: _ControlDispatchReport
) -> void:
	var instance: Variant = _resolve_instance(target_stable_id)
	if instance == null or not (instance is Object) or not is_instance_valid(instance):
		for connection: Variant in connections:
			report.record_no_op(target_stable_id, connection.action_id, REASON_TARGET_NOT_FOUND)
		return
	if not _has_target_capability(instance):
		for connection: Variant in connections:
			report.record_no_op(target_stable_id, connection.action_id, REASON_TARGET_NO_CAPABILITY)
		return
	var action_defs: Dictionary = _action_definitions_index(instance)
	var surviving: Array = []
	for connection: Variant in connections:
		var action_def: Variant = action_defs.get(connection.action_id, null)
		if action_def == null:
			report.record_no_op(target_stable_id, connection.action_id, REASON_ACTION_UNKNOWN)
			continue
		if not action_def.check_params(connection.params).is_empty():
			report.record_no_op(target_stable_id, connection.action_id, REASON_ACTION_PARAMS_INVALID)
			continue
		surviving.append(connection)
	if surviving.is_empty():
		return
	surviving.sort_custom(_command_order)
	var deduped: Array = _dedupe_commands(surviving)
	var conflict_reason: StringName = _detect_conflict(deduped, action_defs)
	if conflict_reason != &"":
		report.record_conflict(target_stable_id, _action_ids_of(deduped), conflict_reason)
		return
	_apply_atomically(instance, target_stable_id, deduped, cascade_events, report)


## 原子执行：逐步 apply（每步提交使下一步从最新候选态计算）；任一失败整组回滚批次前状态。
## [br]组内执行记录先缓冲，组成功才落入报告（回滚组不留下“已执行”诊断，与原子语义一致）。
func _apply_atomically(
		instance: Object,
		target_stable_id: String,
		commands: Array,
		cascade_events: Array,
		report: _ControlDispatchReport
) -> void:
	var pre_state: Variant = instance.call(TARGET_FACE_GET_STATE)
	var group_executed: Array = []
	for connection: Variant in commands:
		var result: Variant = instance.call(TARGET_FACE_APPLY, connection.action_id, connection.params)
		if result == null or not (result is _ControlActionResult) or not result.validate().is_empty():
			var rolled_back: bool = instance.call(TARGET_FACE_COMMIT, pre_state)
			report.record_no_op(
				target_stable_id, connection.action_id, REASON_APPLY_INVALID_RESULT
			)
			if not rolled_back:
				push_error("ControlDispatcher：%s 组回滚提交失败，状态可能残留。" % [target_stable_id])
			return
		var committed: bool = instance.call(TARGET_FACE_COMMIT, result.candidate_state)
		if not committed:
			instance.call(TARGET_FACE_COMMIT, pre_state)
			report.record_no_op(
				target_stable_id, connection.action_id, REASON_APPLY_INVALID_RESULT
			)
			return
		group_executed.append(connection)
		_collect_declared_events(instance, target_stable_id, result, cascade_events, report)
	for connection: Variant in group_executed:
		report.record_executed(target_stable_id, connection.action_id)


## 收集结果级联事件（§31）：事件 ID 须在目标 Source 面声明内，未声明事件丢弃并记录。
func _collect_declared_events(
		instance: Object,
		target_stable_id: String,
		result: Variant,
		cascade_events: Array,
		report: _ControlDispatchReport
) -> void:
	var declared: Dictionary = {}
	if instance.has_method(SOURCE_FACE_EVENTS):
		for event_id: Variant in instance.call(SOURCE_FACE_EVENTS):
			declared[event_id] = true
	for event: Variant in result.output_events:
		if event == null or not (event is _ControlOutputEvent):
			report.record_dropped_event(target_stable_id, &"", REASON_EVENT_NOT_DECLARED)
			continue
		if not declared.has(event.event_id):
			report.record_dropped_event(
				target_stable_id, event.event_id, REASON_EVENT_NOT_DECLARED
			)
			continue
		cascade_events.append(event)


## Target 能力判定：四个必备契约面齐备（Source / Reset 面可选）。
func _has_target_capability(instance: Object) -> bool:
	return (
		instance.has_method(TARGET_FACE_ACTIONS)
		and instance.has_method(TARGET_FACE_GET_STATE)
		and instance.has_method(TARGET_FACE_APPLY)
		and instance.has_method(TARGET_FACE_COMMIT)
	)


## 目标动作声明索引：action_id → ControlActionDefinition。
func _action_definitions_index(instance: Object) -> Dictionary:
	var index: Dictionary = {}
	for definition: Variant in instance.call(TARGET_FACE_ACTIONS):
		if definition is _ControlActionDefinition:
			index[definition.action_id] = definition
	return index


## 组内命令确定性排序（§29：结果不得依赖遍历顺序）。
static func _command_order(a: Variant, b: Variant) -> bool:
	var key_a: String = "%s|%s|%s" % [a.action_id, a.get_params_key(), a.source_stable_id]
	var key_b: String = "%s|%s|%s" % [b.action_id, b.get_params_key(), b.source_stable_id]
	return key_a < key_b


## 去重（§29 duplicate）：相同 action_id + 相同 params 只保留一个（首个，经确定性排序）。
func _dedupe_commands(commands: Array) -> Array:
	var seen: Dictionary = {}
	var deduped: Array = []
	for connection: Variant in commands:
		var identity: String = "%s|%s" % [connection.action_id, connection.get_params_key()]
		if seen.has(identity):
			continue
		seen[identity] = true
		deduped.append(connection)
	return deduped


## 冲突检测（§30）：显式互斥 / 同 Action 不同 Params；返回原因码（空 = 无冲突）。
func _detect_conflict(commands: Array, action_defs: Dictionary) -> StringName:
	var by_action: Dictionary = {}
	for connection: Variant in commands:
		if not by_action.has(connection.action_id):
			by_action[connection.action_id] = []
		(by_action[connection.action_id] as Array).append(connection)
	for action_id: StringName in by_action.keys():
		var group: Array = by_action[action_id]
		if group.size() > 1:
			for other: Variant in group:
				if not _ControlActionDefinition.params_equal(
					other.params, (group[0] as Variant).params
				):
					return REASON_SAME_ACTION_DIFFERENT_PARAMS
	for action_id: StringName in by_action.keys():
		var definition: Variant = action_defs.get(action_id, null)
		if definition == null:
			continue
		for mutex_id: StringName in definition.mutually_exclusive_with:
			if mutex_id != action_id and by_action.has(mutex_id):
				return REASON_MUTEX_DECLARED
	return &""


## 稳定 ID → 登记实例（经 FormalObjectRegistry 唯一通道；不做任何 fallback 解析）。
func _resolve_instance(stable_id: String) -> Variant:
	if not _object_registry.has_object(stable_id):
		return null
	return _object_registry.get_object_snapshot(stable_id)["instance"]


## 全部登记稳定 ID（预置 + 动态；Reset 遍历用）。
func _all_registered_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.append_array(
		_object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_PREPLACED)
	)
	ids.append_array(
		_object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_SPAWNED)
	)
	return ids


## 组内出现的动作 ID 集合（确定性排序）。
func _action_ids_of(commands: Array) -> Array[StringName]:
	var ids: Array[StringName] = []
	for connection: Variant in commands:
		if not ids.has(connection.action_id):
			ids.append(connection.action_id)
	return ids


## 字典键确定性排序副本。
static func _sorted_keys(source: Dictionary) -> Array:
	var keys: Array = source.keys()
	keys.sort()
	return keys
