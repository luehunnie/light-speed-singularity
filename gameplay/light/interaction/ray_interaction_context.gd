class_name RayInteractionContext
extends LightInteractionContext

## RAY 形态交互 Context（冻结 Guide §19.1 分层）：连续路径光线进入机关格时的不可变事实快照。
## 仅含 Shared Facts（§19.2）；不带 Particle-only 字段（speed_tier / particle_runtime_id 归 ParticleInteractionContext）。
## current_color 为 RAY 专属事实（光粒无颜色），故放本类不放共享基类 LightInteractionContext。
## 由 Runtime 传播层（RayExecutionModule）在机关一次计算前构造；机关只读，不得反向改写传播状态。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。

const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

## 当前光线颜色（ColorValue 枚举值，RAY 专属事实；光粒无颜色故不放共享基类）。
var _current_color: int


## 构造 RAY 交互 Context（唯一正式入口）。
## [br]输入：cell 为光到达的机关格；incoming_direction 须为合法八方向；
##   emission_id 为本次 Ray 发射身份；runtime_generation 为运行代快照；
##   current_color 为当前光线颜色（ColorValue 枚举值，默认 WHITE，须为真实四色）。
## [br]返回：合法返回 RayInteractionContext；任一事实非法 push_error 并返回 null（调用方按无交互降级）。
## [br]副作用：仅写入新实例只读字段。
static func create(
		cell: Vector2i,
		incoming_direction: Vector2i,
		emission_id: int,
		runtime_generation: int,
		current_color: int = _RayColor.ColorValue.WHITE
) -> RayInteractionContext:
	var context: RayInteractionContext = RayInteractionContext.new()
	if not context._setup_shared(
			cell,
			incoming_direction,
			_LightEmissionTypes.LightForm.RAY,
			emission_id,
			runtime_generation
	):
		return null
	if not _RayColor.is_valid(current_color):
		push_error("RayInteractionContext: 非法当前颜色 %d，拒绝构造。" % current_color)
		return null
	context._current_color = current_color
	return context

## 读取当前光线颜色（只读）。
## [br]返回 ColorValue 枚举值；本函数无副作用，不修改传播状态。
func get_current_color() -> int:
	return _current_color
