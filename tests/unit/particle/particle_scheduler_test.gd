extends SceneTree

## ParticleScheduler 定向测试（D7-4 B2 / B2.1）。
## 覆盖：runtime_id 单调；STANDARD 正交 due=4 / 斜向 due=6；due 前不移动；due 正好移动一次；apply_move 后 next_move_tick 正确；
##   accelerator→FAST / decelerator→SLOW 下一步按新档 Tick；FAST+1 / SLOW-1 饱和；越界/墙 terminate 后 active 减少；
##   同 Tick 多 Particle 按 runtime_id 稳定排序；generation mismatch 不推进；切换 generation 后旧 Particle 不再执行；
##   批处理增删不漏不重；drain 状态正确；generation 外部唯一所有权（scheduler 不自产 / 重复倒退原子拒绝 / runtime_id 跨 generation 不回拨）。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不依赖真实等待 0.1 秒，所有 Tick 推进为同步整数 advance_one_tick。

const _Scheduler: GDScript = preload(
	"res://gameplay/particle/particle_scheduler.gd"
)
const _Executor: GDScript = preload(
	"res://gameplay/particle/particle_step_executor.gd"
)
const _Motion: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)
const _Fake: GDScript = preload(
	"res://tests/unit/particle/fixtures/fake_particle_world_query.gd"
)

const _GROUP_COUNT: int = 20

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_12_runtime_id_monotonic()
	_test_13_standard_orthogonal_due_4()
	_test_14_standard_diagonal_due_6()
	_test_15_no_move_before_due()
	_test_16_move_exactly_once_at_due_tick()
	_test_17_next_move_tick_after_apply_move()
	_test_18_accelerator_to_fast_ticks()
	_test_19_decelerator_to_slow_ticks()
	_test_20_fast_plus_one_saturated()
	_test_21_slow_minus_one_saturated()
	_test_22_terrain_wall_terminate_reduces_active()
	_test_23_same_tick_stable_order()
	_test_24_generation_mismatch_no_advance()
	_test_25_old_generation_particles_not_executed()
	_test_26_batch_no_miss_no_duplicate()
	_test_27_drain_state()
	_test_28_generation_external_ownership()
	_test_29_snapshot_contract()
	_test_30_multi_emit_same_generation_coexist()
	_test_31_mirror_reflection_applied_to_state()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 推进到指定 Tick（每调用一次 advance_one_tick 当前 Tick +1），返回沿途累计事件。
func _advance_to_tick(s: _Scheduler, generation: int, target_tick: int) -> Array:
	var all: Array = []
	while s.get_current_tick() < target_tick:
		all.append_array(s.advance_one_tick(generation))
	return all


## 统计事件中某 outcome 的数量。
func _count_outcome(events: Array, outcome: int) -> int:
	var n: int = 0
	for ev: Variant in events:
		if ev.outcome == outcome:
			n += 1
	return n


# ===== 测试 =====

## 12. emitted runtime_id 单调；非法发射不消费 id。
func _test_12_runtime_id_monotonic() -> void:
	const G: String = "12_runtime_id单调"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	_check(G, s.emit_particle(Vector2i(0, 0), Vector2i(1, 0)) == 0, "首颗 runtime_id 期望 0。")
	_check(G, s.emit_particle(Vector2i(0, 0), Vector2i(0, 1)) == 1, "次颗 runtime_id 期望 1。")
	_check(G, s.emit_particle(Vector2i(0, 0), Vector2i(1, 1)) == 2, "第三颗 runtime_id 期望 2。")
	_check(G, s.get_next_runtime_id() == 3, "next_runtime_id 期望 3。")
	_check(G, s.get_active_count() == 3, "active count 期望 3。")
	_check(G, s.emit_particle(Vector2i(0, 0), Vector2i.ZERO) == -1, "非法方向 emit 期望返回 -1。")
	_check(G, s.get_next_runtime_id() == 3, "非法 emit 后 next_runtime_id 仍期望 3（不消费 id）。")


## 13. STANDARD 正交首次 due=4。
func _test_13_standard_orthogonal_due_4() -> void:
	const G: String = "13_正交due=4"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["next_move_tick"] == 4, "STANDARD 正交 next_move_tick 期望 4，实际 %d。" % st["next_move_tick"])
	_check(G, st["speed_tier"] == _Motion.SpeedTier.STANDARD, "初速期望 STANDARD。")


