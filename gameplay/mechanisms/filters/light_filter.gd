@tool
class_name LightFilter
extends PlaceableToken

## 滤光片机关（机关规则 滤光片 v0.1）。
## 职责：持有唯一朝向事实 orientation（4 薄膜朝向）与唯一颜色事实 color（红/绿/蓝），实现正式光交互契约面
##   （get_light_interaction_forms + interact_ray / interact_particle，Guide §21）：
##   RAY 与薄膜面平行（共轴 2 向）→ BLOCK（撞棱角）；穿过薄膜 → 滤色（白光→单色 / 同色保持 / 异色吸收 BLOCK）；
##   PARTICLE 任意方向 → BLOCK（光粒被阻挡，不改速）。
## 共享根因：共轴判定唯一事实为 DirectionDomain.same_axis（Guide §18），与光屏障共用同一共轴路径；
##   滤色规则为滤光片私有（白光→单色/同色保持/异色吸收，玩法设计 §6 已冻结），不进公共 ray_color.gd。
## 关卡预置承载（与 光屏障/速度机关 共用同一最小共享路径）：继承 PlaceableToken →
##   关卡场景 RuntimeObjects 下实例化（light_filter.tscn，interaction_profile="fixed"）→
##   PreplacedMechanismAdopter.adopt_all 收养 + OccupancyRegistry 单格注册 → 传播核心按格解析机关节点；
##   朝向与颜色在制作阶段经 Inspector @export 或 Typed apply_configuration 写入。玩家不可拿取/放置/移动/回收。
## 视觉：朝向同步为 ObjectVisualView 内容状态（颜色维度后置，视觉 profile 待补）；DebugFilm（薄膜线）作纹理缺失回退。
## 不负责：颜色视觉映射（属视觉层）、光粒 Tick、库存、占用登记（Adopter 负责）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## 薄膜朝向（4 种，定义薄膜面延伸方向）。
## [br]VERTICAL：竖 |，薄膜面沿 ↑↓；HORIZONTAL：横 —，沿 →←；SLASH：正斜 /，沿 ↗↙；BACKSLASH：反斜 \，沿 ↘↖。
enum FilterOrientation {
	VERTICAL,
	HORIZONTAL,
	SLASH,
	BACKSLASH,
}

## 滤光颜色（3 种，不存在白色滤光片）。
enum FilterColor {
	RED,
	GREEN,
	BLUE,
}


## 薄膜朝向，是共轴判定（撞棱角）与薄膜线视觉的唯一事实来源。
## [br]默认 VERTICAL（竖），仅关卡制作阶段配置；进入游玩后锁定，玩家无修改入口。
@export_group("滤光片配置")
@export var orientation: FilterOrientation = FilterOrientation.VERTICAL : set = set_orientation
## 滤光颜色，是滤色判定的唯一事实来源。
## [br]默认 RED，仅关卡制作阶段配置。
@export var color: FilterColor = FilterColor.RED : set = set_color


# 正式光交互契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
# 唯一八方向公共 Domain（Guide §18 冻结）：same_axis 为"薄膜面平行"共轴判定唯一来源。
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
# 玩法颜色唯一事实来源（ColorValue 枚举 + is_valid）。
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：薄膜朝向字段 + 滤光颜色字段。
const FIELD_ORIENTATION: StringName = &"orientation"
const FIELD_COLOR: StringName = &"color"

# 调试薄膜线节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _debug_film: Line2D = $DebugFilm

# 内容状态 ID 契约：必须与未来滤光片 visual profile 的 states state_id 保持一致（颜色维度后置，先按朝向 4 态）。
const STATE_VERTICAL: StringName = &"vertical"
const STATE_HORIZONTAL: StringName = &"horizontal"
const STATE_SLASH: StringName = &"slash"
const STATE_BACKSLASH: StringName = &"backslash"


## 初始化薄膜朝向与颜色视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 orientation 把内容状态写入 ObjectVisualView 并刷新调试薄膜线，不修改占用、库存、RunState 或光路。
func _ready() -> void:
	_refresh_visual()


