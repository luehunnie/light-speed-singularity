extends SceneTree

## C-08 REDIRECT_CROSS 契约 + Ray 执行定向测试。
## 覆盖：redirect_cross_result 构造与合法校验（RAY/PARTICLE 两形态）、非法域拒绝（方向/正交/互斥/分支约束）、
##   BranchSpec 工厂与继承盖章；RayExecutionModule 穿邻格透明步进（路径记录、同机关不重复触发、
##   跨界格墙体/越界对称停止）、分光分支载荷收集与颜色盖章。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _Result: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_redirect_cross_contract_legal()
	_test_02_redirect_cross_contract_illegal()
	_test_03_ray_cross_cell_transparent_step()
	_test_04_cross_cell_wall_and_bounds()
	_test_05_branch_collection_and_color_inheritance()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, cond: bool, why: String) -> void:
	_checks += 1
	if not cond:
		_failures.append("[%s] %s" % [group, why])


## 构造 10×10 只读光线查询门面（与 ray_execution_module_test 同构）。
## [br]注意 Callable 不保留 RefCounted：_Lookup 实例由本测试成员表持有，防止 Callable 单引用下被提前回收。
var _lookups: Array = []

func _build_world(wall_cells: Array[Vector2i]) -> Dictionary:
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var placed: Dictionary[StringName, Variant] = {}
	var lookup: _Lookup = _Lookup.new()
	lookup.placed = placed
	_lookups.append(lookup)
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10), wall_cells, Vector2i(0, 5), registry, occupancy,
		Callable(lookup, "get_node"))
	return { "query": _LightWorldQuery.new(level_query), "placed": placed, "occupancy": occupancy }


class _Lookup:
	var placed: Dictionary[StringName, Variant]
	func get_node(mechanism_id: StringName) -> Variant:
		return placed.get(mechanism_id, null)


## 伪造契约机关：RAY 形态声明，interact_ray 返回预置 Result 并计数调用（观察同机关不重复触发）。
class _CrossMechanism extends RefCounted:
	var result: Variant = null
	var ray_calls: int = 0
	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY"]
	func interact_ray(_ray_context: Variant) -> Variant:
		ray_calls += 1
		return result


## 把机关登记进世界占用并放入 placed 查表（双事实与正式运行一致）。
func _register_mechanism(world: Dictionary, occupancy: _OccupancyRegistry, cell: Vector2i, mech: Variant, id: StringName) -> void:
	occupancy.register_single_cell(id, cell)
	world.placed[id] = mech


## 1. REDIRECT_CROSS 合法构造与校验：字段读回、两形态 validate 均空、分光器默认朝向接口默认值。
func _test_01_redirect_cross_contract_legal() -> void:
	const G: String = "01_CROSS契约合法"
	var r: _Result = _Result.redirect_cross_result(Vector2i(0, -1), Vector2i(1, 0))
	_check(G, r.decision == _Result.Decision.REDIRECT_CROSS, "decision 应为 REDIRECT_CROSS。")
	_check(G, r.redirect_direction == Vector2i(0, -1), "redirect_direction 应读回 (0,-1)。")
	_check(G, r.cross_direction == Vector2i(1, 0), "cross_direction 应读回 (1,0)。")
	_check(G, r.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "RAY 形态 validate 应无问题。")
	_check(G, r.validate(_LightEmissionTypes.LightForm.PARTICLE).is_empty(), "PARTICLE 形态 validate 应无问题（Particle 同语义消费）。")
	_check(G, _Result.DEFAULT_SPLITTER_ORIENTATION == Vector2i.RIGHT, "分光器默认朝向接口默认值应为 RIGHT。")
	var spec: Variant = _Result.make_branch_spec(Vector2i(3, 4), Vector2i(0, 1), -1)
	_check(G, spec.source_cell == Vector2i(3, 4) and spec.direction == Vector2i(0, 1), "BranchSpec 工厂应原样读回位置与方向。")
	_check(G, spec.color == -1, "BranchSpec.color 工厂应原样读回（机关侧恒 NONE）。")


## 2. REDIRECT_CROSS 非法域拒绝：非法改向 / 非正交跨界 / 零跨界 / 互斥与分支约束。
func _test_02_redirect_cross_contract_illegal() -> void:
	const G: String = "02_CROSS契约非法"
	_check(G, not _Result.redirect_cross_result(Vector2i(2, 0), Vector2i(1, 0)).validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"非法八方向改向应被拒绝。")
	_check(G, not _Result.redirect_cross_result(Vector2i(1, 0), Vector2i(1, 1)).validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"非正交 cross_direction 应被拒绝。")
	_check(G, not _Result.redirect_cross_result(Vector2i(1, 0), Vector2i.ZERO).validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"ZERO cross_direction 应被拒绝。")
	var cont: _Result = _Result.continue_result()
	cont.cross_direction = Vector2i(1, 0)
	_check(G, not cont.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "非 REDIRECT_CROSS 携带 cross_direction 应被拒绝（互斥）。")
	var fc: _Result = _Result.form_change_result(1, Vector2i(1, 0))
	fc.add_spawned_branch(Vector2i(2, 2), Vector2i(0, 1))
	_check(G, not fc.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "FORM_CHANGE 携带分支应被拒绝。")
	var part: _Result = _Result.continue_result()
	part.add_spawned_branch(Vector2i(2, 2), Vector2i(0, 1))
	_check(G, not part.validate(_LightEmissionTypes.LightForm.PARTICLE).is_empty(), "PARTICLE 形态携带分支应被拒绝（分支仅 RAY）。")
	var bad_dir: _Result = _Result.continue_result()
	bad_dir.add_spawned_branch(Vector2i(2, 2), Vector2i(2, 0))
	_check(G, not bad_dir.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "分支非法方向应被拒绝。")
	var colored: _Result = _Result.continue_result()
	colored.spawned_branches.append(_Result.make_branch_spec(Vector2i(2, 2), Vector2i(0, 1), 1))
	_check(G, not colored.validate(_LightEmissionTypes.LightForm.RAY).is_empty(), "分支携带非 NONE 色应被拒绝（色由执行层盖章）。")