## 14. STANDARD 斜向首次 due=6。
func _test_14_standard_diagonal_due_6() -> void:
	const G: String = "14_斜向due=6"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 1))
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["next_move_tick"] == 6, "STANDARD 斜向 next_move_tick 期望 6，实际 %d。" % st["next_move_tick"])


## 15. due 前不移动：推到 due-1 仍无事件、state 未动。
func _test_15_no_move_before_due() -> void:
	const G: String = "15_due前不移动"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var events = _advance_to_tick(s, s.get_current_generation(), 3)
	_check(G, events.is_empty(), "due 前（tick 1~3）应无事件。")
	_check(G, s.get_current_tick() == 3, "当前 Tick 期望 3。")
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["cell"] == Vector2i(0, 0), "due 前 cell 应仍为 (0,0)。")
	_check(G, s.get_active_count() == 1, "due 前 active count 仍期望 1。")


## 16. due Tick 正好移动一次。
func _test_16_move_exactly_once_at_due_tick() -> void:
	const G: String = "16_due正好移动一次"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var events = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, events.size() == 1, "due Tick 期望恰好 1 个事件，实际 %d。" % events.size())
	_check(G, events[0].outcome == _Executor.Outcome.MOVE, "事件 outcome 期望 MOVE。")
	_check(G, events[0].entered_cell == Vector2i(1, 0), "事件 entered_cell 期望 (1,0)。")
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["cell"] == Vector2i(1, 0), "state cell 期望推进到 (1,0)。")
	_check(G, s.get_active_count() == 1, "MOVE 后 active count 仍期望 1。")


## 17. apply_move 后 next_move_tick 正确：正交 STANDARD 4+4=8；斜向 6+6=12。
##    D7-4 B4b-1 MF-1：同时校验 BatchEvent.next_move_tick == snapshot.next_move_tick（authoritative 一致）。
func _test_17_next_move_tick_after_apply_move() -> void:
	const G: String = "17_apply_move后nexttick"
	var q1: _Fake = _Fake.new()
	var s1: _Scheduler = _Scheduler.new(q1)
	s1.begin_generation(0)
	s1.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var events_ortho = _advance_to_tick(s1, s1.get_current_generation(), 4)
	var st_ortho = s1.get_particle_state_snapshot(0)
	_check(G, st_ortho["next_move_tick"] == 8, "正交移动后 next_move_tick 期望 4+4=8，实际 %d。" % st_ortho["next_move_tick"])
	# MF-1：MOVE BatchEvent.next_move_tick == commit 后 state next_move_tick（authoritative，Visual 不重算）。
	_check(G, events_ortho.size() == 1 and events_ortho[0].next_move_tick == 8, "正交 BatchEvent.next_move_tick 期望 8，实际 %d。" % [events_ortho[0].next_move_tick if not events_ortho.is_empty() else -1])
	_check(G, events_ortho[0].next_move_tick == st_ortho["next_move_tick"], "BatchEvent.next_move_tick 须与 state next_move_tick 一致。")

	var q2: _Fake = _Fake.new()
	var s2: _Scheduler = _Scheduler.new(q2)
	s2.begin_generation(0)
	s2.emit_particle(Vector2i(0, 0), Vector2i(1, 1))
	var events_diag = _advance_to_tick(s2, s2.get_current_generation(), 6)
	var st_diag = s2.get_particle_state_snapshot(0)
	_check(G, st_diag["next_move_tick"] == 12, "斜向移动后 next_move_tick 期望 6+6=12，实际 %d。" % st_diag["next_move_tick"])
	_check(G, events_diag.size() == 1 and events_diag[0].next_move_tick == 12, "斜向 BatchEvent.next_move_tick 期望 12，实际 %d。" % [events_diag[0].next_move_tick if not events_diag.is_empty() else -1])
	_check(G, events_diag[0].next_move_tick == st_diag["next_move_tick"], "斜向 BatchEvent.next_move_tick 须与 state next_move_tick 一致。")


