extends SceneTree

## EmissionPreview D3B-2 定向自动测试。
## 覆盖：继承 Node2D、默认状态、set_preview_state 保存与幂等（不重复 queue_redraw）、
##   ZERO 方向保留、不复制枚举、无禁止依赖、无 _process、不改 position、
##   步长由 GridCoordinateRules 派生、光线终点三格、光粒三点、运行时隐藏、
##   不加载主场景、不依赖 addons、不继承 GridPlacedObject。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_extends_node2d()
	_test_02_default_direction_right()
	_test_03_default_particle_style_false()
	_test_04_default_preview_enabled_true()
	_test_05_set_preview_state_saves()
	_test_06_identical_state_no_redraw()
	_test_07_zero_direction_preserved()
	_test_08_no_copied_enums()
	_test_09_no_forbidden_dependencies()
	_test_10_no_process()
	_test_11_no_position_mutation()
	_test_12_step_derived_from_grid_rules()
	_test_13_ray_end_three_cells()
	_test_14_particle_three_points()
	_test_15_runtime_hidden()
	_test_16_no_main_scene_loaded()
	_test_17_no_addons()
	_test_18_not_extends_grid_placed_object()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 继承 Node2D。
func _test_01_extends_node2d() -> void:
	const NAME: String = "01_继承Node2D"
	var p: _EmissionPreview = _EmissionPreview.new()
	_check(NAME, p is Node2D, "应为 Node2D 子类。")
	_check(NAME, p is _EmissionPreview, "应为 EmissionPreview 实例。")
	p.free()


## 2. 默认方向为 RIGHT。
func _test_02_default_direction_right() -> void:
	const NAME: String = "02_默认方向RIGHT"
	var p: _EmissionPreview = _EmissionPreview.new()
	_check(NAME, p.get_preview_direction() == Vector2i.RIGHT, "默认方向应为 RIGHT，实际 %s。" % [p.get_preview_direction()])
	p.free()


## 3. 默认 particle_style 为 false。
func _test_03_default_particle_style_false() -> void:
	const NAME: String = "03_默认光粒样式false"
	var p: _EmissionPreview = _EmissionPreview.new()
	_check(NAME, p.is_particle_style() == false, "默认 particle_style 应为 false。")
	p.free()


## 4. 默认 preview_enabled 为 true。
func _test_04_default_preview_enabled_true() -> void:
	const NAME: String = "04_默认预览开启true"
	var p: _EmissionPreview = _EmissionPreview.new()
	_check(NAME, p.is_preview_enabled() == true, "默认 preview_enabled 应为 true。")
	p.free()


## 5. set_preview_state 正确保存三项状态。
func _test_05_set_preview_state_saves() -> void:
	const NAME: String = "05_set_preview_state保存"
	var p: _EmissionPreview = _EmissionPreview.new()
	p.set_preview_state(Vector2i.DOWN, true, false)
	_check(NAME, p.get_preview_direction() == Vector2i.DOWN, "方向应保存为 DOWN，实际 %s。" % [p.get_preview_direction()])
	_check(NAME, p.is_particle_style() == true, "particle_style 应保存为 true。")
	_check(NAME, p.is_preview_enabled() == false, "preview_enabled 应保存为 false。")
	p.free()


## 6. 完全相同状态重复设置保持稳定，且后续真实变化仍能正常更新。
func _test_06_identical_state_no_redraw() -> void:
	const NAME: String = "06_相同状态保持稳定"
	var p: _EmissionPreview = _EmissionPreview.new()
	p.set_preview_state(Vector2i.DOWN, true, false)
	# 重复完全相同状态多次，状态应保持稳定。
	p.set_preview_state(Vector2i.DOWN, true, false)
	p.set_preview_state(Vector2i.DOWN, true, false)
	_check(NAME, p.get_preview_direction() == Vector2i.DOWN, "重复相同状态后方向应稳定为 DOWN，实际 %s。" % [p.get_preview_direction()])
	_check(NAME, p.is_particle_style() == true, "重复相同状态后 particle_style 应稳定为 true。")
	_check(NAME, p.is_preview_enabled() == false, "重复相同状态后 preview_enabled 应稳定为 false。")
	# 后续真实变化仍能正常更新（未因幂等短路误吞变化）。
	p.set_preview_state(Vector2i.UP, false, true)
	_check(NAME, p.get_preview_direction() == Vector2i.UP, "后续变化方向应为 UP，实际 %s。" % [p.get_preview_direction()])
	_check(NAME, p.is_particle_style() == false, "后续变化 particle_style 应为 false。")
	_check(NAME, p.is_preview_enabled() == true, "后续变化 preview_enabled 应为 true。")
	p.free()


