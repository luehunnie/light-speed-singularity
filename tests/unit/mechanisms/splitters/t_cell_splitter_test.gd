extends SceneTree

## 四格T型分光器 判定逻辑与契约回归测试（C-09 内容批次；机关规则 四格T型分光器 v0.1）。
## 覆盖：
##   A 脚本接口——可实例化、继承 PlaceableToken、默认朝向 RIGHT、四朝向 4 格 T 形 footprint、RAY+PARTICLE 形态声明。
##   B 判定纯函数 resolve_interaction——四朝向分光 + 非法方向/反向/侧面/斜向/支格命中全 BLOCK。
##   C interact_ray 正式入口——四朝向分光（BLOCK + 3 分支：前进 + 左旋 + 右旋，color 恒 NONE）；
##     非法命中 → 纯 BLOCK（无分支）；interact_particle 恒 BLOCK。
##   D 端到端——真实 TCellSplitter 走 RayExecutionModule.execute，BLOCK 收集 3 分支 + 继承色盖章（Q53）。
##   E Definition 发现——FormalContentDiscovery 扫描真实 definitions 目录发现 t_cell_splitter 且校验通过。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _TCellSplitter: GDScript = preload(
	"res://gameplay/mechanisms/splitters/t_cell_splitter.gd"
)
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _RayInteractionContext: GDScript = preload(
	"res://gameplay/light/interaction/ray_interaction_context.gd"
)
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _Discovery: GDScript = preload("res://gameplay/content/formal_content_discovery.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_A01_script_interface()
	_test_A02_default_orientation_right()
	_test_A03_footprint_four_orientations()
	_test_A04_forms_declaration()
	_test_B01_resolve_interaction_table()
	_test_C01_interact_ray_four_orientations()
	_test_C02_interact_ray_illegal_block()
	_test_D01_end_to_end_branch_collection()
	_test_E01_definition_discovery()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, cond: bool, why: String) -> bool:
	_checks += 1
	if not cond:
		_failures.append("[%s] %s" % [group, why])
	return cond


# ===== A 脚本与接口 =====

func _test_A01_script_interface() -> void:
	const G: String = "A01_脚本可实例化且接口完整"
	var m: Variant = _TCellSplitter.new()
	if _check(G, m != null, "t_cell_splitter.gd 实例化失败。"):
		_check(G, m is PlaceableToken, "应继承 PlaceableToken。")
		_check(G, m.has_method("interact_ray"), "应具备 interact_ray。")
		_check(G, m.has_method("interact_particle"), "应具备 interact_particle。")
		_check(G, m.has_method("get_occupied_offsets"), "应具备 get_occupied_offsets。")
		_check(G, m.has_method("set_orientation"), "应具备 set_orientation。")
		_check(G, m.has_method("toggle_orientation"), "应具备 toggle_orientation。")
		_check(G, m.has_method("apply_configuration"), "应具备 apply_configuration。")
		_check(G, m.has_method("get_light_interaction_forms"), "应具备 get_light_interaction_forms。")
		_check(G, "orientation" in m, "应具备 orientation 事实字段。")
		m.free()


func _test_A02_default_orientation_right() -> void:
	const G: String = "A02_默认朝向RIGHT"
	var m: Variant = _TCellSplitter.new()
	_check(G, m.orientation == _TCellSplitter.SplitterOrientation.RIGHT,
		"默认 orientation 期望 RIGHT，实际 %s。" % [m.orientation])
	m.free()


