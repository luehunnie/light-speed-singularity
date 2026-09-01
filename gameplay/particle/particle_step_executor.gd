class_name ParticleStepExecutor
extends RefCounted

## 光粒单步执行器（D7-4 B2）。
## 职责：对单颗活动光粒，按冻结顺序纯同步求值一次传播步，返回一个纯 StepResult，描述“是否进入下一格 / 进入何格 /
##   离开方向 / 速度增量 / 是否踩到水晶 / 终止原因”，作为 scheduler 决定 apply_move / terminate 的唯一只读依据。
## 位置：位于 gameplay/particle 下；本类是“单步求值”的唯一入口，介于 ParticleRuntimeState（纯数据）与 scheduler（推进器）之间。
## 依赖：通过 preload 引用 ParticleRuntimeState 取只读 getter；通过 preload 引用 ParticleMechanismAdapter 把格内机关翻译成通用效果；
##   world_query 参数为 Variant 鸭子类型（须提供 is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at 四个只读方法），
##   正式运行传入 LightWorldQuery，测试传入 fixtures 下的等价只读 fake，二者方法契约一致。
## 不负责：修改 state（绝不调 apply_move / terminate）、点亮 Crystal、修改 Objective、调 scheduler、判断具体加速器 / 减速器类、
##   计算下一步 due Tick、SpeedTier 饱和、Tick 推进、Node / Timer / 视觉 / 异步。
## 边界条件：单步顺序冻结为 ① state 须 active ② next_cell = cell + direction ③ 越界 → TERMINATE(OUT_OF_TERRAIN)
##   ④ 墙体 → TERMINATE(WALL) ⑤ 进入 next_cell ⑥ 查 has_crystal_at ⑦ 查 get_light_mechanism_at ⑧ 交 Adapter
##   ⑧b 机关 BLOCK（continue_motion=false）→ TERMINATE(MECHANISM_BLOCK)（被阻挡光粒停在机关格外，与 WALL 同形）
##   ⑨ 返回 StepResult；
##   ①③④⑧b 任一 TERMINATE 分支 speed_delta=0、has_crystal=false、outgoing_direction=入射方向、next_step_blocked=false；
##   ①③④ 不查水晶 / 机关；⑧b 查机关后终止（水晶与阻挡型机关不可同格，has_crystal=false）；
##   MOVE 分支附 M4-E4 确定性前瞻 next_step_blocked（entered_cell + outgoing_direction 是否墙 / 越界，供 Visual 边界即时消失）；
##   本类无任何可变实例字段，evaluate_step 可被多 scheduler / 多线程上下文（GDScript 单线程）安全复用。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


const _ParticleRuntimeState: GDScript = preload(
	"res://gameplay/particle/particle_runtime_state.gd"
)
const _ParticleMechanismAdapter: GDScript = preload(
	"res://gameplay/particle/particle_mechanism_adapter.gd"
)
const _ParticleInteractionContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)


## 单步求值结果类型。MOVE=成功进入下一格；TERMINATE=本步终止传播。
enum Outcome {
	MOVE,
	TERMINATE,
}


## 终止原因。NONE=未终止（MOVE 时）；INACTIVE=state 已不活动；OUT_OF_TERRAIN=越出地形；WALL=撞墙；
## MECHANISM_BLOCK=机关 BLOCK 决策（光屏障等阻挡型机关；被阻挡光粒停在机关格外，与 WALL 同形）。
enum TerminationReason {
	NONE,
	INACTIVE,
	OUT_OF_TERRAIN,
	WALL,
	MECHANISM_BLOCK,
}


## 单步求值纯结果（只读数据载体）。
## [br]outcome：MOVE / TERMINATE。
## [br]entered_cell：MOVE 时为成功进入的 next_cell；TERMINATE 时为被阻挡的 next_cell（INACTIVE 时为原 cell），仅 MOVE 时是“已进入”事实。
## [br]outgoing_direction：MOVE 时为 Adapter 给出的离开方向（镜面机关按正式规则改向；其余机关为入射方向）；TERMINATE 时为入射方向。
## [br]speed_delta：MOVE 时为机关速度增量；TERMINATE 时为 0。
## [br]has_crystal：MOVE 时为是否踩到水晶（仅事件意义，不点亮）；TERMINATE 时为 false。
## [br]termination_reason：MOVE 时 NONE；TERMINATE 时为具体原因。
## [br]next_step_blocked：仅 MOVE 时有意义——本步离开方向上的再下一格（entered_cell + outgoing_direction）
##   是否为墙 / 越界（M4-E4 墙体边界消失：确定性前瞻，供 Visual 在接触边界时即时消失，不改本类任何终止 / 提交语义）；
##   TERMINATE 时恒 false（光粒本步已终止，前瞻无意义）。
## [br]form_change_target / form_change_direction（阶段C-01）：TERMINATE(MECHANISM_BLOCK) 且携带 FORM_CHANGE 载荷时
##   为目标形态（LightForm 值）与出射八方向（转换发生在机关格内，entered_cell 即转换器格）；其余分支恒 -1 / ZERO。
class StepResult:
	extends RefCounted

	var outcome: int = Outcome.MOVE
	var entered_cell: Vector2i = Vector2i.ZERO
	var outgoing_direction: Vector2i = Vector2i.ZERO
	var speed_delta: int = 0
	var has_crystal: bool = false
	var termination_reason: int = TerminationReason.NONE
	var next_step_blocked: bool = false
	var form_change_target: int = -1
	var form_change_direction: Vector2i = Vector2i.ZERO


