class_name ParticleSnapshotState
extends RefCounted

## 活动 Particle 快照契约（D7-R1 Snapshot v1）。
##
## 职责：
## 保存一次采样时刻某颗活动光粒的只读事实——runtime_id（光粒唯一身份，ParticleScheduler 单调分配，跨 generation 不回拨）、
## 所属 emission_id、generation、cell、direction、speed_tier、step_started_tick、next_move_tick、active；
## 并提供只读校验与独立深复制。字段与 ParticleScheduler.get_particle_state_snapshot detached 八字段一一对应，
## 附加 emission_id 关联（由 registry 双向映射提供），不使用 Node.name / instance_id。
##
## 在当前系统中的位置：
## gameplay/diagnostics/snapshot 下快照数据契约，由 RuntimeSnapshotSampler 从 runtime detached 事实构造，
## 随 RuntimeSnapshotData 一并序列化。
##
## 主要依赖：
## Godot 内建类型（int、bool、Vector2i）；不依赖节点、场景树、玩法对象或文件系统。
##
## 明确不负责：
## 采集数据、推进 Tick、终止光粒、修改 scheduler、序列化 JSON。


## 光粒唯一身份（ParticleScheduler 分配，>=0，跨 generation 单调不回拨）。
var runtime_id: int
## 所属 emission_id（registry 反向映射；活动光粒必属某条活动 emission，>=1）。
var emission_id: int
## 光粒 generation（emit 时 scheduler 绑定的镜像标签，与所属 emission 的 generation 一致）。
var generation: int
## 光粒当前逻辑格。
var cell: Vector2i
## 光粒当前传播方向（单位向量）。
var direction: Vector2i
## 光粒速度档位（ParticleMotionRules.SpeedTier 数值）。
var speed_tier: int
## 本传播步开始时的绝对整数 Tick。
var step_started_tick: int
## 下一次移动应发生的绝对整数 Tick（authoritative timing）。
var next_move_tick: int
## 光粒是否仍活动。
var active: bool


## 构造一份活动光粒快照；仅赋值（全为值类型），校验统一由 validate() 负责。
func _init(
		p_runtime_id: int,
		p_emission_id: int,
		p_generation: int,
		p_cell: Vector2i,
		p_direction: Vector2i,
		p_speed_tier: int,
		p_step_started_tick: int,
		p_next_move_tick: int,
		p_active: bool
) -> void:
	runtime_id = p_runtime_id
	emission_id = p_emission_id
	generation = p_generation
	cell = p_cell
	direction = p_direction
	speed_tier = p_speed_tier
	step_started_tick = p_step_started_tick
	next_move_tick = p_next_move_tick
	active = p_active


## 只读校验；返回全部中文错误，无问题时为空数组。不修改数据、不 push_error、不抛异常。
## [br]边界：一次返回全部问题；runtime_id >=0；emission_id >=1；generation >=0；方向非零且分量绝对值不超过 1；
## step_started_tick / next_move_tick 非负。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	if runtime_id < 0:
		problems.append("ParticleSnapshotState：runtime_id 为负，必须为非负（ParticleScheduler 从 0 起单调分配）。")
	if emission_id < 1:
		problems.append("ParticleSnapshotState：emission_id 必须 >=1（活动光粒必属某条活动 emission）。")
	if generation < 0:
		problems.append("ParticleSnapshotState：generation 为负，必须为非负。")
	if direction == Vector2i.ZERO:
		problems.append("ParticleSnapshotState：direction 为零向量，必须为非零方向。")
	if absi(direction.x) > 1 or absi(direction.y) > 1:
		problems.append("ParticleSnapshotState：direction 分量绝对值超过 1，必须为单位方向向量。")
	if step_started_tick < 0:
		problems.append("ParticleSnapshotState：step_started_tick 为负，必须非负。")
	if next_move_tick < 0:
		problems.append("ParticleSnapshotState：next_move_tick 为负，必须非负。")
	return problems


## 返回全新独立深副本（全为值类型字段，逐字段相等且互不影响）。
func duplicate_state() -> ParticleSnapshotState:
	return ParticleSnapshotState.new(
		runtime_id, emission_id, generation, cell, direction,
		speed_tier, step_started_tick, next_move_tick, active)
