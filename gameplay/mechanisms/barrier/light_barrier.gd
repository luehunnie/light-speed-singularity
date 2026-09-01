@tool
class_name LightBarrier
extends PlaceableToken

## 光屏障机关（机关规则 光屏障 v0.6）。
## 职责：持有唯一薄膜朝向事实 orientation（4 薄膜朝向），实现正式光交互契约面
##   （get_light_interaction_forms + interact_ray / interact_particle，Guide §21）：
##   RAY 无论方向一律 BLOCK；PARTICLE 与薄膜面平行（共轴 2 向）→ BLOCK（撞棱角，任意速度），
##   其余 6 方向（含斜向）→ 速度门槛判定（慢速→BLOCK，标准/快速→CONTINUE + PARTICLE_SPEED_DELTA(-1)）。
## 共享根因（平行判定唯一实现点）：平行/穿过分区不写六份分支，唯一事实为 DirectionDomain.same_axis
##   （Guide §18 冻结的共轴纯函数，与滤光片「薄膜面平行 2 向停、其余 6 向穿过」共用同一共轴判定路径）。
## 关卡预置承载（与 滤光片/速度机关 共用同一最小共享路径）：继承 PlaceableToken →
##   关卡场景 RuntimeObjects 下实例化（light_barrier.tscn，interaction_profile="fixed"）→
##   PreplacedMechanismAdopter.adopt_all 收养 + OccupancyRegistry 单格注册 → core_loop._get_mechanism_node
##   按格解析机关节点；四向朝向经 Inspector @export orientation 或 Typed apply_configuration(FIELD_ORIENTATION)
##   在关卡制作阶段写入。玩家不可拿取/放置/移动/回收/改向；运行期 interact_* 为纯函数零写入
##   （R/Reload 不变量：屏障与朝向为预置事实，运行期任何路径不得修改 orientation）。
## 视觉：orientation 同步为 ObjectVisualView 内容状态与正式纹理旋转（四向共用一张竖膜纹理，
##   非竖直朝向经 set_artwork_rotation 旋转呈现，编辑器/运行期一致）；场景内 DebugFilm（薄膜线）
##   仅作纹理缺失时的占位后备，不参与玩法状态。
## 不负责：占用登记（Adopter 负责）、库存、视觉纹理、光粒 Tick 计算、SpeedTier 饱和（Runtime 负责）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## 薄膜朝向（4 种，定义薄膜面延伸方向）。
## [br]VERTICAL：竖 |，薄膜面沿 ↑↓；HORIZONTAL：横 —，沿 →←；SLASH：正斜 /，沿 ↗↙；BACKSLASH：反斜 \，沿 ↘↖。
enum BarrierOrientation {
	VERTICAL,
	HORIZONTAL,
	SLASH,
	BACKSLASH,
}


## 薄膜朝向，是平行判定（撞棱角）与薄膜线视觉的唯一事实来源。
## [br]默认 VERTICAL（竖），仅关卡制作阶段配置（Inspector / authored 配置）；进入游玩后锁定，玩家无修改入口。
@export_group("屏障朝向")
@export var orientation: BarrierOrientation = BarrierOrientation.VERTICAL : set = set_orientation

# 正式光交互契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
# 唯一八方向公共 Domain（Guide §18 冻结）：same_axis 为「薄膜面平行」共轴判定的唯一来源。
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
# 速度档位唯一事实来源（不自建第二份枚举；SLOW 档判定用）。
const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：薄膜朝向字段（枚举值序与 BarrierOrientation 一致）。
const FIELD_ORIENTATION: StringName = &"orientation"

# 调试薄膜节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _debug_film: Line2D = $DebugFilm


# 内容状态 ID 契约：必须与未来光屏障 visual profile 的 states state_id 保持一致（对齐滤光片 4 向）。
const STATE_VERTICAL: StringName = &"vertical"
const STATE_HORIZONTAL: StringName = &"horizontal"
const STATE_SLASH: StringName = &"slash"
const STATE_BACKSLASH: StringName = &"backslash"


