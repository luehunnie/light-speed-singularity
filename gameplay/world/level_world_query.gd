class_name LevelWorldQuery
extends RefCounted

## 当前世界事实只读门面（Day 1 D1-A / D3-C）：集中“读取当前世界事实”的查询入口，为光线层与放置层提供统一只读边界。
## 只组合 map_bounds、wall_cells、emitter_cell、LevelObjectRegistry、OccupancyRegistry 与 PlacementController.get_placed_node 的现有事实，不新增玩法规则。
## 由 core_loop_prototype.gd 在所有真实依赖初始化后构造并持有；不加入场景树、不设为 Autoload。
## 只读边界：水晶查询走 LevelObjectRegistry（不持可写水晶容器），机关节点经 get_placed_node_by_id 只读 Callable 解析（不持可写机关映射）；map_bounds、emitter_cell 为值类型不可变，wall_cells 为 @export 数组运行期只读。
## 四层 TileMapLayer 快照为可选兼容参数（D5-B.2A）：非空时正式运行 Terrain/LegalArea/Wall 以快照为唯一事实，map_bounds/wall_cells 退化为过渡兼容，仅服务旧测试/旧构造；不把两者并列为正式运行双事实。

# 用 preload 引用 LevelObjectRegistry 类型，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
# 四层 TileMapLayer 只读快照类型（D5-B.2A 可选兼容参数）：preload 引用避开 class_name 全局缓存坑；单向 preload 不构成循环。
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")


## 地图边界（值类型，运行期不可变）。
var _map_bounds: Rect2i
## 墙体格集合（@export 数组引用，运行期只读）。
var _wall_cells: Array[Vector2i]
## 主发射源所在格（值类型，运行期不可变）。
var _emitter_cell: Vector2i
## 关卡稳定对象索引（水晶按 crystal_id 与 cell 双向索引，只读查询）。
var _registry: _LevelObjectRegistry
## 占用表（引用，运行期只原地增删，不重赋值）。
var _occupancy: OccupancyRegistry
## 机关 ID → 正式节点的只读解析边界（持有 PlacementController.get_placed_node），不获得可写映射。
var _get_placed_node_by_id: Callable
## 四层 TileMapLayer 只读快照（D5-B.2A 可选兼容参数）：非空时为正式运行 Terrain/LegalArea/Wall 唯一事实来源；null 走旧 map_bounds+wall_cells 兼容路径，仅供旧测试/旧构造。
var _tile_layer_snapshot: _LevelTileLayerSnapshot = null


## 构造只读世界查询门面；registry 与 occupancy 持引用（调用方保证生命周期），机关节点经 get_placed_node_by_id 只读解析，不复制动态容器。
## tile_layer_snapshot 追加在末尾为可选兼容参数（默认 null）：正式运行由 core 传入非空快照作为 Terrain/LegalArea/Wall 唯一事实；旧测试/旧构造省略该参即走 map_bounds+wall_cells 兼容路径。
func _init(
		map_bounds: Rect2i,
		wall_cells: Array[Vector2i],
		emitter_cell: Vector2i,
		registry: _LevelObjectRegistry,
		occupancy: OccupancyRegistry,
		get_placed_node_by_id: Callable,
		tile_layer_snapshot: _LevelTileLayerSnapshot = null
) -> void:
	_map_bounds = map_bounds
	_wall_cells = wall_cells
	_emitter_cell = emitter_cell
	_registry = registry
	_occupancy = occupancy
	_get_placed_node_by_id = get_placed_node_by_id
	_tile_layer_snapshot = tile_layer_snapshot


## 判断格是否位于可通行 Terrain 内。
## 有快照（正式运行）：先以 Terrain 外包 Rect2i 粗筛，最终必须由 has_terrain_cell 精确确认（外包矩形含空洞，只认真实 Terrain 格）；map_bounds 不再作为唯一边界事实。
## 无快照兼容路径（仅旧测试/旧构造）：过渡期保留旧 map_bounds 矩形语义。
func is_in_bounds(cell: Vector2i) -> bool:
	if _tile_layer_snapshot != null:
		if not _tile_layer_snapshot.get_terrain_bounds().has_point(cell):
			return false
		return _tile_layer_snapshot.has_terrain_cell(cell)
	return _map_bounds.has_point(cell)


## 判断格是否为墙体格。
## 有快照（正式运行）：WallLayer 格为唯一墙体事实，不读旧 wall_cells，避免与快照并列为正式运行双事实。
## 无快照兼容路径（仅旧测试/旧构造）：过渡期读取旧 wall_cells 数组。
func is_wall_cell(cell: Vector2i) -> bool:
	if _tile_layer_snapshot != null:
		return _tile_layer_snapshot.has_wall_cell(cell)
	return _wall_cells.has(cell)


