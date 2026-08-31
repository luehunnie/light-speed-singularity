extends SceneTree

## 光屏障（LightBarrier）合同 + 集成定向测试（机关规则 光屏障 v0.6 薄膜模型）。
## 覆盖：四向朝向 × 八向入射分区扫描（每朝向恰 2 平行薄膜面「撞棱角」/ 6 穿过，撞棱角任意速度 BLOCK、
##   穿过方向进速度门——分区经 DirectionDomain.same_axis 唯一共轴判定，无六份分支）；穿过方向速度门矩阵
##   （SLOW 停 / STANDARD、FAST 过 -1 档）；RAY 恒 BLOCK（Contract 分发 + RayMechanismAdapter 映射）；
##   executor 消费机关 BLOCK → TERMINATE(MECHANISM_BLOCK)（与 WALL 同形停在格外，既有 CONTINUE/速度路径回归）；
##   真实 LightBarrier 节点 × 真实 ParticleScheduler 平行撞棱角终止 + 穿过方向 -1 档自下一传播步生效；
##   减速器→屏障（§3.5 真实速度判定）；连续双屏障快速降档链（边界 #8）；运行期零写入
##   （R 不变量：orientation 恒为 authored 值）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题；
##   机关为 Node fixture（不进场景树，_ready 不触发），用后 free。全部失败项收集后统一退出（任一失败 quit(1)）。

const _Barrier: GDScript = preload("res://gameplay/mechanisms/barrier/light_barrier.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _Contract: GDScript = preload("res://gameplay/light/interaction/light_interaction_contract.gd")
const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _RayAdapter: GDScript = preload("res://gameplay/light/ray_mechanism_adapter.gd")
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")
const _RayContext: GDScript = preload("res://gameplay/light/interaction/ray_interaction_context.gd")
const _ParticleContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)
const _Motion: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _State: GDScript = preload("res://gameplay/particle/particle_runtime_state.gd")
const _Executor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
const _Scheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _Fake: GDScript = preload("res://tests/unit/particle/fixtures/fake_particle_world_query.gd")
const _Accelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_accelerator.gd")
const _Decelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_decelerator.gd")

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 跨组共享的真实屏障节点（G5/G6 集成用；G7 校验其运行期零写入后统一 free）。
var _shared_barrier: Variant = null


func _initialize() -> void:
	_shared_barrier = _Barrier.new()
	_shared_barrier.set_orientation(_Barrier.BarrierOrientation.VERTICAL)
	_test_01_orientation_partition_sweep()
	_test_02_pass_through_speed_gate_matrix()
	_test_03_ray_always_block()
	_test_04_executor_consumes_block()
	_test_05_scheduler_edge_and_gate()
	_test_06_double_barrier_fast_chain()
	_test_07_runtime_zero_write_invariant()
	_shared_barrier.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 构造 PARTICLE 交互 Context（tier 为 _Motion.SpeedTier 值）。
func _particle_ctx(incoming: Vector2i, tier: int) -> Variant:
	return _ParticleContext.create(Vector2i(2, 0), incoming, 1, 0, tier, 7)


## 经正式 Contract 分发一次 PARTICLE 交互（返回校验后的 Result；分发层已完成 validate）。
func _dispatch_particle(mechanism: Variant, incoming: Vector2i, tier: int) -> Variant:
	return _Contract.dispatch_particle(mechanism, _particle_ctx(incoming, tier))


## 推进 scheduler 到 until_tick（不含），收集全部 BatchEvent（含 TERMINATE）。
func _collect_events(s: Variant, generation: int, until_tick: int) -> Array:
	var events: Array = []
	while s.get_current_tick() < until_tick:
		events.append_array(s.advance_one_tick(generation))
	return events


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 光屏障薄膜合同+集成测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)


# ===== 测试 =====

