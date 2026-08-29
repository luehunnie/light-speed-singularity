extends SceneTree

## S3 光颜色水晶最小测试（机关规则 光颜色水晶_颜色_v0.1）：
## 覆盖：命中事实颜色域（RAY 真实四色 / PARTICLE 恒 NONE / 非法拒绝）、color_condition 配置域（红/绿/蓝合法，
## WHITE/NONE 越界拒绝）与求值矩阵（精确匹配才满足；WHITE 与 PARTICLE 不满足）、form+color AND 组合、
## meta 条件绑定（objective_conditions 的 target_color 参数）+ Controller 点亮 / Reset 归零、
## RayExecutionModule 到达色逐格事实（滤光片 COLOR_CHANGE 从下一格起生效 + 异色吸收 BLOCK）。
## 复用 ray_execution_module_test 的真实 LevelWorldQuery/OccupancyRegistry/placed 查表模式。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")
const _ObjectiveConditionConfiguration: GDScript = preload("res://gameplay/objectives/objective_condition_configuration.gd")
const _ObjectiveConditionEvaluator: GDScript = preload("res://gameplay/objectives/objective_condition_evaluator.gd")
const _ObjectiveTarget: GDScript = preload("res://gameplay/objectives/objective_target.gd")
const _ObjectiveMetaReader: GDScript = preload("res://gameplay/objectives/objective_meta_reader.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LightFilterScene: PackedScene = preload("res://gameplay/mechanisms/filters/light_filter.tscn")
const _ColorCrystalScript: GDScript = preload("res://gameplay/crystals/color_crystal.gd")
const _ColorCrystalScene: PackedScene = preload("res://gameplay/crystals/color_crystal.tscn")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_hit_context_color_domain()
	_test_02_color_configuration_domain()
	_test_03_evaluator_matrix()
	_test_04_target_and_semantics()
	await _test_05_meta_binding_and_light_up()
	_test_06_propagation_arrival_color_facts()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, reason])
	return condition


func _report() -> void:
	print("RESULTS: %d checks, %d failures" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("FAIL " + failure)
	if _failures.is_empty():
		print("ALL PASS")


## 构造 Ray 命中事实（指定到达色）。
func _ray_hit(cell: Vector2i, color: int) -> _ObjectiveHitContext:
	return _ObjectiveHitContext.create_for_ray(cell, Vector2i(1, 0), 7, 3, color)


## 构造 Particle 命中事实（STANDARD 档）。
func _particle_hit(cell: Vector2i) -> _ObjectiveHitContext:
	return _ObjectiveHitContext.create_for_particle(cell, Vector2i(0, 1), 9, 4, 1)


## 1. 命中事实颜色域：RAY 携带真实四色可读回；PARTICLE 恒 NONE；非法值（NONE/越界/带色光粒）拒绝构造。
func _test_01_hit_context_color_domain() -> void:
	const NAME: String = "01_命中颜色域"
	var white: _ObjectiveHitContext = _ray_hit(Vector2i(2, 3), _RayColor.ColorValue.WHITE)
	var red: _ObjectiveHitContext = _ray_hit(Vector2i(2, 3), _RayColor.ColorValue.RED)
	var blue: _ObjectiveHitContext = _ray_hit(Vector2i(2, 3), _RayColor.ColorValue.BLUE)
	_check(NAME, white != null and white.get_color() == _RayColor.ColorValue.WHITE, "WHITE Ray 命中应构造且颜色可读回。")
	_check(NAME, red != null and red.get_color() == _RayColor.ColorValue.RED, "RED Ray 命中应构造且颜色可读回。")
	_check(NAME, blue != null and blue.get_color() == _RayColor.ColorValue.BLUE, "BLUE Ray 命中应构造且颜色可读回。")
	var particle: _ObjectiveHitContext = _particle_hit(Vector2i(2, 3))
	_check(NAME, particle != null and particle.get_color() == _RayColor.ColorValue.NONE, "PARTICLE 命中颜色恒为 NONE 哨兵。")
	_check(NAME, _ray_hit(Vector2i(2, 3), _RayColor.ColorValue.NONE) == null, "RAY 命中携带 NONE 应拒绝。")
	_check(NAME, _ray_hit(Vector2i(2, 3), 4) == null, "RAY 命中携带越界颜色 4 应拒绝。")


## 2. color_condition 配置域：红/绿/蓝合法；WHITE/NONE/越界拒绝；create() 旧入口不接受 color 类型。
func _test_02_color_configuration_domain() -> void:
	const NAME: String = "02_颜色配置域"
	for color: int in _ObjectiveConditionDefinition.get_valid_target_colors():
		var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create_for_color(color)
		_check(NAME, configuration != null and configuration.get_target_color() == color, "目标色 %d 应合法并可读回。" % color)
	_check(NAME, _ObjectiveConditionConfiguration.create_for_color(_RayColor.ColorValue.WHITE) == null, "WHITE 目标色应拒绝（白光不构成颜色条件）。")
	_check(NAME, _ObjectiveConditionConfiguration.create_for_color(_RayColor.ColorValue.NONE) == null, "NONE 目标色应拒绝。")
	_check(NAME, _ObjectiveConditionConfiguration.create_for_color(4) == null, "越界目标色 4 应拒绝。")
	_check(NAME, _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION, []) == null, "create() 旧入口不接受 color_condition（参数域不同）。")
	var definition: _ObjectiveConditionDefinition = _ObjectiveConditionDefinition.get_by_type_id(_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION)
	_check(NAME, definition != null and definition.get_param_ids() == [_ObjectiveConditionDefinition.PARAM_TARGET_COLOR], "注册表应含 color_condition 且参数为 target_color。")


