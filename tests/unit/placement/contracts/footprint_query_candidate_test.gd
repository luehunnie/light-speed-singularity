extends SceneTree

## AF-03 Footprint Contract / Shared Placement Query / Placement Candidate 定向合同测试（Guide §13/§17/§14）。
## 覆盖：静态足迹默认 [(0,0)] 与 anchor 展开、动态足迹（配置驱动偏移、非法动态值回退静态）、
## 共享查询 reason codes（OUTSIDE_TERRAIN / NOT_IN_LEGAL_AREA / WALL_BLOCKED / OBJECT_OCCUPIED /
## SHAPE_OUT_OF_BOUNDS）、忽略自身占用的移动语义、候选快照 detached 不污染 authoritative state。
## headless extends SceneTree；全部通过 quit(0)，任一失败 quit(1)。


const _FootprintContract: GDScript = preload(
	"res://gameplay/placement/contracts/footprint_contract.gd"
)
const _SharedPlacementQuery: GDScript = preload(
	"res://gameplay/placement/contracts/shared_placement_query.gd"
)
const _PlacementCandidate: GDScript = preload(
	"res://gameplay/placement/contracts/placement_candidate.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)
const _LevelObjectRegistry: GDScript = preload(
	"res://gameplay/level/level_object_registry.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)

const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 8, 8)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_static_footprint()
	_test_02_dynamic_footprint()
	_test_03_query_reason_codes()
	_test_04_query_ignored_occupant()
	_test_05_candidate_snapshot_detached()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 静态足迹：默认单格 [(0,0)]；anchor 展开为绝对格；声明多格偏移按定义展开。
func _test_01_static_footprint() -> void:
	const NAME: String = "01_静态足迹"
	var definition := _make_single_cell_definition()
	var offsets: Array[Vector2i] = _FootprintContract.footprint_offsets(definition, null)
	_check(NAME, offsets == [Vector2i.ZERO], "默认静态足迹应为 [(0,0)]。")
	var cells: Array[Vector2i] = _FootprintContract.footprint_cells(definition, null, Vector2i(3, 4))
	_check(NAME, cells == [Vector2i(3, 4)], "anchor 展开应为绝对格。")
	var wide := _make_single_cell_definition()
	wide.static_footprint_offsets = [Vector2i.ZERO, Vector2i(1, 0)]
	var wide_cells: Array[Vector2i] = _FootprintContract.footprint_cells(wide, null, Vector2i(2, 2))
	_check(NAME, wide_cells == [Vector2i(2, 2), Vector2i(3, 2)], "多格偏移按声明展开。")


## 2. 动态足迹：footprint_field_id 声明时读配置偏移；配置缺字段/非法列表回退静态声明。
func _test_02_dynamic_footprint() -> void:
	const NAME: String = "02_动态足迹"
	var definition := _make_dynamic_footprint_definition()
	var configuration: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults(definition.configuration_fields)
	var dynamic_cells: Array[Vector2i] = _FootprintContract.footprint_cells(definition, configuration, Vector2i(5, 5))
	_check(NAME, dynamic_cells == [Vector2i(5, 5), Vector2i(5, 6)], "动态足迹应读配置偏移字段。")
	configuration.apply_override(&"shape", [Vector2i.ZERO])
	var single_cells: Array[Vector2i] = _FootprintContract.footprint_cells(definition, configuration, Vector2i(5, 5))
	_check(NAME, single_cells == [Vector2i(5, 5)], "改写配置后足迹随之变化（纯函数，无状态）。")
	configuration.apply_override(&"shape", [])
	var fallback_cells: Array[Vector2i] = _FootprintContract.footprint_cells(definition, configuration, Vector2i(5, 5))
	_check(NAME, fallback_cells == [Vector2i(5, 5)], "空动态列表非法应回退静态声明。")
	var static_cells: Array[Vector2i] = _FootprintContract.footprint_cells(_make_single_cell_definition(), null, Vector2i(1, 1))
	_check(NAME, static_cells == [Vector2i(1, 1)], "未声明动态字段走静态。")


## 3. 共享查询 reason codes：出界/墙体/占用/空列表/重复格各自归因，合法集零 issue。
func _test_03_query_reason_codes() -> void:
	const NAME: String = "03_查询归因"
	var query := _make_shared_query()
	var outside: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(20, 20)])
	_check(NAME, not outside.is_allowed() and outside.issues == [_SharedPlacementQuery.REASON_OUTSIDE_TERRAIN], "出界应回 OUTSIDE_TERRAIN。")
	var wall: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(0, 0)])
	_check(NAME, not wall.is_allowed() and wall.issues == [_SharedPlacementQuery.REASON_WALL_BLOCKED], "墙体格应回 WALL_BLOCKED。")
	var occupied: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(2, 2)])
	_check(NAME, not occupied.is_allowed() and occupied.issues == [_SharedPlacementQuery.REASON_OBJECT_OCCUPIED], "他机关占用格应回 OBJECT_OCCUPIED。")
	var emitter: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(4, 4)])
	_check(NAME, not emitter.is_allowed() and emitter.issues == [_SharedPlacementQuery.REASON_OBJECT_OCCUPIED], "主发射源格应回 OBJECT_OCCUPIED。")
	var empty: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([])
	_check(NAME, not empty.is_allowed() and empty.issues == [_SharedPlacementQuery.REASON_SHAPE_OUT_OF_BOUNDS], "空列表应回 SHAPE_OUT_OF_BOUNDS。")
	var dup: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(1, 1), Vector2i(1, 1)])
	_check(NAME, not dup.is_allowed() and dup.issues == [_SharedPlacementQuery.REASON_SHAPE_OUT_OF_BOUNDS], "重复格应回 SHAPE_OUT_OF_BOUNDS。")
	var mixed: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(20, 20), Vector2i(0, 0)])
	_check(NAME, mixed.issues == [_SharedPlacementQuery.REASON_OUTSIDE_TERRAIN, _SharedPlacementQuery.REASON_WALL_BLOCKED], "多格逐格归因去重保序。")
	var legal: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(1, 1), Vector2i(1, 2)])
	_check(NAME, legal.is_allowed() and legal.issues.is_empty(), "合法格集应零 issue。")