## 01. 四向朝向 × 八向入射分区扫描：每朝向恰 2 平行（薄膜面撞棱角）/ 6 穿过；
##     平行方向 FAST 也 BLOCK（撞棱角任意速度），穿过方向 STANDARD 进速度门 CONTINUE。
func _test_01_orientation_partition_sweep() -> void:
	const G: String = "01_四向分区扫描"
	var barrier: Variant = _Barrier.new()
	var domain: Array = _DirectionDomain.CLOCKWISE_ORDER
	for orientation_value: int in range(4):
		barrier.set_orientation(orientation_value)
		var edge_count: int = 0
		for token: StringName in domain:
			var incoming: Vector2i = _DirectionDomain.to_vector(token)
			var edge: bool = barrier.is_edge_collision(incoming)
			if edge:
				edge_count += 1
				var fast: Variant = _dispatch_particle(barrier, incoming, _Motion.SpeedTier.FAST)
				_check(G, fast.decision == _Result.Decision.BLOCK,
					"朝向 %d 平行入射 %s FAST 应 BLOCK（撞棱角）。" % [orientation_value, token])
				_check(G, fast.get_speed_delta() == 0, "撞棱角 BLOCK 不得携带速度增量。")
			else:
				var standard: Variant = _dispatch_particle(barrier, incoming, _Motion.SpeedTier.STANDARD)
				_check(G, standard.decision == _Result.Decision.CONTINUE,
					"朝向 %d 穿过入射 %s STANDARD 应 CONTINUE（进速度门）。" % [orientation_value, token])
		_check(G, edge_count == 2,
			"朝向 %d 平行方向数期望 2，实际 %d。" % [orientation_value, edge_count])
	barrier.free()


## 02. 穿过方向速度门矩阵：SLOW→BLOCK；STANDARD/FAST→CONTINUE + delta -1（4 朝向 × 6 穿过方向 × 三档数据驱动；
##     平行撞棱角方向已在测试 01 覆盖）。
func _test_02_pass_through_speed_gate_matrix() -> void:
	const G: String = "02_穿过方向速度门矩阵"
	var barrier: Variant = _Barrier.new()
	var domain: Array = _DirectionDomain.CLOCKWISE_ORDER
	var tiers: Array = [
		_Motion.SpeedTier.SLOW, _Motion.SpeedTier.STANDARD, _Motion.SpeedTier.FAST,
	]
	var tier_names: Array = ["SLOW", "STANDARD", "FAST"]
	for orientation_value: int in range(4):
		barrier.set_orientation(orientation_value)
		for token: StringName in domain:
			var incoming: Vector2i = _DirectionDomain.to_vector(token)
			if barrier.is_edge_collision(incoming):
				continue
			for tier: int in tiers:
				var result: Variant = _dispatch_particle(barrier, incoming, tier)
				if tier == _Motion.SpeedTier.SLOW:
					_check(G, result.decision == _Result.Decision.BLOCK,
						"朝向 %d 穿过 %s 慢速期望 BLOCK（能量不足）。" % [orientation_value, token])
					_check(G, result.get_speed_delta() == 0, "慢速 BLOCK 不得携带速度增量。")
				else:
					_check(G, result.decision == _Result.Decision.CONTINUE,
						"朝向 %d 穿过 %s %s 期望 CONTINUE 通过。" % [orientation_value, token, tier_names[tier]])
					_check(G, result.get_speed_delta() == -1,
						"朝向 %d 穿过 %s %s 期望 -1 档（实际 %d）。"
						% [orientation_value, token, tier_names[tier], result.get_speed_delta()])
	_check(G, barrier.get_light_interaction_forms() == [&"RAY", &"PARTICLE"],
		"形态声明应为 RAY+PARTICLE。")
	barrier.free()


## 03. RAY 恒 BLOCK：平行 + 穿过方向样本经 Contract 分发与 RayMechanismAdapter 映射均为停止。
func _test_03_ray_always_block() -> void:
	const G: String = "03_RAY恒BLOCK"
	var barrier: Variant = _Barrier.new()
	barrier.set_orientation(_Barrier.BarrierOrientation.VERTICAL)
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		var incoming: Vector2i = _DirectionDomain.to_vector(token)
		var ray_ctx: Variant = _RayContext.create(Vector2i(2, 0), incoming, 1, 0)
		var result: Variant = _Contract.dispatch_ray(barrier, ray_ctx)
		_check(G, result.decision == _Result.Decision.BLOCK,
			"RAY 入射 %s 期望恒 BLOCK（含平行与穿过方向）。" % token)
		_check(G, result.redirect_direction == Vector2i.ZERO, "RAY BLOCK 不得携带方向。")
		_check(G, result.effects.is_empty(), "RAY BLOCK 不得携带效果。")
		var adapted: Variant = _RayAdapter.evaluate(barrier, ray_ctx)
		_check(G, adapted.kind == _RayMechanismResult.Kind.BLOCK,
			"RayMechanismAdapter 应把屏障 RAY 响应映射为 BLOCK。")
	barrier.free()


