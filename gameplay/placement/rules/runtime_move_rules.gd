class_name RuntimeMoveRules
extends RefCounted

## 运行期移动纯规则共享模块（批次 4B-D3-B）。
## 职责：集中持有 core_loop_prototype.gd 原有的七条运行期移动纯判断规则，作为正式玩法层与启动自检共用的唯一规则来源。
## 本模块只计算规则结果，不执行任何事务：不执行移动、不更新占用、不扣运行期移动次数、不回收机关、不读写真实玩法状态。
## 调用方（core_loop_prototype）仍负责占用原子更新、节点移动、queue_free、库存与状态机事务以及 runtime_moves_used 的扣除；
## 本模块仅在调用方提交前与预览时提供纯判断，扣次仍只发生在原占用更新成功之后。
## 依赖：通过 preload 引用 res://gameplay/interaction/runtime_interaction_types.gd 取得 RunState 与 DragSource 枚举，
## 不定义第二份 RunState 或 DragSource，不依赖 Diagnostics，不访问 Node、场景树、文件、时间或随机数。
## INVALID_CELL 由核心循环持有；本模块不定义、不复制，也不依赖其具体数值。core_loop_prototype 持有，不属于本模块；
## 本模块函数体不直接引用 INVALID_CELL，from_cell 仅作为普通 Vector2i 参与相等比较（INVENTORY 来源由调用方传入哨兵值）。
## 已知临时边界：运行期回收后重新放置不消耗直接移动次数的边界不在本模块修正，规则与原实现严格等价，不增加额外规则。

const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)


## 计算运行期剩余移动次数（纯函数，无副作用）。
## [br]职责：把上限与已用次数换算为可提交的剩余配额。
## [br]输入：move_limit 是运行期移动上限，moves_used 是已用次数。
## [br]返回：max(move_limit - moves_used, 0)；moves_used 超过 move_limit 时返回 0。
## [br]副作用：无；不读取或修改任何实例状态。
## [br]失败：本函数不会失败，任意 int 输入均返回钳制后的非负结果。
## [br]边界：仅提供剩余换算，不决定是否扣次；扣次由调用方在占用原子更新成功后执行。
static func compute_runtime_moves_remaining(move_limit: int, moves_used: int) -> int:
	return max(move_limit - moves_used, 0)


## 判断一次已放置机关拖拽松手是否应计入运行期移动次数（纯判断，无副作用）。
## [br]职责：判定“运行期状态 + 跨格”这一扣次前提。
## [br]输入：run_state 是提交时的运行状态，from_cell 是拖拽原始格，to_cell 是松手目标格。
## [br]返回：true 仅当处于运行期状态（PULSE_ACTIVE 或 MOVE_WINDOW）且 from_cell 与 to_cell 不同。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入 Vector2i。
## [br]失败：不会失败；非运行期状态、原格松手均返回 false。
## [br]边界：SETUP 跨格移动返回 false（不扣次），COMPLETED 返回 false，原格松手返回 false；
## 目标是否合法、占用原子更新是否成功等运行期事实由调用方在调用前确认，本函数只负责扣次前提。
static func should_count_runtime_move(
	run_state: _RuntimeInteractionTypes.RunState,
	from_cell: Vector2i,
	to_cell: Vector2i
) -> bool:
	if run_state != _RuntimeInteractionTypes.RunState.PULSE_ACTIVE and run_state != _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
		return false
	if to_cell == from_cell:
		return false
	return true


## 判断当前运行状态是否允许从世界拖起已放置机关（纯判断，无副作用）。
## [br]职责：判定拖起权限，与跨格移动提交权限分离。
## [br]输入：run_state 是当前运行状态。
## [br]返回：true 表示当前不是 COMPLETED：SETUP、PULSE_ACTIVE、MOVE_WINDOW 均允许拖起；COMPLETED 与未知值返回 false。
## [br]副作用：无；不读取或修改任何实例状态。
## [br]失败：不会失败；未知枚举值落入默认分支返回 false。
## [br]边界：remaining=0 禁止提交跨格移动（由 can_commit_placed_move 负责），但不禁止拖起，
## 因为拖起还承担回收和取消；从机关栏拿取与回收另由专用函数判断。
static func can_begin_placed_drag(run_state: _RuntimeInteractionTypes.RunState) -> bool:
	match run_state:
		_RuntimeInteractionTypes.RunState.SETUP, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return true
		_:
			return false


