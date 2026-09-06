extends SceneTree

## 三格直条分光器 判定逻辑与契约回归测试（C-09 内容批次；机关规则 三格直条分光器 v0.1）。
## 覆盖：
##   A 脚本接口——可实例化、继承 PlaceableToken、默认朝向 RIGHT、四朝向 footprint、RAY+PARTICLE 形态声明。
##   B 判定纯函数 resolve_interaction——四朝向分光 + 非法方向/反向/侧面/斜向/端格命中全 BLOCK。
##   C interact_ray 正式入口——四朝向分光（BLOCK + 2 分支，源格=两端格、方向=输入方向、color 恒 NONE）；
##     非法命中 → 纯 BLOCK（无分支）；interact_particle 恒 BLOCK。
##   D 端到端——真实 TripleCellSplitter 走 RayExecutionModule.execute，BLOCK 收集分支 + 继承色盖章（Q53）。
##   E Definition 发现——FormalContentDiscovery 扫描真实 definitions 目录发现 triple_cell_splitter 且校验通过。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _TripleCellSplitter: GDScript = preload(
	"res://gameplay/mechanisms/splitters/triple_cell_splitter.gd"
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

## A01. 可实例化、继承 PlaceableToken、具备正式交互契约面与多格 footprint 接口。
func _test_A01_script_interface() -> void:
	const G: String = "A01_脚本可实例化且接口完整"
	var m: Variant = _TripleCellSplitter.new()
	if _check(G, m != null, "triple_cell_splitter.gd 实例化失败。"):
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


## A02. 默认朝向 RIGHT（对齐 Q52 冻结 DEFAULT_SPLITTER_ORIENTATION）。
func _test_A02_default_orientation_right() -> void:
	const G: String = "A02_默认朝向RIGHT"
	var m: Variant = _TripleCellSplitter.new()
	_check(G, m.orientation == _TripleCellSplitter.SplitterOrientation.RIGHT,
		"默认 orientation 期望 RIGHT，实际 %s。" % [m.orientation])
	m.free()


## A03. 四朝向 footprint（横排/竖排三格，读自身 orientation）。
func _test_A03_footprint_four_orientations() -> void:
	const G: String = "A03_四朝向footprint"
	var m: Variant = _TripleCellSplitter.new()
	m.set_orientation(_TripleCellSplitter.SplitterOrientation.RIGHT)
	_check(G, m.get_occupied_offsets() == [Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)],
		"RIGHT 期望竖排 [(0,-1),(0,0),(0,1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TripleCellSplitter.SplitterOrientation.DOWN)
	_check(G, m.get_occupied_offsets() == [Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)],
		"DOWN 期望横排 [(-1,0),(0,0),(1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TripleCellSplitter.SplitterOrientation.LEFT)
	_check(G, m.get_occupied_offsets() == [Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)],
		"LEFT 期望竖排 [(0,-1),(0,0),(0,1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_TripleCellSplitter.SplitterOrientation.UP)
	_check(G, m.get_occupied_offsets() == [Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)],
		"UP 期望横排 [(-1,0),(0,0),(1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.free()


## A04. 声明 RAY + PARTICLE（光粒必须声明，否则透明穿过违背规则文档 §3.2）。
func _test_A04_forms_declaration() -> void:
	const G: String = "A04_声明RAY与PARTICLE"
	var m: Variant = _TripleCellSplitter.new()
	var forms: Array = m.get_light_interaction_forms()
	_check(G, &"RAY" in forms and &"PARTICLE" in forms, "应声明 RAY 与 PARTICLE，实际 %s。" % [forms])
	m.free()


# ===== B 判定纯函数 =====

