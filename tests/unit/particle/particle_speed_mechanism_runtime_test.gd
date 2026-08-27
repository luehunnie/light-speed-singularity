extends SceneTree

## S3-01 真实速度机关运行级定向测试。
## 覆盖：真实 ParticleAccelerator / ParticleDecelerator 节点（不进场景树，仅正式契约面
##   get_light_interaction_forms + interact_particle）× 真实 ParticleScheduler Tick 推进——
##   STANDARD→FAST、FAST 饱和、STANDARD→SLOW、SLOW 饱和、混合链 FAST→STANDARD、
##   方向不匹配透明、斜向 Tick 表、可观察 tick/间隔行为（事件 next_move_tick 权威时序 == 下次实际移动 Tick）
##   与运行中 get_particle_state_snapshot 只读快照。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题；
##   机关为 Node2D fixture，用后 free（不进树，_ready 不触发，@onready 不解引用）。
## 全部失败项收集后统一退出（任一失败 quit(1)）；所有 Tick 推进为同步整数 advance_one_tick，不真实等待。

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
const _Accelerator: GDScript = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.gd"
)
const _Decelerator: GDScript = preload(
	"res://gameplay/mechanisms/speed/particle_decelerator.gd"
)

const _GROUP_COUNT: int = 6

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_accelerator_chain_standard_to_fast_saturated()
	_test_02_decelerator_chain_standard_to_slow_saturated()
	_test_03_direction_mismatch_transparent()
	_test_04_mixed_chain_fast_back_to_standard()
	_test_05_mid_run_snapshot_observable()
	_test_06_diagonal_tick_table()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 逐 Tick 推进到 until_tick（不含），记录每个 MOVE 事件的发生 Tick（可观察 tick 行为）。
func _collect_moves(s, generation: int, until_tick: int) -> Array:
	var records: Array = []
	while s.get_current_tick() < until_tick:
		var tick: int = s.get_current_tick() + 1
		for ev: Variant in s.advance_one_tick(generation):
			if ev.outcome == _Executor.Outcome.MOVE:
				records.append({"tick": tick, "event": ev})
	return records


## 断言一条 MOVE 记录：发生 Tick、进入格、档位、权威 next_move_tick 四项一致。
func _check_move(group: String, rec: Dictionary, expected_tick: int, expected_entered: Vector2i,
		expected_tier: int, expected_next: int) -> void:
	var ev: Variant = rec["event"]
	_check(group, rec["tick"] == expected_tick,
		"MOVE 发生 Tick 期望 %d，实际 %d。" % [expected_tick, rec["tick"]])
	_check(group, ev.entered_cell == expected_entered,
		"entered_cell 期望 (%d,%d)，实际 (%d,%d)。" % [expected_entered.x, expected_entered.y, ev.entered_cell.x, ev.entered_cell.y])
	_check(group, ev.speed_tier == expected_tier,
		"speed_tier 期望 %d，实际 %d。" % [expected_tier, ev.speed_tier])
	_check(group, ev.next_move_tick == expected_next,
		"next_move_tick 期望 %d，实际 %d。" % [expected_next, ev.next_move_tick])


## 断言可观察间隔链：第 i 次 MOVE 的发生 Tick == 第 i-1 次事件的权威 next_move_tick。
func _check_timing_chain(group: String, records: Array, count: int) -> void:
	for i: int in range(1, count):
		var prev_ev: Variant = records[i - 1]["event"]
		_check(group, records[i]["tick"] == prev_ev.next_move_tick,
			"第 %d 次 MOVE Tick 期望衔接上一次 next_move_tick %d，实际 %d。" % [i + 1, prev_ev.next_move_tick, records[i]["tick"]])


func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 真实速度机关运行级测试摘要（S3-01）====")
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

## 01. 加速链：两台真实加速器（方向 RIGHT）。STANDARD→FAST（间隔 4→2）+ 第二台 FAST 饱和（间隔保持 2）。
func _test_01_accelerator_chain_standard_to_fast_saturated() -> void:
	const G: String = "01_加速链STANDARD→FAST饱和"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var m1 = _Accelerator.new()
	var m2 = _Accelerator.new()
	q.add_mechanism(Vector2i(1, 0), m1)
	q.add_mechanism(Vector2i(2, 0), m2)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var records: Array = _collect_moves(s, 0, 9)
	_check(G, records.size() == 3, "tick≤8 期望恰 3 次 MOVE，实际 %d。" % records.size())
	_check_move(G, records[0], 4, Vector2i(1, 0), _Motion.SpeedTier.FAST, 6)
	_check_move(G, records[1], 6, Vector2i(2, 0), _Motion.SpeedTier.FAST, 8)
	_check_move(G, records[2], 8, Vector2i(3, 0), _Motion.SpeedTier.FAST, 10)
	_check_timing_chain(G, records, 3)
	m1.free()
	m2.free()


