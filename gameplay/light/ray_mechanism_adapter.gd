class_name RayMechanismAdapter
extends RefCounted

## 普通光线机关光学适配器（AF-02 收口）：经 LightInteractionContract 正式分发机关对入射方向的光学响应，
## 把 LightInteractionResult 映射回 RayMechanismResult（CONTINUE/REDIRECT/BLOCK）。
## 由 RayExecutionModule 在逐格传播中调用；不加入场景树、不持核心节点引用或 RunState、无副作用。
## 边界：null 与未声明契约机关保持原方向（CONTINUE）；已登记但失效节点停止（BLOCK）；
##   机关返回不合法 Result 时由 Contract 层降级为透明 CONTINUE，本类不推测光学行为、不因类型未知崩溃。


# 用 preload 引用类型，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")
const _LightInteractionContract: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_contract.gd"
)
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)


## 评估机关节点对入射方向的光学响应（AF-02 正式契约分发）。
## [br]输入：mechanism 为 world_query.get_light_mechanism_at 返回的机关节点 Variant；
##   ray_context 为 RayExecutionModule 构造的 RayInteractionContext（不可变事实快照）。
## [br]返回：null → CONTINUE；已失效节点 → BLOCK；未声明 RAY 契约 → 透明 CONTINUE；
##   契约机关 → 其 interact_ray 经校验的 Decision 映射（CONTINUE/REDIRECT/BLOCK）。
## [br]副作用：无；Typed Effects 中 PARTICLE_SPEED_DELTA 对 RAY 形态不合法、由 Contract 校验拒绝；
##   OUTPUT_EVENT 本批仅经 Result 承载与校验，消费留 Control 域（P1），本类不处理；
##   COLOR_CHANGE 经 mech_result.color_change 透传给传播核心消费。
static func evaluate(
		mechanism: Variant,
		ray_context: Variant
) -> _RayMechanismResult:
	var incoming_direction: Vector2i = ray_context.get_incoming_direction()

	# 无正式机关节点：保持原方向（既有行为）。
	if mechanism == null:
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 机关节点为空，本轮保持原方向。")
		return _RayMechanismResult.continue_with(incoming_direction)

	# 已登记但节点已失效：安全停止传播。
	if not is_instance_valid(mechanism):
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 机关节点已失效，停止传播。")
		return _RayMechanismResult.block()

	# 正式契约分发（AF-02）：未声明 RAY 的机关（含未知类型）由 Contract 判透明，不再依赖具体类名。
	var interaction: _LightInteractionResult = _LightInteractionContract.dispatch_ray(mechanism, ray_context)
	var mech_result: _RayMechanismResult
	match interaction.decision:
		_LightInteractionResult.Decision.REDIRECT:
			mech_result = _RayMechanismResult.redirect_to(interaction.redirect_direction)
		_LightInteractionResult.Decision.FORM_CHANGE:
			# 阶段C-01 光形式转换器：转换载荷（目标形态+输出方向）经本结果透传给传播核心，
			#   新 emission 的生成由执行适配层（RayEmissionDriver 回调 → FormChangeEmissionSpawner）消费，本类不生成。
			mech_result = _RayMechanismResult.form_change(interaction.target_form, interaction.redirect_direction)
		_LightInteractionResult.Decision.BLOCK:
			if OS.is_debug_build():
				print_debug("RayMechanismAdapter: 机关 BLOCK 停止传播。")
			mech_result = _RayMechanismResult.block()
		_:
			mech_result = _RayMechanismResult.continue_with(incoming_direction)
	# 透传颜色变更（改动 4）：COLOR_CHANGE 效果经 color_change 字段交给传播核心消费。
	mech_result.color_change = interaction.get_color_change()
	return mech_result
