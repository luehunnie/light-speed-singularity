class_name LightInteractionContext
extends RefCounted

## 光交互共享事实基类（冻结 Guide §19）：Ray / Particle 两形态 Context 的共同最小字段层。
## Shared Facts（§19.2 冻结最小集）：cell / incoming_direction / light_form / emission_id / runtime_generation。
## 不可变事实快照（§23 原则 1）：仅经 create 一次构造，之后只读（私有字段 + getter，不提供写入口）。
## 不公开（§19.4）：WorldQuery / SceneTree / LevelRuntimeController / ObjectiveController / Stable Instance ID /
##   previous_cell / 绝对 Scheduler Tick——机关不得经 Context 触达 Runtime 基础设施。
## 位置：gameplay/light/interaction 下；不进场景树、不 preload 机关 / Runtime。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")

## 光到达的机关所在格。
var _cell: Vector2i
## 光进入该格时的入射八方向（冻结事实，机关不得改写传播真值）。
var _incoming_direction: Vector2i
## 光形态（LightEmissionTypes.LightForm 值：RAY=0 / PARTICLE=1）。
var _light_form: int
## 本次发射身份（ActiveEmissionRegistry 单调 ID；Ray 恒有真实值，Particle 经 state 携带）。
var _emission_id: int
## 运行代（epoch token；仅事实快照，机关不得据此改写 Runtime 状态）。
var _runtime_generation: int


## 构造共享事实（子类 create 调用；不做公开入口）。
## [br]校验：incoming_direction 须为合法八方向；light_form 须为 LightForm 枚举值；任一非法 push_error 并返回 false。
func _setup_shared(
		cell: Vector2i,
		incoming_direction: Vector2i,
		light_form: int,
		emission_id: int,
		runtime_generation: int
) -> bool:
	if not _DirectionDomain.is_valid(incoming_direction):
		push_error("LightInteractionContext：非法入射方向 %s，拒绝构造。" % [incoming_direction])
		return false
	if light_form != _LightEmissionTypes.LightForm.RAY and light_form != _LightEmissionTypes.LightForm.PARTICLE:
		push_error("LightInteractionContext：非法光形态 %d，拒绝构造。" % [light_form])
		return false
	_cell = cell
	_incoming_direction = incoming_direction
	_light_form = light_form
	_emission_id = emission_id
	_runtime_generation = runtime_generation
	return true


## 光到达的机关所在格（只读）。
func get_cell() -> Vector2i:
	return _cell


## 入射八方向（只读）。
func get_incoming_direction() -> Vector2i:
	return _incoming_direction


## 光形态（LightEmissionTypes.LightForm 值，只读）。
func get_light_form() -> int:
	return _light_form


## 本次发射身份（只读）。
func get_emission_id() -> int:
	return _emission_id


## 运行代快照（只读）。
func get_runtime_generation() -> int:
	return _runtime_generation
