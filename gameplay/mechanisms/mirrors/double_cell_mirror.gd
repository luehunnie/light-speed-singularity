@tool
class_name DoubleCellMirror
extends PlaceableToken

## 双格平面镜机关（别名"长镜面"；机关规则 双格平面镜 v0.6）。
## 职责：持有 4 朝向唯一事实 orientation（BOTTOM / RIGHT / TOP / LEFT，默认 RIGHT），
##   实现单面反射——正面（朝向镜面）反射、背面阻挡、端点穿越；斜向光命中镜面中心点时
##   "反射穿邻格"（REDIRECT_CROSS，先透明跨过镜面另一格再按反射方向传播）。
## 光交互契约（Guide §21 + C-08 Q48）：get_light_interaction_forms 声明 RAY + PARTICLE，
##   经对称入口 interact_ray / interact_particle 返回正式 LightInteractionResult；
##   斜向中心点反射 → redirect_cross_result(反射方向, 穿邻方向)，端点/平行 → continue_result，
##   折回/背面 → block_result。判定纯函数 resolve_interaction 不依赖节点、无副作用，可被自检直接验证。
## 多格 footprint（C-08 Q50）：覆写 get_occupied_offsets() 返回相对锚格的两格偏移；
##   放置/移动/回收由 PlacementController 展开绝对占格后经 register_cells/move_cells 原子提交。
## 位置：gameplay/mechanisms/mirrors 下，与 single_cell_mirror.gd 并列；由核心闭环原型经
##   OccupancyRegistry 查到本节点后调用交互入口。
## 依赖：PlaceableToken（通用放置/拖拽显示 + _MechanismConfiguration preload）、ObjectVisualView 内容状态接口、
##   LightInteractionResult（preload）、C-08 冻结的 REDIRECT_CROSS 传播链（光线侧 RayExecutionModule 跨格步进 /
##   光粒侧 pending 跨格机制）。
## 不负责：占用登记（PlacementController 负责）、库存、RunState 权限判断、鼠标输入、光线/光粒传播循环、
##   水晶点亮、通关判断、分光、颜色、形态转换、多格视觉尺寸（正式视觉由 profile 贴图承担，调试线仅占位）。
## 关键规则：orientation 是朝向唯一事实来源，图片不得反过来决定反射逻辑；镜面几何（中心点/端点判定）
##   是机关自身规则，不进入 DirectionDomain；布局编辑与内部配置锁定是不同概念，朝向修改仅 SETUP 由关卡控制器把关。


## 四朝向（值序 0..3 = 顺时针）：按镜面所在边命名。
## [br]BOTTOM 镜面在底边反射面↑；RIGHT 镜面在右边反射面←；TOP 镜面在顶边反射面↓；LEFT 镜面在左边反射面→。
enum MirrorOrientation {
	BOTTOM,
	RIGHT,
	TOP,
	LEFT,
}

## 当前朝向，是反射判定、footprint 与视觉的唯一事实来源。
## [br]默认 RIGHT（镜面在右边、反射面向左，2026-09-03 由 BOTTOM 改，对齐规则文档 §2/§6/§7）；
## [br]移动、回收取消或 R 重置不应把已有镜面强制恢复默认方向。
var orientation: MirrorOrientation = MirrorOrientation.RIGHT

# 正式光交互契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)

# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：镜面朝向字段（INT 枚举 0..3）。
const FIELD_ORIENTATION: StringName = &"orientation"

# 内容状态 ID 契约：必须与 double_cell_mirror_visuals.tres 中 states 的 state_id 保持一致。
const STATE_BOTTOM: StringName = &"bottom"
const STATE_RIGHT: StringName = &"right"
const STATE_TOP: StringName = &"top"
const STATE_LEFT: StringName = &"left"

# 调试镜面线段节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _mirror_line: Line2D = $MirrorLine

# 调试镜面线段占位点位（相对节点原点 = anchor 格中心；CELL_SIZE=64，HALF=32）。
# 镜面为 2 格长线段：BOTTOM 底边 / RIGHT 右边 / TOP 顶边 / LEFT 左边，端点坐标按两格公共边展开。
# 仅占位后备，正式视觉由 profile 贴图（含旋转）承担，最终以成员C 美术素材为准。
var _bottom_line_points: PackedVector2Array = PackedVector2Array([Vector2(-32.0, 32.0), Vector2(96.0, 32.0)])
var _right_line_points: PackedVector2Array = PackedVector2Array([Vector2(32.0, -32.0), Vector2(32.0, 96.0)])
var _top_line_points: PackedVector2Array = PackedVector2Array([Vector2(-96.0, -32.0), Vector2(32.0, -32.0)])
var _left_line_points: PackedVector2Array = PackedVector2Array([Vector2(-32.0, -96.0), Vector2(-32.0, 32.0)])
const _DEBUG_LINE_COLOR: Color = Color(0.03, 0.09, 0.14, 1.0)


