@tool
class_name EmitterConfigNode
extends GridPlacedObject

## 发射器关卡配置节点（阶段 1 D3B-1）。
## 职责：仅承载可由 Inspector 编辑的发射器配置数据——形态、光线方向、光粒方向、视觉资源、预览可见性，
##   并在配置实际变化时发出信号；不执行发射、不创建视觉节点、不接运行时编排。
## 位置事实：position 继承自 GridPlacedObject，是唯一放置事实；cell 由 position 派生；
##   本类不重新导出 cell、不新增 emitter_position、不使用 Node.name 作为 ID、本批不新增 emitter_id。
## 光粒边界：PARTICLE 当前只允许保存配置与后续编辑器预览，未接运行时；
##   is_runtime_form_supported 仅 RAY 为 true，PARTICLE 不抛假结果、不自动降级为 RAY。
## 方向映射：枚举到稳定 Vector2i 的换算唯一入口为 ray_direction_to_vector / particle_direction_to_vector，
##   不在他处重复维护映射表；合法性集合即枚举自身，不依赖运行期发射器的向量算法。

signal configuration_changed
signal visual_profile_changed(profile: ObjectVisualProfile)
signal preview_visibility_changed(visible: bool)


## 发射形态。RAY 已接正式运行时；PARTICLE 仅保存配置与编辑器预览，不执行发射。
enum LightForm {
	RAY,
	PARTICLE,
}

## 光线八方向枚举（Inspector 下拉用）。
enum RayDirection {
	RIGHT,
	DOWN_RIGHT,
	DOWN,
	DOWN_LEFT,
	LEFT,
	UP_LEFT,
	UP,
	UP_RIGHT,
}

## 光粒四正方向枚举；不允许斜向。
enum ParticleDirection {
	RIGHT,
	DOWN,
	LEFT,
	UP,
}


@export_group("发射形态")
## 当前默认发射形态。
@export var default_light_form: LightForm = LightForm.RAY : set = _set_default_light_form

@export_group("光线方向")
## RAY 形态的默认发射方向。
@export var ray_default_direction: RayDirection = RayDirection.RIGHT : set = _set_ray_default_direction

@export_group("光粒方向")
## PARTICLE 形态的默认发射方向（仅四正方向）。
@export var particle_default_direction: ParticleDirection = ParticleDirection.RIGHT : set = _set_particle_default_direction

@export_group("视觉与预览")
## 永久视觉资源，可为空；非空时由后续视觉视图消费。
@export var visual_profile: ObjectVisualProfile : set = _set_visual_profile
## 编辑器预览是否可见；本批仅承载配置，不实际显示预览。
@export var editor_preview_visible: bool = true : set = _set_editor_preview_visible


# ===== 方向映射（枚举到 Vector2i 的唯一入口） =====

## RayDirection 到稳定 Vector2i 的唯一映射；非法值 push_error 并返回 ZERO。
static func ray_direction_to_vector(direction: RayDirection) -> Vector2i:
	match direction:
		RayDirection.RIGHT: return Vector2i(1, 0)
		RayDirection.DOWN_RIGHT: return Vector2i(1, 1)
		RayDirection.DOWN: return Vector2i(0, 1)
		RayDirection.DOWN_LEFT: return Vector2i(-1, 1)
		RayDirection.LEFT: return Vector2i(-1, 0)
		RayDirection.UP_LEFT: return Vector2i(-1, -1)
		RayDirection.UP: return Vector2i(0, -1)
		RayDirection.UP_RIGHT: return Vector2i(1, -1)
	push_error("EmitterConfigNode：非法 RayDirection 值 %d。" % [direction])
	return Vector2i.ZERO


## ParticleDirection 到稳定 Vector2i 的唯一映射；非法值 push_error 并返回 ZERO。
static func particle_direction_to_vector(direction: ParticleDirection) -> Vector2i:
	match direction:
		ParticleDirection.RIGHT: return Vector2i(1, 0)
		ParticleDirection.DOWN: return Vector2i(0, 1)
		ParticleDirection.LEFT: return Vector2i(-1, 0)
		ParticleDirection.UP: return Vector2i(0, -1)
	push_error("EmitterConfigNode：非法 ParticleDirection 值 %d。" % [direction])
	return Vector2i.ZERO


# ===== 合法性校验 =====
## 枚举合法集合即映射键集合，不依赖运行期发射器的向量八方向算法。

static func _is_valid_light_form(value: int) -> bool:
	return value in LightForm.values()


static func _is_valid_ray_direction(value: int) -> bool:
	return value in RayDirection.values()


static func _is_valid_particle_direction(value: int) -> bool:
	return value in ParticleDirection.values()


# ===== Setter：仅在实际变化时发信号，非法值拒绝并保持旧值 =====

func _set_default_light_form(next: LightForm) -> void:
	if not _is_valid_light_form(next):
		push_error("EmitterConfigNode：非法 LightForm 值 %d，已拒绝并保持旧值。" % [next])
		return
	if default_light_form == next:
		return
	default_light_form = next
	configuration_changed.emit()


func _set_ray_default_direction(next: RayDirection) -> void:
	if not _is_valid_ray_direction(next):
		push_error("EmitterConfigNode：非法 RayDirection 值 %d，已拒绝并保持旧值。" % [next])
		return
	if ray_default_direction == next:
		return
	ray_default_direction = next
	configuration_changed.emit()


func _set_particle_default_direction(next: ParticleDirection) -> void:
	if not _is_valid_particle_direction(next):
		push_error("EmitterConfigNode：非法 ParticleDirection 值 %d，已拒绝并保持旧值。" % [next])
		return
	if particle_default_direction == next:
		return
	particle_default_direction = next
	configuration_changed.emit()


func _set_visual_profile(next: ObjectVisualProfile) -> void:
	if visual_profile == next:
		return
	visual_profile = next
	visual_profile_changed.emit(next)
	configuration_changed.emit()


func _set_editor_preview_visible(next: bool) -> void:
	if editor_preview_visible == next:
		return
	editor_preview_visible = next
	preview_visibility_changed.emit(next)
	configuration_changed.emit()


# ===== 公共 getter =====

func get_default_light_form() -> LightForm:
	return default_light_form


func get_ray_direction() -> RayDirection:
	return ray_default_direction


func get_particle_direction() -> ParticleDirection:
	return particle_default_direction


func get_ray_direction_vector() -> Vector2i:
	return ray_direction_to_vector(ray_default_direction)


func get_particle_direction_vector() -> Vector2i:
	return particle_direction_to_vector(particle_default_direction)


## 根据当前默认形态返回对应方向向量。
func get_active_direction_vector() -> Vector2i:
	match default_light_form:
		LightForm.RAY:
			return get_ray_direction_vector()
		LightForm.PARTICLE:
			return get_particle_direction_vector()
	return Vector2i.ZERO


func get_visual_profile() -> ObjectVisualProfile:
	return visual_profile


func is_editor_preview_visible() -> bool:
	return editor_preview_visible


## 仅 RAY 接正式运行时；PARTICLE 不抛假结果、不自动降级为 RAY。
func is_runtime_form_supported() -> bool:
	return default_light_form == LightForm.RAY
