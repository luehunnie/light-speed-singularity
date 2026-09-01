@tool
extends RefCounted

# AF-08 编辑期统一 Placement Query（Guide §10.1/§10.2）：Editor 拖拽 / 选中预览与 Palette 放置
# 共用 Runtime/Validator 同一正式空间合法性语义（SharedPlacementQuery → LevelWorldQuery 委托链原样复用）。
# 构造：四层 TileMapLayer → LevelTileLayerSnapshot（Terrain/LegalArea/Wall 唯一事实）；
#   正式对象（机关 / 水晶 / 发射器）当前占格 → OccupancyRegistry（OBJECT_OCCUPIED 归因来源）；
#   发射器格作为静态阻挡事实传入。不实例化任何运行时控制器，纯只读。
# 返回值不是 Bool：PlacementQueryResult.allowed + issues（OUTSIDE_TERRAIN / NOT_IN_LEGAL_AREA /
#   WALL_BLOCKED / OBJECT_OCCUPIED / SHAPE_OUT_OF_BOUNDS），Editor 用它画合法/非法与失败原因。


const _LevelTileLayerSnapshot: GDScript = preload(
	"res://gameplay/world/level_tile_layer_snapshot.gd"
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
const _SharedPlacementQuery: GDScript = preload(
	"res://gameplay/placement/contracts/shared_placement_query.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)

# 正式四层角色名（与 LevelValidator 冻结角色一致）。
const ROLE_TERRAIN: String = "TerrainLayer"
const ROLE_WALL: String = "WallLayer"
const ROLE_LEGAL: String = "LegalAreaLayer"
const ROLE_DECORATION: String = "DecorationLayer"

# 编辑期占用人 token：正式对象无 stable ID 时回退节点实例 ID（同一构建内仍唯一）。
const _FALLBACK_PREFIX: String = "node_"


var _level_world_query: _LevelWorldQuery = null
var _shared_query: _SharedPlacementQuery = null
var _occupancy_ids_by_node: Dictionary = {}
var _terrain_bounds: Rect2i = Rect2i()


# 从关卡根构建编辑期查询；四层缺任一或根为空返回 false（不静默降级为空地图语义）。
# [br]skip_node：构建占用时不登记的节点（预览中的对象自身，其占格经 ignored_occupant_id 忽略亦可）。
func build(level_root: Node2D, skip_node: Node = null) -> bool:
	if level_root == null:
		return false
	var terrain: TileMapLayer = find_layer(level_root, ROLE_TERRAIN)
	var wall: TileMapLayer = find_layer(level_root, ROLE_WALL)
	var legal: TileMapLayer = find_layer(level_root, ROLE_LEGAL)
	var decoration: TileMapLayer = find_layer(level_root, ROLE_DECORATION)
	if not _LevelTileLayerSnapshot.validate_layers(terrain, wall, legal, decoration):
		return false
	var snapshot := _LevelTileLayerSnapshot.new(terrain, wall, legal, decoration)
	_terrain_bounds = snapshot.get_terrain_bounds()
	var occupancy := _OccupancyRegistry.new()
	var no_walls: Array[Vector2i] = []
	_occupancy_ids_by_node = {}
	for node: Node in _StableIdService.find_formal_objects(level_root):
		if node == skip_node or not (node is Node2D):
			continue
		var occupant_id := StringName(str(node.get("stable_instance_id")))
		if str(occupant_id).is_empty():
			occupant_id = StringName(_FALLBACK_PREFIX + str(node.get_instance_id()))
		var cell: Vector2i = _GridCoordinateRules.world_to_cell((node as Node2D).position)
		# C-08 多格最小接线：实例提供 get_occupied_offsets（D7-R4 footprint 契约）时自锚格展开全部占格登记；
		# 其余正式对象（发射器/水晶等单格）回退单格、行为不变。register_cells 原子提交（任一冲突整体拒绝），
		# 与原 register_single_cell 相同不读返回值：冲突事实由后续 evaluate 的 OBJECT_OCCUPIED 归因呈现。
		var occupied: Array[Vector2i] = []
		if (node as Node2D).has_method("get_occupied_offsets"):
			for offset: Variant in (node as Node2D).call("get_occupied_offsets"):
				occupied.append(cell + (offset as Vector2i))
		else:
			occupied.append(cell)
		occupancy.register_cells(occupant_id, occupied)
		_occupancy_ids_by_node[node] = occupant_id
	_level_world_query = _LevelWorldQuery.new(
		snapshot.get_terrain_bounds(), no_walls, _find_emitter_cell(level_root),
		_LevelObjectRegistry.new(), occupancy, Callable(), snapshot
	)
	_shared_query = _SharedPlacementQuery.new(_level_world_query)
	return true


# 评估一组绝对占格的编辑期可放置性（SharedPlacementQuery 原样委托）；未构建返回空 allowed=false 结果。
# [br]cells 接受未类型化数组（UI/测试字面量友好），逐项须为 Vector2i，含异物按 SHAPE_OUT_OF_BOUNDS 拒绝。
func evaluate(cells: Array, ignored_node: Node = null) -> _SharedPlacementQuery.PlacementQueryResult:
	if _shared_query == null:
		return _SharedPlacementQuery.PlacementQueryResult.new(false, [])
	var typed_cells: Array[Vector2i] = []
	for cell: Variant in cells:
		if not (cell is Vector2i):
			return _shared_query.evaluate([])
		typed_cells.append(cell)
	var ignored_id := &""
	if ignored_node != null and _occupancy_ids_by_node.has(ignored_node):
		ignored_id = _occupancy_ids_by_node[ignored_node]
	return _shared_query.evaluate(typed_cells, ignored_id)


# 查询是否已成功构建。
func is_ready() -> bool:
	return _shared_query != null


# Terrain used cells 外包矩形（Palette 扫描首个空格的迭代域）；未构建返回零矩形。
func get_terrain_bounds() -> Rect2i:
	return _terrain_bounds


# 按角色名找关卡根直接子层（与 LevelValidator 角色契约一致；非直接子节点不算）。
static func find_layer(level_root: Node2D, role: String) -> TileMapLayer:
	for child in level_root.get_children():
		var candidate: Node = child
		if candidate is TileMapLayer and candidate.name == StringName(role):
			return candidate
	return null


# 找主发射器格（发射器为静态阻挡事实）；缺失返回远离地图的哨兵格（不与真实格冲突）。
static func _find_emitter_cell(level_root: Node2D) -> Vector2i:
	for node: Node in _StableIdService.find_formal_objects(level_root):
		if node is _EmitterConfigNode and node is Node2D:
			return _GridCoordinateRules.world_to_cell((node as Node2D).position)
	return Vector2i(-1000000, -1000000)
