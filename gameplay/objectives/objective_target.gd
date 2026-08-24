class_name ObjectiveTarget
extends RefCounted

## 目标运行时 Target Carrier（冻结 Guide A §13 / Guide B §25.2，AF-04 / P0-6）。
## 技术模型：Target Carrier + 0..N Objective Conditions；空条件 = Base Success（任何合法命中即成功）。
## BasicCrystal 即 conditions = [] 的 Carrier；Ray 形态目标 = + FormCondition(RAY)。
## 组合语义（Guide B §25.4）：不同 Condition AND / 同 Condition Type 最多一次（构造时强制）/
##   Condition 内多值由该 Condition 自己定义 / 空条件 Base Success。
## 本类是纯运行时数据模型：不持 Node / 水晶引用、不进场景树、不判断组关系（组由 ObjectiveGroup 持本类 ID）、
##   不负责点亮视觉与关卡完成（由 ObjectiveController 统一完成状态）。
## 跨目标 Required / Optional 属于 Independent Objective 或 Group，不属成员自身（Guide A §14.1）；
##   本类的 required 只在"独立目标（未入组）"语境下被 ObjectiveModel 消费。


const _ObjectiveConditionConfiguration: GDScript = preload("res://gameplay/objectives/objective_condition_configuration.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _ObjectiveConditionEvaluator: GDScript = preload("res://gameplay/objectives/objective_condition_evaluator.gd")

## 无成功记录哨兵（区别于任何合法时间值）。
const NO_SUCCESS: float = -1.0


## 目标稳定 ID（正式身份；不从 Node.name 推导）。
var _target_id: StringName
## 目标所在格（ObjectiveController 命中路由键；一格一目标，由 ObjectiveModel 保证唯一）。
var _cell: Vector2i
## 是否 Required（仅独立目标语境生效；入组目标的完成语义由所属组决定）。
var _required: bool
## 条件配置列表（构造时校验：类型已声明且同类型最多一次）。
var _conditions: Array
## 最近一次通过全部条件的成功时间（时间戳由调用方注入；NO_SUCCESS 表示从未成功）。
var _last_success_at: float


## 构造 Target Carrier；同类型条件重复或含非法配置返回 null 并 push_error（零副作用拒绝）。
static func create(
		target_id: StringName,
		cell: Vector2i,
		required: bool,
		conditions: Array
) -> ObjectiveTarget:
	if target_id == &"":
		push_error("ObjectiveTarget：目标 ID 不得为空，拒绝构造。")
		return null
	var seen_type_ids: Array[StringName] = []
	var validated: Array = []
	for condition_variant: Variant in conditions:
		var condition: _ObjectiveConditionConfiguration = condition_variant as _ObjectiveConditionConfiguration
		if condition == null:
			push_error("ObjectiveTarget：%s 含非法条件配置，拒绝构造。" % [target_id])
			return null
		var type_id: StringName = condition.get_condition_type_id()
		if seen_type_ids.has(type_id):
			push_error("ObjectiveTarget：%s 条件类型 %s 重复，拒绝构造（同类型最多一次）。" % [target_id, type_id])
			return null
		seen_type_ids.append(type_id)
		validated.append(condition)
	var target: ObjectiveTarget = ObjectiveTarget.new()
	target._target_id = target_id
	target._cell = cell
	target._required = required
	target._conditions = validated
	target._last_success_at = NO_SUCCESS
	return target


## 目标稳定 ID（只读）。
func get_target_id() -> StringName:
	return _target_id


## 目标所在格（只读）。
func get_cell() -> Vector2i:
	return _cell


## 是否 Required（只读；仅独立目标语境生效）。
func is_required() -> bool:
	return _required


## 条件配置数（只读；0 即 Base Success）。
func get_condition_count() -> int:
	return _conditions.size()


## 判定一次命中是否通过本目标全部条件（AND；空条件列表 = Base Success 直接放行）。
## [br]纯判定：不修改任何状态；调用方据返回值决定 register_success。
func evaluate_hit(hit: Variant) -> bool:
	var hit_context: _ObjectiveHitContext = hit as _ObjectiveHitContext
	if hit_context == null:
		return false
	for condition_variant: Variant in _conditions:
		var condition: _ObjectiveConditionConfiguration = condition_variant as _ObjectiveConditionConfiguration
		if _ObjectiveConditionEvaluator.evaluate(condition, hit_context) != _ObjectiveConditionEvaluator.Verdict.SATISFIED:
			return false
	return true


## 登记一次成功（调用方在 evaluate_hit 为 true 后调用）；记录最近成功时间，重复调用安全（刷新时间）。
func register_success(now: float) -> void:
	_last_success_at = now


## 是否已有成功记录（独立目标完成语义；滑动窗口内有效性由所属组判定）。
func has_success() -> bool:
	return _last_success_at != NO_SUCCESS


## 最近一次成功时间（NO_SUCCESS 表示从未成功，只读）。
func get_last_success_at() -> float:
	return _last_success_at


## 重置运行状态：清空成功记录（conditions 与身份不变）；重复调用安全。
func reset_runtime() -> void:
	_last_success_at = NO_SUCCESS
