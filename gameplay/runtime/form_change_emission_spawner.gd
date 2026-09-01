extends RefCounted

## 机关派生 emission 生成器（阶段C-01 光形式转换器执行适配层；C-08 扩展分光分支派生入口）。
## 职责：作为"机关正式结果 → 派生新 emission"的唯一执行适配点——
##   接收 Ray driver（传播停止载荷 FORM_CHANGE / 分支载荷 spawned_branches）与 Particle TERMINATE 链路（Tick driver 上报载荷）透传的转换事实，
##   经 LRC 注入的 dispatch Callable（→ LRC._dispatch_emission 事务）生成对应形态的新 emission；
##   RAY→PARTICLE 标准速度 / PARTICLE→RAY 默认白色均由既有发射路径（scheduler 冻结 STANDARD / Ray 颜色初始 WHITE）天然保证，
##   本类不复制任何转换规则；并持有 per-fire 转换链深度 guard（同一次 fire 内反复互转有上限，
##   杜绝"转换器+镜面"等回环布局无限分配 emission），链深度按 generation 自动归零。
##   C-08：新增分光分支派生入口 handle_ray_branches——分支按 LightForm.RAY 派生（继承色经 dispatch color 参数透传），
##   受树级总预算 MAX_BRANCH_BUDGET 约束（同一 fire 内全部分支树累计 ≤ 128，generation token 自动跨 epoch 归零、per-fire 随 reset_chain 重置）；
##   分支派生经既有 dispatch/driver 范式（不在 RayExecutionModule 单路径内建队列，冻结裁决）。
##   PARTICLE 路径同时承担 per-runtime 结算事务体（M4-E2 契约）：解绑 runtime → 先生成转换 emission（保持脉冲活动）→
##   源 emission 无剩余 runtime 时 finish（聚合结算仍归 LRC._finish_emission）。
## 严禁拥有（硬边界）：emission 身份分配（一律经 dispatch Callable 走 LRC 事务）、generation / RunState 真值（经 Callable 只读）、
##   机关判定（FORM_CHANGE / 分支载荷由机关经 LightInteractionResult 决定）、视觉、cooldown。
## 位置：gameplay/runtime 下；由 LevelRuntimeController 唯一持有并接线（driver on_form_change + on_ray_branches + Tick driver on_particle_terminated）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## 同一次 fire 内最大形态转换链深度（RAY→PARTICLE→RAY→…）；超限按阻挡处理（不再生成 emission）。
## ponytail: 固定 16 覆盖关卡合理回环；若未来出现长链关卡需求再改为配置注入。
const MAX_FORM_CHANGE_CHAIN: int = 16

## 同一次 fire 内分支树总预算（C-08 冻结裁决：全部派生分支 emission 累计 ≤ 128；超限按阻挡处理不再生成）。
## ponytail: 固定 128 与 MAX_PROPAGATION_STEPS 同量级，覆盖分光器多级级联合理上限；不随关卡配置。
const MAX_BRANCH_BUDGET: int = 128

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## ActiveEmissionRegistry 共享引用（unbind_particle_runtime / get_emission_runtime_count；分配归 LRC）。
var _registry: Variant
## 生成一个 emission 的 outward Callable（签名 (generation, light_form, cell, direction, color = WHITE) -> int，返回 emission_id 或 -1；→ LRC._dispatch_emission）。
var _dispatch: Callable
## 读 LRC._runtime_generation 真值的 Callable。
var _get_generation: Callable
## 读 RunStateController.is_current_pulse_active 的 Callable。
var _is_pulse_active: Callable
## 完成 LRC per-emission 聚合结算的 outward Callable（签名 (expected_generation, emission_id) -> void；→ LRC._finish_emission）。
var _finish_emission: Callable
## 链深度计数所属的 generation（token）；与当前 generation 不一致时计数自动归零。
var _chain_generation: int = -1
## 当前 generation 内已发生的转换次数（per-fire 由 LRC 在 request_fire 时 reset_chain）。
var _chain_depth: int = 0
## 分支预算计数所属的 generation（token；与链深度独立计数，互不挤占）。
var _branch_budget_generation: int = -1
## 当前 fire 内已派生的分支 emission 数（树级累计；per-fire 由 reset_chain 重置，跨 epoch 由 token 归零）。
var _branch_budget_used: int = 0


## 构造生成器；registry 为共享引用，dispatch / get_generation / is_pulse_active / finish_emission 为 LRC 注入的 Callable。
func _init(
		registry: Variant,
		dispatch: Callable,
		get_generation: Callable,
		is_pulse_active: Callable,
		finish_emission: Callable
) -> void:
	_registry = registry
	_dispatch = dispatch
	_get_generation = get_generation
	_is_pulse_active = is_pulse_active
	_finish_emission = finish_emission


## RAY 传播停止于转换器格后的生成入口（RayEmissionDriver on_form_change 回调；阶段C-01）。
## [br]输入：generation 为本 Ray 的 immutable 代快照；source_emission_id 为源 Ray emission（解绑无需——Ray emission 由
##   _schedule_completion 自行 finish，故仅作签名占位）；target_form / converter_cell / direction 为转换载荷。
## [br]副作用：载荷合法且守卫通过时经 dispatch 生成新 emission；链深度 +1。
## [br]边界：generation 过期 / 脉冲非活动 / 链深度达上限 / dispatch 失败时 no-op（源 Ray 照常 finish）。
func handle_ray_form_change(generation: int, _source_emission_id: int, target_form: int, converter_cell: Vector2i, direction: Vector2i) -> void:
	_spawn(generation, target_form, converter_cell, direction)


