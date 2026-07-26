class_name FireRequest
extends RefCounted

## 普通光线发射请求数据（Day 2 D2-E）：保存一次普通主发射源脉冲发射所需的纯数据（起始格、方向、最大步数）。
## 由 FixedEmitter.build_fire_request() 构造；核心 fire_light() 据此调用 RayExecutionModule.execute()。
## 纯数据：不执行传播、不修改方向、不访问场景树、不持有 RunState/发射器节点/世界查询/水晶/光路结果/光粒类型/颜色或光强。
## 方向合法性由 FixedEmitter 在构造前校验；本类不重复校验，只承载已确认的发射事实。


## 光线起始格（发射器所在格）。
var _start_cell: Vector2i
## 发射方向（八方向单位 Vector2i，非零且分量绝对值不超过 1）。
var _direction: Vector2i
## 传播最大步数上限；触顶由 RayExecutionModule 记录 STEP_LIMIT，核心据此复现 push_warning。
var _max_steps: int


## 构造发射请求；只写入三项纯数据，不校验、不产生副作用。方向合法性由 FixedEmitter 保证。
func _init(start_cell: Vector2i, direction: Vector2i, max_steps: int) -> void:
	_start_cell = start_cell
	_direction = direction
	_max_steps = max_steps


## 发射起始格。
func get_start_cell() -> Vector2i:
	return _start_cell


## 发射方向。
func get_direction() -> Vector2i:
	return _direction


## 传播最大步数。
func get_max_steps() -> int:
	return _max_steps