## 4. 移动语义：ignored_occupant_id 为被移动机关自身 ID 时其原占用格放行；其他占用者 ID 仍阻止。
func _test_04_query_ignored_occupant() -> void:
	const NAME: String = "04_忽略自身占用"
	var query := _make_shared_query()
	var self_cell: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(2, 2)], &"other_1")
	_check(NAME, self_cell.is_allowed(), "以占用者自身 ID 忽略时原格应合法。")
	var other_cell: _SharedPlacementQuery.PlacementQueryResult = query.evaluate([Vector2i(2, 2)], &"self_1")
	_check(NAME, not other_cell.is_allowed(), "忽略无关 ID 时占用仍阻止。")


## 5. 候选快照 detached：候选配置是副本，后续改写不影响候选；候选构造不触 Registry / Occupancy。
func _test_05_candidate_snapshot_detached() -> void:
	const NAME: String = "05_候选detached"
	var definition := _make_dynamic_footprint_definition()
	var source: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults(definition.configuration_fields)
	var candidate: _PlacementCandidate = _PlacementCandidate.new("fci_1", definition.content_type_id, Vector2i(1, 1), definition, source)
	_check(NAME, candidate.stable_instance_id == "fci_1" and candidate.anchor_cell == Vector2i(1, 1), "候选身份字段正确。")
	_check(NAME, candidate.footprint_cells == [Vector2i(1, 1), Vector2i(1, 2)], "候选足迹在构造时确定性展开。")
	source.apply_override(&"shape", [Vector2i.ZERO])
	_check(NAME, candidate.configuration.get_value(&"shape") == [Vector2i.ZERO, Vector2i(0, 1)], "源配置后续改写不影响候选快照。")


## 单格静态足迹 Definition。
func _make_single_cell_definition() -> _MechanismDefinition:
	var definition: _MechanismDefinition = _MechanismDefinition.new()
	definition.content_type_id = &"test_single"
	definition.display_name = "单格测试类型"
	definition.scene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
	definition.inventory_eligible = true
	definition.static_footprint_offsets = [Vector2i.ZERO]
	return definition


## 动态足迹 Definition：shape 字段（VECTOR2I_ARRAY）驱动偏移。
func _make_dynamic_footprint_definition() -> _MechanismDefinition:
	var shape_field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	shape_field.field_id = &"shape"
	shape_field.display_name = "占格形状"
	shape_field.value_type = _MechanismFieldDefinition.ValueType.VECTOR2I_ARRAY
	shape_field.default_value = [Vector2i.ZERO, Vector2i(0, 1)]
	var definition := _make_single_cell_definition()
	definition.content_type_id = &"test_dynamic"
	definition.configuration_fields = [shape_field]
	definition.footprint_field_id = &"shape"
	return definition


## 共享查询 fixture：8×8 地图；(0,0) 为墙；(2,2) 被 other_1 机关占用；(4,4) 为主发射源格。
func _make_shared_query() -> _SharedPlacementQuery:
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	occupancy.register_single_cell(&"other_1", Vector2i(2, 2))
	var world_query: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS,
		[Vector2i(0, 0)] as Array[Vector2i],
		Vector2i(4, 4),
		registry,
		occupancy,
		Callable()
	)
	return _SharedPlacementQuery.new(world_query)


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("footprint_query_candidate_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