## 初始化朝向视觉。
## [br]无参数、无返回值。
## [br]副作用：按当前 orientation 写入 ObjectVisualView 内容状态并刷新调试镜面线段，不修改占用、库存、RunState 或光路。
## [br]边界：若 set_orientation() 在节点 ready 前被调用，_refresh_orientation_visual() 安全跳过，orientation 字段仍已写入，_ready() 时再按最终朝向刷新。
func _ready() -> void:
	_refresh_orientation_visual()


## 设置镜面朝向。
## [br]new_orientation 为目标 MirrorOrientation。
## [br]无返回值；副作用是写入 orientation 并经 _refresh_orientation_visual() 同步视觉。
## [br]越界值 push_error 并保持原朝向；本函数不判断 SETUP / PULSE_ACTIVE / MOVE_WINDOW / COMPLETED，朝向修改权限由关卡控制器把关。
func set_orientation(new_orientation: MirrorOrientation) -> void:
	if new_orientation < MirrorOrientation.BOTTOM or new_orientation > MirrorOrientation.LEFT:
		push_error("DoubleCellMirror: 非法镜面朝向：%s" % [new_orientation])
		return
	orientation = new_orientation
	_refresh_orientation_visual()


## 顺时针 90° 旋转朝向（BOTTOM → RIGHT → TOP → LEFT → BOTTOM）。
## [br]无参数、无返回值。
## [br]副作用：经 set_orientation() 修改 orientation 并刷新视觉。
## [br]边界：本函数只表达内部配置变化；是否允许玩家右键触发由关卡控制器判断（仅 SETUP）。
func toggle_orientation() -> void:
	match orientation:
		MirrorOrientation.BOTTOM:
			set_orientation(MirrorOrientation.RIGHT)
		MirrorOrientation.RIGHT:
			set_orientation(MirrorOrientation.TOP)
		MirrorOrientation.TOP:
			set_orientation(MirrorOrientation.LEFT)
		MirrorOrientation.LEFT:
			set_orientation(MirrorOrientation.BOTTOM)


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）。
## [br]按 Stable Field ID "orientation" 解释枚举整数值并写入朝向（经 set_orientation 同步视觉）。
## [br]配置含未知字段或缺 orientation 字段返回 false 且朝向不变；值越界由 set_orientation 拒绝并保持原朝向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_ORIENTATION)
	if not (value is int):
		push_error("DoubleCellMirror: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_ORIENTATION])
		return false
	var next_orientation := value as MirrorOrientation
	if next_orientation < MirrorOrientation.BOTTOM or next_orientation > MirrorOrientation.LEFT:
		push_error("DoubleCellMirror: Typed 配置朝向越界：%s。" % [value])
		return false
	set_orientation(next_orientation)
	return true


## 覆写多格 footprint（C-08 Q50）：返回相对锚格的两格偏移，随朝向变化。
## [br]⚠️ 关键：PlacementController 调用 token.get_occupied_offsets() 不传 orientation 参数（朝向事实由实例自持），
##   故必须读自身 orientation 字段，忽略形参 _p_orientation。
## [br]返回 anchor 相对偏移（anchor 恒为自身 cell）；offsets 内无重复格（register_cells 原子拒绝重复）。
func get_occupied_offsets(_p_orientation: int = 0) -> Array[Vector2i]:
	match orientation:
		MirrorOrientation.BOTTOM:
			return [Vector2i.ZERO, Vector2i(1, 0)]
		MirrorOrientation.RIGHT:
			return [Vector2i.ZERO, Vector2i(0, 1)]
		MirrorOrientation.TOP:
			return [Vector2i(-1, 0), Vector2i.ZERO]
		MirrorOrientation.LEFT:
			return [Vector2i(0, -1), Vector2i.ZERO]
	return [Vector2i.ZERO]


## 声明本机关支持的光形态（Guide §21 正式契约面；Definition 侧声明的运行期镜像）。
## [br]双格镜对 RAY 与 PARTICLE 均有交互（正面反射/背面停止/端点穿越/穿邻格）；未声明形态由 Runtime 判透明。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21 / C-08 Q48）：按朝向 + 入格 + 入射方向判定。
## [br]ray_context 为 RayInteractionContext（只读事实快照）。
## [br]返回：斜向中心点正面 → REDIRECT_CROSS(反射方向, 穿邻方向)；端点/平行 → CONTINUE；折回/背面 → BLOCK。
## [br]无副作用；反射真值唯一来自 orientation，不改占用/传播状态。
func interact_ray(ray_context: Variant) -> _LightInteractionResult:
	var cell_offset: Vector2i = ray_context.get_cell() - cell
	var resolution := resolve_interaction(orientation, cell_offset, ray_context.get_incoming_direction())
	match resolution.outcome:
		Resolution.Outcome.REDIRECT_CROSS:
			return _LightInteractionResult.redirect_cross_result(
				resolution.reflect_direction, resolution.cross_direction)
		Resolution.Outcome.BLOCK:
			return _LightInteractionResult.block_result()
		_:
			return _LightInteractionResult.continue_result()


## PARTICLE 正式交互入口（Guide §21 / C-08 Q48）：与 interact_ray 同判定，改向不改速。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照，速度档不参与镜面计算）。
## [br]返回：斜向中心点正面 → REDIRECT_CROSS（光粒侧 pending 跨格机制由 C-08 就绪，第二格不重复判机关）；
##   端点/平行 → CONTINUE；折回/背面 → BLOCK（与光线一致，文档 §3.2 背面停止）。
## [br]无副作用；不产生 SpeedDelta（镜面不改速）。
func interact_particle(particle_context: Variant) -> _LightInteractionResult:
	var cell_offset: Vector2i = particle_context.get_cell() - cell
	var resolution := resolve_interaction(orientation, cell_offset, particle_context.get_incoming_direction())
	match resolution.outcome:
		Resolution.Outcome.REDIRECT_CROSS:
			return _LightInteractionResult.redirect_cross_result(
				resolution.reflect_direction, resolution.cross_direction)
		Resolution.Outcome.BLOCK:
			return _LightInteractionResult.block_result()
		_:
			return _LightInteractionResult.continue_result()


## 判断入射方向是否可用于双格镜交互（八方向单位向量）。
## [br]direction 为待检查 Vector2i；返回 true 表示合法八方向。
## [br]无副作用；边界：非零且两分量绝对值均 ≤1 即覆盖全部八方向。
func is_valid_incoming_direction(direction: Vector2i) -> bool:
	return is_valid_incoming_direction_value(direction)


## 执行无节点、无副作用的入射方向合法性检查（静态）。
## [br]供启动自检 / resolve_interaction 复用，不访问场景树、真实镜面、占用表、库存或光路。
static func is_valid_incoming_direction_value(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 反射面法线（normal = 反射面朝向的八方向单位向量）。
## [br]BOTTOM→↑(0,-1)；RIGHT→←(-1,0)；TOP→↓(0,1)；LEFT→→(1,0)。越界返回 ZERO。
## [br]静态纯函数，无副作用；normal 是"正面/背面"与"镜面反射"判定的唯一几何依据。
static func _normal_for(mirror_orientation: MirrorOrientation) -> Vector2i:
	match mirror_orientation:
		MirrorOrientation.BOTTOM:
			return Vector2i(0, -1)
		MirrorOrientation.RIGHT:
			return Vector2i(-1, 0)
		MirrorOrientation.TOP:
			return Vector2i(0, 1)
		MirrorOrientation.LEFT:
			return Vector2i(1, 0)
	return Vector2i.ZERO


## 镜面切线（tangent = anchor 格 → 第二格方向，即"穿邻方向"的基准）。
## [br]BOTTOM→(1,0)；RIGHT→(0,1)；TOP→(-1,0)；LEFT→(0,-1)。越界返回 ZERO。
## [br]静态纯函数，无副作用；tangent 是 footprint 第二格方向与穿邻方向的唯一几何依据。
static func _tangent_for(mirror_orientation: MirrorOrientation) -> Vector2i:
	match mirror_orientation:
		MirrorOrientation.BOTTOM:
			return Vector2i(1, 0)
		MirrorOrientation.RIGHT:
			return Vector2i(0, 1)
		MirrorOrientation.TOP:
			return Vector2i(-1, 0)
		MirrorOrientation.LEFT:
			return Vector2i(0, -1)
	return Vector2i.ZERO


## 无节点、无副作用的判定：按朝向 + 入格偏移 + 入射方向 → 光学响应（48 条速查表收敛为一个公式）。
## [br]mirror_orientation 为镜面朝向；cell_offset 为入格相对 anchor 的偏移（ZERO=anchor 格，tangent=第二格）；
##   incoming_direction 为合法八方向入射向量。
## [br]返回 Resolution：CONTINUE（端点穿越/平行/非法方向）、BLOCK（正交折回/背面、斜向背面中心点）、
##   REDIRECT_CROSS（斜向正面命中中心点，含反射方向与穿邻方向）。
## [br]几何依据：双格镜镜面线段上的中心点/端点均为格顶点；斜向光走格角，命中顶点 = 入格 ± 入射方向 × 0.5。
##   命中中心点 ⟺ (anchor 格 且 dx*dy==+1) 或 (第二格 且 dx*dy==-1)；其余斜向命中端点。
##   正面/背面由入射方向与法线点积符号判定（d·normal < 0 为正面）。
## [br]本静态函数无副作用，可供 debug 自检验证全部 48 条映射，不建节点、不改真实镜面、不触发光路。
static func resolve_interaction(
		mirror_orientation: MirrorOrientation,
		cell_offset: Vector2i,
		incoming_direction: Vector2i
) -> Resolution:
	var result := Resolution.new()
	if not is_valid_incoming_direction_value(incoming_direction):
		return result  # 非法方向 → CONTINUE（默认）

	var normal: Vector2i = _normal_for(mirror_orientation)
	var tangent: Vector2i = _tangent_for(mirror_orientation)
	var is_second_cell: bool = (cell_offset == tangent)

	# 1. 正交光（走格边中点）：垂直折回 / 背面 均 BLOCK，平行穿越 CONTINUE。
	if incoming_direction.x == 0 or incoming_direction.y == 0:
		if incoming_direction == -normal or incoming_direction == normal:
			result.outcome = Resolution.Outcome.BLOCK
		else:
			result.outcome = Resolution.Outcome.CONTINUE
		return result

	# 2. 斜向光（走格角）：命中中心点 → 交互，命中端点 → 穿越。
	var hits_center: bool = (
		(not is_second_cell and incoming_direction.x * incoming_direction.y == 1)
		or (is_second_cell and incoming_direction.x * incoming_direction.y == -1)
	)
	if not hits_center:
		result.outcome = Resolution.Outcome.CONTINUE
		return result

	# 命中中心点：正面（光朝向反射面）→ 反射穿邻；背面 → 停止。
	# 点积手算（Vector2i 无 dot()，dot 仅 Vector2 浮点向量提供）。
	var dot_value: int = incoming_direction.x * normal.x + incoming_direction.y * normal.y
	if dot_value < 0:
		result.outcome = Resolution.Outcome.REDIRECT_CROSS
		result.reflect_direction = incoming_direction - 2 * dot_value * normal
		result.cross_direction = tangent if not is_second_cell else -tangent
	else:
		result.outcome = Resolution.Outcome.BLOCK
	return result


## 把当前朝向映射为 ObjectVisualView 的内容状态 ID。
## [br]无参数；返回 STATE_BOTTOM/RIGHT/TOP/LEFT 之一；无副作用。
## [br]边界：映射单向——图片不得反过来决定反射逻辑；调用方在朝向变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_orientation() -> StringName:
	match orientation:
		MirrorOrientation.BOTTOM:
			return STATE_BOTTOM
		MirrorOrientation.RIGHT:
			return STATE_RIGHT
		MirrorOrientation.TOP:
			return STATE_TOP
		MirrorOrientation.LEFT:
			return STATE_LEFT
	return STATE_RIGHT


## 按当前朝向刷新视觉：写入 ObjectVisualView 内容状态并更新调试镜面线段。
## [br]无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换朝向状态；正式纹理缺失时显示 MirrorLine 调试线段、存在时隐藏。
## [br]边界：节点尚未 ready 时安全返回；视觉更新不反推逻辑，反射始终只读取 orientation。
func _refresh_orientation_visual() -> void:
	if not is_node_ready():
		return
	_visual_view.set_content_state(_content_state_id_for_orientation())

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_mirror_line.visible = not has_artwork
	if not has_artwork:
		match orientation:
			MirrorOrientation.BOTTOM:
				_mirror_line.points = _bottom_line_points
			MirrorOrientation.RIGHT:
				_mirror_line.points = _right_line_points
			MirrorOrientation.TOP:
				_mirror_line.points = _top_line_points
			MirrorOrientation.LEFT:
				_mirror_line.points = _left_line_points
		_mirror_line.default_color = _DEBUG_LINE_COLOR


## 判定结果内部载体（不耦合 LightInteractionResult，便于纯函数自检）。
class Resolution:
	## 判定结果枚举。
	enum Outcome {
		CONTINUE,
		BLOCK,
		REDIRECT_CROSS,
	}

	## 判定结果（CONTINUE / BLOCK / REDIRECT_CROSS）。
	var outcome: int = Outcome.CONTINUE
	## REDIRECT_CROSS 时的反射方向（改向后出射八方向）；其余恒 ZERO。
	var reflect_direction: Vector2i = Vector2i.ZERO
	## REDIRECT_CROSS 时的穿邻方向（正交四方向）；其余恒 ZERO。
	var cross_direction: Vector2i = Vector2i.ZERO
