@tool
class_name TCellSplitter
extends PlaceableToken

## 四格T型分光器机关（机关规则 四格T型分光器 v0.1；C-09 内容批次）。
## 职责：持有 4 朝向唯一事实 orientation（RIGHT / DOWN / LEFT / UP，默认 RIGHT），
##   实现"一分为三"的单向端口分光——单束光线从中间格输入口进入，被完全消耗后派生三束出射光：
##   前进支（沿入射方向直出）+ 两个垂直侧支（左旋 90° / 右旋 90°），分别从三个支格输出口射出。
## 光交互契约（Guide §21 + C-09 Q53）：get_light_interaction_forms 声明 RAY + PARTICLE，
##   interact_ray 命中中间格输入口 → block_result() + 3 支 spawned_branches（消耗式分光，Q53）；
##   其余命中（斜向 / 反向 / 侧面 / 支格 / 输出口反向）→ block_result()；interact_particle 恒 block_result()（光粒不支持分光）。
##   判定纯函数 resolve_interaction 不依赖节点、无副作用，可被自检直接验证。
## 多格 footprint（C-08 Q50）：覆写 get_occupied_offsets() 返回相对中间格的四格 T 形偏移（随朝向变化）；
##   放置/移动/回收由 PlacementController 展开绝对占格后经 register_cells/move_cells 原子提交。
## 位置：gameplay/mechanisms/splitters 下；由核心经 OccupancyRegistry 查到本节点后调用交互入口。
## 依赖：PlaceableToken（通用放置/拖拽显示 + _MechanismConfiguration preload）、ObjectVisualView 内容状态接口、
##   LightInteractionResult（preload）、Q53 冻结的 BLOCK 携带分支传播链（RayExecutionModule BLOCK 收集分支）。
## 不负责：占用登记（PlacementController 负责）、库存、RunState 权限判断、鼠标输入、光线/光粒传播循环、
##   分支 emission 生成（FormChangeEmissionSpawner 负责）、水晶点亮、通关判断、颜色、形态转换、多格视觉尺寸
##   （正式视觉由 profile 贴图承担，调试轮廓仅占位）。
## 关键规则：orientation 是朝向唯一事实来源，图片不得反过来决定分光逻辑；端口语义（输入口只进不出、
##   输出口只出不进、其余命中一律 BLOCK）是机关自身规则，不进入 DirectionDomain；布局编辑与内部配置锁定是
##   不同概念，朝向修改仅 SETUP 由关卡控制器把关。


## 四朝向（值序 0..3 = 顺时针）：以光线输入方向命名。
## [br]RIGHT 输入 (1,0)；DOWN 输入 (0,1)；LEFT 输入 (-1,0)；UP 输入 (0,-1)。
enum SplitterOrientation {
	RIGHT,
	DOWN,
	LEFT,
	UP,
}

## 当前朝向，是分光判定、footprint 与视觉的唯一事实来源。
## [br]默认 RIGHT（输入方向 (1,0)，对齐 Q52 冻结 DEFAULT_SPLITTER_ORIENTATION）；
## [br]移动、回收取消或 R 重置不应把已有分光器强制恢复默认方向。
var orientation: SplitterOrientation = SplitterOrientation.RIGHT

# 正式光交互契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)

# Typed Configuration 类型引用继承 PlaceableToken._MechanismConfiguration（AF-03 / P0-4 apply_configuration 覆写）。
# 本类型的正式 Stable Field ID（内容 Schema 身份，Guide §11.3）：分光朝向字段（INT 枚举 0..3）。
const FIELD_ORIENTATION: StringName = &"orientation"

# 内容状态 ID 契约：必须与 t_cell_splitter_visuals.tres 中 states 的 state_id 保持一致。
const STATE_RIGHT: StringName = &"right"
const STATE_DOWN: StringName = &"down"
const STATE_LEFT: StringName = &"left"
const STATE_UP: StringName = &"up"

# 调试轮廓节点：正式纹理可解析时隐藏，仅作纹理缺失时的占位后备，不参与玩法状态。
@onready var _outline: Line2D = $SplitterOutline

