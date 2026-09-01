class_name RayEmissionDriver
extends RefCounted

## RAY emission 执行驱动器（M4-E2.1 从 LevelRuntimeController 拆出；GPT-5.6sol must-fix：Ray immutable snapshot + 最小职责拆分）。
## 职责（唯一）：接收**已完成 preflight 的 immutable Ray fire data**（generation / emission_id / start_cell / direction），执行一次 Ray 传播并完成本 emission：
##   - 防御性校验 immutable direction（失败返回 false，交 LRC rollback；正常路径 LRC 已 preflight，此处为 clean failure boundary）；
##   - 调 RayExecutionModule.execute（无副作用纯计算，传入构造期注入的 light_world_query 与冻结 max_steps）；
##   - 逐 step 应用副作用（同一格先 show_step 再 apply_hit 水晶命中——视觉→水晶顺序冻结，S3-05 起命中经 ObjectiveHitContext）；
##   - 应用完 steps 后回调 on_steps_applied（LRC 据此刷新完成标签，driver 不读 Objective 完成真值）；
##   - RAY 传播停止于机关格且携带 FORM_CHANGE 转换载荷时（阶段C-01 光形式转换器），回调 on_form_change
##     （签名 (generation, source_emission_id, target_form, converter_cell, direction) -> void；→ FormChangeEmissionSpawner），
##     driver 只透传载荷，不生成 emission、不复制转换规则；
##   - 管理本 Ray 的 visual delay（SceneTreeTimer），到期后回调 finish_emission(generation, emission_id) 交 LRC 聚合结算。
## 严禁拥有（硬边界——本驱动绝不做以下任何一项）：
##   - Registry / allocate / mark_finished（emission 身份与活动表归 LRC/ActiveEmissionRegistry）；
##   - RunStateController / 决定 PULSE_ACTIVE / 决定 COMPLETED / MOVE_WINDOW（聚合结算归 LRC._finish_emission）；
##   - generation 真值（仅作 immutable 快照透传 + 守卫参数透传给 finish_emission；真值唯一来源 LRC._runtime_generation）；
##   - 主发射器 cooldown（EmitterFireCooldown 归 LRC）；
##   - Objective 完成真值（不调 is_completed；完成标签经 on_steps_applied 由 LRC 读 Objective 刷新）；
##   - _finish_emission 聚合规则（仅回调 LRC 提供的 finish_emission Callable；过期/非活动/已结束守卫全部在 LRC._finish_emission 内）。
## 不再从可变 _fixed_emitter 重读请求：start_cell / direction 为 dispatch 调用方（LRC._dispatch_emission）传入的 immutable 快照，
##   dispatch 后修改 FixedEmitter 不影响已发 Ray（M4-E2.1 must-fix：消除 _execute_ray_emission 重读 build_fire_request 的 mutable re-read）。
## 位置：gameplay/runtime 下；纯执行驱动器，由 LevelRuntimeController 唯一持有；不 preload 任何 controller / Registry / RunState / cooldown / visual event。
## 依赖：RayExecutionModule（静态执行）/ RayExecutionResult（结果类型）/ LightEmissionTypes（is_valid_direction 防御性校验）经 preload；
##   light_visual_controller（show_step）/ objective_controller（apply_hit；S3-05 起经 ObjectiveHitContext 命中事实）/ light_world_query（RayExecutionModule.execute 参数）
##   为构造期注入的共享引用；finish_emission / on_steps_applied 为回调 LRC 的 outward Callable。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")


