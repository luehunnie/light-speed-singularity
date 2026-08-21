extends SceneTree

## RayExecutionModule 定向自动测试（Day 1 D1-C）：只通过 execute() 公开静态入口观察行为，
## 覆盖五类停止条件与顺序保真——直线到边界、墙体停止、镜面转向、机关 BLOCK、最大步数、水晶逐格顺序。
## tests/unit 下 extends SceneTree 的 headless 脚本，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 关键边界：全部失败项收集后统一退出（任一失败 quit(1)）；镜面用场景 instantiate() 创建但不加入场景树，
## set_orientation() 在 ready 前调用时 _refresh_orientation_visual() 安全返回、字段仍写入；BLOCK 用 free() 释放镜面模拟“已登记但失效”；
## 每个用例独立构造 LevelWorldQuery 与 OccupancyRegistry，避免跨用例状态污染。


const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _SingleCellMirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_test_01_straight_to_bounds()
	_test_02_wall_stop()
	_test_03_mirror_redirect()
	_test_04_mechanism_block()
	_test_05_step_limit()
	_test_06_crystal_per_step_order()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一个 10×10 边界、给定墙体与水晶的只读光线查询门面，附带独立占用表与已放置机关映射。
## [br]wall_cells 为墙体格；crystals 为普通独立水晶数组（默认空，每颗须已配置非空 crystal_id）；返回 { query, occupancy, placed }，query 为 LightWorldQuery，调用方按需登记机关。
func _build_world(wall_cells: Array[Vector2i], crystals: Array[BasicCrystal] = []) -> Dictionary:
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	for crystal: BasicCrystal in crystals:
		registry.register_crystal(crystal.get_crystal_id(), crystal.cell, crystal)
	var placed: Dictionary[StringName, Variant] = {}
	var lookup: _PlacedLookup = _PlacedLookup.new()
	lookup.placed = placed
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10),
		wall_cells,
		Vector2i(0, 5),
		registry,
		occupancy,
		Callable(lookup, "get_node")
	)
	var light_query: _LightWorldQuery = _LightWorldQuery.new(level_query)
	return { "query": light_query, "occupancy": occupancy, "placed": placed, "lookup": lookup }


## 机关节点只读查表桩：供 LevelWorldQuery 的 get_placed_node_by_id Callable 解析 placed 字典，不暴露可写引用。
class _PlacedLookup:
	var placed: Dictionary[StringName, Variant] = {}
	func get_node(mechanism_id: StringName) -> Variant:
		if not placed.has(mechanism_id):
			return null
		return placed[mechanism_id]


## 1. 直线传播到边界：从 (0,5) 向右，无墙无机关，应进入 (1,5)..(9,5) 后在 (10,5) 越界停止。
func _test_01_straight_to_bounds() -> void:
	const NAME: String = "01_直线到边界"
	var world: Dictionary = _build_world([])
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS,
		"stop_reason 期望 OUT_OF_BOUNDS，实际 %s。" % [result.stop_reason])
	_check(NAME, result.reached_step_limit == false, "reached_step_limit 期望 false。")
	_check(NAME, result.steps.size() == 9,
		"steps 数期望 9，实际 %d。" % [result.steps.size()])
	if _check(NAME, result.steps.size() >= 1, "steps 非空才能校验末步。"):
		var last: Object = result.steps[result.steps.size() - 1]
		_check(NAME, last.cell == Vector2i(9, 5), "末步 cell 期望 (9,5)，实际 %s。" % [last.cell])
		_check(NAME, last.incoming_direction == Vector2i.RIGHT, "末步入射方向期望 RIGHT，实际 %s。" % [last.incoming_direction])
	# 无水晶路径：每步 has_crystal 必须为 false，确认字段存在且默认正确。
	for step: Object in result.steps:
		_check(NAME, step.has_crystal == false, "无水晶路径 has_crystal 期望 false，实际 %s @ %s。" % [step.has_crystal, step.cell])


## 2. 墙体停止：墙在 (5,5)，从 (0,5) 向右应进入 (1,5)..(4,5) 后在 (5,5) 墙体停止，墙格不进入结果。
func _test_02_wall_stop() -> void:
	const NAME: String = "02_墙体停止"
	var world: Dictionary = _build_world([Vector2i(5, 5)])
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.WALL,
		"stop_reason 期望 WALL，实际 %s。" % [result.stop_reason])
	_check(NAME, result.steps.size() == 4,
		"steps 数期望 4，实际 %d。" % [result.steps.size()])
	for step: Object in result.steps:
		_check(NAME, step.cell != Vector2i(5, 5), "墙格 (5,5) 不应进入 steps，实际包含。")


## 3. 镜面转向：(3,5) 放 SLASH 镜面，从 (0,5) 向右进入镜面格后入射 RIGHT 应反射为 UP，后续格子向上。
func _test_03_mirror_redirect() -> void:
	const NAME: String = "03_镜面转向"
	var world: Dictionary = _build_world([])
	var mirror: Variant = _SingleCellMirrorScene.instantiate()
	mirror.set_orientation(_SingleCellMirrorScript.MirrorOrientation.SLASH)
	var mirror_id: StringName = &"mirror_3_5"
	world["occupancy"].register_single_cell(mirror_id, Vector2i(3, 5))
	world["placed"][mirror_id] = mirror

	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	# SLASH 反射 RIGHT(1,0) → (-0,-1) = UP(0,-1)；光路：(1,5)(2,5)(3,5) 向右，(3,4)..(3,0) 向上，(3,-1) 越界。
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS,
		"stop_reason 期望 OUT_OF_BOUNDS，实际 %s。" % [result.stop_reason])
	_check(NAME, result.steps.size() == 8,
		"steps 数期望 8（3 向右 + 5 向上），实际 %d。" % [result.steps.size()])
	if _check(NAME, result.steps.size() >= 4, "steps 足够才能校验镜面格与转向后首步。"):
		var mirror_step: Object = result.steps[2]
		_check(NAME, mirror_step.cell == Vector2i(3, 5), "镜面格期望 (3,5)，实际 %s。" % [mirror_step.cell])
		_check(NAME, mirror_step.incoming_direction == Vector2i.RIGHT, "镜面格入射方向期望 RIGHT，实际 %s。" % [mirror_step.incoming_direction])
		var after_step: Object = result.steps[3]
		_check(NAME, after_step.cell == Vector2i(3, 4), "转向后首步期望 (3,4)，实际 %s。" % [after_step.cell])
		_check(NAME, after_step.incoming_direction == Vector2i.UP, "转向后首步入射方向期望 UP，实际 %s。" % [after_step.incoming_direction])
	mirror.free()