## 04. executor 消费机关 BLOCK：真实 LightBarrier 在前方 → TERMINATE(MECHANISM_BLOCK)，停在格外（entered=尝试格），
##     speed_delta=0 / has_crystal=false / next_step_blocked=false；无机关与速度机关（CONTINUE 路径）回归不受影响。
func _test_04_executor_consumes_block() -> void:
	const G: String = "04_执行器BLOCK消费"
	var q: _Fake = _Fake.new()
	var barrier: Variant = _Barrier.new()
	barrier.set_orientation(_Barrier.BarrierOrientation.VERTICAL)
	q.add_mechanism(Vector2i(2, 0), barrier)
	var executor: _Executor = _Executor.new()

	# 平行入射（UP 撞棱角 → 向屏障）：next_cell=(2,0) 屏障 → TERMINATE(MECHANISM_BLOCK)。
	var state_off: Variant = _State.create_emitted(1, 0, Vector2i(2, 1), Vector2i(0, -1), 0)
	var r_off: Variant = executor.evaluate_step(state_off, q)
	_check(G, r_off.outcome == _Executor.Outcome.TERMINATE, "平行入射期望 TERMINATE。")
	_check(G, r_off.termination_reason == _Executor.TerminationReason.MECHANISM_BLOCK,
		"平行入射终止原因期望 MECHANISM_BLOCK。")
	_check(G, r_off.entered_cell == Vector2i(2, 0), "平行入射 entered_cell 应为被阻挡尝试格 (2,0)。")
	_check(G, r_off.outgoing_direction == Vector2i(0, -1), "终止时 outgoing 应为入射方向。")
	_check(G, r_off.speed_delta == 0 and not r_off.has_crystal and not r_off.next_step_blocked,
		"BLOCK 终止四字段应全为安全值。")

	# 穿过 STANDARD 对照 → MOVE 通过并 -1 档。
	var state_on: Variant = _State.create_emitted(2, 0, Vector2i(1, 0), Vector2i(1, 0), 0)
	var r_on: Variant = executor.evaluate_step(state_on, q)
	_check(G, r_on.outcome == _Executor.Outcome.MOVE, "穿过 STANDARD 期望 MOVE 通过屏障格。")
	_check(G, r_on.speed_delta == -1, "穿过 STANDARD 通过期望 -1 档。")
	_check(G, r_on.entered_cell == Vector2i(2, 0), "穿过通过 entered_cell 应为屏障格。")

	# 回归：无机关格 → MOVE delta 0；速度机关（FakeSpeedMechanism -1）→ MOVE delta -1（BLOCK 分支不影响既有路径）。
	var state_free: Variant = _State.create_emitted(3, 0, Vector2i(4, 0), Vector2i(1, 0), 0)
	var r_free: Variant = executor.evaluate_step(state_free, q)
	_check(G, r_free.outcome == _Executor.Outcome.MOVE and r_free.speed_delta == 0,
		"无机关格应保持 MOVE/delta 0 回归。")
	var speed_mech: Variant = _Fake.FakeSpeedMechanism.new()
	speed_mech.delta = -1
	q.add_mechanism(Vector2i(6, 0), speed_mech)
	var state_speed: Variant = _State.create_emitted(4, 0, Vector2i(5, 0), Vector2i(1, 0), 0)
	var r_speed: Variant = executor.evaluate_step(state_speed, q)
	_check(G, r_speed.outcome == _Executor.Outcome.MOVE and r_speed.speed_delta == -1,
		"速度机关 CONTINUE 路径应保持 MOVE/delta -1 回归。")
	barrier.free()


