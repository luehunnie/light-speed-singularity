class_name RayMechanismAdapter
extends RefCounted

## 普通光线机关光学适配器：统一计算机关对入射方向的光学响应，返回 RayMechanismResult（CONTINUE/REDIRECT/BLOCK）。
## 由 RayExecutionModule 在逐格传播中调用；不加入场景树、不持核心节点引用或 RunState、无副作用。
## 边界：null 与未知机关类型保持原方向（CONTINUE），已登记但失效节点停止（BLOCK）；不得因类型未知崩溃或推测光学行为。


# 用 preload 引用 RayMechanismResult，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")


## 评估机关节点对入射方向的光学响应：null 与未知机关类型返回 CONTINUE，已登记但失效节点返回 BLOCK；
## SingleCellMirror 返回其 reflect_direction()（非零→REDIRECT，零→BLOCK）。无副作用，不抛异常。
static func evaluate(
		mechanism: Variant,
		incoming_direction: Vector2i
) -> _RayMechanismResult:
	# 无正式机关节点：保持原方向（既有行为）。
	if mechanism == null:
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 机关节点为空，本轮保持原方向。")
		return _RayMechanismResult.continue_with(incoming_direction)

	# 已登记但节点已失效：安全停止传播。
	if not is_instance_valid(mechanism):
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 机关节点已失效，停止传播。")
		return _RayMechanismResult.block()

	# 未知机关类型：保持原方向，不推测光学行为。
	if mechanism is not SingleCellMirror:
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 未知机关类型，本轮不产生光学效果。")
		return _RayMechanismResult.continue_with(incoming_direction)

	# SingleCellMirror：调用其公开 reflect_direction()，零向量表示非法入射方向，转入 BLOCK。
	var reflected_direction: Vector2i = mechanism.reflect_direction(incoming_direction)
	if reflected_direction == Vector2i.ZERO:
		if OS.is_debug_build():
			print_debug("RayMechanismAdapter: 镜面收到非法入射方向 %s，停止传播。" % [incoming_direction])
		return _RayMechanismResult.block()
	return _RayMechanismResult.redirect_to(reflected_direction)
