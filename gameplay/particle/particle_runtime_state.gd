class_name ParticleRuntimeState
extends RefCounted

## 单颗光粒运行期纯数据状态（D7-4 B1 / B1.1）。
## 职责：承载一颗已发射光粒在整数 Tick 调度下的最小逻辑事实——身份、版本、当前格、方向、速度档位、
##   当前步起始 Tick、下一次移动 Tick、是否仍在活动——作为未来 scheduler / executor 的纯数据载体，
##   不持有 Node、场景树、Timer、视觉或 world query 引用。
##   并提供唯一正式状态推进入口 apply_move：校验并原子提交已算好的下一 cell / direction / speed_tier /
##   step_started_tick / next_move_tick，不负责 Tick 计算、terrain / wall / 机关 / world query / 视觉 / Crystal。
## 位置：位于 gameplay/particle 下；本类是“单颗光粒运行期逻辑快照”的唯一数据载体。
## 依赖：通过 preload 引用 ParticleMotionRules 取 SpeedTier 枚举与 ticks_for，引用 LightEmissionTypes 复用八方向合法性；
##   不定义第二份 SpeedTier 或方向合法集合，不引用 Node / 场景树 / Timer / _process / world query / 视觉 / 加速器 / 减速器。
## 不负责：runtime_id 分配（由未来 scheduler 分配）、Tick 推进、移动执行、碰撞、视觉、机关效果、复活已终止光粒。
## 边界条件：runtime_id 为外部稳定单调整数，不由本类分配，禁止 Node.name / NodePath / instance_id 作为业务身份；
##   generation 为创建时版本标签，不做递增保证；cell 为最近一次逻辑确认到达的格，允许任意 Vector2i（含负坐标）；
##   direction 必须是合法八方向，非法方向构造拒绝；current_tick 不复制进 state，仅用于推导 step_started_tick / next_move_tick；
##   next_move_tick 为绝对整数 Tick；active=false 代表终止，终止后不得复活（无任何置真入口）。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


const _ParticleMotionRules: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)


# ===== 字段（私有；通过 getter 只读暴露；活动置假入口 terminate / 状态推进入口 apply_move） =====

## 未来 scheduler 分配的稳定单调整数身份；不由本类分配，禁止 Node.name / NodePath / instance_id 作为业务身份。
var _runtime_id: int
## 创建时版本标签；不做递增保证，仅用于追溯同身份光粒的生成批次。
var _generation: int
## 最近一次逻辑确认到达的格；允许任意 Vector2i（含负坐标），本类不做地图合法性校验。
var _cell: Vector2i
## 传播方向；构造时强制为合法八方向，非法方向构造拒绝。
var _direction: Vector2i
## 速度档位（_ParticleMotionRules.SpeedTier 值）；emitted 入口固定写入 STANDARD。
var _speed_tier: int
## 当前传播步的逻辑起始 Tick（绝对整数 Tick）；emitted 入口写入构造时的 current_tick。
var _step_started_tick: int
## 下一次移动的绝对整数 Tick；emitted 入口写入 current_tick + ticks_for(STANDARD, direction)。
var _next_move_tick: int
## 是否仍在活动；emitted 入口写入 true，terminate 后置 false 且不得复活。
var _active: bool
## 发射身份（ActiveEmissionRegistry 单调 emission_id；AF-02 光交互 Context Shared Facts 用）。
## [br]0 = 未关联 emission（遗留两参构造 / 测试桩），正式运行由 scheduler.emit_particle 传入真实值。
var _emission_id: int


## 默认构造：创建一个 inactive 空壳（active=false，字段为零值）。
## 真实光粒请用 create_emitted 入口构造；本默认构造仅为 RefCounted 实例化所需，不应直接产出可调度光粒。
func _init() -> void:
	_runtime_id = 0
	_generation = 0
	_cell = Vector2i.ZERO
	_direction = Vector2i.ZERO
	_speed_tier = _ParticleMotionRules.SpeedTier.STANDARD
	_step_started_tick = 0
	_next_move_tick = 0
	_active = false
	_emission_id = 0


