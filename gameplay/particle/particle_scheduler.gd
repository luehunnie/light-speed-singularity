class_name ParticleScheduler
extends RefCounted

## 光粒整数 Tick 集中调度器（D7-4 B2）。
## 职责：作为整数 Tick 真值的唯一集中持有者——current_tick / next_runtime_id / 活动 Particle 索引——
##   并按 due-batch 算法把每个 due Tick 上的活动光粒交给 ParticleStepExecutor 求值，再依据纯 StepResult 原子 apply_move 或 terminate，
##   产出有序 BatchEvents 供未来 LevelRuntimeController 读取。本类是“Tick 推进 + due 采集 + 原子提交 + 事件产出”的唯一入口。
##   generation 不属本类“真值”范畴：_current_generation 仅为上层 Runtime 绑定进来的镜像标签，
##   唯一真值来源为未来 LevelRuntimeController._pulse_generation；本类绝不自行产生 / 自增 generation（D7-4 B2.1 单一所有权收口）。
## 位置：位于 gameplay/particle 下；本类是光粒运行期的集中调度核心，B2 不接入 LevelRuntimeController / UI / visual / Timer 泵。
## 依赖：通过 preload 引用 ParticleRuntimeState（create_emitted / apply_move / terminate / 只读 getter）、
##   ParticleMotionRules（apply_speed_delta / ticks_for）、ParticleStepExecutor（evaluate_step）；
##   world_query 为构造期注入的 Variant 鸭子类型（须提供 is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at）。
## 不负责：SceneTreeTimer / Timer 泵（由后续 B3b 的 LevelRuntimeController 驱动 advance_one_tick）、ObjectiveController、visual、
##   Space/request_fire、Emitter 双形态、Q 切换、玩家八方向输入、RuntimeSnapshot、复活已终止光粒。
## 边界条件：runtime_id 由本类单调分配，跨 generation 不回拨；generation 由外部 Runtime（未来 LevelRuntimeController._pulse_generation）
##   传入 begin_generation 绑定为镜像标签——本类只记录不自增，重复 / 倒退被原子拒绝；旧 expected_generation 调 advance_one_tick 永久无效；
##   每个 due Tick 的处理 ID 集合在采集时冻结为快照，本 Tick 内新登记光粒不得进入当前批；
##   每颗光粒每 Tick 最多执行一步；每次执行前重新解析 state，已失效则跳过；删除在批次结束后统一进行，不漏处理 / 不重复处理；
##   速度机关只影响“离开机关格后的下一传播步”，绝不回改已花掉的进入 Tick。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


const _ParticleRuntimeState: GDScript = preload(
	"res://gameplay/particle/particle_runtime_state.gd"
)
const _ParticleMotionRules: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)
const _ParticleStepExecutor: GDScript = preload(
	"res://gameplay/particle/particle_step_executor.gd"
)


# ===== 私有事实（current_tick / next_runtime_id / 活动 Particle 索引为本类真值；_current_generation 为外部镜像标签） =====

## 当前绝对整数 Tick；begin_generation 重置为 0，advance_one_tick 每次 +1。
var _current_tick: int = 0
## 当前由上层 Runtime 绑定进来的 generation 镜像标签（初始 -1 表示未绑定）。
## 注意：非 generation 真值来源，仅镜像外部绑定值；真值为未来 LevelRuntimeController._pulse_generation。本类不自产 / 自增。
## advance_one_tick(expected) 须与本镜像匹配才推进。
var _current_generation: int = -1
## 下一个待分配的 runtime_id；单调递增，跨 generation 不回拨。
var _next_runtime_id: int = 0
## 活动 Particle 索引：runtime_id -> ParticleRuntimeState（仅由本类增删）。
var _active_states: Dictionary = {}

## 构造期注入的只读世界查询（Variant 鸭子类型），转交 executor.evaluate_step。
var _world_query: Variant
## 无状态单步执行器实例（executor 无可变字段，单实例安全复用）。
var _executor: _ParticleStepExecutor