## A03. 四朝向 4 格 T 形 footprint（前进 + 左旋 + 中间 + 右旋，读自身 orientation）。
func _test_A03_footprint_four_orientations() -> void:
	const G: String = "A03_四朝向footprint"
	var m: Variant = _TCellSplitter.new()
	m.set_orientation(_TCellSplitter.SplitterOrientation.RIGHT)
	_check(G, m.get_occupied_offsets() == [Vector2i(1, 0), Vector2i(0, 1), Vector2i.ZERO, Vector2i(0, -1)],
		"RIGHT 期望 [(1,0),(0,1),(0,0),(0,-1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TCellSplitter.SplitterOrientation.DOWN)
	_check(G, m.get_occupied_offsets() == [Vector2i(0, 1), Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)],
		"DOWN 期望 [(0,1),(-1,0),(0,0),(1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TCellSplitter.SplitterOrientation.LEFT)
	_check(G, m.get_occupied_offsets() == [Vector2i(-1, 0), Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)],
		"LEFT 期望 [(-1,0),(0,-1),(0,0),(0,1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TCellSplitter.SplitterOrientation.UP)
	_check(G, m.get_occupied_offsets() == [Vector2i(0, -1), Vector2i(1, 0), Vector2i.ZERO, Vector2i(-1, 0)],
		"UP 期望 [(0,-1),(1,0),(0,0),(-1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.free()


func _test_A04_forms_declaration() -> void:
	const G: String = "A04_声明RAY与PARTICLE"
	var m: Variant = _TCellSplitter.new()
	var forms: Array = m.get_light_interaction_forms()
	_check(G, &"RAY" in forms and &"PARTICLE" in forms, "应声明 RAY 与 PARTICLE，实际 %s。" % [forms])
	m.free()


# ===== B 判定纯函数 =====

func _test_B01_resolve_interaction_table() -> void:
	const G: String = "B01_判定速查表"
	var RIGHT: int = _TCellSplitter.SplitterOrientation.RIGHT
	var DOWN: int = _TCellSplitter.SplitterOrientation.DOWN
	var LEFT: int = _TCellSplitter.SplitterOrientation.LEFT
	var UP: int = _TCellSplitter.SplitterOrientation.UP
	var cases: Array = [
		# 四朝向分光（中间格 + 输入方向）
		[RIGHT, Vector2i.ZERO, Vector2i(1, 0), true],
		[DOWN, Vector2i.ZERO, Vector2i(0, 1), true],
		[LEFT, Vector2i.ZERO, Vector2i(-1, 0), true],
		[UP, Vector2i.ZERO, Vector2i(0, -1), true],
		# 反向
		[UP, Vector2i.ZERO, Vector2i(0, 1), false],
		[RIGHT, Vector2i.ZERO, Vector2i(-1, 0), false],
		# 侧面（正交但非输入/反向）
		[UP, Vector2i.ZERO, Vector2i(1, 0), false],
		[UP, Vector2i.ZERO, Vector2i(-1, 0), false],
		# 斜向
		[UP, Vector2i.ZERO, Vector2i(1, 1), false],
		[UP, Vector2i.ZERO, Vector2i(-1, -1), false],
		# 支格命中（cell_offset != ZERO，含前进支/侧支格）
		[UP, Vector2i(0, -1), Vector2i(0, -1), false],
		[UP, Vector2i(-1, 0), Vector2i(0, -1), false],
		[UP, Vector2i(1, 0), Vector2i(0, -1), false],
		# 非法方向
		[UP, Vector2i.ZERO, Vector2i.ZERO, false],
		[UP, Vector2i.ZERO, Vector2i(2, 0), false],
	]
	for c: Array in cases:
		var res: Variant = _TCellSplitter.resolve_interaction(c[0], c[1], c[2])
		_check(G, res.split == c[3],
			"orientation=%d offset=%s dir=%s => split=%s（期望 %s）" % [c[0], c[1], c[2], res.split, c[3]])


# ===== C interact_ray 正式入口 =====

## C01. 四朝向分光：BLOCK + 3 分支（前进 + 左旋 + 右旋），源格/方向正确，color 恒 NONE。
func _test_C01_interact_ray_four_orientations() -> void:
	const G: String = "C01_四朝向分光"
	var RIGHT: int = _TCellSplitter.SplitterOrientation.RIGHT
	var DOWN: int = _TCellSplitter.SplitterOrientation.DOWN
	var LEFT: int = _TCellSplitter.SplitterOrientation.LEFT
	var UP: int = _TCellSplitter.SplitterOrientation.UP
	# [orientation, input, b0_cell, b0_dir, b1_cell, b1_dir, b2_cell, b2_dir]（anchor 恒 (2,2)）
	var cases: Array = [
		[RIGHT, Vector2i(1, 0), Vector2i(3, 2), Vector2i(1, 0), Vector2i(2, 3), Vector2i(0, 1), Vector2i(2, 1), Vector2i(0, -1)],
		[DOWN, Vector2i(0, 1), Vector2i(2, 3), Vector2i(0, 1), Vector2i(1, 2), Vector2i(-1, 0), Vector2i(3, 2), Vector2i(1, 0)],
		[LEFT, Vector2i(-1, 0), Vector2i(1, 2), Vector2i(-1, 0), Vector2i(2, 1), Vector2i(0, -1), Vector2i(2, 3), Vector2i(0, 1)],
		[UP, Vector2i(0, -1), Vector2i(2, 1), Vector2i(0, -1), Vector2i(3, 2), Vector2i(1, 0), Vector2i(1, 2), Vector2i(-1, 0)],
	]
	for c: Array in cases:
		var m: Variant = _TCellSplitter.new()
		m.set_cell(Vector2i(2, 2))
		m.set_orientation(c[0])
		var ctx: Variant = _RayInteractionContext.create(Vector2i(2, 2), c[1], 1, 1)
		var r: Variant = m.interact_ray(ctx)
		var ok: bool = r.decision == _LightInteractionResult.Decision.BLOCK
		ok = ok and r.spawned_branches.size() == 3
		if r.spawned_branches.size() == 3:
			ok = ok and r.spawned_branches[0].source_cell == c[2] and r.spawned_branches[0].direction == c[3]
			ok = ok and r.spawned_branches[1].source_cell == c[4] and r.spawned_branches[1].direction == c[5]
			ok = ok and r.spawned_branches[2].source_cell == c[6] and r.spawned_branches[2].direction == c[7]
			ok = ok and r.spawned_branches[0].color == _RayColor.ColorValue.NONE
			ok = ok and r.spawned_branches[1].color == _RayColor.ColorValue.NONE
			ok = ok and r.spawned_branches[2].color == _RayColor.ColorValue.NONE
		_check(G, ok,
			"朝向 %d 分光不正确：decision=%d branches=%s（期望 BLOCK + 3 分支）"
			% [c[0], r.decision, _branch_summary(r)])
		m.free()


## C02. 非法命中 → 纯 BLOCK（无分支）；interact_particle 恒 BLOCK。
func _test_C02_interact_ray_illegal_block() -> void:
	const G: String = "C02_非法命中BLOCK"
	var m: Variant = _TCellSplitter.new()
	m.set_cell(Vector2i(2, 2))
	m.set_orientation(_TCellSplitter.SplitterOrientation.UP)
	var illegals: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1)]
	for dir: Vector2i in illegals:
		var ctx: Variant = _RayInteractionContext.create(Vector2i(2, 2), dir, 1, 1)
		var r: Variant = m.interact_ray(ctx)
		_check(G, r.decision == _LightInteractionResult.Decision.BLOCK and r.spawned_branches.is_empty(),
			"命中中间格但方向 %s 应纯 BLOCK（无分支），实际 decision=%d branches=%d。" % [dir, r.decision, r.spawned_branches.size()])
	# 前进支格命中（光到达 (2,1)，方向 (0,-1)）
	var ctx2: Variant = _RayInteractionContext.create(Vector2i(2, 1), Vector2i(0, -1), 1, 1)
	var r2: Variant = m.interact_ray(ctx2)
	_check(G, r2.decision == _LightInteractionResult.Decision.BLOCK and r2.spawned_branches.is_empty(),
		"支格命中应纯 BLOCK（无分支），实际 decision=%d branches=%d。" % [r2.decision, r2.spawned_branches.size()])
	# 光粒恒 BLOCK
	var pr: Variant = m.interact_particle(null)
	_check(G, pr.decision == _LightInteractionResult.Decision.BLOCK, "interact_particle 应恒 BLOCK。")
	m.free()


