class_name LightInteractionResult
extends RefCounted

## 光交互正式结果（冻结 Guide §22）：1 个 Propagation Decision + 0..N 个有限 Typed Effects。
## 机关只“请求结果”，不直接改 Runtime；不开放任意 Effect 字典或自由命令数组（§22 禁止）。
## Decision（§22.1）：CONTINUE / BLOCK / REDIRECT(direction)。
## Typed Effects（§22.2）：PARTICLE_SPEED_DELTA(delta)（只允许 ±1，Guide §24）/ OUTPUT_EVENT(event_id) / COLOR_CHANGE(target_color)。
## 不可变意图：经 continue_result / block_result / redirect_result 构造，add_* 追加效果后交 Runtime；
##   Runtime 校验入口 validate(light_form) 返回问题清单，校验失败由 Runtime 安全降级（Contract 分发层负责）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

## Propagation Decision（§22.1 冻结）。
enum Decision {
	CONTINUE,
	BLOCK,
	REDIRECT,
}

## Typed Effect 种类（§22.2 冻结；新增种类须冻结变更）。
enum EffectType {
	PARTICLE_SPEED_DELTA,
	OUTPUT_EVENT,
	COLOR_CHANGE,
}


## 有限 Typed Effect 载体（构造后只读）。
class TypedEffect:
	extends RefCounted

	## 效果种类（EffectType 值）。
	var type: int
	## PARTICLE_SPEED_DELTA 的档位增量（合法域 ±1）。
	var delta: int
	## OUTPUT_EVENT 的稳定事件 ID（非空 StringName）。
	var event_id: StringName
	## COLOR_CHANGE 的目标色（ColorValue 枚举值，合法域为真实四色）。
	var target_color: int


## Propagation Decision（三值之一）。
var decision: int = Decision.CONTINUE
## REDIRECT 的出射八方向；CONTINUE / BLOCK 时恒为 Vector2i.ZERO。
var redirect_direction: Vector2i = Vector2i.ZERO
## 有序 Typed Effects（0..N）。
var effects: Array[TypedEffect] = []


## 构造 CONTINUE 结果（保持传播状态）。
static func continue_result() -> LightInteractionResult:
	var result: LightInteractionResult = LightInteractionResult.new()
	result.decision = Decision.CONTINUE
	return result


## 构造 BLOCK 结果（停止传播）。
static func block_result() -> LightInteractionResult:
	var result: LightInteractionResult = LightInteractionResult.new()
	result.decision = Decision.BLOCK
	return result


## 构造 REDIRECT 结果；direction 须为合法八方向（非法由 validate 拒绝）。
static func redirect_result(direction: Vector2i) -> LightInteractionResult:
	var result: LightInteractionResult = LightInteractionResult.new()
	result.decision = Decision.REDIRECT
	result.redirect_direction = direction
	return result


## 追加 PARTICLE_SPEED_DELTA 效果（合法 delta 仅 +1 / -1，Guide §24）；返回自身便于链式表达。
func add_speed_delta(delta: int) -> LightInteractionResult:
	var effect: TypedEffect = TypedEffect.new()
	effect.type = EffectType.PARTICLE_SPEED_DELTA
	effect.delta = delta
	effect.event_id = &""
	effect.target_color = _RayColor.ColorValue.NONE
	effects.append(effect)
	return self


## 追加 OUTPUT_EVENT 效果（event_id 须为非空稳定事件 ID）；返回自身便于链式表达。
func add_output_event(event_id: StringName) -> LightInteractionResult:
	var effect: TypedEffect = TypedEffect.new()
	effect.type = EffectType.OUTPUT_EVENT
	effect.delta = 0
	effect.event_id = event_id
	effect.target_color = _RayColor.ColorValue.NONE
	effects.append(effect)
	return self

## 追加 COLOR_CHANGE 效果（target_color 须为真实四色，NONE 不可）；返回自身便于链式表达。
func add_color_change(target_color: int) -> LightInteractionResult:
	var effect: TypedEffect = TypedEffect.new()
	effect.type = EffectType.COLOR_CHANGE
	effect.delta = 0
	effect.event_id = &""
	effect.target_color = target_color
	effects.append(effect)
	return self