## 05. 真实屏障 × 真实调度器：平行 2 向撞棱角终止于格外（MECHANISM_BLOCK）；穿过 STANDARD 通过 -1 档自下一传播步生效；
##     真实减速器→屏障链证明「以进入屏障时的真实速度判定」（§3.5）。
func _test_05_scheduler_edge_and_gate() -> void:
	const G: String = "05_调度器撞棱角与门槛"

	# a) 平行 2 向：屏障 VERTICAL 于 (2,0)，平行方向逐向发射，首个事件即 TERMINATE(MECHANISM_BLOCK)（撞棱角）。
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		var incoming: Vector2i = _DirectionDomain.to_vector(token)
		if not _shared_barrier.is_edge_collision(incoming):
			continue
		var q: _Fake = _Fake.new()
		q.add_mechanism(Vector2i(2, 0), _shared_barrier)
		var s: Variant = _Scheduler.new(q)
		s.begin_generation(0)
		s.emit_particle(Vector2i(2, 0) - incoming, incoming, 1)
		var events: Array = _collect_events(s, 0, 12)
		var terminates: Array = events.filter(
			func(ev): return ev.outcome == _Executor.Outcome.TERMINATE)
		var moves_into_barrier: Array = events.filter(
			func(ev): return ev.outcome == _Executor.Outcome.MOVE and ev.entered_cell == Vector2i(2, 0))
		_check(G, terminates.size() == 1, "平行 %s 期望恰 1 个 TERMINATE（实际 %d）。" % [token, terminates.size()])
		if terminates.size() == 1:
			var ev: Variant = terminates[0]
			_check(G, ev.termination_reason == _Executor.TerminationReason.MECHANISM_BLOCK,
				"平行 %s 终止原因期望 MECHANISM_BLOCK。" % token)
			_check(G, ev.entered_cell == Vector2i(2, 0), "平行 %s 终止尝试格应为屏障格。" % token)
		_check(G, moves_into_barrier.is_empty(), "平行 %s 不得 MOVE 进入屏障格。" % token)
		_check(G, s.get_active_count() == 0, "平行 %s 终止后活动光粒应清零。" % token)

	# b) 穿过 STANDARD 通过：MOVE (1,0)@4 STANDARD → MOVE (2,0)@8 SLOW（穿屏障 -1）→ MOVE (3,0)@16 SLOW。
	var q2: _Fake = _Fake.new()
	q2.add_mechanism(Vector2i(2, 0), _shared_barrier)
	var s2: Variant = _Scheduler.new(q2)
	s2.begin_generation(0)
	s2.emit_particle(Vector2i(0, 0), Vector2i(1, 0), 1)
	var events2: Array = _collect_events(s2, 0, 20)
	var moves: Array = events2.filter(func(ev): return ev.outcome == _Executor.Outcome.MOVE)
	_check(G, moves.size() == 3, "穿过 STANDARD 期望 3 次 MOVE（实际 %d）。" % moves.size())
	if moves.size() == 3:
		_check(G, moves[1].entered_cell == Vector2i(2, 0) and moves[1].speed_tier == _Motion.SpeedTier.SLOW,
			"进入屏障格事件应携带穿过后新档 SLOW。")
		_check(G, moves[1].next_move_tick == 16,
			"穿屏障后权威 next_move_tick 应按新档 SLOW 取 16（实际 %d）。" % moves[1].next_move_tick)
		_check(G, moves[2].entered_cell == Vector2i(3, 0), "屏障后下一 MOVE 应抵达 (3,0)。")
		_check(G, moves[2].speed_tier == _Motion.SpeedTier.SLOW, "屏障后档位应保持 SLOW。")
	_check(G, s2.get_active_count() == 1, "穿过 STANDARD 后光粒应仍活动。")

	# c) 减速器→屏障（穿过 SLOW 真实速度判定）：SLOW 到达屏障 → TERMINATE(MECHANISM_BLOCK)。
	var q3: _Fake = _Fake.new()
	var decel: Variant = _Decelerator.new()
	decel.set_direction(0)
	q3.add_mechanism(Vector2i(1, 0), decel)
	q3.add_mechanism(Vector2i(3, 0), _shared_barrier)
	var s3: Variant = _Scheduler.new(q3)
	s3.begin_generation(0)
	s3.emit_particle(Vector2i(0, 0), Vector2i(1, 0), 1)
	var events3: Array = _collect_events(s3, 0, 24)
	var term3: Array = events3.filter(func(ev): return ev.outcome == _Executor.Outcome.TERMINATE)
	_check(G, term3.size() == 1, "减速后穿过 SLOW 期望恰 1 个 TERMINATE。")
	if term3.size() == 1:
		_check(G, term3[0].termination_reason == _Executor.TerminationReason.MECHANISM_BLOCK
			and term3[0].entered_cell == Vector2i(3, 0),
			"SLOW 穿过应以 MECHANISM_BLOCK 止于屏障格外 (3,0)。")
	decel.free()