# 调试轮廓占位点位（相对节点原点 = 中间格 anchor 中心；CELL_SIZE=64，HALF=32）。
# 四格 T 形（前进支 + 左/右两侧支 + 中间格）的矩形轮廓，仅占位后备，正式视觉由 profile 贴图承担。
var _up_outline_points: PackedVector2Array = PackedVector2Array([
	Vector2(-32.0, -96.0), Vector2(32.0, -96.0), Vector2(32.0, -32.0), Vector2(96.0, -32.0),
	Vector2(96.0, 32.0), Vector2(-96.0, 32.0), Vector2(-96.0, -32.0), Vector2(-32.0, -32.0), Vector2(-32.0, -96.0)])
var _down_outline_points: PackedVector2Array = PackedVector2Array([
	Vector2(-96.0, -32.0), Vector2(96.0, -32.0), Vector2(96.0, 32.0), Vector2(32.0, 32.0),
	Vector2(32.0, 96.0), Vector2(-32.0, 96.0), Vector2(-32.0, 32.0), Vector2(-96.0, 32.0), Vector2(-96.0, -32.0)])
var _right_outline_points: PackedVector2Array = PackedVector2Array([
	Vector2(-32.0, -96.0), Vector2(32.0, -96.0), Vector2(32.0, -32.0), Vector2(96.0, -32.0),
	Vector2(96.0, 32.0), Vector2(32.0, 32.0), Vector2(32.0, 96.0), Vector2(-32.0, 96.0), Vector2(-32.0, -96.0)])
var _left_outline_points: PackedVector2Array = PackedVector2Array([
	Vector2(-32.0, -96.0), Vector2(32.0, -96.0), Vector2(32.0, 96.0), Vector2(-32.0, 96.0),
	Vector2(-32.0, 32.0), Vector2(-96.0, 32.0), Vector2(-96.0, -32.0), Vector2(-32.0, -32.0), Vector2(-32.0, -96.0)])
const _DEBUG_LINE_COLOR: Color = Color(0.03, 0.09, 0.14, 1.0)


## 初始化朝向视觉。
## [br]无参数、无返回值。
## [br]副作用：按当前 orientation 写入 ObjectVisualView 内容状态并刷新调试轮廓，不修改占用、库存、RunState 或光路。
## [br]边界：若 set_orientation() 在节点 ready 前被调用，_refresh_orientation_visual() 安全跳过，orientation 字段仍已写入，_ready() 时再按最终朝向刷新。
func _ready() -> void:
	_refresh_orientation_visual()


## 设置分光朝向。
## [br]new_orientation 为目标 SplitterOrientation。
## [br]无返回值；副作用是写入 orientation 并经 _refresh_orientation_visual() 同步视觉。
## [br]越界值 push_error 并保持原朝向；本函数不判断 SETUP / PULSE_ACTIVE / MOVE_WINDOW / COMPLETED，朝向修改权限由关卡控制器把关。
func set_orientation(new_orientation: SplitterOrientation) -> void:
	if new_orientation < SplitterOrientation.RIGHT or new_orientation > SplitterOrientation.UP:
		push_error("TCellSplitter: 非法分光朝向：%s" % [new_orientation])
		return
	orientation = new_orientation
	_refresh_orientation_visual()


## 顺时针 90° 旋转朝向（RIGHT → DOWN → LEFT → UP → RIGHT）。
## [br]无参数、无返回值。
## [br]副作用：经 set_orientation() 修改 orientation 并刷新视觉。
## [br]边界：本函数只表达内部配置变化；是否允许玩家右键触发由关卡控制器判断（仅 SETUP）。
func toggle_orientation() -> void:
	match orientation:
		SplitterOrientation.RIGHT:
			set_orientation(SplitterOrientation.DOWN)
		SplitterOrientation.DOWN:
			set_orientation(SplitterOrientation.LEFT)
		SplitterOrientation.LEFT:
			set_orientation(SplitterOrientation.UP)
		SplitterOrientation.UP:
			set_orientation(SplitterOrientation.RIGHT)


