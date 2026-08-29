class_name ObjectiveConditionEvaluator
extends RefCounted

## 目标条件纯求值器（冻结 Guide B §25.3，AF-04 / P0-6）。
## 契约：configuration + ObjectiveHitContext → SATISFIED / NOT_SATISFIED。
## 禁止（源码级边界，由静态扫描测试锁定）：查询 Ray / Particle Runtime、扫描 World、
## 修改其它目标、自己完成关卡；本类只做纯函数判定，无状态、无副作用、不进场景树。
## Base Success（空条件列表）不是条件类型，由 ObjectiveTarget.evaluate_hit 空列表直接放行。


const _ObjectiveConditionConfiguration: GDScript = preload("res://gameplay/objectives/objective_condition_configuration.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")

## 求值结果：条件满足 / 条件不满足。
enum Verdict {
	SATISFIED = 0,
	NOT_SATISFIED = 1,
}


## 纯求值入口：判定单条条件配置对一次命中事实是否满足。
## [br]输入均不被修改；返回 SATISFIED / NOT_SATISFIED；未知条件类型按 NOT_SATISFIED 安全失败（配置构造已挡非法类型，此为双保险）。
static func evaluate(configuration: Variant, hit: Variant) -> int:
	var condition_configuration: _ObjectiveConditionConfiguration = configuration as _ObjectiveConditionConfiguration
	var hit_context: _ObjectiveHitContext = hit as _ObjectiveHitContext
	if condition_configuration == null or hit_context == null:
		return Verdict.NOT_SATISFIED
	match condition_configuration.get_condition_type_id():
		_ObjectiveConditionDefinition.TYPE_FORM_CONDITION:
			return Verdict.SATISFIED if condition_configuration.allows_light_form(hit_context.get_light_form()) else Verdict.NOT_SATISFIED
		_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION:
			return Verdict.SATISFIED if condition_configuration.accepts_color(hit_context.get_color()) else Verdict.NOT_SATISFIED
		_:
			return Verdict.NOT_SATISFIED