## 3. 求值矩阵：目标=红；红命中满足，白/绿/蓝命中与 PARTICLE 命中均不满足（规则 §8 专属规则表）。
func _test_03_evaluator_matrix() -> void:
	const NAME: String = "03_求值矩阵"
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create_for_color(_RayColor.ColorValue.RED)
	var cell: Vector2i = Vector2i(0, 0)
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, _ray_hit(cell, _RayColor.ColorValue.RED)) == _ObjectiveConditionEvaluator.Verdict.SATISFIED, "红色 RAY 命中红目标应满足。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, _ray_hit(cell, _RayColor.ColorValue.WHITE)) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "白色 RAY 命中红目标应不满足。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, _ray_hit(cell, _RayColor.ColorValue.GREEN)) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "绿色 RAY 命中红目标应不满足。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, _ray_hit(cell, _RayColor.ColorValue.BLUE)) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "蓝色 RAY 命中红目标应不满足。")
	_check(NAME, _ObjectiveConditionEvaluator.evaluate(configuration, _particle_hit(cell)) == _ObjectiveConditionEvaluator.Verdict.NOT_SATISFIED, "PARTICLE 命中应不满足（光粒无颜色）。")


## 4. Target AND 组合：form(RAY)+color(红)；只有 RAY 且红色同时成立才通过。
func _test_04_target_and_semantics() -> void:
	const NAME: String = "04_Target组合"
	var conditions: Array = [
		_ObjectiveConditionConfiguration.create(
			_ObjectiveConditionDefinition.TYPE_FORM_CONDITION,
			[_LightEmissionTypes.LightForm.RAY]),
		_ObjectiveConditionConfiguration.create_for_color(_RayColor.ColorValue.RED),
	]
	var target: _ObjectiveTarget = _ObjectiveTarget.create(&"color_and", Vector2i(0, 0), true, conditions)
	_check(NAME, target != null, "form+color 组合目标应构造成功。")
	if target == null:
		return
	_check(NAME, target.evaluate_hit(_ray_hit(Vector2i(0, 0), _RayColor.ColorValue.RED)), "红色 RAY 应通过全部条件。")
	_check(NAME, not target.evaluate_hit(_ray_hit(Vector2i(0, 0), _RayColor.ColorValue.WHITE)), "白色 RAY 应被颜色条件拒绝。")
	_check(NAME, not target.evaluate_hit(_particle_hit(Vector2i(0, 0))), "PARTICLE 应被形态与颜色条件拒绝。")