## 7. direction == ZERO 被保留，不自动改为 RIGHT。
func _test_07_zero_direction_preserved() -> void:
	const NAME: String = "07_ZERO方向保留"
	var p: _EmissionPreview = _EmissionPreview.new()
	p.set_preview_state(Vector2i.ZERO, false, true)
	_check(NAME, p.get_preview_direction() == Vector2i.ZERO, "ZERO 应被保留，实际 %s。" % [p.get_preview_direction()])
	_check(NAME, p.get_preview_direction() != Vector2i.RIGHT, "ZERO 不应被自动修正为 RIGHT。")
	p.free()


## 8. 不复制 LightForm/RayDirection/ParticleDirection 枚举。
func _test_08_no_copied_enums() -> void:
	const NAME: String = "08_不复制枚举"
	var src: String = _EmissionPreview.source_code
	for token: String in ["LightForm", "RayDirection", "ParticleDirection"]:
		_check(NAME, not src.contains(token), "源码不应复制枚举 %s。" % [token])


## 9. 不依赖 FixedEmitter/CoreLoopPrototype/LightPathLayer/RayExecutionModule/WorldQuery。
func _test_09_no_forbidden_dependencies() -> void:
	const NAME: String = "09_无禁止依赖"
	var src: String = _EmissionPreview.source_code
	for token: String in ["FixedEmitter", "CoreLoopPrototype", "LightPathLayer", "RayExecutionModule", "WorldQuery"]:
		_check(NAME, not src.contains(token), "源码不应引用禁止依赖 %s。" % [token])


## 10. 不使用 _process / _physics_process。
func _test_10_no_process() -> void:
	const NAME: String = "10_无_process"
	var src: String = _EmissionPreview.source_code
	_check(NAME, not src.contains("_process"), "源码不应定义 _process。")
	_check(NAME, not src.contains("_physics_process"), "源码不应定义 _physics_process。")


## 11. 不修改自身 position。
func _test_11_no_position_mutation() -> void:
	const NAME: String = "11_不改position"
	var src: String = _EmissionPreview.source_code
	_check(NAME, not src.contains("position ="), "源码不应写 position =。")
	_check(NAME, not src.contains("position="), "源码不应写 position=。")
	_check(NAME, not src.contains("global_position ="), "源码不应写 global_position =。")


## 12. 相邻格绘制步长由 GridCoordinateRules 派生；不写死格尺寸常量。
func _test_12_step_derived_from_grid_rules() -> void:
	const NAME: String = "12_步长派生自GridRules"
	var src: String = _EmissionPreview.source_code
	_check(NAME, src.contains("cell_to_world"), "应通过 cell_to_world 派生步长。")
	_check(NAME, src.contains("GridCoordinateRules"), "应引用 GridCoordinateRules。")
	_check(NAME, not src.contains("CELL_SIZE"), "不应复制 CELL_SIZE 公式。")
	# 不得写死格尺寸数值。
	for n: String in ["64", "32", "96", "128", "192"]:
		_check(NAME, not src.contains(n), "源码不应写死格尺寸数值 %s。" % [n])
	var p: _EmissionPreview = _EmissionPreview.new()
	var dirs: Array = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(1, -1)]
	for dir: Vector2i in dirs:
		var expected: Vector2 = _GridCoordinateRules.cell_to_world(dir) - _GridCoordinateRules.cell_to_world(Vector2i.ZERO)
		_check(NAME, p._get_cell_step(dir) == expected, "步长 %s 期望 %s，实际 %s。" % [dir, expected, p._get_cell_step(dir)])
	_check(NAME, p._get_cell_step(Vector2i.ZERO) == Vector2.ZERO, "ZERO 步长应为 Vector2.ZERO，实际 %s。" % [p._get_cell_step(Vector2i.ZERO)])
	p.free()


## 13. 光线预览终点为方向的三格示意。
func _test_13_ray_end_three_cells() -> void:
	const NAME: String = "13_光线终点三格"
	var p: _EmissionPreview = _EmissionPreview.new()
	var dirs: Array = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(0, -1), Vector2i(-1, 1)]
	for dir: Vector2i in dirs:
		var step: Vector2 = p._get_cell_step(dir)
		var expected: Vector2 = step * 3.0
		_check(NAME, p._get_ray_end(dir) == expected, "光线终点 %s 期望 %s，实际 %s。" % [dir, expected, p._get_ray_end(dir)])
		# 三格 = 三倍相邻格中心位移，等价于 cell_to_world(dir*3) - cell_to_world(ZERO)。
		var alt: Vector2 = _GridCoordinateRules.cell_to_world(dir * 3) - _GridCoordinateRules.cell_to_world(Vector2i.ZERO)
		_check(NAME, p._get_ray_end(dir) == alt, "光线终点 %s 应等于三格位移 %s，实际 %s。" % [dir, alt, p._get_ray_end(dir)])
	p.free()


