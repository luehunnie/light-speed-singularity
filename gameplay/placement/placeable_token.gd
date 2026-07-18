class_name PlaceableToken
extends Node2D

## 核心闭环原型单格可放置机关视觉脚本。
## 职责：保存原型机关的唯一 ID 与逻辑格子，按关卡控制器传入的位置刷新显示，提供普通放置态与拖拽预览态。
## 位置：由 levels/prototypes/core_loop_prototype.gd 在布置阶段实例化和驱动，用于验证库存、拖拽、占用登记、移动和回收流程。
## 依赖：Vector2i 格子坐标、StringName 机关 ID，以及本场景内 Shadow、TokenBody、InnerMark 三个 ColorRect 子节点。
## 不负责：地图合法性判断、OccupancyRegistry 写入、库存数量、RunState、光传播、阻挡、反射、颜色转换或通关判断。

var mechanism_id: StringName = &""
var cell: Vector2i = Vector2i.ZERO

@onready var _shadow: ColorRect = $Shadow
@onready var _body: ColorRect = $TokenBody
@onready var _inner_mark: ColorRect = $InnerMark

const _PLACED_BODY_COLOR: Color = Color(0.25, 0.85, 0.95, 1.0)
const _PLACED_MARK_COLOR: Color = Color(0.95, 1.0, 1.0, 1.0)
const _VALID_PREVIEW_BODY_COLOR: Color = Color(0.2, 0.95, 0.35, 0.62)
const _INVALID_PREVIEW_BODY_COLOR: Color = Color(1.0, 0.18, 0.18, 0.62)
const _VALID_PREVIEW_MARK_COLOR: Color = Color(0.02, 0.25, 0.08, 0.95)
const _INVALID_PREVIEW_MARK_COLOR: Color = Color(0.35, 0.02, 0.02, 0.95)
const _PLACED_Z_INDEX: int = 20
const _PREVIEW_Z_INDEX: int = 80


## 配置原型机关实例的基础数据。
## [br]id 是关卡控制器分配的唯一机关 ID，initial_cell 是当前逻辑格子。
## [br]无返回值；副作用是写入 mechanism_id 和 cell，并刷新为普通放置视觉。
## [br]边界条件：允许预览节点使用临时 ID；本函数不验证 ID 唯一性、不判断格子合法性、不写占用表。
func configure(id: StringName, initial_cell: Vector2i) -> void:
	mechanism_id = id
	cell = initial_cell
	set_drag_preview(false, true)


## 更新机关保存的逻辑格子。
## [br]new_cell 是关卡控制器确认后的格子坐标。
## [br]无返回值；副作用仅修改 cell，不移动节点世界坐标。
## [br]边界条件：本函数不判断地图边界、墙体、水晶或占用；调用方必须在提交前完成合法性检查。
func set_cell(new_cell: Vector2i) -> void:
	cell = new_cell


## 更新机关节点的世界位置。
## [br]world_position 是关卡控制器通过统一 cell_to_world() 或鼠标吸附规则计算出的世界坐标。
## [br]无返回值；副作用是设置 Node2D.position。
## [br]边界条件：本节点不自行实现坐标换算，避免与关卡控制器产生第二套 cell/world 规则。
func set_world_position(world_position: Vector2) -> void:
	position = world_position


## 切换拖拽预览或普通放置视觉。
## [br]is_preview 表示是否作为鼠标拖拽预览显示，is_valid 表示当前预览格是否合法。
## [br]无返回值；副作用是改变颜色、透明度、z_index 与缩放，提供合法/非法明显反馈。
## [br]边界条件：普通放置态忽略 is_valid；本函数只改视觉，不改库存、不改 RunState、不改 OccupancyRegistry。
func set_drag_preview(is_preview: bool, is_valid: bool) -> void:
	if is_preview:
		z_index = _PREVIEW_Z_INDEX
		scale = Vector2(1.08, 1.08)
		_shadow.color = Color(0.0, 0.0, 0.0, 0.28)
		if is_valid:
			_body.color = _VALID_PREVIEW_BODY_COLOR
			_inner_mark.color = _VALID_PREVIEW_MARK_COLOR
		else:
			_body.color = _INVALID_PREVIEW_BODY_COLOR
			_inner_mark.color = _INVALID_PREVIEW_MARK_COLOR
		return

	z_index = _PLACED_Z_INDEX
	scale = Vector2.ONE
	_shadow.color = Color(0.0, 0.0, 0.0, 0.18)
	_body.color = _PLACED_BODY_COLOR
	_inner_mark.color = _PLACED_MARK_COLOR


## 设置拖拽预览节点自身是否可见。
## [br]preview_is_visible 为 false 时只隐藏世界空间中的拖拽预览；为 true 时恢复该预览显示。
## [br]无返回值；副作用仅设置 visible，不改变 cell、mechanism_id、合法/非法颜色、库存或 OccupancyRegistry。
## [br]边界条件：本接口专用于 RuntimeObjects 下的世界拖拽预览；隐藏预览不等于取消拖拽，也不复用正式已放置机关的 set_placed_visible()。
func set_drag_preview_visible(preview_is_visible: bool) -> void:
	visible = preview_is_visible


## 设置正式已放置机关是否可见。
## [br]placed_is_visible 为 true 时显示正式机关，为 false 时隐藏正式机关。
## [br]无返回值；副作用是设置 visible。
## [br]边界条件：隐藏通常用于拖动已放置机关期间；隐藏不代表注销占用，旧逻辑占用仍由关卡控制器保留到松手提交。
func set_placed_visible(placed_is_visible: bool) -> void:
	visible = placed_is_visible
