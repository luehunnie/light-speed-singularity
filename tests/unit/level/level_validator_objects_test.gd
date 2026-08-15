extends SceneTree

## LevelValidator 固定对象规则定向测试（D6-B）。
## 用纯内存 fixture（程序化最小 TileSet + 未入树 TileMapLayer + 真实 EmitterConfigNode / BasicCrystal /
##   ObjectVisualView / ObjectVisualProfile 实例，全部 .new() 构造、不入树、不读写 .tscn / .tres）固化
##   LevelFixedObjectValidator 的固定对象共同规则、Emitter 规则、Crystal 规则与 object_id 行为。
## 覆盖 20 项冻结用例：合法单 Emitter + 单 Crystal、Emitter 数量、错路径 / 非直属、PARTICLE 已支持（B3b-1 起）、
##   RAY 八方向、position 偏移合法 / 越界、非有限、Terrain 外、Wall 上、Emitter-Crystal 同格、无 Crystal、
##   空 / 重复 crystal_id、两 Crystal 不同 ID、改名不改 object_id、缺 VisualView、Profile 缺失仅 WARNING
##   （Crystal 与 Emitter）、连续 validate 一致且不改场景。
## headless extends SceneTree，由 Godot --script 运行；preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；fixture 不入 SceneTree，各用例受控 free，不保存任何资源。
##
## 关于 emitter_light_form_invalid / emitter_direction_invalid / emitter_runtime_form_unsupported：均为防御性校验。
## 真实 EmitterConfigNode 的 setter 对非法枚举值执行 push_error 并保持旧值（_set_default_light_form /
##   _set_ray_default_direction / _set_particle_default_direction），因此通过正式 API 无法把非法枚举持久化到
##   节点上。本测试按真实 API 可构造性设计：对八光线方向与八光粒方向做正向覆盖（全部被 setter 接受、校验器不报
##   emitter_direction_invalid）；不通过伪造不可能持久化的非法赋值（如 =99）制造假覆盖。
## B3b-1 起 RAY / PARTICLE 均接正式 Runtime（is_runtime_form_supported 对二者均 true），故 emitter_runtime_form_unsupported
##   对当前两种形态均不可达；该校验委派正式能力来源、不在 Validator 内硬编码白名单，仅在未来引入第三种未接形态时触发（前向兼容守卫）。
## 故 emitter_light_form_invalid / emitter_direction_invalid / emitter_runtime_form_unsupported 无失败 fixture，属预期且合规。

const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")
const _ObjectVisualProfile: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_profile.gd")

const _GROUP_COUNT: int = 20

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 20 组后统一报告并退出。
func _initialize() -> void:
	_test_01_valid_single_emitter_and_crystal()
	_test_02_emitter_count_zero_and_two()
	_test_03_emitter_wrong_path_and_nondirect()
	_test_04_particle_supported()
	_test_05_ray_eight_directions()
	_test_06_position_offset_legal()
	_test_07_position_offset_off_grid()
	_test_08_position_non_finite()
	_test_09_object_outside_terrain()
	_test_10_object_on_wall()
	_test_11_emitter_crystal_overlap()
	_test_12_no_crystal()
	_test_13_empty_crystal_id()
	_test_14_two_crystals_duplicate_id()
	_test_15_two_crystals_distinct_ids()
	_test_16_rename_node_object_id_stable()
	_test_17_crystal_missing_visualview()
	_test_18_crystal_profile_missing_warning()
	_test_19_emitter_profile_missing_warning()
	_test_20_twice_consistent()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 用例 =====

## 1. 合法单 Emitter（RAY + Profile）+ 单 Crystal（crystal_id + VisualView + Profile）：0 issue。
func _test_01_valid_single_emitter_and_crystal() -> void:
	const G: String = "01_合法单Emitter单Crystal"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(2, 2), &"crystal_001")
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "合法固定对象期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "合法固定对象期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, result.get_warning_count() == 0, "合法固定对象期望 0 WARNING，实际 %d。" % result.get_warning_count())
	root.free()