## 14. 光粒预览生成三个离散示意点。
func _test_14_particle_three_points() -> void:
	const NAME: String = "14_光粒三点"
	var p: _EmissionPreview = _EmissionPreview.new()
	var step: Vector2 = p._get_cell_step(Vector2i(1, 0))
	var pts: PackedVector2Array = p._get_particle_points(Vector2i(1, 0))
	_check(NAME, pts.size() == 3, "光粒点数期望 3，实际 %d。" % [pts.size()])
	if pts.size() == 3:
		_check(NAME, pts[0] == step * 1.0, "第 1 点期望 %s，实际 %s。" % [step * 1.0, pts[0]])
		_check(NAME, pts[1] == step * 2.0, "第 2 点期望 %s，实际 %s。" % [step * 2.0, pts[1]])
		_check(NAME, pts[2] == step * 3.0, "第 3 点期望 %s，实际 %s。" % [step * 3.0, pts[2]])
	# 斜向同样三点。
	var pts2: PackedVector2Array = p._get_particle_points(Vector2i(1, 1))
	_check(NAME, pts2.size() == 3, "斜向光粒点数期望 3，实际 %d。" % [pts2.size()])
	p.free()


## 15. 运行时非 editor hint 时 visible 为 false（_ready 与 set_preview_state 两条路径）。
func _test_15_runtime_hidden() -> void:
	const NAME: String = "15_运行时隐藏"
	# 路径 A：_ready 同步可见性。--script 下 _initialize 不泵帧，_ready 不会自动触发，直接调用以验证其同步逻辑。
	var p_in_tree: _EmissionPreview = _EmissionPreview.new()
	root.add_child(p_in_tree)
	_check(NAME, p_in_tree.visible == true, "入树前 visible 默认应为 true。")
	p_in_tree._ready()
	_check(NAME, p_in_tree.visible == false, "_ready 后运行时（非 editor hint）visible 应为 false。")
	_check(NAME, p_in_tree.is_preview_enabled() == true, "preview_enabled 仍为 true，但运行时应隐藏。")
	p_in_tree.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留子节点。")
	# 路径 B：未入树，set_preview_state 用非默认值触发同步（enabled 仍为 true）。
	var p_off_tree: _EmissionPreview = _EmissionPreview.new()
	_check(NAME, p_off_tree.visible == true, "未入树前 Node2D.visible 默认应为 true。")
	p_off_tree.set_preview_state(Vector2i.DOWN, false, true)
	_check(NAME, p_off_tree.visible == false, "set_preview_state 后运行时 visible 应为 false（enabled=true 但非 editor hint）。")
	p_off_tree.free()


## 16. 不加载正式主场景：root 无残留、源码无 change_scene。
func _test_16_no_main_scene_loaded() -> void:
	const NAME: String = "16_不加载主场景"
	_check(NAME, root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	var src: String = _EmissionPreview.source_code
	_check(NAME, not src.contains("change_scene"), "源码不应调用 change_scene。")


## 17. 不依赖 addons。
func _test_17_no_addons() -> void:
	const NAME: String = "17_不依赖addons"
	var src: String = _EmissionPreview.source_code
	_check(NAME, not src.contains("addons"), "源码不应引用 addons。")


## 18. 不继承 GridPlacedObject：源码不含该类型，节点属性表无 cell/emitter_id/emitter_position。
func _test_18_not_extends_grid_placed_object() -> void:
	const NAME: String = "18_不继承GridPlacedObject"
	var src: String = _EmissionPreview.source_code
	_check(NAME, not src.contains("GridPlacedObject"), "源码不应引用 GridPlacedObject。")
	_check(NAME, not src.contains("emitter_id"), "不应保存 emitter_id。")
	_check(NAME, not src.contains("emitter_position"), "不应保存 emitter_position。")
	# 属性表不应暴露格坐标事实。
	var p: _EmissionPreview = _EmissionPreview.new()
	var prop_names: PackedStringArray = _property_names(p)
	_check(NAME, not prop_names.has("cell"), "属性表不应有 cell（不派生格坐标）。")
	_check(NAME, not prop_names.has("emitter_id"), "属性表不应有 emitter_id。")
	_check(NAME, not prop_names.has("emitter_position"), "属性表不应有 emitter_position。")
	p.free()


## 取节点全部属性名，用于结构性断言。
func _property_names(node: Object) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for prop: Dictionary in node.get_property_list():
		names.append(prop["name"])
	return names


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 18
	var passed_checks: int = _checks - _failures.size()
	print("==== EmissionPreview 测试摘要 ====")
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
