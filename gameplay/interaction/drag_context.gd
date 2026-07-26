extends RefCounted

## 一次拖拽的临时事实唯一所有者：来源、机关 ID、原格、预览格、起始朝向。
## 不持有 Node、Controller、OccupancyRegistry、UI、Callable 或场景树引用；预览与正式节点句柄由核心保留。
## 复用 RuntimeInteractionTypes.DragSource，不定义第二份来源枚举；can_recycle 由核心在松手时按当前状态实时查询，不在此缓存。
## orientation 是拖拽起始朝向快照：库存拖拽为 SLASH，已放置拖拽取自正式节点；正式节点本身仍保留朝向，本字段不作同步副本维护。


const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _SingleCellMirror: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)

## 与核心 INVALID_CELL 一致的哨兵；库存拖拽时 original_cell 取此值，表示无原始格。
const INVALID_CELL: Vector2i = Vector2i(-999999, -999999)

## 拖拽来源；复用 RuntimeInteractionTypes.DragSource，NONE 表示无进行中的拖拽。
var source: _RuntimeInteractionTypes.DragSource = _RuntimeInteractionTypes.DragSource.NONE
## 库存拖拽的机关类型 ID；PLACED 拖拽时为空。
var token_type_id: StringName = &""
## 已放置机关拖拽的机关 ID；库存拖拽时为空。
var mechanism_id: StringName = &""
## 已放置机关拖拽的原始格；库存拖拽时为 INVALID_CELL。
var original_cell: Vector2i = INVALID_CELL
## 当前预览格；鼠标移动时由核心调用 update_preview_cell 更新。
var preview_cell: Vector2i = INVALID_CELL
## 拖拽起始朝向快照；库存拖拽为 SLASH，已放置拖拽取自正式节点。
var original_orientation: _SingleCellMirror.MirrorOrientation = _SingleCellMirror.MirrorOrientation.SLASH


## 开始一次库存拖拽；记录类型 ID、预览格与起始朝向，清空已放置机关字段。
func begin_inventory(
	p_token_type_id: StringName,
	p_initial_preview_cell: Vector2i,
	p_orientation: _SingleCellMirror.MirrorOrientation
) -> void:
	source = _RuntimeInteractionTypes.DragSource.INVENTORY
	token_type_id = p_token_type_id
	mechanism_id = &""
	original_cell = INVALID_CELL
	preview_cell = p_initial_preview_cell
	original_orientation = p_orientation


## 开始一次已放置机关拖拽；记录机关 ID、原格、预览格与起始朝向，清空库存字段。
func begin_placed(
	p_mechanism_id: StringName,
	p_original_cell: Vector2i,
	p_initial_preview_cell: Vector2i,
	p_orientation: _SingleCellMirror.MirrorOrientation
) -> void:
	source = _RuntimeInteractionTypes.DragSource.PLACED
	token_type_id = &""
	mechanism_id = p_mechanism_id
	original_cell = p_original_cell
	preview_cell = p_initial_preview_cell
	original_orientation = p_orientation


## 更新当前预览格；只由核心在鼠标移动时调用。
func update_preview_cell(cell: Vector2i) -> void:
	preview_cell = cell


## 清空全部拖拽事实；不释放节点、不恢复正式机关，节点清理由核心完成。
func clear() -> void:
	source = _RuntimeInteractionTypes.DragSource.NONE
	token_type_id = &""
	mechanism_id = &""
	original_cell = INVALID_CELL
	preview_cell = INVALID_CELL
	original_orientation = _SingleCellMirror.MirrorOrientation.SLASH


## 是否存在进行中的拖拽（source != NONE）。
func is_active() -> bool:
	return source != _RuntimeInteractionTypes.DragSource.NONE


## 拖拽来源是否为库存。
func is_inventory_source() -> bool:
	return source == _RuntimeInteractionTypes.DragSource.INVENTORY


## 拖拽来源是否为已放置机关。
func is_placed_source() -> bool:
	return source == _RuntimeInteractionTypes.DragSource.PLACED