## LightVisualController 共享引用（show_step 创建/记录本 emission 的逐格光路视觉）。
var _light_visual_controller: Variant
## ObjectiveController 共享引用（apply_hit 应用光路上的水晶命中事实；未绑定模型等价原型激活）。
var _objective_controller: Variant
## 只读世界查询（RayExecutionModule.execute 的 world_query 参数；边界/墙体/水晶/机关只读契约）。
var _light_world_query: Variant
## Ray 传播最大步数上限（冻结配置值，构造期注入；触顶由 RayExecutionModule 记录 STEP_LIMIT，driver 复现 push_warning）。
var _max_propagation_steps: int
## Ray 视觉持续时间（秒）：dispatch 后等待本时长再回调 finish_emission（管理 visual delay；过期/非活动守卫在 LRC._finish_emission）。
var _pulse_visual_duration_seconds: float
## 完成 LRC per-emission 聚合结算的 outward Callable（签名 (generation: int, emission_id: int) -> void；→ LRC._finish_emission）。
## driver 仅回调；generation/pulse/active 守卫与 mark_finished/clear_emission/聚合切 RunState 全在 LRC._finish_emission 内。
var _finish_emission: Callable
## 逐 step 应用完成后的 outward Callable（签名 () -> void；→ LRC 刷新完成标签）。driver 不读 Objective 完成真值。
var _on_steps_applied: Callable
## FORM_CHANGE 转换载荷 outward Callable（阶段C-01；签名 (generation, source_emission_id, target_form, converter_cell, direction) -> void；
##   → FormChangeEmissionSpawner.handle_ray_form_change）。driver 只透传，不生成 emission；未接线（默认 Callable()）时转换载荷被忽略。
var _on_form_change: Callable


## 构造驱动器；light_visual_controller / objective_controller / light_world_query 为共享引用，
## [br]max_propagation_steps / pulse_visual_duration_seconds 为冻结配置，finish_emission / on_steps_applied 为回调 LRC 的 Callable。
func _init(
		light_visual_controller: Variant,
		objective_controller: Variant,
		light_world_query: Variant,
		max_propagation_steps: int,
		pulse_visual_duration_seconds: float,
		finish_emission: Callable,
		on_steps_applied: Callable,
		on_form_change: Callable = Callable()
) -> void:
	_light_visual_controller = light_visual_controller
	_objective_controller = objective_controller
	_light_world_query = light_world_query
	_max_propagation_steps = max_propagation_steps
	_pulse_visual_duration_seconds = pulse_visual_duration_seconds
	_finish_emission = finish_emission
	_on_steps_applied = on_steps_applied
	_on_form_change = on_form_change


## 执行一次 RAY emission（M4-E2.1）：接收 immutable preflight Ray fire data，执行传播 + 应用副作用 + 安排完成。
## [br]输入：tree 为当前 SceneTree（create_timer 用，dispatch 作用域内使用，不持久持有）；
## [br]  generation / emission_id 为本次 emission 的 immutable 身份快照（真值仍为 LRC._runtime_generation；emission_id 由 LRC allocate）；
## [br]  start_cell / direction 为 immutable Ray 起点与方向（LRC._dispatch_emission 从 request_fire 快照传入，dispatch 后修改 FixedEmitter 不影响本 Ray）。
## [br]返回：true = Ray 已执行 + 完成已安排；false = immutable direction 非法（build 失败），交调用方 rollback（无视觉/无 timer 残留）。
## [br]副作用（成功时）：逐格 show_step + try_activate_crystal_at；on_steps_applied 回调；SceneTreeTimer 安排 finish_emission。
## [br]边界：不 allocate/mark_finished emission（LRC 已 allocate）；不判 RunState；不清其它 emission 视觉；不重读 FixedEmitter。
func dispatch(
		tree: SceneTree,
		generation: int,
		emission_id: int,
		start_cell: Vector2i,
		direction: Vector2i
) -> bool:
	# 防御性 immutable direction 校验（clean failure boundary）：正常路径 LRC 已 preflight，此处失败仅白盒注入/异常路径，交 LRC rollback。
	if not _LightEmissionTypes.is_valid_direction(direction):
		push_error("RayEmissionDriver: dispatch 拒绝非法 immutable direction %s（emission=%d），无视觉/无 timer 残留。" % [direction, emission_id])
		return false
	# 传播计算在 RayExecutionModule 内无副作用完成；本驱动只应用结果。
	var execution_result: _RayExecutionResult = _RayExecutionModule.execute(
		start_cell,
		direction,
		_max_propagation_steps,
		_light_world_query,
		emission_id,
		generation
	)
	if execution_result.reached_step_limit:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")
	# 逐格按结果顺序应用副作用（同一格先 show_step 再 try_activate_crystal_at）；emission_id 使本段视觉归属本次 Ray emission。
	_apply_ray_execution_result(execution_result, emission_id, generation)
	# FORM_CHANGE 转换载荷透传（阶段C-01）：转换器格 = steps 末格（模块仅在记录该格后才可能携带载荷）。
	#   新 emission 的生成守卫（generation/pulse/链深度）全部在 spawner 内，driver 不复制。
	if execution_result.form_change_target != -1 and _on_form_change.is_valid() and not execution_result.steps.is_empty():
		_on_form_change.call(
			generation,
			emission_id,
			execution_result.form_change_target,
			execution_result.steps[execution_result.steps.size() - 1].cell,
			execution_result.form_change_direction)
	# 应用完 steps：回调 LRC 刷新完成标签（driver 不读 Objective 完成真值）。
	_on_steps_applied.call()
	# 启动异步结束（捕获 immutable generation + emission_id；过期/非活动守卫在 LRC._finish_emission）。
	_schedule_completion(tree, generation, emission_id)
	return true


