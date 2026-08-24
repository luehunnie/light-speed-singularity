class_name PlayerInteractionAction
extends RefCounted

## Typed Player Interaction Action 域（AF-03 / P0-4，Guide §12）：玩家修改机关内部状态的有限 Typed 动作。
## MOVE / RECOVER 属 Placement / Inventory Infrastructure，不属本域；两者经 Runtime Interaction Permission
## 以 MOVE_INSTANCE / RECOVER_INSTANCE 基础设施动作统一判权（见 runtime_interaction_permission.gd）。
## 禁止（Guide §12）：Runtime UI 对目标做具体类型判断、任意字符串方法名调用与任意参数 Dictionary；
## 候选配置由本域按 Definition 字段声明的 player_action 映射纯函数提案，不经节点类型分支。
## 依赖方向：本模块（交互域）→ content/configuration（字段/配置）；mechanism_definition 反向引用本模块
## 校验动作 token 归属，二者不构成循环（configuration 不回引交互域）。


## 循环内部状态（如镜面朝向 / 与 \ 切换）。
const CYCLE_INTERNAL_STATE: StringName = &"cycle_internal_state"
## 循环方向（如八方向机关顺时针换向）。
const CYCLE_DIRECTION: StringName = &"cycle_direction"

## 全部正式动作 token（供 Definition 校验归属；新增动作须同步本表）。
const ALL_ACTION_TOKENS: Array[StringName] = [
	CYCLE_INTERNAL_STATE,
	CYCLE_DIRECTION,
]

## 字段声明 / 配置存储类型引用（preload 避开新 class_name 全局缓存陈旧问题）。
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)


## 一次玩家动作请求（Guide §12 链路入口）：目标稳定实例 ID + 动作 token，不携带任意参数。
class ActionRequest:
	var target_stable_id: String = ""
	var action: StringName = &""

	func _init(p_target_stable_id: String = "", p_action: StringName = &"") -> void:
		target_stable_id = p_target_stable_id
		action = p_action


## 动作 token 是否属正式动作域（纯判断）。
static func is_valid_action(action: StringName) -> bool:
	return ALL_ACTION_TOKENS.has(action)


## 按动作 token 从配置 Schema 找到被驱动字段的 Stable Field ID；未声明该动作返回空。
## [br]纯查找：fields 为 MechanismFieldDefinition 数组；一个动作至多驱动一个字段（Definition 校验保证不重复）。
static func find_driven_field_id(fields: Array, action: StringName) -> StringName:
	for field: Variant in fields:
		if not (field is _MechanismFieldDefinition):
			continue
		var field_definition: _MechanismFieldDefinition = field as _MechanismFieldDefinition
		if field_definition.player_action == action:
			return field_definition.field_id
	return &""


## 机关提案候选配置（Guide §12 "Mechanism proposes Candidate Configuration"）：
## [br]按动作找到驱动字段并把其枚举值循环 +1（到上界回绕下界）；无驱动字段或字段非枚举 INT 返回 null。
## [br]纯函数：不修改传入配置，返回 duplicate 后的候选副本；调用方经 Placement 校验后原子提交。
static func propose_candidate_configuration(
	fields: Array,
	current: _MechanismConfiguration,
	action: StringName
) -> _MechanismConfiguration:
	var field_id := find_driven_field_id(fields, action)
	if field_id == &"":
		return null
	var field_definition := _find_field(fields, field_id)
	if field_definition == null or not field_definition.has_enum_range():
		push_error("PlayerInteractionAction: 动作 %s 的驱动字段缺少枚举界，无法提案。" % [action])
		return null
	var current_value: Variant = current.get_value(field_id)
	if not (current_value is int):
		push_error("PlayerInteractionAction: 字段 %s 当前值非整数，无法提案。" % [field_id])
		return null
	var candidate := current.duplicate_configuration()
	var span: int = field_definition.enum_max - field_definition.enum_min + 1
	var next_value: int = field_definition.enum_min + (int(current_value) - field_definition.enum_min + 1) % span
	if not candidate.apply_override(field_id, next_value):
		return null
	return candidate


## 按字段 ID 查 Schema 声明（内部复用；未声明返回 null）。
static func _find_field(fields: Array, field_id: StringName) -> _MechanismFieldDefinition:
	for field: Variant in fields:
		if not (field is _MechanismFieldDefinition):
			continue
		var field_definition: _MechanismFieldDefinition = field as _MechanismFieldDefinition
		if field_definition.field_id == field_id:
			return field_definition
	return null
