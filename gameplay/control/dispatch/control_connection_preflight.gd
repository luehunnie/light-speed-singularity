class_name ControlConnectionPreflight
extends RefCounted

## 控制连接作者期 / Preflight 校验（Guide §32 Authoring ERROR 清单 + 控制图非法成环）。
## 只读、无玩法副作用、不修改连接集合与注册表（§35 Rule Provider 边界）；
## 返回 machine-readable issue（稳定 code + 说明 + 定位信息），供 Validator / Authoring 消费
##   （AF-05 交付元数据与校验入口；并入场景级 LevelValidator 属 AF-06 Validator 阶段）。
## ERROR 清单（§32 冻结）：Target 稳定 ID 不存在 / 无 Control Target 能力 / Action ID 不存在 /
##   Params 不符 Schema / Self-target / 控制图非法成环 / 指向不允许作为普通 Target 的动态 Spawn。
## 运行期损坏数据的 safe no-op 策略由 ControlDispatcher 承担（§32 Runtime），不在本类。


const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _ControlConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)
const _ControlDispatcher: GDScript = preload(
	"res://gameplay/control/dispatch/control_dispatcher.gd"
)
const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)

## 稳定问题码（machine-readable）。
const CODE_TARGET_NOT_FOUND: StringName = &"control_target_not_found"
const CODE_TARGET_DYNAMIC_SPAWN: StringName = &"control_target_dynamic_spawn"
const CODE_TARGET_NO_CAPABILITY: StringName = &"control_target_no_capability"
const CODE_ACTION_UNKNOWN: StringName = &"control_action_unknown"
const CODE_ACTION_PARAMS_INVALID: StringName = &"control_action_params_invalid"
const CODE_SELF_TARGET: StringName = &"control_connection_self_target"
const CODE_EVENT_NOT_DECLARED: StringName = &"control_event_not_declared"
const CODE_GRAPH_CYCLE: StringName = &"control_connection_cycle"

## issue 字典固定键（detached，供上层 Go To / 归类）。
const K_CODE: String = "code"
const K_MESSAGE: String = "message"
const K_CONNECTION_INDEX: String = "connection_index"
const K_SOURCE_STABLE_ID: String = "source_stable_id"
const K_TARGET_STABLE_ID: String = "target_stable_id"


## 校验整份连接集合（§32 Authoring 全域 + 成环检测）。
## [br]输入：connection_set 为 ControlConnectionSet；object_registry 为 FormalObjectRegistry（目标存在性 /
##   来源域 / 实例解析的唯一真相）。
## [br]返回：issue 字典数组（确定性排序：code → connection_index）；空数组 = 全部通过。
static func validate(connection_set: Variant, object_registry: Variant) -> Array:
	var issues: Array = []
	var connections: Array = connection_set.get_all_connections()
	for index: int in connections.size():
		_validate_connection(
			connections[index], index, object_registry, issues
		)
	_validate_graph_cycle(connection_set, issues)
	issues.sort_custom(_issue_order)
	return issues


## 单条连接校验（不含成环；成环是图级属性）。
static func _validate_connection(
		connection: Variant,
		index: int,
		object_registry: Variant,
		issues: Array
) -> void:
	if connection.source_stable_id == connection.target_stable_id:
		issues.append(_issue(
			CODE_SELF_TARGET,
			"连接 %d Self-target：Source 与 Target 为同一稳定 ID（%s）。" % [index, connection.target_stable_id],
			index, connection
		))
	if not object_registry.has_object(connection.target_stable_id):
		issues.append(_issue(
			CODE_TARGET_NOT_FOUND,
			"连接 %d 目标稳定 ID 不存在：%s。" % [index, connection.target_stable_id],
			index, connection
		))
		return
	var snapshot: Dictionary = object_registry.get_object_snapshot(connection.target_stable_id)
	if snapshot["origin"] == _FormalObjectRegistry.ORIGIN_SPAWNED:
		issues.append(_issue(
			CODE_TARGET_DYNAMIC_SPAWN,
			"连接 %d 目标为动态 Spawn 对象，不允许作为普通 Target：%s。" % [index, connection.target_stable_id],
			index, connection
		))
	var instance: Variant = snapshot["instance"]
	if instance == null or not (instance is Object) or not is_instance_valid(instance):
		issues.append(_issue(
			CODE_TARGET_NO_CAPABILITY,
			"连接 %d 目标实例不可解析，无法判定 Control Target 能力：%s。" % [index, connection.target_stable_id],
			index, connection
		))
		return
	if not _has_target_capability(instance):
		issues.append(_issue(
			CODE_TARGET_NO_CAPABILITY,
			"连接 %d 目标不具备 Control Target 能力（契约面缺失）：%s。" % [index, connection.target_stable_id],
			index, connection
		))
		return
	var action_def: Variant = _find_action_definition(instance, connection.action_id)
	if action_def == null:
		issues.append(_issue(
			CODE_ACTION_UNKNOWN,
			"连接 %d 动作 ID 未被目标声明：%s。" % [index, connection.action_id],
			index, connection
		))
		return
	if not action_def.check_params(connection.params).is_empty():
		issues.append(_issue(
			CODE_ACTION_PARAMS_INVALID,
			"连接 %d 参数不符合动作 %s 的 schema。" % [index, connection.action_id],
			index, connection
		))
	_check_source_event_declaration(connection, index, object_registry, issues)