## 逐格按 steps 顺序应用副作用：同一格先创建光路视觉（per-emission，携带 emission_id/generation）再应用水晶命中；不重新计算路径、不改占用/机关/RunState/库存。
## [br]emission_id 使本段视觉归属本次 Ray emission（新 Ray 不清旧 Ray；本 Ray finish 只清自身）；generation 为 visual version metadata（非 gameplay 真值）。
## [br]顺序冻结：show_step 必须早于 apply_hit 水晶命中（与旧 fire_light 循环一致；源码扫描测试锁定本顺序）。
## [br]水晶命中（S3-05）：经 ObjectiveHitContext.create_for_ray(cell, 入射方向, emission_id, generation, 到达色) 构造不可变命中事实交
## [br]  ObjectiveController.apply_hit——未绑定模型等价旧 try_activate_crystal_at 原型激活；绑定模型按条件路由（通过才点亮）。
## [br]反射格（D7-R5 视觉修复）：某格的进入方向与下一步的进入方向不同 = 该格机关改向（镜面）——
##   本格改画两段半光束（入射半段 + 出射半段，经 show_reflection_step 在格中心拼出拐角），
##   不再画贯穿整格的入射段（旧画法使光束视觉上穿过镜面格远端、且拐角处留半格断口，用户 GUI 验收截图暴露）。
##   改向判定纯读相邻 step 事实（steps[i].incoming_direction != steps[i+1].incoming_direction），不重查机关、不复制反射算法。
func _apply_ray_execution_result(result: _RayExecutionResult, emission_id: int, generation: int) -> void:
	for i: int in range(result.steps.size()):
		var step = result.steps[i]
		# 下一步进入方向与本步不同 = 本格为反射格（机关已在本格改向，出射方向从下一步起生效）。
		var next_incoming: Vector2i = (
			result.steps[i + 1].incoming_direction
			if i + 1 < result.steps.size()
			else step.incoming_direction
		)
		if next_incoming != step.incoming_direction:
			_light_visual_controller.show_reflection_step(
				emission_id, generation, step.cell, step.incoming_direction, next_incoming)
		else:
			_light_visual_controller.show_step(emission_id, generation, step.cell, step.incoming_direction)
		if step.has_crystal:
			# S3-05 正式命中点：命中事实（含 step.color 到达色）经 ObjectiveHitContext.create_for_ray 交 ObjectiveController.apply_hit
			#（未绑定模型时 apply_hit 等价水晶原型激活；绑定模型时按条件路由，通过才点亮）。
			var hit: Variant = _ObjectiveHitContext.create_for_ray(
				step.cell, step.incoming_direction, emission_id, generation, step.color)
			if hit != null:
				_objective_controller.apply_hit(hit)


## 等待 Ray 视觉持续时间后回调 LRC finish_emission（generation, emission_id）（M4-E2.1 per-emission；driver 管理 visual delay）。
## [br]过期（R / 新 epoch）或非活动脉冲或 emission 已结束的守卫**全部在 LRC._finish_emission 内**——driver 不持有 generation truth / RunState，
## [br]  故只负责“到期回调”，回调内的守卫与聚合结算归 LRC（不复制第二套守卫）。
func _schedule_completion(tree: SceneTree, expected_generation: int, emission_id: int) -> void:
	await tree.create_timer(_pulse_visual_duration_seconds).timeout
	# LRC 已释放（场景卸载 / 测试 cleanup）时 callable 失效，静默退出；不替代 generation/RunState 守卫。
	if not _finish_emission.is_valid():
		return
	_finish_emission.call(expected_generation, emission_id)
