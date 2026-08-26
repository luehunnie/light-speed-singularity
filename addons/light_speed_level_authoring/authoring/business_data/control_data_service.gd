@tool
extends RefCounted

# AF-09 Control Connection 业务数据服务（Guide §26 / §32）：连接的读 / 校验 / 声明枚举。
# 数据形状：control_connections = [{source_stable_id, event_id, target_stable_id, action_id: String,
# params: {String → bool|int}}]（字典键 String，运行期接线边界再转 StringName，FROZEN_DEFERRED）。
# 只提供声明过的 Event / Action（MechanismDefinition.control_output_events / control_actions 枚举）；
# 结构校验与运行时 ControlConnection / ControlConnectionSet 语义同构（五元组去重、params 值域
# bool/int、schema 键集与类型一致），作者期非法（Self-target / 成环等）留 Preflight 运行域。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)

# meta 键（与 BusinessDataService.apply_id_remap 消费口径一致）。
const META_CONNECTIONS: String = "control_connections"


# 读连接列表（detached）。
static func read_connections(root: Node) -> Array:
	return _BusinessData.read_meta(root, META_CONNECTIONS, []) as Array


# 某类型的已声明输出事件选项（[{event_id, display_name}]；未声明返回空）。
static func get_event_options(type_id: StringName, registry) -> Array[Dictionary]:
	return _collect_declarations(type_id, registry, "control_output_events", "event_id")


# 某类型的已声明动作选项（[{action_id, display_name, param_schema}]；param_schema 原样 detached）。
static func get_action_options(type_id: StringName, registry) -> Array[Dictionary]:
	return _collect_declarations(type_id, registry, "control_actions", "action_id")


# 校验连接列表（结构四段非空 / 对象存在 / 事件与动作已由对端定义声明 / params 匹配 schema / 五元组去重）。
static func validate_connections(connections: Array, object_index: Array[Dictionary], registry) -> PackedStringArray:
	var problems := PackedStringArray()
	var by_id := {}
	for entry: Dictionary in object_index:
		by_id[entry.stable_id] = entry
	var seen_keys: Array[String] = []
	for index: int in connections.size():
		var connection: Dictionary = connections[index]
		var source_id := str(connection.get("source_stable_id", ""))
		var event_id := str(connection.get("event_id", ""))
		var target_id := str(connection.get("target_stable_id", ""))
		var action_id := str(connection.get("action_id", ""))
		if source_id.is_empty() or event_id.is_empty() or target_id.is_empty() or action_id.is_empty():
			problems.append("连接 %d：四段 ID（source/event/target/action）均不能为空。" % index)
			continue
		if not by_id.has(source_id):
			problems.append("连接 %d：Source %s 不是场景内正式对象。" % [index, source_id])
		if not by_id.has(target_id):
			problems.append("连接 %d：Target %s 不是场景内正式对象。" % [index, target_id])
			continue
		var params: Dictionary = connection.get("params", {})
		var params_problems := _validate_params(params)
		problems.append_array(params_problems)
		var event_ok := _is_declared(by_id, source_id, "control_output_events", "event_id", event_id, registry)
		if not event_ok:
			problems.append("连接 %d：Source %s 未声明事件 %s。" % [index, source_id, event_id])
		var action_entry: Variant = _find_action_declaration(by_id, target_id, action_id, registry)
		if action_entry == null:
			problems.append("连接 %d：Target %s 未声明动作 %s。" % [index, target_id, action_id])
		elif params_problems.is_empty():
			problems.append_array(_check_params_against_schema(index, action_entry, params))
		var key := "%s|%s|%s|%s|%s" % [source_id, event_id, target_id, action_id, _params_key(params)]
		if seen_keys.has(key):
			problems.append("连接 %d：与既有连接五元组完全重复。" % index)
		seen_keys.append(key)
	return problems


# params 结构域（键非空 String、值仅 bool/int；与 ControlConnection._validate_structure 同构）。
static func _validate_params(params: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key_variant: Variant in params.keys():
		var key := str(key_variant)
		if key.is_empty():
			problems.append("params 含空键。")
			continue
		var value: Variant = params[key_variant]
		if not (value is bool or value is int):
			problems.append("参数 %s 的值只允许 bool / int。" % key)
	return problems


# params 与动作 schema 比对（键集一致、类型匹配；委托 ControlActionDefinition.check_params 冻结算法）。
static func _check_params_against_schema(index: int, action_entry: Variant, params: Dictionary) -> PackedStringArray:
	var action_definition: Variant = action_entry
	var typed_params := {}
	for key_variant: Variant in params.keys():
		typed_params[StringName(str(key_variant))] = params[key_variant]
	var problems: PackedStringArray = action_definition.check_params(typed_params)
	if problems.is_empty():
		return problems
	var prefixed := PackedStringArray()
	for problem: String in problems:
		prefixed.append("连接 %d：%s" % [index, problem])
	return prefixed


# params 确定性排序键（与 ControlConnectionSet 去重口径一致）。
static func _params_key(params: Dictionary) -> String:
	var keys := params.keys()
	keys.sort()
	var parts: Array[String] = []
	for key: Variant in keys:
		parts.append("%s=%s" % [str(key), str(params[key])])
	return ",".join(parts)


# 枚举某类型定义域上的声明条目（detached；field = "event_id" / "action_id"）。
static func _collect_declarations(type_id: StringName, registry, domain_field: String, id_field: String) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if registry == null or type_id == &"":
		return options
	var definition: Variant = registry.get_definition(type_id)
	if definition == null:
		return options
	# 非 MechanismDefinition（发射器/目标域）无控制声明面：get 返回 null，视作空声明表。
	var declared: Variant = definition.get(domain_field)
	if declared == null:
		return options
	for entry_variant: Variant in declared:
		var entry: Variant = entry_variant
		var option := {"display_name": entry.display_name}
		option[id_field] = String(entry.get(id_field))
		if id_field == "action_id":
			option["param_schema"] = (entry.param_schema as Array).duplicate(true)
		options.append(option)
	return options


# 判断对端定义是否声明了某 id（事件或动作）。
static func _is_declared(by_id: Dictionary, object_id: String, domain_field: String,
		id_field: String, value: String, registry) -> bool:
	if not by_id.has(object_id):
		return false
	var type_id: StringName = by_id[object_id].type_id
	var definition: Variant = registry.get_definition(type_id) if registry != null else null
	if definition == null:
		return false
	var declared: Variant = definition.get(domain_field)
	if declared == null:
		return false
	for entry_variant: Variant in declared:
		if String((entry_variant as Object).get(id_field)) == value:
			return true
	return false


# 找目标对象定义上的动作声明（供 params schema 比对）。
static func _find_action_declaration(by_id: Dictionary, target_id: String, action_id: String, registry) -> Variant:
	if not by_id.has(target_id) or registry == null:
		return null
	var type_id: StringName = by_id[target_id].type_id
	var definition: Variant = registry.get_definition(type_id)
	if definition == null:
		return null
	var declared: Variant = definition.get("control_actions")
	if declared == null:
		return null
	for entry_variant: Variant in declared:
		if String((entry_variant as Object).get("action_id")) == action_id:
			return entry_variant
	return null