## 判断当前运行状态是否允许从机关栏拿取新机关（纯判断，无副作用）。
## [br]职责：判定库存拿取/首次放置权限。
## [br]输入：run_state 是当前运行状态。
## [br]返回：true 表示当前不是 COMPLETED：SETUP、PULSE_ACTIVE、MOVE_WINDOW 均允许拿取；COMPLETED 与未知值返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改库存。
## [br]失败：不会失败；未知枚举值落入默认分支返回 false。
## [br]边界：拿取/首次放置不消耗 runtime_moves_used（直接移动次数只限制已有机关从世界格 A 直接移动到世界格 B）；
## 运行期回收后重新放置不消耗直接移动次数属已知临时边界，本模块不修正。
static func can_take_from_inventory_for_state(run_state: _RuntimeInteractionTypes.RunState) -> bool:
	match run_state:
		_RuntimeInteractionTypes.RunState.SETUP, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return true
		_:
			return false


## 判断当前运行状态是否允许把已放置机关拖回机关栏回收（纯判断，无副作用）。
## [br]职责：判定回收权限。
## [br]输入：run_state 是当前运行状态。
## [br]返回：true 表示当前不是 COMPLETED：SETUP、PULSE_ACTIVE、MOVE_WINDOW 均允许回收；COMPLETED 与未知值返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改库存，不注销占用。
## [br]失败：不会失败；未知枚举值落入默认分支返回 false。
## [br]边界：回收不消耗 runtime_moves_used，只影响下一次发射；
## 运行期回收后重新放置不消耗直接移动次数属已知临时边界，本模块不修正。
static func can_recycle_placed_token_for_state(run_state: _RuntimeInteractionTypes.RunState) -> bool:
	match run_state:
		_RuntimeInteractionTypes.RunState.SETUP, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return true
		_:
			return false


## 判断当前运行状态是否允许正式提交一次已放置机关跨格移动（纯判断，无副作用）。
## [br]职责：移动提交前的第二次校验核心。
## [br]输入：run_state 是提交时的运行状态，moves_remaining 是提交时剩余运行期移动次数，from_cell/to_cell 是原始格与目标格。
## [br]返回：true 仅当 from_cell != to_cell，且状态为 SETUP，或处于 PULSE_ACTIVE/MOVE_WINDOW 且 moves_remaining > 0；COMPLETED 与未知值返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入 Vector2i。
## [br]失败：不会失败；原格松手永远返回 false。
## [br]边界：目标格合法性、占用原子更新等运行期事实由调用方在调用前确认；
## 本函数只判定状态与剩余次数是否允许跨格提交，不执行占用更新或扣次。
static func can_commit_placed_move(
	run_state: _RuntimeInteractionTypes.RunState,
	moves_remaining: int,
	from_cell: Vector2i,
	to_cell: Vector2i
) -> bool:
	if to_cell == from_cell:
		return false
	match run_state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return true
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, _RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return moves_remaining > 0
		_:
			return false


## 判断当前世界格松手预览是否应显示为合法（纯判断，无副作用）。
## [br]职责：把空间合法性与当前松手提交权限合并为单一预览合法性结果，供视觉反馈使用。
## [br]输入：drag_source 是拖拽来源，run_state 是当前运行状态，moves_remaining 是当前剩余运行期跨格移动次数，
## from_cell 是拖拽原始格（INVENTORY 来源由调用方传入 INVALID_CELL 哨兵），to_cell 是预览目标格，spatially_valid 是目标格空间合法性。
## [br]返回：true 表示该次世界格松手预览应显示合法颜色；返回 false 表示应显示非法颜色。
## [br]副作用：无；不读取或修改任何实例状态、不写 OccupancyRegistry、不改库存、不移动节点、不扣次数、不修改输入 Vector2i。
## [br]失败：不会失败；COMPLETED 与未知来源落入默认分支返回 false。
## [br]边界：本函数只用于视觉预览，不替代正式提交的二次校验。INVENTORY 来源只看拿取/首次放置权限与空间合法性，不读 runtime_move_limit。
## PLACED 来源：原格视为安全取消位置（空间合法即合法）；跨格需同时空间合法且 can_commit_placed_move 通过。
## INVALID_CELL 属于核心拖拽状态，不属于本模块；本函数仅把 from_cell 当作普通 Vector2i 参与相等比较。
static func is_world_drop_preview_valid(
	drag_source: _RuntimeInteractionTypes.DragSource,
	run_state: _RuntimeInteractionTypes.RunState,
	moves_remaining: int,
	from_cell: Vector2i,
	to_cell: Vector2i,
	spatially_valid: bool
) -> bool:
	if not spatially_valid:
		return false
	match drag_source:
		_RuntimeInteractionTypes.DragSource.INVENTORY:
			return can_take_from_inventory_for_state(run_state)
		_RuntimeInteractionTypes.DragSource.PLACED:
			if not can_begin_placed_drag(run_state):
				return false
			# 原格是安全取消位置，不是跨格移动；空间合法即显示可接受颜色。
			if to_cell == from_cell:
				return true
			return can_commit_placed_move(run_state, moves_remaining, from_cell, to_cell)
		_:
			return false
