extends RefCounted

## LevelData 场景只读提取器（D7-R2 最小适配层）。
## 职责：从关卡根 Node（正式四层 + 固定对象结构）一次性只读提取 LevelData 静态字段，
##   使现有 .tscn 关卡可以在零迁移、零运行时改动下产出可序列化数据。
## 输入：关卡根 Node（与 LevelValidator.validate 同源结构）。
## 输出：合法提取时返回 LevelData；根非法、任一逻辑层缺失/缺 TileSet、发射器或水晶数量 != 1、
##   或固定对象 position 非有限时 push_error 说明原因并返回 null（不静默降级、不部分提取）。
## 边界：只读——不改场景任何节点/属性；level_id 恒保持空（unavailable 政策，绝不以 Node.name 顶替）；
##   不做合法性校验（提取结果交给 LevelData.validate() / LevelValidator）；不缓存节点。
## 类型注册：与 LevelTileLayerSnapshot 同策略不使用 class_name（避开全局 class 缓存坑），外部 preload 使用。

const _LevelData: GDScript = preload("res://gameplay/level/data/level_data.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")

## 提取入口。read-only：整个调用不产生任何写操作。
static func capture(level_root: Node) -> _LevelData:
	if level_root == null or not (level_root is Node2D):
		push_error("LevelDataCapture：关卡根为空或非 Node2D，已放弃提取。")
		return null
	var root: Node2D = level_root
	# 四层逻辑格：Terrain/Wall/LegalArea 必须齐备且已绑 TileSet（Decoration 纯视觉，不读）。
	var terrain_layer: TileMapLayer = _direct_layer(root, "TerrainLayer")
	var wall_layer: TileMapLayer = _direct_layer(root, "WallLayer")
	var legal_layer: TileMapLayer = _direct_layer(root, "LegalAreaLayer")
	if terrain_layer == null or wall_layer == null or legal_layer == null:
		push_error("LevelDataCapture：Terrain/Wall/LegalArea 存在直属 TileMapLayer 缺失或缺 TileSet，已放弃提取。")
		return null
	# 固定对象：v0 契约恰好 1 发射器 + 1 水晶（与 LevelFixedObjectValidator 同判定口径）。
	var emitters: Array = _find_instances(root, _EmitterConfigNode)
	if emitters.size() != 1:
		push_error("LevelDataCapture：EmitterConfigNode 数量必须为 1，实际 %d，已放弃提取。" % emitters.size())
		return null
	var crystals: Array = _find_instances(root, _BasicCrystal)
	if crystals.size() != 1:
		push_error("LevelDataCapture：BasicCrystal 数量必须为 1，实际 %d，已放弃提取。" % crystals.size())
		return null
	var emitter: _EmitterConfigNode = emitters[0]
	var crystal: _BasicCrystal = crystals[0]
	if not _is_finite(emitter.position) or not _is_finite(crystal.position):
		push_error("LevelDataCapture：固定对象 position 含非有限值，已放弃提取。")
		return null
	var data: _LevelData = _LevelData.new()
	data.terrain_cells = _cells_copy(terrain_layer)
	data.wall_cells = _cells_copy(wall_layer)
	data.legal_area_cells = _cells_copy(legal_layer)
	data.emitter_cell = _GridCoordinateRules.world_to_cell(emitter.position)
	data.emitter_form = emitter.default_light_form
	data.emitter_allow_form_switch = emitter.allow_form_switch
	data.emitter_ray_direction = emitter.ray_default_direction
	data.emitter_particle_direction = emitter.particle_default_direction
	data.crystal_cell = _GridCoordinateRules.world_to_cell(crystal.position)
	data.crystal_id = crystal.crystal_id
	return data


## 取根直属指定名 TileMapLayer；缺失、错型或缺 TileSet 返回 null。
static func _direct_layer(root: Node2D, layer_name: String) -> TileMapLayer:
	var node: Node = root.get_node_or_null(NodePath(layer_name))
	if node == null or not (node is TileMapLayer):
		return null
	var layer: TileMapLayer = node
	if layer.tile_set == null:
		return null
	return layer


## 复制单层 used cells 为独立 Array[Vector2i]（值拷贝，与源层解耦）。
static func _cells_copy(layer: TileMapLayer) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell: Vector2i in layer.get_used_cells():
		cells.append(cell)
	return cells


## DFS 收集子树中某脚本类型的全部实例（不含根；与 LevelFixedObjectValidator 同扫描口径）。
static func _find_instances(root: Node, script_type: GDScript) -> Array:
	var out: Array = []
	_gather(root, script_type, out)
	return out


static func _gather(node: Node, script_type: GDScript, out: Array) -> void:
	for child in node.get_children():
		if is_instance_of(child, script_type):
			out.append(child)
		_gather(child, script_type, out)


## position 两轴是否均为有限值。
static func _is_finite(pos: Vector2) -> bool:
	return is_finite(pos.x) and is_finite(pos.y)
