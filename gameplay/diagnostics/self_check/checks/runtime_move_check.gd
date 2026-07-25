class_name RuntimeMoveCheck
extends RefCounted

## 运行期移动规则启动期自检模块（Diagnostics 批次 4B-D4）。
##
## 职责：
## 把原核心闭环原型中的 _run_runtime_move_self_check() 测试案例抽离为独立、
## 无副作用、不访问场景树的纯函数式自检；覆盖 RuntimeMoveRules 的七条公开纯规则：
## 剩余换算、扣次判断、拖起权限、库存拿取权限、回收权限、跨格提交权限与世界格松手预览合法性。
## 本模块只验证正式规则接口的事实输出，不复制任何移动规则实现，不执行任何玩法事务。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；由核心闭环原型以薄包装形式构造
## SelfCheckCallable 并交由 SelfCheckRunner 执行，保持原 Debug 硬断言失败语义。
##
## 主要依赖：
## RuntimeMoveRules（玩法层共享纯规则，单一来源）与 RuntimeInteractionTypes（RunState / DragSource
## 共享枚举契约），以及 SelfCheckResult 数据契约。不依赖场景树、节点、时间 API、文件系统或真实玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、拖拽/提交/回收/扣次事务编排。
## 本模块只如实报告规则接口的检查事实，不修改任何玩法状态，不决定实际移动是否合法，不复制规则实现。
##
## 关键边界：
## - run() 只读：只调用 RuntimeMoveRules 的公开静态纯判断函数，不创建机关、不读写 OccupancyRegistry、
##   不读取真实 runtime_moves_used、不访问 core_loop 私有字段、不访问场景树、不创建 Node。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能汇总全部检查失败。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 不使用文件系统、系统时间或随机数。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。
## - INVALID_CELL 归属：INVALID_CELL 由 core_loop_prototype 持有，本模块不 preload core_loop、
##   不读取其 INVALID_CELL、不复制 Vector2i(-999999, -999999)、不新建同义哨兵常量，
##   也不把 INVALID_CELL 移入 RuntimeMoveRules 或 RuntimeInteractionTypes。原自检在 INVENTORY
##   预览案例中传入 INVALID_CELL 只是被正式规则忽略的 from_cell 占位值；迁移后改用本模块私有的
##   普通非哨兵占位格 _IGNORED_INVENTORY_FROM_CELL，仅用于满足调用签名，不表达 INVALID_CELL 语义。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与核心闭环原型中的引用方式保持一致，避开 MCP run_project 不重建全局类型缓存的问题。
const _RuntimeMoveRules: GDScript = preload(
	"res://gameplay/placement/runtime_move_rules.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)

# INVENTORY 预览案例使用的普通占位 from_cell。
# 正式规则 is_world_drop_preview_valid 的 INVENTORY 分支只看拿取/首次放置权限与空间合法性，
# 按正式规则不读取 from_cell；此值只是测试调用签名所需的普通占位格，不表达 INVALID_CELL 语义，
# 也不得用于 PLACED 分支测试（PLACED 案例必须继续使用真实 from_cell/to_cell）。
const _IGNORED_INVENTORY_FROM_CELL: Vector2i = Vector2i.ZERO


## 执行运行期移动纯规则自检。
## [br]本函数无参数，只读、无业务修复、不执行任何玩法事务。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"runtime_move_rules"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]副作用：只调用 RuntimeMoveRules 与 RuntimeInteractionTypes 的公开静态纯函数；
## [br]不创建机关、不读写 OccupancyRegistry、不读取真实 runtime_moves_used、不访问 core_loop 私有字段、
## [br]不访问场景树、不创建 Node、不执行拖拽/提交/回收/扣次事务、不写文件、不写日志、不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能汇总全部失败；
## [br]不使用 assert、push_error 或 push_warning。
## [br]边界条件：测试格 cell_a=(10,10)、cell_b=(11,11) 刻意远离当前光路与默认布局；
## [br]INVENTORY 案例的 from_cell 使用普通占位格 _IGNORED_INVENTORY_FROM_CELL，不表达 INVALID_CELL 语义；
## [br]PLACED 案例继续使用真实 from_cell/to_cell；不删减原自检覆盖的任何测试案例，也不增加新规则。
static func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()

	var cell_a: Vector2i = Vector2i(10, 10)
	var cell_b: Vector2i = Vector2i(11, 11)

	# --- 剩余换算：compute_runtime_moves_remaining ---

	_expect_int(details, _RuntimeMoveRules.compute_runtime_moves_remaining(0, 0), 0, "运行期移动自检：limit=0 used=0 应 remaining=0")
	_expect_int(details, _RuntimeMoveRules.compute_runtime_moves_remaining(1, 0), 1, "运行期移动自检：limit=1 used=0 应 remaining=1")
	_expect_int(details, _RuntimeMoveRules.compute_runtime_moves_remaining(1, 1), 0, "运行期移动自检：limit=1 used=1 应 remaining=0")
	_expect_int(details, _RuntimeMoveRules.compute_runtime_moves_remaining(1, 2), 0, "运行期移动自检：used 超过 limit 时 remaining 仍为 0")
	_expect_int(details, _RuntimeMoveRules.compute_runtime_moves_remaining(2, 1), 1, "运行期移动自检：limit=2 used=1 应 remaining=1")

	# --- 扣次判断：should_count_runtime_move（状态、同格、跨格）---

	# SETUP 移动不扣次。
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.SETUP, cell_a, cell_b), false, "运行期移动自检：SETUP 跨格移动不应扣次")
	# PULSE_ACTIVE 与 MOVE_WINDOW 跨格成功移动应扣次。
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, cell_a, cell_b), true, "运行期移动自检：PULSE_ACTIVE 跨格移动应扣次")
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.MOVE_WINDOW, cell_a, cell_b), true, "运行期移动自检：MOVE_WINDOW 跨格移动应扣次")
	# COMPLETED 不允许移动，自然不扣次。
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.COMPLETED, cell_a, cell_b), false, "运行期移动自检：COMPLETED 不应扣次")
	# 原格松手不扣次（即使处于运行期）。
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, cell_a, cell_a), false, "运行期移动自检：PULSE_ACTIVE 原格松手不应扣次")
	_expect_bool(details, _RuntimeMoveRules.should_count_runtime_move(_RuntimeInteractionTypes.RunState.MOVE_WINDOW, cell_a, cell_a), false, "运行期移动自检：MOVE_WINDOW 原格松手不应扣次")

	# --- 拖起权限：can_begin_placed_drag（四状态）---
	# remaining=0 禁止提交跨格移动，但不禁止拖起，因为拖起还承担回收和取消。

	_expect_bool(details, _RuntimeMoveRules.can_begin_placed_drag(_RuntimeInteractionTypes.RunState.SETUP), true, "运行期移动自检：SETUP 应允许拖起已放置机关")
	_expect_bool(details, _RuntimeMoveRules.can_begin_placed_drag(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE), true, "运行期移动自检：PULSE_ACTIVE（remaining=1 或 0）应允许拖起")
	_expect_bool(details, _RuntimeMoveRules.can_begin_placed_drag(_RuntimeInteractionTypes.RunState.MOVE_WINDOW), true, "运行期移动自检：MOVE_WINDOW（remaining=1 或 0）应允许拖起")
	_expect_bool(details, _RuntimeMoveRules.can_begin_placed_drag(_RuntimeInteractionTypes.RunState.COMPLETED), false, "运行期移动自检：COMPLETED 不应允许拖起")

	# --- 库存拿取权限：can_take_from_inventory_for_state（四状态）---

	_expect_bool(details, _RuntimeMoveRules.can_take_from_inventory_for_state(_RuntimeInteractionTypes.RunState.SETUP), true, "运行期移动自检：SETUP 应允许从机关栏拿取")
	_expect_bool(details, _RuntimeMoveRules.can_take_from_inventory_for_state(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE), true, "运行期移动自检：PULSE_ACTIVE 应允许从机关栏拿取")
	_expect_bool(details, _RuntimeMoveRules.can_take_from_inventory_for_state(_RuntimeInteractionTypes.RunState.MOVE_WINDOW), true, "运行期移动自检：MOVE_WINDOW 应允许从机关栏拿取")
	_expect_bool(details, _RuntimeMoveRules.can_take_from_inventory_for_state(_RuntimeInteractionTypes.RunState.COMPLETED), false, "运行期移动自检：COMPLETED 禁止从机关栏拿取")

	# --- 回收权限：can_recycle_placed_token_for_state（四状态）---

	_expect_bool(details, _RuntimeMoveRules.can_recycle_placed_token_for_state(_RuntimeInteractionTypes.RunState.SETUP), true, "运行期移动自检：SETUP 应允许回收")
	_expect_bool(details, _RuntimeMoveRules.can_recycle_placed_token_for_state(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE), true, "运行期移动自检：PULSE_ACTIVE 应允许回收")
	_expect_bool(details, _RuntimeMoveRules.can_recycle_placed_token_for_state(_RuntimeInteractionTypes.RunState.MOVE_WINDOW), true, "运行期移动自检：MOVE_WINDOW 应允许回收")
	_expect_bool(details, _RuntimeMoveRules.can_recycle_placed_token_for_state(_RuntimeInteractionTypes.RunState.COMPLETED), false, "运行期移动自检：COMPLETED 禁止回收")

	# --- 提交权限：can_commit_placed_move（状态、余量、同格、跨格）---
	# 提交前第二次校验的纯判断；所有状态原格提交均为 false。

	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.SETUP, 0, cell_a, cell_b), true, "运行期移动自检：SETUP 跨格应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.SETUP, 0, cell_a, cell_a), false, "运行期移动自检：SETUP 原格不应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 1, cell_a, cell_b), true, "运行期移动自检：PULSE_ACTIVE 跨格且 remaining=1 应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, cell_a, cell_b), false, "运行期移动自检：PULSE_ACTIVE 跨格且 remaining=0 不应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 1, cell_a, cell_a), false, "运行期移动自检：PULSE_ACTIVE 原格不应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1, cell_a, cell_b), true, "运行期移动自检：MOVE_WINDOW 跨格且 remaining=1 应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, cell_a, cell_b), false, "运行期移动自检：MOVE_WINDOW 跨格且 remaining=0 不应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.COMPLETED, 1, cell_a, cell_b), false, "运行期移动自检：COMPLETED 跨格不应允许提交")
	_expect_bool(details, _RuntimeMoveRules.can_commit_placed_move(_RuntimeInteractionTypes.RunState.COMPLETED, 1, cell_a, cell_a), false, "运行期移动自检：COMPLETED 原格不应允许提交")

	# --- 世界格松手预览合法性：is_world_drop_preview_valid ---
	# 同时反映空间合法性与当前松手提交权限（纯判断，无副作用）。

	# INVENTORY 来源：只看拿取/首次放置权限与空间合法性，不读 runtime_move_limit；
	# from_cell 使用普通占位格 _IGNORED_INVENTORY_FROM_CELL，不表达 INVALID_CELL 语义。
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.INVENTORY, _RuntimeInteractionTypes.RunState.SETUP, 0, _IGNORED_INVENTORY_FROM_CELL, cell_b, true), true, "运行期移动自检：INVENTORY SETUP 空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.INVENTORY, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, _IGNORED_INVENTORY_FROM_CELL, cell_b, true), true, "运行期移动自检：INVENTORY PULSE_ACTIVE 空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.INVENTORY, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, _IGNORED_INVENTORY_FROM_CELL, cell_b, true), true, "运行期移动自检：INVENTORY MOVE_WINDOW 空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.INVENTORY, _RuntimeInteractionTypes.RunState.COMPLETED, 1, _IGNORED_INVENTORY_FROM_CELL, cell_b, true), false, "运行期移动自检：INVENTORY COMPLETED 应预览非法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.INVENTORY, _RuntimeInteractionTypes.RunState.SETUP, 0, _IGNORED_INVENTORY_FROM_CELL, cell_b, false), false, "运行期移动自检：INVENTORY 空间非法应预览非法")
	# PLACED 原格：安全取消位置，空间合法即合法（即使 remaining=0）。
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.SETUP, 0, cell_a, cell_a, true), true, "运行期移动自检：PLACED SETUP 原格应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, cell_a, cell_a, true), true, "运行期移动自检：PLACED PULSE_ACTIVE remaining=0 原格仍应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, cell_a, cell_a, true), true, "运行期移动自检：PLACED MOVE_WINDOW remaining=0 原格仍应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.COMPLETED, 1, cell_a, cell_a, true), false, "运行期移动自检：PLACED COMPLETED 原格应预览非法")
	# PLACED 跨格：需同时空间合法且 can_commit_placed_move 通过。
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.SETUP, 0, cell_a, cell_b, true), true, "运行期移动自检：PLACED SETUP remaining=0 跨格空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 1, cell_a, cell_b, true), true, "运行期移动自检：PLACED PULSE_ACTIVE remaining=1 跨格空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 0, cell_a, cell_b, true), false, "运行期移动自检：PLACED PULSE_ACTIVE remaining=0 跨格空间合法应预览非法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1, cell_a, cell_b, true), true, "运行期移动自检：PLACED MOVE_WINDOW remaining=1 跨格空间合法应预览合法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 0, cell_a, cell_b, true), false, "运行期移动自检：PLACED MOVE_WINDOW remaining=0 跨格空间合法应预览非法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.COMPLETED, 1, cell_a, cell_b, true), false, "运行期移动自检：PLACED COMPLETED 跨格应预览非法")
	_expect_bool(details, _RuntimeMoveRules.is_world_drop_preview_valid(_RuntimeInteractionTypes.DragSource.PLACED, _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, 1, cell_a, cell_b, false), false, "运行期移动自检：PLACED 空间非法应预览非法")

	var summary: String = "运行期移动规则自检：剩余换算、扣次判断、拖起/拿取/回收/提交权限与世界格松手预览合法性。"
	return SelfCheckResult.new(&"runtime_move_rules", details.is_empty(), summary, details, 0)


