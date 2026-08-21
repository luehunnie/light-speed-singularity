class_name ControlActionDefinition
extends Resource

## 控制动作稳定声明（Guide §26.2 / §30）：稳定 action_id + display_name + typed parameter schema
##   + 有限结构化 Conflict Semantics（显式互斥 Action 列表）。
## 冲突关系不是 Dispatcher 硬编码，也不是 Target 临时猜（§30 冻结）：互斥由本声明给出；
##   “相同 Action ID + 相同 Typed Params → duplicate / 不同 Params → conflict”为 Dispatcher
##   通用规则（v1 全部动作按状态设置型处理，见 ControlDispatcher 裁定注释）。
## 参数值域 v1 冻结为 BOOL / INT 两类标量；不开放任意 JSON / 表达式（AF-05 Frozen/Boundary）。


## 参数值类型 token（v1 冻结域）。
const VALUE_TYPE_BOOL: StringName = &"BOOL"
const VALUE_TYPE_INT: StringName = &"INT"

## param_schema 条目的固定键。
const _K_PARAM_ID: String = "param_id"
const _K_PARAM_TYPE: String = "value_type"


## 稳定动作 ID（非空 StringName；关卡数据身份）。
@export var action_id: StringName = &""

## 作者展示名（非空）。
@export var display_name: String = ""

## Typed parameter schema：Array[Dictionary]，每项 {param_id: StringName, value_type: BOOL|INT}。
## [br]空 schema = 无参动作；键集与值类型是运行期 Connection params 的唯一合法域。
@export var param_schema: Array = []

## 显式互斥 Action ID 列表（对称声明由校验提示；不自指、不重复）。
@export var mutually_exclusive_with: Array[StringName] = []


## 追加互斥动作声明（接受未类型化数组；StringName 成员逐一入列，供声明面构造使用）。
func add_mutually_exclusive(ids: Array) -> void:
	for id: Variant in ids:
		mutually_exclusive_with.append(id)


## 校验声明合法性：ID / 展示名非空、schema 条目结构合法且 param_id 唯一、互斥列表合法。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if action_id == &"":
		problems.append("action_id 不能为空。")
	if display_name.is_empty():
		problems.append("display_name 不能为空（动作 %s）。" % [action_id])
	problems.append_array(_validate_schema())
	problems.append_array(_validate_mutex())
	return problems


## 校验一份 params 是否恰好符合 schema（键集一致、值类型匹配）。
## [br]返回问题清单（空 = 接受）；params 键须为 StringName，值只允许 bool / int。
func check_params(params: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var schema_by_id := _schema_index()
	var extra: Array[StringName] = []
	for key: Variant in params.keys():
		if not (key is StringName) or key == &"":
			problems.append("params 含非法键（须为非空 StringName）：%s。" % [key])
			continue
		var param_id: StringName = key
		if not schema_by_id.has(param_id):
			extra.append(param_id)
			continue
		if not _value_type_ok(schema_by_id[param_id], params[param_id]):
			problems.append("参数 %s 值类型不符 schema（声明 %s）。" % [param_id, schema_by_id[param_id]])
	if not extra.is_empty():
		problems.append("params 含 schema 未声明参数：%s。" % [", ".join(extra)])
	for param_id: StringName in schema_by_id.keys():
		if not params.has(param_id):
			problems.append("params 缺少 schema 参数 %s。" % [param_id])
	return problems


## 取 schema 参数 ID 副本（声明序）。
func get_param_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for entry: Variant in param_schema:
		if entry is Dictionary:
			ids.append(entry.get(_K_PARAM_ID, &""))
	return ids


## params 的确定性排序键（去重 / 冲突判定用；不依赖字典遍历序）。
static func canonical_params_key(params: Dictionary) -> String:
	var keys: Array = []
	for key: Variant in params.keys():
		keys.append(String(key))
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for key_text: String in keys:
		var value: Variant = params[StringName(key_text)]
		parts.append("%s=%s" % [key_text, _value_token(value)])
	return ",".join(parts)


## 两份 params 是否等价（键集与值全等；确定性比较）。
static func params_equal(a: Dictionary, b: Dictionary) -> bool:
	return canonical_params_key(a) == canonical_params_key(b)


## 校验 schema 条目：结构 / 值类型 token / param_id 唯一。
func _validate_schema() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	for entry: Variant in param_schema:
		if not (entry is Dictionary):
			problems.append("param_schema 条目须为 Dictionary（动作 %s）。" % [action_id])
			continue
		var param_id: Variant = entry.get(_K_PARAM_ID, null)
		var value_type: Variant = entry.get(_K_PARAM_TYPE, null)
		if not (param_id is StringName) or param_id == &"":
			problems.append("param_schema 含非法 param_id（动作 %s）。" % [action_id])
			continue
		if seen.has(param_id):
			problems.append("param_schema 存在重复 param_id：%s（动作 %s）。" % [param_id, action_id])
			continue
		seen[param_id] = true
		if value_type != VALUE_TYPE_BOOL and value_type != VALUE_TYPE_INT:
			problems.append("参数 %s 值类型须为 BOOL / INT（动作 %s）。" % [param_id, action_id])
	return problems


## 校验互斥列表：非空 ID、不自指、不重复。
func _validate_mutex() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	for other: StringName in mutually_exclusive_with:
		if other == &"":
			problems.append("mutually_exclusive_with 含空 action_id（动作 %s）。" % [action_id])
			continue
		if other == action_id:
			problems.append("动作 %s 声明与自身互斥。" % [action_id])
			continue
		if seen.has(other):
			problems.append("mutually_exclusive_with 存在重复：%s（动作 %s）。" % [other, action_id])
			continue
		seen[other] = true
	return problems


## schema → {param_id: value_type} 索引。
func _schema_index() -> Dictionary:
	var index: Dictionary = {}
	for entry: Variant in param_schema:
		if entry is Dictionary:
			index[entry.get(_K_PARAM_ID, &"")] = entry.get(_K_PARAM_TYPE, &"")
	return index


## 值类型匹配（GDScript typeof：bool 与 int 严格区分，不做隐式转换）。
static func _value_type_ok(declared_type: StringName, value: Variant) -> bool:
	if declared_type == VALUE_TYPE_BOOL:
		return value is bool
	if declared_type == VALUE_TYPE_INT:
		return value is int
	return false


## 值的确定性 token（bool / int 之外的理论不可达值固定 "?"，保证比较仍确定）。
static func _value_token(value: Variant) -> String:
	if value is bool:
		return "b:%d" % [1 if value else 0]
	if value is int:
		return "i:%d" % [value]
	return "?"
