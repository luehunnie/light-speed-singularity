class_name ParticleTickDriver
extends RefCounted

## Particle Tick 驱动协作器（M4-E1 强制拆分；M4-E2 拆 settle contract 为 per-runtime 上报 + 技术 drain）。
## 职责：持有 pump_active 单链 flag + scheduler/pump 引用，按冻结顺序驱动每个整数 Tick——generation 守卫 → scheduler.advance_one_tick
##   → 应用本批 BatchEvents（Crystal 命中）→ 发布 TICK_BATCH_COMMITTED → 逐 runtime TERMINATE 上报 LRC（per-emission 结算）→ 技术 drain 判定（停泵）。
##   pump 单链保证：同 generation 同一时刻只存在一条有效 pump 链——start_pump_if_idle 在 _pump_active 已真时复用，不启动第二条致每 0.1s 推进 2 Tick。
## M4-E2 关键变更（settle contract 拆分）：
##   - 旧：scheduler.is_drained() → _settle(LRC._finish_current_pulse) 直接结束整个 pulse（单 emission 模型，drain==pulse 完成）。
##   - 新：drain 只是技术事实（停共享 Tick 泵）；emission 结算改为逐 runtime TERMINATE 上报——on_particle_terminated(gen, runtime_id) 通知 LRC，
##     LRC 反查 emission_id、解绑 runtime、该 emission 无 runtime 时 _finish_emission(gen, eid)；最后一条 active emission 结束才聚合结算 RunState。
##   - 故可能出现“Scheduler drained 但仍有 Ray emission active”，或“一个 Particle emission 已结束但另一 Particle 活跃致 Scheduler 未 drained”。
## M4-E2.1 stale drained 修复：on_tick 在 drained_provisional 清 flag + 跑完 TERMINATE callback 后，**重新校验**调用瞬间是否仍 drained
##   （gen 仍匹配 + 仍 PULSE_ACTIVE + scheduler.is_drained() 仍 true）才 on_drained。TERMINATE callback 同步创建新 Particle 时不再 drained →
##   旧链 return false 停止、新泵由 callback 启动、**不报告** subsystem drained（杜绝 stale on_drained 与“有粒无泵”）。
## 位置：gameplay/runtime 下；纯驱动协作器，由 LevelRuntimeController 唯一持有；不拥有 RunState/Objective/Registry/Cooldown/generation 真值——全部经 ref / Callable 读 LRC。
## 依赖：scheduler（ParticleScheduler 引用，advance/snapshot/get_current_*/is_drained）、pump（ParticleTickPump 或测试替身，run 签名一致）、objective（try_activate_crystal_at）、
##   publish_event Callable（发布 TICK_BATCH_COMMITTED）、get_generation Callable（读 _runtime_generation 真值）、is_pulse_active Callable、
##   on_particle_terminated Callable（→ LRC._on_particle_terminated，逐 runtime 结算）、on_drained Callable（→ LRC._on_particle_subsystem_drained，纯技术停泵事实）。
## 不负责（硬边界）：不自增 / 自产 generation（真值 LRC._runtime_generation）；不操作 RunState / Registry / Cooldown；不知 emission_id（TERMINATE 只上报 runtime_id，emission 反查归 LRC/Registry）；
##   不决定 COMPLETED / MOVE_WINDOW（per-emission 聚合结算归 LRC._finish_emission）；不创建 Timer / 不解释视觉节点；不 emit_particle（发射由 LRC._begin_particle_emission 经 scheduler 直接 emit）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ParticleStepExecutor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")


