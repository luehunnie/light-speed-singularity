class_name ParticleMechanismAdapter
extends RefCounted

## 光粒机关效果适配器（D7-4 B2；D7-R5 加镜面改向；AF-02 收口为正式契约分发）。
## 职责：经 LightInteractionContract 正式分发（interact_particle + LightInteractionResult），
##   把机关的一次交互结果转换成光粒通用效果，作为 executor 与具体机关类之间的唯一边界。
##   正式契约面 = get_light_interaction_forms 声明 + interact_particle 入口 + LightInteractionResult（Guide §21）；
##   旧 has_method("reflect_direction") / has_method("get_speed_modifier") 鸭子探测已收口删除，
##   新增同类速度 / 改向机关无需改本类或 executor 的类型分支。
## 位置：位于 gameplay/particle 下；本类是“机关交互结果 → 光粒通用效果”的唯一适配入口。
## 依赖：LightInteractionContract / LightInteractionResult（preload）；输入 mechanism 为 Variant
##   （null / Object / 未知类型一律安全降级为透明通过）。
## 不负责：修改 ParticleRuntimeState、SpeedTier 饱和（由 ParticleMotionRules / Runtime 负责）、Tick 计算（由 scheduler 负责）、
##   点亮 Crystal、Objective、视觉、Node 生命周期。
## 边界条件：null / 已释放 / 非契约机关（未声明 PARTICLE）一律“继续传播 + outgoing_direction=incoming + speed_delta=0”
##   （Guide §21 未声明形态 = 透明）；机关返回不合法 Result 由 Contract 层降级为透明 CONTINUE；
##   SpeedDelta 只读取机关请求的 ±1 档位增量，不 clamp、不计算下一步 Tick（§23 从下一传播步影响调度）；
##   OUTPUT_EVENT 本批仅经 Result 承载与校验，消费留 Control 域（P1），本类不处理；
##   BLOCK 决策映射 continue_motion=false（光屏障起被 executor 消费 → TERMINATE(MECHANISM_BLOCK)）。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


const _LightInteractionContract: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_contract.gd"
)
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)


## 光粒机关效果（最小结构，为未来 Barrier 预留）。
## [br]continue_motion：是否继续传播（Contract BLOCK 决策置 false；光屏障六向非轴/能量不足时为 false）。
## [br]outgoing_direction：离开机关格的传播方向（契约机关 REDIRECT 改向；其余机关为入射方向）。
## [br]speed_delta：速度档位增量（契约机关 PARTICLE_SPEED_DELTA 的 ±1；其余为 0）。
class MechanismEffect:
	extends RefCounted

	## 是否继续传播。BLOCK 决策机关（光屏障等）置 false；透明/改向/速度机关为 true。
	var continue_motion: bool = true
	## 离开机关格的传播方向。契约机关可 REDIRECT 改向；透明机关为入射方向。
	var outgoing_direction: Vector2i = Vector2i.ZERO
	## 速度档位增量（+1/-1/0）。机关仅经 PARTICLE_SPEED_DELTA 效果请求。
	var speed_delta: int = 0


## 把机关的一次正式交互结果转换成光粒通用效果（纯同步、无副作用、不修改任何 state）。
## [br]输入：mechanism 为 world_query.get_light_mechanism_at(cell) 返回的 Variant（null / 已释放 / 未知机关 / 契约机关）；
##   particle_context 为 ParticleStepExecutor 构造的 ParticleInteractionContext（不可变事实快照，本函数不修改）。
## [br]返回：一个 MechanismEffect——
##   null / 已释放 / 非契约机关 / 未声明 PARTICLE / 不合法 Result → continue_motion=true、outgoing_direction=incoming、speed_delta=0；
##   契约机关 → Decision 映射（REDIRECT 改 outgoing_direction；BLOCK 置 continue_motion=false）+ 首个
##   PARTICLE_SPEED_DELTA 映射 speed_delta（±1；无该效果则 0）。
## [br]副作用：无；不读取或修改 ParticleRuntimeState，不 clamp SpeedTier，不计算 Tick，不点亮 Crystal，不调 Objective，不触碰视觉。
## [br]失败：不会失败；对任意 Variant 输入均返回一个安全的默认或机关效果。
## [br]边界：本函数只“翻译”机关交互结果，不“解释” delta——是否 +1 后饱和、何时生效由 scheduler 负责；
##   改向后的 Tick 与前瞻由 scheduler / executor 以 outgoing_direction 统一计算（斜向 Tick 表天然生效）。
static func adapt(mechanism: Variant, particle_context: Variant) -> MechanismEffect:
	var effect: MechanismEffect = MechanismEffect.new()
	var incoming_direction: Vector2i = particle_context.get_incoming_direction()
	effect.continue_motion = true
	effect.outgoing_direction = incoming_direction
	effect.speed_delta = 0
	if mechanism == null:
		return effect
	if not is_instance_valid(mechanism):
		return effect
	if not (mechanism is Object):
		return effect
	# AF-02 正式契约分发：未声明 PARTICLE / 不合法 Result 由 Contract 层判透明（返回 CONTINUE）。
	var interaction: _LightInteractionResult = _LightInteractionContract.dispatch_particle(
		mechanism, particle_context)
	match interaction.decision:
		_LightInteractionResult.Decision.REDIRECT:
			effect.outgoing_direction = interaction.redirect_direction
		_LightInteractionResult.Decision.BLOCK:
			effect.continue_motion = false
		_:
			pass
	effect.speed_delta = interaction.get_speed_delta()
	return effect
