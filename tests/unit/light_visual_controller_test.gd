extends SceneTree

## LightVisualController 定向自动测试（Day 3 D3-B）。
## 覆盖 show_step 创建/多步/cell 传递/四方向映射/非法方向/清理/连续清理/重建/计数/不访问水晶不修改状态/视觉→水晶顺序接线。
## 通过 preload 引用控制器与 LightSegmentView，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 替身策略：每个用例新建一个 Node2D 父节点（不加入场景树），控制器把片段 add_child 到该父节点；
## LightSegmentView 的 @onready 子节点未就绪时 refresh_visual() 安全返回，_direction 字段仍写入，足以断言方向与位置接线。


const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _LightSegmentViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")


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
	_test_09_clear_removes_all()
	_test_10_repeated_clear_safe()
	_test_11_recreate_after_clear()
	_test_12_segment_count()
	_test_13_no_crystal_access()
	_test_14_no_state_mutation()
	_test_15_wiring_visual_before_crystal()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一个独立父节点与控制器，返回 { parent, controller }；父节点不加入场景树，调用方负责 free。
func _make_controller() -> Dictionary:
	var parent: Node2D = Node2D.new()
	var controller: _LightVisualController = _LightVisualController.new(parent)
	return { "parent": parent, "controller": controller }


