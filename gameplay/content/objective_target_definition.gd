@tool
class_name ObjectiveTargetDefinition
extends FormalContentDefinition

## 目标域声明（Guide 4.1）：目标类型级能力与作者元数据。
## 允许的目标条件类型等目标域能力按 P0-6 阶段 additive 扩展。


# 条件类型注册表（Editor/Validator 枚举唯一入口）；content → objectives 单向依赖，objectives 不回引 content。
const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")


## 命中即基础成功（Base Success）。
@export var base_success_on_hit: bool = true

## 允许挂载的目标条件类型稳定 ID 列表（Guide B §165 Allowed Objective Condition Types）。
## 空列表 = 不限制（全部已声明条件类型可挂）；非空 = 仅列出的类型可挂（同类型在单目标上仍最多一次，由运行时强制）。
@export var allowed_condition_types: Array[StringName] = []


func get_content_domain() -> StringName:
	return &"objective_target"


## 域校验（additive）：条件类型必须已在注册表正式声明且不重复；空列表放行（不限制语义）。
func validate_definition() -> PackedStringArray:
	var issues: PackedStringArray = super.validate_definition()
	var seen: Array[StringName] = []
	for type_id: StringName in allowed_condition_types:
		if _ObjectiveConditionDefinition.get_by_type_id(type_id) == null:
			issues.append("objective_target.allowed_condition_types：条件类型 %s 未正式声明。" % [type_id])
		if seen.has(type_id):
			issues.append("objective_target.allowed_condition_types：条件类型 %s 重复。" % [type_id])
		seen.append(type_id)
	return issues
