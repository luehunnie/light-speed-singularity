@tool
class_name LightFormConverter
extends PlaceableToken

## 光形式转换器机关（阶段C-01；需求文档《光形式转换器》关卡预置 v0.1 / 玩家道具 v0.1 共用同一转换核心）。
## 职责：保存转换器的唯一输出朝向事实 direction；对七向入射光（RAY 与 PARTICLE 皆可）返回 FORM_CHANGE 正式结果
## ——转换发生在转换器格内，出射方向恒为本机关朝向、形态翻转为另一形态（RAY↔PARTICLE）；
## 背面入射（入射方向 == 朝向的反向）恒 BLOCK。速度/颜色规则不在此表达：RAY→PARTICLE 标准速度、
## PARTICLE→RAY 默认白色由执行适配层（FormChangeEmissionSpawner 经既有发射路径）按平台默认生成，
## 本机关只携带"目标形态 + 输出方向"最小载荷（总控裁决：转换逻辑单点消费，不复制）。
## 视觉接入：direction 是方向的唯一事实来源；经 _content_state_id_for_direction() 映射 ObjectVisualView 内容状态 ID；
## 正式纹理缺失时由 DebugArrow 占位后备（与加速器同一模式，美术后补不改本脚本逻辑）。
## 编辑接入：八向枚举经 @export 暴露 Inspector；右键顺时针轮转走 cycle_direction()（玩家道具版经
## player_interaction_actions 接线，关卡控制器 SETUP 权限限定；预置版无 cycle 动作=运行期不可编辑）。
## 位置：gameplay/mechanisms/converter/ 下第一个形态转换机关；两份 .tres Definition（预置/道具）共享本场景与脚本。
## 不负责：新 emission 的生成（执行适配层职责）、OccupancyRegistry 写入、库存、RunState 权限判断、
## 鼠标输入、光粒传播循环、水晶点亮、通关判断。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


enum ConverterDirection {
	RIGHT,
	DOWN_RIGHT,
	DOWN,
	DOWN_LEFT,
	LEFT,
	UP_LEFT,
	UP,
	UP_RIGHT,
}


## 当前输出朝向，是出射方向判定和视觉外观的唯一事实来源。
## [br]固定预放置实例可在 Inspector 中配置初始朝向；默认 RIGHT 表示出射箭头指向 →。
@export_group("转换朝向")
@export var direction: ConverterDirection = ConverterDirection.RIGHT : set = set_direction

# 正式光交互契约（Guide §21）与形态枚举；Result / LightForm 经 preload 引用。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)
# 八方向公共规则（S3-01 统一八方向 API 的速度域入口；本机关枚举值序与 CLOCKWISE_ORDER 对齐）。
const _SpeedDirectionRules: GDScript = preload(
	"res://gameplay/mechanisms/speed/speed_direction_rules.gd"
)
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
const FIELD_DIRECTION: StringName = &"direction"

# 调试箭头节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _debug_arrow: Line2D = $DebugArrow

# 内容状态 ID 契约：必须与 light_form_converter_visuals.tres 中 states 的 state_id 保持一致。
const STATE_RIGHT: StringName = &"right"
const STATE_DOWN_RIGHT: StringName = &"down_right"
const STATE_DOWN: StringName = &"down"
const STATE_DOWN_LEFT: StringName = &"down_left"
const STATE_LEFT: StringName = &"left"
const STATE_UP_LEFT: StringName = &"up_left"
const STATE_UP: StringName = &"up"
const STATE_UP_RIGHT: StringName = &"up_right"


## 初始化转换朝向视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按当前 direction 把内容状态写入 ObjectVisualView 并刷新调试箭头点位，不修改占用、库存、RunState 或光路。
## [br]边界条件：若 set_direction() 在节点 ready 前被调用，_refresh_direction_visual() 会安全跳过，
## direction 字段仍已写入，_ready() 时再按最终方向刷新视觉。
func _ready() -> void:
	_refresh_direction_visual()


## 按当前 direction 刷新视觉：写入 ObjectVisualView 内容状态，并更新调试箭头方向。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换朝向纹理并按 direction 派生 Artwork 旋转角，
## 正式纹理可解析时隐藏 DebugArrow、缺失时显示并刷新其点位（占位后备）。
## [br]边界条件：若节点尚未 ready 则安全返回，避免在 @onready 变量初始化前解引用；
## 切换显示模式（WORLD/DRAG_PREVIEW）不会改变内容状态与旋转，因此拖拽预览保留当前朝向。
func _refresh_direction_visual() -> void:
	if not is_node_ready():
		return

	_visual_view.set_content_state(_content_state_id_for_direction())
	# 转换器暂无正式贴图（美术留白）：Artwork 旋转基准按"贴图朝右 = 0"预留，程序旋转此时为 0 旋转。
	_visual_view.set_artwork_rotation(Vector2(direction_to_vector(direction)).angle())

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_debug_arrow.visible = not has_artwork
	if not has_artwork:
		var arrow_end: Vector2i = direction_to_vector(direction) * 28
		_debug_arrow.points = PackedVector2Array([Vector2.ZERO, Vector2(arrow_end)])


