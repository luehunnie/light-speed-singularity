class_name FixedEmitter
extends RefCounted

## 固定发射器（Day 2 D2-E）：固定发射器运行期格子与方向的唯一所有者。
## 由 core_loop_prototype 在 _ready 中用 Inspector 初始配置（emitter_cell/emitter_direction）构造一次；此后运行期格子和方向只由此实例提供。
## 职责：持有格子与方向、判断方向合法性、构建 FireRequest；不调用 begin_pulse、不递增 pulse_generation、不调用 RayExecutionModule、不创建视觉、不激活水晶、不结束脉冲。
## 固定语义：格子不可移动，不提供 set_cell；不实现 WASD/方向 UI/光线光粒切换/READY_TO_FIRE/开始运行按钮。
## 非法方向语义：保留非法初始方向不自动修正，build_fire_request 返回 null，由核心按旧行为拒绝发射（先于 _prepare_for_new_pulse 与 begin_pulse）。
## 依赖：仅 FireRequest（preload）；不依赖核心、场景树、RunState、世界查询或 Diagnostics。方向合法性规则唯一来源为本类 is_valid_direction，核心不再保留副本。


const _FireRequest: GDScript = preload("res://gameplay/light/fire_request.gd")


## 发射器所在格（运行期不可变）。
var _cell: Vector2i
## 当前发射方向；保留非法值不自动修正，由 build_fire_request 拒绝发射。
var _direction: Vector2i


## 构造固定发射器；保留传入的方向原值，非法方向不自动修正，由 build_fire_request 在发射时拒绝。
func _init(initial_cell: Vector2i, initial_direction: Vector2i) -> void:
	_cell = initial_cell
	_direction = initial_direction


## 发射器所在格。
func get_cell() -> Vector2i:
	return _cell


## 当前发射方向（可能为非法值，调用方据 build_fire_request 结果决定是否发射）。
func get_direction() -> Vector2i:
	return _direction


## 尝试设置发射方向；仅合法方向（非零且分量绝对值不超过 1）成功并写入，非法方向返回 false 且旧方向不变。
## 本批无现有调用方，仅提供合法数据边界，不接入新输入。
func try_set_direction(direction: Vector2i) -> bool:
	if not is_valid_direction(direction):
		return false
	_direction = direction
	return true


## 构建一次普通光线发射请求；方向非法时返回 null，核心据此按旧行为退出（先于 _prepare_for_new_pulse 与 begin_pulse）。
func build_fire_request(max_steps: int) -> _FireRequest:
	if not is_valid_direction(_direction):
		return null
	return _FireRequest.new(_cell, _direction, max_steps)


## 判断传播方向是否合法：非零且每分量绝对值不超过 1。ZERO、超过一格的方向与非法斜率均被拒绝。
## 唯一规则来源，核心与运行期移动自检共用，不在他处复制。
static func is_valid_direction(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)
