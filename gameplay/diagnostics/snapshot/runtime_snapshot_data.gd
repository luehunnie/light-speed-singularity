class_name RuntimeSnapshotData
extends RefCounted

## 运行期快照数据公共数据契约（D7-R1 Snapshot v1：升级到 M4 后 multi-emission Runtime 语义）。
##
## 职责：
## 保存某一运行时刻的只读事实摘要（时间戳、level_id、运行状态、是否完成、runtime_generation、运行期移动次数、
## cooldown 摘要、发射器 cell/direction/form/allow_form_switch、活动 emission 列表、活动光粒列表、Particle tick、
## Ray 段数、库存与已放置机构摘要、水晶状态列表、采样耗时），并提供只读校验与独立深复制；
## 供 RuntimeSnapshot 序列化为 JSON 快照使用。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照数据层；由 RuntimeSnapshotSampler 只读采样构造（D7-R1 起接入真实 Runtime）。
##
## 主要依赖：
## CrystalSnapshotState、EmissionSnapshotState、ParticleSnapshotState（同目录快照子契约）；
## 不依赖场景树、节点、核心循环私有变量、玩法对象或文件系统。
##
## 明确不负责：
## 采集数据（由 RuntimeSnapshotSampler 负责）、序列化为 JSON、写入文件、轮转、判断关卡是否完成、
## 修复水晶/库存/移动次数、聚合日志。
##
## 关键边界：
## - 本类只保存调用方主动提供的只读摘要：不接收 Node/Object 后反射字段、不遍历场景树、
##   不直接读取核心循环私有变量、不使用 Node.name / instance_id 冒充业务身份。
## - level_id 无正式来源时必须为空（unavailable 政策），不得拿 Node.name 顶替。
## - 构造时深复制 emission_states / particle_states / crystal_states，不保存调用方可变引用。
## - validate() 一次返回全部中文错误，不提前返回、不修改数据、不 push_error、不抛异常。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。
## - v1 schema 冻结字段见 RuntimeSnapshot._build_root；结构变更须递增 SCHEMA_VERSION。


# 光形态枚举唯一公共来源（preload 引用，用于 emitter_form 校验；不依赖任何运行期对象）。
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 快照产生时刻的 Unix 毫秒时间戳。必须非负。
var timestamp_unix_msec: int

## 正式 level_id；当前无正式来源，恒为空（unavailable 政策），不得用 Node.name 顶替。
var level_id: StringName

## 快照对应运行状态，使用稳定 StringName（SETUP/READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）。不得为空。
var run_state: StringName

## 快照采集时关卡是否已完成（ObjectiveController 事实）。仅如实记录，本契约不据此判断。
var is_completed: bool

## Runtime/reset epoch token（M4-E1 语义：仅 SETUP→READY 与 R 递增；同 epoch 多次发射共享同一值）。必须非负。
var runtime_generation: int

## 快照采集时已使用运行期移动次数。必须非负。
var runtime_move_count: int

## 快照采集时剩余运行期移动次数（max(limit - used, 0)）。必须非负。
var runtime_moves_remaining: int

## 运行期移动次数上限（构造注入的配置值）。必须非负。
var runtime_move_limit: int

## 发射器所在逻辑格坐标。
var emitter_cell: Vector2i

## 发射器朝向（单位向量；不得为零，分量绝对值不超过 1）。
var emitter_direction: Vector2i

## 发射器当前光形态（LightEmissionTypes.LightForm 数值，RAY=0 / PARTICLE=1；Q 只影响后续发射）。
var emitter_form: int

## 关卡 Q 形态切换开关（关卡配置只读事实；false 时 Q 无效）。
var allow_form_switch: bool

## 主发射器 0.5s cooldown 是否 ready（RAY/PARTICLE 共用；成功发射后 0.5s 内 false）。
var fire_cooldown_ready: bool

## 当前活动 emission 数量。必须非负，且等于 emission_states.size()。
var active_emission_count: int

## 活动 emission 快照列表（按 allocate 顺序）；构造时逐项深复制。
var emission_states: Array[EmissionSnapshotState]

## 活动光粒快照列表（含所属 emission_id 关联）；构造时逐项深复制。
var particle_states: Array[ParticleSnapshotState]

## 当前 Particle 绝对整数 Tick。必须非负。
var particle_tick: int

## 当前活动光粒数量（scheduler 真值）。必须非负。
var particle_active_count: int

## 当前 Ray 光路段总数（LightVisualController 只读事实）。必须非负。
var ray_segment_count: int

