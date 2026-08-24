class_name InteractionProfile
extends RefCounted

## Interaction Profile 域（AF-03 / P0-4，Guide §9）：作者对实例“允许玩家使用哪些已有能力”的裁剪层。
## Profile 只能缩权限，不能创造 Definition 没有的能力（Guide 9.2）：有效动作 = Definition 能力 ∩ Profile 允许。
## Profile ≠ Runtime State（Guide 9.3）：Profile 不随 SETUP / PULSE_ACTIVE / MOVE_WINDOW 自动切换；
## “此刻是否允许操作”由 runtime_interaction_permission.gd 统一判断，本模块只回答结构性裁剪。
## 同一 Definition / Scene 不因实例角色（Fixed / Movable / Recoverable / Inventory Spawn / Preplaced）复制。


## 固定机关：作者禁止一切玩家布局操作（预置固定物常用）。
const FIXED: StringName = &"fixed"
## 可移动预置机关：允许移动，不允许回收入库。
const MOVABLE_PREPLACED: StringName = &"movable_preplaced"
## 玩家工具（Inventory Spawn 默认 Profile，Guide 15.3）：允许移动 / 回收与声明的 Typed 配置动作。
const PLAYER_TOOL: StringName = &"player_tool"

## 全部正式 Profile token。
const ALL_PROFILE_TOKENS: Array[StringName] = [
	FIXED,
	MOVABLE_PREPLACED,
	PLAYER_TOOL,
]

## 基础设施动作 token（与 PlayerInteractionAction 域分工一致的布局/库存动作；属 Placement / Inventory Infrastructure）。
const ACTION_MOVE_INSTANCE: StringName = &"move_instance"
const ACTION_RECOVER_INSTANCE: StringName = &"recover_instance"
const ACTION_TAKE_FROM_INVENTORY: StringName = &"take_from_inventory"

const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)


## Profile token 是否属正式域（纯判断）。
static func is_valid_profile(profile: StringName) -> bool:
	return ALL_PROFILE_TOKENS.has(profile)


## 判断 Profile 结构上是否允许某动作（纯判断，不看 RunState / 预算 / 目标）。
## [br]action 取值：ACTION_MOVE_INSTANCE / ACTION_RECOVER_INSTANCE / ACTION_TAKE_FROM_INVENTORY
## [br]或 PlayerInteractionAction 域动作 token。
## [br]MOVE：FIXED 拒绝，MOVABLE_PREPLACED / PLAYER_TOOL 允许；RECOVER / TAKE：仅 PLAYER_TOOL 允许；
## [br]Typed 配置动作（CYCLE_*）：PLAYER_TOOL 且动作须属正式动作域（能力面由调用方以 Definition 声明交集约束，
## [br]本函数只裁剪 Profile 层，保证“只能缩权限”语义的单点实现）。
static func profile_allows(profile: StringName, action: StringName) -> bool:
	match profile:
		PLAYER_TOOL:
			if action == ACTION_MOVE_INSTANCE or action == ACTION_RECOVER_INSTANCE or action == ACTION_TAKE_FROM_INVENTORY:
				return true
			return _PlayerInteractionAction.is_valid_action(action)
		MOVABLE_PREPLACED:
			return action == ACTION_MOVE_INSTANCE
		FIXED:
			return false
		_:
			return false
