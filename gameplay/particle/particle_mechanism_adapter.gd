class_name ParticleMechanismAdapter
extends RefCounted

## 光粒机关效果适配器（D7-4 B2；D7-R5 加镜面改向）。
## 职责：把格内机关的公开能力转换成光粒通用效果，作为 executor 与具体机关类之间的唯一边界。
##   正式支持两类公共能力契约：镜面机关 reflect_direction(incoming_direction) -> Vector2i（改向不改速）与
##   速度机关 get_speed_modifier(incoming_direction) -> int（改速不改向）；
##   不依赖具体 SingleCellMirror / ParticleAccelerator / ParticleDecelerator 类名——仅以 has_method 判定。
## 位置：位于 gameplay/particle 下；本类是“机关公开能力 → 光粒通用效果”的唯一适配入口。
## 依赖：零游戏脚本依赖（不 preload 任何模块）；输入 mechanism 为 Variant（null / Object / 未知类型一律安全降级）。
## 不负责：修改 ParticleRuntimeState、SpeedTier 饱和（由 ParticleMotionRules 负责）、Tick 计算（由 scheduler 负责）、
##   运动中止（未来 Barrier）、点亮 Crystal、Objective、视觉、Node 生命周期。
## 边界条件：null / 已释放 / 未知机关一律“继续传播 + outgoing_direction=incoming + speed_delta=0”；
##   速度机关只读取其 get_speed_modifier 返回的 delta（+1/-1/0），不自行解释、不 clamp、不计算下一步 Tick；
##   镜面机关（has_method("reflect_direction")，D7-R5 GUI 验收修复）按正式规则（机关规则 §8“传播过程中镜面仍可改变方向”）
##   读取其 reflect_direction(incoming) 返回的八方向作为 outgoing_direction（speed_delta=0，不改速）；
##   反射返回 ZERO（非法入射；正式传播八方向恒合法，实际不可达）时安全降级为保持入射方向；
##   本类是纯同步无状态适配器，可由静态入口直接调用。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


## 光粒机关效果（最小结构，为未来 Barrier 预留）。
## [br]continue_motion：是否继续传播（未来 Barrier 可置 false 中止；本批恒为 true）。
## [br]outgoing_direction：离开机关格的传播方向（镜面机关按正式规则改向；其余机关为入射方向）。
## [br]speed_delta：速度档位增量（速度机关 +1/-1/0；镜面机关恒 0）。
class MechanismEffect:
	extends RefCounted

	## 是否继续传播。未来 Barrier 可置 false；本批恒为 true。
	var continue_motion: bool = true
	## 离开机关格的传播方向。未来 Mirror 可改向；本批恒为入射方向。
	var outgoing_direction: Vector2i = Vector2i.ZERO
	## 速度档位增量（+1/-1/0）。本批唯一会被机关改写的字段。
	var speed_delta: int = 0


## 把格内机关的公开能力转换成光粒通用效果（纯同步、无副作用、不修改任何 state）。
## [br]输入：mechanism 为 world_query.get_light_mechanism_at(cell) 返回的 Variant（可能是 null / 已释放 / 未知机关 / 速度机关）；
##   incoming_direction 为光粒进入该格时的入射八方向向量，本函数不修改它。
## [br]返回：一个 MechanismEffect——
##   null / 已释放 / 未知机关 → continue_motion=true、outgoing_direction=incoming_direction、speed_delta=0；
##   镜面机关（has_method("reflect_direction")）→ continue_motion=true、speed_delta=0、
##     outgoing_direction=int(mechanism.reflect_direction(incoming_direction))（非零八方向；零向量安全降级为入射方向）；
##   速度机关（has_method("get_speed_modifier")）→ continue_motion=true、outgoing_direction=incoming_direction、
##     speed_delta=int(mechanism.get_speed_modifier(incoming_direction))。
## [br]副作用：无；不读取或修改 ParticleRuntimeState，不 clamp SpeedTier，不计算 Tick，不点亮 Crystal，不调 Objective，不触碰视觉。
## [br]失败：不会失败；对任意 Variant 输入（含 null / 非 Object / 已释放）均返回一个安全的默认或机关效果。
## [br]边界：本函数只“翻译”机关公开能力，不“解释” delta——是否 +1 后饱和、何时生效由 scheduler 负责；
##   镜面改向后的 Tick 与前瞻由 scheduler / executor 以 outgoing_direction 统一计算（斜向 Tick 表天然生效）。
static func adapt(mechanism: Variant, incoming_direction: Vector2i) -> MechanismEffect:
	var effect: MechanismEffect = MechanismEffect.new()
	effect.continue_motion = true
	effect.outgoing_direction = incoming_direction
	effect.speed_delta = 0
	if mechanism == null:
		return effect
	if not is_instance_valid(mechanism):
		return effect
	if not (mechanism is Object):
		return effect
	# 镜面机关（D7-R5 GUI 验收修复）：按正式规则读取 reflect_direction 改向（不改速）。
	# 不依赖具体 SingleCellMirror 类名——与速度机关同样只认公共方法契约（has_method("reflect_direction")）。
	if mechanism.has_method("reflect_direction"):
		var reflected: Vector2i = mechanism.reflect_direction(incoming_direction)
		# 零向量 = 非法入射（正式传播八方向恒合法，实际不可达）：安全降级保持入射方向，不猜测光学行为。
		if reflected != Vector2i.ZERO:
			effect.outgoing_direction = reflected
		return effect
	if mechanism.has_method("get_speed_modifier"):
		effect.speed_delta = int(mechanism.get_speed_modifier(incoming_direction))
		return effect
	return effect
