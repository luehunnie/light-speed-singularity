class_name EmitterDefinition
extends FormalContentDefinition

## 发射器域声明（Guide 4.1）：主发射器类型级作者能力，与机关域分域（Guide 39 矩阵）。
## 光形态与朝向均用冻结 token（字符串名）表达；八方向公共 API 属 P0-3，后续接入时 token 对齐方向域。
## 发射器不入库存（非 inventory_eligible 域），由预置进入正式世界。


## 允许的光形态 token 集合（RAY / PARTICLE）。
@export var allowed_forms: Array[StringName] = [&"RAY", &"PARTICLE"]
## 初始光形态 token；必须属于 allowed_forms。
@export var initial_form: StringName = &"RAY"
## 允许的初始朝向 token 集合（方向域字符串名）。
@export var allowed_directions: Array[StringName] = [&"E", &"NE", &"N", &"NW", &"W", &"SW", &"S", &"SE"]
## 初始朝向 token；必须属于 allowed_directions。
@export var initial_direction: StringName = &"E"
## PARTICLE 形态初始速度档。
@export var particle_initial_speed: int = 1


func get_content_domain() -> StringName:
	return &"emitter"


## 校验：基类域 + 发射器域 token 归属。
func validate_definition() -> PackedStringArray:
	var errors := super.validate_definition()
	if not allowed_forms.has(initial_form):
		errors.append("initial_form 不在 allowed_forms 内。")
	if not allowed_directions.has(initial_direction):
		errors.append("initial_direction 不在 allowed_directions 内。")
	return errors