## 3. Ray 穿邻格透明步进：机关格记录 → 跨界格记录（入射=跨界方向）→ 沿改向继续；同机关只触发一次。
func _test_03_ray_cross_cell_transparent_step() -> void:
	const G: String = "03_Ray透明跨格"
	var world := _build_world([])
	var occupancy: _OccupancyRegistry = world.occupancy
	_occupancy_hold(occupancy)
	var mech: _CrossMechanism = _CrossMechanism.new()
	mech.result = _Result.redirect_cross_result(Vector2i(0, -1), Vector2i(1, 0))
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), mech, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3)
	_check(G, mech.ray_calls == 1, "同机关跨格不得重复触发（应恰 1 次 interact_ray）。")
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "跨界后上行应最终越界停止。")
	_check(G, result.steps.size() == 11, "路径应含直行 5 格+跨界格+上行 5 格共 11 步，实际 %d。" % result.steps.size())
	_check(G, result.steps[4].cell == Vector2i(5, 5) and result.steps[4].incoming_direction == Vector2i(1, 0),
		"第 5 步应为机关格 (5,5) 原入射。")
	_check(G, result.steps[5].cell == Vector2i(6, 5) and result.steps[5].incoming_direction == Vector2i(1, 0),
		"第 6 步应为跨界格 (6,5)，入射=跨界方向。")
	_check(G, result.steps[6].cell == Vector2i(6, 4) and result.steps[6].incoming_direction == Vector2i(0, -1),
		"第 7 步应沿改向 (0,-1) 到 (6,4)。")


## 4. 跨界格墙体 / 越界对称停止：跨界格不入路径，机关格已记录，停止原因与普通步进同形。
func _test_04_cross_cell_wall_and_bounds() -> void:
	const G: String = "04_跨界格停止"
	var world := _build_world([Vector2i(6, 5)])
	var mech: _CrossMechanism = _CrossMechanism.new()
	mech.result = _Result.redirect_cross_result(Vector2i(0, -1), Vector2i(1, 0))
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), mech, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.WALL, "跨界格墙体应 WALL 停止。")
	_check(G, result.steps.size() == 5 and result.steps[4].cell == Vector2i(5, 5), "跨界格不路径化，直行 4 格+机关格共 5 步。")
	var world2 := _build_world([])
	var mech2: _CrossMechanism = _CrossMechanism.new()
	mech2.result = _Result.redirect_cross_result(Vector2i(0, -1), Vector2i(1, 0))
	_register_mechanism(world2, world2.occupancy, Vector2i(9, 5), mech2, &"m2")
	var result2: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world2.query, 8, 3)
	_check(G, result2.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "跨界格越界应越界停止。")
	_check(G, result2.steps.size() == 9 and result2.steps[8].cell == Vector2i(9, 5), "越界跨界格不入路径，直行至机关格共 9 步。")


## 5. 分光分支收集与颜色继承：CONTINUE 携带分支经适配链透传，执行层按当前到达色盖章。
func _test_05_branch_collection_and_color_inheritance() -> void:
	const G: String = "05_分支继承"
	var world := _build_world([])
	var mech: _CrossMechanism = _CrossMechanism.new()
	var interaction: _Result = _Result.continue_result()
	interaction.add_spawned_branch(Vector2i(5, 5), Vector2i(0, -1))
	interaction.add_spawned_branch(Vector2i(5, 5), Vector2i(0, 1))
	mech.result = interaction
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), mech, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3, _RayColor.ColorValue.RED)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "CONTINUE 分支机关应照常传播至越界。")
	_check(G, result.spawned_branches.size() == 2, "应收集 2 条分支，实际 %d。" % result.spawned_branches.size())
	if result.spawned_branches.size() == 2:
		var b0: Variant = result.spawned_branches[0]
		var b1: Variant = result.spawned_branches[1]
		_check(G, b0.direction == Vector2i(0, -1) and b0.source_cell == Vector2i(5, 5), "分支 0 位置方向应原样透传。")
		_check(G, b1.direction == Vector2i(0, 1), "分支 1 方向应原样透传。")
		_check(G, b0.color == _RayColor.ColorValue.RED and b1.color == _RayColor.ColorValue.RED,
			"分支应盖章继承当前到达色 RED。")


## 占用表保活（测试进程内防止提前回收）。
var _occupancy_ref: _OccupancyRegistry = null
func _occupancy_hold(occupancy: _OccupancyRegistry) -> void:
	_occupancy_ref = occupancy


func _report() -> void:
	print("C-08 redirect_cross contract/ray: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
