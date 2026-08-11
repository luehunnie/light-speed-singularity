extends SceneTree

## RuntimeMoveRules READY_TO_FIRE 专项测试（D7-2 GPT-5.6sol FAIL 修复批次）。
##
## 职责：
## 只通过 RuntimeMoveRules 的静态纯判断接口，锁定 READY_TO_FIRE（数值 4）状态下的运行期移动规则行为，
## 覆盖八项 READY 专项合同：拖起/库存拿取/回收/跨格提交（remaining>0 允许、==0 拒绝）/原格安全取消不计次/取消回滚语义/预览合法性两分支。
## 不创建场景、不注册 Autoload、不使用 class_name、不依赖 GUT/WAT、不读取场景树节点、不写入资源目录；
## 不修改 PlacementController/InventoryController/OccupancyRegistry 或任何事务实现，只验证纯规则。
##
## 在当前系统中的位置：
## tests/unit/runtime/level_runtime 下独立 extends SceneTree 的 headless 测试脚本，由 Godot --script 运行；
## 通过 preload 引用 RuntimeMoveRules 与 RuntimeInteractionTypes 枚举契约，避开 MCP run_project 不重建全局 class_name 缓存的问题。
## 与 runtime_moves_test.gd（经 LevelRuntimeController 的集成路径）解耦，本片只对纯规则做 READY 专项断言。
##
## 主要依赖：
## RuntimeMoveRules（res://gameplay/placement/rules/runtime_move_rules.gd，全部静态纯判断）与
## RuntimeInteractionTypes（RunState/DragSource 枚举契约，res://gameplay/interaction/runtime_interaction_types.gd）。
##
## 关键边界：
## - 全部失败项收集后统一退出；任一失败 quit(1)，全过 quit(0)。
## - 纯静态规则测试，无夹具/控制器/节点；静态方法经 preload const 调用，与 level_runtime_controller.gd 生产用法一致。
## - INVENTORY 来源的 from_cell 传入哨兵 Vector2i(-1,-1)（与 core INVALID_CELL 同约定）；RuntimeMoveRules 不依赖其具体数值，
##   仅 PLACED 分支用 from==to 判原格，INVENTORY 分支忽略 from_cell。
## - READY_TO_FIRE 跨格移动按 D7-2 合同属运行期计次状态（消耗 runtime_move_limit），与 PULSE_ACTIVE/MOVE_WINDOW 同；SETUP 不计次、COMPLETED 全冻结。


const _RuntimeMoveRules: GDScript = preload(
	"res://gameplay/placement/rules/runtime_move_rules.gd"
)
const _Types: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)

## INVENTORY 来源哨兵 from_cell；RuntimeMoveRules 不依赖其具体数值，仅 PLACED 分支用 from==to 判原格。
const _INVENTORY_SENTINEL: Vector2i = Vector2i(-1, -1)


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_run_all_tests()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 运行全部 8 组 READY_TO_FIRE 专项测试。
func _run_all_tests() -> void:
	_test_01_ready_can_begin_placed_drag()
	_test_02_ready_can_take_from_inventory()
	_test_03_ready_can_recycle_placed_token()
	_test_04_ready_cross_cell_remaining_positive_allowed_and_counted()
	_test_05_ready_cross_cell_zero_remaining_rejected()
	_test_06_ready_same_cell_safe_cancel_no_count()
	_test_07_ready_cancel_rollback_semantics()
	_test_08_ready_world_drop_preview_valid_branches()


# ===== 测试用例 =====

## 1. READY 已放置机关允许拖起：can_begin_placed_drag(READY_TO_FIRE) == true（与 SETUP/PULSE/MOVE 同；COMPLETED 冻结）。
func _test_01_ready_can_begin_placed_drag() -> void:
	const NAME: String = "01_READY允许拖起已放置"
	var READY: int = _Types.RunState.READY_TO_FIRE
	_check(NAME, _RuntimeMoveRules.can_begin_placed_drag(READY) == true, "READY 应允许拖起已放置机关。")
	# 对比：COMPLETED 冻结拖起。
	_check(NAME, _RuntimeMoveRules.can_begin_placed_drag(_Types.RunState.COMPLETED) == false, "COMPLETED 应冻结拖起。")


## 2. READY 允许从库存拿取/首次放置：can_take_from_inventory_for_state(READY) == true。
func _test_02_ready_can_take_from_inventory() -> void:
	const NAME: String = "02_READY允许库存拿取"
	var READY: int = _Types.RunState.READY_TO_FIRE
	_check(NAME, _RuntimeMoveRules.can_take_from_inventory_for_state(READY) == true, "READY 应允许从库存拿取/首次放置。")
	_check(NAME, _RuntimeMoveRules.can_take_from_inventory_for_state(_Types.RunState.COMPLETED) == false, "COMPLETED 应禁止拿取。")


## 3. READY 允许回收已放置机关：can_recycle_placed_token_for_state(READY) == true。
func _test_03_ready_can_recycle_placed_token() -> void:
	const NAME: String = "03_READY允许回收"
	var READY: int = _Types.RunState.READY_TO_FIRE
	_check(NAME, _RuntimeMoveRules.can_recycle_placed_token_for_state(READY) == true, "READY 应允许回收已放置机关。")
	_check(NAME, _RuntimeMoveRules.can_recycle_placed_token_for_state(_Types.RunState.COMPLETED) == false, "COMPLETED 应禁止回收。")