## 2. Emitter 0 个 / 2 个 → emitter_count_invalid。
func _test_02_emitter_count_zero_and_two() -> void:
	const G: String = "02_Emitter数量"
	# 0 个 Emitter。
	var root0: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_crystal(root0, Vector2i(0, 0), &"c1")
	var r0: _LevelValidationResult = _validate(root0)
	_check(G, r0.is_valid() == false, "0 Emitter 期望 is_valid=false。")
	_check(G, _has_code(r0, "emitter_count_invalid"), "0 Emitter 期望 emitter_count_invalid。")
	root0.free()
	# 2 个 Emitter（不同格，避免 overlap 噪声）。
	var root2: Node2D = _make_level(_cells_3x3(), [])
	var e1: _EmitterConfigNode = _add_valid_emitter(root2, Vector2i(0, 0))
	e1.name = &"EmitterA"
	var e2: _EmitterConfigNode = _add_valid_emitter(root2, Vector2i(2, 0))
	e2.name = &"EmitterB"
	_add_valid_crystal(root2, Vector2i(2, 2), &"c1")
	var r2: _LevelValidationResult = _validate(root2)
	_check(G, r2.is_valid() == false, "2 Emitter 期望 is_valid=false。")
	_check(G, _has_code(r2, "emitter_count_invalid"), "2 Emitter 期望 emitter_count_invalid。")
	_check(G, not _has_code(r2, "fixed_object_overlap"), "两 Emitter 不同格不应报 fixed_object_overlap。")
	root2.free()


## 3. Emitter 错路径（直属 RuntimeObjects 但名错）/ 非直属（嵌套 RuntimeObjects/Holder 下）。
func _test_03_emitter_wrong_path_and_nondirect() -> void:
	const G: String = "03_Emitter错路径与非直属"
	# 错路径：直属 RuntimeObjects 但名不是 Emitter。
	var rootA: Node2D = _make_level(_cells_3x3(), [])
	var eA: _EmitterConfigNode = _new_emitter(Vector2i(0, 0), _new_profile())
	eA.name = &"WrongName"
	rootA.get_node(^"RuntimeObjects").add_child(eA)
	_add_valid_crystal(rootA, Vector2i(2, 2), &"c1")
	var rA: _LevelValidationResult = _validate(rootA)
	_check(G, _has_code(rA, "emitter_path_invalid"), "错名 Emitter 期望 emitter_path_invalid。")
	_check(G, not _has_code(rA, "fixed_object_parent_invalid"), "直属 RuntimeObjects 的 Emitter 不应报 fixed_object_parent_invalid。")
	rootA.free()
	# 非直属：嵌套于 RuntimeObjects/Holder 下。
	var rootB: Node2D = _make_level(_cells_3x3(), [])
	var holder: Node2D = Node2D.new()
	holder.name = &"Holder"
	rootB.get_node(^"RuntimeObjects").add_child(holder)
	var eB: _EmitterConfigNode = _new_emitter(Vector2i(0, 0), _new_profile())
	holder.add_child(eB)
	_add_valid_crystal(rootB, Vector2i(2, 2), &"c1")
	var rB: _LevelValidationResult = _validate(rootB)
	_check(G, _has_code(rB, "emitter_path_invalid"), "嵌套 Emitter 期望 emitter_path_invalid。")
	_check(G, _has_code(rB, "fixed_object_parent_invalid"), "嵌套 Emitter 期望 fixed_object_parent_invalid。")
	rootB.free()


