class_name LevelRuntimeController
extends Node

## 正式关卡运行期编排控制器（Day 3 D3-E；M4-E2 per-emission 生命周期核心）。
## 完整拥有普通脉冲发射请求编排、per-emission 异步结束、runtime_generation 过期保护、活动 emission 登记（含 particle runtime_id 双向映射）、发射 cooldown、运行期移动次数与 R 完整重置顺序。
## 状态事实仍由 RunStateController 唯一持有；本控制器只请求状态转换，不保存第二份 current_state，不定义第二份 RunState 枚举。
## 发射顺序、视觉→水晶顺序、非法方向先于 begin_pulse 拒绝、完成事实由 ObjectiveController 唯一提供等边界与旧 fire_light/reset_runtime 严格一致。
## M4-E1：_runtime_generation 为“Runtime/reset 异步失效 token”——仅 SETUP→READY 新 epoch 与 R 时递增，**不再每次 fire 递增**，同 epoch 多次发射共享同一 generation。
## M4-E2 per-emission 生命周期：删除 _current_emission_id 单槽；每次发射 allocate 自己的 emission_id，Ray async timer 与 Particle TERMINATE 各自携带 (expected_generation, emission_id/runtime_id) 身份；
##   统一 _finish_emission(gen, eid) 聚合结算——一个 emission 结束只 mark_finished 自己，registry 仍有 active 则保持 PULSE_ACTIVE，最后一个结束才 Objective complete ? COMPLETED : MOVE_WINDOW；Particle TERMINATE(runtime_id) → _on_particle_terminated 经 Registry 反查 emission（Scheduler 不知 emission_id）。
## M4-E3 正式 repeated fire：request_fire 接冻结 transaction（零副作用 preflight→immutable 快照→状态事务→dispatch→成功消费 cooldown 一次/失败仅回滚本次）；PULSE_ACTIVE 中 0.5s cooldown 到期可再发射（不请求 begin_pulse 自环）；preflight 下沉 FireRequestPreflight。
## M4-E4 正式 Q 形态切换：request_switch_light_form 按 allow_form_switch + 非 COMPLETED 门翻转 FixedEmitter 形态（只影响后续发射快照；不触旧 emission/cooldown/RunState）；R 恢复关卡初始形态。
## 生命周期：extends Node，由核心 _ready 构造并 add_child，跟随关卡场景；异步 await 依赖 SceneTreeTimer，对象在树期间不被释放，无需核心继续保存异步编排。

