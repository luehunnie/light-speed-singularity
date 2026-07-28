extends SceneTree

## BasicCrystal D4A 定向自动测试：继承 GridPlacedObject 后 position 为唯一位置事实，cell 由 position 派生；
## 激活/重置语义与缺少 VisualView 的生命周期安全边界保持既有契约。
## 覆盖：是 GridPlacedObject；position→cell 派生；set_cell 写 position；get_cell 与 .cell 一致；
##   无第二份持久化 cell；activate/reset_runtime 语义；重复 activate 稳定；缺 VisualView 时未触发 _ready 的路径安全。
## 期望值一律由 GridCoordinateRules 派生，不复制 64×64 公式。由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _BasicCrystal: GDScript = preload(
	"res://gameplay/crystals/basic_crystal.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _VisualViewScene: PackedScene = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.tscn"
)
const _CrystalProfile: Resource = preload(
	"res://assets/visual_profiles/basic_crystal_visuals.tres"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 本轮创建的水晶实例，统一释放避免 --script 模式泄漏。
var _crystals: Array[BasicCrystal] = []


func _initialize() -> void:
	_test_01_is_grid_placed_object()
	_test_02_position_derives_cell()
	_test_03_set_cell_updates_position()
	_test_04_get_cell_matches_cell()
	_test_05_no_second_persistent_cell()
	_test_06_activate_semantics()
	_test_07_reset_runtime_semantics()
	_test_08_repeat_activate_stable()
	_test_09_missing_visual_view_safe_boundary()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. BasicCrystal 是 GridPlacedObject（继承契约）。
func _test_01_is_grid_placed_object() -> void:
	const NAME: String = "01_是GridPlacedObject"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	_check(NAME, crystal is _GridPlacedObject, "BasicCrystal 应为 GridPlacedObject，实际 %s。" % [crystal.get_class()])
	_check(NAME, crystal is Node2D, "BasicCrystal 仍应为 Node2D 子类。")
	crystal.free()


## 2. 设置 position 后 cell 正确派生：cell == world_to_cell(position)。
func _test_02_position_derives_cell() -> void:
	const NAME: String = "02_position派生cell"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	var pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	crystal.position = pos
	_check(NAME, crystal.cell == Vector2i(3, 1), "position=%s 后 cell 期望 (3,1)，实际 %s。" % [pos, crystal.cell])
	crystal.free()


## 3. set_cell() 会更新 position：position == cell_to_world(cell)。
func _test_03_set_cell_updates_position() -> void:
	const NAME: String = "03_set_cell更新position"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.set_cell(Vector2i(5, 2))
	var expected: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(5, 2))
	_check(NAME, crystal.position == expected, "set_cell(5,2) 后 position 期望 %s，实际 %s。" % [expected, crystal.position])
	crystal.free()


## 4. get_cell() 与 .cell 一致（同一 position 下两条读取路径结果相同）。
func _test_04_get_cell_matches_cell() -> void:
	const NAME: String = "04_get_cell与cell一致"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(7, 4))
	_check(NAME, crystal.get_cell() == crystal.cell, "get_cell() %s 应与 .cell %s 一致。" % [crystal.get_cell(), crystal.cell])
	_check(NAME, crystal.get_cell() == Vector2i(7, 4), "get_cell 期望 (7,4)，实际 %s。" % [crystal.get_cell()])
	crystal.free()


## 5. 不存在 BasicCrystal 自己的第二份持久化 cell：set_cell(A) 后直接改 position 到 B 格中心，cell 应为 B 而非 A。
func _test_05_no_second_persistent_cell() -> void:
	const NAME: String = "05_无第二份持久化cell"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.set_cell(Vector2i(3, 1))
	# 源码静态断言：本脚本不再声明独立 cell 字段，cell 全部继承自 GridPlacedObject。
	var src: String = crystal.get_script().get_source_code()
	_check(NAME, src.find("@export var cell") == -1, "BasicCrystal 源码不应再声明 @export var cell。")
	_check(NAME, src.find("var cell:") == -1, "BasicCrystal 源码不应再声明独立 var cell。")
	# 行为断言：直接改 position 后 cell 跟随 position，不残留 set_cell 写入的旧值。
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(8, 6))
	_check(NAME, crystal.cell == Vector2i(8, 6), "改 position 后 cell 期望 (8,6) 不残留 (3,1)，实际 %s。" % [crystal.cell])
	_check(NAME, crystal.get_cell() == Vector2i(8, 6), "get_cell 期望 (8,6)，实际 %s。" % [crystal.get_cell()])
	crystal.free()


## 6. activate() 语义不变：is_activated 置 true，内容状态切到 "lit"。
func _test_06_activate_semantics() -> void:
	const NAME: String = "06_activate语义不变"
	var crystal: _BasicCrystal = _make_crystal_with_visual(Vector2i(3, 1))
	var view: _ObjectVisualView = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, not crystal.is_activated, "初始应未点亮。")
	_check(NAME, view != null and view.get_content_state() == &"unlit", "初始内容状态应为 unlit，实际 %s。" % [view.get_content_state() if view != null else "null"])
	crystal.activate()
	_check(NAME, crystal.is_activated, "activate 后应已点亮。")
	_check(NAME, view != null and view.get_content_state() == &"lit", "activate 后内容状态应为 lit，实际 %s。" % [view.get_content_state() if view != null else "null"])