## RAY 分光分支派生入口（C-08；RayEmissionDriver on_ray_branches 回调）。
## [br]输入：generation 为源 Ray 的 immutable 代快照；source_emission_id 为源 Ray emission（仅签名占位，同 handle_ray_form_change）；
##   branches 为分支载荷数组（元素为 LightInteractionResult.BranchSpec：source_cell / direction / color 已由执行层盖章）。
## [br]副作用：逐分支按 RAY 形态经 dispatch 派生 emission（继承色经 dispatch color 参数透传，WHITE 默认不丢失）；
##   每个成功派生计 1 分支预算。
## [br]边界：generation 过期 / 脉冲非活动 / 分支预算达上限 / 单分支 dispatch 失败时该分支 no-op（其余分支继续）；
##   分支再触发机关再派生属自然递归（同 tick 内同步嵌套），预算为树级总闸保证终止。
func handle_ray_branches(generation: int, _source_emission_id: int, branches: Array) -> void:
	for branch: Variant in branches:
		_spawn_branch(generation, branch)


## 光粒 TERMINATE 链入口（M4-E2 per-runtime 结算事务体，阶段C-01 扩展 FORM_CHANGE 载荷）。
## [br]顺序冻结：①守卫（generation / PULSE_ACTIVE，语义与旧 LRC._on_particle_terminated 一致）→ ②解绑源 runtime →
##   ③载荷有效时先 spawn 转换 emission（先于结算，保证源 emission 聚合时脉冲仍活动）→ ④源 emission 无剩余 runtime 时 finish。
## [br]载荷恒携带：非转换终止 target == -1，跳过 ③（等价旧 LRC._on_particle_terminated 行为）。
func handle_particle_terminated(expected_generation: int, runtime_id: int, form_change_target: int, form_change_direction: Vector2i, converter_cell: Vector2i) -> void:
	if expected_generation != int(_get_generation.call()):
		return
	if not bool(_is_pulse_active.call()):
		return
	var emission_id: int = int(_registry.unbind_particle_runtime(runtime_id))
	if form_change_target >= 0:
		_spawn(expected_generation, form_change_target, converter_cell, form_change_direction)
	if emission_id > 0 and int(_registry.get_emission_runtime_count(emission_id)) == 0:
		_finish_emission.call(expected_generation, emission_id)


## 清空链深度与分支预算计数（per-fire 预算重置；由 LRC.request_fire 在 dispatch 前调用；
##   跨 epoch 由各自 generation token 自动归零兜底）。
func reset_chain() -> void:
	_chain_depth = 0
	_branch_budget_used = 0


## 守卫 + 经 LRC dispatch 事务生成新 emission（内部唯一生成点）。
## [br]守卫顺序：generation 真值匹配 → PULSE_ACTIVE → 链 generation 变更自动归零 → 链深度上限。
## [br]dispatch 返回 -1（rollback / 失败）时 no-op，链深度不计。
func _spawn(generation: int, target_form: int, cell: Vector2i, direction: Vector2i) -> void:
	if generation != int(_get_generation.call()):
		return
	if not bool(_is_pulse_active.call()):
		return
	if _chain_generation != generation:
		_chain_generation = generation
		_chain_depth = 0
	if _chain_depth >= MAX_FORM_CHANGE_CHAIN:
		push_warning("FormChangeEmissionSpawner: 转换链深度达上限 %d，本次转换按阻挡处理（不再生成 emission）。" % MAX_FORM_CHANGE_CHAIN)
		return
	var emission_id: int = int(_dispatch.call(generation, target_form, cell, direction))
	if emission_id < 0:
		return
	_chain_depth += 1


## 守卫 + 经 LRC dispatch 事务派生单个 RAY 分支 emission（C-08 内部唯一分支生成点）。
## [br]守卫顺序：generation 真值匹配 → PULSE_ACTIVE → 预算 generation 变更自动归零 → 树级预算上限。
## [br]形态恒 RAY（分支仅 RAY 合法，Contract validate 强制）；继承色经 dispatch color 参数透传。
## [br]dispatch 返回 -1 时该分支 no-op，预算不计；超预算 push_warning 并按阻挡处理（不再生成）。
func _spawn_branch(generation: int, branch: Variant) -> void:
	if generation != int(_get_generation.call()):
		return
	if not bool(_is_pulse_active.call()):
		return
	if _branch_budget_generation != generation:
		_branch_budget_generation = generation
		_branch_budget_used = 0
	if _branch_budget_used >= MAX_BRANCH_BUDGET:
		push_warning("FormChangeEmissionSpawner: 分支树总预算达上限 %d，本分支按阻挡处理（不再生成 emission）。" % MAX_BRANCH_BUDGET)
		return
	var emission_id: int = int(_dispatch.call(
		generation, _LightEmissionTypes.LightForm.RAY, branch.source_cell, branch.direction, branch.color))
	if emission_id < 0:
		return
	_branch_budget_used += 1