## 4. 默认 PARTICLE 已接 Runtime（B3b-1 起）：八光粒方向均合法、被运行时支持、整体合法；不再报 emitter_runtime_form_unsupported。
func _test_04_particle_supported() -> void:
	const G: String = "04_PARTICLE已支持"
	var root: Node2D = _make_level(_cells_3x3(), [])
	var e: _EmitterConfigNode = _add_valid_emitter(root, Vector2i(0, 0))
	e.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var dirs: Array = [
		_EmitterConfigNode.ParticleDirection.RIGHT,
		_EmitterConfigNode.ParticleDirection.DOWN_RIGHT,
		_EmitterConfigNode.ParticleDirection.DOWN,
		_EmitterConfigNode.ParticleDirection.DOWN_LEFT,
		_EmitterConfigNode.ParticleDirection.LEFT,
		_EmitterConfigNode.ParticleDirection.UP_LEFT,
		_EmitterConfigNode.ParticleDirection.UP,
		_EmitterConfigNode.ParticleDirection.UP_RIGHT,
	]
	for d: int in dirs:
		e.particle_default_direction = d
		var result: _LevelValidationResult = _validate(root)
		_check(G, not _has_code(result, "emitter_runtime_form_unsupported"), "PARTICLE 已接 Runtime，不应报 emitter_runtime_form_unsupported（dir=%d）。" % d)
		_check(G, not _has_code(result, "emitter_direction_invalid"), "PARTICLE 合法八方向不应报 emitter_direction_invalid（dir=%d）。" % d)
		_check(G, not _has_code(result, "emitter_light_form_invalid"), "PARTICLE 为合法枚举不应报 emitter_light_form_invalid（dir=%d）。" % d)
		_check(G, result.is_valid() == true, "PARTICLE 合法配置整体应合法（dir=%d）。" % d)
	root.free()


## 5. 合法 RAY 八方向：均不报方向错误、均被运行时支持。
func _test_05_ray_eight_directions() -> void:
	const G: String = "05_Ray八方向"
	var root: Node2D = _make_level(_cells_3x3(), [])
	var e: _EmitterConfigNode = _add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var dirs: Array = [
		_EmitterConfigNode.RayDirection.RIGHT,
		_EmitterConfigNode.RayDirection.DOWN_RIGHT,
		_EmitterConfigNode.RayDirection.DOWN,
		_EmitterConfigNode.RayDirection.DOWN_LEFT,
		_EmitterConfigNode.RayDirection.LEFT,
		_EmitterConfigNode.RayDirection.UP_LEFT,
		_EmitterConfigNode.RayDirection.UP,
		_EmitterConfigNode.RayDirection.UP_RIGHT,
	]
	for d: int in dirs:
		e.ray_default_direction = d
		var result: _LevelValidationResult = _validate(root)
		_check(G, not _has_code(result, "emitter_direction_invalid"), "RAY 合法八方向不应报 emitter_direction_invalid（dir=%d）。" % d)
		_check(G, not _has_code(result, "emitter_runtime_form_unsupported"), "RAY 应被运行时支持（dir=%d）。" % d)
		_check(G, not _has_code(result, "emitter_light_form_invalid"), "RAY 为合法枚举不应报 emitter_light_form_invalid（dir=%d）。" % d)
		_check(G, result.is_valid() == true, "RAY 任一合法方向整体应合法（dir=%d）。" % d)
	root.free()


## 6. position 偏移 0.0005 px 合法（容差内）。
func _test_06_position_offset_legal() -> void:
	const G: String = "06_偏移0.0005合法"
	var root: Node2D = _make_level(_cells_3x3(), [])
	var e: _EmitterConfigNode = _add_valid_emitter(root, Vector2i(0, 0))
	e.position = _cell_center(Vector2i(0, 0)) + Vector2(0.0005, 0.0005)
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, not _has_code(result, "fixed_object_position_off_grid"), "偏移 0.0005 px 不应报 fixed_object_position_off_grid。")
	_check(G, result.is_valid() == true, "偏移 0.0005 px 期望 is_valid=true。")
	root.free()


## 7. position 偏移 0.0011 px → fixed_object_position_off_grid（cell 级）。
func _test_07_position_offset_off_grid() -> void:
	const G: String = "07_偏移0.0011越界"
	var root: Node2D = _make_level(_cells_3x3(), [])
	var e: _EmitterConfigNode = _add_valid_emitter(root, Vector2i(0, 0))
	e.position = _cell_center(Vector2i(0, 0)) + Vector2(0.0011, 0.0)
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_cell_issue(result, "fixed_object_position_off_grid", Vector2i(0, 0)), "偏移 0.0011 px 期望 fixed_object_position_off_grid(0,0)。")
	_check(G, result.is_valid() == false, "off_grid 期望 is_valid=false。")
	root.free()