## 18. accelerator 下一步由 STANDARD→FAST 后按 FAST Tick：next_move_tick = 4 + FAST正交2 = 6（非旧档 8）。
func _test_18_accelerator_to_fast_ticks() -> void:
	const G: String = "18_加速STANDARD→FAST"
	var q: _Fake = _Fake.new()
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	q.add_mechanism(Vector2i(1, 0), m)
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var events = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, events.size() == 1 and events[0].outcome == _Executor.Outcome.MOVE, "期望 1 个 MOVE 事件。")
	_check(G, events[0].speed_tier == _Motion.SpeedTier.FAST, "事件 speed_tier 期望 FAST。")
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["speed_tier"] == _Motion.SpeedTier.FAST, "state speed_tier 期望 FAST。")
	_check(G, st["cell"] == Vector2i(1, 0), "应已进入机关格 (1,0)。")
	# 关键：下一步按 FAST Tick（2），不按旧 STANDARD Tick（4）。
	_check(G, st["next_move_tick"] == 6, "加速后 next_move_tick 期望 4+FAST(2)=6，实际 %d（若误用旧档则为 8）。" % st["next_move_tick"])
	# D7-4 B4b-1 MF-1：BatchEvent.next_move_tick 使用新 outgoing speed tier（FAST→6），不使用旧 STANDARD（→8）。
	_check(G, events[0].next_move_tick == 6, "加速 BatchEvent.next_move_tick 期望 6（新 outgoing FAST 档），实际 %d。" % events[0].next_move_tick)


## 19. decelerator 下一步 STANDARD→SLOW：next_move_tick = 4 + SLOW正交8 = 12。
func _test_19_decelerator_to_slow_ticks() -> void:
	const G: String = "19_减速STANDARD→SLOW"
	var q: _Fake = _Fake.new()
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = -1
	q.add_mechanism(Vector2i(1, 0), m)
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_advance_to_tick(s, s.get_current_generation(), 4)
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["speed_tier"] == _Motion.SpeedTier.SLOW, "state speed_tier 期望 SLOW。")
	_check(G, st["next_move_tick"] == 12, "减速后 next_move_tick 期望 4+SLOW(8)=12，实际 %d。" % st["next_move_tick"])


## 20. FAST +1 饱和 FAST：连续两个加速器，第二步仍 FAST。
func _test_20_fast_plus_one_saturated() -> void:
	const G: String = "20_FAST+1饱和"
	var q: _Fake = _Fake.new()
	var m1 = _Fake.FakeSpeedMechanism.new(); m1.delta = 1
	var m2 = _Fake.FakeSpeedMechanism.new(); m2.delta = 1
	q.add_mechanism(Vector2i(1, 0), m1)
	q.add_mechanism(Vector2i(2, 0), m2)
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, s.get_particle_state_snapshot(0)["speed_tier"] == _Motion.SpeedTier.FAST, "第一加速器后期望 FAST。")
	_advance_to_tick(s, s.get_current_generation(), 6)
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["speed_tier"] == _Motion.SpeedTier.FAST, "FAST+1 应饱和为 FAST。")
	_check(G, st["cell"] == Vector2i(2, 0), "应推进到 (2,0)。")
	_check(G, st["next_move_tick"] == 8, "饱和 FAST 后 next_move_tick 期望 6+2=8，实际 %d。" % st["next_move_tick"])


## 21. SLOW -1 饱和 SLOW：连续两个减速器，第二步仍 SLOW。
func _test_21_slow_minus_one_saturated() -> void:
	const G: String = "21_SLOW-1饱和"
	var q: _Fake = _Fake.new()
	var m1 = _Fake.FakeSpeedMechanism.new(); m1.delta = -1
	var m2 = _Fake.FakeSpeedMechanism.new(); m2.delta = -1
	q.add_mechanism(Vector2i(1, 0), m1)
	q.add_mechanism(Vector2i(2, 0), m2)
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, s.get_particle_state_snapshot(0)["speed_tier"] == _Motion.SpeedTier.SLOW, "第一减速器后期望 SLOW。")
	_advance_to_tick(s, s.get_current_generation(), 12)
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["speed_tier"] == _Motion.SpeedTier.SLOW, "SLOW-1 应饱和为 SLOW。")
	_check(G, st["cell"] == Vector2i(2, 0), "应推进到 (2,0)。")


