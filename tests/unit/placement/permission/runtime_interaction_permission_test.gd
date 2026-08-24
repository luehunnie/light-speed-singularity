extends SceneTree

## AF-03 Interaction Profile / Runtime Interaction Permission 定向合同测试（Guide §9/§10）。
## 覆盖：Profile token 域与结构裁剪矩阵（FIXED/MOVABLE_PREPLACED/PLAYER_TOOL × 动作）、
## 统一判权五种 machine-readable 拒绝原因（INVALID_TARGET / PROFILE_FORBIDS_ACTION / COMPLETED_LOCKED /
## CONFIGURATION_LOCKED / MOVE_BUDGET_EXHAUSTED）、允许路径（SETUP 配置动作、跨状态 MOVE/RECOVER、
## 库存拿取资格门）、移动预算判定与 RuntimeMoveRules 唯一规则源等价。
## headless extends SceneTree；全部通过 quit(0)，任一失败 quit(1)。


const _InteractionProfile: GDScript = preload(
	"res://gameplay/interaction/permission/interaction_profile.gd"
)
const _RuntimeInteractionPermission: GDScript = preload(
	"res://gameplay/interaction/permission/runtime_interaction_permission.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _RuntimeMoveRules: GDScript = preload(
	"res://gameplay/placement/rules/runtime_move_rules.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_profile_token_domain()
	_test_02_profile_allows_matrix()
	_test_03_permission_reject_reasons()
	_test_04_permission_allowed_paths()
	_test_05_move_budget_rule_equivalence()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. Profile token 域：三 token 合法，未知 token 非法。
func _test_01_profile_token_domain() -> void:
	const NAME: String = "01_Profile域"
	_check(NAME, _InteractionProfile.is_valid_profile(_InteractionProfile.FIXED), "FIXED 应合法。")
	_check(NAME, _InteractionProfile.is_valid_profile(_InteractionProfile.MOVABLE_PREPLACED), "MOVABLE_PREPLACED 应合法。")
	_check(NAME, _InteractionProfile.is_valid_profile(_InteractionProfile.PLAYER_TOOL), "PLAYER_TOOL 应合法。")
	_check(NAME, not _InteractionProfile.is_valid_profile(&"admin"), "未知 token 应非法。")


## 2. 结构裁剪矩阵：FIXED 全拒；MOVABLE_PREPLACED 仅 MOVE；PLAYER_TOOL 允许 MOVE/RECOVER/TAKE 与合法 Typed 动作。
func _test_02_profile_allows_matrix() -> void:
	const NAME: String = "02_裁剪矩阵"
	var move: StringName = _InteractionProfile.ACTION_MOVE_INSTANCE
	var recover: StringName = _InteractionProfile.ACTION_RECOVER_INSTANCE
	var take: StringName = _InteractionProfile.ACTION_TAKE_FROM_INVENTORY
	var cycle: StringName = _PlayerInteractionAction.CYCLE_INTERNAL_STATE
	_check(NAME, not _InteractionProfile.profile_allows(_InteractionProfile.FIXED, move), "FIXED 拒绝 MOVE。")
	_check(NAME, not _InteractionProfile.profile_allows(_InteractionProfile.FIXED, recover), "FIXED 拒绝 RECOVER。")
	_check(NAME, _InteractionProfile.profile_allows(_InteractionProfile.MOVABLE_PREPLACED, move), "MOVABLE_PREPLACED 允许 MOVE。")
	_check(NAME, not _InteractionProfile.profile_allows(_InteractionProfile.MOVABLE_PREPLACED, recover), "MOVABLE_PREPLACED 拒绝 RECOVER。")
	_check(NAME, not _InteractionProfile.profile_allows(_InteractionProfile.MOVABLE_PREPLACED, cycle), "MOVABLE_PREPLACED 拒绝配置动作。")
	_check(NAME, _InteractionProfile.profile_allows(_InteractionProfile.PLAYER_TOOL, move), "PLAYER_TOOL 允许 MOVE。")
	_check(NAME, _InteractionProfile.profile_allows(_InteractionProfile.PLAYER_TOOL, recover), "PLAYER_TOOL 允许 RECOVER。")
	_check(NAME, _InteractionProfile.profile_allows(_InteractionProfile.PLAYER_TOOL, take), "PLAYER_TOOL 允许 TAKE。")
	_check(NAME, _InteractionProfile.profile_allows(_InteractionProfile.PLAYER_TOOL, cycle), "PLAYER_TOOL 允许合法 Typed 动作。")
	_check(NAME, not _InteractionProfile.profile_allows(_InteractionProfile.PLAYER_TOOL, &"explode"), "PLAYER_TOOL 拒绝未知动作 token。")
	_check(NAME, not _InteractionProfile.profile_allows(&"unknown", move), "未知 Profile 一律拒绝。")


## 3. 统一判权拒绝原因：五种 machine-readable token 各自命中且不串扰。
func _test_03_permission_reject_reasons() -> void:
	const NAME: String = "03_拒绝原因"
	var cycle: StringName = _PlayerInteractionAction.CYCLE_DIRECTION
	var declared: Array[StringName] = [_PlayerInteractionAction.CYCLE_DIRECTION]
	# INVALID_TARGET：目标不存在优先于一切。
	var invalid_target := _evaluate(cycle, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.SETUP, 0, false)
	_check(NAME, invalid_target.reason == _RuntimeInteractionPermission.REASON_INVALID_TARGET, "目标无效应回 INVALID_TARGET。")
	# PROFILE_FORBIDS_ACTION：FIXED 拒 MOVE / 未声明能力拒配置动作 / 无库存资格拒拿取。
	var fixed_move := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.FIXED, declared, true, _RuntimeInteractionTypes.RunState.SETUP, 5, true, Vector2i(0, 0), Vector2i(1, 1))
	_check(NAME, fixed_move.reason == _RuntimeInteractionPermission.REASON_PROFILE_FORBIDS_ACTION, "FIXED 拒 MOVE 应回 PROFILE_FORBIDS_ACTION。")
	var undeclared := _evaluate(_PlayerInteractionAction.CYCLE_INTERNAL_STATE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.SETUP, 0, true)
	_check(NAME, undeclared.reason == _RuntimeInteractionPermission.REASON_PROFILE_FORBIDS_ACTION, "未声明动作应回 PROFILE_FORBIDS_ACTION。")
	var take_ineligible := _evaluate(_InteractionProfile.ACTION_TAKE_FROM_INVENTORY, _InteractionProfile.PLAYER_TOOL, declared, false, _RuntimeInteractionTypes.RunState.SETUP, 0, true)
	_check(NAME, take_ineligible.reason == _RuntimeInteractionPermission.REASON_PROFILE_FORBIDS_ACTION, "无库存资格拿取应回 PROFILE_FORBIDS_ACTION。")
	# COMPLETED_LOCKED：通关冻结一切（非 COMPLETED 拒绝原因优先让位）。
	var completed := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.COMPLETED, 5, true, Vector2i(0, 0), Vector2i(1, 1))
	_check(NAME, completed.reason == _RuntimeInteractionPermission.REASON_COMPLETED_LOCKED, "COMPLETED 应回 COMPLETED_LOCKED。")
	# CONFIGURATION_LOCKED：配置动作仅 SETUP。
	var locked := _evaluate(cycle, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, true)
	_check(NAME, locked.reason == _RuntimeInteractionPermission.REASON_CONFIGURATION_LOCKED, "PULSE_ACTIVE 配置动作应回 CONFIGURATION_LOCKED。")
	# MOVE_BUDGET_EXHAUSTED：MOVE_WINDOW 跨格无预算。
	var exhausted := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, true, Vector2i(0, 0), Vector2i(1, 1))
	_check(NAME, exhausted.reason == _RuntimeInteractionPermission.REASON_MOVE_BUDGET_EXHAUSTED, "无预算跨格移动应回 MOVE_BUDGET_EXHAUSTED。")