## 构造调度器；注入只读 world_query，内部持有无状态 executor。
## [br]输入：world_query 为只读世界查询（须实现 is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at）。
## [br]副作用：仅写入 _world_query 与新建一个 executor；不推进 Tick、不分配 runtime_id、不登记光粒。
func _init(world_query: Variant) -> void:
	_world_query = world_query
	_executor = _ParticleStepExecutor.new()


## 单个 Tick 批次事件（有序产出，供未来 LRC 只读读取）。
## [br]runtime_id / generation：身份与版本。
## [br]outcome：MOVE / TERMINATE（值同 ParticleStepExecutor.Outcome）。
## [br]from_cell：本步起始格（移动前 cell）。
## [br]entered_cell：MOVE 时为进入格；TERMINATE 时为被阻挡的尝试格（未进入）。
## [br]direction：MOVE 时为离开方向（Adapter 给出）；TERMINATE 时为入射方向。
## [br]speed_tier：MOVE 时为 apply_speed_delta 后的新档位；TERMINATE 时为终止前档位。
## [br]has_crystal：MOVE 时是否踩到水晶（仅事件，不点亮）；TERMINATE 时 false。
## [br]termination_reason：MOVE 时 NONE；TERMINATE 时具体原因（值同 ParticleStepExecutor.TerminationReason）。
## [br]next_move_tick：MOVE 时为本步 authoritative 下一传播步结束 Tick（== apply_move 后 state.next_move_tick，由 commit 时
##   ticks_for(新档, 离开方向) 算出——D7-4 B4b-1 MF-1 timing 合同：Visual 据此 + TICK envelope.tick 得 step duration，不得重算）；
##   TERMINATE 时保持默认 0（不伪造下一步 timing，Visual 不得 Tween 到 entered_cell）。
## [br]next_step_blocked：仅 MOVE 时有意义——executor 确定性前瞻（entered_cell + direction 是否墙 / 越界，M4-E4）；
##   Visual 据此把本段插值截到两格边界并在接触时即时消失；TERMINATE 时恒 false。不改本类 Tick / 终止语义。
class BatchEvent:
	extends RefCounted

	var runtime_id: int = 0
	var generation: int = 0
	var outcome: int = _ParticleStepExecutor.Outcome.MOVE
	var from_cell: Vector2i = Vector2i.ZERO
	var entered_cell: Vector2i = Vector2i.ZERO
	var direction: Vector2i = Vector2i.ZERO
	var speed_tier: int = _ParticleMotionRules.SpeedTier.STANDARD
	var has_crystal: bool = false
	var termination_reason: int = _ParticleStepExecutor.TerminationReason.NONE
	## MOVE authoritative 下一传播步结束 Tick（D7-4 B4b-1 MF-1）；TERMINATE 保持默认 0。
	var next_move_tick: int = 0
	## M4-E4 executor 前瞻：MOVE 离开方向再下一格是否墙 / 越界；TERMINATE 恒 false。
	var next_step_blocked: bool = false


# ===== generation / 发射 =====

## 绑定一个由外部 Runtime 提供的 generation 镜像标签（D7-4 B2.1 单一所有权收口）。
## [br]职责：记录外部 generation（绝不自行产生 / 自增），current_tick 重置 0，清空旧活动 states；
##   next_runtime_id 不回拨（跨 generation 单调）。generation 唯一真值来源为未来 LevelRuntimeController._pulse_generation。
## [br]输入：generation 为外部 Runtime 声明的当前 generation（须严格大于当前已绑定值；初始 -1 视为未绑定，故首次合法值可 >=0）。
## [br]返回：generation 严格大于当前已绑定值时成功记录并返回 true；generation <= 当前值（重复 / 倒退）时 push_error 并返回 false，
##   且不做任何副作用——不清 active、不重置 tick、不改 generation、不改 runtime_id。
## [br]副作用（成功时）：写 _current_generation、重置 _current_tick=0、清空 _active_states；不触碰 _next_runtime_id。
## [br]边界：同一 generation 误调两次不会清空活动 Particle（第二次被原子拒绝）；旧 generation 的光粒随清空一并移出活动索引，不再被本调度器处理。
func begin_generation(generation: int) -> bool:
	if generation <= _current_generation:
		push_error("ParticleScheduler：begin_generation 拒绝——generation %d 须严格大于当前已绑定 %d（重复 / 倒退），不产生任何副作用。" % [generation, _current_generation])
		return false
	_current_generation = generation
	_current_tick = 0
	_active_states.clear()
	return true


