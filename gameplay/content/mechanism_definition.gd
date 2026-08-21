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


## 是否可进入库存并被玩家 Spawn。
@export var inventory_eligible: bool = false

## 声明支持交互的光形态 token 集合（Guide §21“Definition 声明实际支持的 Light Forms”；子集 of {RAY, PARTICLE}）。
## [br]空 = 未声明任何形态 → 对两形态均透明（Runtime 不调用 interact_*）；
##   运行期分发读机关节点 get_light_interaction_forms() 镜像（P0-2 统一消费接线前的事实入口）。
@export var light_interaction_forms: Array[StringName] = []

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


## 校验：基类域 + 光形态 token 归属 + 控制域声明合法性。
func validate_definition() -> PackedStringArray:
	var errors := super.validate_definition()
	var allowed: Array[StringName] = [&"RAY", &"PARTICLE"]
	for form_token: StringName in light_interaction_forms:
		if not allowed.has(form_token):
			errors.append("light_interaction_forms 含非法光形态 %s（仅允许 RAY / PARTICLE）。" % [form_token])
	if light_interaction_forms.size() != _unique_form_count():
		errors.append("light_interaction_forms 存在重复声明。")
	errors.append_array(_validate_control_declarations())
	return errors


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
