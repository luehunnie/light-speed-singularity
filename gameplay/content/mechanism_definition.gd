@tool
class_name MechanismDefinition
extends FormalContentDefinition

## 机关域声明（Guide 4.1）：机关类型级能力与作者元数据，与目标域/发射器域分域。
## 本批最小集含库存资格、光照交互形态（P0-3 additive）与控制域能力（AF-05 / P1 additive）；
##   足迹、玩家动作、稳定字段等能力域字段按 P0-4 各阶段 additive 扩展，
##   本类不得保存具体玩法算法（Guide 4.2）。


const _ControlEventDefinition: GDScript = preload(
	"res://gameplay/control/control_event_definition.gd"
)
const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)


## 库存资格声明已上移 FormalContentDefinition 基类（inventory_eligible；机关域沿用同一事实源）。

## 声明支持交互的光形态 token 集合（Guide §21“Definition 声明实际支持的 Light Forms”；子集 of {RAY, PARTICLE}）。
## [br]空 = 未声明任何形态 → 对两形态均透明（Runtime 不调用 interact_*）；
##   运行期分发读机关节点 get_light_interaction_forms() 镜像（P0-2 统一消费接线前的事实入口）。
@export var light_interaction_forms: Array[StringName] = []

## 正式 Typed Configuration 字段声明（AF-03 / P0-4，Guide §11.3/§11.4）：MechanismFieldDefinition 数组。
## [br]只有在此声明的 Stable Field ID 才是正式 Designer API；field_id 不得重复，默认值须自洽。
@export var configuration_fields: Array = []

## 本类型支持的 Typed Player Interaction Action token 集合（Guide §12；子集 of {CYCLE_INTERNAL_STATE, CYCLE_DIRECTION}）。
## [br]MOVE / RECOVER 属 Placement / Inventory Infrastructure，不在此声明。
@export var player_interaction_actions: Array[StringName] = []

## 静态 Footprint 声明（Guide §13.2）：anchor 相对偏移格；默认单格 [(0,0)]。
## [br]动态占格（配置驱动 offsets）另经 footprint_field_id 声明；本列表非空、无重复格。
@export var static_footprint_offsets: Array[Vector2i] = [Vector2i.ZERO]

## 动态 Footprint 驱动字段的 Stable Field ID（Guide §13.2；空 = 纯静态 Footprint）。
## [br]声明时该字段须存在于 configuration_fields 且值类型为 VECTOR2I_ARRAY（偏移格列表）。
@export var footprint_field_id: StringName = &""

## 控制源能力：本类型可发出的稳定 Output Events（ControlEventDefinition 数组；Guide §4.1 / §26.2）。
## [br]作者/校验枚举元数据；运行期事件声明镜像读机关节点 get_output_event_ids()。
@export var control_output_events: Array = []

## 控制目标能力：本类型接受的稳定 Control Actions（ControlActionDefinition 数组；Guide §4.1 / §26.2 / §30）。
## [br]运行期能力/Schema/互斥镜像读机关节点 get_control_action_definitions()。
@export var control_actions: Array = []

## 运行状态能力声明（Guide §28）：只有真正有状态的正式内容才为 true；
## [br]无状态机关不得创建空 State 对象；Reset 集成见 Dispatcher 可选 Hook（§33 / P1-2）。
@export var has_control_runtime_state: bool = false


func get_content_domain() -> StringName:
	return &"mechanism"


## 校验：基类域 + 光形态 token 归属 + 控制域声明合法性 + P0-4 配置/动作/足迹域。
func validate_definition() -> PackedStringArray:
	var errors := super.validate_definition()
	var allowed: Array[StringName] = [&"RAY", &"PARTICLE"]
	for form_token: StringName in light_interaction_forms:
		if not allowed.has(form_token):
			errors.append("light_interaction_forms 含非法光形态 %s（仅允许 RAY / PARTICLE）。" % [form_token])
	if light_interaction_forms.size() != _unique_form_count():
		errors.append("light_interaction_forms 存在重复声明。")
	errors.append_array(_validate_control_declarations())
	errors.append_array(_validate_configuration_declarations())
	return errors


