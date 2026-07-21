class_name SingleCellMirror
extends PlaceableToken

## 基础单格斜面镜机关。
## 职责：保存单格镜面的唯一方向事实 orientation，提供“/”与“\”两种双面斜面镜视觉，并按八方向 Vector2i 入射方向返回反射方向。
## 位置：作为 gameplay/mechanisms/mirrors 下的第一个正式光学机关，由核心闭环原型通过 OccupancyRegistry 查询到本节点后调用反射接口。
## 依赖：PlaceableToken 的单格放置/拖拽视觉基础、Vector2i 八方向整数向量，以及本场景内的 MirrorLine 节点。
## 不负责：OccupancyRegistry 写入、库存、RunState 权限判断、鼠标输入、光线传播循环、水晶点亮、通关判断、分光、颜色、持续光线或多格机关体系。
## 关键规则：orientation 是镜面朝向的唯一事实来源；布局编辑与内部配置锁定是不同概念，朝向修改只允许 SETUP，由关卡控制器在调用 toggle_orientation() 前判断。

enum MirrorOrientation {
	SLASH,
	BACKSLASH,
}

## 当前镜面朝向，是反射方向和镜面视觉的唯一事实来源。
## [br]默认 SLASH 表示从机关栏新拿出的镜面显示“/”；移动、回收取消或 R 重置不应把已有镜面强制恢复默认方向。
var orientation: MirrorOrientation = MirrorOrientation.SLASH

@onready var _mirror_line: Line2D = $MirrorLine

# 镜面方向线占位点位，覆盖 64 世界格内可读范围（±28），不碰格边；最终以张梓涵 64×64 正式美术素材替换为准。
var _slash_points: PackedVector2Array = PackedVector2Array([Vector2(-28.0, 28.0), Vector2(28.0, -28.0)])
var _backslash_points: PackedVector2Array = PackedVector2Array([Vector2(-28.0, -28.0), Vector2(28.0, 28.0)])
const _PLACED_LINE_COLOR: Color = Color(0.03, 0.09, 0.14, 1.0)
const _VALID_PREVIEW_LINE_COLOR: Color = Color(0.02, 0.18, 0.06, 1.0)
const _INVALID_PREVIEW_LINE_COLOR: Color = Color(0.95, 0.95, 0.95, 1.0)

var _is_preview_mode: bool = false
var _preview_is_valid: bool = true


## 初始化镜面方向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：只按当前 orientation 刷新 MirrorLine 点位和颜色，不修改占用、库存、RunState 或光路。
## [br]边界条件：从机关栏新实例化时默认显示 SLASH；已放置镜面拖拽预览的方向由关卡控制器在创建预览后复制。
func _ready() -> void:
	_update_orientation_visual()


## 设置镜面的内部朝向配置。
## [br]new_orientation 是目标 MirrorOrientation，SLASH 表示“/”，BACKSLASH 表示“\”。
## [br]无返回值；副作用是写入 orientation 并刷新镜面方向视觉。
## [br]失败条件：传入枚举范围外的值时输出错误并保持原方向。
## [br]边界条件：本函数不自行判断 SETUP / PULSE_ACTIVE / MOVE_WINDOW / COMPLETED；朝向修改权限由关卡控制器的 can_edit_configuration() 控制，因此 PULSE_ACTIVE 和 MOVE_WINDOW 仍可移动布局但不能改内部配置。
func set_orientation(new_orientation: MirrorOrientation) -> void:
	if new_orientation != MirrorOrientation.SLASH and new_orientation != MirrorOrientation.BACKSLASH:
		push_error("SingleCellMirror: 非法镜面朝向：%s" % [new_orientation])
		return
	orientation = new_orientation
	_update_orientation_visual()


## 在“/”与“\”之间切换镜面朝向。
## [br]本函数无参数、无返回值。
## [br]副作用：通过 set_orientation() 修改 orientation 并刷新视觉。
## [br]边界条件：本函数只表达内部配置变化本身；是否允许玩家右键触发由关卡控制器判断，当前仅 SETUP 可触发，COMPLETED 冻结时不会调用。
func toggle_orientation() -> void:
	if orientation == MirrorOrientation.SLASH:
		set_orientation(MirrorOrientation.BACKSLASH)
	else:
		set_orientation(MirrorOrientation.SLASH)