## 7. reset_runtime() 语义不变：is_activated 归 false，内容状态切回 "unlit"，position/cell 不变。
func _test_07_reset_runtime_semantics() -> void:
	const NAME: String = "07_reset_runtime语义不变"
	var crystal: _BasicCrystal = _make_crystal_with_visual(Vector2i(3, 1))
	var view: _ObjectVisualView = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	crystal.activate()
	var pos_before: Vector2 = crystal.position
	var cell_before: Vector2i = crystal.cell
	crystal.reset_runtime()
	_check(NAME, not crystal.is_activated, "reset 后应未点亮。")
	_check(NAME, view != null and view.get_content_state() == &"unlit", "reset 后内容状态应为 unlit，实际 %s。" % [view.get_content_state() if view != null else "null"])
	_check(NAME, crystal.position == pos_before, "reset 不应改变 position，%s vs %s。" % [crystal.position, pos_before])
	_check(NAME, crystal.cell == cell_before, "reset 不应改变 cell，%s vs %s。" % [crystal.cell, cell_before])


## 8. 重复 activate() 行为保持既有契约：多次调用不破坏状态；reset 后再次 activate 仍点亮。
func _test_08_repeat_activate_stable() -> void:
	const NAME: String = "08_重复activate稳定"
	var crystal: _BasicCrystal = _make_crystal_with_visual(Vector2i(3, 1))
	var view: _ObjectVisualView = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	crystal.activate()
	crystal.activate()
	crystal.activate()
	_check(NAME, crystal.is_activated, "重复 activate 后仍应点亮。")
	_check(NAME, view != null and view.get_content_state() == &"lit", "重复 activate 后内容状态应仍为 lit，实际 %s。" % [view.get_content_state() if view != null else "null"])
	crystal.reset_runtime()
	_check(NAME, not crystal.is_activated, "reset 后应未点亮。")
	crystal.activate()
	_check(NAME, crystal.is_activated, "reset 后再次 activate 应点亮。")
	_check(NAME, view != null and view.get_content_state() == &"lit", "再次 activate 后内容状态应为 lit，实际 %s。" % [view.get_content_state() if view != null else "null"])


## 9. 缺少 VisualView 时生命周期安全边界保持既有行为：未触发 _ready 的路径下 cell/position/is_activated 可查询不崩溃，
##    且脚本未新增 null 守卫吞掉缺 VisualView 的场景配置错误（_ready 仍直接经 @onready _visual 暴露错误）。
func _test_09_missing_visual_view_safe_boundary() -> void:
	const NAME: String = "09_缺VisualView生命周期安全边界"
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	# 未挂 VisualView、未触发 _ready：position/cell/is_activated 可安全查询，与 Registry 测试所依赖的边界一致。
	_check(NAME, crystal.cell == Vector2i(3, 1), "缺 VisualView 时 cell 仍应派生为 (3,1)，实际 %s。" % [crystal.cell])
	_check(NAME, crystal.get_cell() == Vector2i(3, 1), "缺 VisualView 时 get_cell 仍应为 (3,1)，实际 %s。" % [crystal.get_cell()])
	_check(NAME, not crystal.is_activated, "缺 VisualView 时 is_activated 初始应为 false。")
	# 静态断言：_apply_state 仍直接调用 _visual.set_content_state，未新增 null 守卫吞掉缺 VisualView 错误。
	var src: String = crystal.get_script().get_source_code()
	_check(NAME, src.find("_visual.set_content_state") != -1, "_apply_state 应仍直接调用 _visual.set_content_state。")
	_check(NAME, src.find("if _visual == null") == -1 and src.find("if not _visual") == -1, "不应新增 _visual null 守卫吞掉缺 VisualView 的场景配置错误。")
	crystal.free()


# ===== 辅助 =====

## 构造带真实 VisualView 子节点的水晶并手动触发 _ready（--script 不自动触发），用于激活/重置语义测试。
func _make_crystal_with_visual(cell: Vector2i) -> _BasicCrystal:
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.cell = cell
	var view: ObjectVisualView = _VisualViewScene.instantiate()
	view.name = "VisualView"
	view.visual_profile = _CrystalProfile
	view.initial_state_id = &"unlit"
	crystal.add_child(view)
	view._ready()
	crystal._ready()
	_crystals.append(crystal)
	return crystal


## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 释放本轮创建的水晶实例（连带 VisualView 子节点），跳过已释放实例。
func _cleanup() -> void:
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			for child: Node in crystal.get_children():
				child.free()
			crystal.free()
	_crystals.clear()


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== BasicCrystal D4A 测试摘要 ====")
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
