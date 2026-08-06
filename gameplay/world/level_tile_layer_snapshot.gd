extends RefCounted


## 四层 TileMapLayer 只读快照（D5-B.1）。
## 职责：构造时一次性复制 Terrain/Wall/LegalArea/Decoration 四层 used cells 到内部 Dictionary，之后不再持有 TileMapLayer 节点；
## 以只读方式回答“某格在某层是否存在”与 Terrain 外包矩形查询。
## 输入：_init 接收四个 TileMapLayer 节点（仅用于本次复制 used cells；存在性与类型校验由调用方负责）。
## 输出：has_*_cell 返回 bool；get_terrain_bounds 返回 Rect2i。
## 边界：构造后与源节点解耦，源节点后续增删不影响本快照；不暴露内部 Dictionary/Array 引用，对外只返回值类型。


# 四层 used cells：以 Vector2i 为键、true 为占位值，复制后与源 TileMapLayer 解耦。
var _terrain_cells: Dictionary = {}
var _legal_cells: Dictionary = {}
var _wall_cells: Dictionary = {}
var _decoration_cells: Dictionary = {}
# Terrain used cells 的外包矩形；空 Terrain 为 Rect2i(0,0,0,0)。
var _terrain_bounds: Rect2i = Rect2i(0, 0, 0, 0)


## 构造四层只读快照：逐层复制 used cells 并计算 Terrain 外包矩形。复制完成后不再保留传入的 TileMapLayer 引用。
func _init(
		terrain_layer: TileMapLayer,
		wall_layer: TileMapLayer,
		legal_area_layer: TileMapLayer,
		decoration_layer: TileMapLayer
) -> void:
	_terrain_cells = _copy_used_cells_of(terrain_layer)
	_wall_cells = _copy_used_cells_of(wall_layer)
	_legal_cells = _copy_used_cells_of(legal_area_layer)
	_decoration_cells = _copy_used_cells_of(decoration_layer)
	_terrain_bounds = _compute_bounds(_terrain_cells)


## 复制单层 used cells 到以 Vector2i 为键的 Dictionary（值占位 true）；返回独立副本，不暴露源层数据。
func _copy_used_cells_of(layer: TileMapLayer) -> Dictionary:
	var cells: Dictionary = {}
	for cell: Vector2i in layer.get_used_cells():
		cells[cell] = true
	return cells


## 由 used cells 计算外包 Rect2i；空集返回 Rect2i(0,0,0,0)。
func _compute_bounds(cells: Dictionary) -> Rect2i:
	if cells.is_empty():
		return Rect2i(0, 0, 0, 0)
	var min_x: int = 0
	var min_y: int = 0
	var max_x: int = 0
	var max_y: int = 0
	var is_first: bool = true
	for cell: Vector2i in cells:
		if is_first:
			min_x = cell.x
			min_y = cell.y
			max_x = cell.x
			max_y = cell.y
			is_first = false
		else:
			if cell.x < min_x:
				min_x = cell.x
			if cell.y < min_y:
				min_y = cell.y
			if cell.x > max_x:
				max_x = cell.x
			if cell.y > max_y:
				max_y = cell.y
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## Terrain 层是否存在该格。
func has_terrain_cell(cell: Vector2i) -> bool:
	return _terrain_cells.has(cell)


## LegalArea 层是否存在该格。
func has_legal_cell(cell: Vector2i) -> bool:
	return _legal_cells.has(cell)


## Wall 层是否存在该格。
func has_wall_cell(cell: Vector2i) -> bool:
	return _wall_cells.has(cell)


## Decoration 层是否存在该格。
func has_decoration_cell(cell: Vector2i) -> bool:
	return _decoration_cells.has(cell)


## Terrain used cells 的外包矩形（空 Terrain 返回零尺寸 Rect2i）；返回值类型，调用方修改不影响快照内部状态。
func get_terrain_bounds() -> Rect2i:
	return _terrain_bounds
