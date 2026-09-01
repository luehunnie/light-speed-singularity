class_name LightInteractionResult
extends RefCounted

## 光交互正式结果（冻结 Guide §22）：1 个 Propagation Decision + 0..N 个有限 Typed Effects。
## 机关只“请求结果”，不直接改 Runtime；不开放任意 Effect 字典或自由命令数组（§22 禁止）。
## Decision（§22.1）：CONTINUE / BLOCK / REDIRECT(direction)；阶段C-01 扩展 FORM_CHANGE(target_form, direction)
##   （光形式转换器：转换发生在机关格内，出射沿 direction、形态变为 target_form，速度/颜色规则由执行适配层按平台默认生成）；
##   阶段C-08 扩展 REDIRECT_CROSS(redirect_direction, cross_direction)（穿邻格：跨界格透明通过）与分光分支载荷
##   spawned_branches: Array[BranchSpec]（仅 CONTINUE / REDIRECT 且 RAY 形态可携带；扩展已登记 Freeze Ledger §47，此后冻结）。
## Typed Effects（§22.2）：PARTICLE_SPEED_DELTA(delta)（只允许 ±1，Guide §24）/ OUTPUT_EVENT(event_id) / COLOR_CHANGE(target_color)。
## 不可变意图：经 continue_result / block_result / redirect_result / form_change_result 构造，add_* 追加效果后交 Runtime；
##   Runtime 校验入口 validate(light_form) 返回问题清单，校验失败由 Runtime 安全降级（Contract 分发层负责）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

## 分光器默认朝向（C-08 冻结裁决：仅作为接口默认值登记，本基座不实现分光器本体）。
const DEFAULT_SPLITTER_ORIENTATION: Vector2i = Vector2i.RIGHT

## Propagation Decision（§22.1 冻结；C-08 扩展 REDIRECT_CROSS）。
enum Decision {
	CONTINUE,
	BLOCK,
	REDIRECT,
	FORM_CHANGE,
	REDIRECT_CROSS,
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


## 分光分支载荷（C-08 冻结；仅服务已知分光需求的公共基座，本基座不实现分光器本体）。
## [br]source_cell / direction 由机关按自身端口表设定（分支出发点与出射八方向）；
## [br]color 非机关输入——由执行层按入射状态盖章（继承既有光线颜色），机关构造时恒为 NONE 哨兵，validate 拒绝非 NONE。
## [br]形态与速度不携带：分支仅 RAY 形态合法（validate 强制，PARTICLE 无分支），RAY 无速度语义——形态恒 RAY、速度无定义。
class BranchSpec:
	extends RefCounted