## 4. 允许路径：SETUP 配置动作、SETUP 跨格移动（不计预算）、MOVE_WINDOW 有预算移动、跨状态回收、库存拿取。
func _test_04_permission_allowed_paths() -> void:
	const NAME: String = "04_允许路径"
	var declared: Array[StringName] = [_PlayerInteractionAction.CYCLE_DIRECTION]
	var setup_cycle := _evaluate(_PlayerInteractionAction.CYCLE_DIRECTION, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.SETUP, 0, true)
	_check(NAME, setup_cycle.is_allowed() and setup_cycle.reason == _RuntimeInteractionPermission.REASON_OK, "SETUP 配置动作应允许。")
	var setup_move := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.SETUP, 0, true, Vector2i(0, 0), Vector2i(1, 1))
	_check(NAME, setup_move.is_allowed(), "SETUP 跨格移动不读预算应允许。")
	var window_move := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1, true, Vector2i(0, 0), Vector2i(1, 1))
	_check(NAME, window_move.is_allowed(), "MOVE_WINDOW 有预算跨格应允许。")
	var same_cell := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, true, Vector2i(2, 2), Vector2i(2, 2))
	_check(NAME, same_cell.is_allowed(), "原格提交不耗预算应允许（安全取消语义）。")
	var recover := _evaluate(_InteractionProfile.ACTION_RECOVER_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, true)
	_check(NAME, recover.is_allowed(), "运行期回收应允许。")
	var take := _evaluate(_InteractionProfile.ACTION_TAKE_FROM_INVENTORY, _InteractionProfile.PLAYER_TOOL, declared, true, _RuntimeInteractionTypes.RunState.READY_TO_FIRE, 0, true)
	_check(NAME, take.is_allowed(), "READY_TO_FIRE 库存拿取应允许。")


## 5. 移动预算判定与 RuntimeMoveRules.can_commit_placed_move 完全等价（唯一规则源复用证明）。
func _test_05_move_budget_rule_equivalence() -> void:
	const NAME: String = "05_预算规则等价"
	var declared: Array[StringName] = []
	var states: Array[int] = [
		_RuntimeInteractionTypes.RunState.SETUP,
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE,
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE,
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW,
	]
	for state: int in states:
		for budget: int in [0, 1]:
			var from_cell := Vector2i(0, 0)
			var to_cell := Vector2i(3, 3)
			var permission := _evaluate(_InteractionProfile.ACTION_MOVE_INSTANCE, _InteractionProfile.PLAYER_TOOL, declared, true, state, budget, true, from_cell, to_cell)
			var rules_allowed: bool = _RuntimeMoveRules.can_commit_placed_move(state, budget, from_cell, to_cell)
			_check(NAME, permission.is_allowed() == rules_allowed, "状态 %d 预算 %d 判权应与 RuntimeMoveRules 等价。" % [state, budget])


## 判权便捷封装（默认无位移；MOVE 用例显式传格）。
func _evaluate(
	action: StringName,
	profile: StringName,
	declared: Array[StringName],
	inventory_eligible: bool,
	run_state: int,
	moves_remaining: int,
	target_valid: bool,
	from_cell: Vector2i = Vector2i.ZERO,
	to_cell: Vector2i = Vector2i.ZERO
) -> _RuntimeInteractionPermission.PermissionResult:
	return _RuntimeInteractionPermission.evaluate(
		action, profile, declared, inventory_eligible, run_state, moves_remaining, target_valid, from_cell, to_cell
	)


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("runtime_interaction_permission_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