## 根据当前镜面朝向反射一个八方向入射向量。
## [br]incoming_direction 是光进入镜面格时的传播方向，必须是非零且每个分量绝对值不超过 1 的 Vector2i 八方向单位向量。
## [br]返回反射后的 Vector2i 方向；非法入射方向返回 Vector2i.ZERO，调用方应安全停止传播。
## [br]本函数无副作用，不修改 orientation、占用、库存、水晶或光路视觉。
## [br]边界条件：基础版本采用双面反射；SLASH 使用 Vector2i(-direction.y, -direction.x)，BACKSLASH 使用 Vector2i(direction.y, direction.x)，不使用浮点角度、物理碰撞或 RayCast。
func reflect_direction(incoming_direction: Vector2i) -> Vector2i:
	return reflect_direction_for_orientation(orientation, incoming_direction)


## 判断一个入射方向是否可用于单格镜面反射。
## [br]direction 是待检查的 Vector2i 方向。
## [br]返回 true 表示 direction 是八方向单位向量；返回 false 表示 Vector2i.ZERO、任一分量绝对值大于 1 或其他非法方向，反射应返回 Vector2i.ZERO。
## [br]本函数无副作用；边界条件：Godot 的 Vector2i 为整数向量，因此非零且两个分量均在 -1 到 1 间即覆盖全部八方向。
func is_valid_incoming_direction(direction: Vector2i) -> bool:
	return is_valid_incoming_direction_value(direction)


## 按指定镜面朝向执行无节点、无副作用的反射计算。
## [br]mirror_orientation 是要使用的 MirrorOrientation，incoming_direction 是入射方向。
## [br]返回反射后的八方向 Vector2i；非法方向或非法朝向返回 Vector2i.ZERO。
## [br]本静态函数无副作用，可供 debug 自检直接验证至少 16 组合法映射，不创建镜面节点、不修改真实镜面、不触发光线。
## [br]边界条件：orientation 仍是运行中镜面方向的唯一事实来源；本函数只是把同一方向事实作为参数传入以支持纯函数自检。
static func reflect_direction_for_orientation(mirror_orientation: MirrorOrientation, incoming_direction: Vector2i) -> Vector2i:
	if not is_valid_incoming_direction_value(incoming_direction):
		return Vector2i.ZERO

	if mirror_orientation == MirrorOrientation.SLASH:
		return Vector2i(-incoming_direction.y, -incoming_direction.x)
	if mirror_orientation == MirrorOrientation.BACKSLASH:
		return Vector2i(incoming_direction.y, incoming_direction.x)

	return Vector2i.ZERO


## 执行无节点、无副作用的入射方向合法性检查。
## [br]direction 是待检查的 Vector2i 方向。
## [br]返回 true 表示可作为八方向入射方向；返回 false 表示反射调用应得到 Vector2i.ZERO。
## [br]边界条件：该静态函数用于启动自检，不能访问场景树、真实镜面、OccupancyRegistry、库存或光路。
static func is_valid_incoming_direction_value(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 切换普通放置态或拖拽预览态视觉，并保持镜面朝向线可辨认。
## [br]is_preview 表示是否处于拖拽预览，is_valid 表示预览格是否合法。
## [br]无返回值；副作用是调用 PlaceableToken 的通用预览颜色逻辑，并刷新 MirrorLine 颜色和方向点位。
## [br]边界条件：拖动已有镜面时，关卡控制器会先复制 orientation，因此预览线方向必须保留当前朝向；合法和非法预览只改变视觉反馈，不改变 orientation 或占用。
func set_drag_preview(is_preview: bool, is_valid: bool) -> void:
	_is_preview_mode = is_preview
	_preview_is_valid = is_valid
	super.set_drag_preview(is_preview, is_valid)
	_update_orientation_visual()


## 按当前 orientation 和预览状态刷新镜面方向线。
## [br]本函数无参数、无返回值。
## [br]副作用：只修改 MirrorLine.points 与 MirrorLine.default_color。
## [br]边界条件：若节点尚未 ready 则安全返回；本视觉更新不反推逻辑方向，反射始终只读取 orientation。
func _update_orientation_visual() -> void:
	if not is_node_ready():
		return
	if orientation == MirrorOrientation.SLASH:
		_mirror_line.points = _slash_points
	else:
		_mirror_line.points = _backslash_points
	_mirror_line.default_color = _get_mirror_line_color()


## 取得当前镜面线条颜色。
## [br]本函数无参数。
## [br]返回用于 MirrorLine.default_color 的 Color；本函数无副作用。
## [br]边界条件：普通放置态、合法预览和非法预览使用不同颜色，保证镜面方向视觉与放置反馈同时可辨认。
func _get_mirror_line_color() -> Color:
	if not _is_preview_mode:
		return _PLACED_LINE_COLOR
	return _VALID_PREVIEW_LINE_COLOR if _preview_is_valid else _INVALID_PREVIEW_LINE_COLOR