## 设置转换器的内部朝向配置。
## [br]new_dir 是目标 ConverterDirection。
## [br]无返回值；副作用是写入 direction 并通过 _refresh_direction_visual() 同步视觉内容状态。
## [br]失败条件：传入 0~7 范围外的值时输出错误并保持原朝向。
## [br]边界条件：本函数不自行判断运行状态；玩家交互权限由关卡控制器统一限定在 SETUP，
## 固定预放置的初始朝向可经 Inspector/apply_configuration 写入；
## 所有 direction 变化后立即同步视觉状态，保证图片与逻辑始终读取同一朝向事实。
func set_direction(new_dir: ConverterDirection):
	if new_dir < 0 or new_dir > 7:
		push_error("LightFormConverter: 非法转换朝向：%d" % [new_dir])
		return

	direction = new_dir
	_refresh_direction_visual()


## 顺时针循环切换转换朝向：RIGHT → DOWN_RIGHT → ... → UP_RIGHT → RIGHT（玩家道具右键动作正式入口）。
## [br]本函数无参数、无返回值。
## [br]副作用：经 speed_direction_rules.cycle_clockwise（DirectionDomain 唯一顺序事实）修改 direction 并刷新视觉。
## [br]边界条件：本函数只表达内部配置变化本身；玩家右键只由关卡控制器在 SETUP 调用。
func cycle_direction() -> void:
	set_direction(_SpeedDirectionRules.cycle_clockwise(direction))


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）：
## [br]按 Stable Field ID "direction" 解释枚举整数值并写入唯一朝向事实（经 set_direction 同步视觉）。
## [br]配置含未知字段或缺 direction 字段返回 false 且朝向不变；值越界由 set_direction 拒绝并保持原朝向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_DIRECTION)
	if not (value is int):
		push_error("LightFormConverter: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_DIRECTION])
		return false
	var next_direction := value as ConverterDirection
	if next_direction < 0 or next_direction > 7:
		push_error("LightFormConverter: Typed 配置朝向越界：%s。" % [value])
		return false
	set_direction(next_direction)
	return true


## 把当前 direction 映射为 ObjectVisualView 的内容状态 ID。
## [br]本函数无参数。
## [br]返回 8 个 STATE_* 常量之一；无副作用，不修改 direction 或视觉。
## [br]边界条件：映射是单向的——图片不得反过来决定逻辑；调用方在 direction 变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_direction() -> StringName:
	match direction:
		ConverterDirection.RIGHT:
			return STATE_RIGHT
		ConverterDirection.DOWN_RIGHT:
			return STATE_DOWN_RIGHT
		ConverterDirection.DOWN:
			return STATE_DOWN
		ConverterDirection.DOWN_LEFT:
			return STATE_DOWN_LEFT
		ConverterDirection.LEFT:
			return STATE_LEFT
		ConverterDirection.UP_LEFT:
			return STATE_UP_LEFT
		ConverterDirection.UP:
			return STATE_UP
		ConverterDirection.UP_RIGHT:
			return STATE_UP_RIGHT
		_:
			return STATE_RIGHT


## 把 ConverterDirection 枚举值转换为对应的八方向单位向量（经 speed_direction_rules 唯一事实换算）。
## [br]dir 是目标方向枚举值。
## [br]返回 Vector2i 方向向量；非法方向返回 Vector2i.ZERO。
## [br]本静态函数无副作用，不依赖实例状态。
static func direction_to_vector(dir: ConverterDirection) -> Vector2i:
	return _SpeedDirectionRules.direction_to_vector(dir)


## 声明本机关支持的光形态（Guide §21 正式契约面；两份 Definition 侧声明的运行期镜像）。
## [br]转换器对 RAY 与 PARTICLE 皆可交互（双向形态转换的核心前提）。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## 判断入射方向是否为背面入射（需求 §8.2）：入射方向 == 朝向的反向时恒 BLOCK。
## [br]incoming 是入射光的八方向运动向量。
## [br]返回 true 表示背面阻挡；false 表示七向正面/侧面入射应转换。
## [br]本函数无副作用，不修改 direction、视觉或任何系统状态。
func is_back_face(incoming: Vector2i) -> bool:
	return incoming == _DirectionDomain.opposite(direction_to_vector(direction))


## RAY 正式交互入口（Guide §21）：背面入射 → BLOCK；其余七向 → FORM_CHANGE(目标 PARTICLE, 输出朝向)。
## [br]ray_context 为 RayInteractionContext（只读事实快照）。
## [br]边界：只携带目标形态 + 输出方向（总控裁决最小载荷）；RAY→PARTICLE 标准速度、颜色丢弃
## 由执行适配层按平台默认生成，本入口不表达速度/颜色效果。
func interact_ray(ray_context: Variant) -> _LightInteractionResult:
	if is_back_face(ray_context.get_incoming_direction()):
		return _LightInteractionResult.block_result()
	return _LightInteractionResult.form_change_result(
		_LightEmissionTypes.LightForm.PARTICLE, direction_to_vector(direction))


## PARTICLE 正式交互入口（Guide §21）：背面入射 → BLOCK；其余七向 → FORM_CHANGE(目标 RAY, 输出朝向)。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照）。
## [br]边界：只携带目标形态 + 输出方向；PARTICLE→RAY 出射为默认白色、速度回落由执行适配层按平台默认生成。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	if is_back_face(particle_context.get_incoming_direction()):
		return _LightInteractionResult.block_result()
	return _LightInteractionResult.form_change_result(
		_LightEmissionTypes.LightForm.RAY, direction_to_vector(direction))