## 8. position NaN / Infinity → fixed_object_position_non_finite（结构级，无 cell）。
func _test_08_position_non_finite() -> void:
	const G: String = "08_非有限position"
	# NaN。
	var rootN: Node2D = _make_level(_cells_3x3(), [])
	var eN: _EmitterConfigNode = _add_valid_emitter(rootN, Vector2i(0, 0))
	eN.position = Vector2(NAN, 32.0)
	_add_valid_crystal(rootN, Vector2i(2, 2), &"c1")
	var rN: _LevelValidationResult = _validate(rootN)
	_check(G, _has_code(rN, "fixed_object_position_non_finite"), "NaN position 期望 fixed_object_position_non_finite。")
	_check(G, not _has_code(rN, "fixed_object_position_off_grid"), "非有限 position 不应再报 fixed_object_position_off_grid。")
	rootN.free()
	# Infinity。
	var rootI: Node2D = _make_level(_cells_3x3(), [])
	var eI: _EmitterConfigNode = _add_valid_emitter(rootI, Vector2i(0, 0))
	eI.position = Vector2(INF, 32.0)
	_add_valid_crystal(rootI, Vector2i(2, 2), &"c1")
	var rI: _LevelValidationResult = _validate(rootI)
	_check(G, _has_code(rI, "fixed_object_position_non_finite"), "Infinity position 期望 fixed_object_position_non_finite。")
	rootI.free()


## 9. 固定对象 Terrain 外 → fixed_object_outside_terrain（cell 级）。
func _test_09_object_outside_terrain() -> void:
	const G: String = "09_固定对象Terrain外"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(5, 5), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_cell_issue(result, "fixed_object_outside_terrain", Vector2i(5, 5)), "期望 fixed_object_outside_terrain(5,5)。")
	_check(G, result.is_valid() == false, "Terrain 外对象期望 is_valid=false。")
	root.free()


## 10. 固定对象位于 Wall → fixed_object_on_wall（cell 级）。
func _test_10_object_on_wall() -> void:
	const G: String = "10_固定对象位于Wall"
	var root: Node2D = _make_level(_cells_3x3(), [Vector2i(2, 2)])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_cell_issue(result, "fixed_object_on_wall", Vector2i(2, 2)), "期望 fixed_object_on_wall(2,2)。")
	_check(G, result.is_valid() == false, "对象位于 Wall 期望 is_valid=false。")
	root.free()


## 11. Emitter 与 Crystal 同 cell → fixed_object_overlap（cell 级）。
func _test_11_emitter_crystal_overlap() -> void:
	const G: String = "11_Emitter与Crystal同格"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(1, 1))
	_add_valid_crystal(root, Vector2i(1, 1), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_cell_issue(result, "fixed_object_overlap", Vector2i(1, 1)), "期望 fixed_object_overlap(1,1)。")
	_check(G, result.is_valid() == false, "同格 overlap 期望 is_valid=false。")
	root.free()


## 12. 无 Crystal → crystal_missing。
func _test_12_no_crystal() -> void:
	const G: String = "12_无Crystal"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "crystal_missing"), "期望 crystal_missing。")
	_check(G, result.is_valid() == false, "无 Crystal 期望 is_valid=false。")
	root.free()


## 13. 空 crystal_id → crystal_id_empty；object_id 保持空。
func _test_13_empty_crystal_id() -> void:
	const G: String = "13_空crystal_id"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(2, 2), &"")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "crystal_id_empty"), "期望 crystal_id_empty。")
	_check(G, result.is_valid() == false, "空 crystal_id 期望 is_valid=false。")
	_check(G, _object_id_of(result, "crystal_id_empty") == &"", "crystal_id_empty 的 object_id 应为空。")
	root.free()