## 4. READY 跨格移动 remaining>0 允许并按运行期规则计次：
##    can_commit_placed_move(READY, >0, 跨格)==true 且 should_count_runtime_move(READY, 跨格)==true。
func _test_04_ready_cross_cell_remaining_positive_allowed_and_counted() -> void:
	const NAME: String = "04_READY跨格remaining>0允许并计次"
	var READY: int = _Types.RunState.READY_TO_FIRE
	var from_cell: Vector2i = Vector2i(1, 1)
	var to_cell: Vector2i = Vector2i(2, 1)
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 1, from_cell, to_cell) == true, "READY remaining=1 跨格应允许提交。")
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 5, from_cell, to_cell) == true, "READY remaining=5 跨格应允许提交。")
	_check(NAME, _RuntimeMoveRules.should_count_runtime_move(READY, from_cell, to_cell) == true, "READY 跨格应计次。")
	# 对比：SETUP 跨格允许提交但不计次（D7-2 SETUP 不属运行期计次状态）。
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(_Types.RunState.SETUP, 0, from_cell, to_cell) == true, "SETUP 跨格提交不受次数限制。")
	_check(NAME, _RuntimeMoveRules.should_count_runtime_move(_Types.RunState.SETUP, from_cell, to_cell) == false, "SETUP 跨格不应计次。")


## 5. READY 跨格移动 remaining==0 拒绝提交：can_commit_placed_move(READY, 0, 跨格)==false。
func _test_05_ready_cross_cell_zero_remaining_rejected() -> void:
	const NAME: String = "05_READY跨格remaining==0拒绝"
	var READY: int = _Types.RunState.READY_TO_FIRE
	var from_cell: Vector2i = Vector2i(1, 1)
	var to_cell: Vector2i = Vector2i(2, 1)
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 0, from_cell, to_cell) == false, "READY remaining=0 跨格应拒绝提交。")
	# 边界对照：remaining>0 同跨格允许，确认 0 与正数的区分仅在跨格提交。
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 1, from_cell, to_cell) == true, "READY remaining=1 跨格应允许（边界对照）。")


## 6. READY 原格松手保持安全取消/不计次语义：should_count_runtime_move(READY, 原格)==false；原格不构成跨格提交。
func _test_06_ready_same_cell_safe_cancel_no_count() -> void:
	const NAME: String = "06_READY原格安全取消不计次"
	var READY: int = _Types.RunState.READY_TO_FIRE
	var cell: Vector2i = Vector2i(3, 3)
	_check(NAME, _RuntimeMoveRules.should_count_runtime_move(READY, cell, cell) == false, "READY 原格松手不应计次。")
	# 原格 from==to 永远不构成跨格提交（remaining 正/零皆然），由 is_world_drop_preview_valid 视为安全取消位置。
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 1, cell, cell) == false, "原格 from==to 不构成跨格提交（remaining=1）。")
	_check(NAME, _RuntimeMoveRules.can_commit_placed_move(READY, 0, cell, cell) == false, "原格 from==to 不构成跨格提交（remaining=0）。")


## 7. READY 取消/回滚保持现有语义：规则层不实现回滚事务，只锁定取消位置（原格）预览合法性不受 remaining==0 影响；
##    空间非法时预览永远非法；跨格 remaining==0 预览非法。
func _test_07_ready_cancel_rollback_semantics() -> void:
	const NAME: String = "07_READY取消/回滚语义"
	var READY: int = _Types.RunState.READY_TO_FIRE
	var cell: Vector2i = Vector2i(3, 3)
	var other: Vector2i = Vector2i(4, 4)
	# 原格空间合法：安全取消位置，即使 remaining==0 也合法。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 0, cell, cell, true) == true, "READY 原格空间合法应预览合法（安全取消，不受 remaining=0 影响）。")
	# 原格空间非法：预览非法。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 0, cell, cell, false) == false, "READY 原格空间非法应预览非法。")
	# 跨格 remaining==0 空间合法：预览非法（无法提交）。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 0, cell, other, true) == false, "READY 跨格 remaining=0 应预览非法。")


## 8. is_world_drop_preview_valid 的 INVENTORY 与 PLACED 两分支 READY 专项覆盖。
func _test_08_ready_world_drop_preview_valid_branches() -> void:
	const NAME: String = "08_READY预览合法性两分支"
	var READY: int = _Types.RunState.READY_TO_FIRE
	var from_cell: Vector2i = Vector2i(1, 1)
	var to_cell: Vector2i = Vector2i(2, 1)
	# INVENTORY 分支：READY 允许拿取；只看空间合法 + 拿取权限，不读 remaining。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.INVENTORY, READY, 0, _INVENTORY_SENTINEL, to_cell, true) == true, "INVENTORY+READY 空间合法应预览合法。")
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.INVENTORY, READY, 0, _INVENTORY_SENTINEL, to_cell, false) == false, "INVENTORY+READY 空间非法应预览非法。")
	# INVENTORY 分支：COMPLETED 禁止拿取（READY 对比）。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.INVENTORY, _Types.RunState.COMPLETED, 0, _INVENTORY_SENTINEL, to_cell, true) == false, "INVENTORY+COMPLETED 应预览非法。")
	# PLACED 分支：READY 跨格 remaining>0 空间合法 → 合法。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 1, from_cell, to_cell, true) == true, "PLACED+READY 跨格 remaining>0 空间合法应预览合法。")
	# PLACED 分支：READY 跨格 remaining==0 空间合法 → 非法。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 0, from_cell, to_cell, true) == false, "PLACED+READY 跨格 remaining==0 应预览非法。")
	# PLACED 分支：READY 原格空间合法 → 合法（安全取消）。
	_check(NAME, _RuntimeMoveRules.is_world_drop_preview_valid(_Types.DragSource.PLACED, READY, 0, from_cell, from_cell, true) == true, "PLACED+READY 原格空间合法应预览合法（安全取消）。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 8
	var passed_checks: int = _checks - _failures.size()
	print("==== RuntimeMoveRules READY_TO_FIRE 专项测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
