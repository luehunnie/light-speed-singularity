extends SceneTree

## ParticleStepExecutor 定向测试（D7-4 B2）。
## 覆盖：Terrain 外 terminate / Wall terminate / 空格 MOVE / Crystal 仅 has_crystal 事件 / 速度机关返回 delta / executor 不修改 state。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _Executor: GDScript = preload(
	"res://gameplay/particle/particle_step_executor.gd"
)
const _Fake: GDScript = preload(
	"res://tests/unit/particle/fixtures/fake_particle_world_query.gd"
)
const _ParticleRuntimeState: GDScript = preload(
	"res://gameplay/particle/particle_runtime_state.gd"
)

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_06_out_of_terrain_terminate()
	_test_07_wall_terminate()
	_test_08_empty_cell_move()
	_test_09_crystal_only_event()
	_test_10_speed_mechanism_delta()
	_test_11_executor_no_state_mutation()
	_test_12_mirror_reflection_move()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 新建一个 executor 实例（无状态，每测新建）。
func _new_executor() -> _Executor:
	return _Executor.new()


## 6. Terrain 外 terminate：next_cell 越出 bounds → TERMINATE(OUT_OF_TERRAIN)。
func _test_06_out_of_terrain_terminate() -> void:
	const G: String = "06_越界terminate"
	var q: _Fake = _Fake.new()
	q.set_bounds(Rect2i(0, 0, 3, 3))  # 仅 (0,0)~(2,2) 在界内
	var ex = _new_executor()
	# 在右边界 (2,0) 向右 → next (3,0) 越界。
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(2, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.TERMINATE, "越界 outcome 期望 TERMINATE。")
	_check(G, r.termination_reason == _Executor.TerminationReason.OUT_OF_TERRAIN,
		"越界 reason 期望 OUT_OF_TERRAIN，实际 %d。" % r.termination_reason)
	_check(G, r.entered_cell == Vector2i(3, 0), "越界 entered_cell 期望尝试格 (3,0)。")
	_check(G, r.speed_delta == 0, "越界 speed_delta 期望 0。")
	_check(G, r.has_crystal == false, "越界 has_crystal 期望 false。")


## 7. Wall terminate：next_cell 为墙 → TERMINATE(WALL)。
func _test_07_wall_terminate() -> void:
	const G: String = "07_墙terminate"
	var q: _Fake = _Fake.new()
	q.add_wall(Vector2i(1, 0))
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.TERMINATE, "墙体 outcome 期望 TERMINATE。")
	_check(G, r.termination_reason == _Executor.TerminationReason.WALL,
		"墙体 reason 期望 WALL，实际 %d。" % r.termination_reason)
	_check(G, r.entered_cell == Vector2i(1, 0), "墙体 entered_cell 期望尝试格 (1,0)。")
	_check(G, r.speed_delta == 0, "墙体 speed_delta 期望 0。")
	_check(G, r.has_crystal == false, "墙体 has_crystal 期望 false。")


## 8. 空格 MOVE：next_cell 在界内、无墙、无水晶、无机关 → MOVE，entered_cell 正确，delta=0。
func _test_08_empty_cell_move() -> void:
	const G: String = "08_空格MOVE"
	var q: _Fake = _Fake.new()
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "空格 outcome 期望 MOVE。")
	_check(G, r.termination_reason == _Executor.TerminationReason.NONE, "空格 reason 期望 NONE。")
	_check(G, r.entered_cell == Vector2i(1, 0), "空格 entered_cell 期望 (1,0)。")
	_check(G, r.outgoing_direction == Vector2i(1, 0), "空格 outgoing_direction 期望入射 (1,0)。")
	_check(G, r.speed_delta == 0, "空格 speed_delta 期望 0。")
	_check(G, r.has_crystal == false, "空格 has_crystal 期望 false。")


## 9. Crystal 仅产生 has_crystal 事件，不点亮 Objective：MOVE + has_crystal=true；executor 无 objective 入口。
func _test_09_crystal_only_event() -> void:
	const G: String = "09_Crystal仅事件"
	var q: _Fake = _Fake.new()
	q.add_crystal(Vector2i(1, 0))
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "水晶格 outcome 仍期望 MOVE。")
	_check(G, r.has_crystal == true, "水晶格 has_crystal 期望 true。")
	_check(G, r.entered_cell == Vector2i(1, 0), "水晶格 entered_cell 期望 (1,0)。")
	# 结构保证：executor 不持有 / 不调 Objective，也不点亮水晶。
	_check(G, not ex.has_method("light_crystal"), "executor 不应暴露 light_crystal。")
	_check(G, not ex.has_method("set_objective"), "executor 不应暴露 set_objective。")
	# 只读查询不应改变 fake 的水晶登记。
	_check(G, q.has_crystal_at(Vector2i(1, 0)) == true, "evaluate_step 后水晶登记应不变。")