## 5. meta 绑定 + Controller 点亮 / Reset：红/绿颜色水晶场景 + objective_conditions(target_color) meta → 模型绑定；
## 白色不点亮、目标色点亮、异色命中返回不通过、reset_runtime 后归零且可再次点亮（规则 §4/§6）。
func _test_05_meta_binding_and_light_up() -> void:
	const NAME: String = "05_meta绑定与点亮"
	var red_crystal: Variant = _ColorCrystalScene.instantiate()
	var green_crystal: Variant = _ColorCrystalScene.instantiate()
	red_crystal.crystal_id = &"color_red"
	green_crystal.crystal_id = &"color_green"
	# 单一正式项"光颜色水晶"：默认红；第二颗改绿（颜色字段 = RayColor.ColorValue 值）。
	_check(NAME, red_crystal.get("crystal_color") == _RayColor.ColorValue.RED, "光颜色水晶实例默认颜色应为红。")
	green_crystal.set("crystal_color", _RayColor.ColorValue.GREEN)
	_check(NAME, green_crystal.get("crystal_color") == _RayColor.ColorValue.GREEN, "光颜色水晶实例应可改为绿。")
	red_crystal.position = Vector2(96, 32)
	green_crystal.position = Vector2(96, 160)
	root.add_child(red_crystal)
	root.add_child(green_crystal)
	await process_frame
	var red_cell: Vector2i = red_crystal.cell
	var green_cell: Vector2i = green_crystal.cell
	if not _check(NAME, red_cell != green_cell, "两颗水晶格应不同（%s vs %s）。" % [red_cell, green_cell]):
		red_crystal.free()
		green_crystal.free()
		return
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	registry.register_crystal(&"color_red", red_cell, red_crystal)
	registry.register_crystal(&"color_green", green_cell, green_crystal)
	var level_root: Node = Node.new()
	level_root.set_meta("objective_conditions", {
		"color_red": [
			{"condition_type_id": "form_condition", "allowed_forms": [_LightEmissionTypes.LightForm.RAY]},
			{"condition_type_id": "color_condition", "target_color": _RayColor.ColorValue.RED},
		],
		"color_green": [
			{"condition_type_id": "color_condition", "target_color": _RayColor.ColorValue.GREEN},
		],
	})
	var model: Variant = _ObjectiveMetaReader.build_model(level_root, registry)
	_check(NAME, model != null, "含 color_condition 的 meta 应构造目标模型。")
	if model == null:
		level_root.free()
		red_crystal.free()
		green_crystal.free()
		return
	var controller: _ObjectiveController = _ObjectiveController.new(registry)
	controller.set_objective_model(model)
	# 白色 RAY 命中红水晶：不点亮（规则 §4-3）。
	_check(NAME, not controller.apply_hit(_ray_hit(red_cell, _RayColor.ColorValue.WHITE)), "白色 RAY 命中红目标应返回不通过。")
	_check(NAME, not red_crystal.is_activated, "白色 RAY 不应点亮红颜色水晶。")
	# 红色 RAY 命中红水晶：点亮（规则 §4-1）。
	_check(NAME, controller.apply_hit(_ray_hit(red_cell, _RayColor.ColorValue.RED)), "红色 RAY 命中红目标应通过。")
	_check(NAME, red_crystal.is_activated, "红色 RAY 应点亮红颜色水晶。")
	# 红色 RAY 命中绿水晶：不点亮（规则 §8 异色）；再被非目标色命中保持已点亮（规则 §4-5）。
	_check(NAME, not controller.apply_hit(_ray_hit(green_cell, _RayColor.ColorValue.RED)), "红色 RAY 命中绿目标应返回不通过。")
	_check(NAME, not green_crystal.is_activated, "红色 RAY 不应点亮绿颜色水晶。")
	_check(NAME, not controller.apply_hit(_ray_hit(red_cell, _RayColor.ColorValue.GREEN)), "已点亮后异色命中应返回不通过。")
	_check(NAME, red_crystal.is_activated, "已点亮水晶应保持点亮（边界 #5）。")
	# 绿色 RAY 命中绿水晶：点亮。
	_check(NAME, controller.apply_hit(_ray_hit(green_cell, _RayColor.ColorValue.GREEN)), "绿色 RAY 命中绿目标应通过。")
	_check(NAME, green_crystal.is_activated, "绿色 RAY 应点亮绿颜色水晶。")
	# Reset：两颗水晶归零、成功记录清空，且可再次完整点亮（规则 §6）。
	controller.reset_runtime()
	_check(NAME, not red_crystal.is_activated and not green_crystal.is_activated, "reset_runtime 后两颗水晶应归零。")
	_check(NAME, controller.apply_hit(_ray_hit(red_cell, _RayColor.ColorValue.RED)), "Reset 后红色 RAY 应可再次点亮红水晶。")
	_check(NAME, red_crystal.is_activated, "Reset 后应可再次点亮。")
	level_root.free()
	red_crystal.free()
	green_crystal.free()
	await process_frame