## B01. resolve_interaction 速查表：四朝向分光 + 反向/侧面/斜向/端格/非法方向全 BLOCK。
func _test_B01_resolve_interaction_table() -> void:
	const G: String = "B01_判定速查表"
	var RIGHT: int = _TripleCellSplitter.SplitterOrientation.RIGHT
	var DOWN: int = _TripleCellSplitter.SplitterOrientation.DOWN
	var LEFT: int = _TripleCellSplitter.SplitterOrientation.LEFT
	var UP: int = _TripleCellSplitter.SplitterOrientation.UP
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
		# 端格命中（cell_offset != ZERO）
		[UP, Vector2i(-1, 0), Vector2i(0, -1), false],
		[UP, Vector2i(1, 0), Vector2i(0, -1), false],
		# 非法方向
		[UP, Vector2i.ZERO, Vector2i.ZERO, false],
		[UP, Vector2i.ZERO, Vector2i(2, 0), false],
	]
	for c: Array in cases:
		var res: Variant = _TripleCellSplitter.resolve_interaction(c[0], c[1], c[2])
		_check(G, res.split == c[3],
			"orientation=%d offset=%s dir=%s => split=%s（期望 %s）" % [c[0], c[1], c[2], res.split, c[3]])


# ===== C interact_ray 正式入口 =====

## C01. 四朝向分光：BLOCK + 2 分支，源格=两端格、方向=输入方向、color 恒 NONE。
func _test_C01_interact_ray_four_orientations() -> void:
	const G: String = "C01_四朝向分光"
	var RIGHT: int = _TripleCellSplitter.SplitterOrientation.RIGHT
	var DOWN: int = _TripleCellSplitter.SplitterOrientation.DOWN
	var LEFT: int = _TripleCellSplitter.SplitterOrientation.LEFT
	var UP: int = _TripleCellSplitter.SplitterOrientation.UP
	# [orientation, input_dir, branch0_cell, branch1_cell]（anchor 恒 (2,2)）
	var cases: Array = [
		[RIGHT, Vector2i(1, 0), Vector2i(2, 3), Vector2i(2, 1)],
		[DOWN, Vector2i(0, 1), Vector2i(1, 2), Vector2i(3, 2)],
		[LEFT, Vector2i(-1, 0), Vector2i(2, 1), Vector2i(2, 3)],
		[UP, Vector2i(0, -1), Vector2i(3, 2), Vector2i(1, 2)],
	]
	for c: Array in cases:
		var m: Variant = _TripleCellSplitter.new()
		m.set_cell(Vector2i(2, 2))
		m.set_orientation(c[0])
		var ctx: Variant = _RayInteractionContext.create(Vector2i(2, 2), c[1], 1, 1)
		var r: Variant = m.interact_ray(ctx)
		var ok: bool = r.decision == _LightInteractionResult.Decision.BLOCK
		ok = ok and r.spawned_branches.size() == 2
		if r.spawned_branches.size() == 2:
			ok = ok and r.spawned_branches[0].source_cell == c[2] and r.spawned_branches[0].direction == c[1]
			ok = ok and r.spawned_branches[1].source_cell == c[3] and r.spawned_branches[1].direction == c[1]
			ok = ok and r.spawned_branches[0].color == _RayColor.ColorValue.NONE
			ok = ok and r.spawned_branches[1].color == _RayColor.ColorValue.NONE
		_check(G, ok,
			"朝向 %d 分光不正确：decision=%d branches=%s（期望 BLOCK + 2 分支 %s/%s 方向 %s）"
			% [c[0], r.decision, _branch_summary(r), c[2], c[3], c[1]])
		m.free()