## 22. Terrain/Wall terminate 后 active count 减少。
func _test_22_terrain_wall_terminate_reduces_active() -> void:
	const G: String = "22_终止后active减少"
	# 越界。
	var q1: _Fake = _Fake.new()
	q1.set_bounds(Rect2i(0, 0, 3, 3))
	var s1: _Scheduler = _Scheduler.new(q1)
	s1.begin_generation(0)
	s1.emit_particle(Vector2i(2, 0), Vector2i(1, 0))  # next (3,0) 越界
	var ev1 = _advance_to_tick(s1, s1.get_current_generation(), 4)
	_check(G, ev1.size() == 1 and ev1[0].outcome == _Executor.Outcome.TERMINATE, "越界期望 1 个 TERMINATE 事件。")
	_check(G, ev1[0].termination_reason == _Executor.TerminationReason.OUT_OF_TERRAIN, "越界 reason 期望 OUT_OF_TERRAIN。")
	# D7-4 B4b-1 MF-1：TERMINATE BatchEvent.next_move_tick 保持默认 0（不伪造下一步 timing）。
	_check(G, ev1[0].next_move_tick == 0, "越界 TERMINATE next_move_tick 期望 0（不伪造），实际 %d。" % ev1[0].next_move_tick)
	_check(G, s1.get_active_count() == 0, "越界终止后 active count 期望 0。")
	_check(G, s1.is_drained() == true, "越界终止后应 drained。")
	# 墙体。
	var q2: _Fake = _Fake.new()
	q2.add_wall(Vector2i(1, 0))
	var s2: _Scheduler = _Scheduler.new(q2)
	s2.begin_generation(0)
	s2.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var ev2 = _advance_to_tick(s2, s2.get_current_generation(), 4)
	_check(G, ev2.size() == 1 and ev2[0].outcome == _Executor.Outcome.TERMINATE, "墙体期望 1 个 TERMINATE 事件。")
	_check(G, ev2[0].termination_reason == _Executor.TerminationReason.WALL, "墙体 reason 期望 WALL。")
	_check(G, ev2[0].next_move_tick == 0, "墙体 TERMINATE next_move_tick 期望 0（不伪造），实际 %d。" % ev2[0].next_move_tick)
	_check(G, s2.get_active_count() == 0, "墙体终止后 active count 期望 0。")


## 23. 同 Tick 多 Particle 按 runtime_id 稳定排序。
func _test_23_same_tick_stable_order() -> void:
	const G: String = "23_同Tick稳定排序"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))  # rid 0
	s.emit_particle(Vector2i(5, 0), Vector2i(1, 0))  # rid 1
	var events = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, events.size() == 2, "同 Tick 两颗 due 期望 2 个事件，实际 %d。" % events.size())
	_check(G, events[0].runtime_id < events[1].runtime_id,
		"事件应按 runtime_id 升序：%d < %d。" % [events[0].runtime_id, events[1].runtime_id])
	_check(G, events[0].runtime_id == 0 and events[1].runtime_id == 1, "期望顺序 [0, 1]。")


## 24. generation mismatch 不推进 current_tick：旧/错 generation 调 advance_one_tick 永久 no-op。
func _test_24_generation_mismatch_no_advance() -> void:
	const G: String = "24_generation不匹配不推进"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)  # 外部绑定 gen 0, tick 0
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var events = s.advance_one_tick(99)  # 错 generation
	_check(G, events.is_empty(), "generation 不匹配应返回空事件。")
	_check(G, s.get_current_tick() == 0, "generation 不匹配不应推进 current_tick，期望 0，实际 %d。" % s.get_current_tick())
	var st = s.get_particle_state_snapshot(0)
	_check(G, st["cell"] == Vector2i(0, 0), "不匹配时光粒不应移动。")
	# 正确 generation 仍可推进。
	s.advance_one_tick(s.get_current_generation())
	_check(G, s.get_current_tick() == 1, "正确 generation 应推进到 tick 1。")


