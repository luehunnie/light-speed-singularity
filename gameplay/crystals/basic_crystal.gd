class_name BasicCrystal
extends Node2D

## 核心闭环原型普通独立水晶占位脚本（plan §4.3 / v0.8 水晶规则）。
## 职责：保存格子坐标与点亮状态，提供 activate() / reset_runtime()，并用当前 ColorRect 的透明度表现未点亮和点亮。
## 位置：由核心闭环原型关卡控制器 core_loop_prototype.gd 按 Vector2i 格子命中后调用。
## 依赖：当前场景结构中必须存在名为 CrystalVisual 的 ColorRect 子节点；水晶基础 RGB 来自该视觉节点的初始颜色。
## 不负责：光是否经过、墙体阻挡、通关判断、颜色/光形式条件、同时组、顺序组或通用 ObjectiveController。
## 注意：普通独立水晶合法点亮后保持到玩家按 R 重置，不随普通光线路径约 1 秒后消失而熄灭。

@export var cell: Vector2i = Vector2i(7, 3)

var is_activated: bool = false

@onready var _visual: ColorRect = $CrystalVisual

const _UNLIT_ALPHA: float = 0.35
const _LIT_ALPHA: float = 1.0

var _base_color: Color = Color(0.35, 0.45, 0.7, 1.0)


## 初始化普通独立水晶视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：读取必需的 CrystalVisual ColorRect 当前颜色作为基础 RGB，并立即按 is_activated 刷新透明度。
## [br]边界条件：CrystalVisual 缺失或类型错误属于场景配置错误，应由 Godot 节点绑定直接暴露，而不是在脚本中静默忽略。
func _ready() -> void:
	# 保留场景里配置的水晶基础 RGB；透明度由点亮状态统一控制。
	_base_color = Color(_visual.color.r, _visual.color.g, _visual.color.b, _LIT_ALPHA)
	_update_visual()


## 点亮当前普通独立水晶。
## [br]本函数无参数、无返回值。
## [br]副作用：首次合法命中时将 is_activated 设为 true，并刷新视觉为基础 RGB 的完全不透明状态。
## [br]状态变化：点亮后保持到 reset_runtime()，不会因光线路径视觉消失而自动恢复。
## [br]边界条件：重复点亮安全无效果；不判断光形式、颜色、同时组或顺序组条件。
func activate() -> void:
	if is_activated:
		return
	is_activated = true
	_update_visual()


## 重置当前普通独立水晶的运行状态。
## [br]本函数无参数、无返回值。
## [br]副作用：将 is_activated 设为 false，并刷新视觉为基础 RGB 的半透明未点亮状态。
## [br]状态变化：只由 R 重置或关卡完整重置流程调用；普通脉冲结束不应调用它来熄灭独立水晶。
## [br]边界条件：重复重置安全；不改变 cell 或基础 RGB。
func reset_runtime() -> void:
	is_activated = false
	_update_visual()


## 按当前点亮状态刷新 ColorRect 视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：设置必需的 CrystalVisual.color，保留基础 RGB，仅在未点亮和点亮之间切换 alpha。
## [br]边界条件：CrystalVisual 必须存在且必须是 ColorRect；未点亮 alpha 为 0.35，点亮 alpha 为 1.0。
func _update_visual() -> void:
	var next_color: Color = _base_color
	next_color.a = _LIT_ALPHA if is_activated else _UNLIT_ALPHA
	_visual.color = next_color