## 取首个 PARTICLE_SPEED_DELTA 的增量（无则 0）；供 Runtime 一次提交速度效果。
func get_speed_delta() -> int:
	for effect: TypedEffect in effects:
		if effect.type == EffectType.PARTICLE_SPEED_DELTA:
			return effect.delta
	return 0


## 取全部 OUTPUT_EVENT 的稳定事件 ID 副本（无则空）；供 Runtime 一次提交事件效果。
func get_output_event_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for effect: TypedEffect in effects:
		if effect.type == EffectType.OUTPUT_EVENT:
			ids.append(effect.event_id)
	return ids

## 取首个 COLOR_CHANGE 的目标色（无则 NONE 哨兵）；供 Runtime 一次提交颜色效果。
func get_color_change() -> int:
	for effect: TypedEffect in effects:
		if effect.type == EffectType.COLOR_CHANGE:
			return effect.target_color
	return _RayColor.ColorValue.NONE

## Runtime 校验入口（§23“Runtime 校验 Result”）：按形态校验 Decision / 方向 / Typed Effects 合法域。
## [br]输入：light_form 为 LightEmissionTypes.LightForm 值，用于形态相关合法性（RAY 无速度语义）。
## [br]返回：问题清单（空 = 合法）；不修改本结果、不产生副作用。
## [br]规则：未知 Decision 非法；REDIRECT 须携带合法八方向，CONTINUE / BLOCK 不得携带方向；
##   PARTICLE_SPEED_DELTA 仅 PARTICLE 形态合法且 delta 只允许 ±1、至多一个；
##   OUTPUT_EVENT 的 event_id 须非空且至多一个（重复同类效果视为不合法 Result）；
##   COLOR_CHANGE 仅 RAY 形态合法、target_color 须为真实四色、至多一个。
func validate(light_form: int) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if decision != Decision.CONTINUE and decision != Decision.BLOCK and decision != Decision.REDIRECT:
		problems.append("未知 Propagation Decision：%d。" % [decision])
		return problems
	if decision == Decision.REDIRECT:
		if not _DirectionDomain.is_valid(redirect_direction):
			problems.append("REDIRECT 须携带合法八方向，实际 %s。" % [redirect_direction])
	elif redirect_direction != Vector2i.ZERO:
		problems.append("CONTINUE / BLOCK 不得携带 redirect_direction。")
	var speed_delta_count: int = 0
	var event_count: int = 0
	var color_change_count: int = 0
	for effect: TypedEffect in effects:
		if effect.type == EffectType.PARTICLE_SPEED_DELTA:
			speed_delta_count += 1
			if light_form != _LightEmissionTypes.LightForm.PARTICLE:
				problems.append("PARTICLE_SPEED_DELTA 仅 PARTICLE 形态合法。")
			if effect.delta != 1 and effect.delta != -1:
				problems.append("PARTICLE_SPEED_DELTA 只允许 ±1，实际 %d。" % [effect.delta])
		elif effect.type == EffectType.OUTPUT_EVENT:
			event_count += 1
			if effect.event_id == &"":
				problems.append("OUTPUT_EVENT 须携带非空 event_id。")
		elif effect.type == EffectType.COLOR_CHANGE:
			color_change_count += 1
			if light_form != _LightEmissionTypes.LightForm.RAY:
				problems.append("COLOR_CHANGE 仅 RAY 形态合法。")
			if not _RayColor.is_valid(effect.target_color):
				problems.append("COLOR_CHANGE 的 target_color 须为真实四色。")
		else:
			problems.append("未知 Typed Effect 种类：%d。" % [effect.type])
	if speed_delta_count > 1:
		problems.append("同一次交互至多一个 PARTICLE_SPEED_DELTA（实际 %d 个）。" % [speed_delta_count])
	if event_count > 1:
		problems.append("同一次交互至多一个 OUTPUT_EVENT（实际 %d 个）。" % [event_count])
	if color_change_count > 1:
		problems.append("同一次交互至多一个 COLOR_CHANGE（实际 %d 个）。" % [color_change_count])
	return problems