## 25. 切换 generation 后旧 Particle 不再执行：外部传入新 generation 绑定，清空旧活动索引。
func _test_25_old_generation_particles_not_executed() -> void:
	const G: String = "25_旧gen不再执行"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(10)  # 外部绑定 gen 10
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, s.get_active_count() == 1, "gen 10 发射后 active 期望 1。")
	var gen_before: int = s.get_current_generation()  # 10
	s.begin_generation(11)  # 外部绑定 gen 11，清空
	_check(G, s.get_current_generation() == 11, "新 generation 应为外部传入的 11（非 scheduler 自增）。")
	_check(G, s.get_current_generation() == gen_before + 1, "外部 11 == 旧 10 + 1（单调性由调用方保证，scheduler 仅记录）。")
	_check(G, s.get_active_count() == 0, "切换 generation 后旧 Particle 应被清出活动索引。")
	_check(G, s.get_current_tick() == 0, "新 generation current_tick 应重置 0。")
	# 旧 generation 调用永久无效。
	var ev_old = s.advance_one_tick(gen_before)
	_check(G, ev_old.is_empty() and s.get_current_tick() == 0, "旧 generation 调用应 no-op。")
	# 新 generation 推进也不处理旧光粒（已不在索引）。
	var ev_new = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, ev_new.is_empty(), "新 generation 不应处理旧光粒。")
	_check(G, s.get_active_count() == 0, "全程 active 期望 0。")


## 26. 批处理中增删不漏处理/不重复处理：同 Tick 一终止一移动，各恰好一次。
func _test_26_batch_no_miss_no_duplicate() -> void:
	const G: String = "26_批处理不漏不重"
	var q: _Fake = _Fake.new()
	q.add_wall(Vector2i(1, 0))  # P0 将撞墙终止
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))  # rid 0 → 撞墙
	s.emit_particle(Vector2i(5, 0), Vector2i(1, 0))  # rid 1 → 空格移动
	var events = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, events.size() == 2, "同 Tick 两颗 due 期望 2 个事件，实际 %d。" % events.size())
	_check(G, _count_outcome(events, _Executor.Outcome.TERMINATE) == 1, "期望恰好 1 个 TERMINATE。")
	_check(G, _count_outcome(events, _Executor.Outcome.MOVE) == 1, "期望恰好 1 个 MOVE。")
	# P0 终止不漏处理 P1，P1 恰好移动一次（cell 推进到 (6,0)）。
	var st1 = s.get_particle_state_snapshot(1)
	_check(G, st1 != null and st1["cell"] == Vector2i(6, 0), "P1 应推进到 (6,0)。")
	_check(G, s.get_particle_state_snapshot(0) == null, "P0 应已从活动索引移除。")
	_check(G, s.get_active_count() == 1, "批后 active 期望 1（仅 P1）。")
	# 新登记 Particle 不进入已返回的当前批事件（按 runtime_id 逐事件核验）。
	var rid2: int = s.emit_particle(Vector2i(9, 0), Vector2i(1, 0))
	_check(G, rid2 == 2, "新发射 runtime_id 期望 2。")
	var new_in_batch: bool = false
	for ev: Variant in events:
		if ev.runtime_id == rid2:
			new_in_batch = true
	_check(G, not new_in_batch, "批后新登记 Particle 不应进入已返回的当前批事件。")


## 27. drain 状态正确：终止前非 drained，全部终止后 drained。
func _test_27_drain_state() -> void:
	const G: String = "27_drain状态"
	var q: _Fake = _Fake.new()
	q.add_wall(Vector2i(1, 0))
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, s.is_drained() == false, "存在活动光粒时 is_drained 期望 false。")
	_advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, s.is_drained() == true, "全部终止后 is_drained 期望 true。")
	_check(G, s.get_active_count() == 0, "drain 时 active count 期望 0。")


