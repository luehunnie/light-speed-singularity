class_name RuntimeInteractionPermission
extends RefCounted

## Runtime Interaction Permission 统一入口（AF-03 / P0-4，Guide §10）：
## 普通机关与 UI 不自行读取 RunStateController 决定玩家权限；一切“此刻是否允许操作”经本模块。
## 输入：Definition 能力（声明动作集 / inventory_eligible）+ Interaction Profile + RunState + 移动预算 + 目标有效性；
## 输出：PermissionResult（allowed + machine-readable reason）。
## 典型拒绝原因（Guide §10 冻结命名）：COMPLETED_LOCKED / PROFILE_FORBIDS_ACTION / CONFIGURATION_LOCKED /
## MOVE_BUDGET_EXHAUSTED / INVALID_TARGET。状态门复用 RuntimeMoveRules 唯一规则源，不复制第二份状态策略。
## 本模块为纯函数集合：不读实例状态、不访问 Node / 场景树、不执行任何事务。


## 拒绝原因 machine-readable token。
const REASON_COMPLETED_LOCKED: StringName = &"COMPLETED_LOCKED"
const REASON_PROFILE_FORBIDS_ACTION: StringName = &"PROFILE_FORBIDS_ACTION"
const REASON_CONFIGURATION_LOCKED: StringName = &"CONFIGURATION_LOCKED"
const REASON_MOVE_BUDGET_EXHAUSTED: StringName = &"MOVE_BUDGET_EXHAUSTED"
const REASON_INVALID_TARGET: StringName = &"INVALID_TARGET"
const REASON_OK: StringName = &"OK"

## 允许原因 token（allowed=true 时 reason 固定为 OK）。
const _REASON_ALLOWED: StringName = &"OK"

const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _RuntimeMoveRules: GDScript = preload(
	"res://gameplay/placement/rules/runtime_move_rules.gd"
)
const _InteractionProfile: GDScript = preload(
	"res://gameplay/interaction/permission/interaction_profile.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)


## 统一判权结果：allowed + machine-readable reason（不携带节点、UI 或异常对象）。
class PermissionResult:
	var allowed: bool = false
	var reason: StringName = &""

	func _init(p_allowed: bool = false, p_reason: StringName = &"") -> void:
		allowed = p_allowed
		reason = p_reason

	func is_allowed() -> bool:
		return allowed


## 统一判权（Guide §10）。
## [br]action：InteractionProfile.ACTION_MOVE_INSTANCE / ACTION_RECOVER_INSTANCE 或 Typed 配置动作 token；
## [br]declared_actions：Definition.player_interaction_actions（能力面；配置动作须同时被声明与被 Profile 允许）；
## [br]inventory_eligible：Definition 库存资格（TAKE 判权使用；MOVE/RECOVER/配置动作不要求）；
## [br]run_state / moves_remaining：当前运行状态与剩余移动预算（调用方只读传入，本模块不读控制器）；
## [br]target_valid：目标实例是否有效（false → INVALID_TARGET）；
## [br]moves_from_cell / moves_to_cell：仅 MOVE_INSTANCE 预算判定使用（原格视为安全取消，同格不耗预算）。
## [br]判定顺序：目标 → Profile/能力 → COMPLETED → 配置锁 → 移动预算；全部通过才 allowed=true。
static func evaluate(
	action: StringName,
	profile: StringName,
	declared_actions: Array[StringName],
	inventory_eligible: bool,
	p_run_state: _RuntimeInteractionTypes.RunState,
	moves_remaining: int,
	target_valid: bool,
	moves_from_cell: Vector2i = Vector2i.ZERO,
	moves_to_cell: Vector2i = Vector2i.ZERO
) -> PermissionResult:
	var run_state: int = p_run_state
	# 1. 目标无效（实例不存在 / 类型未登记等）。
	if not target_valid:
		return PermissionResult.new(false, REASON_INVALID_TARGET)
	# 2. Profile 结构裁剪 + Definition 能力交集（Profile 只能缩权限，不能创造能力）。
	if not _action_allowed_by_profile_and_capability(
		action, profile, declared_actions, inventory_eligible
	):
		return PermissionResult.new(false, REASON_PROFILE_FORBIDS_ACTION)
	# 3. COMPLETED 冻结一切交互（只允许 R，R 不经本入口）。
	if run_state == _RuntimeInteractionTypes.RunState.COMPLETED:
		return PermissionResult.new(false, REASON_COMPLETED_LOCKED)
	# 4. 配置动作状态锁：Typed 配置修改仅 SETUP 允许（与既有核心右键配置门一致）。
	if _PlayerInteractionAction.is_valid_action(action) and run_state != _RuntimeInteractionTypes.RunState.SETUP:
		return PermissionResult.new(false, REASON_CONFIGURATION_LOCKED)
	# 5. 移动预算：跨格移动在计次状态须有剩余预算（复用 RuntimeMoveRules 唯一规则源）。
	if action == _InteractionProfile.ACTION_MOVE_INSTANCE and moves_from_cell != moves_to_cell:
		var state: _RuntimeInteractionTypes.RunState = p_run_state
		if not _RuntimeMoveRules.can_commit_placed_move(state, moves_remaining, moves_from_cell, moves_to_cell):
			return PermissionResult.new(false, REASON_MOVE_BUDGET_EXHAUSTED)
	return PermissionResult.new(true, _REASON_ALLOWED)


## Profile 裁剪 ∩ Definition 能力：基础设施动作只看 Profile；Typed 配置动作须 Profile 允许且被 Definition 声明；
## [br]库存拿取须 Profile 允许且类型声明 inventory_eligible。
static func _action_allowed_by_profile_and_capability(
	action: StringName,
	profile: StringName,
	declared_actions: Array[StringName],
	inventory_eligible: bool
) -> bool:
	if not _InteractionProfile.profile_allows(profile, action):
		return false
	if action == _InteractionProfile.ACTION_TAKE_FROM_INVENTORY:
		return inventory_eligible
	if _PlayerInteractionAction.is_valid_action(action):
		return declared_actions.has(action)
	return true
