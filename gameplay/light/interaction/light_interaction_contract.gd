class_name LightInteractionContract
extends RefCounted

## Ray / Particle 正式交互分发合同（冻结 Guide §21 / §23）：Typed Context → 机关一次计算 → Runtime 校验 Result。
## 正式入口（§21）：interact_ray(ray_context) / interact_particle(particle_context)，两形态对称；
##   禁止以具体机关类名（如 SingleCellMirror）作发现逻辑，也不把 has_method() 本身当正式 API 契约——
##   本类的 has_method 探测仅是对非契约节点（水晶 / 发射器 / 未知对象 / 已释放）的防御性护栏，契约本体是
##   “get_light_interaction_forms 声明 + interact_* 入口 + LightInteractionResult”三件套。
## 未声明形态 = 对该形态透明（§21 冻结语义）：Runtime 不调用对应入口，保持传播状态继续。
## Commit 时序（§23）：本类承担“构造后分发 → 机关一次计算 → Runtime 校验”三步；效果一次提交与传播决策执行
##   由调用方（既有 Adapter / Executor 层）按原时序完成；同一次交互不因中间副作用重新求值（机关单次调用）。
## 校验失败安全降级：Result 为 null / 非正式类型 / validate 不通过时 push_error 并返回透明 CONTINUE（不推测光学行为）。
## 机关不得直接访问 Scheduler（§AF-02 Non-goals）：本模块不向机关透出任何 Runtime 句柄，Context 即全部输入。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _RayInteractionContext: GDScript = preload(
	"res://gameplay/light/interaction/ray_interaction_context.gd"
)
const _ParticleInteractionContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)

## 机关侧形态声明入口名（正式契约面之一；返回 Array[StringName]，token 为 &"RAY" / &"PARTICLE"）。
const FORM_DECLARATION_METHOD: String = "get_light_interaction_forms"


## 判定机关是否声明支持指定光形态（§21“Definition 声明实际支持的 Light Forms”的运行期镜像）。
## [br]输入：mechanism 为任意 Variant（null / 已释放 / 非 Object / 非契约节点一律 false）；form 为 LightForm 值。
## [br]返回：true = 机关实现正式契约面且声明了该形态；false = 对该形态透明。
## [br]边界：本函数只读声明，不调用 interact_*，不产生副作用；声明集合非数组 / 出错按未声明处理。
static func supports_form(mechanism: Variant, form: int) -> bool:
	if not _is_contract_node(mechanism):
		return false
	var declared: Variant = mechanism.call(FORM_DECLARATION_METHOD)
	if declared is not Array:
		return false
	var token: StringName = _form_token(form)
	if token == &"":
		return false
	return token in declared


## RAY 正式分发（§21 interact_ray）：未声明 / 校验失败返回透明 CONTINUE。
## [br]输入：mechanism 为机关节点 Variant；context 须为 RayInteractionContext（非法返回透明 CONTINUE）。
## [br]返回：经校验的 LightInteractionResult；机关一次计算，不重入、不重求值。
static func dispatch_ray(mechanism: Variant, context: Variant) -> _LightInteractionResult:
	if not _is_contract_node(mechanism):
		return _LightInteractionResult.continue_result()
	if context is not _RayInteractionContext:
		push_error("LightInteractionContract：dispatch_ray 收到非 RayInteractionContext，按透明降级。")
		return _LightInteractionResult.continue_result()
	if not supports_form(mechanism, _LightEmissionTypes.LightForm.RAY):
		return _LightInteractionResult.continue_result()
	var result: Variant = mechanism.interact_ray(context)
	return _validated(result, _LightEmissionTypes.LightForm.RAY, mechanism)


## PARTICLE 正式分发（§21 interact_particle）：未声明 / 校验失败返回透明 CONTINUE。
## [br]输入：mechanism 为机关节点 Variant；context 须为 ParticleInteractionContext（非法返回透明 CONTINUE）。
## [br]返回：经校验的 LightInteractionResult；机关一次计算，不重入、不重求值。
static func dispatch_particle(mechanism: Variant, context: Variant) -> _LightInteractionResult:
	if not _is_contract_node(mechanism):
		return _LightInteractionResult.continue_result()
	if context is not _ParticleInteractionContext:
		push_error("LightInteractionContract：dispatch_particle 收到非 ParticleInteractionContext，按透明降级。")
		return _LightInteractionResult.continue_result()
	if not supports_form(mechanism, _LightEmissionTypes.LightForm.PARTICLE):
		return _LightInteractionResult.continue_result()
	var result: Variant = mechanism.interact_particle(context)
	return _validated(result, _LightEmissionTypes.LightForm.PARTICLE, mechanism)


## 防御性节点判定：有效 Object 且实现正式形态声明入口（非契约发现逻辑，仅护栏）。
static func _is_contract_node(mechanism: Variant) -> bool:
	if mechanism == null or not (mechanism is Object) or not is_instance_valid(mechanism):
		return false
	return mechanism.has_method(FORM_DECLARATION_METHOD)


## 校验机关返回的 Result：null / 非正式类型 / validate 不通过 → push_error + 透明 CONTINUE（§23 Runtime 校验）。
static func _validated(result: Variant, light_form: int, mechanism: Variant) -> _LightInteractionResult:
	if result == null or result is not _LightInteractionResult:
		push_error("LightInteractionContract：机关 %s 返回非正式 LightInteractionResult，按透明降级。" % [mechanism])
		return _LightInteractionResult.continue_result()
	var problems: PackedStringArray = result.validate(light_form)
	if not problems.is_empty():
		push_error("LightInteractionContract：机关 %s 返回不合法 Result——%s；按透明降级。" % [mechanism, "；".join(problems)])
		return _LightInteractionResult.continue_result()
	return result


## LightForm 值 → 声明 token（仅 RAY / PARTICLE 两个冻结形态）。
static func _form_token(form: int) -> StringName:
	if form == _LightEmissionTypes.LightForm.RAY:
		return &"RAY"
	if form == _LightEmissionTypes.LightForm.PARTICLE:
		return &"PARTICLE"
	return &""