const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _RuntimeStateRules: GDScript = preload("res://gameplay/interaction/runtime_state_rules.gd")
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
# M4-E2.1：Ray 执行/timer/visual delay 迁入 RayEmissionDriver；LRC 不再 preload RayExecutionModule/RayExecutionResult/FireRequest（immutable snapshot 经 driver）。
const _RayEmissionDriver: GDScript = preload("res://gameplay/runtime/ray_emission_driver.gd")
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
# D7-3 正式运行入口：运行期校验门（无状态薄门）与结构化校验结果；runtime → level/validation 依赖方向与 D7-1 Gate 一致。
const _RuntimeValidationGate: GDScript = preload("res://gameplay/runtime/runtime_validation_gate.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
# D7-4 B3b-1 Particle Runtime 接线：光粒整数 Tick 集中调度器与公共光形态契约。
# 调度器由本控制器唯一持有并驱动（begin_generation/emit_particle/advance_one_tick 仅本控制器调用）；generation 真值为 _runtime_generation。
const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
# D7-4 B3b-2 BatchEvent 应用：取 Outcome.MOVE 识别移动事件（scheduler BatchEvent.outcome 值同此枚举）。
const _ParticleStepExecutor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
# D7-4 B3b-2 现实时间驱动泵：把 SceneTreeTimer 创建 + await 循环从 LRC 抽出；helper 不持有 generation/RunState/Objective/ParticleRuntimeState。
const _ParticleTickPump: GDScript = preload("res://gameplay/runtime/particle_tick_pump.gd")
# D7-4 B4a Particle 视觉事件边界：detached 事件纯构造器（不持 gameplay 状态）；LRC 只调用并转发其产物，不在本控制器构造 payload 字段。
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
# M4-E1 多发射 Runtime 基础：活动 emission 登记表（emission_id 单调递增、RAY/PARTICLE 共用、M4-E2 起含 runtime_id 双向映射）与主发射器统一 0.5s cooldown（两形态共用、形态切换不重置）。纯职责组件，均不碰 RunState/Objective/Scheduler/Visual。
const _ActiveEmissionRegistry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _EmitterFireCooldown: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_fire_cooldown.gd")
# M4-E1 强制拆分：Particle tick 驱动协作器（tick 推进 / BatchEvent 应用 / per-runtime TERMINATE 上报 / 技术 drain / pump 单链 flag 从 LRC 抽出，控 LRC 规模）。
const _ParticleTickDriver: GDScript = preload("res://gameplay/runtime/particle_tick_driver.gd")
# M4-E3 自然职责拆分：零副作用发射预检（拖拽/状态/0.5s cooldown/形态/方向 → immutable 快照）；LRC 只保留事务编排。
const _FireRequestPreflight: GDScript = preload("res://gameplay/runtime/fire_request_preflight.gd")
# D7-R1 Runtime 只读诊断出口：detached 运行期事实快照构造器（不含 Diagnostics 依赖；LRC 仅一条只读转发）。
const _RuntimeDiagnosticsSnapshotBuilder: GDScript = preload("res://gameplay/runtime/runtime_diagnostics_snapshot_builder.gd")


var _run_state_controller: _RunStateController
var _fixed_emitter: _FixedEmitter
var _light_world_query: _LightWorldQuery
var _light_visual_controller: _LightVisualController
var _objective_controller: _ObjectiveController
var _placement_controller: _PlacementController
var _inventory_controller: _InventoryController
var _drag_flow_controller: _DragFlowController
var _max_propagation_steps: int
var _pulse_visual_duration_seconds: float
var _runtime_move_limit: int
# 高层 UI/一致性回调：刷新全部运行 UI、显隐完成标签、执行库存一致性断言；不传入 UI 节点，不拆成十几个细碎 Callable。
var _refresh_runtime_ui: Callable
var _set_complete_label_visible: Callable
var _assert_inventory_consistency: Callable

## Runtime/reset 异步失效 token（M4-E1）：仅在 SETUP→READY 进入新 epoch（_on_state_changed）与 R（reset_runtime）时递增，**不再每次 request_fire 递增**；同 epoch 多次发射共享本值，旧 generation 异步回调经 expected_generation != _runtime_generation 守卫永久 no-op。emission_id / runtime_id 与本值职责不同。
var _runtime_generation: int = 0
## 运行期已使用移动次数（R 清零）；唯一事实来源，核心与 DragFlowController 不持有同步副本，规则全部委托 RuntimeMoveRules。
var _runtime_moves_used: int = 0
## Particle 整数 Tick 集中调度器（B3b-1）：generation 镜像由 epoch-start / R 的 begin_generation(_runtime_generation) 绑定；M4-E1 起 begin_generation 只在 epoch-start / R 调用，request_fire 仅 emit_particle（不清空），故同 epoch 多粒并存。LRC 持有（epoch/reset/emit/accessor/反射测试），driver 持共享引用。
var _particle_scheduler: _ParticleScheduler
## Particle Tick 驱动协作器（M4-E1 强制拆分；M4-E2 settle 拆为 on_particle_terminated + on_drained）：持有 pump + pump_active 单链 flag，驱动 tick 推进 / BatchEvent 应用 / per-runtime TERMINATE 上报 / 技术 drain。
var _particle_tick_driver: _ParticleTickDriver
## Particle 视觉事件发布 Callable（B4a）：把 detached EMITTED/TICK_BATCH_COMMITTED/CLEARED 转发到外部视觉层；本控制器只调用并转发 builder 产物，不解释事件/构造 payload/维护 View，与 _refresh_runtime_ui 等同为 outward Callable（LRC 不引入 signal）。
var _publish_particle_visual_event: Callable
## 活动 emission 登记表（M4-E1；M4-E2 含 runtime_id 双向映射）：emission_id 单调递增、RAY/PARTICLE 共用、R 后不复用。成功 fire allocate、emission 结束 mark_finished、R 时 clear；per-emission 聚合结算由 _finish_emission 据 has_active 推进。
var _active_emission_registry: _ActiveEmissionRegistry
## 主发射器统一 0.5s cooldown（M4-E1；M4-E3 起为 request_fire 硬门）：RAY/PARTICLE 共用、形态切换不重置。
## 成功 fire 调 on_fire_success（恰好一次），R 与 epoch-start 调 reset；失败/拒绝路径不消费、不刷新、不延长。
var _emitter_fire_cooldown: _EmitterFireCooldown
var _fire_request_preflight: _FireRequestPreflight
## RAY emission 执行驱动器（M4-E2.1 从本控制器拆出）：接收 immutable preflight Ray fire data，执行 RayExecutionModule + 应用 step 视觉/水晶 + 管理 visual delay + 完成回调 _finish_emission。LRC 仍是唯一 lifecycle orchestrator。
var _ray_emission_driver: _RayEmissionDriver
## 关卡配置的 Q 形态切换开关（M4-E4；构造注入只读，运行期不变）：false 时任何状态 Q 均无效；权限判定委派 RuntimeStateRules.can_switch_light_form。
var _allow_form_switch: bool = false


## 构造运行期编排控制器；依赖全部由核心注入，不在本类构造场景节点或第二套事实。drag_flow_controller 直接注入以安全取消拖拽。
## [br]particle_tick_pump 为光粒 Tick 驱动泵的技术 seam（B3b-2.1 MF-2）：正式留空→构造冻结 0.1s cadence 的 ParticleTickPump；测试可传入 tests/** ControllableParticleTickPump 替身（Variant 鸭子）显式 resume 驱动 Tick。该 seam 不进 gameplay 真值（Tick 真值仍为 scheduler._current_tick 整数递增；0.1s cadence 唯一来源 ParticleTickPump.PARTICLE_TICK_SECONDS）。
## [br]emitter_fire_cooldown_clock 为发射 cooldown 的可控时钟 seam（M4-E3）：正式留空→cooldown 读单调时钟 Time.get_ticks_msec()；测试注入 () -> float 可控时钟驱动 0.499/0.500 边界，不真实等待。cooldown 间隔真值唯一来源 EmitterFireCooldown.FIRE_INTERVAL_SECONDS，本参数不得改变它。
## [br]allow_form_switch 为关卡配置的 Q 形态切换开关（M4-E4；主发射器 v0.3 §4.2）：false（默认）时任何状态 Q 均无效；true 时非 COMPLETED 状态允许 RAY↔PARTICLE 切换（只影响后续发射快照）。开关事实由关卡配置唯一提供，本控制器只读取。
func _init(
		run_state_controller: _RunStateController,
		fixed_emitter: _FixedEmitter,
		light_world_query: _LightWorldQuery,
		light_visual_controller: _LightVisualController,
		objective_controller: _ObjectiveController,
		placement_controller: _PlacementController,
		inventory_controller: _InventoryController,
		drag_flow_controller: _DragFlowController,
		max_propagation_steps: int,
		pulse_visual_duration_seconds: float,
		runtime_move_limit: int,
		refresh_runtime_ui: Callable,
		set_complete_label_visible: Callable,
		assert_inventory_consistency: Callable,
		publish_particle_visual_event: Callable,
		particle_tick_pump: Variant = null,
		emitter_fire_cooldown_clock: Callable = Callable(),
		allow_form_switch: bool = false
) -> void:
	_run_state_controller = run_state_controller
	_fixed_emitter = fixed_emitter
	_light_world_query = light_world_query
	_light_visual_controller = light_visual_controller
	_objective_controller = objective_controller
	_placement_controller = placement_controller
	_inventory_controller = inventory_controller
	_drag_flow_controller = drag_flow_controller
	_max_propagation_steps = max_propagation_steps
	_pulse_visual_duration_seconds = pulse_visual_duration_seconds
	_runtime_move_limit = runtime_move_limit
	_refresh_runtime_ui = refresh_runtime_ui
	_set_complete_label_visible = set_complete_label_visible
	_assert_inventory_consistency = assert_inventory_consistency
	# B3b-1：构造 Particle 调度器，注入同一 _light_world_query（提供 is_in_bounds/is_wall_cell/has_crystal_at/get_light_mechanism_at 只读契约）。
	# RAY 形态不使用调度器，但始终构造以使 reset_runtime 的旧 generation 失效路径统一；调度器无外部可变入口，仅本控制器驱动。
	_particle_scheduler = _ParticleScheduler.new(_light_world_query)
	_publish_particle_visual_event = publish_particle_visual_event
	# Tick 驱动泵技术 seam：正式（particle_tick_pump == null）构造冻结 0.1s cadence 的 ParticleTickPump；测试注入 tests/** 可控替身。cadence 唯一来源 ParticleTickPump.PARTICLE_TICK_SECONDS，本参数不得改变它。
	var tick_pump: Variant = _ParticleTickPump.new() if particle_tick_pump == null else particle_tick_pump
	# M4-E2 settle contract 拆分：driver 经 on_particle_terminated 逐 runtime 上报 LRC（per-emission 结算），on_drained 仅技术停泵事实（不完成 emission / 不切 RunState）。
	_particle_tick_driver = _ParticleTickDriver.new(
		_particle_scheduler, tick_pump, _objective_controller, _publish_particle_visual_event,
		Callable(self, "get_runtime_generation"),
		Callable(_run_state_controller, "is_current_pulse_active"),
		Callable(self, "_on_particle_terminated"),
		Callable(self, "_on_particle_subsystem_drained"))
	# M4-E1 多发射 Runtime 基础 + M4-E3：registry / 统一 0.5s cooldown（时钟 seam：正式留空读单调时钟；测试注入 () -> float 控 0.499/0.500 边界）/ 零副作用发射预检（依赖与 LRC 共享同一实例，不建第二套事实）。
	_active_emission_registry = _ActiveEmissionRegistry.new()
	_emitter_fire_cooldown = _EmitterFireCooldown.new(emitter_fire_cooldown_clock)
	_fire_request_preflight = _FireRequestPreflight.new(drag_flow_controller, run_state_controller, fixed_emitter, _emitter_fire_cooldown)
	_allow_form_switch = allow_form_switch
	# M4-E2.1：RAY emission 执行/timer/visual delay 迁入 RayEmissionDriver（immutable snapshot；不再重读 _fixed_emitter）。
	# finish_emission 经 LRC._finish_emission 聚合结算（守卫全在 _finish_emission 内）；on_steps_applied 刷新完成标签（driver 不读 Objective 真值）。
	_ray_emission_driver = _RayEmissionDriver.new(
		_light_visual_controller, _objective_controller, _light_world_query,
		_max_propagation_steps, _pulse_visual_duration_seconds,
		Callable(self, "_finish_emission"), Callable(self, "_on_ray_steps_applied"))
	# M4-E1 generation 新语义：监听 SETUP→READY 进入新 Runtime epoch——rsc.begin_runtime 与 request_begin_runtime 两条路径都经 state_changed 覆盖。
	_run_state_controller.state_changed.connect(_on_state_changed)


## RunStateController.state_changed 回调（M4-E1）：仅在 SETUP→READY_TO_FIRE（进入新 Runtime epoch）时 _advance_runtime_epoch；经信号覆盖 rsc.begin_runtime 与 request_begin_runtime 两条路径。其它转换不推进 generation（R 的 →SETUP 由 reset_runtime 自行递增）。不发布 CLEARED、不切状态、不 fire。
func _on_state_changed(
		previous_state: _RuntimeInteractionTypes.RunState,
		new_state: _RuntimeInteractionTypes.RunState
) -> void:
	if previous_state == _RuntimeInteractionTypes.RunState.SETUP and new_state == _RuntimeInteractionTypes.RunState.READY_TO_FIRE:
		_advance_runtime_epoch()


## 推进 runtime generation 到新 epoch 并复位 epoch 级组件（M4-E1）：gen +=1 → scheduler.begin_generation 绑定新镜像（清旧光粒 + 重置 tick）→ registry.clear → cooldown.reset → pump guard 清零。由 SETUP→READY 与 reset_runtime 共享；旧 generation 异步回调此后经守卫永久 no-op。
func _advance_runtime_epoch() -> void:
	_runtime_generation += 1
	_particle_scheduler.begin_generation(_runtime_generation)
	_active_emission_registry.clear()
	_emitter_fire_cooldown.reset()
	_particle_tick_driver.reset_pump_active()


## 请求发射一次普通脉冲（B3b-1 统一 RAY/PARTICLE 入口；M4-E3 冻结 transaction 正式接线：零副作用 preflight→immutable 快照→状态事务→dispatch→成功消费 cooldown 一次/失败仅回滚本次）。
## [br]状态事务：READY_TO_FIRE/MOVE_WINDOW 首发经 begin_pulse 进 PULSE_ACTIVE；PULSE_ACTIVE 追加发射不请求 begin_pulse（禁止非法自环）；场上活动光不阻止再次发射（唯一节流 0.5s cooldown）。
## [br]RAY 走 FireRequest→RayExecutionModule→逐 step 视觉（携带 emission_id）→水晶→完成标签→异步结束；PARTICLE 走 emit_particle + bind runtime 到 emission。返回 true=已启动发射；false=被拖拽/状态/cooldown/方向/形态拒绝或 dispatch 安全失败（均不消费 cooldown）。
## [br]M4-E2：不再 clear_path()——新 Ray 不清旧 Ray（per-emission ownership；单发射玩家路径下上一 emission 已由自身 _finish_emission 清视觉）。
func request_fire() -> bool:
	# 1. 零副作用 preflight（M4-E3）：拖拽/状态（含 PULSE_ACTIVE repeated fire）/0.5s cooldown/形态/方向 → immutable 快照；任一拒绝零副作用返回。
	var snapshot: Dictionary = _fire_request_preflight.evaluate()
	if snapshot.is_empty():
		return false
	# 2. 状态事务：首发（READY_TO_FIRE/MOVE_WINDOW）经 begin_pulse 进入 PULSE_ACTIVE；已 PULSE_ACTIVE 的追加发射不请求 begin_pulse（非法自环）。
	if not _run_state_controller.is_current_pulse_active():
		if not _run_state_controller.begin_pulse():
			return false
	# 3. per-emission transaction（M4-E2.1）：dispatch 失败已在 _dispatch_emission 内 rollback 本 emission；abort 仅在无任何活动 emission 时退出 PULSE_ACTIVE（joined failure 保持 PULSE_ACTIVE，不影响旧 emission）。
	var current_generation: int = _runtime_generation
	var emission_id: int = _dispatch_emission(current_generation, snapshot["light_form"], snapshot["emitter_cell"], snapshot["direction"])
	if emission_id < 0:
		_abort_pulse_if_no_active_emission()
		return false
	# 4. 成功提交（M4-E3）：cooldown 恰好消费一次；所有拒绝/失败路径已提前 return，不消费 cooldown。
	_emitter_fire_cooldown.on_fire_success()
	return true


## 请求切换主发射器光形态（M4-E4 Q 正式入口；主发射器 v0.3 §4.2 冻结规则）。
## [br]权限：关卡 allow_form_switch=true 且当前状态非 COMPLETED（SETUP/READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW 均允许），判定委派 RuntimeStateRules.can_switch_light_form；
## [br]  allow_form_switch=false 或 COMPLETED 拒绝，FixedEmitter._form 保持不变。
## [br]返回：成功返回切换后的 LightForm 数值（RAY/PARTICLE，供调用方驱动形态提示 UI）；被拒绝返回 -1。
## [br]副作用（冻结语义）：仅翻转 FixedEmitter._form——只影响后续发射快照（下一次 request_fire 以新形态发射）；
## [br]  不改变/不重建/不清除场上已存在 emission（Ray 视觉/Particle runtime 不受影响）、不自动发射、
## [br]  不重置/不消费/不延长共享 0.5s cooldown、不切 RunState。
func request_switch_light_form() -> int:
	if not _RuntimeStateRules.can_switch_light_form(_run_state_controller.get_current_state(), _allow_form_switch):
		return -1
	return _fixed_emitter.toggle_light_form()


## per-emission 编排 seam（M4-E2 内部/private；M4-E2.1 显式成功/失败 transaction）：allocate emission_id + 按 form dispatch；成功返回 emission_id，失败 _rollback_emission（mark_finished 本 emission + 清视觉，不留 zombie）返回 -1。
## request_fire（M4-E3 已开放 repeated fire）经此入口；白盒测试仍经反射直接调用本 seam 制造确定性第二 emission / joined failure。不消费 cooldown（玩家路径 dispatch 成功后才消费）。
## 失败只回滚本次 emission——不清其它 Ray/Particle、不 mark_finished 其它 emission、不 finish 整个 pulse；joined failure 由 _abort_pulse_if_no_active_emission 决定是否退 PULSE_ACTIVE。
func _dispatch_emission(generation: int, light_form: int, emitter_cell: Vector2i, direction: Vector2i) -> int:
	var emission_id: int = _active_emission_registry.allocate(generation, light_form)
	var dispatched: bool = false
	match light_form:
		_LightEmissionTypes.LightForm.RAY:
			# immutable snapshot：driver 不再重读 _fixed_emitter；dispatch 后修改 FixedEmitter 不影响本 Ray。
			dispatched = _ray_emission_driver.dispatch(get_tree(), generation, emission_id, emitter_cell, direction)
		_LightEmissionTypes.LightForm.PARTICLE:
			dispatched = _begin_particle_emission(generation, emission_id, emitter_cell, direction)
		_:
			# 未知 form：明确失败 + rollback（不落入 Ray 分支）。
			push_error("LevelRuntimeController: 未知 light_form %d，dispatch 拒绝并 rollback emission %d。" % [light_form, emission_id])
			dispatched = false
	if not dispatched:
		_rollback_emission(emission_id)
		return -1
	return emission_id


## 回滚单次失败 emission（M4-E2.1）：mark_finished（不留 active zombie）+ 清本 emission Ray 视觉（幂等）。emission_id 形成不复用空洞（allocator 不回拨）。
## 只回滚本次——不清其它 Ray/Particle、不 mark_finished 其它 emission、不 finish 整个 pulse。PARTICLE 失败均在 emit 前/emit 失败/emit 后 bind 防御拒绝（bind 拒绝时刚发射光粒已在 _begin_particle_emission 内即时撤销），未 bind runtime / 未发 EMITTED，无 scheduler 残留光粒。
func _rollback_emission(emission_id: int) -> void:
	_active_emission_registry.mark_finished(emission_id)
	_light_visual_controller.clear_emission(emission_id)


## Ray 逐 step 应用完成回调（M4-E2.1；driver 不读 Objective 真值，只通知“steps 已应用”，本控制器刷新完成标签）。
func _on_ray_steps_applied() -> void:
	_set_complete_label_visible.call(_objective_controller.is_completed())


## PARTICLE emission 启动（M4-E2 per-emission；由 _dispatch_emission 调用）：scheduler 已由 epoch-start 绑定当前 generation——此处仅 emit_particle + bind runtime_id 到 emission_id。
## [br]scheduler 镜像不一致（被毒化等）、emission 不活动（M4-E3 bind 前置防御）或 emit 失败返回 false（交 _dispatch_emission 回滚 allocation；emit 前拒绝路径零光粒残留）；emit 成功则 bind runtime 到 emission（返回值显式检查——防御拒绝时先经 scheduler 内部协作方法 _rollback_emitted_particle 撤销刚发射光粒再返回 false，失败路径零光粒残留）并启动 Tick 泵单链。
## [br]emit 用 scheduler._current_tick 为基线，故同 epoch 第二颗以其发射时刻 Tick 正确共存；runtime_id 与 emission_id 经 Registry 双向绑定，TERMINATE 时反查。
func _begin_particle_emission(generation: int, emission_id: int, emitter_cell: Vector2i, direction: Vector2i) -> bool:
	# 防御性校验 scheduler 镜像不一致（被毒化等）则返回 false（保留旧 begin_generation 失败的安全语义 test_16）；epoch-start 已绑定 generation，此处不再 begin_generation。
	if _particle_scheduler.get_current_generation() != generation:
		push_error("LevelRuntimeController: Particle scheduler 未绑定到当前 generation %d（实际 %d），拒绝本次 emission。" % [generation, _particle_scheduler.get_current_generation()])
		return false
	# M4-E3 bind 前置防御：emission 不活动（未登记/已 finish）时 bind 必失败——先于 emit 拒绝，保证失败路径零光粒残留。
	if not _active_emission_registry.is_active(emission_id):
		push_error("LevelRuntimeController: emission %d 不活动，拒绝 Particle 发射（bind 前置防御）。" % [emission_id])
		return false
	# 发射一颗光粒：runtime_id 由 scheduler 单调分配；同 generation 多次 emit 各得不同 runtime_id 并存（不清空旧光粒）。
	var runtime_id: int = _particle_scheduler.emit_particle(emitter_cell, direction)
	if runtime_id < 0:
		push_error("LevelRuntimeController: Particle emit_particle 失败（cell=%s direction=%s），拒绝本次 emission。" % [emitter_cell, direction])
		return false
	# M4-E2/M4-E3：bind runtime_id → emission_id（双向映射）；TERMINATE(runtime_id) 反查 emission。前置已校验 emission 活动、runtime_id 为新分配（不可能 cross-emission rebind），故 false 正常不可达；防御触发则先经 scheduler._rollback_emitted_particle（下划线私有约定的内部协作方法，仅本防御事务调用；非新增 public API）立即撤销刚发射光粒（M4-E3 Gate 2：不留 zombie 惰性存活至 epoch 重置；同步段内 Tick 未推进、无视觉事件，移除即无痕），再按 dispatch 失败回滚（registry 由 _rollback_emission 清；bind 拒绝本身零副作用不动任何映射）。
	if not _active_emission_registry.bind_particle_runtime(emission_id, runtime_id):
		push_error("LevelRuntimeController: bind_particle_runtime(emission=%d, runtime=%d) 被拒，立即撤销刚发射光粒并回滚本次 emission。" % [emission_id, runtime_id])
		_particle_scheduler._rollback_emitted_particle(generation, runtime_id)
		return false
	# M4-E4 墙体边界消失：发射期确定性前瞻——发射格前方格是否墙 / 越界（只读 world query，与 executor MOVE 前瞻同一判定），
	# 作为纯值传给 builder（payload 构造仍在 builder，本控制器不写字段）；blocked 时 Visual 半程截断到格边界、接触即删。
	var forward_cell: Vector2i = emitter_cell + direction
	var forward_blocked: bool = (
		not _light_world_query.is_in_bounds(forward_cell)
		or _light_world_query.is_wall_cell(forward_cell))
	_publish_particle_visual_event.call(_ParticleVisualEvent.build_emitted(
		_particle_scheduler.get_particle_state_snapshot(runtime_id), forward_blocked))
	# Tick 泵单链（经 driver）：同 generation 已有活动泵则复用，不启动第二条致每 0.1s 推进 2 Tick。
	_particle_tick_driver.start_pump_if_idle(get_tree(), generation)
	return true


## dispatch 失败后退出 PULSE_ACTIVE（仅当无活动 emission；M4-E2.1 取代旧 aggregate safe-fail 旁路）。
## 本次 emission 已在 _dispatch_emission rollback——本方法只决定“脉冲是否退出”。Registry 空（首/唯一 emission 失败）→ finish_pulse(false) 恢复发射前合理状态；仍有活动 emission（joined failure）→ 保持 PULSE_ACTIVE，旧 emission 生命周期不受影响。不触发完整 R。
func _abort_pulse_if_no_active_emission() -> void:
	if _active_emission_registry.has_active():
		_refresh_runtime_ui.call()
		return
	if _run_state_controller.is_current_pulse_active():
		_run_state_controller.finish_pulse(false)
	_refresh_runtime_ui.call()


## 请求正式开始运行（D7-3）：SETUP 下经 RuntimeValidationGate 校验关卡根，valid 时切换到 READY_TO_FIRE；invalid 保持 SETUP 并原样返回结构化结果供 UI 最小反馈。
## [br]非 SETUP（READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）重复请求直接返回 null：不调 Gate、不切换状态、不发额外 state_changed（正常 UI 此时 Start Run 已隐藏/禁用）。
## [br]输入：level_root 为当前关卡根 Node2D；非法根（null/非 Node2D）由 LevelValidator 以结构化 level_root_invalid ERROR 体现，本方法不替它前置判空或自愈。
## [br]返回：SETUP 下返回 LevelValidationResult（valid=已进 READY_TO_FIRE / invalid=仍 SETUP）；非 SETUP 返回 null 表示被忽略。
## [br]语义：valid = result.is_valid()==true（不存在任何 ERROR；仅 WARNING 无 ERROR 时仍为 true，严格遵循 LevelValidationResult.is_valid，不建立第二套严重度）。
## [br]副作用：valid 时仅发生一次 SETUP→READY_TO_FIRE 转换（由 RunStateController.begin_runtime 经 state_changed 体现）；
## [br]  invalid 与非 SETUP 均零玩法副作用：不自动 fire、不递增 pulse_generation、不产生 Ray、不激活水晶、不修改库存/占用/TileMap/固定对象、不消耗运行期移动次数。
## [br]边界：Gate 无状态、每次调用独立构造（与 D7-1 一致）；本方法只决定“是否继续生命周期”，不复制 Validator 规则；按钮本身不发射，fire 仍走 request_fire。
func request_begin_runtime(level_root: Node) -> _LevelValidationResult:
	# 1. 非 SETUP 拒绝重复请求：不调 Gate、不改状态、不发额外 state_changed（正常 UI 此时 Start Run 已隐藏/禁用）。
	if not _run_state_controller.can_begin_runtime():
		return null
	# 2. 无状态 Gate 原样返回结构化 LevelValidationResult；本控制器不复制 Validator 规则、不前置判空 level_root。
	var result: _LevelValidationResult = _RuntimeValidationGate.new().validate_for_run_start(level_root)
	# 3. valid（含仅 WARNING 无 ERROR）→ 一次 SETUP→READY_TO_FIRE 转换；invalid 保持 SETUP，结构化结果原样回 UI。
	#    Gate 不切状态、begin_runtime 仍校验 SETUP（此时仍为 SETUP，转换必成），故整个请求至多一次状态转换。
	if result.is_valid():
		_run_state_controller.begin_runtime()
	return result


## 统一 per-emission 聚合结算（M4-E2）：Ray async timer（经 RayEmissionDriver._schedule_completion 回调）与 Particle _on_particle_terminated 均经此入口，不复制两套结算。mark_finished + clear_emission(自身 Ray 视觉)；registry 仍有 active → 保持 PULSE_ACTIVE；registry 已空 → Objective complete ? COMPLETED : MOVE_WINDOW。
func _finish_emission(expected_generation: int, emission_id: int) -> void:
	# 过期回调保护：结束清理前再次确认这是当前有效 generation。
	if expected_generation != _runtime_generation:
		return
	if not _run_state_controller.is_current_pulse_active():
		return
	# emission 不存在 / 已完成（重复回调 / stale）：安全 no-op。
	if not _active_emission_registry.is_active(emission_id):
		return
	_active_emission_registry.mark_finished(emission_id)
	# 只清本 emission 的 Ray 视觉（PARTICLE emission 无 Ray 段，clear_emission 天然 no-op；PARTICLE View 由 TERMINATE 视觉事件逐粒移除）。
	_light_visual_controller.clear_emission(emission_id)
	# 仍有其它 active emission → 保持 PULSE_ACTIVE 不结算（多发射 per-emission 生命周期核心）。
	if _active_emission_registry.has_active():
		_refresh_runtime_ui.call()
		return
	# 最后一个 active emission 结束 → 聚合结算 RunState。
	var level_completed: bool = _objective_controller.is_completed()
	var next_state: _RuntimeInteractionTypes.RunState = _RuntimeStateRules.get_post_pulse_state(level_completed)
	# COMPLETED 进入冻结前由本控制器取消当前拖拽，必须在请求状态转换前完成，避免冻结后鼠标松开仍提交移动/回收。
	if next_state == _RuntimeInteractionTypes.RunState.COMPLETED and _drag_flow_controller.is_dragging():
		_drag_flow_controller.cancel_current_drag()
	# 请求 RunStateController 切换状态；失败通过现有错误边界暴露并安全退出。
	if not _run_state_controller.finish_pulse(level_completed):
		push_error("LevelRuntimeController: RunStateController.finish_pulse 被拒绝，无法结束脉冲。")
		return
	# 完成结果保留：路径消失后，已经成立的关卡完成标签继续显示。
	if _run_state_controller.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED:
		_set_complete_label_visible.call(true)
	_refresh_runtime_ui.call()


## Particle TERMINATE 逐 runtime 上报入口（M4-E2；由 ParticleTickDriver.on_tick 对每条 TERMINATE BatchEvent 调用）：generation mismatch / 非活动脉冲 → no-op；unbind_particle_runtime 反查并解绑其 emission，该 emission 已无 runtime → _finish_emission 推进 per-emission 结算。
## [br]Scheduler 不知 emission_id——runtime_id → emission_id 反查经 Registry；多粒 emission 最后一个 runtime 解绑才 finish 该 emission。
func _on_particle_terminated(expected_generation: int, runtime_id: int) -> void:
	if expected_generation != _runtime_generation:
		return
	if not _run_state_controller.is_current_pulse_active():
		return
	var emission_id: int = _active_emission_registry.unbind_particle_runtime(runtime_id)
	if emission_id <= 0:
		return
	if _active_emission_registry.get_emission_runtime_count(emission_id) == 0:
		_finish_emission(expected_generation, emission_id)


## Particle 子系统 drained 技术 callback（M4-E2；由 driver 在 is_drained 时调用）。仅技术事实——scheduler 无活动 Particle；driver 已据此停泵（回调前清 _pump_active 保重入安全）。不完成 emission / 不切 RunState / 不清视觉——emission 结算已由 _on_particle_terminated 逐 runtime 完成。
func _on_particle_subsystem_drained(_expected_generation: int) -> void:
	# 故意为空（drain 语义已由 driver 据 is_drained 停泵体现）；保留为技术诊断 seam 与 driver callback 合同。
	pass


## R 完整重置：推进 runtime generation 到新 epoch（_advance_runtime_epoch：gen++ → scheduler 绑定新镜像清旧光粒 → registry.clear → cooldown.reset → pump guard 清零）→ 发布 CLEARED → 安全取消拖拽→清全部光路视觉（clear_all，M4-E2）→重置水晶→隐藏完成标签→PlacementController.clear_all_placed 逐项复用回收事务清理玩家机关→清零移动次数→回 SETUP→刷新 UI→一致性断言。
## [br]不删除发射器/墙体/水晶/静态内容；不调用 occupancy.clear()；clear_all_placed 逐项复用 recycle_placed 回收事务，每项通过 InventoryController 库存归还预留（reserve→commit）提交，部分失败项完整保留节点/映射/占用，不由本控制器建立第二套 reconcile 计算。
## [br]R 在 SETUP/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 均可执行；旧异步回调（Ray timer / Particle Tick 泵）因 generation 不匹配不再清理或改变新状态；旧 emission_id 在新 epoch 天然失效（registry.clear + emission_id 跨 R 不复用）。
func reset_runtime() -> void:
	# 1. 推进 runtime generation 到新 epoch（M4-E1）：gen +=1 → scheduler 绑定新镜像（清旧光粒 + 重置 tick）→ registry.clear → cooldown.reset → pump guard 清零。
	#    使旧 generation 的 Ray 异步结束 / Particle Tick 泵回调经 generation 守卫永久 no-op；旧光粒已随 begin_generation 清空；旧 emission_id 随 registry.clear 失效。
	_advance_runtime_epoch()
	# 1b. 发布 CLEARED 使视觉层清全部旧 Particle View（new_generation > watermark 推进并清旧）。
	_publish_particle_visual_event.call(_ParticleVisualEvent.build_cleared(_runtime_generation - 1, _runtime_generation))
	# 2. 安全取消当前拖拽：should_assert_consistency=false，把断言延后到玩家机关统一清理之后。
	if _drag_flow_controller.is_dragging():
		_drag_flow_controller.cancel_current_drag(false)
	# 3. 清理全部光路视觉（M4-E2 per-emission ownership：clear_all 全清所有 emission 的 Ray 段）。
	_light_visual_controller.clear_all()
	# 4. 重置水晶点亮与完成事实。
	_objective_controller.reset_runtime()
	# 4b. 恢复关卡配置的初始光形态（M4-E4；主发射器 v0.3 §9.3/§11.11：修改过形态后按 R 恢复该关卡初始形态）。
	_fixed_emitter.reset_to_initial_form()
	# 5. 隐藏完成标签。
	_set_complete_label_visible.call(false)
	# 6/7. 玩家机关清理由 PlacementController.clear_all_placed 逐项复用 recycle_placed 回收事务负责；每项通过 InventoryController 库存归还预留（reserve→commit）提交，部分失败项完整保留节点/映射/占用，不由本控制器建立第二套 reconcile 计算。
	var clear_result: _PlacementController.ClearPlacedResult = _placement_controller.clear_all_placed()
	if clear_result.unresolved_count > 0:
		push_error("LevelRuntimeController: R重置玩家机关清理未完全成功，残留 %d 个机关，库存按残留数对齐。" % [clear_result.unresolved_count])
	# 8. 运行期移动次数清零。
	_runtime_moves_used = 0
	# 9. 状态回 SETUP（幂等，已在 SETUP 时不发信号）。
	_run_state_controller.reset_to_setup()
	# 10. 刷新运行 UI（库存 + 移动次数 + 完成标签）。
	_refresh_runtime_ui.call()
	# 11. 库存、映射、占用一致性断言（仅 Debug 构建）。
	if OS.is_debug_build():
		_assert_inventory_consistency.call()


## 剩余运行期移动次数 max(limit - used, 0)；委托 RuntimeMoveRules，不在此递增，不复制规则。
func get_runtime_moves_remaining() -> int:
	return _RuntimeMoveRules.compute_runtime_moves_remaining(_runtime_move_limit, _runtime_moves_used)


## 已使用运行期移动次数（只读）。
func get_runtime_moves_used() -> int:
	return _runtime_moves_used


## 运行期移动次数上限（构造时由核心传入的配置值）。
func get_runtime_move_limit() -> int:
	return _runtime_move_limit


## 当前 Runtime generation（只读，供测试与诊断；M4-E1 新语义：Runtime/reset epoch token，不再每次 fire 递增）。
func get_runtime_generation() -> int:
	return _runtime_generation


## 当前活动 emission 数量（只读诊断 / 测试；M4-E1）：成功 fire +1、emission 结束 -1、R 清零。
func get_active_emission_count() -> int:
	return _active_emission_registry.active_count()


## 主发射器 cooldown 是否 ready（只读诊断 / 测试；M4-E1）：成功 fire 后 0.5s 内 false，R 后 true。
func is_fire_cooldown_ready() -> bool:
	return _emitter_fire_cooldown.is_ready()


## 当前活动光粒数量（只读诊断 / 测试；B3b-1）。
func get_particle_active_count() -> int:
	return _particle_scheduler.get_active_count()


## 当前 Particle generation 镜像（只读诊断 / 测试；真值为 _runtime_generation，二者必须相等）。
func get_particle_generation() -> int:
	return _particle_scheduler.get_current_generation()


## 当前 Particle 绝对整数 Tick（只读诊断 / 测试；B3b-2）。转发 scheduler.get_current_tick，不持有第二份 Tick。
## gameplay Tick 真值仍为 scheduler._current_tick 整数递增，现实 0.1s 间隔只驱动其递增频率。
func get_particle_tick() -> int:
	return _particle_scheduler.get_current_tick()


## 组装一份 detached 运行期事实快照（D7-R1 只读诊断；零副作用）。
## [br]委派 RuntimeDiagnosticsSnapshotBuilder.build：读取本控制器私有事实（generation / 移动次数 / allow_form_switch）+
##   registry / cooldown / scheduler / light_visual_controller 只读访问器，返回纯值 Dictionary 供 Diagnostics 侧采样。
## [br]边界：本方法只读——不推进 Tick、不 finish emission、不重置 / 消费 cooldown、不动视觉、不改 RunState；
##   返回 Dictionary 与内部真值完全 detached，调用方修改零影响。
func get_runtime_diagnostics_snapshot() -> Dictionary:
	return _RuntimeDiagnosticsSnapshotBuilder.build(
		_active_emission_registry,
		_emitter_fire_cooldown,
		_particle_scheduler,
		_light_visual_controller,
		_runtime_generation,
		_runtime_moves_used,
		get_runtime_moves_remaining(),
		_runtime_move_limit,
		_allow_form_switch
	)


## 按 runtime_id 取活动光粒的只读快照（B3b-1.1 只读边界收口；B3b-2.1 MF-3 起直接转发调度器 detached snapshot；未登记或已移出返回 null）。
## [br]返回值为与内部真实 state 脱离的 detached Dictionary：含 runtime_id/generation/cell/direction/speed_tier/step_started_tick/next_move_tick/active 八字段（皆为值类型副本）。
## [br]外部修改返回 Dictionary 不得改变真实光粒——真实状态唯一存在 Scheduler/ParticleRuntimeState 内部。
## [br]本控制器不复制字段构造逻辑：snapshot 合同唯一由 ParticleScheduler.get_particle_state_snapshot 定义，本方法纯转发；不暴露 ParticleScheduler、_active_states，也不暴露可调用 apply_move/terminate 的内部 state 引用。
func get_particle_state_snapshot(runtime_id: int) -> Variant:
	return _particle_scheduler.get_particle_state_snapshot(runtime_id)


## 是否处于 PULSE_ACTIVE；转发 RunStateController.is_current_pulse_active，不保存第二份状态。
func is_pulse_active() -> bool:
	return _run_state_controller.is_current_pulse_active()


## 是否允许正式提交一次已放置机关跨格移动；委托 RuntimeMoveRules.can_commit_placed_move，传入当前状态与剩余次数，不复制规则。
func can_commit_placed_move(original_cell: Vector2i, target_cell: Vector2i) -> bool:
	return _RuntimeMoveRules.can_commit_placed_move(
		_run_state_controller.get_current_state(),
		get_runtime_moves_remaining(),
		original_cell,
		target_cell
	)


## 若本次跨格移动应计入运行期次数则扣除一次并返回 true；原格、SETUP、COMPLETED、取消、回收、新放置不扣。委托 RuntimeMoveRules 判定。
func consume_runtime_move_if_required(original_cell: Vector2i, target_cell: Vector2i) -> bool:
	if not _RuntimeMoveRules.should_count_runtime_move(
		_run_state_controller.get_current_state(), original_cell, target_cell
	):
		return false
	_runtime_moves_used += 1
	return true


## 无条件扣除一次运行期移动次数；供 DragFlowController 在已通过 should_count_runtime_move 校验后经核心 Callable 委托调用，避免重复判定。
func consume_runtime_move() -> void:
	_runtime_moves_used += 1