## 按当前朝向刷新视觉：写入 ObjectVisualView 内容状态，并更新调试薄膜线（沿薄膜切线方向）。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换朝向状态；正式纹理缺失时显示 DebugFilm、存在时隐藏。
## [br]边界条件：若节点尚未 ready 则安全返回；颜色维度视觉后置，暂不随 color 变化。
func _refresh_visual() -> void:
	if not is_node_ready():
		return

	_visual_view.set_content_state(_content_state_id())

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_debug_film.visible = not has_artwork
	if not has_artwork:
		var tangent: Vector2i = _tangent_vector(orientation)
		var film_end: Vector2 = Vector2(tangent) * 28
		_debug_film.points = PackedVector2Array([-film_end, film_end])


## 设置薄膜朝向（仅关卡制作阶段 / 测试配置入口）。
## [br]new_orientation 是目标 FilterOrientation。
## [br]无返回值；副作用是写入 orientation（唯一朝向事实）并经 _refresh_visual() 同步视觉。
## [br]越界值 push_error 并保持原值；节点未 ready 时视觉刷新安全跳过。
func set_orientation(new_orientation: FilterOrientation) -> void:
	if new_orientation < 0 or new_orientation > 3:
		push_error("LightFilter: 非法薄膜朝向：%d" % [new_orientation])
		return
	orientation = new_orientation
	_refresh_visual()