## P0-4 域校验：Typed 配置字段自身合法且 field_id / player_action 不重复、
## [br]玩家动作 token 归属正式动作域、静态足迹非空无重复、动态足迹驱动字段存在且类型正确。
func _validate_configuration_declarations() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen_field_ids: Dictionary = {}
	var seen_player_actions: Dictionary = {}
	for field: Variant in configuration_fields:
		if not (field is _MechanismFieldDefinition):
			errors.append("configuration_fields 含非 MechanismFieldDefinition 成员。")
			continue
		errors.append_array(_prefixed("configuration_fields", field.validate()))
		if seen_field_ids.has(field.field_id):
			errors.append("configuration_fields 存在重复 field_id：%s。" % [field.field_id])
		seen_field_ids[field.field_id] = true
		if field.player_action != &"":
			if seen_player_actions.has(field.player_action):
				errors.append("configuration_fields 存在重复 player_action 驱动声明：%s。" % [field.player_action])
			seen_player_actions[field.player_action] = true
	var allowed_actions: Array[StringName] = _PlayerInteractionAction.ALL_ACTION_TOKENS
	for action_token: StringName in player_interaction_actions:
		if not allowed_actions.has(action_token):
			errors.append("player_interaction_actions 含非法动作 token %s。" % [action_token])
	if static_footprint_offsets.is_empty():
		errors.append("static_footprint_offsets 为空（至少须含 anchor 偏移 (0,0)）。")
	var seen_cells: Dictionary = {}
	for offset: Vector2i in static_footprint_offsets:
		if seen_cells.has(offset):
			errors.append("static_footprint_offsets 存在重复偏移格 %s。" % [offset])
		seen_cells[offset] = true
	if footprint_field_id != &"":
		var footprint_field := _find_configuration_field(footprint_field_id)
		if footprint_field == null:
			errors.append("footprint_field_id 指向未声明字段：%s。" % [footprint_field_id])
		elif footprint_field.value_type != _MechanismFieldDefinition.ValueType.VECTOR2I_ARRAY:
			errors.append("footprint_field_id 指向字段 %s 类型须为 VECTOR2I_ARRAY。" % [footprint_field_id])
	return errors


## 按 Stable Field ID 查配置字段声明；未声明返回 null。
func _find_configuration_field(field_id: StringName) -> _MechanismFieldDefinition:
	for field: Variant in configuration_fields:
		if not (field is _MechanismFieldDefinition):
			continue
		if (field as _MechanismFieldDefinition).field_id == field_id:
			return field as _MechanismFieldDefinition
	return null


## 控制域声明校验：成员须为正式声明资源、自身合法、event_id / action_id 不重复。
func _validate_control_declarations() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen_event_ids: Dictionary = {}
	for event_definition: Variant in control_output_events:
		if not (event_definition is _ControlEventDefinition):
			errors.append("control_output_events 含非 ControlEventDefinition 成员。")
			continue
		errors.append_array(_prefixed("control_output_events", event_definition.validate()))
		if seen_event_ids.has(event_definition.event_id):
			errors.append("control_output_events 存在重复 event_id：%s。" % [event_definition.event_id])
		seen_event_ids[event_definition.event_id] = true
	var seen_action_ids: Dictionary = {}
	for action_definition: Variant in control_actions:
		if not (action_definition is _ControlActionDefinition):
			errors.append("control_actions 含非 ControlActionDefinition 成员。")
			continue
		errors.append_array(_prefixed("control_actions", action_definition.validate()))
		if seen_action_ids.has(action_definition.action_id):
			errors.append("control_actions 存在重复 action_id：%s。" % [action_definition.action_id])
		seen_action_ids[action_definition.action_id] = true
	return errors


## 为子声明校验问题加域前缀（定位到字段）。
func _prefixed(field: String, problems: PackedStringArray) -> PackedStringArray:
	var prefixed: PackedStringArray = PackedStringArray()
	for problem: String in problems:
		prefixed.append("%s：%s" % [field, problem])
	return prefixed


## 统计去重后的形态数（供重复声明检测）。
func _unique_form_count() -> int:
	var seen: Dictionary = {}
	for form_token: StringName in light_interaction_forms:
		seen[form_token] = true
	return seen.size()
