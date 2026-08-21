class_name DirectionDomain
extends RefCounted

## 唯一八方向公共 Domain（冻结 Guide §18 / P0-3）。
## 职责：持有唯一全局顺时针 token 顺序与 token↔向量映射，提供 is_valid / to_vector / from_vector /
##   rotate_clockwise / rotate_counterclockwise / opposite / is_orthogonal / is_diagonal / same_axis 纯函数；
##   镜面反射、双格几何等机关自身规则不进入本域（Guide §18）。
## 单一真相：八方向合法向量集合不自建第二份，is_valid / is_diagonal 委托 LightEmissionTypes；
##   顺时针顺序与本模块的向量序列一致（启动断言见 contract 测试）。
## 位置：gameplay/light 下；纯静态无状态，不进场景树、不 preload 机关 / Runtime / 场景。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

## 唯一全局顺时针方向 token 顺序（Guide §18 冻结；RIGHT 起顺时针）。
const CLOCKWISE_ORDER: Array[StringName] = [
	&"RIGHT",
	&"DOWN_RIGHT",
	&"DOWN",
	&"DOWN_LEFT",
	&"LEFT",
	&"UP_LEFT",
	&"UP",
	&"UP_RIGHT",
]

## 与 CLOCKWISE_ORDER 位置对应的八方向单位向量（y 向下为正的网格约定）。
const _VECTORS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
	Vector2i(0, -1),
	Vector2i(1, -1),
]


## 判定方向向量是否为合法八方向（委托 LightEmissionTypes，唯一合法集合事实来源）。
static func is_valid(direction: Vector2i) -> bool:
	return _LightEmissionTypes.is_valid_direction(direction)


## 判定方向 token 是否为 CLOCKWISE_ORDER 内的合法 token。
static func is_valid_token(token: StringName) -> bool:
	return token in CLOCKWISE_ORDER


## token → 八方向单位向量；未知 token 返回 Vector2i.ZERO（非法哨兵，调用方须校验）。
static func to_vector(token: StringName) -> Vector2i:
	var index: int = CLOCKWISE_ORDER.find(token)
	if index < 0:
		return Vector2i.ZERO
	return _VECTORS[index]


## 八方向单位向量 → token；非法向量返回空 StringName（调用方以 is_valid_token 判空）。
static func from_vector(direction: Vector2i) -> StringName:
	var index: int = _VECTORS.find(direction)
	if index < 0:
		return &""
	return CLOCKWISE_ORDER[index]


## 方向向量顺时针旋转 steps 步（默认 1）；非法向量原样返回，不猜测结果。
static func rotate_clockwise(direction: Vector2i, steps: int = 1) -> Vector2i:
	return _rotated(direction, steps)


## 方向向量逆时针旋转 steps 步（默认 1）；非法向量原样返回。
static func rotate_counterclockwise(direction: Vector2i, steps: int = 1) -> Vector2i:
	return _rotated(direction, -steps)


## 反方向（旋转 4 步）；非法向量原样返回。
static func opposite(direction: Vector2i) -> Vector2i:
	return _rotated(direction, 4)


## 是否正交方向（恰一轴非零）；非法方向返回 false。
static func is_orthogonal(direction: Vector2i) -> bool:
	if not is_valid(direction):
		return false
	return (direction.x == 0) != (direction.y == 0)


## 是否斜向方向（委托 LightEmissionTypes 唯一判定）。
static func is_diagonal(direction: Vector2i) -> bool:
	return _LightEmissionTypes.is_diagonal_direction(direction)


## 两方向是否共轴（同一直线：平行或反平行）；非法输入返回 false。
static func same_axis(direction_a: Vector2i, direction_b: Vector2i) -> bool:
	if not is_valid(direction_a) or not is_valid(direction_b):
		return false
	return direction_a.x * direction_b.y - direction_a.y * direction_b.x == 0


## 按 CLOCKWISE_ORDER 旋转的内部实现；非法向量 / steps==0 原样返回。
static func _rotated(direction: Vector2i, steps: int) -> Vector2i:
	var index: int = _VECTORS.find(direction)
	if index < 0:
		return direction
	var next_index: int = (index + steps) % _VECTORS.size()
	if next_index < 0:
		next_index += _VECTORS.size()
	return _VECTORS[next_index]