## 对单颗活动光粒求值一次传播步（纯同步、无副作用、绝不修改 state）。
## [br]输入：state 为待求值光粒（只读 getter 被调用，绝不写）；world_query 为只读世界查询（Variant 鸭子类型，
##   须实现 is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at）。
## [br]返回：一个 StepResult，按冻结顺序描述本步结局；绝不调 state.apply_move / state.terminate。
## [br]副作用：无；不修改 state、world_query、机关、Crystal、Objective、scheduler 或任何系统状态。
## [br]失败：不会失败；state 非活动时返回 TERMINATE(INACTIVE)，其余路径返回确定 StepResult。
## [br]边界：本函数只“求值”，不“提交”——是否 apply_move / terminate 由 scheduler 决定；
##   不判断具体加速器 / 减速器类（机关识别委托 Adapter），不计算下一步 due Tick。
func evaluate_step(
		state: _ParticleRuntimeState,
		world_query: Variant
) -> StepResult:
	var result: StepResult = StepResult.new()

	# ① state 须 active——非活动直接终止，不计算 next_cell。
	if not state.is_active():
		result.outcome = Outcome.TERMINATE
		result.termination_reason = TerminationReason.INACTIVE
		result.entered_cell = state.get_cell()
		result.outgoing_direction = state.get_direction()
		result.speed_delta = 0
		result.has_crystal = false
		return result

	# ② next_cell = cell + direction。
	var next_cell: Vector2i = state.get_cell() + state.get_direction()

	# ③ 越界 → TERMINATE(OUT_OF_TERRAIN)。
	if not world_query.is_in_bounds(next_cell):
		result.outcome = Outcome.TERMINATE
		result.termination_reason = TerminationReason.OUT_OF_TERRAIN
		result.entered_cell = next_cell
		result.outgoing_direction = state.get_direction()
		result.speed_delta = 0
		result.has_crystal = false
		return result

	# ④ 墙体 → TERMINATE(WALL)。
	if world_query.is_wall_cell(next_cell):
		result.outcome = Outcome.TERMINATE
		result.termination_reason = TerminationReason.WALL
		result.entered_cell = next_cell
		result.outgoing_direction = state.get_direction()
		result.speed_delta = 0
		result.has_crystal = false
		return result

	# ⑤ 成功进入 next_cell；⑥ 查水晶；⑦ 查机关；⑧ 构造不可变 Context 后交 Adapter 正式分发（AF-02 §23 时序）。
	var has_crystal: bool = world_query.has_crystal_at(next_cell)
	var mechanism: Variant = world_query.get_light_mechanism_at(next_cell)
	var particle_context: Variant = _ParticleInteractionContext.create(
		next_cell,
		state.get_direction(),
		state.get_emission_id(),
		state.get_generation(),
		state.get_speed_tier(),
		state.get_runtime_id()
	)
	var effect
	if particle_context == null:
		# 防御：state 不变量被破坏（正常不可达）时按透明通过，不中断求值。
		effect = _ParticleMechanismAdapter.MechanismEffect.new()
		effect.outgoing_direction = state.get_direction()
	else:
		effect = _ParticleMechanismAdapter.adapt(mechanism, particle_context)

	# ⑧b 机关 BLOCK（光屏障等阻挡型机关）：光粒撞击屏障边框/薄膜能量不足，于机关格外停止（与 WALL 同形，
	#     不进入阻挡格；方向/速度门槛判定已由机关经 Context 事实完成）。
	#     FORM_CHANGE（阶段C-01 光形式转换器）同形终止：机关在格内完成形态转换，载荷（目标形态+出射方向）
	#     经 StepResult 透传，新 emission 由执行适配层生成；普通阻挡机关载荷恒 -1 / ZERO。
	if not effect.continue_motion:
		result.outcome = Outcome.TERMINATE
		result.termination_reason = TerminationReason.MECHANISM_BLOCK
		result.entered_cell = next_cell
		result.outgoing_direction = state.get_direction()
		result.speed_delta = 0
		result.has_crystal = false
		result.next_step_blocked = false
		result.form_change_target = effect.form_change_target
		result.form_change_direction = effect.form_change_direction
		return result

	# ⑨ 返回纯 StepResult（MOVE）。M4-E4：确定性前瞻——本步离开方向上的再下一格是否墙 / 越界，
	#    供 Visual 在接触边界时即时消失；不改本步 MOVE 语义（本格照常进入，终止仍由下一次求值裁定）。
	var beyond_cell: Vector2i = next_cell + effect.outgoing_direction
	result.outcome = Outcome.MOVE
	result.entered_cell = next_cell
	result.outgoing_direction = effect.outgoing_direction
	result.speed_delta = effect.speed_delta
	result.has_crystal = has_crystal
	result.termination_reason = TerminationReason.NONE
	result.next_step_blocked = (
		not world_query.is_in_bounds(beyond_cell)
		or world_query.is_wall_cell(beyond_cell)
	)
	return result