## 28. generation 外部唯一所有权收口（D7-4 B2.1）：scheduler 不自产 / 不自增 generation，仅记录外部镜像标签；
##   初始未绑定（-1）；emitted state.generation == 当前外部 generation；切换 generation 时 tick 重置 / active 清空 / runtime_id 不回拨；
##   重复 / 倒退被原子拒绝（generation / tick / active / runtime_id 全不变）。
func _test_28_generation_external_ownership() -> void:
	const G: String = "28_generation外部唯一所有权"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	# 1. 初始 generation 未绑定（镜像标签初始 -1）。
	_check(G, s.get_current_generation() == -1, "初始 generation 未绑定期望 -1，实际 %d。" % s.get_current_generation())
	# 2/3/4. begin_generation(10) 成功；current_generation == 10；scheduler 不自行变成 1。
	var ok10: bool = s.begin_generation(10)
	_check(G, ok10 == true, "begin_generation(10) 期望返回 true。")
	_check(G, s.get_current_generation() == 10, "绑定后 current_generation 期望 10（非 scheduler 自增的 1）。")
	_check(G, s.get_current_tick() == 0, "首次绑定后 current_tick 期望 0。")
	# 5. emitted Particle generation == 当前外部 generation（10）。
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var st10 = s.get_particle_state_snapshot(0)
	_check(G, st10 != null and st10["generation"] == 10, "emitted Particle generation 期望 10。")
	# 6. begin_generation(11)：成功、current_tick 重置 0、old active 清空、runtime_id 不回拨。
	# 先推进 tick 制造非 0 基线，再切换 generation 验证 tick 重置与 runtime_id 不回拨。
	_advance_to_tick(s, 10, 2)  # gen 10 推进到 tick 2（光粒 due=4，期间无事件）
	_check(G, s.get_current_tick() == 2, "切换前 current_tick 期望 2。")
	_check(G, s.get_next_runtime_id() == 1, "切换前 next_runtime_id 期望 1。")
	var ok11: bool = s.begin_generation(11)
	_check(G, ok11 == true, "begin_generation(11) 期望返回 true。")
	_check(G, s.get_current_generation() == 11, "切换后 current_generation 期望 11。")
	_check(G, s.get_current_tick() == 0, "切换后 current_tick 应重置 0。")
	_check(G, s.get_active_count() == 0, "切换后 old active 应清空。")
	_check(G, s.get_next_runtime_id() == 1, "切换后 next_runtime_id 不回拨，仍期望 1。")
	# 7. begin_generation(10) 倒退 / 重复：false，generation / tick / active / runtime_id 全不变。
	# 先在新 gen 11 发射一颗 + 推进 tick，建立“应被保留”的状态快照。
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))  # rid 1（next_runtime_id 递增到 2）
	_advance_to_tick(s, 11, 3)  # gen 11 推进到 tick 3（due=4，期间无事件）
	var rid_before: int = s.get_next_runtime_id()  # 2
	var gen_before: int = s.get_current_generation()  # 11
	var tick_before: int = s.get_current_tick()  # 3
	var active_before: int = s.get_active_count()  # 1
	var ok_rollback: bool = s.begin_generation(10)  # 10 <= 11 倒退
	_check(G, ok_rollback == false, "begin_generation(10) 倒退期望返回 false。")
	_check(G, s.get_current_generation() == gen_before, "拒绝后 generation 不应变，仍 11。")
	_check(G, s.get_current_tick() == tick_before, "拒绝后 current_tick 不变，仍 3。")
	_check(G, s.get_active_count() == active_before, "拒绝后 active states 不变，仍 1。")
	_check(G, s.get_next_runtime_id() == rid_before, "拒绝后 next_runtime_id 不变，仍 2。")
	# 重复当前 generation（11 <= 11）同样原子拒绝，不误清活动 Particle。
	var ok_same: bool = s.begin_generation(11)
	_check(G, ok_same == false, "begin_generation(11) 重复当前期望返回 false。")
	_check(G, s.get_active_count() == active_before, "重复拒绝后 active 仍 1，未误清。")
	_check(G, s.get_next_runtime_id() == rid_before, "重复拒绝后 runtime_id 仍 2。")


