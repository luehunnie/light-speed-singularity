extends SceneTree

## ObjectiveController 定向自动测试（D3-D）。
## 覆盖按 cell 激活、完成判断、空 Registry 不误判、重复激活稳定、reset 恢复、计数查询，以及不修改运行状态/不创建视觉/不读 Node.name 的静态边界。
## 另含 D3-D 迁移静态验证：LightWorldQuery 不再持 _crystals/不再遍历水晶数组、核心不再含旧目标业务函数、逐 step 视觉早于 Objective 激活、Objective 不直接调用运行状态控制器。
## 可激活水晶需入树以触发 _ready（@onready _visual 解析 VisualView 子节点），故每颗水晶挂到临时父节点下并装配真实 VisualView 与 profile；测试结束统一释放。


const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _VisualViewScene: PackedScene = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn")
const _CrystalProfile: Resource = preload("res://assets/visual_profiles/basic_crystal_visuals.tres")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 本轮创建的水晶实例，统一释放避免 --script 模式泄漏。
var _crystals: Array[BasicCrystal] = []


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	_test_01_single_unactivated_not_completed()
	_test_02_activate_correct_cell()
	_test_03_completed_after_activation()
	_test_04_wrong_cell_no_side_effect()
	_test_05_repeat_activation_stable()
	_test_06_reset_not_completed()
	_test_07_reset_restores_crystal()
	_test_08_partial_activation_not_completed()
	_test_09_all_activated_completed()
	_test_10_empty_registry_not_completed()
	_test_11_required_count()
	_test_12_activated_count()
	_test_13_no_runstate_mutation()
	_test_14_no_visual_creation()
	_test_15_no_node_name_dependency()
	_test_16_light_world_query_no_crystals_array()
	_test_17_light_world_query_no_iteration()
	_test_18_core_no_legacy_objective_functions()
	_test_19_wiring_visual_before_objective()
	_test_20_objective_no_runstate_call()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 可激活水晶需 _ready 解析 @onready _visual；--script 模式下 add_child 不触发引擎 _ready，故手动调用 view 与 crystal 的 _ready()。
## 不挂场景树，避免引擎在帧处理时二次触发 _ready；测试结束统一 free。
func _make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = cell
	crystal.crystal_id = crystal_id
	var view: ObjectVisualView = _VisualViewScene.instantiate()
	view.name = "VisualView"
	view.visual_profile = _CrystalProfile
	view.initial_state_id = &"unlit"
	crystal.add_child(view)
	view._ready()
	crystal._ready()
	_crystals.append(crystal)
	return crystal


## 构造一个空 Registry。
func _empty_registry() -> _LevelObjectRegistry:
	return _LevelObjectRegistry.new()


## 1. 单水晶未激活时未完成。
func _test_01_single_unactivated_not_completed() -> void:
	const NAME: String = "01_单水晶未激活未完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c001", Vector2i(3, 1))
	r.register_crystal(&"c001", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	_check(NAME, not obj.is_completed(), "未激活时不应完成。")
	_check(NAME, obj.get_activated_count() == 0, "已激活数期望 0。")


## 2. 按正确 cell 激活：返回 true 且水晶点亮。
func _test_02_activate_correct_cell() -> void:
	const NAME: String = "02_按正确cell激活"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c002", Vector2i(3, 1))
	r.register_crystal(&"c002", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	var ok: bool = obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, ok, "正确 cell 应返回 true（存在水晶且请求被接受）。")
	_check(NAME, c.is_activated, "水晶应已点亮。")


## 3. 激活后完成。
func _test_03_completed_after_activation() -> void:
	const NAME: String = "03_激活后完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c003", Vector2i(3, 1))
	r.register_crystal(&"c003", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, obj.is_completed(), "全部激活后应完成。")
	_check(NAME, obj.get_activated_count() == 1, "已激活数期望 1。")