## 6. 传播到达色事实：RED 滤光片在 (2,3)；穿过后从下一格起 color=RED；水晶格 has_crystal 且携带到达色；
## 串联 GREEN 滤光片吸收红色光线（异色 BLOCK）。
func _test_06_propagation_arrival_color_facts() -> void:
	const NAME: String = "06_传播到达色"
	var world: Dictionary = _build_world([&"filter_2_3", &"filter_6_3"], {
		&"filter_2_3": Vector2i(2, 3),
		&"filter_6_3": Vector2i(6, 3),
	})
	# 场景默认 orientation=VERTICAL（薄膜面竖），RIGHT 入射穿过薄膜滤色。
	var placed: Dictionary = world["placed"]
	var red_filter: Variant = _LightFilterScene.instantiate()
	placed[&"filter_2_3"] = red_filter
	var green_filter: Variant = _LightFilterScene.instantiate()
	green_filter.set_color(2) # FilterColor.GREEN
	placed[&"filter_6_3"] = green_filter
	var crystal: Variant = _ColorCrystalScript.new()
	crystal.crystal_id = &"prop_crystal"
	crystal.set("crystal_color", _RayColor.ColorValue.BLUE)
	var registry: Variant = world["registry"]
	registry.register_crystal(&"prop_crystal", Vector2i(4, 3), crystal)

	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 3), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK, "红光线撞绿滤光片应 MECHANISM_BLOCK，实际 %s。" % [result.stop_reason])
	if _check(NAME, result.steps.size() >= 6, "steps 应覆盖 (1,3)..(6,3) 共 6 格，实际 %d。" % [result.steps.size()]):
		_check(NAME, result.steps[0].color == _RayColor.ColorValue.WHITE, "(1,3) 到达色应为 WHITE。")
		_check(NAME, result.steps[1].cell == Vector2i(2, 3) and result.steps[1].color == _RayColor.ColorValue.WHITE, "滤光片格 (2,3) 到达色应为 WHITE（换色从下一格生效）。")
		_check(NAME, result.steps[2].color == _RayColor.ColorValue.RED, "(3,3) 到达色应为 RED。")
		_check(NAME, result.steps[3].cell == Vector2i(4, 3) and result.steps[3].color == _RayColor.ColorValue.RED and result.steps[3].has_crystal, "水晶格 (4,3) 应携带 RED 到达色且 has_crystal。")
		_check(NAME, result.steps[5].cell == Vector2i(6, 3) and result.steps[5].color == _RayColor.ColorValue.RED, "绿滤光片格 (6,3) 应以 RED 到达（随后被吸收 BLOCK）。")
	red_filter.free()
	green_filter.free()
	crystal.free()


## 构造 10×10 只读查询门面（镜像 ray_execution_module_test._build_world；额外登记水晶与多机关占用）。
func _build_world(mechanism_ids: Array, mechanism_cells_by_id: Dictionary) -> Dictionary:
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	for index: int in mechanism_ids.size():
		occupancy.register_single_cell(mechanism_ids[index], mechanism_cells_by_id[mechanism_ids[index]])
	var placed: Dictionary = {}
	var lookup: _PlacedLookup = _PlacedLookup.new()
	lookup.placed = placed
	var walls: Array[Vector2i] = []
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10),
		walls,
		Vector2i(0, 3),
		registry,
		occupancy,
		Callable(lookup, "get_node")
	)
	var light_query: _LightWorldQuery = _LightWorldQuery.new(level_query)
	# lookup 必须随返回字典保留引用：Callable(lookup, ...) 不持有 RefCounted，否则离开作用域即回收（Callable 陷阱）。
	return {"query": light_query, "registry": registry, "placed": placed, "lookup": lookup}


## 机关节点只读查表桩（与 ray_execution_module_test 相同契约）。
class _PlacedLookup:
	var placed: Dictionary = {}

	func get_node(mechanism_id: StringName) -> Variant:
		if not placed.has(mechanism_id):
			return null
		return placed[mechanism_id]