## C02. 非法命中 → 纯 BLOCK（无分支）；interact_particle 恒 BLOCK。
func _test_C02_interact_ray_illegal_block() -> void:
	const G: String = "C02_非法命中BLOCK"
	var m: Variant = _TripleCellSplitter.new()
	m.set_cell(Vector2i(2, 2))
	m.set_orientation(_TripleCellSplitter.SplitterOrientation.UP)
	# 反向 / 侧面 / 斜向 / 端格命中 → 纯 BLOCK（无分支）
	var illegals: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1)]
	for dir: Vector2i in illegals:
		var ctx: Variant = _RayInteractionContext.create(Vector2i(2, 2), dir, 1, 1)
		var r: Variant = m.interact_ray(ctx)
		_check(G, r.decision == _LightInteractionResult.Decision.BLOCK and r.spawned_branches.is_empty(),
			"命中中间格但方向 %s 应纯 BLOCK（无分支），实际 decision=%d branches=%d。" % [dir, r.decision, r.spawned_branches.size()])
	# 端格命中（光到达左端格 (1,2)，方向 (0,-1)）
	var ctx2: Variant = _RayInteractionContext.create(Vector2i(1, 2), Vector2i(0, -1), 1, 1)
	var r2: Variant = m.interact_ray(ctx2)
	_check(G, r2.decision == _LightInteractionResult.Decision.BLOCK and r2.spawned_branches.is_empty(),
		"端格命中应纯 BLOCK（无分支），实际 decision=%d branches=%d。" % [r2.decision, r2.spawned_branches.size()])
	# 光粒恒 BLOCK
	var pr: Variant = m.interact_particle(null)
	_check(G, pr.decision == _LightInteractionResult.Decision.BLOCK, "interact_particle 应恒 BLOCK。")
	m.free()


# ===== D 端到端 =====

## 构造 10×10 只读光线查询门面（与 ray_execution_module_test 同构）。
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


## D01. 真实分光器走完整传播链：BLOCK 收集 2 分支 + 继承色盖章（Q53 消耗式分光端到端）。
func _test_D01_end_to_end_branch_collection() -> void:
	const G: String = "D01_端到端分支收集"
	var world := _build_world([])
	_occupancy_hold(world.occupancy)
	var splitter: Variant = _TripleCellSplitter.new()
	splitter.set_cell(Vector2i(5, 5))  # 默认 RIGHT（输入 (1,0)）
	_register_mechanism(world, world.occupancy, Vector2i(5, 5), splitter, &"m1")
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i(1, 0), 64, world.query, 7, 3, _RayColor.ColorValue.RED)
	_check(G, result.stop_reason == _RayExecutionResult.StopReason.MECHANISM_BLOCK,
		"分光器应 MECHANISM_BLOCK 停止。")
	_check(G, result.spawned_branches.size() == 2,
		"应收集 2 分支，实际 %d。" % result.spawned_branches.size())
	if result.spawned_branches.size() == 2:
		var b0: Variant = result.spawned_branches[0]
		var b1: Variant = result.spawned_branches[1]
		_check(G, b0.source_cell == Vector2i(5, 6) and b1.source_cell == Vector2i(5, 4),
			"分支源格应为两端格 (5,6)/(5,4)，实际 %s/%s。" % [b0.source_cell, b1.source_cell])
		_check(G, b0.direction == Vector2i(1, 0) and b1.direction == Vector2i(1, 0),
			"分支方向应均 (1,0)。")
		_check(G, b0.color == _RayColor.ColorValue.RED and b1.color == _RayColor.ColorValue.RED,
			"分支应盖章继承入射色 RED。")
	splitter.free()


# ===== E Definition 发现 =====

## E01. FormalContentDiscovery 扫描真实 definitions 目录发现 triple_cell_splitter 且校验通过。
func _test_E01_definition_discovery() -> void:
	const G: String = "E01_Definition发现"
	var result: Dictionary = _Discovery.discover()
	var found: bool = false
	for d: Variant in result.definitions:
		if d.content_type_id == &"triple_cell_splitter":
			found = true
			_check(G, d.inventory_eligible == true, "triple_cell_splitter 应 inventory_eligible。")
			_check(G, d.scene != null, "triple_cell_splitter 应声明 PackedScene。")
	_check(G, found, "discover 应发现 triple_cell_splitter（校验失败则不会出现在 definitions）。")
	if not result.ok:
		for e: String in result.errors:
			if "triple_cell_splitter" in e:
				_check(G, false, "triple_cell_splitter 定义校验失败：%s" % e)


# ===== 断言辅助与报告 =====

## 分支载荷摘要（供失败详情）。
func _branch_summary(r: Variant) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for b: Variant in r.spawned_branches:
		parts.append("%s→%s" % [b.source_cell, b.direction])
	return "[%s]" % ", ".join(parts)


func _report() -> void:
	print("==== TripleCellSplitter 判定与契约回归测试摘要 ====")
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
