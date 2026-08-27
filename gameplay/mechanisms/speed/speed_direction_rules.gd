extends RefCounted

## 速度机关（加速器/减速器）方向公共规则（S3-01 统一八方向 API 的速度域入口）。
## 职责：把两机关共有的「枚举值 ↔ 八方向事实」换算与顺时针轮转收敛为单一入口，
##   全部方向事实（token 顺序、向量、旋转）唯一来源为 gameplay/light/direction_domain.gd（Guide §18 冻结），
##   本模块不自建第二份向量表或顺序表。
## 绑定约定：AcceleratorDirection / DeceleratorDirection 枚举值序与 DirectionDomain.CLOCKWISE_ORDER
##   下标一一对齐（两机关脚本同序声明；对齐由 direction_api_unification_test 逐值锁定）。
## 位置：gameplay/mechanisms/speed/ 下纯静态模块；不进场景树、不 preload 场景、不持实例状态。

const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")


## 枚举值 → 八方向单位向量（经 DirectionDomain.to_vector 唯一事实换算）。
## [br]direction_value 是速度机关方向枚举值。
## [br]返回 Vector2i 方向向量；越界值返回 Vector2i.ZERO（非法哨兵，不猜测、不报错，调用方自行校验）。
## [br]本静态函数无副作用，不依赖实例状态。
static func direction_to_vector(direction_value: int) -> Vector2i:
	if not _is_valid_value(direction_value):
		return Vector2i.ZERO
	return _DirectionDomain.to_vector(_DirectionDomain.CLOCKWISE_ORDER[direction_value])


## 顺时针轮转到下一方向枚举值（经 DirectionDomain.rotate_clockwise 唯一顺序事实换算）。
## [br]direction_value 是当前方向枚举值。
## [br]返回下一枚举值；越界值原样返回（不猜测）。
## [br]本静态函数无副作用；边界条件：轮转路径 token → 向量 → token → 枚举值全程经 DirectionDomain，
## 本模块与调用方脚本均不维护独立顺序表。
static func cycle_clockwise(direction_value: int) -> int:
	if not _is_valid_value(direction_value):
		return direction_value
	var token: StringName = _DirectionDomain.CLOCKWISE_ORDER[direction_value]
	var rotated_token: StringName = _DirectionDomain.from_vector(
		_DirectionDomain.rotate_clockwise(_DirectionDomain.to_vector(token))
	)
	return _DirectionDomain.CLOCKWISE_ORDER.find(rotated_token)


## 枚举值是否落在 DirectionDomain.CLOCKWISE_ORDER 覆盖范围内。
static func _is_valid_value(direction_value: int) -> bool:
	return direction_value >= 0 and direction_value < _DirectionDomain.CLOCKWISE_ORDER.size()