## 设置滤光颜色（仅关卡制作阶段 / 测试配置入口）。
## [br]new_color 是目标 FilterColor。
## [br]无返回值；副作用是写入 color（唯一颜色事实）并经 _refresh_visual() 同步视觉。
## [br]越界值 push_error 并保持原值。
func set_color(new_color: FilterColor) -> void:
	if new_color < 0 or new_color > 2:
		push_error("LightFilter: 非法滤光颜色：%d" % [new_color])
		return
	color = new_color
	_refresh_visual()


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "orientation" / "color" 解释枚举整数值并写入唯一事实（经 set_* 同步视觉）。
## [br]配置含未知字段或缺字段返回 false 且状态不变；值越界由 set_* 拒绝并保持原值。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var orientation_value: Variant = configuration.get_value(FIELD_ORIENTATION)
	if not (orientation_value is int):
		push_error("LightFilter: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_ORIENTATION])
		return false
	var next_orientation := orientation_value as FilterOrientation
	if next_orientation < 0 or next_orientation > 3:
		push_error("LightFilter: Typed 配置朝向越界：%s。" % [orientation_value])
		return false
	var color_value: Variant = configuration.get_value(FIELD_COLOR)
	if not (color_value is int):
		push_error("LightFilter: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_COLOR])
		return false
	var next_color := color_value as FilterColor
	if next_color < 0 or next_color > 2:
		push_error("LightFilter: Typed 配置颜色越界：%s。" % [color_value])
		return false
	set_orientation(next_orientation)
	set_color(next_color)
	return true


## 把当前朝向映射为 ObjectVisualView 的内容状态 ID。
## [br]返回 4 个 STATE_* 常量之一；无副作用，不修改朝向或视觉。
## [br]边界条件：映射单向——图片不得反过来决定滤色逻辑；调用方在朝向变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id() -> StringName:
	match orientation:
		FilterOrientation.VERTICAL:
			return STATE_VERTICAL
		FilterOrientation.HORIZONTAL:
			return STATE_HORIZONTAL
		FilterOrientation.SLASH:
			return STATE_SLASH
		FilterOrientation.BACKSLASH:
			return STATE_BACKSLASH
		_:
			return STATE_VERTICAL


## 朝向 → 薄膜切线轴向量（same_axis 不区分正反，用一个单位向量代表轴）。
## [br]VERTICAL → ↑ 轴 (0,-1)；HORIZONTAL → → 轴 (1,0)；SLASH → ↗ 轴 (1,-1)；BACKSLASH → ↘ 轴 (1,1)。
## [br]越界朝向返回 Vector2i.ZERO（非法哨兵，调用方自行校验）。
## [br]本静态函数无副作用，不依赖实例状态。
static func _tangent_vector(orientation: FilterOrientation) -> Vector2i:
	match orientation:
		FilterOrientation.VERTICAL:
			return Vector2i(0, -1)
		FilterOrientation.HORIZONTAL:
			return Vector2i(1, 0)
		FilterOrientation.SLASH:
			return Vector2i(1, -1)
		FilterOrientation.BACKSLASH:
			return Vector2i(1, 1)
		_:
			return Vector2i.ZERO


## 判定入射方向是否与薄膜面平行（= 撞棱角，共 2 个方向）。
## [br]incoming 是光的八方向入射向量。
## [br]返回 true = 与薄膜切线共轴（撞棱角停止）；false = 其余 6 方向（穿过滤色）。
## [br]本函数无副作用；共轴事实唯一来源 DirectionDomain.same_axis（Guide §18 冻结，与光屏障共享）。
func is_edge_collision(incoming: Vector2i) -> bool:
	return _DirectionDomain.same_axis(incoming, _tangent_vector(orientation))


## 当前 FilterColor → 玩法颜色 ColorValue 值。
## [br]返回 _RayColor.ColorValue.RED / GREEN / BLUE 之一；本函数无副作用。
## [br]边界条件：显式映射（而非把 FilterColor 枚举值直接当 ColorValue），避免语义歧义。
func _filter_color_value() -> int:
	match color:
		FilterColor.RED:
			return _RayColor.ColorValue.RED
		FilterColor.GREEN:
			return _RayColor.ColorValue.GREEN
		FilterColor.BLUE:
			return _RayColor.ColorValue.BLUE
		_:
			return _RayColor.ColorValue.RED


## 滤色纯函数（滤光片私有）：白光→对应单色；同色保持；异色吸收（返回 NONE 哨兵）。
## [br]incoming 是入射光颜色（ColorValue），filter 是滤光片颜色（ColorValue）。
## [br]返回结果色或 NONE（吸收/非法）；本静态函数无副作用，不进场景树、不 preload 机关。
static func _filter_color(incoming: int, filter: int) -> int:
	if incoming == _RayColor.ColorValue.WHITE:
		return filter
	if incoming == filter:
		return incoming
	return _RayColor.ColorValue.NONE


## 声明本机关支持的光形态（Guide §21 正式契约面）。
## [br]滤光片同时声明 RAY 与 PARTICLE：RAY 撞棱角/滤色，PARTICLE 恒阻挡。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21 / 机关规则 §3.1）。
## [br]ray_context 为 RayInteractionContext（只读事实快照，含 current_color）。
## [br]返回：与薄膜面平行 → BLOCK（撞棱角）；穿过 → 白光变单色 COLOR_CHANGE / 同色 CONTINUE / 异色吸收 BLOCK。
## [br]本函数无副作用；不改朝向/颜色/占用/传播状态，滤色真值唯一来自 orientation + color。
func interact_ray(ray_context: Variant) -> _LightInteractionResult:
	var incoming: Vector2i = ray_context.get_incoming_direction()
	if is_edge_collision(incoming):
		return _LightInteractionResult.block_result()

	var current: int = ray_context.get_current_color()
	var outcome: int = _filter_color(current, _filter_color_value())
	if outcome == _RayColor.ColorValue.NONE:
		return _LightInteractionResult.block_result()
	if outcome == current:
		return _LightInteractionResult.continue_result()
	return _LightInteractionResult.continue_result().add_color_change(outcome)


## PARTICLE 正式交互入口（Guide §21 / 机关规则 §3.2）。
## [br]光粒不带颜色且无法穿透薄膜，任意方向进入均在滤光片格被阻挡停止。
## [br]本函数无副作用；不产生 SpeedDelta（光粒不穿过，不改速）。
func interact_particle(_particle_context: Variant) -> _LightInteractionResult:
	return _LightInteractionResult.block_result()