## 判断格是否为合法放置区（最小 LegalArea 查询）：必须先位于 Terrain 内；有快照还须存在 LegalArea Tile。
## LegalArea 不代替 Terrain，只作为附加约束；无快照兼容路径（仅旧测试/旧构造）视为允许，保持旧测试行为。
func is_legal_placement_cell(cell: Vector2i) -> bool:
	if not is_in_bounds(cell):
		return false
	if _tile_layer_snapshot != null:
		return _tile_layer_snapshot.has_legal_cell(cell)
	return true


## 查询指定格子被哪个机关占用；未被占用时返回空 StringName（&""），不报错。直接委托 OccupancyRegistry.get_mechanism_at。
func get_mechanism_id_at(cell: Vector2i) -> StringName:
	return _occupancy.get_mechanism_at(cell)


## 根据机关 ID 取得正式机关节点；ID 为空或未登记时返回 null。通过 get_placed_node_by_id 只读 Callable 解析，不持可写映射，不判断节点有效性，调用方需自行 is_instance_valid 校验。
func get_mechanism_node(mechanism_id: StringName) -> Variant:
	if mechanism_id == &"":
		return null
	return _get_placed_node_by_id.call(mechanism_id)


## 判断指定格子是否被任意机关占用；直接委托 OccupancyRegistry.has_mechanism_at，空占用表时始终返回 false。
func has_mechanism_at(cell: Vector2i) -> bool:
	return _occupancy.has_mechanism_at(cell)


## 指定 cell 是否有水晶登记；委托 LevelObjectRegistry.has_crystal_at，供光线层与放置层统一只读查询，不遍历核心 crystals 数组。
func has_crystal_at(cell: Vector2i) -> bool:
	return _registry.has_crystal_at(cell)


## 判断目标格是否被静态对象阻挡（墙体、主发射源格或任一水晶所在格）；墙体经 is_wall_cell 统一事实（正式运行走快照 WallLayer），水晶查询走 Registry，不遍历核心 crystals 数组。
func is_static_blocked_for_placement(cell: Vector2i) -> bool:
	if is_wall_cell(cell):
		return true
	if cell == _emitter_cell:
		return true
	return _registry.has_crystal_at(cell)


## 判断目标格是否被其他机关占用；ignored_id 为移动已放置机关时允许忽略的自身 ID，原格自身占用可被忽略，其他机关占用仍阻止放置。
func is_occupied_by_other(
		cell: Vector2i,
		ignored_id: StringName = &""
) -> bool:
	var occupied_id: StringName = _occupancy.get_mechanism_at(cell)
	if occupied_id == &"":
		return false
	return occupied_id != ignored_id


## 判断目标格是否为合法放置格；最低判定顺序：Terrain 内 → LegalArea 内 → 非 Wall → 无固定对象 → 无动态占用。
## 正式运行 Terrain/LegalArea/Wall 走快照；旧测试/旧构造兼容路径 LegalArea 视为允许、Terrain/Wall 走旧 map_bounds+wall_cells。不处理 INVALID_CELL 哨兵，由调用方在外层守卫。
func is_valid_placement_cell(
		cell: Vector2i,
		ignored_id: StringName = &""
) -> bool:
	if not is_in_bounds(cell):
		return false
	if not is_legal_placement_cell(cell):
		return false
	if is_static_blocked_for_placement(cell):
		return false
	if is_occupied_by_other(cell, ignored_id):
		return false
	return true


## 判断一组格是否整体为合法多格放置集（D7-R4 多格最小路径）：非空、格间无重复，且每格均满足 is_valid_placement_cell
## （Terrain 内 → LegalArea 内 → 非 Wall → 无固定对象 → 无动态占用），任一格非法则整体非法。
## [br]ignored_id 为移动/旋转中的多格机关自身 ID，允许其忽略自身既有占用格（旋转保持锚点时锚点格仍被自身占用）。
## [br]不解释 anchor/方向/footprint 语义：绝对格列表由调用方经对象自身 get_occupied_cells(anchor, orientation) 展开；
## 单格机关可继续使用 is_valid_placement_cell，长度 1 的格集与其等价。
func is_valid_placement_cell_set(
		cells: Array[Vector2i],
		ignored_id: StringName = &""
) -> bool:
	if cells.is_empty():
		return false
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			return false
		seen[cell] = true
		if not is_valid_placement_cell(cell, ignored_id):
			return false
	return true
