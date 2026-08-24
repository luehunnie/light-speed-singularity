class_name ObjectiveConditionDefinition
extends RefCounted

## 目标条件类型正式声明（冻结 Guide A §13.2 / Guide B §25.3，AF-04 / P0-6）。
## 每种条件类型必须正式声明：显示名 / 参数 / 枚举 / 验证 / 可作用目标类型；
## Objective Editor / Validator 不硬编码具体 Condition 名单，一律经本注册表枚举。
## 本批正式声明的条件类型：form_condition（FormCondition：命中光形态 ∈ 允许形态集合，
## 形态内多值即该条件自己的 OR 参数模型，不做通用逻辑表达式）。
## 空条件列表表示 Base Success（Guide A §13.1），Base Success 不是条件类型，不进注册表。
## 纯声明域：不进场景树、不 preload Runtime / WorldQuery；新增条件类型按 additive 扩展 _DECLARED。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

## 条件类型稳定 ID：FormCondition（命中光形态条件）。
const TYPE_FORM_CONDITION: StringName = &"form_condition"
## form_condition 参数模型：allowed_forms——允许的命中光形态集合（LightForm 值，非空，多值 OR）。
const PARAM_ALLOWED_FORMS: StringName = &"allowed_forms"


## 已正式声明的条件类型（稳定 ID 有序表；Editor/Validator 枚举唯一入口，不硬编码名单）。
const _DECLARED_TYPE_IDS: Array[StringName] = [
	TYPE_FORM_CONDITION,
]


## 条件类型稳定 ID（正式身份，不随显示名重构变化）。
var _condition_type_id: StringName
## 显示名（Editor 展示用）。
var _display_name: String
## 可作用目标内容域（目标 Definition 的 get_content_domain 集合；空表示不限）。
var _applicable_target_domains: Array[StringName]
## 参数说明（稳定参数 ID → 人读描述；枚举域与验证入口见 ObjectiveConditionConfiguration）。
var _param_ids: Array[StringName]


## 构造（仅静态注册入口使用；外部不得 new）。
func _init(condition_type_id: StringName, display_name: String, applicable_target_domains: Array[StringName], param_ids: Array[StringName]) -> void:
	_condition_type_id = condition_type_id
	_display_name = display_name
	_applicable_target_domains = applicable_target_domains.duplicate()
	_param_ids = param_ids.duplicate()


## 枚举全部已正式声明的条件类型定义（detached 副本，调用方修改不影响注册表）。
static func get_all_declared() -> Array:
	var definitions: Array = []
	for type_id: StringName in _DECLARED_TYPE_IDS:
		var definition: ObjectiveConditionDefinition = get_by_type_id(type_id)
		if definition != null:
			definitions.append(definition)
	return definitions


## 按稳定 ID 查找条件类型定义；未声明返回 null（Editor/Validator 据此拒绝未知类型，不硬编码名单）。
static func get_by_type_id(condition_type_id: StringName) -> ObjectiveConditionDefinition:
	match condition_type_id:
		TYPE_FORM_CONDITION:
			var domains: Array[StringName] = []
			domains.append(&"objective_target")
			var params: Array[StringName] = []
			params.append(PARAM_ALLOWED_FORMS)
			return ObjectiveConditionDefinition.new(TYPE_FORM_CONDITION, "光形态条件", domains, params)
		_:
			return null


## 条件类型稳定 ID（只读）。
func get_condition_type_id() -> StringName:
	return _condition_type_id


## 显示名（只读）。
func get_display_name() -> String:
	return _display_name


## 可作用目标内容域（detached 副本，只读；空数组表示不限目标类型）。
func get_applicable_target_domains() -> Array[StringName]:
	return _applicable_target_domains.duplicate()


## 参数稳定 ID 列表（detached 副本，只读）。
func get_param_ids() -> Array[StringName]:
	return _param_ids.duplicate()


## 校验目标内容域是否可挂本条件类型（applicable 为空表示不限）。
func is_applicable_to_target_domain(target_domain: StringName) -> bool:
	return _applicable_target_domains.is_empty() or target_domain in _applicable_target_domains


## form_condition 的 allowed_forms 参数合法值集合（LightForm 枚举域；参数枚举的正式事实来源）。
static func get_valid_light_forms() -> Array[int]:
	return [
		_LightEmissionTypes.LightForm.RAY,
		_LightEmissionTypes.LightForm.PARTICLE,
	]
