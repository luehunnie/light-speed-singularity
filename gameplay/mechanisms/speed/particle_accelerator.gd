class_name ParticleAccelerator
extends PlaceableToken

## 光粒加速器机关（对标 SingleCellMirror 接口模式）。
## 职责：保存加速器的唯一方向事实 direction，提供 8 方向顺时针循环切换，未来光粒系统就绪后
## 对匹配方向的光粒执行 +1 速度档位（慢速→标准→快速，不超过最高档）；对光线（RAY 形态）穿透无影响。
## 视觉接入：direction 是方向的唯一事实来源；通过 _content_state_id_for_direction() 映射为
## ObjectVisualView 的内容状态 ID，由 VisualView 按 particle_accelerator_visuals.tres 选取对应纹理；
## 拖拽预览复用同一内容状态，drag_texture 缺失时由 profile 自动回退到同状态 world_texture。
## 位置：gameplay/mechanisms/speed/ 下的第一个速度型机关。
## 依赖：PlaceableToken 的通用放置/拖拽显示模式与反馈、ObjectVisualView 的内容状态接口、Vector2i 八方向整数向量，
## 以及本场景内作为调试后备的 DebugArrow 节点（正式纹理由 VisualView 承载，箭头默认隐藏）。
## 不负责：OccupancyRegistry 写入、库存、RunState 权限判断、鼠标输入、光粒传播循环、水晶点亮、通关判断。
## 关键规则：direction 是方向的唯一事实来源；图片不得反过来决定逻辑；方向修改仅允许 SETUP，
## 由关卡控制器在调用 cycle_direction() 前判断；速度修正仅对光粒形态生效。


enum AcceleratorDirection {
	RIGHT,
	DOWN_RIGHT,
	DOWN,
	DOWN_LEFT,
	LEFT,
	UP_LEFT,
	UP,
	UP_RIGHT,
}


## 当前加速方向，是加速判定和视觉外观的唯一事实来源。
## [br]默认 RIGHT 表示从机关栏新拿出的加速器箭头指向 →。
var direction: AcceleratorDirection = AcceleratorDirection.RIGHT

# 正式光交互契约（Guide §21）：形态声明入口 + interact_particle 入口；Result 经 preload 引用。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：加速方向字段（枚举值序与 AcceleratorDirection 一致）。
const FIELD_DIRECTION: StringName = &"direction"

# 调试箭头节点：正式纹理配置正常时默认隐藏，仅作占位后备，不参与玩法状态。
@onready var _debug_arrow: Line2D = $DebugArrow

# 内容状态 ID 契约：必须与 particle_accelerator_visuals.tres 中 states 的 state_id 保持一致。
const STATE_RIGHT: StringName = &"right"
const STATE_DOWN_RIGHT: StringName = &"down_right"
const STATE_DOWN: StringName = &"down"
const STATE_DOWN_LEFT: StringName = &"down_left"
const STATE_LEFT: StringName = &"left"
const STATE_UP_LEFT: StringName = &"up_left"
const STATE_UP: StringName = &"up"
const STATE_UP_RIGHT: StringName = &"up_right"


## 初始化加速方向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 direction 把内容状态写入 ObjectVisualView 并刷新调试箭头点位，不修改占用、库存、RunState 或光路。
## [br]边界条件：若 set_direction() 在节点 ready 前被调用，_refresh_direction_visual() 会安全跳过，
## direction 字段仍已写入，_ready() 时再按最终方向刷新视觉。
func _ready() -> void:
	_refresh_direction_visual()


## 按当前 direction 刷新视觉：写入 ObjectVisualView 内容状态，并更新调试箭头方向。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换方向纹理，并更新 DebugArrow.points（调试后备，节点默认隐藏）。
## [br]边界条件：若节点尚未 ready 则安全返回，避免在 @onready 变量初始化前解引用；
## 切换显示模式（WORLD/DRAG_PREVIEW）不会改变内容状态，因此拖拽预览保留当前方向图片。
func _refresh_direction_visual() -> void:
	if not is_node_ready():
		return

	_visual_view.set_content_state(_content_state_id_for_direction())

	var arrow_end: Vector2i = direction_to_vector(direction) * 28
	_debug_arrow.points = PackedVector2Array([Vector2.ZERO, Vector2(arrow_end)])


## 设置加速器的内部方向配置。
## [br]new_dir 是目标 AcceleratorDirection。
## [br]无返回值；副作用是写入 direction 并通过 _refresh_direction_visual() 同步视觉内容状态。
## [br]失败条件：传入 0~7 范围外的值时输出错误并保持原方向。
## [br]边界条件：本函数不自行判断 SETUP/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED；
## 方向修改权限由关卡控制器的 can_edit_configuration() 控制；
## 所有 direction 变化后立即同步视觉状态，保证图片与逻辑始终读取同一方向事实。
func set_direction(new_dir: AcceleratorDirection):
	if new_dir < 0 or new_dir > 7:
		push_error("ParticleAccelerator: 非法加速方向：%d" % [new_dir])
		return

	direction = new_dir
	_refresh_direction_visual()