## 14. 两 Crystal 重复 ID → multiple_crystals_unsupported + crystal_id_duplicate（恰好 1 条）。
func _test_14_two_crystals_duplicate_id() -> void:
	const G: String = "14_两Crystal重复ID"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(1, 0), &"dup")
	_add_valid_crystal(root, Vector2i(2, 0), &"dup")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "multiple_crystals_unsupported"), "期望 multiple_crystals_unsupported。")
	_check(G, _count_code(result, "crystal_id_duplicate") == 1, "期望恰好 1 个 crystal_id_duplicate，实际 %d。" % _count_code(result, "crystal_id_duplicate"))
	_check(G, result.is_valid() == false, "重复 ID 期望 is_valid=false。")
	root.free()


## 15. 两 Crystal 不同 ID → 仍 multiple_crystals_unsupported；不报 crystal_id_duplicate。
func _test_15_two_crystals_distinct_ids() -> void:
	const G: String = "15_两Crystal不同ID"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	_add_valid_crystal(root, Vector2i(1, 0), &"a")
	_add_valid_crystal(root, Vector2i(2, 0), &"b")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "multiple_crystals_unsupported"), "不同 ID 仍期望 multiple_crystals_unsupported。")
	_check(G, not _has_code(result, "crystal_id_duplicate"), "不同 ID 不应报 crystal_id_duplicate。")
	root.free()


## 16. Crystal 改 Node.name 不改变 object_id / 结论（object_id 来自 crystal_id，不来自 Node.name）。
func _test_16_rename_node_object_id_stable() -> void:
	const G: String = "16_改名不改object_id"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	var c: _BasicCrystal = _new_crystal(Vector2i(2, 2), &"C1", true, null)
	c.position = _cell_center(Vector2i(2, 2)) + Vector2(0.0011, 0.0)
	c.name = &"CrystalA"
	root.get_node(^"RuntimeObjects").add_child(c)
	var r1: _LevelValidationResult = _validate(root)
	_check(G, _object_id_of(r1, "fixed_object_position_off_grid") == &"C1", "改名前 off_grid 的 object_id 应为 C1。")
	c.name = &"CrystalB"
	var r2: _LevelValidationResult = _validate(root)
	_check(G, _object_id_of(r2, "fixed_object_position_off_grid") == &"C1", "改名后 off_grid 的 object_id 应仍为 C1。")
	_check(G, _signature_code_object_id(r1) == _signature_code_object_id(r2), "改 Node.name 后 (code,object_id) 结论应不变。")
	root.free()


## 17. Crystal 缺 VisualView → crystal_visual_missing（ERROR）。
func _test_17_crystal_missing_visualview() -> void:
	const G: String = "17_Crystal缺VisualView"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	var c: _BasicCrystal = _new_crystal(Vector2i(2, 2), &"c1", false)
	root.get_node(^"RuntimeObjects").add_child(c)
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "crystal_visual_missing"), "期望 crystal_visual_missing。")
	_check(G, result.is_valid() == false, "缺 VisualView 期望 is_valid=false。")
	root.free()


## 18. Crystal VisualView 缺 Profile → crystal_visual_profile_missing（仅 WARNING，is_valid=true）。
func _test_18_crystal_profile_missing_warning() -> void:
	const G: String = "18_Crystal缺Profile仅WARNING"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	var c: _BasicCrystal = _new_crystal(Vector2i(2, 2), &"c1", true, null)
	root.get_node(^"RuntimeObjects").add_child(c)
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "crystal_visual_profile_missing"), "期望 crystal_visual_profile_missing。")
	_check(G, result.get_error_count() == 0, "Profile 缺失仅 WARNING，期望 0 ERROR。")
	_check(G, result.is_valid() == true, "Profile 缺失期望 is_valid=true。")
	root.free()