## 02. 减速链：两台真实减速器（方向 RIGHT）。STANDARD→SLOW（间隔 4→8）+ 第二台 SLOW 饱和（间隔保持 8）。
func _test_02_decelerator_chain_standard_to_slow_saturated() -> void:
	const G: String = "02_减速链STANDARD→SLOW饱和"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var m1 = _Decelerator.new()
	var m2 = _Decelerator.new()
	q.add_mechanism(Vector2i(1, 0), m1)
	q.add_mechanism(Vector2i(2, 0), m2)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var records: Array = _collect_moves(s, 0, 20)
	_check(G, records.size() == 3, "tick≤20 期望恰 3 次 MOVE，实际 %d。" % records.size())
	_check_move(G, records[0], 4, Vector2i(1, 0), _Motion.SpeedTier.SLOW, 12)
	_check_move(G, records[1], 12, Vector2i(2, 0), _Motion.SpeedTier.SLOW, 20)
	_check_move(G, records[2], 20, Vector2i(3, 0), _Motion.SpeedTier.SLOW, 28)
	_check_timing_chain(G, records, 3)
	m1.free()
	m2.free()


## 03. 方向不匹配透明：加速器方向 UP，光粒沿 RIGHT 穿过——档位与间隔均不变（真实 matches_direction 逻辑）。
func _test_03_direction_mismatch_transparent() -> void:
	const G: String = "03_方向不匹配透明"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var m = _Accelerator.new()
	m.set_direction(_Accelerator.AcceleratorDirection.UP)
	q.add_mechanism(Vector2i(1, 0), m)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var records: Array = _collect_moves(s, 0, 12)
	_check(G, records.size() == 3, "tick≤12 期望恰 3 次 MOVE，实际 %d。" % records.size())
	_check_move(G, records[0], 4, Vector2i(1, 0), _Motion.SpeedTier.STANDARD, 8)
	_check_move(G, records[1], 8, Vector2i(2, 0), _Motion.SpeedTier.STANDARD, 12)
	_check_move(G, records[2], 12, Vector2i(3, 0), _Motion.SpeedTier.STANDARD, 16)
	_check_timing_chain(G, records, 3)
	m.free()


## 04. 混合链：真实加速器后接真实减速器（均 RIGHT）——FAST→STANDARD，间隔 2→4 证明档位往返经真实机关。
func _test_04_mixed_chain_fast_back_to_standard() -> void:
	const G: String = "04_混合链FAST→STANDARD"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var accel = _Accelerator.new()
	var decel = _Decelerator.new()
	q.add_mechanism(Vector2i(1, 0), accel)
	q.add_mechanism(Vector2i(2, 0), decel)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	var records: Array = _collect_moves(s, 0, 10)
	_check(G, records.size() == 3, "tick≤10 期望恰 3 次 MOVE，实际 %d。" % records.size())
	_check_move(G, records[0], 4, Vector2i(1, 0), _Motion.SpeedTier.FAST, 6)
	_check_move(G, records[1], 6, Vector2i(2, 0), _Motion.SpeedTier.STANDARD, 10)
	_check_move(G, records[2], 10, Vector2i(3, 0), _Motion.SpeedTier.STANDARD, 14)
	_check_timing_chain(G, records, 3)
	accel.free()
	decel.free()


## 05. 运行中只读快照可观察：加速生效后 snapshot 的 speed_tier/cell/next_move_tick/active。
func _test_05_mid_run_snapshot_observable() -> void:
	const G: String = "05_运行中快照可观察"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var m = _Accelerator.new()
	q.add_mechanism(Vector2i(1, 0), m)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 0))
	_collect_moves(s, 0, 5)
	var st = s.get_particle_state_snapshot(0)
	_check(G, st != null, "tick5 快照不应为 null。")
	if st != null:
		_check(G, st["speed_tier"] == _Motion.SpeedTier.FAST, "快照 speed_tier 期望 FAST，实际 %d。" % st["speed_tier"])
		_check(G, st["cell"] == Vector2i(1, 0), "快照 cell 期望 (1,0)，实际 (%d,%d)。" % [st["cell"].x, st["cell"].y])
		_check(G, st["next_move_tick"] == 6, "快照 next_move_tick 期望 6，实际 %d。" % st["next_move_tick"])
		_check(G, st["active"] == true, "快照 active 期望 true。")
	m.free()


## 06. 斜向 Tick 表：加速器方向 DOWN_RIGHT，光粒斜向——间隔 6→3（FAST 斜向表经真实机关生效）。
func _test_06_diagonal_tick_table() -> void:
	const G: String = "06_斜向Tick表"
	var q: _Fake = _Fake.new()
	var s: _Scheduler = _Scheduler.new(q)
	var m = _Accelerator.new()
	m.set_direction(_Accelerator.AcceleratorDirection.DOWN_RIGHT)
	q.add_mechanism(Vector2i(1, 1), m)
	s.begin_generation(0)
	s.emit_particle(Vector2i(0, 0), Vector2i(1, 1))
	var records: Array = _collect_moves(s, 0, 12)
	_check(G, records.size() == 3, "tick≤12 期望恰 3 次 MOVE，实际 %d。" % records.size())
	_check_move(G, records[0], 6, Vector2i(1, 1), _Motion.SpeedTier.FAST, 9)
	_check_move(G, records[1], 9, Vector2i(2, 2), _Motion.SpeedTier.FAST, 12)
	_check_move(G, records[2], 12, Vector2i(3, 3), _Motion.SpeedTier.FAST, 15)
	_check_timing_chain(G, records, 3)
	m.free()
