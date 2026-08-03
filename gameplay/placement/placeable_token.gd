class_name PlaceableToken
extends Node2D

## 核心闭环原型单格可放置机关通用视觉脚本（永久视觉接口 v1.0 §13）。
## 位置契约：position 是唯一场景位置事实；cell 由 position 经共享 GridCoordinateRules 确定性派生，
## 不持有可独立漂移的 cell 后备字段，不复制第二套 64×64 换算；set_cell/.cell 经 setter 把 position 对齐到格中心。
## 职责：保存原型机关的唯一 ID，按关卡控制器传入的 position 刷新显示，
## 通过 ObjectVisualView 统一承载正式放置态与拖拽预览态的纹理及合法 / 非法反馈，
## 不再让旧 ColorRect 占位承担正式机关图片或合法性反馈。
## 位置：由 levels/prototypes/core_loop_prototype.gd 在布置阶段实例化和驱动，用于验证库存、拖拽、占用登记、移动和回收流程；
## SingleCellMirror 等具体派生机关通过覆盖内容状态映射（slash / backslash 等）复用本类的通用显示模式与反馈。
## 依赖：Vector2i 格子坐标、StringName 机关 ID，以及本场景内挂载的 ObjectVisualView 子节点 VisualView。
## 视觉契约：本类只负责通用显示模式（WORLD / DRAG_PREVIEW）与反馈（NONE / VALID / INVALID），
## 具体内容状态由派生机关决定，本类不硬编码 slash / backslash 等状态 ID；
## 正式图片、拖拽图片与合法 / 非法覆盖层均由 ObjectVisualView 负责，本类不直接访问 TextureRect.texture，
## 也不通过修改正式图片的 color 或 self_modulate 表达合法 / 非法。
## 世界机关尺寸：世界视觉矩形由 ObjectVisualView 固定为 64×64（offsets -32～32），与 GridMetrics.SINGLE_CELL_WORLD_SIZE 一致；
## cell↔position 换算统一经 preload 共享模块 GridCoordinateRules，本脚本不复制第二套 64×64 公式；position 由关卡控制器的 cell_to_world() 或 set_world_position() 写入。
## UI 分离：CanvasLayer 机关栏 TokenIcon 等 UI 图标尺寸与世界机关尺寸相互独立，不随 64 世界格强制缩放。
## 不负责：地图合法性判断、OccupancyRegistry 写入、库存数量、RunState、光传播、阻挡、反射、颜色转换或通关判断。

## 格坐标纯换算规则唯一来源：preload 引用以避开 Godot MCP 运行期未重建全局 class 缓存的类型解析问题。
## 与 GridPlacedObject 共享同一模块，保证单格机关与世界固定格对象使用同一套 cell↔position 换算，无第二套 64×64 公式。
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

var mechanism_id: StringName = &""

## 格子坐标（Vector2i），由 position 确定性派生，非独立持久化事实。
## getter：position → world_to_cell；setter：cell_to_world → position。保留 .cell 访问兼容性。
## 不使用显式后备字段 / 元数据，不序列化第二份 cell；setter 不引用 cell，无递归。
var cell: Vector2i:
	get:
		return _GridCoordinateRules.world_to_cell(position)
	set(next_cell):
		position = _GridCoordinateRules.cell_to_world(next_cell)

## 通用视觉显示组件，承载正式 / 拖拽纹理与合法 / 非法 / 禁用反馈；由具体派生机关场景配置 visual_profile。
@onready var _visual_view: ObjectVisualView = $VisualView

# 层级常量：拖拽预览置于已放置机关之上，保证鼠标拖动时预览可见；与反馈颜色无关，只控制绘制顺序。
const _PLACED_Z_INDEX: int = 20
const _PREVIEW_Z_INDEX: int = 80
# 拖拽预览轻微放大，保留原型的拿取手感；不参与合法性判定，不影响坐标换算。
const _DRAG_PREVIEW_SCALE: Vector2 = Vector2(1.08, 1.08)


## 配置原型机关实例的基础数据。
## [br]id 是关卡控制器分配的唯一机关 ID，initial_cell 是当前逻辑格子。
## [br]无返回值；副作用是写入 mechanism_id，并经 cell setter 把 position 对齐到 initial_cell 格中心，再把视觉切换为正式放置态（WORLD + NONE）。
## [br]边界条件：允许预览节点使用临时 ID；本函数不验证 ID 唯一性、不判断格子合法性、不写占用表；
## [br]调用时机在 add_child 之后，VisualView 已完成 _ready，可安全驱动。
func configure(id: StringName, initial_cell: Vector2i) -> void:
	mechanism_id = id
	cell = initial_cell
	set_drag_preview(false, true)


