class_name RayExecutionModule
extends RefCounted

## 普通光线执行模块（Day 1 D1-C）：把原 fire_light() 逐格传播循环迁出为无副作用纯计算——
## 逐格推进、查询边界/墙体/机关、调用 RayMechanismAdapter、更新方向与颜色、收集有序步骤（含每格是否有水晶）、判断停止原因与最大步数。
## 由核心 fire_light() 静态调用；不加入场景树、不持核心节点引用或 RunState。
## 顺序保真（以旧 fire_light() 循环为唯一依据）：同一格先记录视觉步骤与水晶格再处理机关方向；边界先于墙体；
## 镜面改向在进入镜面格后生效，不影响已记录入射方向；越界格与墙体格不进入结果；MAX_PROPAGATION_STEPS 计数与旧 while 一致。
## 边界：非法方向由调用方调用前校验；模块内 direction 不会变为 ZERO——Adapter 只在非零反射时返回 REDIRECT，零反射转入 BLOCK。


# 用 preload 引用类型，避开 MCP run_project 不重建全局 class_name 缓存的问题；嵌套枚举通过本常量限定访问。
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _RayMechanismAdapter: GDScript = preload("res://gameplay/light/ray_mechanism_adapter.gd")
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _RayInteractionContext: GDScript = preload(
	"res://gameplay/light/interaction/ray_interaction_context.gd"
)
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)