## ParticleScheduler 引用（advance_one_tick / is_drained / get_current_* / get_particle_state_snapshot）。scheduler 由 LRC 拥有，本类持共享引用。
var _scheduler: Variant
## ParticleTickPump 引用（正式 / 测试替身，run 签名一致）。pump 由 LRC 注入本类驱动。
var _pump: Variant
## ObjectiveController 引用（BatchEvent MOVE.has_crystal → try_activate_crystal_at）。
var _objective: Variant
## 发布 TICK_BATCH_COMMITTED 的 outward Callable（与 LRC 同源，转发 builder 产物）。
var _publish_event: Callable
## 读 LRC._runtime_generation 真值的 Callable（generation 守卫用；本类不持有 generation）。
var _get_generation: Callable
## 读 RunStateController.is_current_pulse_active 的 Callable。
var _is_pulse_active: Callable
## 逐 runtime TERMINATE 上报 LRC 的 Callable（M4-E2；签名 (expected_generation: int, runtime_id: int) -> void；→ LRC._on_particle_terminated）。
## LRC 据此反查 emission_id、解绑 runtime、该 emission 无 runtime 时 _finish_emission。
var _on_particle_terminated: Callable
## 技术 drain 上报 LRC 的 Callable（M4-E2；签名 (expected_generation: int) -> void；→ LRC._on_particle_subsystem_drained）。
## 仅技术事实（停泵语义），LRC 不得据此完成 emission / 切 RunState（emission 结算已由 on_particle_terminated 完成）。
var _on_drained: Callable
## pump 单链 flag（M4-E1 纯技术 guard，非 gameplay 真值）：同 generation 同一时刻只允许一条有效 pump 链。
## start_pump_if_idle 设 true、on_tick 当前 gen 链退出（gen 匹配且返回 false）/ reset_pump_active 清 false；旧 gen 链退出不清本标记。
var _pump_active: bool = false


## 构造驱动器；scheduler/pump/objective 为共享引用，publish_event/get_generation/is_pulse_active/on_particle_terminated/on_drained 为回调 LRC 的 Callable。
func _init(
		scheduler: Variant,
		pump: Variant,
		objective: Variant,
		publish_event: Callable,
		get_generation: Callable,
		is_pulse_active: Callable,
		on_particle_terminated: Callable,
		on_drained: Callable
) -> void:
	_scheduler = scheduler
	_pump = pump
	_objective = objective
	_publish_event = publish_event
	_get_generation = get_generation
	_is_pulse_active = is_pulse_active
	_on_particle_terminated = on_particle_terminated
	_on_drained = on_drained


## 若当前 generation 无活动泵则启动一条（fire-and-forget）；已有活动泵则复用，不启动第二条。由 LRC._begin_particle_emission 在 emit 后调用。
## [br]输入：tree 为当前 SceneTree（pump.run 用于 create_timer）；generation 为本链捕获的 generation 快照（真值仍为 LRC._runtime_generation）。
func start_pump_if_idle(tree: SceneTree, generation: int) -> void:
	if not _pump_active:
		_pump_active = true
		_pump.run(tree, Callable(self, "on_tick"), generation)


## 清 pump_active（epoch-start / R 时由 LRC 调用，使新 epoch 可启动新泵；旧 generation 旧泵链经 on_tick 首行 generation 守卫自行 no-op 退出）。
func reset_pump_active() -> void:
	_pump_active = false


