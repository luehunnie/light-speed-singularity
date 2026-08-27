extends SceneTree

## LightVisualController 定向自动测试（Day 3 D3-B；M4-E2 改 per-emission ownership）。
## 覆盖 show_step(emission_id, generation, cell, direction) 创建/多步/cell 传递/四方向映射/非法方向；
##   clear_emission 只清自身、clear_all 全清、连续清理安全、重建、计数；
##   M4-E2 per-emission 隔离：新 Ray 不清旧 Ray、clear_emission(1) 不影响 emission 2、stale emission_id clear 天然 no-op；
##   不访问水晶不修改状态、视觉→水晶顺序接线。
## 通过 preload 引用控制器与 LightSegmentView，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 替身策略：每个用例新建一个 Node2D 父节点（不加入场景树），控制器把片段 add_child 到该父节点；
## LightSegmentView 的 @onready 子节点未就绪时 refresh_visual() 安全返回，_direction 字段仍写入，足以断言方向与位置接线。


const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _LightSegmentViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _RayEmissionDriver: GDScript = preload("res://gameplay/runtime/ray_emission_driver.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_test_01_show_step_creates_one()
	_test_02_multi_step_creates_many()
	_test_03_cell_position_passed()
	_test_04_horizontal_mapping()
	_test_05_vertical_mapping()
	_test_06_slash_mapping()
	_test_07_backslash_mapping()
	_test_08_invalid_direction_legacy()
	_test_09_clear_emission_removes_only_that_emission()
	_test_10_clear_all_removes_all()
	_test_11_repeated_clear_safe()
	_test_12_recreate_after_clear()
	_test_13_segment_count_total()
	_test_14_new_ray_does_not_clear_old_ray()
	_test_15_clear_one_emission_keeps_other()
	_test_16_stale_emission_clear_noop()
	_test_17_emission_segment_count_and_generation()
	_test_18_no_crystal_access()
	_test_19_no_state_mutation()
	_test_20_wiring_visual_before_crystal()
	_test_21_reflection_step_two_half_segments()
	_test_22_driver_reflection_cell_renders_corner()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一个独立父节点与控制器，返回 { parent, controller }；父节点不加入场景树，调用方负责 free。
func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	var controller: _LightVisualController = _LightVisualController.new(parent)
	return { "parent": parent, "controller": controller }


## 1. show_step 创建一个片段（emission 1）。
func _test_01_show_step_creates_one() -> void:
	const NAME: String = "01_show_step创建一个"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var ok: bool = controller.show_step(1, 1, Vector2i(2, 3), Vector2i.RIGHT)
	_check(NAME, ok, "show_step 返回期望 true。")
	_check(NAME, controller.get_segment_count() == 1, "片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_emission_segment_count(1) == 1, "emission1 片段数期望 1。")
	_check(NAME, controller.get_segments_for_emission(1).size() == 1, "emission1 片段副本 size 期望 1。")
	(env["parent"] as Node2D).free()


## 2. 多 step 同 emission 创建多个片段。
func _test_02_multi_step_creates_many() -> void:
	const NAME: String = "02_多step创建多个"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(1, 1, Vector2i(2, 1), Vector2i.RIGHT)
	controller.show_step(1, 1, Vector2i(3, 1), Vector2i.UP)
	_check(NAME, controller.get_segment_count() == 3, "片段数期望 3，实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_emission_segment_count(1) == 3, "emission1 片段数期望 3。")
	_check(NAME, controller.get_emission_count() == 1, "仍只有 1 个 emission。")
	(env["parent"] as Node2D).free()


## 3. cell 位置正确传递到片段根节点 position。
func _test_03_cell_position_passed() -> void:
	const NAME: String = "03_cell位置传递"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var cell: Vector2i = Vector2i(4, 7)
	controller.show_step(1, 1, cell, Vector2i.DOWN)
	var views: Array = controller.get_segments_for_emission(1)
	if _check(NAME, views.size() == 1, "emission1 片段数期望 1。"):
		var view: _LightSegmentViewScript = views[0]
		var expected: Vector2 = _GridCoordinateRules.cell_to_world(cell)
		_check(NAME, view.position == expected, "position 期望 %s，实际 %s。" % [expected, view.position])
	(env["parent"] as Node2D).free()


## 4. 水平映射：RIGHT → horizontal。
func _test_04_horizontal_mapping() -> void:
	_check_mapping("04_水平映射", Vector2i.RIGHT, _LightSegmentVisualProfile.STATE_HORIZONTAL)


## 5. 垂直映射：DOWN → vertical。
func _test_05_vertical_mapping() -> void:
	_check_mapping("05_垂直映射", Vector2i.DOWN, _LightSegmentVisualProfile.STATE_VERTICAL)


## 6. slash 映射：(1,-1) → slash。
func _test_06_slash_mapping() -> void:
	_check_mapping("06_slash映射", Vector2i(1, -1), _LightSegmentVisualProfile.STATE_SLASH)


## 7. backslash 映射：(1,1) → backslash。
func _test_07_backslash_mapping() -> void:
	_check_mapping("07_backslash映射", Vector2i(1, 1), _LightSegmentVisualProfile.STATE_BACKSLASH)


## 8. 非法方向按旧行为处理：仍创建片段并回退占位块，不拒绝。
func _test_08_invalid_direction_legacy() -> void:
	const NAME: String = "08_非法方向按旧行为"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var ok: bool = controller.show_step(1, 1, Vector2i(0, 0), Vector2i.ZERO)
	_check(NAME, ok, "非法方向仍应创建片段并返回 true（旧行为）。")
	_check(NAME, controller.get_segment_count() == 1, "非法方向片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	var views: Array = controller.get_segments_for_emission(1)
	if _check(NAME, views.size() == 1, "片段不应为空。"):
		var view: _LightSegmentViewScript = views[0]
		# 非法方向不映射到任意纹理形态，状态为空。
		_check(NAME, view._direction == Vector2i.ZERO, "_direction 期望 ZERO，实际 %s。" % [view._direction])
		var state: StringName = _LightSegmentVisualProfile.get_segment_state_for_direction(view._direction)
		_check(NAME, state == &"", "非法方向状态期望空，实际 %s。" % [state])
	(env["parent"] as Node2D).free()


## 9. clear_emission 只清自身：emission 1/2 各有片段，clear_emission(1) 后 emission 1 清空、emission 2 不受影响。
func _test_09_clear_emission_removes_only_that_emission() -> void:
	const NAME: String = "09_clear_emission只清自身"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(2, 1, Vector2i(5, 5), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 2, "前置两 emission 各 1 段，总数期望 2。")
	controller.clear_emission(1)
	_check(NAME, controller.get_emission_segment_count(1) == 0, "clear_emission(1) 后 emission1 片段期望 0。")
	_check(NAME, controller.get_segments_for_emission(1).is_empty(), "emission1 片段副本应空。")
	_check(NAME, controller.get_emission_segment_count(2) == 1, "emission2 片段不受影响，期望 1。")
	_check(NAME, controller.get_segment_count() == 1, "总片段数期望 1（只剩 emission2）。")
	(env["parent"] as Node2D).free()


## 10. clear_all 清理全部节点。
func _test_10_clear_all_removes_all() -> void:
	const NAME: String = "10_clear_all清理全部"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(2, 1, Vector2i(2, 1), Vector2i.RIGHT)
	controller.clear_all()
	_check(NAME, controller.get_segment_count() == 0, "清理后片段数期望 0，实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_emission_count() == 0, "清理后 emission 数期望 0。")
	_check(NAME, controller.get_segments_for_emission(1).is_empty(), "清理后 emission1 片段副本应空。")
	(env["parent"] as Node2D).free()


## 11. 连续 clear 安全（无片段时空遍历不报错；clear_all / clear_emission 均幂等）。
func _test_11_repeated_clear_safe() -> void:
	const NAME: String = "11_连续clear安全"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.clear_emission(1)
	controller.clear_emission(1)
	controller.clear_all()
	controller.clear_all()
	_check(NAME, controller.get_segment_count() == 0, "连续清理后片段数期望 0，实际 %d。" % [controller.get_segment_count()])
	(env["parent"] as Node2D).free()


## 12. clear 后可重新创建（同 emission_id 重建或新 emission_id）。
func _test_12_recreate_after_clear() -> void:
	const NAME: String = "12_clear后可重建"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.clear_emission(1)
	var ok: bool = controller.show_step(1, 1, Vector2i(5, 5), Vector2i.UP)
	_check(NAME, ok, "清理后再次 show_step 应成功。")
	_check(NAME, controller.get_segment_count() == 1, "重建后片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	var views: Array = controller.get_segments_for_emission(1)
	if _check(NAME, views.size() == 1, "重建片段不应为空。"):
		_check(NAME, views[0]._direction == Vector2i.UP, "重建片段方向期望 UP，实际 %s。" % [views[0]._direction])
	(env["parent"] as Node2D).free()


## 13. get_segment_count 正确（初始/递增/清理后归零；跨多 emission 求和）。
func _test_13_segment_count_total() -> void:
	const NAME: String = "13_get_segment_count总数"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	_check(NAME, controller.get_segment_count() == 0, "初始片段数期望 0。")
	controller.show_step(1, 1, Vector2i(0, 0), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 1, "1 步后期望 1，实际 %d。" % [controller.get_segment_count()])
	controller.show_step(1, 1, Vector2i(1, 0), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 2, "2 步后期望 2，实际 %d。" % [controller.get_segment_count()])
	controller.show_step(2, 1, Vector2i(9, 9), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 3, "emission2 加 1 段后期望 3，实际 %d。" % [controller.get_segment_count()])
	controller.clear_emission(1)
	_check(NAME, controller.get_segment_count() == 1, "清 emission1 后期望 1（只剩 emission2），实际 %d。" % [controller.get_segment_count()])
	controller.clear_all()
	_check(NAME, controller.get_segment_count() == 0, "clear_all 后期望 0。")
	(env["parent"] as Node2D).free()


## 14.（spec 九）新 Ray 不清旧 Ray：emission 1 show_step 后 emission 2 show_step，emission 1 片段完好。
func _test_14_new_ray_does_not_clear_old_ray() -> void:
	const NAME: String = "14_新Ray不清旧Ray"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(1, 1, Vector2i(2, 1), Vector2i.RIGHT)
	_check(NAME, controller.get_emission_segment_count(1) == 2, "前置 emission1 有 2 段。")
	# 新 Ray（emission 2）不清旧 Ray（emission 1）。
	controller.show_step(2, 1, Vector2i(5, 5), Vector2i.RIGHT)
	controller.show_step(2, 1, Vector2i(6, 5), Vector2i.RIGHT)
	_check(NAME, controller.get_emission_segment_count(1) == 2, "新 Ray 后 emission1 片段仍 2（不被清）。")
	_check(NAME, controller.get_emission_segment_count(2) == 2, "emission2 片段期望 2。")
	_check(NAME, controller.get_segment_count() == 4, "总片段期望 4。")
	_check(NAME, controller.get_emission_count() == 2, "emission 数期望 2。")
	(env["parent"] as Node2D).free()


## 15.（spec 九）clear_emission(1) 不影响 emission 2：两 emission 各有片段，clear emission1 后 emission2 视觉与方向保持。
func _test_15_clear_one_emission_keeps_other() -> void:
	const NAME: String = "15_清一emission不影响其它"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(2, 1, Vector2i(7, 7), Vector2i.DOWN)
	controller.clear_emission(1)
	_check(NAME, controller.get_emission_segment_count(1) == 0, "emission1 清空。")
	var views2: Array = controller.get_segments_for_emission(2)
	if _check(NAME, views2.size() == 1, "emission2 片段仍 1（不受 emission1 清理影响）。"):
		_check(NAME, views2[0]._direction == Vector2i.DOWN, "emission2 方向保持 DOWN。")
		var expected: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(7, 7))
		_check(NAME, views2[0].position == expected, "emission2 position 保持 %s。" % [expected])
	_check(NAME, controller.get_emission_count() == 1, "emission 数期望 1（只剩 emission2）。")
	(env["parent"] as Node2D).free()


## 16.（spec 九）stale emission_id clear 天然 no-op：clear_emission(999)（从未 show）不影响现有 emission；emission_id 跨 clear 不复用。
func _test_16_stale_emission_clear_noop() -> void:
	const NAME: String = "16_stale_emission_clear为no-op"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(1, 1), Vector2i.RIGHT)
	# clear 一个从未 show 过的 emission_id（模拟 stale / 旧 epoch 残留 id）：安全 no-op，不影响 emission1。
	controller.clear_emission(999)
	_check(NAME, controller.get_emission_segment_count(1) == 1, "stale clear 不影响 emission1，片段仍 1。")
	_check(NAME, controller.get_segment_count() == 1, "总片段仍 1。")
	# clear 后再 clear 同 id（已清）幂等 no-op。
	controller.clear_emission(1)
	controller.clear_emission(1)
	_check(NAME, controller.get_segment_count() == 0, "emission1 清空后总片段 0。")
	(env["parent"] as Node2D).free()


## 17. get_emission_segment_count / get_emission_generation / get_emission_count 诊断：未登记返回 0/-1/不计入。
func _test_17_emission_segment_count_and_generation() -> void:
	const NAME: String = "17_emission诊断访问器"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	_check(NAME, controller.get_emission_segment_count(1) == 0, "未登记 emission 片段数期望 0。")
	_check(NAME, controller.get_emission_generation(1) == -1, "未登记 emission generation 期望 -1。")
	_check(NAME, controller.get_emission_count() == 0, "初始 emission 数期望 0。")
	controller.show_step(1, 5, Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(1, 5, Vector2i(2, 1), Vector2i.RIGHT)
	controller.show_step(2, 6, Vector2i(9, 9), Vector2i.RIGHT)
	_check(NAME, controller.get_emission_generation(1) == 5, "emission1 generation metadata 期望 5。")
	_check(NAME, controller.get_emission_generation(2) == 6, "emission2 generation metadata 期望 6。")
	_check(NAME, controller.get_emission_count() == 2, "emission 数期望 2。")
	_check(NAME, controller.get_segments_for_emission(999).is_empty(), "未登记 emission 片段副本应空。")
	(env["parent"] as Node2D).free()


## 18. 不访问水晶：控制器源码不应引用水晶或激活等视觉无关职责（静态接线检查）。
func _test_18_no_crystal_access() -> void:
	const NAME: String = "18_不访问水晶"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/light_visual_controller.gd")
	var forbidden: Array = ["activate", "crystal", "Crystal", "BasicCrystal", "try_activate_crystal", "all_required_crystals"]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "控制器源码不应包含视觉无关令牌：%s" % [token])


## 19. 不修改状态：控制器源码不应引用运行状态/脉冲版本/完成/库存/放置/拖拽/计时器等事实（静态接线检查）。
func _test_19_no_state_mutation() -> void:
	const NAME: String = "19_不修改状态"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/light_visual_controller.gd")
	var forbidden: Array = [
		"_run_state_controller", "pulse_generation", "is_level_completed",
		"begin_pulse", "finish_pulse", "reset_to_setup", "create_timer",
		"_inventory_controller", "_placement_controller", "_drag_flow_controller",
		"RunState", "RayExecutionModule", "RayExecutionResult"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "控制器源码不应包含状态/传播相关令牌：%s" % [token])


## 20. 应用结果仍保持视觉→水晶顺序（M4-E2.1：_apply_ray_execution_result 迁入 RayEmissionDriver，扫描其源码确认 show_step 早于 apply_hit 水晶命中，且无第二套视觉创建实现；S3-05 起命中经 ObjectiveHitContext→apply_hit）。
func _test_20_wiring_visual_before_crystal() -> void:
	const NAME: String = "20_视觉→水晶顺序接线"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/ray_emission_driver.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result（应在 RayEmissionDriver 内）。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var crystal_idx: int = body.find("_objective_controller.apply_hit")
		_check(NAME, show_idx != -1, "_apply_ray_execution_result 应调用 _light_visual_controller.show_step。")
		_check(NAME, crystal_idx != -1, "_apply_ray_execution_result 应调用 _objective_controller.apply_hit。")
		_check(NAME, show_idx < crystal_idx, "视觉创建必须在水晶命中之前（show_step @ %d < apply_hit @ %d）。" % [show_idx, crystal_idx])
		# 不得保留第二套视觉创建实现。
		_check(NAME, body.find("add_light_visual") == -1, "不得在 _apply_ray_execution_result 保留 add_light_visual 第二套实现。")


## 21. 反射格两段半光束（D7-R5 反射格视觉修复）：show_reflection_step 在同一格创建两段半段视图——
##     入射半段方向 = -incoming、出射半段方向 = outgoing；两段位置同为该格中心；计入 emission 桶与总数；clear_emission 一并清理。
func _test_21_reflection_step_two_half_segments() -> void:
	const NAME: String = "21_反射格两段半光束"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var ok: bool = controller.show_reflection_step(1, 5, Vector2i(3, 3), Vector2i.RIGHT, Vector2i.UP)
	_check(NAME, ok, "show_reflection_step 返回期望 true。")
	_check(NAME, controller.get_segment_count() == 2, "反射格应创建 2 段（入射半段 + 出射半段），实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_emission_segment_count(1) == 2, "emission1 片段数期望 2。")
	_check(NAME, controller.get_emission_generation(1) == 5, "emission1 generation metadata 期望 5。")
	var views: Array = controller.get_segments_for_emission(1)
	if _check(NAME, views.size() == 2, "片段副本 size 期望 2。"):
		var incoming_half: _LightSegmentViewScript = views[0]
		var outgoing_half: _LightSegmentViewScript = views[1]
		var cell_world: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 3))
		_check(NAME, incoming_half._direction == Vector2i(-1, 0),
			"入射半段方向期望 -incoming=(-1,0)，实际 %s。" % [str(incoming_half._direction)])
		_check(NAME, outgoing_half._direction == Vector2i(0, -1),
			"出射半段方向期望 outgoing=(0,-1)，实际 %s。" % [str(outgoing_half._direction)])
		_check(NAME, incoming_half.position == cell_world, "入射半段位置期望格中心 %s。" % [str(cell_world)])
		_check(NAME, outgoing_half.position == cell_world, "出射半段位置期望格中心 %s。" % [str(cell_world)])
	# clear_emission 一并清理两段半段。
	controller.clear_emission(1)
	_check(NAME, controller.get_segment_count() == 0, "clear_emission 后片段数期望 0。")
	(env["parent"] as Node2D).free()


## 22. RayEmissionDriver 反射格拐角接线（D7-R5 反射格视觉修复）：相邻 step 进入方向不同的格（镜面格）
##     由 driver 改画两段半光束（show_reflection_step），其余格照常 show_step；水晶仍按 step 顺序处理。
##     用替身视觉记录器直接驱动 _apply_ray_execution_result（不进 dispatch / 不建 timer），锁定 driver 对 steps 的视觉分派。
func _test_22_driver_reflection_cell_renders_corner() -> void:
	const NAME: String = "22_driver反射格拐角"
	var recorder: FakeVisualRecorder = FakeVisualRecorder.new()
	var objective: FakeObjectiveRecorder = FakeObjectiveRecorder.new()
	var driver = _RayEmissionDriver.new(recorder, objective, null, 16, 0.0, Callable(), Callable())
	# 手工构造传播结果：(2,3) RIGHT → (3,3) RIGHT（镜面格，下一步进入方向变 UP = 本格改向）→ (3,2) UP。
	var result = _RayExecutionResult.new()
	result.add_step(Vector2i(2, 3), Vector2i.RIGHT, false)
	result.add_step(Vector2i(3, 3), Vector2i.RIGHT, true)
	result.add_step(Vector2i(3, 2), Vector2i.UP, false)
	driver.call("_apply_ray_execution_result", result, 1, 5)
	_check(NAME, recorder.full_calls.size() == 2, "非反射格应照常 show_step 2 次，实际 %d。" % recorder.full_calls.size())
	if recorder.full_calls.size() == 2:
		_check(NAME, recorder.full_calls[0]["cell"] == Vector2i(2, 3) and recorder.full_calls[0]["direction"] == Vector2i.RIGHT,
			"首格应为 (2,3)+RIGHT 全段。")
		_check(NAME, recorder.full_calls[1]["cell"] == Vector2i(3, 2) and recorder.full_calls[1]["direction"] == Vector2i.UP,
			"末格应为 (3,2)+UP 全段。")
	_check(NAME, recorder.reflection_calls.size() == 1, "反射格应恰好 show_reflection_step 1 次，实际 %d。" % recorder.reflection_calls.size())
	if recorder.reflection_calls.size() == 1:
		var call: Dictionary = recorder.reflection_calls[0]
		_check(NAME, call["cell"] == Vector2i(3, 3), "反射格应为镜面格 (3,3)。")
		_check(NAME, call["incoming"] == Vector2i.RIGHT, "反射格入射方向期望 RIGHT。")
		_check(NAME, call["outgoing"] == Vector2i.UP, "反射格出射方向期望 UP。")
		_check(NAME, call["emission_id"] == 1 and call["generation"] == 5, "反射段应携带 emission/generation metadata。")
	# 水晶格仍按 step 处理（(3,3) has_crystal=true）。
	_check(NAME, objective.activated_cells.size() == 1 and objective.activated_cells[0] == Vector2i(3, 3),
		"镜面格水晶应仍被处理，实际 %s。" % [str(objective.activated_cells)])
	# 无反射路径（方向全程一致）不触发 show_reflection_step。
	var recorder2: FakeVisualRecorder = FakeVisualRecorder.new()
	var driver2 = _RayEmissionDriver.new(recorder2, FakeObjectiveRecorder.new(), null, 16, 0.0, Callable(), Callable())
	var result2 = _RayExecutionResult.new()
	result2.add_step(Vector2i(2, 3), Vector2i.RIGHT, false)
	result2.add_step(Vector2i(3, 3), Vector2i.RIGHT, false)
	driver2.call("_apply_ray_execution_result", result2, 1, 5)
	_check(NAME, recorder2.reflection_calls.is_empty() and recorder2.full_calls.size() == 2,
		"方向不变的路径不应产生反射段（2 全段，0 反射段）。")


## 替身视觉记录器：记录 show_step / show_reflection_step 调用（cell/direction/emission/generation），供组 22 断言分派。
class FakeVisualRecorder:
	extends RefCounted

	var full_calls: Array = []
	var reflection_calls: Array = []

	func show_step(emission_id: int, generation: int, cell: Vector2i, direction: Vector2i) -> bool:
		full_calls.append({"emission_id": emission_id, "generation": generation, "cell": cell, "direction": direction})
		return true

	func show_reflection_step(
			emission_id: int, generation: int, cell: Vector2i,
			incoming_direction: Vector2i, outgoing_direction: Vector2i
	) -> bool:
		reflection_calls.append({
			"emission_id": emission_id, "generation": generation, "cell": cell,
			"incoming": incoming_direction, "outgoing": outgoing_direction})
		return true


## 替身目标记录器：记录 apply_hit 收到的命中格（S3-05 起 driver 经 ObjectiveHitContext→apply_hit；供组 22 断言反射格水晶处理不被影响）。
class FakeObjectiveRecorder:
	extends RefCounted

	var activated_cells: Array = []

	func apply_hit(hit: Variant) -> bool:
		activated_cells.append(hit.get_cell())
		return true


## 四方向映射共用断言：show_step 后片段 _direction 等于传入方向，且该方向映射到预期形态状态。
func _check_mapping(group_name: String, direction: Vector2i, expected_state: StringName) -> void:
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(1, 1, Vector2i(0, 0), direction)
	var views: Array = controller.get_segments_for_emission(1)
	if _check(group_name, views.size() == 1, "片段不应为空。"):
		var view: _LightSegmentViewScript = views[0]
		_check(group_name, view._direction == direction, "_direction 期望 %s，实际 %s。" % [direction, view._direction])
		var state: StringName = _LightSegmentVisualProfile.get_segment_state_for_direction(direction)
		_check(group_name, state == expected_state, "方向 %s 状态期望 %s，实际 %s。" % [direction, expected_state, state])
	(env["parent"] as Node2D).free()


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(group_name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group_name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 22
	var passed_checks: int = _checks - _failures.size()
	print("==== LightVisualController 测试摘要（M4-E2 per-emission）====")
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
