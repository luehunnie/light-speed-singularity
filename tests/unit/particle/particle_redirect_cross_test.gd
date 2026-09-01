extends SceneTree

## C-08 Particle REDIRECT_CROSS 逐tick跨格语义定向测试。
## 覆盖：executor 直测（机关步：outgoing=cross + pending 写穿；跨格消费步：outgoing=redirect + pending 清零，
##   不查机关；水晶照常记录）；scheduler 三tick流（机关格→跨界格→改向继续）；跨界格墙体 WALL 停止；
##   同机关跨格不重复交互（query 机关查询计数恰 1）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _Scheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _Executor: GDScript = preload("res://gameplay/particle/particle_step_executor.gd")
const _State: GDScript = preload("res://gameplay/particle/particle_runtime_state.gd")
const _MotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _Result: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _FakeQuery: GDScript = preload("res://tests/unit/particle/fixtures/fake_particle_world_query.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_executor_mechanism_step_writes_pending()
	_test_02_executor_pending_step_consumes_and_clears()
	_test_03_scheduler_three_tick_flow()
	_test_04_crossed_cell_wall_terminates()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, cond: bool, why: String) -> void:
	_checks += 1
	if not cond:
		_failures.append("[%s] %s" % [group, why])


## 计数型等价 world query：记录 get_light_mechanism_at 的查询格（观察跨格消费步跳过机关查询）。
class _CountingQuery extends "res://tests/unit/particle/fixtures/fake_particle_world_query.gd":
	var mechanism_query_cells: Array[Vector2i] = []
	func get_light_mechanism_at(cell: Vector2i) -> Variant:
		mechanism_query_cells.append(cell)
		return super.get_light_mechanism_at(cell)


## 伪造 PARTICLE 契约机关：返回 REDIRECT_CROSS 并计数调用。
class _CrossMechanism extends RefCounted:
	var ray_calls: int = 0
	func get_light_interaction_forms() -> Array[StringName]:
		return [&"PARTICLE"]
	func interact_particle(_particle_context: Variant) -> Variant:
		ray_calls += 1
		return _Result.redirect_cross_result(Vector2i(1, 0), Vector2i(0, 1))


## 1. executor 机关步：进入机关格，outgoing=cross_direction，pending 写穿为 redirect，水晶照常记录。
func _test_01_executor_mechanism_step_writes_pending() -> void:
	const G: String = "01_机关步写穿"
	var query: _CountingQuery = _CountingQuery.new()
	query.add_crystal(Vector2i(5, 6))
	query.add_mechanism(Vector2i(5, 6), _CrossMechanism.new())
	var state: Variant = _State.create_emitted(0, 1, Vector2i(5, 5), Vector2i(0, 1), 0, 55)
	var executor: _Executor = _Executor.new()
	var result: Variant = executor.evaluate_step(state, query)
	_check(G, result.outcome == _Executor.Outcome.MOVE, "机关 REDIRECT_CROSS 应 MOVE 进入机关格。")
	_check(G, result.entered_cell == Vector2i(5, 6), "应进入机关格 (5,6)。")
	_check(G, result.outgoing_direction == Vector2i(0, 1), "离开方向应为 cross_direction (0,1)。")
	_check(G, result.next_pending_redirect == Vector2i(1, 0), "pending 应写穿为 redirect (1,0)。")
	_check(G, result.has_crystal, "机关格水晶应照常记录。")
	_check(G, result.speed_delta == 0, "跨格语义不改速度（delta 恒 0）。")


## 2. executor 跨格消费步：pending 存在时不查机关、outgoing=pending、pending 写穿清零。
func _test_02_executor_pending_step_consumes_and_clears() -> void:
	const G: String = "02_跨格消费步"
	var query: _CountingQuery = _CountingQuery.new()
	query.add_crystal(Vector2i(5, 7))
	var state: Variant = _State.create_emitted(0, 1, Vector2i(5, 6), Vector2i(0, 1), 0, 55)
	state.set_pending_redirect_direction(Vector2i(1, 0))
	var executor: _Executor = _Executor.new()
	var result: Variant = executor.evaluate_step(state, query)
	_check(G, result.outcome == _Executor.Outcome.MOVE, "跨格消费步应 MOVE 进入跨界格。")
	_check(G, result.entered_cell == Vector2i(5, 7), "应进入同机关第二格 (5,7)。")
	_check(G, result.outgoing_direction == Vector2i(1, 0), "离开方向应为 pending 改向 (1,0)。")
	_check(G, result.next_pending_redirect == Vector2i.ZERO, "消费步 pending 应写穿清零。")
	_check(G, result.has_crystal, "跨界格水晶应照常记录（水晶非机关）。")
	_check(G, not query.mechanism_query_cells.has(Vector2i(5, 7)), "跨格消费步不得查询机关格 (5,7)（同机关不重复交互）。")