## 19. Emitter visual_profile 缺失 → emitter_visual_profile_missing（仅 WARNING，is_valid=true）。
func _test_19_emitter_profile_missing_warning() -> void:
	const G: String = "19_Emitter缺Profile仅WARNING"
	var root: Node2D = _make_level(_cells_3x3(), [])
	var e: _EmitterConfigNode = _new_emitter(Vector2i(0, 0))
	root.get_node(^"RuntimeObjects").add_child(e)
	_add_valid_crystal(root, Vector2i(2, 2), &"c1")
	var result: _LevelValidationResult = _validate(root)
	_check(G, _has_code(result, "emitter_visual_profile_missing"), "期望 emitter_visual_profile_missing。")
	_check(G, result.get_error_count() == 0, "Profile 缺失仅 WARNING，期望 0 ERROR。")
	_check(G, result.is_valid() == true, "Profile 缺失期望 is_valid=true。")
	root.free()


## 20. 连续 validate 两次结果一致，且不修改场景（子节点数 / position / 名称不变）。
func _test_20_twice_consistent() -> void:
	const G: String = "20_连续一致且不改场景"
	var root: Node2D = _make_level(_cells_3x3(), [])
	_add_valid_emitter(root, Vector2i(0, 0))
	var c: _BasicCrystal = _new_crystal(Vector2i(2, 2), &"c1", true, null)
	root.get_node(^"RuntimeObjects").add_child(c)
	var runtime: Node = root.get_node(^"RuntimeObjects")
	var child_count_before: int = runtime.get_child_count()
	var emitter_pos_before: Vector2 = (root.get_node(^"RuntimeObjects/Emitter") as Node2D).position
	var crystal_pos_before: Vector2 = c.position
	var validator: _LevelValidator = _LevelValidator.new()
	var r1: _LevelValidationResult = validator.validate(root)
	var r2: _LevelValidationResult = validator.validate(root)
	_check(G, _signature(r1) == _signature(r2), "两次 validate 结果序列应一致。")
	_check(G, runtime.get_child_count() == child_count_before, "两次 validate 不应改变 RuntimeObjects 子节点数。")
	_check(G, (root.get_node(^"RuntimeObjects/Emitter") as Node2D).position == emitter_pos_before, "validate 不应改 Emitter position。")
	_check(G, c.position == crystal_pos_before, "validate 不应改 Crystal position。")
	_check(G, c.name == &"BasicCrystal", "validate 不应改节点名。")
	root.free()


# ===== fixture =====

## 组装结构合法的关卡根：六个正式角色齐备（Terrain / Wall / Legal / Decoration 为 TileMapLayer，
## RuntimeObjects / LightPathLayer 为 Node2D），LegalArea 固定放 (0,0) 以避免 legal_area_empty 噪声；
## Terrain / Wall 格由参数指定。
func _make_level(terrain_cells: Array, wall_cells: Array) -> Node2D:
	var ts: TileSet = _make_min_tile_set()
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	root.add_child(_new_tile_layer("TerrainLayer", ts, terrain_cells))
	root.add_child(_new_tile_layer("WallLayer", ts, wall_cells))
	root.add_child(_new_tile_layer("LegalAreaLayer", ts, [Vector2i(0, 0)]))
	root.add_child(_new_tile_layer("DecorationLayer", ts, []))
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	var light: Node2D = Node2D.new()
	light.name = &"LightPathLayer"
	root.add_child(light)
	return root


## 构造最小可用 TileSet：单 atlas 源、无纹理；set_cell 引用 source 0 即可使 get_used_cells 返回该格。
func _make_min_tile_set() -> TileSet:
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	tile_set.add_source(source)
	return tile_set


## 用给定 TileSet 与格列表构造未入树的 TileMapLayer 并逐格 set_cell；transform 保持单位。
func _new_tile_layer(layer_name: String, tile_set: TileSet, cells: Array) -> TileMapLayer:
	var layer: TileMapLayer = TileMapLayer.new()
	layer.name = StringName(layer_name)
	layer.tile_set = tile_set
	for c: Vector2i in cells:
		layer.set_cell(c, 0, Vector2i.ZERO, 0)
	return layer


## 格中心世界坐标（正式 GridCoordinateRules.cell_to_world）。
func _cell_center(cell: Vector2i) -> Vector2:
	return _GridCoordinateRules.cell_to_world(cell)


## 新建一个非空 ObjectVisualProfile（内容留空；校验器只判 != null）。
func _new_profile() -> _ObjectVisualProfile:
	return _ObjectVisualProfile.new()