## 顺时针循环切换加速方向：RIGHT → DOWN_RIGHT → ... → UP_RIGHT → RIGHT。
## [br]本函数无参数、无返回值。
## [br]副作用：通过 (direction + 1) % 8 修改 direction 并刷新视觉。
## [br]边界条件：本函数只表达内部配置变化本身；是否允许玩家右键触发由关卡控制器判断，当前仅 SETUP 可触发。
func cycle_direction() -> void:
	direction = (direction + 1) % 8 as AcceleratorDirection
	_refresh_direction_visual()


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "direction" 解释枚举整数值并写入唯一方向事实（经 set_direction 同步视觉）。
## [br]配置含未知字段或缺 direction 字段返回 false 且方向不变；值越界由 set_direction 拒绝并保持原方向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_DIRECTION)
	if not (value is int):
		push_error("ParticleAccelerator: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_DIRECTION])
		return false
	var next_direction := value as AcceleratorDirection
	if next_direction < 0 or next_direction > 7:
		push_error("ParticleAccelerator: Typed 配置方向越界：%s。" % [value])
		return false
	set_direction(next_direction)
	return true


## 把当前 direction 映射为 ObjectVisualView 的内容状态 ID。
## [br]本函数无参数。
## [br]返回 8 个 STATE_* 常量之一；无副作用，不修改 direction 或视觉。
## [br]边界条件：映射是单向的——图片不得反过来决定逻辑；调用方在 direction 变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_direction() -> StringName:
	match direction:
		AcceleratorDirection.RIGHT:
			return STATE_RIGHT
		AcceleratorDirection.DOWN_RIGHT:
			return STATE_DOWN_RIGHT
		AcceleratorDirection.DOWN:
			return STATE_DOWN
		AcceleratorDirection.DOWN_LEFT:
			return STATE_DOWN_LEFT
		AcceleratorDirection.LEFT:
			return STATE_LEFT
		AcceleratorDirection.UP_LEFT:
			return STATE_UP_LEFT
		AcceleratorDirection.UP:
			return STATE_UP
		AcceleratorDirection.UP_RIGHT:
			return STATE_UP_RIGHT
		_:
			return STATE_RIGHT


## 把 AcceleratorDirection 枚举值转换为对应的八方向单位向量。
## [br]dir 是目标方向枚举值。
## [br]返回 Vector2i 方向向量；非法方向返回 Vector2i.ZERO。
## [br]本静态函数无副作用，不依赖实例状态，可供启动自检直接调用验证。
static func direction_to_vector(dir: AcceleratorDirection) -> Vector2i:
	match dir:
		AcceleratorDirection.RIGHT:
			return Vector2i(1, 0)
		AcceleratorDirection.DOWN_RIGHT:
			return Vector2i(1, 1)
		AcceleratorDirection.DOWN:
			return Vector2i(0, 1)
		AcceleratorDirection.DOWN_LEFT:
			return Vector2i(-1, 1)
		AcceleratorDirection.LEFT:
			return Vector2i(-1, 0)
		AcceleratorDirection.UP_LEFT:
			return Vector2i(-1, -1)
		AcceleratorDirection.UP:
			return Vector2i(0, -1)
		AcceleratorDirection.UP_RIGHT:
			return Vector2i(1, -1)
		_:
			return Vector2i.ZERO


## 启动自检：验证 8 方向向量映射无零向量返回。
## [br]本函数无参数。
## [br]返回 true 表示 8 个方向全部映射到非零向量；任一方向返回 ZERO 则返回 false。
## [br]本静态函数无副作用，不访问场景树、节点、库存或光路。
static func validate_direction_vectors() -> bool:
	for dir: int in range(8):
		if direction_to_vector(dir as AcceleratorDirection) == Vector2i.ZERO:
			return false
	return true


## 判断入射光粒方向是否与当前加速方向一致。
## [br]incoming 是光粒的八方向运动向量。
## [br]返回 true 表示方向匹配，应触发加速；false 表示穿透无影响。
## [br]本函数无副作用，不修改 direction、视觉或任何系统状态。
func matches_direction(incoming: Vector2i) -> bool:
	return incoming == direction_to_vector(direction)


## 返回速度修正值。
## [br]incoming 是光粒的八方向运动向量。
## [br]返回 1 表示方向匹配应加速一档；返回 0 表示不匹配穿透无影响。
## [br]本函数无副作用；边界条件：速度档位上下限保护由光粒系统负责，本函数只返回修正量。
func get_speed_modifier(incoming: Vector2i) -> int:
	return 1 if matches_direction(incoming) else 0


## 声明本机关支持的光形态（Guide §21 正式契约面；Definition 侧声明的运行期镜像）。
## [br]加速器仅声明 PARTICLE 交互；RAY 未声明 → Runtime 判透明直通（Guide §21 示例语义）。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"PARTICLE"]


## PARTICLE 正式交互入口（Guide §21）：方向匹配 → CONTINUE + PARTICLE_SPEED_DELTA(+1)；不匹配 → 透明 CONTINUE。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照）。
## [br]边界：只请求 +1 档位增量（Guide §24 速度修改仅允许 ±1），档位饱和由 Runtime 应用；
##   不改传播方向（CONTINUE），不产生 OUTPUT_EVENT。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	var modifier: int = get_speed_modifier(particle_context.get_incoming_direction())
	var result: _LightInteractionResult = _LightInteractionResult.continue_result()
	if modifier != 0:
		result.add_speed_delta(modifier)
	return result
