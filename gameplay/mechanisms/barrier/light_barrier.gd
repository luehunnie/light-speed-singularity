@tool
class_name LightBarrier
extends PlaceableToken

## 光屏障机关（机关规则 光屏障 v0.4/v0.5）。
## 职责：持有唯一方向事实 direction（八向朝向 = 屏障穿越轴/法线），实现正式光交互契约面
##   （get_light_interaction_forms + interact_ray / interact_particle，Guide §21）：
##   RAY 无论方向一律 BLOCK；PARTICLE 仅与穿越轴完全共线的两个相反方向进入速度门槛判定
##   （慢速→BLOCK，标准/快速→CONTINUE + PARTICLE_SPEED_DELTA(-1)），其余六个方向一律 BLOCK（撞击边框/侧面）。
## 共享根因（六向判定唯一实现点）：轴向/非轴分区不写六份分支，唯一事实为 DirectionDomain.same_axis
##   （Guide §18 冻结的共轴纯函数，与滤光片「薄膜面平行 2 向停、其余 6 向穿过」共用同一共轴判定路径）；
##   枚举值序与 DirectionDomain.CLOCKWISE_ORDER 下标一一对齐（同 速度机关 约定，本脚本不自建向量表）。
## 关卡预置承载（与 滤光片/速度机关 共用同一最小共享路径）：继承 PlaceableToken →
##   关卡场景 RuntimeObjects 下实例化（light_barrier.tscn，interaction_profile="fixed"）→
##   PreplacedMechanismAdopter.adopt_all 收养 + OccupancyRegistry 单格注册 → core_loop._get_mechanism_node
##   按格解析机关节点；八向朝向经 Inspector @export direction 或 Typed apply_configuration(FIELD_DIRECTION)
##   在关卡制作阶段写入。玩家不可拿取/放置/移动/回收/改向；运行期 interact_* 为纯函数零写入
##   （R/Reload 不变量：屏障与朝向为预置事实，运行期任何路径不得修改 direction）。
## 视觉：direction 同步为 ObjectVisualView 内容状态 + Artwork 旋转（暂无 visual_profile，null 安全回退）；
##   场景内 DebugFilm（垂直薄膜线）仅作纹理缺失时的占位后备，不参与玩法状态。
## 不负责：两侧护墙校验（LevelValidator 域，明确延期）、占用登记（Adopter 负责）、库存、视觉纹理、
##   光粒 Tick 计算、SpeedTier 饱和（Runtime 负责）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


enum BarrierDirection {
	RIGHT,
	DOWN_RIGHT,
	DOWN,
	DOWN_LEFT,
	LEFT,
	UP_LEFT,
	UP,
	UP_RIGHT,
}


## 屏障穿越轴朝向（8 方向），是方向判定与视觉的唯一事实来源。
## [br]仅关卡制作阶段配置（Inspector / authored 配置）；进入游玩后锁定，玩家无修改入口。
@export_group("屏障朝向")
@export var direction: BarrierDirection = BarrierDirection.RIGHT : set = set_direction

# 正式光交互契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
# 唯一八方向公共 Domain（Guide §18 冻结）：same_axis 为轴向/六向非轴分区的唯一共轴判定。
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
# 速度档位唯一事实来源（不自建第二份枚举；SLOW 档判定用）。
const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：屏障朝向字段（枚举值序与 BarrierDirection 一致）。
const FIELD_DIRECTION: StringName = &"direction"

# 调试薄膜节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _debug_film: Line2D = $DebugFilm

# 占位薄膜线基准朝向为竖直（RIGHT 朝向时薄膜 ⊥ 穿越轴 → 沿 Y，film angle = PI/2）：
# 程序旋转角 = direction 角（基准薄膜竖直时旋转 direction 角恰使薄膜保持与穿越轴垂直）。
# 正式分方向美术落位后按贴图实际基准调整或移除程序旋转。
const _ARTWORK_BASE_ANGLE: float = 0.0

