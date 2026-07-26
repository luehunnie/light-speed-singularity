class_name BasicCrystal
extends Node2D

## 核心闭环原型普通独立水晶占位脚本（plan §4.3 / v0.8 水晶规则）。
## 职责：保存格子坐标与点亮状态，提供 activate() / reset_runtime()，
## 并通过 ObjectVisualView 的两个内容状态表现未点亮和点亮：
## is_activated == false → state_id "unlit"；is_activated == true → state_id "lit"。
## 位置：由核心闭环原型关卡控制器 core_loop_prototype.gd 按 Vector2i 格子命中后调用。
## 依赖：当前场景结构中必须存在挂载 ObjectVisualView 的视觉子节点，且该视图的 visual_profile 已配置为 basic_crystal_visuals.tres。
## 不负责：光是否经过、墙体阻挡、通关判断、颜色/光形式条件、同时组、顺序组或通用 ObjectiveController。
## 注意：普通独立水晶合法点亮后保持到玩家按 R 重置，不随普通光线路径约 1 秒后消失而熄灭。
## 视觉边界：BasicCrystal 不直接访问 TextureRect.texture，只通过 ObjectVisualView 的公开接口 set_content_state() 切换内容状态。

@export var cell: Vector2i = Vector2i(7, 3)

## 关卡作者显式配置的稳定水晶 ID；不从 Node.name 推导、不随机生成、不为空静默填充，cell 变化时保持不变。由 LevelObjectRegistry 再次校验。
@export var crystal_id: StringName = &""

var is_activated: bool = false

@onready var _visual: ObjectVisualView = $VisualView

# 内容状态 ID 契约：必须与 basic_crystal_visuals.tres 中 states 的 state_id 保持一致。
const STATE_UNLIT: StringName = &"unlit"
const STATE_LIT: StringName = &"lit"


## 初始化普通独立水晶视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按初始 is_activated（false）把内容状态写入 ObjectVisualView，显示未点亮纹理。
## [br]边界条件：VisualView 子节点缺失或类型错误属于场景配置错误，应由 Godot 节点绑定直接暴露，而不是在脚本中静默忽略。
func _ready() -> void:
	_apply_state()


## 返回显式配置的稳定 crystal_id；可能为空（&""），由 LevelObjectRegistry 拒绝并暴露，不由本脚本兜底填充。
func get_crystal_id() -> StringName:
	return crystal_id


## 点亮当前普通独立水晶。
## [br]本函数无参数、无返回值。
## [br]副作用：首次合法命中时将 is_activated 设为 true，并通过 ObjectVisualView.set_content_state() 切换到 "lit" 内容状态。
## [br]状态变化：点亮后保持到 reset_runtime()，不会因光线路径视觉消失而自动恢复。
## [br]边界条件：重复点亮安全无效果；不判断光形式、颜色、同时组或顺序组条件。
func activate() -> void:
	if is_activated:
		return
	is_activated = true
	_apply_state()


## 重置当前普通独立水晶的运行状态。
## [br]本函数无参数、无返回值。
## [br]副作用：将 is_activated 设为 false，并通过 ObjectVisualView.set_content_state() 切换回 "unlit" 内容状态。
## [br]状态变化：只由 R 重置或关卡完整重置流程调用；普通脉冲结束不应调用它来熄灭独立水晶。
## [br]边界条件：重复重置安全；不改变 cell。
func reset_runtime() -> void:
	is_activated = false
	_apply_state()


## 按当前点亮状态把内容状态写入 ObjectVisualView。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 ObjectVisualView 的公开接口 set_content_state()，由视图按 profile 选取并刷新纹理；本脚本不直接操作纹理或颜色子节点。
## [br]边界条件：is_activated 为 true 时写入 "lit"，为 false 时写入 "unlit"；反复调用安全。
func _apply_state() -> void:
	_visual.set_content_state(STATE_LIT if is_activated else STATE_UNLIT)
