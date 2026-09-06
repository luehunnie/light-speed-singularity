extends SceneTree

## C-09 分光器消耗式分光契约测试（Q53 冻结裁决）。
## 覆盖：
##   F1 契约扩展——validate() 允许 BLOCK 携带 spawned_branches 的合法域与非法域（冻结语义不得破坏）；
##   F2 执行链——RayExecutionModule 在 BLOCK 时收集分支 + 继承色盖章 + 普通 BLOCK 机关零影响回归。
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
	_test_01_block_branch_contract_legal()
	_test_02_block_branch_contract_illegal()
	_test_03_block_branch_collection_and_color()
	_test_04_plain_block_no_branch_regression()
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


## 伪造契约机关：RAY 形态声明，interact_ray 返回预置 Result 并计数调用。
class _Mechanism extends RefCounted:
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


## 占用表保活（测试进程内防止提前回收）。
var _occupancy_ref: _OccupancyRegistry = null
func _occupancy_hold(occupancy: _OccupancyRegistry) -> void:
	_occupancy_ref = occupancy


## F1-合法：BLOCK 携带 spawned_branches 在 RAY 形态下 validate 通过；分支字段读回正确。
func _test_01_block_branch_contract_legal() -> void:
	const G: String = "01_BLOCK分支合法"
	var r: _Result = _Result.block_result()
	r.add_spawned_branch(Vector2i(3, 3), Vector2i(0, -1))
	r.add_spawned_branch(Vector2i(3, 3), Vector2i(0, 1))
	_check(G, r.decision == _Result.Decision.BLOCK, "decision 应为 BLOCK。")
	_check(G, r.validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"BLOCK 携带 2 分支在 RAY 形态下 validate 应通过（Q53 新行为）。")
	_check(G, r.spawned_branches.size() == 2, "分支数应读回 2。")
	if r.spawned_branches.size() == 2:
		var b0: Variant = r.spawned_branches[0]
		var b1: Variant = r.spawned_branches[1]
		_check(G, b0.source_cell == Vector2i(3, 3) and b0.direction == Vector2i(0, -1), "分支 0 位置方向应读回。")
		_check(G, b1.direction == Vector2i(0, 1), "分支 1 方向应读回。")
		_check(G, b0.color == _RayColor.ColorValue.NONE and b1.color == _RayColor.ColorValue.NONE,
			"分支 color 机关侧构造恒 NONE。")


## F1-非法域：冻结语义不得破坏——PARTICLE / 非法方向 / 非 NONE 色 / FORM_CHANGE / REDIRECT_CROSS 携带分支仍拒绝。
func _test_02_block_branch_contract_illegal() -> void:
	const G: String = "02_BLOCK分支非法域"
	var part: _Result = _Result.block_result()
	part.add_spawned_branch(Vector2i(2, 2), Vector2i(0, 1))
	_check(G, not part.validate(_LightEmissionTypes.LightForm.PARTICLE).is_empty(),
		"BLOCK 携带分支在 PARTICLE 形态应被拒绝（分支仅 RAY）。")
	var bad_dir: _Result = _Result.block_result()
	bad_dir.add_spawned_branch(Vector2i(2, 2), Vector2i(2, 0))
	_check(G, not bad_dir.validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"BLOCK 分支非法方向应被拒绝。")
	var colored: _Result = _Result.block_result()
	colored.spawned_branches.append(_Result.make_branch_spec(Vector2i(2, 2), Vector2i(0, 1), 1))
	_check(G, not colored.validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"BLOCK 分支携带非 NONE 色应被拒绝（色由执行层盖章）。")
	var fc: _Result = _Result.form_change_result(1, Vector2i(1, 0))
	fc.add_spawned_branch(Vector2i(2, 2), Vector2i(0, 1))
	_check(G, not fc.validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"FORM_CHANGE 携带分支应仍被拒绝（回归）。")
	var rc: _Result = _Result.redirect_cross_result(Vector2i(0, -1), Vector2i(1, 0))
	rc.add_spawned_branch(Vector2i(2, 2), Vector2i(0, 1))
	_check(G, not rc.validate(_LightEmissionTypes.LightForm.RAY).is_empty(),
		"REDIRECT_CROSS 携带分支应仍被拒绝（回归）。")


## F2：BLOCK 分支收集——伪造机关返回 BLOCK + 2 分支，执行后收集分支并盖章继承色。
func _test_03_block_branch_collection_and_color() -> void:
	const G: String = "03_BLOCK收集分支"
	var world := _build_world([])
	var mech: _Mechanism = _Mechanism.new()
	var interaction: _Result = _Result.block_result()
	interaction.add_spawned_branch(Vector2i(4, 5), Vector2i(0, -1))
	interaction.add_spawned_branch(Vector2i(6, 5), Vector2i(0, -1))
	mech.result = interaction
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), mech, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3, _RayColor.ColorValue.RED)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK,
		"BLOCK 分光器应 MECHANISM_BLOCK 停止。")
	_check(G, result.spawned_branches.size() == 2,
		"应收集 2 条分支，实际 %d。" % result.spawned_branches.size())
	if result.spawned_branches.size() == 2:
		var b0: Variant = result.spawned_branches[0]
		var b1: Variant = result.spawned_branches[1]
		_check(G, b0.source_cell == Vector2i(4, 5) and b0.direction == Vector2i(0, -1),
			"分支 0 位置方向应原样透传。")
		_check(G, b1.source_cell == Vector2i(6, 5) and b1.direction == Vector2i(0, -1),
			"分支 1 位置方向应原样透传。")
		_check(G, b0.color == _RayColor.ColorValue.RED and b1.color == _RayColor.ColorValue.RED,
			"分支应盖章继承当前到达色 RED。")


## F2 回归：普通 BLOCK 机关（无分支）spawned_branches 恒空，A2 改动零影响。
func _test_04_plain_block_no_branch_regression() -> void:
	const G: String = "04_普通BLOCK零影响"
	var world := _build_world([])
	var mech: _Mechanism = _Mechanism.new()
	mech.result = _Result.block_result()
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), mech, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK,
		"普通 BLOCK 应 MECHANISM_BLOCK 停止。")
	_check(G, result.spawned_branches.is_empty(),
		"普通 BLOCK 无分支，spawned_branches 应空。")


func _report() -> void:
	print("C-09 block-branch split contract: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
