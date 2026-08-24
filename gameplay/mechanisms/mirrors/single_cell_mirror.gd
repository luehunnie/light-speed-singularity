class_name SingleCellMirror
extends PlaceableToken

## 基础单格斜面镜机关（永久视觉接口 v1.0 §14）。
## 职责：保存单格镜面的唯一方向事实 orientation，提供“/”与“\”两种双面斜面镜视觉，并按八方向 Vector2i 入射方向返回反射方向。
## 视觉接入：orientation 是镜面朝向的唯一事实来源；通过 _content_state_id_for_orientation() 把 orientation 映射为
## ObjectVisualView 的内容状态 ID（SLASH → “slash”，BACKSLASH → “backslash”），由 VisualView 按 single_cell_mirror_visuals.tres 选取对应世界纹理；
## 拖拽预览复用同一内容状态，因此拖动已有镜面时保留当前方向图片，drag_texture 缺失时由 profile 自动回退到同状态 world_texture。
## 位置：作为 gameplay/mechanisms/mirrors 下的第一个正式光学机关，由核心闭环原型通过 OccupancyRegistry 查询到本节点后调用反射接口。
## 依赖：PlaceableToken 的通用放置 / 拖拽显示模式与反馈、ObjectVisualView 的内容状态接口、Vector2i 八方向整数向量，
## 以及本场景内作为调试后备的 MirrorLine 节点（正式纹理由 VisualView 承载，方向线默认隐藏）。
## 不负责：OccupancyRegistry 写入、库存、RunState 权限判断、鼠标输入、光线传播循环、水晶点亮、通关判断、分光、颜色、持续光线或多格机关体系。
## 关键规则：orientation 是镜面朝向的唯一事实来源；图片不得反过来决定反射逻辑，反射计算只读取 orientation；
## 布局编辑与内部配置锁定是不同概念，朝向修改只允许 SETUP，由关卡控制器在调用 toggle_orientation() 前判断。

enum MirrorOrientation {
	SLASH,
	BACKSLASH,
}

## 当前镜面朝向，是反射方向和镜面视觉的唯一事实来源。
## [br]默认 SLASH 表示从机关栏新拿出的镜面显示“/”；移动、回收取消或 R 重置不应把已有镜面强制恢复默认方向。
var orientation: MirrorOrientation = MirrorOrientation.SLASH

# 正式光交互契约（Guide §21）：形态声明入口 + 对称 interact_* 入口；Result/Context 经 preload 引用。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：镜面朝向字段。
const FIELD_ORIENTATION: StringName = &"orientation"

# 支持的八方向入射集合（正式传播恒为八方向；is_valid_incoming_direction_value 为唯一判定）。
# 内容状态 ID 契约：必须与 single_cell_mirror_visuals.tres 中 states 的 state_id 保持一致。
# slash（/，左下到右上）对应 large_mirror.png；backslash（\，左上到右下）对应 large_mirror_other.png。
const STATE_SLASH: StringName = &"slash"
const STATE_BACKSLASH: StringName = &"backslash"

# 调试方向线节点：正式纹理配置正常时默认隐藏，仅作占位后备，不参与玩法状态，不得成为正式美术表现。
@onready var _mirror_line: Line2D = $MirrorLine

# 镜面方向线占位点位，覆盖 64 世界格内可读范围（±28），不碰格边；仅用于调试后备，最终以张梓涵 64×64 正式美术素材为准。
var _slash_points: PackedVector2Array = PackedVector2Array([Vector2(-28.0, 28.0), Vector2(28.0, -28.0)])
var _backslash_points: PackedVector2Array = PackedVector2Array([Vector2(-28.0, -28.0), Vector2(28.0, 28.0)])
const _DEBUG_LINE_COLOR: Color = Color(0.03, 0.09, 0.14, 1.0)


## 初始化镜面方向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 orientation 把内容状态写入 ObjectVisualView 并刷新调试方向线点位，不修改占用、库存、RunState 或光路。
## [br]边界条件：从机关栏新实例化时默认显示 SLASH；已放置镜面拖拽预览的方向由关卡控制器在创建预览后通过 set_orientation() 复制；
## [br]若 set_orientation() 在节点 ready 前被调用，_refresh_orientation_visual() 会安全跳过，orientation 字段仍已写入，_ready() 时再按最终方向刷新视觉。
func _ready() -> void:
	_refresh_orientation_visual()


## 设置镜面的内部朝向配置。
## [br]new_orientation 是目标 MirrorOrientation，SLASH 表示“/”，BACKSLASH 表示“\”。
## [br]无返回值；副作用是写入 orientation 并通过 _refresh_orientation_visual() 同步视觉内容状态。
## [br]失败条件：传入枚举范围外的值时输出错误并保持原方向。
## [br]边界条件：本函数不自行判断 SETUP / PULSE_ACTIVE / MOVE_WINDOW / COMPLETED；朝向修改权限由关卡控制器的 can_edit_configuration() 控制，因此 PULSE_ACTIVE 和 MOVE_WINDOW 仍可移动布局但不能改内部配置；
## [br]所有 orientation 变化后立即同步视觉状态，保证图片与反射计算始终读取同一方向事实。
func set_orientation(new_orientation: MirrorOrientation) -> void:
	if new_orientation != MirrorOrientation.SLASH and new_orientation != MirrorOrientation.BACKSLASH:
		push_error("SingleCellMirror: 非法镜面朝向：%s" % [new_orientation])
		return
	orientation = new_orientation
	_refresh_orientation_visual()