## 发射一颗光粒：由本类分配单调 runtime_id、generation=current_generation、初速 STANDARD，经 create_emitted 构造并登记。
## [br]输入：cell 为发射起始格；direction 为合法八方向；emission_id 为发射身份（AF-02 Context Shared Facts；默认 0 = 未关联，正式运行必传真实值）。
## [br]返回：成功返回分配的 runtime_id（>=0）；direction 非法致 create_emitted 返回 null 时 push_error 并返回 -1（不消费 id）。
## [br]副作用：成功时 _next_runtime_id +=1 并登记进 _active_states；不推进 Tick、不查 world、不调 executor。
## [br]边界：发射使用当前 current_tick 作为 step_started_tick / next_move_tick 基线；初速冻结 STANDARD。
func emit_particle(cell: Vector2i, direction: Vector2i, emission_id: int = 0) -> int:
	var runtime_id: int = _next_runtime_id
	var state: Variant = _ParticleRuntimeState.create_emitted(
		runtime_id, _current_generation, cell, direction, _current_tick, emission_id)
	if state == null:
		push_error("ParticleScheduler：emit_particle 拒绝——create_emitted 返回 null（cell=(%d,%d), direction=(%d,%d)）。" % [cell.x, cell.y, direction.x, direction.y])
		return -1
	_next_runtime_id += 1
	_active_states[runtime_id] = state
	return runtime_id


## 撤销一颗刚发射、尚未被任何 Tick 处理的光粒（M4-E3 Gate 2）：从活动索引移除指定 runtime_id。
## [br]内部协作方法（下划线私有约定，非 public API）：唯一用途为 LRC._begin_particle_emission 在 emit 成功后
##   bind_particle_runtime 被防御性拒绝时，于同一同步段内立即撤销本次 emit——不留 zombie 光粒惰性存活至 epoch 重置。
##   除 LRC 防御性事务外任何调用方不得依赖本方法（B3b-2.1 MF-3 边界维持：public mutator 仍仅生命周期入口，无新增 public API）。
## [br]输入：expected_generation 为调用方声明的期望 generation；runtime_id 为本次 emit_particle 返回的刚分配 id。
## [br]返回：generation 匹配且 runtime_id 在活动索引中时移除并返回 true；否则 push_error 返回 false（零副作用）。
## [br]副作用（成功时）：仅 erase _active_states[runtime_id]；不回拨 _next_runtime_id（跨 emission 单调，与 emission_id 失败空洞一致）、
##   不推进/回退 _current_tick、不产出 BatchEvent、不调 executor / world_query。
## [br]边界：只服务“emit 同一同步段内的撤销”——正常调用时该光粒尚未进入任何 due 批次（Tick 未推进、无视觉事件发布），移除即无痕；
##   不用于撤销已推进光粒（那属于 advance_one_tick 的原子事务范畴）。
func _rollback_emitted_particle(expected_generation: int, runtime_id: int) -> bool:
	if expected_generation != _current_generation:
		push_error("ParticleScheduler：_rollback_emitted_particle 拒绝——generation %d 与当前绑定 %d 不匹配，零副作用。" % [expected_generation, _current_generation])
		return false
	if not _active_states.has(runtime_id):
		push_error("ParticleScheduler：_rollback_emitted_particle 拒绝——runtime_id %d 不在活动索引，零副作用。" % runtime_id)
		return false
	_active_states.erase(runtime_id)
	return true


# ===== Tick 推进 / due-batch =====