## 29. snapshot 合同（D7-4 B3b-2.1 MF-3）：raw accessor 已删除；新 detached snapshot API 存在；八字段值正确；detached（外部修改零影响真实 state）；无 apply_move/terminate；切换 generation 后旧 rid → null。
func _test_29_snapshot_contract() -> void:
	const G: String = "29_snapshot合同"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	# 1. raw accessor 已删除；新 detached snapshot API 存在；未登记 rid 返回 null。
	_check(G, not s.has_method("get_particle_state"), "scheduler 不应再暴露 raw get_particle_state。")
	_check(G, s.has_method("get_particle_state_snapshot"), "scheduler 应暴露 get_particle_state_snapshot。")
	_check(G, s.get_particle_state_snapshot(0) == null, "未登记 rid 0 snapshot 应为 null。")
	# 2. emit 后 snapshot 八字段值正确。
	s.begin_generation(7)
	s.emit_particle(Vector2i(2, 3), Vector2i(1, 0))  # STANDARD 正交 next_move_tick=4
	var snap = s.get_particle_state_snapshot(0)
	_check(G, snap != null, "emit 后 rid 0 snapshot 应非 null。")
	if snap != null:
		_check(G, snap is Dictionary, "snapshot 应为 Dictionary。")
		var expected_keys: Array = ["runtime_id", "generation", "cell", "direction", "speed_tier", "step_started_tick", "next_move_tick", "active"]
		if snap is Dictionary:
			_check(G, snap.keys().size() == expected_keys.size(), "snapshot 键数期望 %d，实际 %d。" % [expected_keys.size(), snap.keys().size()])
			for k: String in expected_keys:
				_check(G, snap.has(k), "snapshot 应含键 %s。" % k)
			_check(G, snap["runtime_id"] == 0, "runtime_id 期望 0。")
			_check(G, snap["generation"] == 7, "generation 期望 7。")
			_check(G, snap["cell"] == Vector2i(2, 3), "cell 期望 (2,3)。")
			_check(G, snap["direction"] == Vector2i(1, 0), "direction 期望 (1,0)。")
			_check(G, snap["speed_tier"] == _Motion.SpeedTier.STANDARD, "speed_tier 期望 STANDARD。")
			_check(G, snap["step_started_tick"] == 0, "step_started_tick 期望 0。")
			_check(G, snap["next_move_tick"] == 4, "next_move_tick 期望 4。")
			_check(G, snap["active"] == true, "active 期望 true。")
			# 3. detached：篡改 snapshot 全部字段后，重新取只读快照仍反映真实原值（外部修改零影响真实 state）。
			snap["runtime_id"] = 999
			snap["generation"] = 999
			snap["cell"] = Vector2i(-5, -5)
			snap["direction"] = Vector2i(-1, 0)
			snap["speed_tier"] = _Motion.SpeedTier.FAST
			snap["step_started_tick"] = 999
			snap["next_move_tick"] = 999
			snap["active"] = false
			var fresh = s.get_particle_state_snapshot(0)
			_check(G, fresh != null and fresh["runtime_id"] == 0, "篡改后 runtime_id 仍期望 0。")
			_check(G, fresh != null and fresh["generation"] == 7, "篡改后 generation 仍期望 7。")
			_check(G, fresh != null and fresh["cell"] == Vector2i(2, 3), "篡改后 cell 仍期望 (2,3)。")
			_check(G, fresh != null and fresh["direction"] == Vector2i(1, 0), "篡改后 direction 仍期望 (1,0)。")
			_check(G, fresh != null and fresh["speed_tier"] == _Motion.SpeedTier.STANDARD, "篡改后 speed_tier 仍期望 STANDARD。")
			_check(G, fresh != null and fresh["step_started_tick"] == 0, "篡改后 step_started_tick 仍期望 0。")
			_check(G, fresh != null and fresh["next_move_tick"] == 4, "篡改后 next_move_tick 仍期望 4。")
			_check(G, fresh != null and fresh["active"] == true, "篡改后 active 仍期望 true。")
			# 4. snapshot 为 Dictionary（无方法表），不得含 apply_move/terminate 入口——内部 state 引用未泄漏。
			_check(G, not snap.has("apply_move"), "snapshot 不得含 apply_move 入口。")
			_check(G, not snap.has("terminate"), "snapshot 不得含 terminate 入口。")
	# 5. 切换 generation（R 等价：begin_generation 清空 _active_states）后旧 rid → null。
	s.begin_generation(8)
	_check(G, s.get_particle_state_snapshot(0) == null, "切换 generation 后旧 rid 0 snapshot 应为 null。")
	_check(G, s.get_active_count() == 0, "切换 generation 后 active 期望 0。")


