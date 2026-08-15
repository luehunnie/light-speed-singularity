extends SceneTree

## ParticleView 单元测试（D7-4 B4a）。
## 覆盖主体逻辑尺寸 24×16、本地默认 RIGHT rotation=0、八方向 rotation、set_cell 使用正式 cell_to_world、
##   View 不拥有 gameplay cell/speed truth（无 cell/speed 成员/getter）。
## 通过 preload 引用 ParticleView 场景与 GridCoordinateRules，避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ParticleViewScene: PackedScene = preload("res://gameplay/visuals/particles/particle_view.tscn")
const _ParticleViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前等待一帧，确保 SceneTree 就绪。
	await process_frame
	_test_01_body_logical_size_24x16()
	_test_02_right_rotation_zero()
	_test_03_eight_directions_rotation()
	_test_04_set_cell_uses_cell_to_world()
	_test_05_view_does_not_own_cell_or_speed_truth()
	_test_06_position_change_does_not_persist_cell_truth()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 实例化一个 ParticleView（不加入场景树；set_cell/set_direction 不依赖树）。
func _make_view() -> _ParticleViewScript:
	return _ParticleViewScene.instantiate()


# ===== 测试用例 =====

## 1.（spec 17）主体逻辑尺寸 24×16：consts == 24/16、get_body_size()==Vector2(24,16)、Body ColorRect 偏移实现 24×16。
func _test_01_body_logical_size_24x16() -> void:
	const NAME: String = "01_主体逻辑尺寸24x16"
	var view: _ParticleViewScript = _make_view()
	_check(NAME, _ParticleViewScript.BODY_LENGTH == 24, "BODY_LENGTH 期望 24，实际 %d。" % [_ParticleViewScript.BODY_LENGTH])
	_check(NAME, _ParticleViewScript.BODY_WIDTH == 16, "BODY_WIDTH 期望 16，实际 %d。" % [_ParticleViewScript.BODY_WIDTH])
	_check(NAME, view.get_body_size() == Vector2(24, 16), "get_body_size 期望 (24,16)，实际 %s。" % [view.get_body_size()])
	# Body ColorRect 偏移实现的尺寸须与逻辑常量一致（保证 .tscn 视觉与逻辑真值对齐）。
	var body: ColorRect = view.get_node_or_null("Body")
	if _check(NAME, body != null, "Body ColorRect 子节点应存在。"):
		var width: float = body.offset_right - body.offset_left
		var height: float = body.offset_bottom - body.offset_top
		_check(NAME, width == 24.0, "Body 宽度期望 24（offset_right-left），实际 %f。" % [width])
		_check(NAME, height == 16.0, "Body 高度期望 16（offset_bottom-top），实际 %f。" % [height])
	view.free()


## 2.（spec 18）RIGHT rotation=0：set_direction(RIGHT) 后 rotation==0。
func _test_02_right_rotation_zero() -> void:
	const NAME: String = "02_RIGHT_rotation为0"
	var view: _ParticleViewScript = _make_view()
	view.set_direction(Vector2i.RIGHT)
	_check(NAME, is_zero_approx(view.rotation), "RIGHT rotation 期望 0，实际 %f。" % [view.rotation])
	view.free()


## 3.（spec 19）八方向 rotation 正确：每个合法八方向 set_direction 后 rotation == Vector2(direction).angle()。
func _test_03_eight_directions_rotation() -> void:
	const NAME: String = "03_八方向rotation正确"
	var view: _ParticleViewScript = _make_view()
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	]
	for d: Vector2i in dirs:
		view.set_direction(d)
		var expected: float = Vector2(d).angle()
		_check(NAME, is_equal_approx(view.rotation, expected), "方向 %s rotation 期望 %f，实际 %f。" % [d, expected, view.rotation])
	view.free()


## 4.（spec 20）set_cell 使用正式 cell_to_world：set_cell(cell) 后 position == GridCoordinateRules.cell_to_world(cell)。
func _test_04_set_cell_uses_cell_to_world() -> void:
	const NAME: String = "04_set_cell使用正式cell_to_world"
	var view: _ParticleViewScript = _make_view()
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(3, 5), Vector2i(1, 3), Vector2i(14, 7)]
	for c: Vector2i in cells:
		view.set_cell(c)
		var expected: Vector2 = _GridCoordinateRules.cell_to_world(c)
		_check(NAME, view.position.is_equal_approx(expected), "cell %s position 期望 %s，实际 %s。" % [c, expected, view.position])
	# 初始位置（emitter cell 中心）场景验证：configure(emitter_cell, RIGHT) 后位置 = cell_to_world(emitter_cell)。
	view.configure(Vector2i(2, 3), Vector2i.RIGHT)
	_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(2, 3))), "configure 后初始位置应 = cell_to_world((2,3))。")
	view.free()


## 5.（spec 22）View 不拥有 gameplay cell/speed truth：无 get_cell/get_speed_tier 方法，无 cell/speed_tier 属性。
func _test_05_view_does_not_own_cell_or_speed_truth() -> void:
	const NAME: String = "05_View不拥有cell或speed真值"
	var view: _ParticleViewScript = _make_view()
	_check(NAME, not view.has_method("get_cell"), "View 不应暴露 get_cell（不持 cell truth）。")
	_check(NAME, not view.has_method("get_speed_tier"), "View 不应暴露 get_speed_tier（不持 speed truth）。")
	_check(NAME, not view.has_method("get_direction"), "View 不应暴露 get_direction（不持 direction truth，仅写 rotation）。")
	# 无 cell / speed_tier / direction 属性（property 列表不含这些 gameplay 字段）。
	var props: Array = view.get_property_list()
	var prop_names: Array = []
	for p: Dictionary in props:
		prop_names.append(p["name"])
	_check(NAME, not ("cell" in prop_names), "View 不应含 cell 属性。")
	_check(NAME, not ("speed_tier" in prop_names), "View 不应含 speed_tier 属性。")
	_check(NAME, not ("_cell" in prop_names), "View 不应含 _cell 私有成员。")
	view.free()


## 6.（spec 22 延伸）View 位置变化不反向持久化为 cell truth：set_cell 后改 position，再 set_cell 仍按新 cell 正确定位。
func _test_06_position_change_does_not_persist_cell_truth() -> void:
	const NAME: String = "06_position变化不持久化cell真值"
	var view: _ParticleViewScript = _make_view()
	view.set_cell(Vector2i(2, 3))
	# 外部篡改 position（模拟视觉漂移）；View 不据此更新任何 cell truth。
	view.position = Vector2(9999, 9999)
	# 再次 set_cell 按 cell 正确定位（证明 position 是可写视觉副本，不缓存 cell）。
	view.set_cell(Vector2i(5, 1))
	_check(NAME, view.position.is_equal_approx(_GridCoordinateRules.cell_to_world(Vector2i(5, 1))), "set_cell(5,1) 后 position 期望 cell_to_world((5,1))，实际 %s。" % [view.position])
	view.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleView 单元测试摘要（D7-4 B4a）====")
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