## 快照采集时剩余库存数量。必须非负。
var inventory_remaining: int

## 库存总量（InventoryController 只读事实）。必须非负。
var inventory_total: int

## 快照采集时已放置机构数量。必须非负。
var placed_mechanism_count: int

## 水晶状态列表，元素类型为 CrystalSnapshotState。构造时逐项深复制。
var crystal_states: Array[CrystalSnapshotState]

## 本次采样（Runtime→Sampler→Data）耗时（微秒；最小性能观测，不参与玩法）。必须非负。
var snapshot_duration_usec: int


## 构造一份运行期快照数据；仅赋值并完成必要深复制，校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
## [br]副作用：深复制 emission_states、particle_states、crystal_states，调用方之后修改原数组不影响本快照。
func _init(
		p_timestamp_unix_msec: int,
		p_level_id: StringName,
		p_run_state: StringName,
		p_is_completed: bool,
		p_runtime_generation: int,
		p_runtime_move_count: int,
		p_runtime_moves_remaining: int,
		p_runtime_move_limit: int,
		p_emitter_cell: Vector2i,
		p_emitter_direction: Vector2i,
		p_emitter_form: int,
		p_allow_form_switch: bool,
		p_fire_cooldown_ready: bool,
		p_active_emission_count: int,
		p_emission_states: Array[EmissionSnapshotState],
		p_particle_states: Array[ParticleSnapshotState],
		p_particle_tick: int,
		p_particle_active_count: int,
		p_ray_segment_count: int,
		p_inventory_remaining: int,
		p_inventory_total: int,
		p_placed_mechanism_count: int,
		p_crystal_states: Array[CrystalSnapshotState],
		p_snapshot_duration_usec: int
) -> void:
	timestamp_unix_msec = p_timestamp_unix_msec
	level_id = p_level_id
	run_state = p_run_state
	is_completed = p_is_completed
	runtime_generation = p_runtime_generation
	runtime_move_count = p_runtime_move_count
	runtime_moves_remaining = p_runtime_moves_remaining
	runtime_move_limit = p_runtime_move_limit
	emitter_cell = p_emitter_cell
	emitter_direction = p_emitter_direction
	emitter_form = p_emitter_form
	allow_form_switch = p_allow_form_switch
	fire_cooldown_ready = p_fire_cooldown_ready
	active_emission_count = p_active_emission_count
	# 深复制三类子契约列表：逐项 duplicate_state 生成独立副本；null 元素原样保留交由 validate 报告。
	emission_states = _copy_emission_states(p_emission_states)
	particle_states = _copy_particle_states(p_particle_states)
	crystal_states = _copy_crystal_states(p_crystal_states)
	particle_tick = p_particle_tick
	particle_active_count = p_particle_active_count
	ray_segment_count = p_ray_segment_count
	inventory_remaining = p_inventory_remaining
	inventory_total = p_inventory_total
	placed_mechanism_count = p_placed_mechanism_count
	snapshot_duration_usec = p_snapshot_duration_usec


## 深复制活动 emission 快照列表的私有辅助；null 元素原样保留（交由 validate 报告，不在构造期中断）。
func _copy_emission_states(p_source: Array[EmissionSnapshotState]) -> Array[EmissionSnapshotState]:
	var copy: Array[EmissionSnapshotState] = []
	for index: int in range(p_source.size()):
		var state: EmissionSnapshotState = p_source[index]
		copy.append(null if state == null else state.duplicate_state())
	return copy


## 深复制活动光粒快照列表的私有辅助；null 元素原样保留（交由 validate 报告，不在构造期中断）。
func _copy_particle_states(p_source: Array[ParticleSnapshotState]) -> Array[ParticleSnapshotState]:
	var copy: Array[ParticleSnapshotState] = []
	for index: int in range(p_source.size()):
		var state: ParticleSnapshotState = p_source[index]
		copy.append(null if state == null else state.duplicate_state())
	return copy


## 深复制水晶状态列表的私有辅助；null 元素原样保留（交由 validate 报告，不在构造期中断）。
func _copy_crystal_states(p_source: Array[CrystalSnapshotState]) -> Array[CrystalSnapshotState]:
	var copy: Array[CrystalSnapshotState] = []
	for index: int in range(p_source.size()):
		var state: CrystalSnapshotState = p_source[index]
		copy.append(null if state == null else state.duplicate_state())
	return copy