## 4. 错误 cell 无副作用：返回 false，不点亮任何水晶，不完成。
func _test_04_wrong_cell_no_side_effect() -> void:
	const NAME: String = "04_错误cell无副作用"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c004", Vector2i(3, 1))
	r.register_crystal(&"c004", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	var ok: bool = obj.try_activate_crystal_at(Vector2i(9, 9))
	_check(NAME, not ok, "错误 cell 应返回 false（无水晶）。")
	_check(NAME, not c.is_activated, "错误 cell 不应点亮水晶。")
	_check(NAME, not obj.is_completed(), "错误 cell 后不应完成。")


## 5. 重复激活保持稳定：多次调用不破坏状态，仍完成。
func _test_05_repeat_activation_stable() -> void:
	const NAME: String = "05_重复激活稳定"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c005", Vector2i(3, 1))
	r.register_crystal(&"c005", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	obj.try_activate_crystal_at(Vector2i(3, 1))
	obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, c.is_activated, "重复激活后水晶仍应点亮。")
	_check(NAME, obj.is_completed(), "重复激活后仍应完成。")
	_check(NAME, obj.get_activated_count() == 1, "重复激活后已激活数仍为 1。")


## 6. reset_runtime 后未完成。
func _test_06_reset_not_completed() -> void:
	const NAME: String = "06_reset后未完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c006", Vector2i(3, 1))
	r.register_crystal(&"c006", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, obj.is_completed(), "激活后应先完成。")
	obj.reset_runtime()
	_check(NAME, not obj.is_completed(), "reset 后不应完成。")
	_check(NAME, obj.get_activated_count() == 0, "reset 后已激活数期望 0。")


## 7. reset 后水晶状态恢复（is_activated 归 false）。
func _test_07_reset_restores_crystal() -> void:
	const NAME: String = "07_reset后水晶状态恢复"
	var r: _LevelObjectRegistry = _empty_registry()
	var c: BasicCrystal = _make_crystal(&"c007", Vector2i(3, 1))
	r.register_crystal(&"c007", Vector2i(3, 1), c)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	obj.reset_runtime()
	_check(NAME, not c.is_activated, "reset 后水晶应恢复未点亮。")


## 8. 多水晶只激活一部分时未完成。
func _test_08_partial_activation_not_completed() -> void:
	const NAME: String = "08_多水晶部分激活未完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var c1: BasicCrystal = _make_crystal(&"c008a", Vector2i(3, 1))
	var c2: BasicCrystal = _make_crystal(&"c008b", Vector2i(5, 1))
	r.register_crystal(&"c008a", Vector2i(3, 1), c1)
	r.register_crystal(&"c008b", Vector2i(5, 1), c2)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, not obj.is_completed(), "仅激活一部分时不应完成。")
	_check(NAME, obj.get_activated_count() == 1, "已激活数期望 1。")
	_check(NAME, obj.get_required_count() == 2, "必需数期望 2。")


## 9. 多水晶全部激活后完成。
func _test_09_all_activated_completed() -> void:
	const NAME: String = "09_多水晶全部激活完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var c1: BasicCrystal = _make_crystal(&"c009a", Vector2i(3, 1))
	var c2: BasicCrystal = _make_crystal(&"c009b", Vector2i(5, 1))
	var c3: BasicCrystal = _make_crystal(&"c009c", Vector2i(7, 1))
	r.register_crystal(&"c009a", Vector2i(3, 1), c1)
	r.register_crystal(&"c009b", Vector2i(5, 1), c2)
	r.register_crystal(&"c009c", Vector2i(7, 1), c3)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	obj.try_activate_crystal_at(Vector2i(3, 1))
	obj.try_activate_crystal_at(Vector2i(5, 1))
	_check(NAME, not obj.is_completed(), "激活两颗第三颗未激活时不应完成。")
	obj.try_activate_crystal_at(Vector2i(7, 1))
	_check(NAME, obj.is_completed(), "全部激活后应完成。")
	_check(NAME, obj.get_activated_count() == 3, "已激活数期望 3。")


