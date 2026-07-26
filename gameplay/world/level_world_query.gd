class_name LevelWorldQuery
extends RefCounted

## 当前世界事实只读门面（Day 1 D1-A）：集中“读取当前世界事实”的查询入口，为光线层与放置层提供统一只读边界。
## 只组合 map_bounds、wall_cells、emitter_cell、crystals、OccupancyRegistry 与 placed_tokens_by_id 的现有事实，不新增玩法规则。
## 由 core_loop_prototype.gd 在所有真实依赖初始化后构造并持有；不加入场景树、不设为 Autoload。
## 动态引用安全：crystals、occupancy、placed_tokens_by_id 运行期只原地增删或 clear()，从不整体重赋值，故构造时持有引用不会失效；
## wall_cells 为 @export 数组运行期只读；map_bounds、emitter_cell 为值类型不可变。所有方法每次调用都读取当前真实事实，不缓存失效快照。


## 地图边界（值类型，运行期不可变）。
var _map_bounds: Rect2i
## 墙体格集合（@export 数组引用，运行期只读）。
var _wall_cells: Array[Vector2i]
## 主发射源所在格（值类型，运行期不可变）。
var _emitter_cell: Vector2i
## 普通独立水晶数组（引用，运行期不重赋值，只读迭代）。
var _crystals: Array[BasicCrystal]
## 占用表（引用，运行期只原地增删，不重赋值）。
var _occupancy: OccupancyRegistry
## 已放置机关 ID → 节点映射（引用，运行期只原地增删键，不重赋值）。
var _placed_tokens_by_id: Dictionary[StringName, Variant]


## 构造只读世界查询门面；不复制动态容器，只持有其引用，调用方保证容器在生命周期内不被整体重赋值。
func _init(
		map_bounds: Rect2i,
		wall_cells: Array[Vector2i],
		emitter_cell: Vector2i,
		crystals: Array[BasicCrystal],
		occupancy: OccupancyRegistry,
		placed_tokens_by_id: Dictionary[StringName, Variant]
) -> void:
	_map_bounds = map_bounds
	_wall_cells = wall_cells
	_emitter_cell = emitter_cell
	_crystals = crystals
	_occupancy = occupancy
	_placed_tokens_by_id = placed_tokens_by_id


## 判断格子是否在地图边界内；只读，每次调用直接读取当前 map_bounds，不缓存结果。
func is_in_bounds(cell: Vector2i) -> bool:
	return _map_bounds.has_point(cell)


## 判断格子是否为墙体格；只检查静态 wall_cells，不处理可消除墙、机关占用或电控门。
func is_wall_cell(cell: Vector2i) -> bool:
	return _wall_cells.has(cell)


## 查询指定格子被哪个机关占用；未被占用时返回空 StringName（&""），不报错。直接委托 OccupancyRegistry.get_mechanism_at。
func get_mechanism_id_at(cell: Vector2i) -> StringName:
	return _occupancy.get_mechanism_at(cell)


## 根据机关 ID 取得正式机关节点；ID 为空或未登记时返回 null。不判断节点有效性，调用方需自行 is_instance_valid 校验。
func get_mechanism_node(mechanism_id: StringName) -> Variant:
	if mechanism_id == &"":
		return null
	if not _placed_tokens_by_id.has(mechanism_id):
		return null
	return _placed_tokens_by_id[mechanism_id]


## 判断指定格子是否被任意机关占用；直接委托 OccupancyRegistry.has_mechanism_at，空占用表时始终返回 false。
func has_mechanism_at(cell: Vector2i) -> bool:
	return _occupancy.has_mechanism_at(cell)


## 判断目标格是否被静态对象阻挡（墙体、主发射源格或任一水晶所在格）；只集中既有静态阻挡规则，不新增允许格枚举。
func is_static_blocked_for_placement(cell: Vector2i) -> bool:
	if _wall_cells.has(cell):
		return true
	if cell == _emitter_cell:
		return true
	for crystal: BasicCrystal in _crystals:
		if crystal.cell == cell:
			return true
	return false


## 判断目标格是否被其他机关占用；ignored_id 为移动已放置机关时允许忽略的自身 ID，原格自身占用可被忽略，其他机关占用仍阻止放置。
func is_occupied_by_other(
		cell: Vector2i,
		ignored_id: StringName = &""
) -> bool:
	var occupied_id: StringName = _occupancy.get_mechanism_at(cell)
	if occupied_id == &"":
		return false
	return occupied_id != ignored_id


## 判断目标格是否为合法放置格（边界内、未被静态阻挡、且未被其他机关占用）；不处理 INVALID_CELL 哨兵，由调用方在外层守卫。
func is_valid_placement_cell(
		cell: Vector2i,
		ignored_id: StringName = &""
) -> bool:
	if not is_in_bounds(cell):
		return false
	if is_static_blocked_for_placement(cell):
		return false
	if is_occupied_by_other(cell, ignored_id):
		return false
	return true
