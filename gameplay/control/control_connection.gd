class_name ControlConnection
extends RefCounted

## Typed Connection Data（Guide §26.1 / §26.3）：Source 稳定 ID + 稳定 event_id
##   → Target 稳定 ID + 稳定 action_id + 作者期固定 Typed Params。
## 冻结边界：不做 Event payload → Action param 映射、不做数据转换、不开放任意 runtime JSON；
##   params 值域与键集以 ControlActionDefinition 的 schema 为唯一合法域。
## 身份不使用 Node.name / NodePath / 坐标（§32）；Self-target / 成环 / 动态 Spawn 目标
##   等作者期非法性由 ControlConnectionPreflight 判定，本类只做结构合法性。


const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)


## Source 实例稳定 ID（非空）。
var source_stable_id: String = ""

## 订阅的稳定事件 ID（非空 StringName）。
var event_id: StringName = &""

## Target 实例稳定 ID（非空）。
var target_stable_id: String = ""

## 触发的稳定动作 ID（非空 StringName）。
var action_id: StringName = &""

## 作者期固定参数（键为非空 StringName，值只允许 bool / int）。
var params: Dictionary = {}


## 构造合法连接；结构非法返回 null 并 push_error（fail-fast，零副作用）。
## [br]注意：本入口不校验 params 是否匹配目标动作 schema（那需要动作声明，见 validate_against_action）。
static func create(
		source_stable_id: String,
		event_id: StringName,
		target_stable_id: String,
		action_id: StringName,
		params: Dictionary
) -> ControlConnection:
	var connection: ControlConnection = ControlConnection.new()
	connection.source_stable_id = source_stable_id
	connection.event_id = event_id
	connection.target_stable_id = target_stable_id
	connection.action_id = action_id
	connection.params = params
	var problems: PackedStringArray = connection._validate_structure()
	if not problems.is_empty():
		push_error("ControlConnection：非法构造——%s。" % ["；".join(problems)])
		return null
	return connection


## 结构合法性：四段 ID 非空、params 键为非空 StringName 且值只允许 bool / int。
func _validate_structure() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if source_stable_id.is_empty():
		problems.append("source_stable_id 不能为空。")
	if event_id == &"":
		problems.append("event_id 不能为空。")
	if target_stable_id.is_empty():
		problems.append("target_stable_id 不能为空。")
	if action_id == &"":
		problems.append("action_id 不能为空。")
	for key: Variant in params.keys():
		if not (key is StringName) or key == &"":
			problems.append("params 含非法键（须为非空 StringName）：%s。" % [key])
			continue
		var value: Variant = params[key]
		if not (value is bool or value is int):
			problems.append("参数 %s 的值只允许 bool / int（实际为非法类型）。" % [key])
	return problems


## 校验 params 是否匹配目标动作 schema（键集一致、值类型匹配）。
## [br]输入：action_def 为 ControlActionDefinition（或其 preloaded 脚本实例）。
## [br]返回：问题清单（空 = 匹配）；不修改本连接。
func validate_against_action(action_def: Variant) -> PackedStringArray:
	if not (action_def is _ControlActionDefinition):
		return PackedStringArray(["action_def 须为 ControlActionDefinition。"])
	return action_def.check_params(params)


## params 确定性排序键（结构校验通过后使用；委托 ControlActionDefinition 冻结算法）。
func get_params_key() -> String:
	return _ControlActionDefinition.canonical_params_key(params)
