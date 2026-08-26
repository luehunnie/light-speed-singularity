@tool
class_name EmitterConfigNode
extends GridPlacedObject

## 发射器关卡配置节点（阶段 1 D3B-1 / D3C-0 / D3C-2.5）。
## 职责：承载可由 Inspector 编辑的发射器配置数据——形态、光线方向、光粒方向、视觉资源、预览可见性，
##   在配置实际变化时发出信号，并单向驱动两个可选直属子节点（EmitterVisual / EmissionPreview）的显示；
##   D3C-2.5：根据 default_light_form 与对应活动方向计算 EmitterVisual.rotation，不旋转根节点、不建立方向到角度的第二张映射表；
##   不执行发射、不创建子节点、不接运行时编排，子节点缺失由后续阶段检查结构完整性。
## 位置事实：position 继承自 GridPlacedObject，是唯一放置事实；cell 由 position 派生；
##   本类不重新导出 cell、不新增 emitter_position、不使用 Node.name 作为 ID、本批不新增 emitter_id。
## 光粒边界（B3a→B3b-1）：PARTICLE 形态的 Runtime 快照（light_form / emitter_cell / active_direction）已可只读读取，
##   与 RAY 同样产出合法八方向 Vector2i；B3b-1 起 is_runtime_form_supported 对 RAY/PARTICLE 均返回 true（与真实 Runtime 能力同步），
##   PARTICLE 已成为合法 Runtime form；不创建 ParticleRuntimeState / ParticleFireRequest，调度器 / Timer 由 LevelRuntimeController 接线，本类不参与。
## 形态事实来源：公共 LightForm 契约为 LightEmissionTypes.LightForm（RAY=0/PARTICLE=1，冻结）；
##   本类 LightForm 枚举为 Inspector / 旧场景 / 旧测试兼容别名，数值与公共契约逐一对齐，合法性校验走公共契约。
## 方向映射：枚举到稳定 Vector2i 的换算唯一入口为 ray_direction_to_vector / particle_direction_to_vector，
##   不在他处重复维护映射表；输出方向合法性统一由公共 LightEmissionTypes.is_valid_direction 判定，本类不另立八方向合法集合。

## 公共光形态契约唯一来源（preload 避开全局 class 缓存问题）；本类 LightForm 仅作兼容别名，合法性校验委派此模块。
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

signal configuration_changed
signal visual_profile_changed(profile: ObjectVisualProfile)
signal preview_visibility_changed(visible: bool)