## 初始化薄膜朝向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 orientation 把内容状态写入 ObjectVisualView 并刷新调试薄膜线，不修改占用、库存、RunState 或光路。
## [br]边界条件：若 set_orientation() 在节点 ready 前被调用，_refresh_visual() 会安全跳过，
## orientation 字段仍已写入，_ready() 时再按最终朝向刷新视觉。
func _ready() -> void:
	_refresh_visual()


## 按当前朝向刷新视觉：写入 ObjectVisualView 内容状态与正式纹理旋转，并更新调试薄膜线（沿薄膜切线方向）。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换朝向状态并按朝向旋转正式纹理
##   （四向共用一张竖膜纹理，旋转是朝向可见性的唯一来源）；正式纹理缺失时显示 DebugFilm、存在时隐藏。
## [br]边界条件：若节点尚未 ready 则安全返回，避免在 @onready 变量初始化前解引用。
func _refresh_visual() -> void:
	if not is_node_ready():
		return

	_visual_view.set_content_state(_content_state_id())
	_visual_view.set_artwork_rotation(_artwork_rotation(orientation))

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_debug_film.visible = not has_artwork
	if not has_artwork:
		var tangent: Vector2i = _tangent_vector(orientation)
		var film_end: Vector2 = Vector2(tangent) * 28
		_debug_film.points = PackedVector2Array([-film_end, film_end])