## 正式 Typed Configuration 应用（AF-03 / P0-4，覆写 PlaceableToken 契约）。
## [br]按 Stable Field ID "orientation" 解释枚举整数值并写入朝向（经 set_orientation 同步视觉）。
## [br]配置含未知字段或缺 orientation 字段返回 false 且朝向不变；值越界由 set_orientation 拒绝并保持原朝向。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_ORIENTATION)
	if not (value is int):
		push_error("TCellSplitter: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_ORIENTATION])
		return false
	var next_orientation := value as SplitterOrientation
	if next_orientation < SplitterOrientation.RIGHT or next_orientation > SplitterOrientation.UP:
		push_error("TCellSplitter: Typed 配置朝向越界：%s。" % [value])
		return false
	set_orientation(next_orientation)
	return true


## 覆写多格 footprint（C-08 Q50）：返回相对中间格的四格 T 形偏移，随朝向变化。
## [br]⚠️ 关键：PlacementController 调用 token.get_occupied_offsets() 不传 orientation 参数（朝向事实由实例自持），
##   故必须读自身 orientation 字段，忽略形参 _p_orientation。
## [br]T 形 = 前进支格（沿输入方向）+ 两个垂直侧支格（左旋 90° / 右旋 90°）+ 中间格；offsets 内无重复格。
func get_occupied_offsets(_p_orientation: int = 0) -> Array[Vector2i]:
	var input: Vector2i = input_dir_for(orientation)
	var left: Vector2i = Vector2i(-input.y, input.x)
	var right: Vector2i = Vector2i(input.y, -input.x)
	return [input, left, Vector2i.ZERO, right]


## 声明本机关支持的光形态（Guide §21 正式契约面；Definition 侧声明的运行期镜像）。
## [br]分光器对 RAY 分光、对 PARTICLE 恒阻挡（光粒不支持分光，命中视为墙体）；
##   两者都须声明，否则光粒会被 Runtime 判透明穿过（违背规则文档 §3.2）。
func get_light_interaction_forms() -> Array[StringName]:
	return [&"RAY", &"PARTICLE"]


## RAY 正式交互入口（Guide §21 / C-09 Q53）：命中中间格输入口 → 消耗式分光（BLOCK + 3 分支），其余 → BLOCK。
## [br]ray_context 为 RayInteractionContext（只读事实快照）。
## [br]返回：block_result() + 3 支 spawned_branches（前进 + 左旋 + 右旋）或纯 block_result()。
## [br]无副作用；分光真值唯一来自 orientation，不改占用/传播状态；分支 color 恒 NONE（继承色由执行层盖章）。
func interact_ray(ray_context: Variant) -> _LightInteractionResult:
	var cell_offset: Vector2i = ray_context.get_cell() - cell
	var resolution: Resolution = resolve_interaction(orientation, cell_offset, ray_context.get_incoming_direction())
	if resolution.split:
		var result: _LightInteractionResult = _LightInteractionResult.block_result()
		var input: Vector2i = input_dir_for(orientation)
		var left: Vector2i = Vector2i(-input.y, input.x)
		var right: Vector2i = Vector2i(input.y, -input.x)
		result.add_spawned_branch(cell + input, input)
		result.add_spawned_branch(cell + left, left)
		result.add_spawned_branch(cell + right, right)
		return result
	return _LightInteractionResult.block_result()


## PARTICLE 正式交互入口（Guide §21 / 规则文档 §3.2）：光粒命中分光器任何格一律视为碰撞墙体，停止。
## [br]particle_context 为 ParticleInteractionContext（只读事实快照）。
## [br]返回：恒 block_result()；无副作用、不产生任何光粒分支、不改变光粒速度。
func interact_particle(_particle_context: Variant) -> _LightInteractionResult:
	return _LightInteractionResult.block_result()


## 判断入射方向是否可用于分光判定（八方向单位向量）。
## [br]direction 为待检查 Vector2i；返回 true 表示合法八方向。
## [br]无副作用；边界：非零且两分量绝对值均 ≤1 即覆盖全部八方向。
func is_valid_incoming_direction(direction: Vector2i) -> bool:
	return is_valid_incoming_direction_value(direction)


## 执行无节点、无副作用的入射方向合法性检查（静态）。
## [br]供启动自检 / resolve_interaction 复用，不访问场景树、真实分光器、占用表、库存或光路。
static func is_valid_incoming_direction_value(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 朝向 → 输入方向（静态纯函数，无副作用）。
## [br]RIGHT→(1,0)；DOWN→(0,1)；LEFT→(-1,0)；UP→(0,-1)；越界返回 ZERO。
static func input_dir_for(o: SplitterOrientation) -> Vector2i:
	match o:
		SplitterOrientation.RIGHT:
			return Vector2i(1, 0)
		SplitterOrientation.DOWN:
			return Vector2i(0, 1)
		SplitterOrientation.LEFT:
			return Vector2i(-1, 0)
		SplitterOrientation.UP:
			return Vector2i(0, -1)
	return Vector2i.ZERO


## 无节点、无副作用的判定：按朝向 + 入格偏移 + 入射方向 → 是否分光（纯函数，可自检）。
## [br]splitter_orientation 为分光朝向；cell_offset 为入格相对 anchor（中间格）的偏移（ZERO=中间格）；
##   incoming_direction 为合法八方向入射向量。
## [br]返回 Resolution：split=true 当且仅当 命中中间格(cell_offset==ZERO) 且 入射方向==输入方向；
##   其余（斜向 / 反向 / 侧面 / 支格命中）split=false（→ BLOCK）。非法方向 split=false。
static func resolve_interaction(
		splitter_orientation: SplitterOrientation,
		cell_offset: Vector2i,
		incoming_direction: Vector2i
) -> Resolution:
	var result: Resolution = Resolution.new()
	if not is_valid_incoming_direction_value(incoming_direction):
		return result
	var input: Vector2i = input_dir_for(splitter_orientation)
	result.split = (cell_offset == Vector2i.ZERO and incoming_direction == input)
	return result


## 把当前朝向映射为 ObjectVisualView 的内容状态 ID。
## [br]无参数；返回 STATE_RIGHT/DOWN/LEFT/UP 之一；无副作用。
## [br]边界：映射单向——图片不得反过来决定分光逻辑；调用方在朝向变化后用本结果驱动 VisualView.set_content_state()。
func _content_state_id_for_orientation() -> StringName:
	match orientation:
		SplitterOrientation.RIGHT:
			return STATE_RIGHT
		SplitterOrientation.DOWN:
			return STATE_DOWN
		SplitterOrientation.LEFT:
			return STATE_LEFT
		SplitterOrientation.UP:
			return STATE_UP
	return STATE_RIGHT


## 按当前朝向刷新视觉：写入 ObjectVisualView 内容状态并更新调试轮廓。
## [br]无参数、无返回值。
## [br]副作用：调用 _visual_view.set_content_state() 切换朝向状态；正式纹理缺失时显示 SplitterOutline 调试轮廓、存在时隐藏。
## [br]边界：节点尚未 ready 时安全返回；视觉更新不反推逻辑，分光始终只读取 orientation。
func _refresh_orientation_visual() -> void:
	if not is_node_ready():
		return
	_visual_view.set_content_state(_content_state_id_for_orientation())

	var has_artwork: bool = _visual_view.has_resolved_texture()
	_outline.visible = not has_artwork
	if not has_artwork:
		match orientation:
			SplitterOrientation.UP:
				_outline.points = _up_outline_points
			SplitterOrientation.DOWN:
				_outline.points = _down_outline_points
			SplitterOrientation.RIGHT:
				_outline.points = _right_outline_points
			SplitterOrientation.LEFT:
				_outline.points = _left_outline_points
		_outline.default_color = _DEBUG_LINE_COLOR


## 判定结果内部载体（不耦合 LightInteractionResult，便于纯函数自检）。
class Resolution:
	## 是否分光（命中中间格输入口）；false 表示 BLOCK（消耗主路径但无分支）。
	var split: bool = false