## 30. M4-E1 同 generation 多 emit 共存（#9/#10）：同一 generation 内连续 emit_particle 两颗——第二颗不清空第一颗，两颗并存于 _active_states。
## [br]证明 scheduler 原生支持同 generation 多 runtime_id 并存（LRC M4-E1 起不再每发 begin_generation，依赖此能力）；只有 begin_generation（epoch-start / R）才清空。
func _test_30_multi_emit_same_generation_coexist() -> void:
	const G: String = "30_同generation多emit共存"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	_check(G, s.begin_generation(0), "begin_generation(0) 应成功。")
	var rid0: int = s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, rid0 == 0, "首颗 rid 期望 0。")
	_check(G, s.get_active_count() == 1, "首颗 emit 后 active 期望 1，实际 %d。" % s.get_active_count())
	_check(G, s.get_particle_state_snapshot(0) != null, "首颗 rid 0 snapshot 应存在。")
	# 第二颗 emit（同一 generation，无 begin_generation）：不得清空第一颗。
	var rid1: int = s.emit_particle(Vector2i(5, 0), Vector2i(1, 0))
	_check(G, rid1 == 1, "第二颗 rid 期望 1（单调），实际 %d。" % rid1)
	_check(G, s.get_active_count() == 2, "第二颗 emit 后 active 期望 2（不清首），实际 %d。" % s.get_active_count())
	_check(G, s.get_particle_state_snapshot(0) != null, "第二颗 emit 后 rid 0 仍应存在（#10 不清首）。")
	_check(G, s.get_particle_state_snapshot(1) != null, "rid 1 snapshot 应存在。")
	# 两颗共享同一 generation 镜像。
	_check(G, s.get_particle_state_snapshot(0)["generation"] == 0 and s.get_particle_state_snapshot(1)["generation"] == 0, "两颗 generation 均期望 0（同 epoch 共享 generation）。")
	# begin_generation（epoch-start / R 等价）才清空——证明清空唯一入口。
	_check(G, s.begin_generation(1), "begin_generation(1) 应成功。")
	_check(G, s.get_active_count() == 0, "begin_generation 后两颗全清空，active 期望 0。")
	_check(G, s.get_particle_state_snapshot(0) == null and s.get_particle_state_snapshot(1) == null, "begin_generation 后两颗 snapshot 均应为 null。")


## 31. 镜面反射端到端（D7-R5 GUI 验收修复）：SLASH 镜在 (1,0)，光粒 (0,0) RIGHT 发射——
##     tick4 MOVE 进镜面格且 BatchEvent.direction=UP(0,-1)（反射方向，非入射）；state.direction 同步改向；
##     反射后 next_move_tick 按出射方向 Tick 计算（4+4=8）；tick8 光粒进入 (1,-1)（沿反射方向传播，非穿镜直行）。
func _test_31_mirror_reflection_applied_to_state() -> void:
	const G: String = "31_镜面反射端到端"
	var q: _Fake = _Fake.new()
	var m = q.FakeReflectMechanism.new()
	m.slash = true
	q.add_mechanism(Vector2i(1, 0), m)
	var s: _Scheduler = _Scheduler.new(q)
	s.begin_generation(0)
	var rid: int = s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_check(G, rid >= 0, "emit 应成功。")
	var events_mirror = _advance_to_tick(s, s.get_current_generation(), 4)
	_check(G, events_mirror.size() == 1, "tick4 应恰有一个 MOVE 事件，实际 %d。" % events_mirror.size())
	if not events_mirror.is_empty():
		_check(G, events_mirror[0].entered_cell == Vector2i(1, 0), "tick4 entered_cell 期望镜面格 (1,0)。")
		_check(G, events_mirror[0].direction == Vector2i(0, -1),
			"镜面格 MOVE direction 期望反射方向 UP(0,-1)，实际 (%d,%d)。" % [events_mirror[0].direction.x, events_mirror[0].direction.y])
		_check(G, events_mirror[0].next_move_tick == 8, "反射后 next_move_tick 期望 4+4=8（出射正交 STANDARD），实际 %d。" % events_mirror[0].next_move_tick)
	var st = s.get_particle_state_snapshot(rid)
	_check(G, st != null and st["direction"] == Vector2i(0, -1), "state.direction 应已改向 UP(0,-1)。")
	_check(G, st != null and st["cell"] == Vector2i(1, 0), "state.cell 期望镜面格 (1,0)。")
	# 沿反射方向继续传播：tick8 进入 (1,-1)（镜面格上方），而非穿镜直行 (2,0)。
	var events_after = _advance_to_tick(s, s.get_current_generation(), 8)
	_check(G, events_after.size() == 1, "tick8 应恰有一个 MOVE 事件，实际 %d。" % events_after.size())
	if not events_after.is_empty():
		_check(G, events_after[0].entered_cell == Vector2i(1, -1),
			"反射后下一步 entered_cell 期望 (1,-1)（沿 UP 传播），实际 (%d,%d)。" % [events_after[0].entered_cell.x, events_after[0].entered_cell.y])
	st = s.get_particle_state_snapshot(rid)
	_check(G, st != null and st["cell"] == Vector2i(1, -1), "最终 state.cell 期望 (1,-1)。")


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleScheduler 测试摘要（D7-4 B2）====")
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
