class_name ObjectiveConditionConfiguration
extends RefCounted

## 目标条件实例配置（冻结 Guide B §25.3，AF-04 / P0-6）。
## 持有"某目标挂了哪种条件类型 + 该类型的参数取值"；Schema 式约束 Typed 存储，
## 与 AF-03 MechanismConfiguration 同构：未知类型 / 非法参数拒绝构造，构造后只读。
## 参数域（v1 裁定，additive 扩展）：form_condition → allowed_forms（LightForm 值集合，非空，
## 多值即该条件自己的 OR 参数模型，冻结 Guide A §13.1"OR 由 Condition 自己的参数模型表达"）；
## color_condition → target_color（ColorValue 的 RED/GREEN/BLUE 之一，WHITE 不构成颜色条件，规则 光颜色水晶 v0.1 §8）。
## 同一条件类型在一个 Target 上最多一次由 ObjectiveTarget 构造时强制；本类只保证单实例合法。


const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 条件类型稳定 ID（必为已正式声明类型）。
var _condition_type_id: StringName
## form_condition 参数：允许的命中光形态集合（非空、值域合法、去重有序）。
var _allowed_forms: Array[int]
## color_condition 参数：目标颜色（ColorValue 的 RED/GREEN/BLUE 之一；非 color_condition 条件恒为 -1）。
var _target_color: int = -1


## 构造条件配置；类型未声明或参数非法返回 null 并 push_error（零副作用拒绝）。
## [br]form_condition 要求 allowed_forms 非空且值 ∈ {RAY, PARTICLE}；重复值自动去重。
static func create(condition_type_id: StringName, allowed_forms: Array) -> ObjectiveConditionConfiguration:
	var definition: _ObjectiveConditionDefinition = _ObjectiveConditionDefinition.get_by_type_id(condition_type_id)
	if definition == null:
		push_error("ObjectiveConditionConfiguration：条件类型 %s 未正式声明，拒绝构造。" % [condition_type_id])
		return null
	var configuration: ObjectiveConditionConfiguration = ObjectiveConditionConfiguration.new()
	configuration._condition_type_id = condition_type_id
	match condition_type_id:
		_ObjectiveConditionDefinition.TYPE_FORM_CONDITION:
			var normalized: Array[int] = []
			for form_variant: Variant in allowed_forms:
				var form: int = int(form_variant)
				if not form in _ObjectiveConditionDefinition.get_valid_light_forms():
					push_error("ObjectiveConditionConfiguration：光形态值 %d 越界，拒绝构造。" % [form])
					return null
				if not normalized.has(form):
					normalized.append(form)
			if normalized.is_empty():
				push_error("ObjectiveConditionConfiguration：allowed_forms 不得为空，拒绝构造。")
				return null
			configuration._allowed_forms = normalized
		_:
			push_error("ObjectiveConditionConfiguration：条件类型 %s 已声明但无参数域，拒绝构造。" % [condition_type_id])
			return null
	return configuration


## 构造 color_condition 条件配置（光颜色水晶颜色条件）；目标色越界返回 null 并 push_error（零副作用拒绝）。
## [br]target_color 须为 ColorValue 的 RED/GREEN/BLUE 之一（get_valid_target_colors 域）；
## [br]WHITE（白光不是单色目标）与 NONE（哨兵）均拒绝——机关规则 光颜色水晶 v0.1 §8 设计决策拍板。
static func create_for_color(target_color: int) -> ObjectiveConditionConfiguration:
	if not target_color in _ObjectiveConditionDefinition.get_valid_target_colors():
		push_error("ObjectiveConditionConfiguration：目标颜色值 %d 越界（仅 RED/GREEN/BLUE），拒绝构造。" % [target_color])
		return null
	var configuration: ObjectiveConditionConfiguration = ObjectiveConditionConfiguration.new()
	configuration._condition_type_id = _ObjectiveConditionDefinition.TYPE_COLOR_CONDITION
	configuration._target_color = target_color
	return configuration


## 条件类型稳定 ID（只读）。
func get_condition_type_id() -> StringName:
	return _condition_type_id


## allowed_forms 参数（detached 副本，只读；非 form_condition 条件为空数组）。
func get_allowed_forms() -> Array[int]:
	return _allowed_forms.duplicate()


## 判断某光形态是否被本配置允许（form_condition 语义；仅 ObjectiveConditionEvaluator 使用）。
func allows_light_form(light_form: int) -> bool:
	return _allowed_forms.has(light_form)


## target_color 参数（只读；非 color_condition 条件恒为 -1）。
func get_target_color() -> int:
	return _target_color


## 判断某到达颜色是否命中本条件的目标色（color_condition 语义：精确相等，只筛选不改色；
## 仅 ObjectiveConditionEvaluator 使用）。
func accepts_color(color: int) -> bool:
	return _target_color == color
