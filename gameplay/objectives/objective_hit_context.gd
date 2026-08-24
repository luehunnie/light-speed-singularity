class_name ObjectiveHitContext
extends RefCounted

## 目标命中事实快照（冻结 Guide B §25.1，AF-04 / P0-6）。
## Objective 不直接复用 LightInteractionContext；本类是 Objective 域的独立最小命中事实。
## 最小事实集：cell / incoming_direction / light_form / emission_id / runtime_generation；
## PARTICLE 命中额外携带 speed_tier（Ray 命中恒为 -1 哨兵）。暂不加入 particle_runtime_id（冻结裁定）。
## 不可变事实快照：仅经 create_for_ray / create_for_particle 一次构造，之后只读（私有字段 + getter，无写入口）。
## 位置：gameplay/objectives 下；不进场景树、不 preload Runtime / WorldQuery / 机关脚本。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _ParticleMotionRules: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

## Ray 命中 speed_tier 哨兵（Ray 无速度档位；区别于任何合法 SpeedTier 值 0..2）。
const RAY_SPEED_TIER_NONE: int = -1


## 命中所在格。
var _cell: Vector2i
## 命中入射八方向（冻结事实，Objective 域不得改写传播真值）。
var _incoming_direction: Vector2i
## 命中光形态（LightEmissionTypes.LightForm 值：RAY=0 / PARTICLE=1）。
var _light_form: int
## 本次发射身份（ActiveEmissionRegistry 单调 ID）。
var _emission_id: int
## 运行代快照（epoch token；仅事实，不得据此改写 Runtime 状态）。
var _runtime_generation: int
## 光粒速度档位（ParticleMotionRules.SpeedTier 值）；Ray 命中恒为 RAY_SPEED_TIER_NONE。
var _speed_tier: int


## 构造 Ray 形态命中事实；非法方向返回 null 并 push_error。
static func create_for_ray(
		cell: Vector2i,
		incoming_direction: Vector2i,
		emission_id: int,
		runtime_generation: int
) -> ObjectiveHitContext:
	return _create(cell, incoming_direction, _LightEmissionTypes.LightForm.RAY, emission_id, runtime_generation, RAY_SPEED_TIER_NONE)


## 构造 Particle 形态命中事实；非法方向或非法速度档位返回 null 并 push_error。
static func create_for_particle(
		cell: Vector2i,
		incoming_direction: Vector2i,
		emission_id: int,
		runtime_generation: int,
		speed_tier: int
) -> ObjectiveHitContext:
	return _create(cell, incoming_direction, _LightEmissionTypes.LightForm.PARTICLE, emission_id, runtime_generation, speed_tier)


## 统一构造入口（私有）：校验方向 / 形态 / 速度档位后一次写入全部字段。
static func _create(
		cell: Vector2i,
		incoming_direction: Vector2i,
		light_form: int,
		emission_id: int,
		runtime_generation: int,
		speed_tier: int
) -> ObjectiveHitContext:
	if not _LightEmissionTypes.is_valid_direction(incoming_direction):
		push_error("ObjectiveHitContext：非法入射方向 %s，拒绝构造。" % [incoming_direction])
		return null
	if light_form != _LightEmissionTypes.LightForm.RAY and light_form != _LightEmissionTypes.LightForm.PARTICLE:
		push_error("ObjectiveHitContext：非法光形态 %d，拒绝构造。" % [light_form])
		return null
	if light_form == _LightEmissionTypes.LightForm.PARTICLE:
		if speed_tier < _ParticleMotionRules.SpeedTier.SLOW or speed_tier > _ParticleMotionRules.SpeedTier.FAST:
			push_error("ObjectiveHitContext：PARTICLE 命中携带非法速度档位 %d，拒绝构造。" % [speed_tier])
			return null
	elif speed_tier != RAY_SPEED_TIER_NONE:
		push_error("ObjectiveHitContext：RAY 命中不得携带速度档位 %d，拒绝构造。" % [speed_tier])
		return null
	var context: ObjectiveHitContext = ObjectiveHitContext.new()
	context._cell = cell
	context._incoming_direction = incoming_direction
	context._light_form = light_form
	context._emission_id = emission_id
	context._runtime_generation = runtime_generation
	context._speed_tier = speed_tier
	return context


## 命中所在格（只读）。
func get_cell() -> Vector2i:
	return _cell


## 入射八方向（只读）。
func get_incoming_direction() -> Vector2i:
	return _incoming_direction


## 命中光形态（LightEmissionTypes.LightForm 值，只读）。
func get_light_form() -> int:
	return _light_form


## 本次发射身份（只读）。
func get_emission_id() -> int:
	return _emission_id


## 运行代快照（只读）。
func get_runtime_generation() -> int:
	return _runtime_generation


## 光粒速度档位（ParticleMotionRules.SpeedTier 值；Ray 命中为 RAY_SPEED_TIER_NONE，只读）。
func get_speed_tier() -> int:
	return _speed_tier