## 逐tick泵进直到产出事件或达上限（motion rules 每格多 tick，测试不假设固定 tick 数）。
func _pump_until_event(scheduler: Variant, generation: int, max_ticks: int = 32) -> Array:
	for i in range(max_ticks):
		var events: Array = scheduler.advance_one_tick(generation)
		if not events.is_empty():
			return events
	return []


## 3. scheduler 流：机关格(cross)→跨界格(redirect)→改向继续；机关查询仅 1 次。
func _test_03_scheduler_three_tick_flow() -> void:
	const G: String = "03_scheduler三tick"
	var query: _CountingQuery = _CountingQuery.new()
	var mech: _CrossMechanism = _CrossMechanism.new()
	query.add_mechanism(Vector2i(5, 6), mech)
	query.add_crystal(Vector2i(5, 7))
	var scheduler: Variant = _Scheduler.new(query)
	scheduler.begin_generation(1)
	var rid: int = scheduler.emit_particle(Vector2i(5, 5), Vector2i(0, 1), 55)
	_check(G, rid >= 0, "发射应成功。")
	var step1: Array = _pump_until_event(scheduler, 1)
	_check(G, step1.size() == 1 and step1[0].entered_cell == Vector2i(5, 6), "第 1 事件应进入机关格。")
	_check(G, step1[0].direction == Vector2i(0, 1), "第 1 事件离开方向应为 cross (0,1)。")
	var step2: Array = _pump_until_event(scheduler, 1)
	_check(G, step2.size() == 1 and step2[0].entered_cell == Vector2i(5, 7), "第 2 事件应进入跨界格 (5,7)。")
	_check(G, step2[0].direction == Vector2i(1, 0), "第 2 事件离开方向应为 redirect (1,0)。")
	_check(G, step2[0].has_crystal, "跨界格水晶应照常记录。")
	var step3: Array = _pump_until_event(scheduler, 1)
	_check(G, step3.size() == 1 and step3[0].entered_cell == Vector2i(6, 7), "第 3 事件应沿改向进入 (6,7)。")
	_check(G, mech.ray_calls == 1 and not query.mechanism_query_cells.has(Vector2i(5, 7)), "机关只触发 1 次，跨界格 (5,7) 不得被机关查询。")


## 4. 跨界格墙体：边界/墙体检查先行，WALL 终止（与普通步进同形），不进入跨界格。
func _test_04_crossed_cell_wall_terminates() -> void:
	const G: String = "04_跨界格墙体"
	var query: _CountingQuery = _CountingQuery.new()
	query.add_wall(Vector2i(5, 7))
	query.add_mechanism(Vector2i(5, 6), _CrossMechanism.new())
	var scheduler: Variant = _Scheduler.new(query)
	scheduler.begin_generation(1)
	var rid: int = scheduler.emit_particle(Vector2i(5, 5), Vector2i(0, 1), 55)
	var step1: Array = _pump_until_event(scheduler, 1)
	_check(G, step1.size() == 1 and step1[0].outcome == _Executor.Outcome.MOVE, "第 1 事件应正常进入机关格。")
	var step2: Array = _pump_until_event(scheduler, 1)
	_check(G, step2.size() == 1 and step2[0].outcome == _Executor.Outcome.TERMINATE, "跨界格墙体应 TERMINATE。")
	_check(G, step2[0].termination_reason == _Executor.TerminationReason.WALL, "终止原因应为 WALL。")
	_check(G, step2[0].entered_cell == Vector2i(5, 7), "被阻挡尝试格应为 (5,7)（未进入）。")
	_check(G, scheduler.is_drained(), "光粒应被回收（drain 完成）。")


func _report() -> void:
	print("C-08 particle redirect_cross: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