## Particle Tick 泵回调（由 ParticleTickPump.run 经 Callable 每个现实间隔调用一次）。
## [br]单 Tick 链正确性的唯一裁定点——按冻结顺序：
## [br]  ① 旧 generation 直接退出（不 advance / 不 clear flag / 不 finish）；
## [br]  ② 已不在 PULSE_ACTIVE（R / safe-fail / 外部切换 / 上层聚合结算终止了脉冲）退出并清 flag；
## [br]  ③ 推进一个 Tick + 应用本批 BatchEvents（Crystal 命中）+ 发布 TICK_BATCH_COMMITTED；
## [br]  ④ 计算 drained_provisional（技术 drain 快照）；
## [br]  ⑤ 【重入安全】若 drained_provisional，**先**清 _pump_active 再回调上层——保证上层 callback 若同步产生新 Particle（经 start_pump_if_idle）能看到 flag=false 启动新泵，杜绝“有粒无泵”；
## [br]  ⑥ 逐 runtime TERMINATE 上报 LRC（on_particle_terminated → per-emission 结算；可能触发 _finish_emission → 聚合切 RunState，或同步产生新 Particle）；
## [br]  ⑦ 【stale drained 修复】drained_provisional 后**重新校验**调用瞬间是否真正 drained——generation 仍匹配 + 仍 PULSE_ACTIVE + scheduler.is_drained() 仍 true——
## [br]     三者皆真才 on_drained；若 TERMINATE callback 同步创建了新 Particle（不再 drained），旧链 return false 停止，**不报告** subsystem drained（新泵已由 callback 启动）。
## [br]返回 true → 泵继续下一 Tick；false → 泵停止本链。
func on_tick(expected_generation: int) -> bool:
	# ① 旧 generation 永久退出（R / 新 epoch 已递增 LRC._runtime_generation）；正确性来自 generation token，不依赖 stop_all_timers / 全局 Timer 清理。
	if expected_generation != int(_get_generation.call()):
		return false
	# ② 已不在 PULSE_ACTIVE（R / safe-fail / 外部切换 / 上层聚合结算终止了脉冲）：本链退出，清 flag。
	if not bool(_is_pulse_active.call()):
		_pump_active = false
		return false
	# ③ 推进一个整数 Tick + 应用本批 BatchEvents（Crystal 命中经 ObjectiveController 现有入口激活）+ 发布 TICK_BATCH_COMMITTED。
	var events: Array = _process_tick(expected_generation)
	# ④ 技术 drain 快照（无活动光粒）；仅用于停泵判定，不直接完成 emission / RunState。
	var drained_provisional: bool = _scheduler.is_drained()
	# ⑤ 【重入安全】drained_provisional 时先清 _pump_active，再回调上层——上层 callback 若同步 emit 新 Particle + start_pump_if_idle 能看到 flag=false 启动新泵。
	if drained_provisional:
		_pump_active = false
	# ⑥ 逐 runtime TERMINATE 上报 LRC（per-emission 结算）。LRC 据此反查 emission_id、解绑 runtime、可能 _finish_emission，或同步产生新 Particle。
	#    drained_provisional 已在回调前清 flag，故若 callback 内同步产生新 Particle，新泵可正确启动。
	for event in events:
		if event.outcome == _ParticleStepExecutor.Outcome.TERMINATE:
			_on_particle_terminated.call(expected_generation, event.runtime_id)
	# ⑦ 【stale drained 修复】仅当调用瞬间仍真正 drained（gen 仍匹配 + 仍 PULSE_ACTIVE + scheduler 仍 drained）才 on_drained + 停本链。
	#    TERMINATE callback 同步创建新 Particle 时 is_drained() 已 false → 不报告 drained；旧链 return false 停止，新泵由 callback 启动。
	if drained_provisional \
			and expected_generation == int(_get_generation.call()) \
			and bool(_is_pulse_active.call()) \
			and _scheduler.is_drained():
		_on_drained.call(expected_generation)
		return false
	# drained_provisional 但 callback 已产生新 Particle（不再 drained）：旧链停止（return false），不报告 drained；
	# 非 drained 路径（仍有活动光粒）继续下一 Tick（return true）。
	if drained_provisional:
		return false
	return true


## 推进一个整数 Tick + 应用本批 BatchEvents + 发布 TICK_BATCH_COMMITTED（generation 守卫；旧 generation 返回空数组）。
func _process_tick(expected_generation: int) -> Array:
	if expected_generation != int(_get_generation.call()):
		return []
	var events: Array = _scheduler.advance_one_tick(expected_generation)
	_apply_batch_events(events)
	_publish_event.call(_ParticleVisualEvent.build_tick_committed(_scheduler.get_current_generation(), _scheduler.get_current_tick(), events))
	return events


## 按返回顺序应用一整批 BatchEvents；本批只消费 MOVE.has_crystal → ObjectiveController.try_activate_crystal_at。
## TERMINATE 不在此处理——scheduler 已完成 terminate + 批后移出；on_tick 据本批返回的 events 逐条 TERMINATE 上报 LRC（M4-E2 per-runtime 结算）。
func _apply_batch_events(events: Array) -> void:
	for event in events:
		if event.outcome == _ParticleStepExecutor.Outcome.MOVE and event.has_crystal:
			_objective.try_activate_crystal_at(event.entered_cell)
