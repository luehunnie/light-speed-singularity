class_name MechanismConfiguration
extends RefCounted

## 机关 Typed Configuration 存储（AF-03 / P0-4，Guide §11）：按 MechanismFieldDefinition Schema
## 约束的字段 ID → 类型化值存储，公共系统不得把它退化成自由 Dictionary 使用。
## 配置三层（Guide 11.2）：Type Default（from_type_defaults）→ Preplaced Instance Override（apply_override）→
## Runtime State（活跃节点自身状态，不在本类存储）；Inventory Spawn 只使用 Type Default，
## 关卡 Inventory Entry 不允许私自覆盖 Spawn 初始配置（由 LevelInventoryEntry 形状本身保证）。
## 未知字段、类型不符或枚举越界的写入一律整体拒绝且零变更；内部 Dictionary 只经 Schema 校验路径写入。


## 字段 Schema 声明类型；preload 引用避开新 class_name 的全局缓存陈旧问题（先例：mechanism_definition.gd）。
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)


## 字段 ID → 类型化值（仅经 _set_checked 写入，键域受构造 Schema 约束）。
var _values_by_field_id: Dictionary[StringName, Variant] = {}
## 构造时的 Schema 字段清单（持有引用，不复制；Definition 侧为唯一来源）。
var _fields: Array = []


## 按 Schema 构造 Type Default 配置（Guide 11.2 第一层）；任一字段默认值非法则返回 null。
## [br]fields 为 MechanismFieldDefinition 数组；含重复 field_id 时拒绝（返回 null）。
static func from_type_defaults(fields: Array) -> MechanismConfiguration:
	var configuration := MechanismConfiguration.new()
	if not configuration._adopt_schema(fields):
		return null
	for field: Variant in fields:
		var field_definition: _MechanismFieldDefinition = field as _MechanismFieldDefinition
		configuration._values_by_field_id[field_definition.field_id] = field_definition.default_value
	return configuration


## 构造一份空 Schema 配置（仅供内部克隆路径与测试构造；正式配置一律经 from_type_defaults）。
func _init() -> void:
	pass


## 应用一层 Instance Override（Guide 11.2 第二层）：字段未知 / 类型不符 / 枚举越界时返回 false 且零变更。
## [br]成功时写入类型化值并返回 true；本方法不区分“覆盖默认”与“改写实例”，统一走 Schema 校验。
func apply_override(field_id: StringName, value: Variant) -> bool:
	var field_definition := _find_field(field_id)
	if field_definition == null:
		push_error("MechanismConfiguration: 未知字段 %s，拒绝写入。" % [field_id])
		return false
	if not field_definition.is_valid_value(value):
		push_error("MechanismConfiguration: 字段 %s 的值 %s 违反类型/枚举界，拒绝写入。" % [field_id, str(value)])
		return false
	_values_by_field_id[field_id] = value
	return true


## 读取字段值（只读；未知字段返回 null 且不报错，调用方按需判空）。
func get_value(field_id: StringName) -> Variant:
	return _values_by_field_id.get(field_id, null)


## 字段是否存在。
func has_field(field_id: StringName) -> bool:
	return _values_by_field_id.has(field_id)


## 全部字段 ID 快照（Schema 声明序）。
func get_field_ids() -> Array[StringName]:
	var field_ids: Array[StringName] = []
	for field: Variant in _fields:
		field_ids.append((field as _MechanismFieldDefinition).field_id)
	return field_ids


## detached 只读快照（field_id → 值）；返回副本，篡改不影响本配置。
func snapshot() -> Dictionary:
	return _values_by_field_id.duplicate()


## 深拷贝一份同 Schema 同值的配置（候选提案的基底；内部值均为值类型，浅复制即可）。
func duplicate_configuration() -> MechanismConfiguration:
	var copy := MechanismConfiguration.new()
	copy._fields = _fields
	copy._values_by_field_id = _values_by_field_id.duplicate()
	return copy


## 是否与本配置逐字段相等（同字段集且值相等；Schema 引用相同性不参与）。
func is_equal_to(other: MechanismConfiguration) -> bool:
	if other == null or _values_by_field_id.size() != other._values_by_field_id.size():
		return false
	for field_id: StringName in _values_by_field_id:
		if not other._values_by_field_id.has(field_id):
			return false
		if _values_by_field_id[field_id] != other._values_by_field_id[field_id]:
			return false
	return true


## 采纳 Schema：成员须为 MechanismFieldDefinition 且 field_id 无重复；失败返回 false。
func _adopt_schema(fields: Array) -> bool:
	var seen: Dictionary = {}
	for field: Variant in fields:
		if not (field is _MechanismFieldDefinition):
			push_error("MechanismConfiguration: Schema 含非 MechanismFieldDefinition 成员，拒绝构造。")
			return false
		var field_definition: _MechanismFieldDefinition = field as _MechanismFieldDefinition
		if field_definition.field_id == &"":
			push_error("MechanismConfiguration: Schema 含空 field_id，拒绝构造。")
			return false
		if seen.has(field_definition.field_id):
			push_error("MechanismConfiguration: Schema 含重复 field_id：%s。" % [field_definition.field_id])
			return false
		seen[field_definition.field_id] = true
	_fields = fields
	return true


## 按 ID 查 Schema 字段；未声明返回 null。
func _find_field(field_id: StringName) -> _MechanismFieldDefinition:
	for field: Variant in _fields:
		var field_definition: _MechanismFieldDefinition = field as _MechanismFieldDefinition
		if field_definition.field_id == field_id:
			return field_definition
	return null