# 内容状态 ID 契约：必须与未来光屏障 visual profile 的 states state_id 保持一致（同速度机关约定）。
const STATE_RIGHT: StringName = &"right"
const STATE_DOWN_RIGHT: StringName = &"down_right"
const STATE_DOWN: StringName = &"down"
const STATE_DOWN_LEFT: StringName = &"down_left"
const STATE_LEFT: StringName = &"left"
const STATE_UP_LEFT: StringName = &"up_left"
const STATE_UP: StringName = &"up"
const STATE_UP_RIGHT: StringName = &"up_right"


## 初始化屏障方向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 direction 把内容状态写入 ObjectVisualView 并刷新调试薄膜线，不修改占用、库存、RunState 或光路。
## [br]边界条件：若 set_direction() 在节点 ready 前被调用，_refresh_direction_visual() 会安全跳过，
## direction 字段仍已写入，_ready() 时再按最终方向刷新视觉。
func _ready() -> void:
	_refresh_direction_visual()


## 按当前 direction 刷新视觉：写入 ObjectVisualView 内容状态，并更新调试薄膜线。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换方向状态并按 direction 派生 Artwork 旋转角
## （薄膜与穿越轴垂直），正式纹理可解析时隐藏 DebugFilm、缺失时显示并刷新其点位（占位后备）。
## [br]边界条件：若节点尚未 ready 则安全返回，避免在 @onready 变量初始化前解引用。
func _refresh_direction_visual() -> void:
	if not is_node_ready():
		return

	_visual_view.set_content_state(_content_state_id_for_direction())
	_visual_view.set_artwork_rotation(
		Vector2(direction_to_vector(direction)).angle() - _ARTWORK_BASE_ANGLE
	)

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_debug_film.visible = not has_artwork
	if not has_artwork:
		var film_axis: Vector2i = _film_axis_vector()
		var film_end: Vector2 = Vector2(film_axis * 28)
		_debug_film.points = PackedVector2Array([-film_end, film_end])


