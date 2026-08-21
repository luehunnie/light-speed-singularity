class_name ParticleInteractionContext
extends LightInteractionContext

## PARTICLE 形态交互 Context（冻结 Guide §19.1 / §19.3）：离散光粒进入机关格时的不可变事实快照。
## Shared Facts（§19.2）之外附 Particle-only Facts（§19.3 冻结）：speed_tier / particle_runtime_id。
## speed_tier 取 ParticleMotionRules.SpeedTier 值（速度单一真相不自建第二份枚举）；
## 由 Runtime 传播层（ParticleStepExecutor）在机关一次计算前构造；机关只读。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

## 光粒当前速度档（ParticleMotionRules.SpeedTier 值）。
var _speed_tier: int
## 光粒运行身份（scheduler 单调 runtime_id）。
var _particle_runtime_id: int


## 构造 PARTICLE 交互 Context（唯一正式入口）。
## [br]输入：cell / incoming_direction（合法八方向）/ emission_id / runtime_generation 为 Shared Facts；
##   speed_tier 须为合法 SpeedTier；particle_runtime_id 须 >=0。
## [br]返回：合法返回 ParticleInteractionContext；任一事实非法 push_error 并返回 null（调用方按无交互降级）。
static func create(
		cell: Vector2i,
		incoming_direction: Vector2i,
		emission_id: int,
		runtime_generation: int,
		speed_tier: int,
		particle_runtime_id: int
) -> ParticleInteractionContext:
	if not _ParticleMotionRules.is_valid_speed_tier(speed_tier):
		push_error("ParticleInteractionContext：非法 speed_tier %d，拒绝构造。" % [speed_tier])
		return null
	if particle_runtime_id < 0:
		push_error("ParticleInteractionContext：非法 particle_runtime_id %d，拒绝构造。" % [particle_runtime_id])
		return null
	var context: ParticleInteractionContext = ParticleInteractionContext.new()
	if not context._setup_shared(
			cell,
			incoming_direction,
			_LightEmissionTypes.LightForm.PARTICLE,
			emission_id,
			runtime_generation
	):
		return null
	context._speed_tier = speed_tier
	context._particle_runtime_id = particle_runtime_id
	return context


## 光粒当前速度档（ParticleMotionRules.SpeedTier 值，只读）。
func get_speed_tier() -> int:
	return _speed_tier


## 光粒运行身份（只读）。
func get_particle_runtime_id() -> int:
	return _particle_runtime_id