## 推进一个整数 Tick 并处理所有 due 光粒（generation 守卫 + due 快照 + 稳定排序 + 逐颗至多一步 + 批后清理）。
## [br]输入：expected_generation 为调用方声明的期望 generation；与 _current_generation 不匹配时永久 no-op。
## [br]返回：本 Tick 产出的有序 BatchEvent 数组（按 runtime_id 升序）；generation 不匹配或无 due 光粒时返回空数组。
## [br]副作用（匹配时）：current_tick +=1；对每颗 due 且仍活动的光粒依 StepResult 原子 apply_move 或 terminate；
##   批次结束后统一从 _active_states 删除已终止光粒；不调 ObjectiveController / visual，不建第二个 Timer / generation 系统。
## [br]边界：due ID 集合在采集时冻结为快照（_active_states.keys() 副本），本 Tick 内新登记光粒不进入当前批；
##   due_ids.sort() 保证同 Tick 多光粒按 runtime_id 升序稳定处理；每次执行前重新 has(rid) + is_active() 校验，已失效则跳过；
##   MOVE 时不回改已花掉的进入 Tick——next_move_tick = current_tick + ticks_for(新档位, 离开方向)。
func advance_one_tick(expected_generation: int) -> Array:
	if expected_generation != _current_generation:
		return []
	_current_tick += 1

	# 采集 due（快照冻结 keys 后过滤；不在线修改 _active_states）。
	var due_ids: Array = []
	var snapshot_keys: Array = _active_states.keys()
	for key: Variant in snapshot_keys:
		var state: Variant = _active_states[key]
		if state.is_active() and state.get_next_move_tick() <= _current_tick:
			due_ids.append(key)
	# 固定快照后按 runtime_id 升序——同 Tick 顺序稳定。
	due_ids.sort()

	var events: Array = []
	var terminated_ids: Array = []
	for rid: Variant in due_ids:
		# 每次执行前重新解析；已失效（被删 / 已 terminate）则跳过，不漏不重。
		if not _active_states.has(rid):
			continue
		var state: Variant = _active_states[rid]
		if not state.is_active():
			continue
		var from_cell: Vector2i = state.get_cell()
		var result = _executor.evaluate_step(state, _world_query)

		if result.outcome == _ParticleStepExecutor.Outcome.MOVE:
			_apply_move_event(state, rid, from_cell, result, events)
		else:
			_apply_terminate_event(state, rid, from_cell, result, events, terminated_ids)

	# 批次结束后统一删除已终止光粒（删除不得导致漏处理——due_ids 已冻结）。
	for rid: Variant in terminated_ids:
		_active_states.erase(rid)
	return events


## 对 MOVE 结果原子提交 apply_move 并产出 MOVE 事件（内部辅助，不直接对外）。
func _apply_move_event(
		state: Variant,
		runtime_id: Variant,
		from_cell: Vector2i,
		result,  # StepResult（_ParticleStepExecutor.StepResult，跨模块内类以非类型化局部读取字段）
		events: Array
) -> void:
	# 速度机关只影响“离开机关格后的下一传播步”——delta=0 时原档保留（不调 apply_speed_delta，避免给其传入文档化非法的 0）；
	# delta=±1 时用 apply_speed_delta 推新档，再用新档 + 离开方向算下一步 Tick。
	var new_speed: int
	if result.speed_delta == 0:
		new_speed = state.get_speed_tier()
	else:
		new_speed = _ParticleMotionRules.apply_speed_delta(
			state.get_speed_tier(), result.speed_delta)
	var ticks: int = _ParticleMotionRules.ticks_for(new_speed, result.outgoing_direction)
	var next_move_tick: int = _current_tick + ticks
	# 只通过 state.apply_move 原子提交五可变字段；绝不手写字段。
	state.apply_move(
		result.entered_cell, result.outgoing_direction, new_speed,
		_current_tick, next_move_tick)
	var ev: BatchEvent = BatchEvent.new()
	ev.runtime_id = runtime_id
	ev.generation = state.get_generation()
	ev.outcome = _ParticleStepExecutor.Outcome.MOVE
	ev.from_cell = from_cell
	ev.entered_cell = result.entered_cell
	ev.direction = result.outgoing_direction
	ev.speed_tier = new_speed
	ev.has_crystal = result.has_crystal
	ev.termination_reason = _ParticleStepExecutor.TerminationReason.NONE
	# D7-4 B4b-1 MF-1：写入 authoritative next_move_tick（== 刚 apply_move 写入 state 的同值）；
	# Visual 经 detached event 取此值 + TICK envelope.tick 得 step duration，绝不重算 ticks_for。
	ev.next_move_tick = next_move_tick
	# M4-E4：透传 executor 确定性前瞻（本类不重查 world，不改 Tick / 终止语义）。
	ev.next_step_blocked = result.next_step_blocked
	events.append(ev)


