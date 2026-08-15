extends SceneTree

## ParticleVisualController 单元测试（D7-4 B4a）。
## 覆盖事件分发、EMITTED 创建/去重、多粒独立 View、MOVE snap 更新、TERMINATE 仅删对应 View、CLEARED 全清/幂等、
##   以及视觉层无法获得 scheduler/raw state / 不改 RunState/scheduler/Objective 的源码边界（forbidden 令牌扫描）。
## 用合成 detached 事件 Dictionary（模仿 ParticleVisualEvent.build_* 产出形态）直接驱动控制器，不依赖 runtime。
## 通过 preload 引用，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ParticleVisualController: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _ParticleViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	await process_frame
	_test_01_emitted_creates_one_view()
	_test_02_duplicate_emitted_no_double_view()
	_test_03_two_particles_two_independent_views()
	_test_04_move_updates_view_snap()
	_test_05_terminate_removes_only_that_view()
	_test_06_cleared_removes_all()
	_test_07_clear_idempotent()
	_test_08_no_path_to_scheduler_or_raw_state()
	_test_09_no_runstate_scheduler_objective_mutation()
	_test_10_m4e1_same_generation_multi_emitted_coexist()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造独立父节点与控制器，返回 { parent, controller }；父节点不加入场景树，调用方负责 free。
func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	var controller: _ParticleVisualController = _ParticleVisualController.new(parent)
	return { "parent": parent, "controller": controller }


# ===== 合成 detached 事件（模仿 ParticleVisualEvent.build_* 产出形态） =====

func _emitted(runtime_id: int, cell: Vector2i, direction: Vector2i) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_EMITTED,
		"runtime_id": runtime_id,
		"generation": 1,
		"cell": cell,
		"direction": direction,
		"speed_tier": 1,
		"step_started_tick": 0,
		"next_move_tick": 4,
	}


## M4-E1：带显式 generation 的 EMITTED（同 generation 多粒共存 / 跨 generation 清理边界用）。
func _emitted_gen(runtime_id: int, generation: int, cell: Vector2i, direction: Vector2i) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_EMITTED,
		"runtime_id": runtime_id,
		"generation": generation,
		"cell": cell,
		"direction": direction,
		"speed_tier": 1,
		"step_started_tick": 0,
		"next_move_tick": 4,
	}


func _tick(events: Array, tick: int = 4) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_TICK_BATCH_COMMITTED,
		"generation": 1,
		"tick": tick,
		"events": events,
	}


func _move_event(runtime_id: int, from_cell: Vector2i, entered_cell: Vector2i, direction: Vector2i) -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"generation": 1,
		"outcome": _ParticleVisualEvent.OUTCOME_MOVE,
		"from_cell": from_cell,
		"entered_cell": entered_cell,
		"direction": direction,
		"speed_tier": 1,
		"has_crystal": false,
		"termination_reason": _ParticleVisualEvent.TERMINATION_NONE,
		"next_move_tick": 8,
	}


func _terminate_event(runtime_id: int, from_cell: Vector2i) -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"generation": 1,
		"outcome": _ParticleVisualEvent.OUTCOME_TERMINATE,
		"from_cell": from_cell,
		"entered_cell": from_cell,
		"direction": Vector2i.RIGHT,
		"speed_tier": 1,
		"has_crystal": false,
		"termination_reason": _ParticleVisualEvent.TERMINATION_WALL,
		"next_move_tick": 0,
	}


func _cleared(old_generation: int, new_generation: int) -> Dictionary:
	return {
		"type": _ParticleVisualEvent.TYPE_CLEARED,
		"old_generation": old_generation,
		"new_generation": new_generation,
		"reason": _ParticleVisualEvent.REASON_RESET,
	}


# ===== 测试用例 =====

## 1.（spec 9）EMITTED → 创建一个 View：count==1、has_view(0)、View 位置=cell_to_world(cell)、rotation=angle(dir)。
func _test_01_emitted_creates_one_view() -> void:
	const NAME: String = "01_EMITTED创建一个View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	_check(NAME, controller.get_view_count() == 1, "EMITTED 后 View 数期望 1，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.has_view(0), "应存在 rid 0 的 View。")
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "rid 0 View 不应为 null。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(2, 3))), "View 初始位置期望 cell_to_world((2,3))，实际 %s。" % [view.position])
		_check(NAME, is_zero_approx(view.rotation), "RIGHT View rotation 期望 0，实际 %f。" % [view.rotation])
	(env["parent"] as Node2D).free()