	## 分支出发的源格（机关按自身端口表设定）。
	var source_cell: Vector2i
	## 分支出射八方向单位向量（validate 强制合法）。
	var direction: Vector2i
	## 继承色（执行层盖章；机关侧构造恒 NONE 哨兵，validate 拒绝非 NONE）。
	var color: int


## Propagation Decision（CONTINUE / BLOCK / REDIRECT / FORM_CHANGE）。
var decision: int = Decision.CONTINUE
## REDIRECT 与 FORM_CHANGE 共用的出射八方向；REDIRECT_CROSS 时为改向后出射方向；CONTINUE / BLOCK 时恒为 Vector2i.ZERO。
var redirect_direction: Vector2i = Vector2i.ZERO
## REDIRECT_CROSS 的跨界方向（C-08；须为合法正交四方向单位向量）：该方向邻格被透明跨过（执行层不重复判机关）；
##   其余 Decision 恒为 Vector2i.ZERO（validate 强制互斥）。
var cross_direction: Vector2i = Vector2i.ZERO
## FORM_CHANGE 的目标形态（LightForm 值：RAY / PARTICLE）；其余 Decision 时恒为 -1 哨兵。
var target_form: int = -1
## 有序 Typed Effects（0..N）。
var effects: Array[TypedEffect] = []
## 有序分光分支载荷（C-08 冻结；仅 CONTINUE / REDIRECT 且 RAY 形态可非空，其余 Decision / 形态须为空——validate 强制；
##   REDIRECT_CROSS 穿邻格为单输出，不得携带分支）。派生 emission 由执行适配层经既有 spawner 范式生成。
var spawned_branches: Array[BranchSpec] = []


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


## 构造 FORM_CHANGE 结果（阶段C-01 光形式转换器）；target_form 须为 LightForm 值，
##   direction 须为合法八方向（非法由 validate 拒绝）。转换发生在机关格内，出射方向 = 本机关朝向。
static func form_change_result(target_form: int, direction: Vector2i) -> LightInteractionResult:
	var result: LightInteractionResult = LightInteractionResult.new()
	result.decision = Decision.FORM_CHANGE
	result.target_form = target_form
	result.redirect_direction = direction
	return result


## 构造 REDIRECT_CROSS 结果（C-08 双格平面镜穿邻格；RAY / PARTICLE 两形态对称合法）。
## [br]redirect_direction 须为合法八方向（改向后出射方向）；cross_direction 须为合法正交四方向——
##   该方向邻格被透明跨过（执行层记录路径但不重复判机关）。非法由 validate 拒绝（降级透明 CONTINUE）。
static func redirect_cross_result(redirect_direction: Vector2i, cross_direction: Vector2i) -> LightInteractionResult:
	var result: LightInteractionResult = LightInteractionResult.new()
	result.decision = Decision.REDIRECT_CROSS
	result.redirect_direction = redirect_direction
	result.cross_direction = cross_direction
	return result


## 追加一个分光分支载荷（C-08；仅 CONTINUE / REDIRECT 决策且 RAY 形态合法，validate 强制）。
## [br]color 留 NONE 哨兵，由执行层按入射状态盖章（机关不得自设色）；返回自身便于链式表达。
func add_spawned_branch(source_cell: Vector2i, direction: Vector2i) -> LightInteractionResult:
	var branch: BranchSpec = BranchSpec.new()
	branch.source_cell = source_cell
	branch.direction = direction
	branch.color = _RayColor.ColorValue.NONE
	spawned_branches.append(branch)
	return self


## 构造分支载荷实例（C-08；供执行适配层复制机关分支并盖章继承色；机关侧应经 add_spawned_branch 追加）。
static func make_branch_spec(source_cell: Vector2i, direction: Vector2i, color: int) -> BranchSpec:
	var branch: BranchSpec = BranchSpec.new()
	branch.source_cell = source_cell
	branch.direction = direction
	branch.color = color
	return branch


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
##   REDIRECT_CROSS（C-08）须携带合法八方向 redirect_direction + 合法正交四方向 cross_direction，
##   且 cross_direction 仅 REDIRECT_CROSS 可携带（严格互斥，其余 Decision 恒 ZERO）；
##   spawned_branches（C-08）仅 CONTINUE / REDIRECT 且 RAY 形态可非空，分支 direction 须合法八方向、
##   color 须为 NONE 哨兵（继承色由执行层盖章）；
##   PARTICLE_SPEED_DELTA 仅 PARTICLE 形态合法且 delta 只允许 ±1、至多一个；
##   OUTPUT_EVENT 的 event_id 须非空且至多一个（重复同类效果视为不合法 Result）；
##   COLOR_CHANGE 仅 RAY 形态合法、target_color 须为真实四色、至多一个。
func validate(light_form: int) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if decision != Decision.CONTINUE and decision != Decision.BLOCK and decision != Decision.REDIRECT and decision != Decision.FORM_CHANGE and decision != Decision.REDIRECT_CROSS:
		problems.append("未知 Propagation Decision：%d。" % [decision])
		return problems
	if decision == Decision.REDIRECT:
		if not _DirectionDomain.is_valid(redirect_direction):
			problems.append("REDIRECT 须携带合法八方向，实际 %s。" % [redirect_direction])
	elif decision == Decision.FORM_CHANGE:
		if not _DirectionDomain.is_valid(redirect_direction):
			problems.append("FORM_CHANGE 须携带合法八方向，实际 %s。" % [redirect_direction])
		if target_form != _LightEmissionTypes.LightForm.RAY and target_form != _LightEmissionTypes.LightForm.PARTICLE:
			problems.append("FORM_CHANGE 的 target_form 须为 RAY / PARTICLE，实际 %d。" % [target_form])
	elif decision == Decision.REDIRECT_CROSS:
		# C-08 穿邻格：改向须八方向，跨界方向须正交四方向（邻格透明跨过）。
		if not _DirectionDomain.is_valid(redirect_direction):
			problems.append("REDIRECT_CROSS 须携带合法八方向 redirect_direction，实际 %s。" % [redirect_direction])
		if not _DirectionDomain.is_orthogonal(cross_direction):
			problems.append("REDIRECT_CROSS 须携带合法正交四方向 cross_direction，实际 %s。" % [cross_direction])
	elif redirect_direction != Vector2i.ZERO:
		problems.append("CONTINUE / BLOCK 不得携带 redirect_direction。")
	# cross_direction 严格互斥（C-08）：仅 REDIRECT_CROSS 可携带，其余 Decision 恒 ZERO。
	if decision != Decision.REDIRECT_CROSS and cross_direction != Vector2i.ZERO:
		problems.append("仅 REDIRECT_CROSS 可携带 cross_direction（其余 Decision 恒 ZERO），实际 %s。" % [cross_direction])
	if decision != Decision.FORM_CHANGE and target_form != -1:
		problems.append("仅 FORM_CHANGE 可携带 target_form（其余 Decision 恒 -1），实际 %d。" % [target_form])
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
	# 分支载荷校验（C-08）：仅 CONTINUE / REDIRECT 且 RAY 形态可非空；分支方向合法、颜色须为 NONE（执行层盖章）。
	if not spawned_branches.is_empty():
		if decision != Decision.CONTINUE and decision != Decision.REDIRECT:
			problems.append("仅 CONTINUE / REDIRECT 可携带 spawned_branches，实际 Decision %d 携带 %d 个分支。" % [decision, spawned_branches.size()])
		if light_form != _LightEmissionTypes.LightForm.RAY:
			problems.append("spawned_branches 仅 RAY 形态合法。")
		for branch: BranchSpec in spawned_branches:
			if not _DirectionDomain.is_valid(branch.direction):
				problems.append("分支 direction 须为合法八方向，实际 %s。" % [branch.direction])
			if branch.color != _RayColor.ColorValue.NONE:
				problems.append("分支 color 须为 NONE 哨兵（继承色由执行层盖章，机关不得自设），实际 %d。" % [branch.color])
	return problems