## 4. 机关 BLOCK：(3,5) 占用指向一个非 Object 的 Variant（如 Dictionary），Adapter is_instance_valid 为 false 且非 null → BLOCK，
## 光应进入 (1,5)(2,5)(3,5) 后停止。该路径对应旧循环 reflected_direction == Vector2i.ZERO 的 break，复现 Adapter 既有 BLOCK 分支。
func _test_04_mechanism_block() -> void:
	const NAME: String = "04_机关BLOCK"
	var world: Dictionary = _build_world([])
	var mirror_id: StringName = &"mirror_block"
	world["occupancy"].register_single_cell(mirror_id, Vector2i(3, 5))
	# 非 Object、非 null 的 Variant：Adapter 先排除 null，再 is_instance_valid 为 false → BLOCK（对应旧代码节点失效分支）。
	world["placed"][mirror_id] = {}

	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK,
		"stop_reason 期望 MECHANISM_BLOCK，实际 %s。" % [result.stop_reason])
	_check(NAME, result.reached_step_limit == false, "reached_step_limit 期望 false。")
	_check(NAME, result.steps.size() == 3,
		"steps 数期望 3（含 BLOCK 格），实际 %d。" % [result.steps.size()])
	if _check(NAME, result.steps.size() >= 1, "steps 非空才能校验末步。"):
		var last: Object = result.steps[result.steps.size() - 1]
		_check(NAME, last.cell == Vector2i(3, 5), "末步应为 BLOCK 格 (3,5)，实际 %s。" % [last.cell])


## 5. 最大步数停止：max_steps=3，从 (0,5) 向右应进入 3 格后触顶，stop_reason=STEP_LIMIT。
func _test_05_step_limit() -> void:
	const NAME: String = "05_最大步数"
	var world: Dictionary = _build_world([])
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 3, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.STEP_LIMIT,
		"stop_reason 期望 STEP_LIMIT，实际 %s。" % [result.stop_reason])
	_check(NAME, result.reached_step_limit == true, "reached_step_limit 期望 true。")
	_check(NAME, result.steps.size() == 3,
		"steps 数期望 3，实际 %d。" % [result.steps.size()])


## 6. 水晶格标记与逐格顺序：水晶在 (3,5)，从 (0,5) 向右应进入 9 格后越界停止；
## steps 必须按进入顺序排列，且只有水晶格 has_crystal 为 true，其余为 false——确认应用数据逐格有序表达。
## [br]本用例只验证结果数据形态，不创建场景树、不调用 activate()、不验证水晶激活副作用。
func _test_06_crystal_per_step_order() -> void:
	const NAME: String = "06_水晶逐格顺序"
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = Vector2i(3, 5)
	crystal.crystal_id = &"crystal_3_5"
	var crystals: Array[BasicCrystal] = [crystal]
	var world: Dictionary = _build_world([], crystals)
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"], 7, 1
	)
	_check(NAME, result.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS,
		"stop_reason 期望 OUT_OF_BOUNDS，实际 %s。" % [result.stop_reason])
	_check(NAME, result.steps.size() == 9,
		"steps 数期望 9，实际 %d。" % [result.steps.size()])
	# 两格子路径逐格有序：steps[1]=(2,5) 无水晶 → steps[2]=(3,5) 有水晶 → steps[3]=(4,5) 无水晶。
	if _check(NAME, result.steps.size() >= 4, "steps 足够才能校验水晶格前后顺序。"):
		var before: Object = result.steps[1]
		var at: Object = result.steps[2]
		var after: Object = result.steps[3]
		_check(NAME, before.cell == Vector2i(2, 5), "水晶格前一步期望 (2,5)，实际 %s。" % [before.cell])
		_check(NAME, before.has_crystal == false, "水晶格前一步 has_crystal 期望 false，实际 %s。" % [before.has_crystal])
		_check(NAME, at.cell == Vector2i(3, 5), "水晶格期望 (3,5)，实际 %s。" % [at.cell])
		_check(NAME, at.has_crystal == true, "水晶格 has_crystal 期望 true，实际 %s。" % [at.has_crystal])
		_check(NAME, after.cell == Vector2i(4, 5), "水晶格后一步期望 (4,5)，实际 %s。" % [after.cell])
		_check(NAME, after.has_crystal == false, "水晶格后一步 has_crystal 期望 false，实际 %s。" % [after.has_crystal])
	# 全路径只有水晶格 has_crystal 为 true，确认字段逐格表达且无重复事实。
	var true_count: int = 0
	for step: Object in result.steps:
		if step.has_crystal:
			true_count += 1
	_check(NAME, true_count == 1, "全路径 has_crystal==true 的步数期望 1，实际 %d。" % [true_count])
	crystal.free()


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== RayExecutionModule D1-C 测试摘要 ====")
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