## 2.（spec 10）runtime_id 重复 EMITTED 不产生双 View。
func _test_02_duplicate_emitted_no_double_view() -> void:
	const NAME: String = "02_重复EMITTED不产生双View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	_check(NAME, controller.get_view_count() == 1, "重复 EMITTED rid 0 后 View 数仍期望 1（去重），实际 %d。" % [controller.get_view_count()])
	(env["parent"] as Node2D).free()


## 3.（spec 11）两颗 Particle → 两个独立 View。
func _test_03_two_particles_two_independent_views() -> void:
	const NAME: String = "03_两颗Particle两个独立View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(1, 1), Vector2i.RIGHT))
	controller.handle_event(_emitted(5, Vector2i(2, 2), Vector2i.DOWN))
	_check(NAME, controller.get_view_count() == 2, "两颗光粒后期望 2 个 View，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.has_view(0) and controller.has_view(5), "应同时存在 rid 0 与 rid 5 的 View。")
	var v0: _ParticleViewScript = controller.get_view(0)
	var v5: _ParticleViewScript = controller.get_view(5)
	if _check(NAME, v0 != null and v5 != null, "两个 View 均不应为 null。"):
		_check(NAME, v0.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(1, 1))), "rid 0 位置期望 cell_to_world((1,1))。")
		_check(NAME, v5.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(2, 2))), "rid 5 位置期望 cell_to_world((2,2))。")
		_check(NAME, is_equal_approx(v5.rotation, Vector2(Vector2i.DOWN).angle()), "rid 5 DOWN rotation 期望 angle(DOWN)。")
	(env["parent"] as Node2D).free()


## 4.（spec 12）MOVE → 对应 View snap 更新（位置=cell_to_world(entered_cell)、rotation=angle(dir)）。
func _test_04_move_updates_view_snap() -> void:
	const NAME: String = "04_MOVE对应View更新"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	controller.handle_event(_tick([_move_event(0, Vector2i(2, 3), Vector2i(3, 3), Vector2i.RIGHT)], 4))
	var view: _ParticleViewScript = controller.get_view(0)
	if _check(NAME, view != null, "MOVE 后 rid 0 View 仍应存在。"):
		_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(3, 3))), "MOVE 后 View 位置期望 cell_to_world((3,3))，实际 %s。" % [view.position])
		_check(NAME, is_zero_approx(view.rotation), "MOVE RIGHT 后 rotation 期望 0，实际 %f。" % [view.rotation])
	_check(NAME, controller.get_view_count() == 1, "MOVE 后 View 数期望 1，实际 %d。" % [controller.get_view_count()])
	(env["parent"] as Node2D).free()


## 5.（spec 13）TERMINATE → 仅删除对应 View（其他保留）。
func _test_05_terminate_removes_only_that_view() -> void:
	const NAME: String = "05_TERMINATE仅删对应View"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	controller.handle_event(_emitted(1, Vector2i(4, 4), Vector2i.DOWN))
	controller.handle_event(_tick([_terminate_event(0, Vector2i(3, 3))], 8))
	_check(NAME, not controller.has_view(0), "TERMINATE rid 0 后应删除 rid 0 View。")
	_check(NAME, controller.has_view(1), "TERMINATE rid 0 不应影响 rid 1 View。")
	_check(NAME, controller.get_view_count() == 1, "View 数期望 1（仅 rid 1），实际 %d。" % [controller.get_view_count()])
	(env["parent"] as Node2D).free()


## 6.（spec 14）CLEARED → 全清。
func _test_06_cleared_removes_all() -> void:
	const NAME: String = "06_CLEARED全清"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	controller.handle_event(_emitted(7, Vector2i(5, 5), Vector2i.UP))
	controller.handle_event(_cleared(1, 2))
	_check(NAME, controller.get_view_count() == 0, "CLEARED 后 View 数期望 0，实际 %d。" % [controller.get_view_count()])
	_check(NAME, not controller.has_view(0) and not controller.has_view(7), "CLEARED 后不应残留任何 View。")
	(env["parent"] as Node2D).free()


## 7.（spec 15）清理幂等：连续 clear_all 安全。
func _test_07_clear_idempotent() -> void:
	const NAME: String = "07_清理幂等"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	controller.handle_event(_emitted(0, Vector2i(2, 3), Vector2i.RIGHT))
	controller.clear_all()
	controller.clear_all()
	controller.handle_event(_cleared(1, 2))
	_check(NAME, controller.get_view_count() == 0, "连续清理后 View 数期望 0，实际 %d。" % [controller.get_view_count()])
	(env["parent"] as Node2D).free()