## 更新机关的逻辑格子。
## [br]new_cell 是关卡控制器确认后的格子坐标。
## [br]无返回值；副作用是经 cell setter 把 position 对齐到 new_cell 格中心（cell 随 position 派生为 new_cell）。
## [br]边界条件：本函数不判断地图边界、墙体、水晶或占用；调用方必须在提交前完成合法性检查。
func set_cell(new_cell: Vector2i) -> void:
	cell = new_cell


## 读取当前派生格。委派给 cell getter，结果随 position 实时变化；保留 get_cell() 兼容接口。
## [br]无副作用，不修改 position、cell、视觉、库存或 OccupancyRegistry。
func get_cell() -> Vector2i:
	return cell


## 更新机关节点的世界位置。
## [br]world_position 是关卡控制器通过统一 cell_to_world() 或鼠标吸附规则计算出的世界坐标。
## [br]无返回值；副作用是设置 Node2D.position，cell 由该 position 派生，VisualView 位于本节点局部原点因此随之移动。
## [br]边界条件：本节点不复制第二套 cell/world 换算，cell 始终由 position 经共享 GridCoordinateRules 派生。
func set_world_position(world_position: Vector2) -> void:
	position = world_position


## 切换拖拽预览或普通放置视觉。
## [br]is_preview 表示是否作为鼠标拖拽预览显示，is_valid 表示当前预览格是否合法。
## [br]无返回值；副作用是通过 ObjectVisualView 切换显示模式与反馈，并调整 z_index 与缩放；
## [br]合法预览 → DRAG_PREVIEW + VALID，非法预览 → DRAG_PREVIEW + INVALID，正式放置 → WORLD + NONE。
## [br]边界条件：普通放置态忽略 is_valid；切换显示模式不改变具体机关内容状态（slash / backslash 等由派生机关维护）；
## [br]合法 / 非法反馈只通过 ObjectVisualView 的 FeedbackOverlay 表达，不直接修改正式图片 color 或 self_modulate；
## [br]本函数只改视觉，不改库存、不改 RunState、不改 OccupancyRegistry。
func set_drag_preview(is_preview: bool, is_valid: bool) -> void:
	if is_preview:
		z_index = _PREVIEW_Z_INDEX
		scale = _DRAG_PREVIEW_SCALE
		_visual_view.set_display_mode(ObjectVisualView.DisplayMode.DRAG_PREVIEW)
		# 合法 / 非法只改变覆盖层，不改变内容状态或纹理选取方向。
		_visual_view.set_feedback(
			ObjectVisualView.FeedbackState.VALID if is_valid else ObjectVisualView.FeedbackState.INVALID
		)
		return

	# 正式放置态：恢复层级与缩放，回到 WORLD 模式并清除任何放置反馈。
	z_index = _PLACED_Z_INDEX
	scale = Vector2.ONE
	_visual_view.set_display_mode(ObjectVisualView.DisplayMode.WORLD)
	_visual_view.set_feedback(ObjectVisualView.FeedbackState.NONE)


## 设置拖拽预览节点自身是否可见。
## [br]preview_is_visible 为 false 时只隐藏世界空间中的拖拽预览；为 true 时恢复该预览显示。
## [br]无返回值；副作用是通过 ObjectVisualView.set_visual_visible() 控制视觉组件可见性，不改变 cell、mechanism_id、内容状态、库存或 OccupancyRegistry。
## [br]边界条件：本接口专用于 RuntimeObjects 下的世界拖拽预览；隐藏预览不等于取消拖拽，也不复用正式已放置机关的 set_placed_visible()。
func set_drag_preview_visible(preview_is_visible: bool) -> void:
	_visual_view.set_visual_visible(preview_is_visible)


## 设置正式已放置机关是否可见。
## [br]placed_is_visible 为 true 时显示正式机关，为 false 时隐藏正式机关。
## [br]无返回值；副作用是通过 ObjectVisualView.set_visual_visible() 控制视觉组件可见性。
## [br]边界条件：隐藏通常用于拖动已放置机关期间；隐藏不代表注销占用，旧逻辑占用仍由关卡控制器保留到松手提交；
## [br]回收和销毁通过 queue_free() 清理节点，不会留下可见拖拽预览。
func set_placed_visible(placed_is_visible: bool) -> void:
	_visual_view.set_visual_visible(placed_is_visible)