## 对 TERMINATE 结果执行 terminate 并产出 TERMINATE 事件，登记到批后清理列表（内部辅助，不直接对外）。
func _apply_terminate_event(
		state: Variant,
		runtime_id: Variant,
		from_cell: Vector2i,
		result,
		events: Array,
		terminated_ids: Array
) -> void:
	state.terminate()
	terminated_ids.append(runtime_id)
	var ev: BatchEvent = BatchEvent.new()
	ev.runtime_id = runtime_id
	ev.generation = state.get_generation()
	ev.outcome = _ParticleStepExecutor.Outcome.TERMINATE
	ev.from_cell = from_cell
	ev.entered_cell = result.entered_cell
	ev.direction = state.get_direction()
	ev.speed_tier = state.get_speed_tier()
	ev.has_crystal = result.has_crystal
	ev.termination_reason = result.termination_reason
	# D7-4 B4b-1 MF-1：TERMINATE 不写 next_move_tick，保持默认 0——不伪造下一步 timing（entered_cell 是未进入的阻挡格，不得 Tween）。
	events.append(ev)


# ===== 只读访问器（供 LRC / 测试读取集中事实） =====

## 当前绝对整数 Tick。
func get_current_tick() -> int:
	return _current_tick


## 当前由上层 Runtime 绑定的 generation 镜像标签（初始 -1 表示未绑定；非真值来源，真值为未来 LRC._pulse_generation）。
func get_current_generation() -> int:
	return _current_generation


## 下一个待分配的 runtime_id（单调，跨 generation 不回拨）。
func get_next_runtime_id() -> int:
	return _next_runtime_id


## 当前活动光粒数量（批次结束后反映 drain 状态）。
func get_active_count() -> int:
	return _active_states.size()


## 按 runtime_id 取活动光粒的只读 detached 快照（D7-4 B3b-2.1 MF-3 收口）；未登记或已移出返回 null。
## [br]每次新建 Dictionary（值类型副本），含 runtime_id/generation/cell/direction/speed_tier/step_started_tick/next_move_tick/active 八字段。
## [br]外部修改返回 Dictionary 零影响真实 state——真实状态唯一存在 _active_states 的 ParticleRuntimeState 内部。
## [br]不返回 ParticleRuntimeState 原引用、不返回 _active_states；外部无法经此 snapshot 调 apply_move/terminate（Dictionary 无方法表）。
## [br]内部 raw state 仍由本类私有范围内经 _active_states 直接访问（advance_one_tick / _apply_* 等不改动）；
## 本类唯一 public mutator 为生命周期入口 begin_generation / emit_particle，不暴露 state 字段级 mutator（B3b-2.1 MF-3 边界不变）。
## [br]_rollback_emitted_particle 为下划线私有约定的内部协作方法（M4-E3 emit 撤销），仅限 LRC 防御性事务调用，不计入 public API。
func get_particle_state_snapshot(runtime_id: int) -> Variant:
	if not _active_states.has(runtime_id):
		return null
	var state: Variant = _active_states[runtime_id]
	return {
		"runtime_id": state.get_runtime_id(),
		"generation": state.get_generation(),
		"cell": state.get_cell(),
		"direction": state.get_direction(),
		"speed_tier": state.get_speed_tier(),
		"step_started_tick": state.get_step_started_tick(),
		"next_move_tick": state.get_next_move_tick(),
		"active": state.is_active(),
	}


## 是否已 drain（无活动光粒）；仅在批次结束后判断有意义。
func is_drained() -> bool:
	return _active_states.is_empty()