## 在“/”与“\”之间切换镜面朝向。
## [br]本函数无参数、无返回值。
## [br]副作用：通过 set_orientation() 修改 orientation 并刷新视觉。
## [br]边界条件：本函数只表达内部配置变化本身；是否允许玩家右键触发由关卡控制器判断，当前仅 SETUP 可触发，COMPLETED 冻结时不会调用。
func toggle_orientation() -> void:
	if orientation == MirrorOrientation.SLASH:
		set_orientation(MirrorOrientation.BACKSLASH)
	else:
		set_orientation(MirrorOrientation.SLASH)


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "orientation" 解释枚举整数值并写入唯一朝向事实（经 set_orientation 同步视觉）。
## [br]配置含未知字段或缺 orientation 字段返回 false 且朝向不变；值越界由 set_orientation 拒绝并保持原朝向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_ORIENTATION)
	if not (value is int):
		push_error("SingleCellMirror: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_ORIENTATION])
		return false
	var next_orientation := value as MirrorOrientation
	if next_orientation != MirrorOrientation.SLASH and next_orientation != MirrorOrientation.BACKSLASH:
		push_error("SingleCellMirror: Typed 配置朝向越界：%s。" % [value])
		return false
	set_orientation(next_orientation)
	return true


## 根据当前镜面朝向反射一个八方向入射向量。
## [br]incoming_direction 是光进入镜面格时的传播方向，必须是非零且每个分量绝对值不超过 1 的 Vector2i 八方向单位向量。
## [br]返回反射后的 Vector2i 方向；非法入射方向返回 Vector2i.ZERO，调用方应安全停止传播。
## [br]本函数无副作用，不修改 orientation、占用、库存、水晶或光路视觉。
## [br]边界条件：基础版本采用双面反射；SLASH 使用 Vector2i(-direction.y, -direction.x)，BACKSLASH 使用 Vector2i(direction.y, direction.x)，不使用浮点角度、物理碰撞或 RayCast。
func reflect_direction(incoming_direction: Vector2i) -> Vector2i:
	return reflect_direction_for_orientation(orientation, incoming_direction)


## 声明本机关支持的光形态（Guide §21 正式契约面；Definition 侧声明的运行期镜像）。
## [br]镜面对 RAY 与 PARTICLE 均有反射响应；未声明形态由 Runtime 判透明，不调用 interact_*。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21）：按 orientation 反射入射方向。
## [br]ray_context 为 RayInteractionContext（只读事实快照）。
## [br]返回：合法入射 → REDIRECT(反射方向)；非法入射（零反射哨兵）→ BLOCK（与既有 Ray 链路停止语义一致）。
## [br]本函数无副作用；不改 orientation / 占用 / 传播状态，反射真值仍唯一来自 orientation。
func interact_ray(ray_context: Variant) -> _LightInteractionResult:
	var reflected: Vector2i = reflect_direction(ray_context.get_incoming_direction())
	if reflected == Vector2i.ZERO:
		return _LightInteractionResult.block_result()
	return _LightInteractionResult.redirect_result(reflected)


## PARTICLE 正式交互入口（Guide §21）：按 orientation 反射入射方向（改向不改速）。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照，速度档不参与镜面计算）。
## [br]返回：合法入射 → REDIRECT(反射方向)；非法入射 → CONTINUE（保持入射方向，与既有 Particle 安全降级一致）。
## [br]本函数无副作用；不产生 SpeedDelta（镜面不改速）。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	var reflected: Vector2i = reflect_direction(particle_context.get_incoming_direction())
	if reflected == Vector2i.ZERO:
		return _LightInteractionResult.continue_result()
	return _LightInteractionResult.redirect_result(reflected)


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


## 把当前 orientation 映射为 ObjectVisualView 的内容状态 ID。
## [br]本函数无参数。
## [br]返回 STATE_SLASH（“slash”）或 STATE_BACKSLASH（“backslash”）；本函数无副作用，不修改 orientation 或视觉。
## [br]边界条件：映射是单向的——图片不得反过来决定反射逻辑；调用方在 orientation 变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_orientation() -> StringName:
	return STATE_SLASH if orientation == MirrorOrientation.SLASH else STATE_BACKSLASH


## 按当前 orientation 刷新视觉：写入 ObjectVisualView 内容状态，并更新调试方向线点位。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换 slash / backslash 纹理，并更新 MirrorLine.points（调试后备，节点默认隐藏）。
## [br]边界条件：若节点尚未 ready 则安全返回，避免在 @onready 变量初始化前解引用；本视觉更新不反推逻辑方向，反射始终只读取 orientation；
## [br]切换显示模式（WORLD / DRAG_PREVIEW）不会改变内容状态，因此拖拽预览保留当前方向图片。
func _refresh_orientation_visual() -> void:
	if not is_node_ready():
		return
	_visual_view.set_content_state(_content_state_id_for_orientation())
	# 调试方向线：仅作占位后备，正式纹理由 VisualView 承载；点位随方向更新以便需要时开启调试。
	if orientation == MirrorOrientation.SLASH:
		_mirror_line.points = _slash_points
	else:
		_mirror_line.points = _backslash_points
	_mirror_line.default_color = _DEBUG_LINE_COLOR
