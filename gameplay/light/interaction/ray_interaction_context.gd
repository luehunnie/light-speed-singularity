class_name RayInteractionContext
extends LightInteractionContext

## RAY 形态交互 Context（冻结 Guide §19.1 分层）：连续路径光线进入机关格时的不可变事实快照。
## 仅含 Shared Facts（§19.2）；不带 Particle-only 字段（speed_tier / particle_runtime_id 归 ParticleInteractionContext）。
## 由 Runtime 传播层（RayExecutionModule）在机关一次计算前构造；机关只读，不得反向改写传播状态。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## 构造 RAY 交互 Context（唯一正式入口）。
## [br]输入：cell 为光到达的机关格；incoming_direction 须为合法八方向；
##   emission_id 为本次 Ray 发射身份；runtime_generation 为运行代快照。
## [br]返回：合法返回 RayInteractionContext；任一事实非法 push_error 并返回 null（调用方按无交互降级）。
## [br]副作用：仅写入新实例只读字段。
static func create(
		cell: Vector2i,
		incoming_direction: Vector2i,
		emission_id: int,
		runtime_generation: int
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
	return context