## 新建真实 EmitterConfigNode：名为 Emitter、position 居中目标格、默认 RAY；profile 可空。
func _new_emitter(cell: Vector2i, profile: _ObjectVisualProfile = null) -> _EmitterConfigNode:
	var e: _EmitterConfigNode = _EmitterConfigNode.new()
	e.name = &"Emitter"
	e.position = _cell_center(cell)
	if profile != null:
		e.visual_profile = profile
	return e


## 新建真实 BasicCrystal：position 居中目标格、显式 crystal_id；with_visual 控制是否挂直属 VisualView，
## profile 配置 VisualView 的 visual_profile（为空即“缺 Profile”）。
func _new_crystal(
		cell: Vector2i,
		crystal_id: StringName,
		with_visual: bool = true,
		profile: _ObjectVisualProfile = null
) -> _BasicCrystal:
	var c: _BasicCrystal = _BasicCrystal.new()
	c.name = &"BasicCrystal"
	c.position = _cell_center(cell)
	c.crystal_id = crystal_id
	if with_visual:
		var view: _ObjectVisualView = _ObjectVisualView.new()
		view.name = &"VisualView"
		if profile != null:
			view.visual_profile = profile
		c.add_child(view)
	return c


## 在 RuntimeObjects 直属下添加合法 Emitter（RAY + Profile，名 Emitter），返回该节点供用例改写。
func _add_valid_emitter(root: Node2D, cell: Vector2i) -> _EmitterConfigNode:
	var e: _EmitterConfigNode = _new_emitter(cell, _new_profile())
	root.get_node(^"RuntimeObjects").add_child(e)
	return e


## 在 RuntimeObjects 直属下添加合法 Crystal（crystal_id + VisualView + Profile），返回该节点供用例改写。
func _add_valid_crystal(root: Node2D, cell: Vector2i, crystal_id: StringName) -> _BasicCrystal:
	var c: _BasicCrystal = _new_crystal(cell, crystal_id, true, _new_profile())
	root.get_node(^"RuntimeObjects").add_child(c)
	return c


## 3×3 实心 Terrain 格（原点 (0,0)，含 (0,0) 以匹配 LegalArea）。
func _cells_3x3() -> Array:
	return [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]


# ===== 断言辅助 =====

## 新建无状态校验器并校验 root。
func _validate(root: Node) -> _LevelValidationResult:
	return _LevelValidator.new().validate(root)


## 结果中是否存在指定 code 的 issue。
func _has_code(result: _LevelValidationResult, code: String) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			return true
	return false


## 结果中指定 code 的 issue 数量。
func _count_code(result: _LevelValidationResult, code: String) -> int:
	var n: int = 0
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			n += 1
	return n


## 结果中是否存在指定 code 且 cell 匹配的 cell 级 issue。
func _has_cell_issue(result: _LevelValidationResult, code: String, cell: Vector2i) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code and issue.has_cell() and issue.get_cell() == cell:
			return true
	return false


## 结果中首个指定 code issue 的 object_id（无则空）。
func _object_id_of(result: _LevelValidationResult, code: String) -> StringName:
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			return issue.get_object_id()
	return &""


## issue 全排序键签名（含 node_path），用于比较两次结果是否逐项一致。
func _signature(result: _LevelValidationResult) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for issue in result.get_issues():
		parts.append("%d|%s|%s|%d|%d,%d|%s" % [
			issue.get_severity(), str(issue.get_code()), str(issue.get_node_path()),
			int(issue.has_cell()), issue.get_cell().x, issue.get_cell().y, str(issue.get_object_id())
		])
	return "\n".join(parts)


## issue 的 (code, object_id) 多重集签名（不含 node_path，节点改名后仍应一致）。
func _signature_code_object_id(result: _LevelValidationResult) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for issue in result.get_issues():
		parts.append("%s|%s" % [str(issue.get_code()), str(issue.get_object_id())])
	parts.sort()
	return "\n".join(parts)


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelValidator 固定对象规则 测试摘要 ====")
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