## 8.（spec 8）视觉层无法获得 scheduler / raw state：控制器源码无 gameplay 模块 preload 路径、无 raw 访问方法。
func _test_08_no_path_to_scheduler_or_raw_state() -> void:
	const NAME: String = "08_视觉无法获得scheduler或raw_state"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/particles/particle_visual_controller.gd")
	# 禁止的 gameplay preload 路径（出现即证明控制器直接依赖 gameplay 模块）。
	var forbidden_paths: Array = [
		"res://gameplay/particle", "res://gameplay/runtime", "res://gameplay/objectives",
		"res://gameplay/interaction", "res://gameplay/world",
	]
	for p: String in forbidden_paths:
		_check(NAME, src.find(p) == -1, "控制器源码不应 preload gameplay 模块路径：%s" % [p])
	# 禁止的 raw 访问 / 调度器方法调用（出现即证明控制器触及 gameplay truth）。
	var forbidden_calls: Array = [
		"advance_one_tick", "emit_particle", "is_drained", "get_particle_state_snapshot",
		"get_current_tick", "get_current_generation", "_active_states",
	]
	for c: String in forbidden_calls:
		_check(NAME, src.find(c) == -1, "控制器源码不应含调度器/raw 访问令牌：%s" % [c])


## 9.（spec 16）控制器不改变 RunState/scheduler/Objective：源码无 RunState/Objective/发射/移动次数 mutation 方法调用。
func _test_09_no_runstate_scheduler_objective_mutation() -> void:
	const NAME: String = "09_不改RunState_scheduler_Objective"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/particles/particle_visual_controller.gd")
	var forbidden_calls: Array = [
		"begin_pulse", "finish_pulse", "begin_runtime", "reset_to_setup",
		"try_activate_crystal_at", "request_fire", "consume_runtime_move",
		"reset_runtime", "begin_generation",
	]
	for c: String in forbidden_calls:
		_check(NAME, src.find(c) == -1, "控制器源码不应含 RunState/Objective/发射 mutation 令牌：%s" % [c])
	# 控制器只暴露视觉 API（handle_event / clear_all / 只读 getter），不暴露 gameplay mutation。
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	_check(NAME, controller.has_method("handle_event"), "控制器应暴露 handle_event。")
	_check(NAME, controller.has_method("clear_all"), "控制器应暴露 clear_all。")
	_check(NAME, not controller.has_method("advance_one_tick"), "控制器不应暴露调度器推进方法。")
	_check(NAME, not controller.has_method("request_fire"), "控制器不应暴露发射方法。")
	(env["parent"] as Node2D).free()


## 10.（M4-E1 #12/#13）同 generation 多 EMITTED 共存；第二次 Fire 的 EMITTED（同 generation）不清第一颗 View；只有 CLEARED（reset）或更高 generation 才清旧 View。
## [br]证明 visual generation 不被每发推进——同 generation 内 EMITTED #1/#2/#3 全部共存；generation high-watermark 仅被 CLEARED / 更高 generation EMITTED 推进。
func _test_10_m4e1_same_generation_multi_emitted_coexist() -> void:
	const NAME: String = "10_M4E1同generation多EMITTED共存"
	var env: Dictionary = _make_controller()
	var controller: _ParticleVisualController = env["controller"]
	# 同 generation=5 三次 EMITTED（模拟同一 Runtime epoch 内多次发射，M4-E1 generation 不再每发推进）。
	controller.handle_event(_emitted_gen(0, 5, Vector2i(1, 1), Vector2i.RIGHT))
	controller.handle_event(_emitted_gen(1, 5, Vector2i(2, 2), Vector2i.DOWN))
	controller.handle_event(_emitted_gen(2, 5, Vector2i(3, 3), Vector2i.LEFT))
	_check(NAME, controller.get_view_count() == 3, "同 generation 三次 EMITTED 应共存 3 View，实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.has_view(0) and controller.has_view(1) and controller.has_view(2), "三颗 rid 0/1/2 View 均应存在（#12 同代共存、#13 第二次 EMITTED 不清第一颗）。")
	_check(NAME, controller.get_current_visual_generation() == 5, "visual generation watermark 期望 5（同代 EMITTED 不推进）。")
	_check(NAME, controller.get_view_generation(0) == 5 and controller.get_view_generation(1) == 5, "rid 0/1 登记 generation 均期望 5。")
	# 只有 CLEARED（reset）才清旧 visual（#13）：CLEARED new=6 > watermark 5 → 推进 + 全清。
	controller.handle_event(_cleared(5, 6))
	_check(NAME, controller.get_view_count() == 0, "CLEARED 后全部 View 清空（#13 reset/CLEARED 才清旧 visual），实际 %d。" % [controller.get_view_count()])
	_check(NAME, controller.get_current_visual_generation() == 6, "CLEARED 后 watermark 推进到 6。")
	(env["parent"] as Node2D).free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleVisualController 单元测试摘要（D7-4 B4a）====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