# ===== D 端到端 =====

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


func _register_mechanism(world: Dictionary, occupancy: _OccupancyRegistry, cell: Vector2i, mech: Variant, id: StringName) -> void:
	occupancy.register_single_cell(id, cell)
	world.placed[id] = mech


var _occupancy_ref: _OccupancyRegistry = null
func _occupancy_hold(occupancy: _OccupancyRegistry) -> void:
	_occupancy_ref = occupancy


## D01. 真实分光器走完整传播链：BLOCK 收集 3 分支 + 继承色盖章（Q53 消耗式分光端到端）。
func _test_D01_end_to_end_branch_collection() -> void:
	const G: String = "D01_端到端分支收集"
	var world := _build_world([])
	_occupancy_hold(world.occupancy)
	var splitter: Variant = _TCellSplitter.new()
	splitter.set_cell(Vector2i(5, 5))  # 默认 RIGHT（输入 (1,0)）
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), splitter, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3, _RayColor.ColorValue.RED)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK,
		"分光器应 MECHANISM_BLOCK 停止。")
	_check(G, result.spawned_branches.size() == 3,
		"应收集 3 分支，实际 %d。" % result.spawned_branches.size())
	if result.spawned_branches.size() == 3:
		var b0: Variant = result.spawned_branches[0]
		var b1: Variant = result.spawned_branches[1]
		var b2: Variant = result.spawned_branches[2]
		_check(G, b0.source_cell == Vector2i(6, 5) and b0.direction == Vector2i(1, 0),
			"前进支源格/方向应为 (6,5)/(1,0)，实际 %s/%s。" % [b0.source_cell, b0.direction])
		_check(G, b1.source_cell == Vector2i(5, 6) and b1.direction == Vector2i(0, 1),
			"侧支1源格/方向应为 (5,6)/(0,1)，实际 %s/%s。" % [b1.source_cell, b1.direction])
		_check(G, b2.source_cell == Vector2i(5, 4) and b2.direction == Vector2i(0, -1),
			"侧支2源格/方向应为 (5,4)/(0,-1)，实际 %s/%s。" % [b2.source_cell, b2.direction])
		_check(G, b0.color == _RayColor.ColorValue.RED and b1.color == _RayColor.ColorValue.RED and b2.color == _RayColor.ColorValue.RED,
			"3 分支应盖章继承入射色 RED。")
	splitter.free()


# ===== E Definition 发现 =====

func _test_E01_definition_discovery() -> void:
	const G: String = "E01_Definition发现"
	var result: Dictionary = _Discovery.discover()
	var found: bool = false
	for d: Variant in result.definitions:
		if d.content_type_id == &"t_cell_splitter":
			found = true
			_check(G, d.inventory_eligible == true, "t_cell_splitter 应 inventory_eligible。")
			_check(G, d.scene != null, "t_cell_splitter 应声明 PackedScene。")
	_check(G, found, "discover 应发现 t_cell_splitter（校验失败则不会出现在 definitions）。")
	if not result.ok:
		for e: String in result.errors:
			if "t_cell_splitter" in e:
				_check(G, false, "t_cell_splitter 定义校验失败：%s" % e)


# ===== 断言辅助与报告 =====

func _branch_summary(r: Variant) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for b: Variant in r.spawned_branches:
		parts.append("%s→%s" % [b.source_cell, b.direction])
	return "[%s]" % ", ".join(parts)


func _report() -> void:
	print("==== TCellSplitter 判定与契约回归测试摘要 ====")
	print("测试组数：9")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print("  %s" % failure)