## 发射形态（Inspector / 旧场景 / 旧测试兼容别名）。
## 公共事实来源为 LightEmissionTypes.LightForm（RAY=0/PARTICLE=1，冻结）；本枚举数值与公共契约逐一对齐，禁止独立偏移。
enum LightForm {
	## 光线形态（= LightEmissionTypes.LightForm.RAY，冻结 0）。
	RAY = 0,
	## 光粒形态（= LightEmissionTypes.LightForm.PARTICLE，冻结 1）。
	PARTICLE = 1,
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

## 光粒方向枚举（八方向）。旧四正方向数值冻结（RIGHT=0/DOWN=1/LEFT=2/UP=3），新四斜向以追加方式加入，不重排旧值；
## 八个方向的输出合法性统一由 LightEmissionTypes.is_valid_direction 判定，本类不另立八方向合法集合。
enum ParticleDirection {
	## → 正向（冻结 0）。
	RIGHT = 0,
	## ↓ 正向（冻结 1）。
	DOWN = 1,
	## ← 正向（冻结 2）。
	LEFT = 2,
	## ↑ 正向（冻结 3）。
	UP = 3,
	## ↘ 斜向（追加 4）。
	DOWN_RIGHT = 4,
	## ↙ 斜向（追加 5）。
	DOWN_LEFT = 5,
	## ↖ 斜向（追加 6）。
	UP_LEFT = 6,
	## ↗ 斜向（追加 7）。
	UP_RIGHT = 7,
}


# 内容状态 ID 契约：必须与 emitter_visuals.tres 中 states 的 state_id 保持一致。
# 形态轴 = 光形态（RAY→ray / PARTICLE→particle，与公共 LightForm 两种既有形态一一对应，不发明未来形态）；
# default 为回退态；三态当前共享同一纹理，Artwork 后续可经 profile 逐态替换。
const STATE_DEFAULT: StringName = &"default"
const STATE_RAY: StringName = &"ray"
const STATE_PARTICLE: StringName = &"particle"


@export_group("发射形态")
## 当前默认发射形态。
@export var default_light_form: LightForm = LightForm.RAY : set = _set_default_light_form

## 关卡是否允许玩家用 Q 切换主发射器光形态（M4-E4；主发射器 v0.3 §4.2）。
## false 时任何状态下 Q 都不改变主发射器形态，保持本节点配置的初始形态；真值经 is_form_switch_allowed 供 core_loop 启动读取一次注入 LevelRuntimeController。
## 本配置在“开始运行”前后含义一致：Q 是运行期专用权限（非 COMPLETED 均可），不属于 §8 的 SETUP 内部配置锁定范围。
@export var allow_form_switch: bool = false

@export_group("光线方向")
## RAY 形态的默认发射方向。
@export var ray_default_direction: RayDirection = RayDirection.RIGHT : set = _set_ray_default_direction

@export_group("光粒方向")
## PARTICLE 形态的默认发射方向（八方向）。
@export var particle_default_direction: ParticleDirection = ParticleDirection.RIGHT : set = _set_particle_default_direction

@export_group("视觉与预览")
## 永久视觉资源，可为空；非空时由后续视觉视图消费。
@export var visual_profile: ObjectVisualProfile : set = _set_visual_profile
## 编辑器预览是否可见；本批仅承载配置，不实际显示预览。
@export var editor_preview_visible: bool = true : set = _set_editor_preview_visible

# AF-08 Authoring 字段（stable_instance_id / editor_note / interaction_profile）继承自 GridPlacedObject
# （本类 extends GridPlacedObject）；默认 interaction_profile=fixed 与主发射器固定预置语义一致，无需覆写。


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


## ParticleDirection 到稳定 Vector2i 的唯一映射（八方向）；非法值 push_error 并返回 ZERO。
## 输出八个向量经 LightEmissionTypes.is_valid_direction 全部合法，与光线方向向量共用同一公共合法集合。
static func particle_direction_to_vector(direction: ParticleDirection) -> Vector2i:
	match direction:
		ParticleDirection.RIGHT: return Vector2i(1, 0)
		ParticleDirection.DOWN: return Vector2i(0, 1)
		ParticleDirection.LEFT: return Vector2i(-1, 0)
		ParticleDirection.UP: return Vector2i(0, -1)
		ParticleDirection.DOWN_RIGHT: return Vector2i(1, 1)
		ParticleDirection.DOWN_LEFT: return Vector2i(-1, 1)
		ParticleDirection.UP_LEFT: return Vector2i(-1, -1)
		ParticleDirection.UP_RIGHT: return Vector2i(1, -1)
	push_error("EmitterConfigNode：非法 ParticleDirection 值 %d。" % [direction])
	return Vector2i.ZERO


# ===== 合法性校验 =====
## 枚举合法集合即映射键集合，不依赖运行期发射器的向量八方向算法。

## 形态合法性以公共契约 LightEmissionTypes.LightForm 为准；本地 LightForm 仅是兼容别名，不在本类独立扩张。
static func _is_valid_light_form(value: int) -> bool:
	return value in _LightEmissionTypes.LightForm.values()


static func _is_valid_ray_direction(value: int) -> bool:
	return value in RayDirection.values()


static func _is_valid_particle_direction(value: int) -> bool:
	return value in ParticleDirection.values()


# ===== 子节点接线（D3C-0） =====
# 固定直属子节点角色名仅用于预制场景内部接线，不作为稳定 emitter_id；单向同步配置到视图，子节点缺失安全跳过。

## 入树时将当前配置单向同步给两个可选直属子节点；不修改自身 position/cell，不执行发射。
## 同步顺序：Visual Profile → EmitterVisual 内容状态（形态轴）→ EmitterVisual 朝向 → EmissionPreview 状态（D3C-2.5）。
## 基类 GridPlacedObject 未定义 _ready，故不调 super。
func _ready() -> void:
	_refresh_visual()
	_refresh_visual_state()
	_refresh_visual_orientation()
	_refresh_preview()


## 取名为 EmitterVisual 的 ObjectVisualView 直属子节点；缺失或类型不符返回 null。
func _get_emitter_visual() -> ObjectVisualView:
	var node := get_node_or_null("EmitterVisual")
	if node is ObjectVisualView:
		return node
	return null


## 取名为 EmissionPreview 的 EmissionPreview 直属子节点；缺失或类型不符返回 null。
func _get_emission_preview() -> EmissionPreview:
	var node := get_node_or_null("EmissionPreview")
	if node is EmissionPreview:
		return node
	return null


## 将当前 visual_profile 单向同步给 EmitterVisual；缺失则跳过，不创建子节点或资源。
func _refresh_visual() -> void:
	var visual := _get_emitter_visual()
	if visual == null:
		return
	visual.set_profile(visual_profile)


## 将当前 default_light_form 对应的内容状态写入 EmitterVisual（配置轴）。
## 经 ObjectVisualView.set_content_state 正式契约驱动纹理选取，不并行维护第二套纹理切换。
func _refresh_visual_state() -> void:
	set_visual_light_form(default_light_form)


## 运行期形态→视觉正式入口：把给定 LightForm 数值映射为内容状态并驱动 EmitterVisual。
## 供 Q 形态切换 / R 恢复初始形态后由关卡核心调用（形态的运行期事实由关卡运行时拥有，本节点只收渲染结果）；
## 不回写 default_light_form（配置事实与运行期事实分离），不做权限判定（权限门在 LevelRuntimeController）。
## EmitterVisual 缺失时安全跳过，不创建子节点。
func set_visual_light_form(light_form: int) -> void:
	var visual := _get_emitter_visual()
	if visual == null:
		return
	visual.set_content_state(content_state_id_for_light_form(light_form))


## 将公共 LightForm 数值映射为内容状态 ID；非法值 push_error 并回退 default，不产生第三态。
static func content_state_id_for_light_form(light_form: int) -> StringName:
	match light_form:
		LightForm.RAY:
			return STATE_RAY
		LightForm.PARTICLE:
			return STATE_PARTICLE
	push_error("EmitterConfigNode：非法 LightForm 值 %d，内容状态回退 default。" % [light_form])
	return STATE_DEFAULT


## 将当前活动方向单向同步为 EmitterVisual.rotation；缺失则跳过，不创建子节点（D3C-2.5）。
## 基础图片约定朝向 RIGHT，故 rotation = Vector2(活动方向).angle()；
## 不建立方向到角度的第二张映射表，不修改 local position 与 visual_profile。
func _refresh_visual_orientation() -> void:
	var visual := _get_emitter_visual()
	if visual == null:
		return
	visual.rotation = Vector2(get_active_direction_vector()).angle()


## 将当前活动方向、形态样式与预览可见性单向同步给 EmissionPreview；缺失则跳过。
func _refresh_preview() -> void:
	var preview := _get_emission_preview()
	if preview == null:
		return
	preview.set_preview_state(
		get_active_direction_vector(),
		default_light_form == LightForm.PARTICLE,
		editor_preview_visible
	)


# ===== Setter：仅在实际变化时发信号，非法值拒绝并保持旧值 =====
# 形态 / 方向 setter 顺序：1.校验 → 2.判断变化 → 3.写值 → 4.刷新 EmitterVisual 朝向与 Preview → 5.发信号。
# 非活动形态方向被修改时仍走刷新，但 get_active_direction_vector() 返回活动形态方向，故视觉朝向不变。

func _set_default_light_form(next: LightForm) -> void:
	if not _is_valid_light_form(next):
		push_error("EmitterConfigNode：非法 LightForm 值 %d，已拒绝并保持旧值。" % [next])
		return
	if default_light_form == next:
		return
	default_light_form = next
	_refresh_visual_state()
	_refresh_visual_orientation()
	_refresh_preview()
	configuration_changed.emit()


func _set_ray_default_direction(next: RayDirection) -> void:
	if not _is_valid_ray_direction(next):
		push_error("EmitterConfigNode：非法 RayDirection 值 %d，已拒绝并保持旧值。" % [next])
		return
	if ray_default_direction == next:
		return
	ray_default_direction = next
	_refresh_visual_orientation()
	_refresh_preview()
	configuration_changed.emit()


func _set_particle_default_direction(next: ParticleDirection) -> void:
	if not _is_valid_particle_direction(next):
		push_error("EmitterConfigNode：非法 ParticleDirection 值 %d，已拒绝并保持旧值。" % [next])
		return
	if particle_default_direction == next:
		return
	particle_default_direction = next
	_refresh_visual_orientation()
	_refresh_preview()
	configuration_changed.emit()


func _set_visual_profile(next: ObjectVisualProfile) -> void:
	if visual_profile == next:
		return
	visual_profile = next
	_refresh_visual()
	visual_profile_changed.emit(next)
	configuration_changed.emit()


func _set_editor_preview_visible(next: bool) -> void:
	if editor_preview_visible == next:
		return
	editor_preview_visible = next
	_refresh_preview()
	preview_visibility_changed.emit(next)
	configuration_changed.emit()


# ===== 公共 getter =====

func get_default_light_form() -> LightForm:
	return default_light_form


## 关卡是否允许 Q 切换光形态（M4-E4）；core_loop 启动读取一次注入 LevelRuntimeController，运行期不再监听本值变化。
func is_form_switch_allowed() -> bool:
	return allow_form_switch


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


## 执行阶段闸门（非快照阶段）：B3b-1 起 RAY 与 PARTICLE 均接正式运行时发射，二者皆返回 true。
## 返回当前 default_light_form 是否为已接 Runtime 的合法形态；未来引入第三种未接形态时返回 false，不抛假结果、不自动降级为另一形态。
func is_runtime_form_supported() -> bool:
	return default_light_form == LightForm.RAY or default_light_form == LightForm.PARTICLE