## 设置屏障朝向（仅关卡制作阶段 / 测试配置入口）。
## [br]new_dir 是目标 BarrierDirection。
## [br]无返回值；副作用是写入 direction（唯一方向事实）并经 _refresh_direction_visual() 同步视觉。
## [br]越界值 push_error 并保持原值，不猜测；节点未 ready 时视觉刷新安全跳过（_ready 时按最终方向刷新）。
func set_direction(new_dir: BarrierDirection) -> void:
	if new_dir < 0 or new_dir > 7:
		push_error("LightBarrier: 非法屏障朝向：%d" % [new_dir])
		return
	direction = new_dir
	_refresh_direction_visual()


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "direction" 解释枚举整数值并写入唯一方向事实（经 set_direction 同步视觉）。
## [br]配置含未知字段或缺 direction 字段返回 false 且方向不变；值越界由 set_direction 拒绝并保持原方向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_DIRECTION)
	if not (value is int):
		push_error("LightBarrier: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_DIRECTION])
		return false
	var next_direction := value as BarrierDirection
	if next_direction < 0 or next_direction > 7:
		push_error("LightBarrier: Typed 配置朝向越界：%s。" % [value])
		return false
	set_direction(next_direction)
	return true


## 把当前 direction 映射为 ObjectVisualView 的内容状态 ID。
## [br]本函数无参数。
## [br]返回 8 个 STATE_* 常量之一；无副作用，不修改 direction 或视觉。
## [br]边界条件：映射是单向的——图片不得反过来决定逻辑；调用方在 direction 变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_direction() -> StringName:
	match direction:
		BarrierDirection.RIGHT:
			return STATE_RIGHT
		BarrierDirection.DOWN_RIGHT:
			return STATE_DOWN_RIGHT
		BarrierDirection.DOWN:
			return STATE_DOWN
		BarrierDirection.DOWN_LEFT:
			return STATE_DOWN_LEFT
		BarrierDirection.LEFT:
			return STATE_LEFT
		BarrierDirection.UP_LEFT:
			return STATE_UP_LEFT
		BarrierDirection.UP:
			return STATE_UP
		BarrierDirection.UP_RIGHT:
			return STATE_UP_RIGHT
		_:
			return STATE_RIGHT


## 把 BarrierDirection 枚举值转换为穿越轴八方向单位向量。
## [br]dir 是目标朝向枚举值。
## [br]返回 Vector2i；越界值返回 Vector2i.ZERO（非法哨兵，调用方自行校验）。
## [br]本静态函数无副作用；向量事实唯一来源为 DirectionDomain（经 CLOCKWISE_ORDER 下标对齐换算，本脚本不自建映射表）。
static func direction_to_vector(dir: BarrierDirection) -> Vector2i:
	if dir < 0 or dir >= _DirectionDomain.CLOCKWISE_ORDER.size():
		return Vector2i.ZERO
	return _DirectionDomain.to_vector(_DirectionDomain.CLOCKWISE_ORDER[dir])


## 屏障薄膜轴（切线方向）单位向量：穿越轴逆时针旋转 90°（T=(-dy,dx)，机关规则 §2.2）。
## [br]本函数无参数；返回非零八方向向量之一；无副作用。护墙位置与占位薄膜线共用本切线事实。
func _film_axis_vector() -> Vector2i:
	var axis: Vector2i = direction_to_vector(direction)
	return Vector2i(-axis.y, axis.x)


## 判定入射方向是否与屏障穿越轴完全共线（唯一分区判定，非六份分支）。
## [br]incoming 是光的八方向入射向量。
## [br]返回 true = 落在穿越轴两端的 2 个方向之一（进入速度门槛判定）；
##   false = 其余 6 个非轴方向（一律撞击边框/侧面 BLOCK）或非法向量（安全按非轴处理）。
## [br]本函数无副作用；共轴事实唯一来源 DirectionDomain.same_axis（Guide §18 冻结，与滤光片共享）。
func is_on_traversal_axis(incoming: Vector2i) -> bool:
	return _DirectionDomain.same_axis(incoming, direction_to_vector(direction))


## 声明本机关支持的光形态（Guide §21 正式契约面）。
## [br]光屏障同时声明 RAY 与 PARTICLE：两形态都与其交互（RAY 恒停，PARTICLE 速度门槛/六向阻挡）。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21 / 机关规则 §3.1）：RAY 永远不能穿过光屏障。
## [br]ray_context 为 RayInteractionContext（只读事实快照，本机关的方向门槛与速度均与 RAY 无关）。
## [br]返回：恒 BLOCK——轴向与非轴向六向全部在屏障格停止（§3.1 两行规则同归 BLOCK）。
## [br]本函数无副作用；不改 direction / 占用 / 传播状态。
func interact_ray(_ray_context: Variant) -> _LightInteractionResult:
	return _LightInteractionResult.block_result()


## PARTICLE 正式交互入口（Guide §21 / 机关规则 §3.2）。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照）。
## [br]返回（顺序冻结：先方向分区再速度门槛）——
##   非穿越轴 6 方向 → BLOCK（撞击边框/侧面）；轴向慢速 → BLOCK（能量不足）；
##   轴向标准/快速 → CONTINUE + PARTICLE_SPEED_DELTA(-1)（通过后 -1 档，新档由 Runtime 从下一传播步生效）。
## [br]边界：非法 speed_tier 不会出现（Context 构造已校验）；防御分支按 BLOCK 安全关闭。
## [br]本函数无副作用；不 clamp SpeedTier（§24 饱和由 Runtime 应用），运行期零写入（R 不变量）。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	var incoming: Vector2i = particle_context.get_incoming_direction()
	if not is_on_traversal_axis(incoming):
		return _LightInteractionResult.block_result()
	match particle_context.get_speed_tier():
		_ParticleMotionRules.SpeedTier.STANDARD, _ParticleMotionRules.SpeedTier.FAST:
			return _LightInteractionResult.continue_result().add_speed_delta(-1)
		_:
			return _LightInteractionResult.block_result()