## 1. show_step 创建一个片段。
func _test_01_show_step_creates_one() -> void:
	const NAME: String = "01_show_step创建一个"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var ok: bool = controller.show_step(Vector2i(2, 3), Vector2i.RIGHT)
	_check(NAME, ok, "show_step 返回期望 true。")
	_check(NAME, controller.get_segment_count() == 1, "片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_segment_at(0) != null, "get_segment_at(0) 不应为 null。")
	(env["parent"] as Node2D).free()


## 2. 多 step 创建多个片段。
func _test_02_multi_step_creates_many() -> void:
	const NAME: String = "02_多step创建多个"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(Vector2i(2, 1), Vector2i.RIGHT)
	controller.show_step(Vector2i(3, 1), Vector2i.UP)
	_check(NAME, controller.get_segment_count() == 3, "片段数期望 3，实际 %d。" % [controller.get_segment_count()])
	(env["parent"] as Node2D).free()


## 3. cell 位置正确传递到片段根节点 position。
func _test_03_cell_position_passed() -> void:
	const NAME: String = "03_cell位置传递"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	var cell: Vector2i = Vector2i(4, 7)
	controller.show_step(cell, Vector2i.DOWN)
	var view: _LightSegmentViewScript = controller.get_segment_at(0)
	if _check(NAME, view != null, "片段不应为 null。"):
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
	var ok: bool = controller.show_step(Vector2i(0, 0), Vector2i.ZERO)
	_check(NAME, ok, "非法方向仍应创建片段并返回 true（旧行为）。")
	_check(NAME, controller.get_segment_count() == 1, "非法方向片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	var view: _LightSegmentViewScript = controller.get_segment_at(0)
	if _check(NAME, view != null, "片段不应为 null。"):
		# 非法方向不映射到任意纹理形态，状态为空。
		_check(NAME, view._direction == Vector2i.ZERO, "_direction 期望 ZERO，实际 %s。" % [view._direction])
		var state: StringName = _LightSegmentVisualProfile.get_segment_state_for_direction(view._direction)
		_check(NAME, state == &"", "非法方向状态期望空，实际 %s。" % [state])
	(env["parent"] as Node2D).free()


## 9. clear_path 清理全部节点。
func _test_09_clear_removes_all() -> void:
	const NAME: String = "09_clear清理全部"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(Vector2i(1, 1), Vector2i.RIGHT)
	controller.show_step(Vector2i(2, 1), Vector2i.RIGHT)
	controller.clear_path()
	_check(NAME, controller.get_segment_count() == 0, "清理后片段数期望 0，实际 %d。" % [controller.get_segment_count()])
	_check(NAME, controller.get_segment_at(0) == null, "清理后 get_segment_at(0) 应为 null。")
	(env["parent"] as Node2D).free()


## 10. 连续 clear 安全（无子节点时空遍历不报错）。
func _test_10_repeated_clear_safe() -> void:
	const NAME: String = "10_连续clear安全"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(Vector2i(1, 1), Vector2i.RIGHT)
	controller.clear_path()
	controller.clear_path()
	controller.clear_path()
	_check(NAME, controller.get_segment_count() == 0, "连续清理后片段数期望 0，实际 %d。" % [controller.get_segment_count()])
	(env["parent"] as Node2D).free()


## 11. clear 后可重新创建。
func _test_11_recreate_after_clear() -> void:
	const NAME: String = "11_clear后可重建"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(Vector2i(1, 1), Vector2i.RIGHT)
	controller.clear_path()
	var ok: bool = controller.show_step(Vector2i(5, 5), Vector2i.UP)
	_check(NAME, ok, "清理后再次 show_step 应成功。")
	_check(NAME, controller.get_segment_count() == 1, "重建后片段数期望 1，实际 %d。" % [controller.get_segment_count()])
	var view: _LightSegmentViewScript = controller.get_segment_at(0)
	if _check(NAME, view != null, "重建片段不应为 null。"):
		_check(NAME, view._direction == Vector2i.UP, "重建片段方向期望 UP，实际 %s。" % [view._direction])
	(env["parent"] as Node2D).free()


## 12. get_segment_count 正确（初始/递增/清理后归零）。
func _test_12_segment_count() -> void:
	const NAME: String = "12_get_segment_count正确"
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	_check(NAME, controller.get_segment_count() == 0, "初始片段数期望 0。")
	controller.show_step(Vector2i(0, 0), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 1, "1 步后期望 1，实际 %d。" % [controller.get_segment_count()])
	controller.show_step(Vector2i(1, 0), Vector2i.RIGHT)
	_check(NAME, controller.get_segment_count() == 2, "2 步后期望 2，实际 %d。" % [controller.get_segment_count()])
	controller.clear_path()
	_check(NAME, controller.get_segment_count() == 0, "清理后期望 0，实际 %d。" % [controller.get_segment_count()])
	(env["parent"] as Node2D).free()


## 13. 不访问水晶：控制器源码不应引用水晶或激活等视觉无关职责（静态接线检查）。
func _test_13_no_crystal_access() -> void:
	const NAME: String = "13_不访问水晶"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/light_visual_controller.gd")
	var forbidden: Array = ["activate", "crystal", "Crystal", "BasicCrystal", "try_activate_crystal", "all_required_crystals"]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "控制器源码不应包含视觉无关令牌：%s" % [token])


## 14. 不修改状态：控制器源码不应引用运行状态/脉冲版本/完成/库存/放置/拖拽/计时器等事实（静态接线检查）。
func _test_14_no_state_mutation() -> void:
	const NAME: String = "14_不修改状态"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/light_visual_controller.gd")
	var forbidden: Array = [
		"_run_state_controller", "pulse_generation", "is_level_completed",
		"begin_pulse", "finish_pulse", "reset_to_setup", "create_timer",
		"_inventory_controller", "_placement_controller", "_drag_flow_controller",
		"RunState", "RayExecutionModule", "RayExecutionResult"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "控制器源码不应包含状态/传播相关令牌：%s" % [token])


## 15. 应用结果仍保持视觉→水晶顺序（D3-E：_apply_ray_execution_result 迁入 LevelRuntimeController，检查其源码中 show_step 早于 try_activate_crystal_at，且无第二套视觉创建实现）。
func _test_15_wiring_visual_before_crystal() -> void:
	const NAME: String = "15_视觉→水晶顺序接线"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var crystal_idx: int = body.find("try_activate_crystal_at")
		_check(NAME, show_idx != -1, "_apply_ray_execution_result 应调用 _light_visual_controller.show_step。")
		_check(NAME, crystal_idx != -1, "_apply_ray_execution_result 应调用 try_activate_crystal_at。")
		_check(NAME, show_idx < crystal_idx, "视觉创建必须在水晶激活之前（show_step @ %d < try_activate @ %d）。" % [show_idx, crystal_idx])
		# 不得保留第二套视觉创建实现。
		_check(NAME, body.find("add_light_visual") == -1, "不得在 _apply_ray_execution_result 保留 add_light_visual 第二套实现。")


## 四方向映射共用断言：show_step 后片段 _direction 等于传入方向，且该方向映射到预期形态状态。
func _check_mapping(group_name: String, direction: Vector2i, expected_state: StringName) -> void:
	var env: Dictionary = _make_controller()
	var controller: _LightVisualController = env["controller"]
	controller.show_step(Vector2i(0, 0), direction)
	var view: _LightSegmentViewScript = controller.get_segment_at(0)
	if _check(group_name, view != null, "片段不应为 null。"):
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
	var group_count: int = 15
	var passed_checks: int = _checks - _failures.size()
	print("==== LightVisualController D3-B 测试摘要 ====")
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