## 事件订阅声明校验：Source 实例提供 get_output_event_ids() 声明面时，事件 ID 须在其中。
static func _check_source_event_declaration(
		connection: Variant,
		index: int,
		object_registry: Variant,
		issues: Array
) -> void:
	if not object_registry.has_object(connection.source_stable_id):
		return
	var snapshot: Dictionary = object_registry.get_object_snapshot(connection.source_stable_id)
	var instance: Variant = snapshot["instance"]
	if instance == null or not (instance is Object) or not is_instance_valid(instance):
		return
	if not instance.has_method(_ControlDispatcher.SOURCE_FACE_EVENTS):
		return
	var declared: Array = instance.call(_ControlDispatcher.SOURCE_FACE_EVENTS)
	if not declared.has(connection.event_id):
		issues.append(_issue(
			CODE_EVENT_NOT_DECLARED,
			"连接 %d 事件 ID 未被 Source 声明：%s。" % [index, connection.event_id],
			index, connection
		))


## 图级成环检测：Source → Target 有向边存在环即 ERROR（连接级 Self-target 已单独报告）。
static func _validate_graph_cycle(connection_set: Variant, issues: Array) -> void:
	var edges: Dictionary = {}
	for connection: Variant in connection_set.get_all_connections():
		if not edges.has(connection.source_stable_id):
			edges[connection.source_stable_id] = {}
		(edges[connection.source_stable_id] as Dictionary)[connection.target_stable_id] = true
	var state: Dictionary = {}
	var stack: Array = []
	for node: String in edges.keys():
		if state.get(node, 0) != 0:
			continue
		var cycle: Array = _dfs_find_cycle(node, edges, state, stack)
		if not cycle.is_empty():
			issues.append(_issue(
				CODE_GRAPH_CYCLE,
				"控制图非法成环：%s。" % [" → ".join(cycle)],
				-1, null
			))
			return


## 染色 DFS 扔回路上的一个环（无环返回空数组）；0=未访问 1=栈上 2=完成。
static func _dfs_find_cycle(node: String, edges: Dictionary, state: Dictionary, stack: Array) -> Array:
	state[node] = 1
	stack.append(node)
	for neighbor: String in (edges.get(node, {}) as Dictionary).keys():
		var neighbor_state: int = state.get(neighbor, 0)
		if neighbor_state == 1:
			return _cycle_from_stack(stack, neighbor)
		if neighbor_state == 0 and edges.has(neighbor):
			var cycle: Array = _dfs_find_cycle(neighbor, edges, state, stack)
			if not cycle.is_empty():
				return cycle
	state[node] = 2
	stack.pop_back()
	return []


## 从 DFS 栈截取自 neighbor 起的环路径。
static func _cycle_from_stack(stack: Array, neighbor: String) -> Array:
	var path: Array = []
	var found: bool = false
	for node: String in stack:
		if node == neighbor:
			found = true
		if found:
			path.append(node)
	path.append(neighbor)
	return path


## 目标能力判定（与 Dispatcher 同一契约面口径）。
static func _has_target_capability(instance: Object) -> bool:
	return (
		instance.has_method(_ControlDispatcher.TARGET_FACE_ACTIONS)
		and instance.has_method(_ControlDispatcher.TARGET_FACE_GET_STATE)
		and instance.has_method(_ControlDispatcher.TARGET_FACE_APPLY)
		and instance.has_method(_ControlDispatcher.TARGET_FACE_COMMIT)
	)


## 在目标实例声明面中查找动作定义（非 ControlActionDefinition 成员一律忽略）。
static func _find_action_definition(instance: Object, action_id: StringName) -> Variant:
	for definition: Variant in instance.call(_ControlDispatcher.TARGET_FACE_ACTIONS):
		if definition is _ControlActionDefinition and definition.action_id == action_id:
			return definition
	return null


## 组装一条 detached issue。
static func _issue(code: StringName, message: String, index: int, connection: Variant) -> Dictionary:
	return {
		K_CODE: code,
		K_MESSAGE: message,
		K_CONNECTION_INDEX: index,
		K_SOURCE_STABLE_ID: connection.source_stable_id if connection != null else "",
		K_TARGET_STABLE_ID: connection.target_stable_id if connection != null else "",
	}


## issue 确定性排序（code → connection_index → message）。
static func _issue_order(a: Dictionary, b: Dictionary) -> bool:
	var key_a: String = "%s|%03d|%s" % [a[K_CODE], a[K_CONNECTION_INDEX], a[K_MESSAGE]]
	var key_b: String = "%s|%03d|%s" % [b[K_CODE], b[K_CONNECTION_INDEX], b[K_MESSAGE]]
	return key_a < key_b