## 已发射光粒的最小构造入口（冻结 emitted-state 合同）。
## [br]输入：runtime_id 为未来 scheduler 分配的稳定单调身份（须 >=0）；generation 为创建时版本标签；
##   cell 为发射起始格（任意 Vector2i）；direction 须为合法八方向；current_tick 为发射时刻绝对整数 Tick（须 >=0）。
## [br]返回：成功返回 ParticleRuntimeState，其 speed=STANDARD、step_started_tick=current_tick、
##   next_move_tick=current_tick + ticks_for(STANDARD, direction)、active=true。
## [br]副作用：仅写入新实例字段；不分配 runtime_id、不推进 Tick、不执行移动、不读写 world query 或视觉。
## [br]失败：direction 非法 / runtime_id<0 / current_tick<0 任一成立时 push_error 并返回 null（按冻结边界拒绝构造）。
## [br]边界：current_tick 不复制进 state；next_move_tick 为绝对整数 Tick；
##   STANDARD 初始速度冻结，不因调用方传入的其它档位参数改变（本入口不接受 speed 参数）；
##   emission_id 为发射身份（AF-02 Context Shared Facts；默认 0 = 未关联，正式运行必传真实值）。
static func create_emitted(
		runtime_id: int,
		generation: int,
		cell: Vector2i,
		direction: Vector2i,
		current_tick: int,
		emission_id: int = 0
) -> ParticleRuntimeState:
	if not _LightEmissionTypes.is_valid_direction(direction):
		push_error("ParticleRuntimeState：非法发射方向 (%d, %d)，拒绝构造。" % [direction.x, direction.y])
		return null
	if runtime_id < 0:
		push_error("ParticleRuntimeState：非法 runtime_id %d（须 >=0），拒绝构造。" % runtime_id)
		return null
	if current_tick < 0:
		push_error("ParticleRuntimeState：非法 current_tick %d（须 >=0），拒绝构造。" % current_tick)
		return null
	var state: ParticleRuntimeState = ParticleRuntimeState.new()
	state._runtime_id = runtime_id
	state._generation = generation
	state._cell = cell
	state._direction = direction
	state._speed_tier = _ParticleMotionRules.SpeedTier.STANDARD
	state._step_started_tick = current_tick
	state._next_move_tick = current_tick + _ParticleMotionRules.ticks_for(
		_ParticleMotionRules.SpeedTier.STANDARD, direction)
	state._active = true
	state._emission_id = emission_id
	return state


## 终止本光粒（活动状态置假入口）。置 active=false，幂等；本类不提供任何置真入口，故终止后不得复活，apply_move 也会拒绝。
func terminate() -> void:
	_active = false


## 正式状态推进入口（冻结 apply_move 合同；B1.1）。
## [br]职责：在一次合法传播步结束后，原子提交本光粒的下一可变事实——cell / direction / speed_tier /
##   step_started_tick / next_move_tick。本入口是这五个字段的唯一可变入口；runtime_id 与 generation 永久不可变。
## [br]输入：next_cell 为本次到达的格（任意 Vector2i，含负坐标）；outgoing_direction 须为合法八方向；
##   next_speed_tier 须为合法 SpeedTier；current_tick 须 >=0；next_move_tick 须 > current_tick。
## [br]返回：全部校验通过并原子提交后返回 true；任一校验失败 push_error 并返回 false。
## [br]副作用：成功时仅写入上述五个字段；不分配身份、不推进 Tick 计算（next_move_tick 由调用方算好传入）、
##   不读写 world query / terrain / wall / 机关 / 视觉 / Crystal；不复活已终止光粒。
## [br]原子性：所有输入校验先于任一字段写入，任一校验失败则五个字段全部保持原值；
##   GDScript 单线程执行保证校验与写入之间无交错；runtime_id / generation 永不被本入口触碰。
## [br]不可复活：active=false（已 terminate）时直接拒绝，不推进、不置真。
func apply_move(
		next_cell: Vector2i,
		outgoing_direction: Vector2i,
		next_speed_tier: int,
		current_tick: int,
		next_move_tick: int
) -> bool:
	if not _active:
		push_error("ParticleRuntimeState：apply_move 拒绝——光粒已 terminate（active=false），不可推进或复活。")
		return false
	if not _LightEmissionTypes.is_valid_direction(outgoing_direction):
		push_error("ParticleRuntimeState：apply_move 拒绝——非法 outgoing_direction (%d, %d)。" % [outgoing_direction.x, outgoing_direction.y])
		return false
	if not _ParticleMotionRules.is_valid_speed_tier(next_speed_tier):
		push_error("ParticleRuntimeState：apply_move 拒绝——非法 SpeedTier %d。" % next_speed_tier)
		return false
	if current_tick < 0:
		push_error("ParticleRuntimeState：apply_move 拒绝——current_tick %d 须 >=0。" % current_tick)
		return false
	if next_move_tick <= current_tick:
		push_error("ParticleRuntimeState：apply_move 拒绝——next_move_tick %d 须 > current_tick %d。" % [next_move_tick, current_tick])
		return false
	_cell = next_cell
	_direction = outgoing_direction
	_speed_tier = next_speed_tier
	_step_started_tick = current_tick
	_next_move_tick = next_move_tick
	return true


# ===== 只读 getter =====

## 未来 scheduler 分配的稳定单调整数身份。
func get_runtime_id() -> int:
	return _runtime_id


## 创建时版本标签。
func get_generation() -> int:
	return _generation


## 最近一次逻辑确认到达的格。
func get_cell() -> Vector2i:
	return _cell


## 传播方向（合法八方向）。
func get_direction() -> Vector2i:
	return _direction


## 当前速度档位（_ParticleMotionRules.SpeedTier 值）。
func get_speed_tier() -> int:
	return _speed_tier


## 发射身份（AF-02 Context Shared Facts；0 = 未关联 emission 的遗留构造 / 测试桩）。
func get_emission_id() -> int:
	return _emission_id


## 当前传播步的逻辑起始 Tick（绝对整数 Tick）。
func get_step_started_tick() -> int:
	return _step_started_tick


## 下一次移动的绝对整数 Tick。
func get_next_move_tick() -> int:
	return _next_move_tick


## 是否仍在活动（active=true 代表仍在传播；false 代表已终止）。
func is_active() -> bool:
	return _active
