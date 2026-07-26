class_name LightWorldQuery
extends RefCounted

## 面向普通光线的只读薄适配层（Day 1 D1-A / D3-D）：为光线层提供“是否在边界内、是否墙体、该格机关节点、该格是否有水晶”的只读组合入口。
## 只转发 LevelWorldQuery 的既有边界、墙体与水晶查询，不新增光学规则；由核心在 LevelWorldQuery 之后构造并持有，作为 RayExecutionModule 的唯一世界查询依赖。
## 水晶查询经 LevelWorldQuery → LevelObjectRegistry，不再持有 crystals 数组或直接遍历水晶。
## 不加入场景树、不设为 Autoload；不负责光传播循环、方向改变、水晶激活、光路视觉、世界修改、RunState、UI、库存或拖拽。

# 用 preload 引用 LevelWorldQuery 类型，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")

## 只读世界门面（引用）。
var _level_world_query: _LevelWorldQuery


## 构造光线层只读适配器；只持有 LevelWorldQuery 引用，水晶查询委托其 has_crystal_at（最终来自 Registry）。
func _init(level_world_query: _LevelWorldQuery) -> void:
	_level_world_query = level_world_query


## 判断格子是否在地图边界内；只读转发 LevelWorldQuery.is_in_bounds，传播模块据此区分越界停止。
func is_in_bounds(cell: Vector2i) -> bool:
	return _level_world_query.is_in_bounds(cell)


## 判断格子是否为墙体格；只读转发 LevelWorldQuery.is_wall_cell，传播模块据此区分墙体停止。
func is_wall_cell(cell: Vector2i) -> bool:
	return _level_world_query.is_wall_cell(cell)


## 取得光线进入格时该格的机关节点；无机关或未登记正式节点时返回 null。不判断节点有效性，不执行反射，不改变方向。
func get_light_mechanism_at(cell: Vector2i) -> Variant:
	var mechanism_id: StringName = _level_world_query.get_mechanism_id_at(cell)
	return _level_world_query.get_mechanism_node(mechanism_id)


## 判断指定格子是否有普通独立水晶；委托 LevelWorldQuery.has_crystal_at（最终来自 Registry），不激活水晶，不遍历水晶数组。
func has_crystal_at(cell: Vector2i) -> bool:
	return _level_world_query.has_crystal_at(cell)
