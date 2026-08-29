class_name RayExecutionResult
extends RefCounted

## 普通光线执行结果（Day 1 D1-C）。
## 职责：保存 RayExecutionModule 一次无副作用传播产生的事实——有序传播步骤（每格坐标、入射方向、是否有水晶）、停止原因与是否达到最大步数。
## 位置：由 RayExecutionModule 构造并返回；核心闭环原型在 fire_light() 中读取后逐格按顺序应用视觉与水晶副作用，不把本对象传入其他地方。
## 依赖：Vector2i 格子与方向；不依赖场景树、OccupancyRegistry、库存、RunState、UI、Diagnostics 或光路视觉节点。
## 不负责：机关识别、反射计算、地图读取、世界修改、水晶激活、光路视觉创建、脉冲结束、pulse_generation。
## 边界：只保存事实，不执行任何副作用；停止原因仅保留当前原型真实存在的最小集合，不携带光强、分光或未来玩法字段；
## 颜色仅记录进入该格时的到达色（ColorValue，供水晶命中事实构造；机关 COLOR_CHANGE 从下一格起生效）。


## 传播停止原因；与旧 fire_light() 逐格循环的 break 分支一一对应，顺序保真以旧循环为准。
## [br]OUT_OF_BOUNDS：下一格越界；WALL：下一格为墙；MECHANISM_BLOCK：进入格机关返回 BLOCK；STEP_LIMIT：达到 max_steps。
enum StopReason {
	OUT_OF_BOUNDS,
	WALL,
	MECHANISM_BLOCK,
	STEP_LIMIT,
}


## 停止原因；模块在每条退出路径上都写入，默认值不会被返回。
var stop_reason: StopReason = StopReason.OUT_OF_BOUNDS

## 是否达到最大步数；核心据此复现旧 push_warning，不在模块内输出日志。
var reached_step_limit: bool = false

## 按光进入顺序排列的传播步骤；每步保存该格坐标、进入该格时的入射方向与该格是否存在水晶（镜面格记入射方向，反射后出射方向从下一步起生效）。
var steps: Array[_Step] = []


## 追加一个传播步骤：cell 为光进入的格子，incoming_direction 为进入该格时的方向（用于光路视觉），has_crystal 表示该格是否存在需尝试激活的水晶。
## [br]无返回值；只向 steps 末尾追加一个 _Step，不修改其他字段。
func add_step(cell: Vector2i, incoming_direction: Vector2i, has_crystal: bool, color: int = 0) -> void:
	steps.append(_Step.new(cell, incoming_direction, has_crystal, color))


## 单步传播事实：光进入的格子、该格入射方向与该格是否存在水晶。
## [br]不携带机关节点或反射结果；仅供核心按顺序逐格应用光路视觉与水晶激活。
class _Step:
	extends RefCounted

	## 光进入的格子坐标。
	var cell: Vector2i
	## 进入该格时的入射方向（八方向 Vector2i 单位向量）。
	var incoming_direction: Vector2i
	## 该格是否存在普通独立水晶；核心按步骤顺序据此决定是否尝试激活。
	var has_crystal: bool
	## 进入该格时的到达色（RayColor.ColorValue 值；机关 COLOR_CHANGE 从下一格起生效，供水晶命中事实构造）。
	var color: int

	func _init(
		p_cell: Vector2i = Vector2i.ZERO,
		p_incoming_direction: Vector2i = Vector2i.ZERO,
		p_has_crystal: bool = false,
		p_color: int = 0
	) -> void:
		cell = p_cell
		incoming_direction = p_incoming_direction
		has_crystal = p_has_crystal
		color = p_color
