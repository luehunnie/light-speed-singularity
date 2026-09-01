extends SceneTree

## C-08 命中去重定向测试（冻结裁决 5：同一 emission 对同一水晶格只计一次）。
## 以未绑定模型的空 Registry 观察值验证去重表语义：重复键 apply_hit 提前幂等返回 true（先于水晶路由）；
## 不同格 / 不同 emission / emission_id=0 遗留桩仍逐次路由；reset_runtime 清空去重历史。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _HitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_same_emission_same_cell_dedup()
	_test_02_different_cell_or_emission_count_separately()
	_test_03_legacy_stub_emission_not_deduped()
	_test_04_reset_clears_history()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 构造空 Registry 控制器（全部格无水晶：try_activate 路径恒 false，返回值差异即去重证据）。
func _make_controller() -> Variant:
	return _ObjectiveController.new(_LevelObjectRegistry.new())


## 构造 RAY 形态命中事实。
func _ray_hit(cell: Vector2i, emission_id: int, generation: int) -> Variant:
	return _HitContext.create_for_ray(
		cell, Vector2i(1, 0), emission_id, generation, _RayColor.ColorValue.WHITE)


## 1. 同 emission 同格重复命中：第二次幂等返回 true（去重拦截，先于水晶路由）。
func _test_01_same_emission_same_cell_dedup() -> void:
	const G: String = "01_同键去重"
	var controller: Variant = _make_controller()
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "首次命中无水晶应 false。")
	_check(G, controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "同 generation|emission|cell 重复命中应幂等 true。")
	_check(G, controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "第三次重复命中仍应幂等 true。")
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 8, 3)), "同格不同 emission 不得命中去重缓存。")


## 2. 不同格 / 不同 generation 仍分别计（键含三元组，互不污染）。
func _test_02_different_cell_or_emission_count_separately() -> void:
	const G: String = "02_异键分别计"
	var controller: Variant = _make_controller()
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "首次命中应 false。")
	_check(G, controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "重复键应去重 true。")
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(5, 4), 7, 3)), "同 emission 不同格应分别计（false）。")
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 4)), "同键不同 generation 应分别计（false）。")


## 3. emission_id=0 遗留测试桩不参与去重：两次都路由水晶路径（无水晶恒 false）。
func _test_03_legacy_stub_emission_not_deduped() -> void:
	const G: String = "03_遗留桩豁免"
	var controller: Variant = _make_controller()
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 0, 3)), "emission_id=0 首次应 false。")
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 0, 3)), "emission_id=0 重复命中不走去重，应再 false。")


## 4. reset_runtime 清空去重历史：同键复位后重新走水晶路径（false）。
func _test_04_reset_clears_history() -> void:
	const G: String = "04_reset清历史"
	var controller: Variant = _make_controller()
	controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3))
	_check(G, controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "重复键应去重 true。")
	controller.reset_runtime()
	_check(G, not controller.apply_hit(_ray_hit(Vector2i(4, 4), 7, 3)), "reset 后去重历史清空，应重新路由（false）。")


func _report() -> void:
	print("C-08 crystal hit dedup: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