## 设置薄膜朝向（仅关卡制作阶段 / 测试配置入口）。
## [br]new_orientation 是目标 BarrierOrientation。
## [br]无返回值；副作用是写入 orientation（唯一朝向事实）并经 _refresh_visual() 同步视觉。
## [br]越界值 push_error 并保持原值；节点未 ready 时视觉刷新安全跳过（_ready 时按最终朝向刷新）。
func set_orientation(new_orientation: BarrierOrientation) -> void:
	if new_orientation < 0 or new_orientation > 3:
		push_error("LightBarrier: 非法薄膜朝向：%d" % [new_orientation])
		return
	orientation = new_orientation
	_refresh_visual()


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "orientation" 解释枚举整数值并写入唯一朝向事实（经 set_orientation 同步视觉）。
## [br]配置含未知字段或缺 orientation 字段返回 false 且朝向不变；值越界由 set_orientation 拒绝并保持原朝向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_ORIENTATION)
	if not (value is int):
		push_error("LightBarrier: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_ORIENTATION])
		return false
	var next_orientation := value as BarrierOrientation
	if next_orientation < 0 or next_orientation > 3:
		push_error("LightBarrier: Typed 配置朝向越界：%s。" % [value])
		return false
	set_orientation(next_orientation)
	return true


## 把当前朝向映射为 ObjectVisualView 的内容状态 ID。
## [br]本函数无参数。
## [br]返回 4 个 STATE_* 常量之一；无副作用，不修改朝向或视觉。
## [br]边界条件：映射单向——图片不得反过来决定逻辑；调用方在朝向变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id() -> StringName:
	match orientation:
		BarrierOrientation.VERTICAL:
			return STATE_VERTICAL
		BarrierOrientation.HORIZONTAL:
			return STATE_HORIZONTAL
		BarrierOrientation.SLASH:
			return STATE_SLASH
		BarrierOrientation.BACKSLASH:
			return STATE_BACKSLASH
		_:
			return STATE_VERTICAL


## 朝向 → 薄膜切线轴向量（same_axis 不区分正反，用一个单位向量代表轴）。
## [br]VERTICAL → ↑ 轴 (0,-1)；HORIZONTAL → → 轴 (1,0)；SLASH → ↗ 轴 (1,-1)；BACKSLASH → ↘ 轴 (1,1)。
## [br]越界朝向返回 Vector2i.ZERO（非法哨兵，调用方自行校验）。
## [br]本静态函数无副作用，不依赖实例状态。
static func _tangent_vector(orientation: BarrierOrientation) -> Vector2i:
	match orientation:
		BarrierOrientation.VERTICAL:
			return Vector2i(0, -1)
		BarrierOrientation.HORIZONTAL:
			return Vector2i(1, 0)
		BarrierOrientation.SLASH:
			return Vector2i(1, -1)
		BarrierOrientation.BACKSLASH:
			return Vector2i(1, 1)
		_:
			return Vector2i.ZERO


## 朝向 → 正式纹理旋转角（弧度；正式纹理按 VERTICAL 竖膜绘制，其余朝向旋转同一张贴图呈现）。
## [br]VERTICAL → 0；HORIZONTAL → PI/2；SLASH（/，沿 ↗↙）→ PI/4；BACKSLASH（\，沿 ↘↖）→ -PI/4；
##   越界朝向返回 0.0（回退竖膜，与 _content_state_id 的回退口径一致）。
## [br]本静态函数无副作用，不依赖实例状态；仅服务视觉同步，不参与玩法判定。
static func _artwork_rotation(orientation: BarrierOrientation) -> float:
	match orientation:
		BarrierOrientation.HORIZONTAL:
			return PI / 2.0
		BarrierOrientation.SLASH:
			return PI / 4.0
		BarrierOrientation.BACKSLASH:
			return -PI / 4.0
		_:
			return 0.0


## 判定入射方向是否与薄膜面平行（= 撞棱角，共 2 个方向）。
## [br]incoming 是光的八方向入射向量。
## [br]返回 true = 与薄膜切线共轴（撞棱角停止）；false = 其余 6 方向（含斜向，进入速度门槛判定）。
## [br]本函数无副作用；共轴事实唯一来源 DirectionDomain.same_axis（Guide §18 冻结，与滤光片共享）。
func is_edge_collision(incoming: Vector2i) -> bool:
	return _DirectionDomain.same_axis(incoming, _tangent_vector(orientation))


## 声明本机关支持的光形态（Guide §21 正式契约面）。
## [br]光屏障同时声明 RAY 与 PARTICLE：两形态都与其交互（RAY 恒停，PARTICLE 平行撞棱角/其余方向速度门槛）。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21 / 机关规则 §3.1）：RAY 永远不能穿过光屏障。
## [br]ray_context 为 RayInteractionContext（只读事实快照，本机关的方向判定与速度均与 RAY 无关）。
## [br]返回：恒 BLOCK——平行与其余六向全部在屏障格停止（§3.1 两行规则同归 BLOCK）。
## [br]本函数无副作用；不改 orientation / 占用 / 传播状态。
func interact_ray(_ray_context: Variant) -> _LightInteractionResult:
	return _LightInteractionResult.block_result()


## PARTICLE 正式交互入口（Guide §21 / 机关规则 §3.2）。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照）。
## [br]返回（顺序冻结：先薄膜平行判定再速度门槛）——
##   与薄膜面平行 2 方向 → BLOCK（撞棱角，任意速度）；其余 6 方向（含斜向）慢速 → BLOCK（能量不足）；
##   标准/快速 → CONTINUE + PARTICLE_SPEED_DELTA(-1)（通过后 -1 档，新档由 Runtime 从下一传播步生效）。
## [br]边界：非法 speed_tier 不会出现（Context 构造已校验）；防御分支按 BLOCK 安全关闭。
## [br]本函数无副作用；不 clamp SpeedTier（§24 饱和由 Runtime 应用），运行期零写入（R 不变量）。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	var incoming: Vector2i = particle_context.get_incoming_direction()
	if is_edge_collision(incoming):
		return _LightInteractionResult.block_result()
	match particle_context.get_speed_tier():
		_ParticleMotionRules.SpeedTier.STANDARD, _ParticleMotionRules.SpeedTier.FAST:
			return _LightInteractionResult.continue_result().add_speed_delta(-1)
		_:
			return _LightInteractionResult.block_result()
