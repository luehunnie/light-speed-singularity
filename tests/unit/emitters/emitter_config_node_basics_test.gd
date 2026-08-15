extends SceneTree

## EmitterConfigNode 单元测试（拆分片 1/5 · 基础契约）。
## 覆盖：继承 GridPlacedObject、默认形态/方向、八光线与四光粒方向映射、active 随形态切换、
##   运行时形态支持、方向分开保存、visual_profile 可空。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 非法值用例会产生预期 push_error 输出，不计入失败。

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_extends_grid_placed_object()
	_test_02_default_form_ray()
	_test_03_default_ray_direction_vector()
	_test_04_default_particle_direction_vector()
	_test_05_all_ray_direction_mappings()
	_test_06_all_particle_direction_mappings()
	_test_07_active_direction_switches_with_form()
	_test_08_runtime_supported_ray()
	_test_09_runtime_supported_particle()
	_test_10_directions_stored_separately()
	_test_11_visual_profile_nullable()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 继承 GridPlacedObject：position/cell 契约由基类承担。
func _test_01_extends_grid_placed_object() -> void:
	const NAME: String = "01_继承GridPlacedObject"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config is _GridPlacedObject, "EmitterConfigNode 应为 GridPlacedObject 子类。")
	_check(NAME, config is Node2D, "EmitterConfigNode 应为 Node2D 子类（经 GridPlacedObject）。")
	config.free()


## 2. 默认形态为 RAY。
func _test_02_default_form_ray() -> void:
	const NAME: String = "02_默认形态RAY"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_default_light_form() == _EmitterConfigNode.LightForm.RAY, "默认形态应为 RAY，实际 %d。" % [config.get_default_light_form()])
	_check(NAME, config.default_light_form == _EmitterConfigNode.LightForm.RAY, "默认 default_light_form 字段应为 RAY。")
	config.free()


## 3. 默认光线方向 RIGHT → Vector2i(1,0)。
func _test_03_default_ray_direction_vector() -> void:
	const NAME: String = "03_默认光线方向RIGHT"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.RIGHT, "默认光线方向应为 RIGHT。")
	_check(NAME, config.get_ray_direction_vector() == Vector2i(1, 0), "默认光线方向向量应为 (1,0)，实际 %s。" % [config.get_ray_direction_vector()])
	config.free()


## 4. 默认光粒方向 RIGHT → Vector2i(1,0)。
func _test_04_default_particle_direction_vector() -> void:
	const NAME: String = "04_默认光粒方向RIGHT"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.RIGHT, "默认光粒方向应为 RIGHT。")
	_check(NAME, config.get_particle_direction_vector() == Vector2i(1, 0), "默认光粒方向向量应为 (1,0)，实际 %s。" % [config.get_particle_direction_vector()])
	config.free()


## 5. 八个光线方向映射全部正确。
func _test_05_all_ray_direction_mappings() -> void:
	const NAME: String = "05_八光线方向映射"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var cases: Array = [
		[_EmitterConfigNode.RayDirection.RIGHT, Vector2i(1, 0)],
		[_EmitterConfigNode.RayDirection.DOWN_RIGHT, Vector2i(1, 1)],
		[_EmitterConfigNode.RayDirection.DOWN, Vector2i(0, 1)],
		[_EmitterConfigNode.RayDirection.DOWN_LEFT, Vector2i(-1, 1)],
		[_EmitterConfigNode.RayDirection.LEFT, Vector2i(-1, 0)],
		[_EmitterConfigNode.RayDirection.UP_LEFT, Vector2i(-1, -1)],
		[_EmitterConfigNode.RayDirection.UP, Vector2i(0, -1)],
		[_EmitterConfigNode.RayDirection.UP_RIGHT, Vector2i(1, -1)],
	]
	for case: Array in cases:
		var d: int = case[0]
		var expected: Vector2i = case[1]
		var got: Vector2i = _EmitterConfigNode.ray_direction_to_vector(d)
		_check(NAME, got == expected, "RayDirection %d 应映射到 %s，实际 %s。" % [d, expected, got])
	config.free()