## 10. 空 Registry 不得完成。
func _test_10_empty_registry_not_completed() -> void:
	const NAME: String = "10_空Registry不完成"
	var r: _LevelObjectRegistry = _empty_registry()
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	_check(NAME, not obj.is_completed(), "空 Registry 不应误判完成。")
	_check(NAME, obj.get_required_count() == 0, "空 Registry 必需数期望 0。")
	_check(NAME, obj.get_activated_count() == 0, "空 Registry 已激活数期望 0。")
	var ok: bool = obj.try_activate_crystal_at(Vector2i(3, 1))
	_check(NAME, not ok, "空 Registry 激活任意 cell 应返回 false。")
	_check(NAME, not obj.is_completed(), "空 Registry 激活后仍不应完成。")


## 11. get_required_count 正确。
func _test_11_required_count() -> void:
	const NAME: String = "11_get_required_count正确"
	var r: _LevelObjectRegistry = _empty_registry()
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	_check(NAME, obj.get_required_count() == 0, "初始必需数期望 0。")
	r.register_crystal(&"c011a", Vector2i(1, 1), _make_crystal(&"c011a", Vector2i(1, 1)))
	_check(NAME, obj.get_required_count() == 1, "注册 1 颗后必需数期望 1。")
	r.register_crystal(&"c011b", Vector2i(2, 1), _make_crystal(&"c011b", Vector2i(2, 1)))
	_check(NAME, obj.get_required_count() == 2, "注册 2 颗后必需数期望 2。")


## 12. get_activated_count 正确。
func _test_12_activated_count() -> void:
	const NAME: String = "12_get_activated_count正确"
	var r: _LevelObjectRegistry = _empty_registry()
	var c1: BasicCrystal = _make_crystal(&"c012a", Vector2i(1, 1))
	var c2: BasicCrystal = _make_crystal(&"c012b", Vector2i(2, 1))
	r.register_crystal(&"c012a", Vector2i(1, 1), c1)
	r.register_crystal(&"c012b", Vector2i(2, 1), c2)
	var obj: _ObjectiveController = _ObjectiveController.new(r)
	_check(NAME, obj.get_activated_count() == 0, "初始已激活数期望 0。")
	obj.try_activate_crystal_at(Vector2i(1, 1))
	_check(NAME, obj.get_activated_count() == 1, "激活 1 颗后期望 1。")
	obj.try_activate_crystal_at(Vector2i(2, 1))
	_check(NAME, obj.get_activated_count() == 2, "激活 2 颗后期望 2。")
	obj.reset_runtime()
	_check(NAME, obj.get_activated_count() == 0, "reset 后已激活数期望 0。")


## 13. ObjectiveController 不修改运行状态：源码不引用运行状态控制器接口与状态规则。
func _test_13_no_runstate_mutation() -> void:
	const NAME: String = "13_不修改运行状态"
	var src: String = FileAccess.get_file_as_string("res://gameplay/objectives/objective_controller.gd")
	var forbidden: Array = [
		"_run_state_controller", "begin_pulse", "finish_pulse", "reset_to_setup",
		"RuntimeStateRules", "RuntimeInteractionTypes", "RunState"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "ObjectiveController 源码不应引用运行状态相关令牌：%s" % [token])


## 14. ObjectiveController 不创建视觉：源码不引用视觉控制器、场景树节点或纹理操作。
func _test_14_no_visual_creation() -> void:
	const NAME: String = "14_不创建视觉"
	var src: String = FileAccess.get_file_as_string("res://gameplay/objectives/objective_controller.gd")
	var forbidden: Array = [
		"_light_visual_controller", "show_step", "clear_path", "LightVisual",
		"LightPathLayer", "add_child", "TextureRect", "ObjectVisualView", "set_content_state"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "ObjectiveController 源码不应包含视觉相关令牌：%s" % [token])


## 15. ObjectiveController 不读取 Node.name：源码不以节点名作为业务标识。
func _test_15_no_node_name_dependency() -> void:
	const NAME: String = "15_不读Node.name"
	var src: String = FileAccess.get_file_as_string("res://gameplay/objectives/objective_controller.gd")
	var forbidden: Array = ["Node.name", ".name", "get_name"]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "ObjectiveController 源码不应读取 Node.name：%s" % [token])


