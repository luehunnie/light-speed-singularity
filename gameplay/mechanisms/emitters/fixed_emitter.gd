class_name FixedEmitter
extends RefCounted

## 固定发射器（Day 2 D2-E / D7-4 B3a / M4-E4 Q 形态切换）：固定发射器运行期格子、方向与光形态的唯一所有者。
## 由 core_loop_prototype 在 _ready 中用 Inspector 初始配置（emitter_cell/emitter_direction）构造一次；此后运行期格子和方向只由此实例提供。
## 职责：持有格子、方向与形态、判断方向合法性、为 LevelRuntimeController 提供只读 Runtime 快照（light_form/emitter_cell/active_direction）；
##   RAY 形态可构建 Ray-only FireRequest；PARTICLE 形态只提供快照，不创建 ParticleRuntimeState、不调用调度器、不创建 Timer、不修改 RunState；
##   M4-E4：_form 可经 toggle_light_form 翻转（Q 正式入口，权限门在控制器）、经 reset_to_initial_form 恢复关卡初始形态（R）。
## 固定语义：格子不可移动，不提供 set_cell；不实现 WASD/方向 UI/READY_TO_FIRE/开始运行按钮。
## 非法方向语义：保留非法初始方向不自动修正，build_fire_request 返回 null，由核心按旧行为拒绝发射（先于 _prepare_for_new_pulse 与 begin_pulse）。
## 依赖：FireRequest（Ray-only）+ LightEmissionTypes（公共光形态 / 八方向合法性）；不依赖核心、场景树、RunState、世界查询、Diagnostics 或 ParticleRuntimeState。
## 方向合法性：唯一公共边界为 LightEmissionTypes.is_valid_direction，本类 is_valid_direction 仅作委派，不复制第二份八方向合法集合。


const _FireRequest: GDScript = preload("res://gameplay/light/fire_request.gd")
## 公共光形态 / 八方向合法性唯一来源（preload 避开全局 class 缓存问题）。
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 发射器所在格（运行期不可变）。
var _cell: Vector2i
## 当前发射方向；保留非法值不自动修正，由 build_fire_request 拒绝发射。RAY/PARTICLE 共用此单字段，切换形态不产生第二份陈旧方向。
var _direction: Vector2i
## 当前光形态（LightEmissionTypes.LightForm 数值，默认 RAY）；M4-E4 起可经 toggle_light_form 由 Q 切换（权限门在 LevelRuntimeController）。
var _form: int = _LightEmissionTypes.LightForm.RAY
## 关卡配置的初始光形态（构造时快照）；R 重置时经 reset_to_initial_form 恢复（主发射器 v0.3 §9.3“恢复该关卡配置的初始光形态”）。
var _initial_form: int = _LightEmissionTypes.LightForm.RAY


## 构造固定发射器；保留传入的方向原值，非法方向不自动修正，由 build_fire_request 在发射时拒绝。
## initial_form 取值见 LightEmissionTypes.LightForm，默认 RAY，保证既有两参调用（core_loop_prototype）行为不变；
## initial_form 同时作为 R 重置的恢复目标快照。
func _init(initial_cell: Vector2i, initial_direction: Vector2i, initial_form: int = _LightEmissionTypes.LightForm.RAY) -> void:
	_cell = initial_cell
	_direction = initial_direction
	_form = initial_form
	_initial_form = initial_form


## 发射器所在格（Runtime 快照 emitter_cell）。
func get_cell() -> Vector2i:
	return _cell


## 当前光形态（Runtime 快照 light_form）；取值见 LightEmissionTypes.LightForm，RAY=0 / PARTICLE=1。
func get_light_form() -> int:
	return _form


## 当前发射方向（Runtime 快照 active_direction；可能为非法值，调用方据 build_fire_request 结果决定是否发射）。
func get_direction() -> Vector2i:
	return _direction


## 尝试设置发射方向；仅合法方向（非零且分量绝对值不超过 1）成功并写入，非法方向返回 false 且旧方向不变。
## 本批无现有调用方，仅提供合法数据边界，不接入新输入。
func try_set_direction(direction: Vector2i) -> bool:
	if not is_valid_direction(direction):
		return false
	_direction = direction
	return true


## 切换一次光形态（M4-E4 Q 正式入口的纯数据操作）：RAY↔PARTICLE 二态翻转，返回切换后的 LightForm 数值。
## [br]本方法不做任何权限判定（关卡 allow_form_switch 与非 COMPLETED 状态门由 LevelRuntimeController.request_switch_light_form 负责），
## [br]不发射、不消费/重置 cooldown、不改变场上已存在 emission——只改写本实例 _form，下一次发射快照据此读取新形态。
## [br]防御语义：_form 被毒化为未知值时翻转到 RAY（非 RAY 一律回到 RAY），不产生第三态。
func toggle_light_form() -> int:
	_form = _LightEmissionTypes.LightForm.RAY if _form != _LightEmissionTypes.LightForm.RAY else _LightEmissionTypes.LightForm.PARTICLE
	return _form


## 恢复关卡配置的初始光形态（R 完整重置；主发射器 v0.3 §9.3/§11.11：修改过形态后按 R 恢复该关卡初始形态）。
## 仅重置 _form 到构造时快照 _initial_form；不清场上 emission（由 LevelRuntimeController.reset_runtime 的 generation 推进统一失效）。
func reset_to_initial_form() -> void:
	_form = _initial_form


## 构建一次普通光线发射请求；FireRequest 为 Ray-only，PARTICLE 形态或方向非法时返回 null，
## 核心据此按旧行为退出（先于 _prepare_for_new_pulse 与 begin_pulse）。不改 Ray max_steps 合同。
func build_fire_request(max_steps: int) -> _FireRequest:
	if _form != _LightEmissionTypes.LightForm.RAY:
		return null
	if not is_valid_direction(_direction):
		return null
	return _FireRequest.new(_cell, _direction, max_steps)


## 判断传播方向是否合法：委派公共边界 LightEmissionTypes.is_valid_direction（八个单位方向合法，ZERO 与超格方向非法）。
## 本类不再维护第二份八方向合法集合；核心与运行期移动自检共用此入口。
static func is_valid_direction(direction: Vector2i) -> bool:
	return _LightEmissionTypes.is_valid_direction(direction)