## 6. 八个光粒方向映射全部正确（旧四正方向数值冻结，新四斜向追加）。
func _test_06_all_particle_direction_mappings() -> void:
	const NAME: String = "06_八光粒方向映射"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var cases: Array = [
		[_EmitterConfigNode.ParticleDirection.RIGHT, Vector2i(1, 0)],
		[_EmitterConfigNode.ParticleDirection.DOWN, Vector2i(0, 1)],
		[_EmitterConfigNode.ParticleDirection.LEFT, Vector2i(-1, 0)],
		[_EmitterConfigNode.ParticleDirection.UP, Vector2i(0, -1)],
		[_EmitterConfigNode.ParticleDirection.DOWN_RIGHT, Vector2i(1, 1)],
		[_EmitterConfigNode.ParticleDirection.DOWN_LEFT, Vector2i(-1, 1)],
		[_EmitterConfigNode.ParticleDirection.UP_LEFT, Vector2i(-1, -1)],
		[_EmitterConfigNode.ParticleDirection.UP_RIGHT, Vector2i(1, -1)],
	]
	for case: Array in cases:
		var d: int = case[0]
		var expected: Vector2i = case[1]
		var got: Vector2i = _EmitterConfigNode.particle_direction_to_vector(d)
		_check(NAME, got == expected, "ParticleDirection %d 应映射到 %s，实际 %s。" % [d, expected, got])
	config.free()


## 7. get_active_direction_vector 随形态切换返回对应方向。
func _test_07_active_direction_switches_with_form() -> void:
	const NAME: String = "07_active随形态切换"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, 1), "RAY 形态 active 应为光线方向 (0,1)，实际 %s。" % [config.get_active_direction_vector()])
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, -1), "PARTICLE 形态 active 应为光粒方向 (0,-1)，实际 %s。" % [config.get_active_direction_vector()])
	# 切回 RAY：active 应回到光线方向，且光线方向未被形态切换覆盖。
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, 1), "切回 RAY 后 active 应为 (0,1)，实际 %s。" % [config.get_active_direction_vector()])
	config.free()


## 8. RAY 形态 is_runtime_form_supported 为 true。
func _test_08_runtime_supported_ray() -> void:
	const NAME: String = "08_RAY运行时支持"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.is_runtime_form_supported() == true, "RAY 形态应支持运行时。")
	config.free()


## 9. PARTICLE 形态 is_runtime_form_supported 为 true（B3b-1 起 PARTICLE 接 Runtime；不抛假结果、不自动降级）。
func _test_09_runtime_supported_particle() -> void:
	const NAME: String = "09_PARTICLE运行时支持"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.is_runtime_form_supported() == true, "PARTICLE 形态 B3b-1 起应支持运行时（与真实 Runtime 能力同步）。")
	_check(NAME, config.get_default_light_form() == _EmitterConfigNode.LightForm.PARTICLE, "设置后形态应仍为 PARTICLE，未自动降级为 RAY。")
	config.free()


## 10. 光线与光粒方向分开保存；切换形态不丢失另一方向。
func _test_10_directions_stored_separately() -> void:
	const NAME: String = "10_方向分开保存"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.DOWN, "切到 PARTICLE 后光线方向应仍为 DOWN。")
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "切到 PARTICLE 后光粒方向应为 UP。")
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.DOWN, "切回 RAY 后光线方向应仍为 DOWN。")
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "切回 RAY 后光粒方向应仍为 UP。")
	config.free()


## 11. visual_profile 允许为空。
func _test_11_visual_profile_nullable() -> void:
	const NAME: String = "11_visual_profile可空"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_visual_profile() == null, "默认 visual_profile 应为 null，实际 %s。" % [config.get_visual_profile()])
	_check(NAME, config.visual_profile == null, "visual_profile 字段默认应为 null。")
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile
	_check(NAME, config.get_visual_profile() == profile, "赋值后 get_visual_profile 应返回同一资源。")
	config.visual_profile = null
	_check(NAME, config.get_visual_profile() == null, "置空后 visual_profile 应为 null。")
	# ObjectVisualProfile 为 RefCounted，随引用计数自动回收，不调用 free()。
	config.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 11
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 基础契约 测试摘要 ====")
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