## 执行一次无副作用的普通光线传播，返回有序路径与停止原因；触顶 push_warning 由核心根据 reached_step_limit 复现。
## 逐格顺序与旧 fire_light() 一致：先算 next_cell，越界/墙体 break，否则记录步骤（含是否有水晶）再查机关；REDIRECT 改向下一轮，BLOCK break，CONTINUE 保持原方向。
## [br]emission_id / runtime_generation 为本次发射身份与运行代快照（AF-02：构造 RayInteractionContext 的 Shared Facts）；
##   模块内维护 current_color（ColorValue，初始 WHITE），与 direction 同构，逐格被机关 COLOR_CHANGE 更新、从下一格起生效。
static func execute(
		start_cell: Vector2i,
		initial_direction: Vector2i,
		max_steps: int,
		world_query: _LightWorldQuery,
		emission_id: int,
		runtime_generation: int,
		initial_color: int = 0
) -> _RayExecutionResult:
	var result: _RayExecutionResult = _RayExecutionResult.new()
	var current_cell: Vector2i = start_cell
	var direction: Vector2i = initial_direction
	# 光线当前颜色（ColorValue，初始 WHITE=0）；与 direction 同构，逐格被 COLOR_CHANGE 更新。
	# C-08：initial_color 供派生分支 emission 继承入射色（机关分支 color 盖章来源），主发射默认 WHITE 不变。
	var current_color: int = initial_color
	var steps: int = 0
	# C-08：本迭代进入的格数（REDIRECT_CROSS 透明跨格时为 2——机关格 + 跨界格），用于尾部步数推进。
	var cells_entered: int = 1

	while steps < max_steps:
		var next_cell: Vector2i = current_cell + direction

		# 1. 边界停止：越界格不进入结果。
		if not world_query.is_in_bounds(next_cell):
			result.stop_reason = _RayExecutionResult.StopReason.OUT_OF_BOUNDS
			break

		# 2. 墙体停止：墙体格不进入结果。
		if world_query.is_wall_cell(next_cell):
			result.stop_reason = _RayExecutionResult.StopReason.WALL
			break

		# 3-5. 光进入 next_cell：先记录该格步骤（入射方向、是否有水晶、到达色）再处理机关方向，保持旧循环顺序。
		result.add_step(next_cell, direction, world_query.has_crystal_at(next_cell), current_color)

		# 6-8. 进入机关格后再更新方向：REDIRECT 改向从下一格起生效，BLOCK 停止，CONTINUE 保持原方向。
		# get_light_mechanism_at 一次取得机关节点；无机关或未登记正式节点返回 null，跳过评估等价 CONTINUE。
		# AF-02：光到达机关格先构造不可变 RayInteractionContext（Shared Facts 快照），再经 Adapter 正式分发。
		var mechanism: Variant = world_query.get_light_mechanism_at(next_cell)
		if mechanism != null:
			var ray_context: Variant = _RayInteractionContext.create(
				next_cell, direction, emission_id, runtime_generation, current_color)
			var mech_result: _RayMechanismResult
			if ray_context == null:
				if OS.is_debug_build():
					print_debug("RayExecutionModule: Context 构造失败，本轮保持原方向。")
				mech_result = _RayMechanismResult.continue_with(direction)
			else:
				mech_result = _RayMechanismAdapter.evaluate(mechanism, ray_context)
			match mech_result.kind:
				_RayMechanismResult.Kind.REDIRECT:
					direction = mech_result.outgoing_direction
				_RayMechanismResult.Kind.REDIRECT_CROSS:
					# C-08 穿邻格透明步进（双格平面镜）：cross_direction 邻格记入路径但不再判机关
					#   （同机关跨格不重复触发），随后沿 outgoing_direction 继续；
					#   跨界格越界 / 墙体按对应停止原因终止（与普通步进同形）。本迭代共进入两格。
					var crossed_cell: Vector2i = next_cell + mech_result.cross_direction
					if not world_query.is_in_bounds(crossed_cell):
						result.stop_reason = _RayExecutionResult.StopReason.OUT_OF_BOUNDS
						break
					if world_query.is_wall_cell(crossed_cell):
						result.stop_reason = _RayExecutionResult.StopReason.WALL
						break
					result.add_step(crossed_cell, mech_result.cross_direction, world_query.has_crystal_at(crossed_cell), current_color)
					direction = mech_result.outgoing_direction
					current_cell = crossed_cell
					cells_entered = 2
				_RayMechanismResult.Kind.FORM_CHANGE:
					# 阶段C-01 光形式转换器：转换发生在机关格内（该格步骤已记录于 steps 末尾），
					#   传播按 MECHANISM_BLOCK 终止并携带转换载荷（目标形态+输出方向）；新 emission 由执行适配层生成。
					result.stop_reason = _RayExecutionResult.StopReason.MECHANISM_BLOCK
					result.form_change_target = mech_result.target_form
					result.form_change_direction = mech_result.outgoing_direction
					break
				_RayMechanismResult.Kind.BLOCK:
					result.stop_reason = _RayExecutionResult.StopReason.MECHANISM_BLOCK
					break
				_:
					pass # CONTINUE：保持原方向，与旧循环 incoming_direction 返回一致。

			# 颜色变更与 REDIRECT 改向一样，从下一格起生效；BLOCK 已 break 跳出，不消费。
			if mech_result.color_change != _RayColor.ColorValue.NONE:
				current_color = mech_result.color_change
			# C-08：分光分支载荷收集——复制为独立 BranchSpec 并按入射状态盖章继承色（机关侧构造恒 NONE）；
			#   仅 CONTINUE / REDIRECT 可能携带（Contract validate 强制；BLOCK / FORM_CHANGE 已 break，REDIRECT_CROSS 禁带）。
			#   传播全程累积（途经机关各自追加）；派生 emission 由执行适配层生成，本模块不生成。
			for branch in mech_result.spawned_branches:
				result.add_spawned_branch(_LightInteractionResult.make_branch_spec(
					branch.source_cell, branch.direction, current_color))

		# 9. 推进当前位置；下一轮使用反射后的 direction。
		#    C-08：REDIRECT_CROSS 已在 arm 内推进到跨界格（本迭代进入两格）；其余情形推进到 next_cell。
		if cells_entered == 1:
			current_cell = next_cell
		steps += cells_entered
		cells_entered = 1

	# 达到步数上限时记录 STEP_LIMIT；push_warning 由核心根据 reached_step_limit 复现。
	if steps >= max_steps:
		result.stop_reason = _RayExecutionResult.StopReason.STEP_LIMIT
		result.reached_step_limit = true

	return result