## 06. 连续双屏障快速降档链（边界 #8）：加速器取 FAST → 第一屏障降 STANDARD 通过 → 第二屏障降 SLOW 通过。
func _test_06_double_barrier_fast_chain() -> void:
	const G: String = "06_连续双屏障链"
	var q: _Fake = _Fake.new()
	var accel: Variant = _Accelerator.new()
	accel.set_direction(0)
	q.add_mechanism(Vector2i(1, 0), accel)
	q.add_mechanism(Vector2i(4, 0), _shared_barrier)
	q.add_mechanism(Vector2i(6, 0), _shared_barrier)
	var s: Variant = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0), 1)
	var events: Array = _collect_events(s, 0, 30)
	var moves: Array = events.filter(func(ev): return ev.outcome == _Executor.Outcome.MOVE)
	var at_barrier_one: Array = moves.filter(func(ev): return ev.entered_cell == Vector2i(4, 0))
	var at_barrier_two: Array = moves.filter(func(ev): return ev.entered_cell == Vector2i(6, 0))
	_check(G, at_barrier_one.size() == 1 and at_barrier_two.size() == 1,
		"双屏障格各应恰 1 次 MOVE 进入（实际 %d/%d）。" % [at_barrier_one.size(), at_barrier_two.size()])
	if at_barrier_one.size() == 1:
		_check(G, at_barrier_one[0].speed_tier == _Motion.SpeedTier.STANDARD,
			"第一屏障穿过后应降为 STANDARD。")
	if at_barrier_two.size() == 1:
		_check(G, at_barrier_two[0].speed_tier == _Motion.SpeedTier.SLOW,
			"第二屏障穿过后应降为 SLOW。")
	_check(G, moves.size() == 7, "t<30 期望 7 次 MOVE（实际 %d）。" % moves.size())
	if moves.size() == 7:
		_check(G, moves[6].entered_cell == Vector2i(7, 0), "链尾应继续传播至 (7,0)。")
	var terminates: Array = events.filter(func(ev): return ev.outcome == _Executor.Outcome.TERMINATE)
	_check(G, terminates.is_empty(), "全程 FAST→STANDARD→SLOW 均应通过，不应终止。")
	accel.free()


## 07. 运行期零写入（R 不变量）：全部交互后 orientation 恒为 authored VERTICAL，形态声明与平行判定稳定。
func _test_07_runtime_zero_write_invariant() -> void:
	const G: String = "07_运行期零写入"
	_check(G, _shared_barrier.orientation == _Barrier.BarrierOrientation.VERTICAL,
		"运行期交互后 orientation 应保持 authored 值 VERTICAL。")
	_check(G, _shared_barrier.is_edge_collision(Vector2i(0, -1)),
		"交互后平行判定应保持稳定（VERTICAL 朝向 ↑ 入射平行撞棱角）。")
	_check(G, not _shared_barrier.is_edge_collision(Vector2i(1, 0)),
		"交互后穿过判定应保持稳定（→ 入射穿过方向）。")
	_check(G, _shared_barrier.get_light_interaction_forms() == [&"RAY", &"PARTICLE"],
		"交互后形态声明应保持稳定。")