## 10. 速度机关返回 delta：next_cell 放置 FakeSpeedMechanism(+1) → MOVE + speed_delta=1。
func _test_10_speed_mechanism_delta() -> void:
	const G: String = "10_速度机关delta"
	var q: _Fake = _Fake.new()
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	q.add_mechanism(Vector2i(1, 0), m)
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "速度机关格 outcome 期望 MOVE。")
	_check(G, r.speed_delta == 1, "速度机关格 speed_delta 期望 1，实际 %d。" % r.speed_delta)
	_check(G, r.outgoing_direction == Vector2i(1, 0), "速度机关格 outgoing_direction 期望入射（不改向）。")
	_check(G, m.call_count == 1, "机关应被调用 1 次，实际 %d。" % m.call_count)
	_check(G, m.last_seen_direction == Vector2i(1, 0),
		"机关收到的方向应为入射 (1,0)，实际 (%d,%d)。" % [m.last_seen_direction.x, m.last_seen_direction.y])


## 11. executor 不修改 state：evaluate_step 前后 state 快照完全一致（绝不 apply_move / terminate）。
func _test_11_executor_no_state_mutation() -> void:
	const G: String = "11_executor不改state"
	var q: _Fake = _Fake.new()
	q.add_crystal(Vector2i(1, 0))
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	q.add_mechanism(Vector2i(1, 0), m)
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		7, 2, Vector2i(0, 0), Vector2i(1, 0), 5)
	var before: Dictionary = _snapshot_state(s)
	var r = ex.evaluate_step(s, q)
	# 即便结果是 MOVE + delta=1 + has_crystal，state 本身零变化。
	_check(G, r.outcome == _Executor.Outcome.MOVE, "应判 MOVE。")
	_check(G, r.speed_delta == 1, "delta 应为 1。")
	_check(G, r.has_crystal == true, "has_crystal 应为 true。")
	_check_snapshot_equals(G, before, _snapshot_state(s), "evaluate_step 后 state 应零变化")
	_check(G, s.is_active() == true, "executor 不应 terminate state，active 仍 true。")


## 12. 镜面反射 MOVE（D7-R5 GUI 验收修复）：next_cell 放 FakeReflectMechanism（SLASH）→ MOVE + entered=镜面格 +
##     outgoing_direction=反射方向 + speed_delta=0；next_step_blocked 前瞻沿反射方向计算（反射后正上方为墙 → true）。
func _test_12_mirror_reflection_move() -> void:
	const G: String = "12_镜面反射MOVE"
	var q: _Fake = _Fake.new()
	var m = _Fake.FakeReflectMechanism.new()
	m.slash = true
	q.add_mechanism(Vector2i(1, 0), m)
	q.add_wall(Vector2i(1, -1))  # 镜面格反射出射 UP 后的正下一格 → 前瞻应为 true
	var ex = _new_executor()
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var r = ex.evaluate_step(s, q)
	_check(G, r.outcome == _Executor.Outcome.MOVE, "镜面格 outcome 期望 MOVE（光粒进入镜面格并改向）。")
	_check(G, r.entered_cell == Vector2i(1, 0), "镜面格 entered_cell 期望 (1,0)。")
	_check(G, r.outgoing_direction == Vector2i(0, -1),
		"SLASH 镜入射 RIGHT 出射期望 UP(0,-1)，实际 (%d,%d)。" % [r.outgoing_direction.x, r.outgoing_direction.y])
	_check(G, r.speed_delta == 0, "镜面格 speed_delta 期望 0（改向不改速）。")
	_check(G, r.next_step_blocked == true,
		"反射方向前瞻：镜面格 + UP(1,-1) 为墙，next_step_blocked 期望 true，实际 %s。" % [str(r.next_step_blocked)])
	_check(G, m.call_count == 1, "reflect_direction 应被调用 1 次，实际 %d。" % m.call_count)
	_check(G, m.last_seen_direction == Vector2i(1, 0), "入射方向应原样传入镜面 (1,0)。")


## 拍摄 state 逻辑事实快照。
func _snapshot_state(s: _ParticleRuntimeState) -> Dictionary:
	return {
		"runtime_id": s.get_runtime_id(),
		"generation": s.get_generation(),
		"cell": s.get_cell(),
		"direction": s.get_direction(),
		"speed_tier": s.get_speed_tier(),
		"step_started_tick": s.get_step_started_tick(),
		"next_move_tick": s.get_next_move_tick(),
		"active": s.is_active(),
	}


## 逐字段比对两份快照。
func _check_snapshot_equals(group: String, expected: Dictionary, actual: Dictionary, label: String) -> void:
	for key: String in expected.keys():
		_check(group, expected[key] == actual[key],
			"%s：字段 %s 期望 %s，实际 %s。" % [label, key, expected[key], actual[key]])


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleStepExecutor 测试摘要（D7-4 B2）====")
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