## 只读校验当前快照数据的字段完整性。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改数据、不 push_error、不抛异常、不修复状态、不访问文件系统。
## [br]边界条件：必须一次返回全部问题；emission/particle/crystal 子契约逐项汇总子错误。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	if timestamp_unix_msec < 0:
		problems.append("RuntimeSnapshotData：timestamp_unix_msec 为负，必须为非负 Unix 毫秒时间戳。")
	# level_id 允许为空：无正式来源时按 unavailable 政策保持空，此处不报告（不得用 Node.name 顶替）。
	if run_state == &"":
		problems.append("RuntimeSnapshotData：run_state 为空，必须填写运行状态。")
	if runtime_generation < 0:
		problems.append("RuntimeSnapshotData：runtime_generation 为负，必须为非负 epoch token。")
	if runtime_move_count < 0:
		problems.append("RuntimeSnapshotData：runtime_move_count 为负，必须非负。")
	if runtime_moves_remaining < 0:
		problems.append("RuntimeSnapshotData：runtime_moves_remaining 为负，必须非负。")
	if runtime_move_limit < 0:
		problems.append("RuntimeSnapshotData：runtime_move_limit 为负，必须非负。")
	if emitter_direction == Vector2i.ZERO:
		problems.append("RuntimeSnapshotData：emitter_direction 为零向量，必须为非零方向。")
	if absi(emitter_direction.x) > 1 or absi(emitter_direction.y) > 1:
		problems.append("RuntimeSnapshotData：emitter_direction 分量绝对值超过 1，必须为单位方向向量。")
	if emitter_form != _LightEmissionTypes.LightForm.RAY and emitter_form != _LightEmissionTypes.LightForm.PARTICLE:
		problems.append("RuntimeSnapshotData：emitter_form 数值 %d 不在 RAY/PARTICLE 合法集合内。" % emitter_form)
	if active_emission_count < 0:
		problems.append("RuntimeSnapshotData：active_emission_count 为负，必须非负。")
	if active_emission_count != emission_states.size():
		problems.append("RuntimeSnapshotData：active_emission_count（%d）与 emission_states.size()（%d）不一致。" % [active_emission_count, emission_states.size()])
	if particle_tick < 0:
		problems.append("RuntimeSnapshotData：particle_tick 为负，必须非负。")
	if particle_active_count < 0:
		problems.append("RuntimeSnapshotData：particle_active_count 为负，必须非负。")
	if ray_segment_count < 0:
		problems.append("RuntimeSnapshotData：ray_segment_count 为负，必须非负。")
	if inventory_remaining < 0:
		problems.append("RuntimeSnapshotData：inventory_remaining 为负，必须非负。")
	if inventory_total < 0:
		problems.append("RuntimeSnapshotData：inventory_total 为负，必须非负。")
	if placed_mechanism_count < 0:
		problems.append("RuntimeSnapshotData：placed_mechanism_count 为负，必须非负。")
	if snapshot_duration_usec < 0:
		problems.append("RuntimeSnapshotData：snapshot_duration_usec 为负，必须非负。")
	# 汇总三类子契约错误，前缀标注来源索引以便定位。
	_append_sub_problems(problems, "emission_states", emission_states)
	_append_sub_problems(problems, "particle_states", particle_states)
	_append_sub_problems(problems, "crystal_states", crystal_states)
	return problems


## 汇总子契约校验错误的私有辅助；null 元素与子错误均前缀标注来源索引。
func _append_sub_problems(p_problems: PackedStringArray, p_field: String, p_states: Array) -> void:
	for index: int in range(p_states.size()):
		var state: Variant = p_states[index]
		if state == null:
			p_problems.append("RuntimeSnapshotData：%s 第 %d 项为 null，元素不得为 null。" % [p_field, index + 1])
			continue
		for sub_problem: String in state.validate():
			p_problems.append("RuntimeSnapshotData：%s 第 %d 项：%s" % [p_field, index + 1, sub_problem])


## 返回当前快照数据的全新独立深副本（通过构造函数完成深复制）。
func duplicate_data() -> RuntimeSnapshotData:
	return RuntimeSnapshotData.new(
		timestamp_unix_msec,
		level_id,
		run_state,
		is_completed,
		runtime_generation,
		runtime_move_count,
		runtime_moves_remaining,
		runtime_move_limit,
		emitter_cell,
		emitter_direction,
		emitter_form,
		allow_form_switch,
		fire_cooldown_ready,
		active_emission_count,
		emission_states,
		particle_states,
		particle_tick,
		particle_active_count,
		ray_segment_count,
		inventory_remaining,
		inventory_total,
		placed_mechanism_count,
		crystal_states,
		snapshot_duration_usec
	)