## 比较布尔实际值与期望值，不一致时向 details 追加稳定中文错误。
## [br]输入：details 为累计失败明细的 PackedStringArray；actual 为规则返回的布尔实际值；
## [br]expected 为该案例期望的布尔值；label 为该断言的中文描述。
## [br]返回：无；仅通过 details.append 产生副作用。
## [br]副作用：actual != expected 时向 details 追加一行中文错误，包含 label、expected 与 actual。
## [br]失败：本函数不会失败，任意布尔输入均安全比较。
## [br]边界：仅做相等比较与字符串追加，不包含玩法规则，不提前返回；
## [br]不使用 Callable、Variant、Dictionary 或无类型 Array；不修改 actual/expected。
static func _expect_bool(
		details: PackedStringArray,
		actual: bool,
		expected: bool,
		label: String
) -> void:
	if actual != expected:
		details.append("%s 期望 %s 实际 %s。" % [label, expected, actual])


## 比较整数实际值与期望值，不一致时向 details 追加稳定中文错误。
## [br]输入：details 为累计失败明细的 PackedStringArray；actual 为规则返回的整数实际值；
## [br]expected 为该案例期望的整数值；label 为该断言的中文描述。
## [br]返回：无；仅通过 details.append 产生副作用。
## [br]副作用：actual != expected 时向 details 追加一行中文错误，包含 label、expected 与 actual。
## [br]失败：本函数不会失败，任意整数输入均安全比较。
## [br]边界：仅做相等比较与字符串追加，不包含玩法规则，不提前返回；
## [br]不使用 Callable、Variant、Dictionary 或无类型 Array；不修改 actual/expected。
static func _expect_int(
		details: PackedStringArray,
		actual: int,
		expected: int,
		label: String
) -> void:
	if actual != expected:
		details.append("%s 期望 %d 实际 %d。" % [label, expected, actual])