## 16. LightWorldQuery 不再保存 _crystals 字段（静态迁移验证）。
func _test_16_light_world_query_no_crystals_array() -> void:
	const NAME: String = "16_LightWorldQuery无crystals数组"
	var src: String = FileAccess.get_file_as_string("res://gameplay/world/light_world_query.gd")
	_check(NAME, src.find("_crystals") == -1, "LightWorldQuery 不应再持有 _crystals 字段。")
	_check(NAME, src.find("crystals: Array[BasicCrystal]") == -1, "LightWorldQuery 构造不应再接收 crystals 数组参数。")


## 17. LightWorldQuery 不再遍历水晶数组：has_crystal_at 委托 LevelWorldQuery，不直接 for 遍历水晶。
func _test_17_light_world_query_no_iteration() -> void:
	const NAME: String = "17_LightWorldQuery不遍历水晶"
	var src: String = FileAccess.get_file_as_string("res://gameplay/world/light_world_query.gd")
	var fn_start: int = src.find("func has_crystal_at")
	if _check(NAME, fn_start != -1, "应找到 has_crystal_at 函数。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		_check(NAME, body.find("for crystal") == -1, "has_crystal_at 不应再 for 遍历水晶数组。")
		_check(NAME, body.find("_level_world_query.has_crystal_at") != -1, "has_crystal_at 应委托 LevelWorldQuery.has_crystal_at。")


## 18. 核心不再包含旧目标业务函数与完成字段（静态迁移验证）。
func _test_18_core_no_legacy_objective_functions() -> void:
	const NAME: String = "18_核心无旧目标业务函数"
	var src: String = FileAccess.get_file_as_string("res://levels/prototypes/core_loop_prototype.gd")
	var forbidden: Array = [
		"func try_activate_crystal_at",
		"func all_required_crystals_activated",
		"func update_completion_state",
		"func _reset_independent_crystals",
		"var is_level_completed",
		"is_level_completed"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "核心不应再保留旧目标业务函数/字段：%s" % [token])


## 19. 逐 step 接线仍是视觉早于 Objective 激活（D3-E：_apply_ray_execution_result 迁入 LevelRuntimeController，检查其源码中 show_step 早于 _objective_controller.try_activate_crystal_at）。
func _test_19_wiring_visual_before_objective() -> void:
	const NAME: String = "19_视觉早于Objective激活"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var obj_idx: int = body.find("_objective_controller.try_activate_crystal_at")
		_check(NAME, show_idx != -1, "_apply_ray_execution_result 应调用 _light_visual_controller.show_step。")
		_check(NAME, obj_idx != -1, "_apply_ray_execution_result 应调用 _objective_controller.try_activate_crystal_at。")
		_check(NAME, show_idx < obj_idx, "视觉创建必须在 Objective 激活之前（show_step @ %d < objective @ %d）。" % [show_idx, obj_idx])


## 20. Objective 不直接调用运行状态控制器（静态迁移验证：与 test 13 互补，独立列出供回归锁定）。
func _test_20_objective_no_runstate_call() -> void:
	const NAME: String = "20_Objective不调用运行状态控制器"
	var src: String = FileAccess.get_file_as_string("res://gameplay/objectives/objective_controller.gd")
	_check(NAME, src.find("_run_state_controller") == -1, "ObjectiveController 不应持有运行状态控制器引用。")
	_check(NAME, src.find("begin_pulse") == -1, "ObjectiveController 不应调用 begin_pulse。")
	_check(NAME, src.find("finish_pulse") == -1, "ObjectiveController 不应调用 finish_pulse。")
	_check(NAME, src.find("reset_to_setup") == -1, "ObjectiveController 不应调用 reset_to_setup。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 释放本轮创建的水晶实例（连带 VisualView 子节点），跳过已释放的实例。
func _cleanup() -> void:
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			# 先释放 VisualView 子节点，再释放水晶本身。
			for child: Node in crystal.get_children():
				child.free()
			crystal.free()
	_crystals.clear()


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 20
	var passed_checks: int = _checks - _failures.size()
	print("==== ObjectiveController D3-D 测试摘要 ====")
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
