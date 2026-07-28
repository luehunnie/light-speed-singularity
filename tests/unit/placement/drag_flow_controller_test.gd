extends SceneTree

## DragFlowController 定向自动测试：通过公开接口验证一次拖拽的完整业务生命周期。
## 使用最小测试替身（桩占用表、桩库存、桩节点、桩工厂、桩 Callable）伪造事务失败与权限拒绝，不修改正式控制器。
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 通过 preload 引用各控制器，避开 MCP run_project 不重建全局 class_name 缓存的问题。
## orientation 镜面复制分支依赖真实 SingleCellMirror 节点（需完整场景树），本单测以桩节点验证“正式机关 orientation 不被拖拽流程改写”；镜面复制本身由集成场景回归。

const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"
const _TOTAL: int = 3
const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 保留工厂实例，避免 RefCounted 在 Callable 单引用下被提前回收导致 null::create。
var _factory_holder: Variant = null


func _initialize() -> void:
	_test_01_inventory_drag_begin()
	_test_02_inventory_place_success()
	_test_03_inventory_illegal_and_transaction_fail()
	_test_04_placed_drag_begin()
	_test_05_original_cell_release()
	_test_06_illegal_cell_release()
	_test_07_cross_cell_move_success()
	_test_08_recycle_success()
	_test_09_recycle_failure()
	_test_10_cancel_current_drag()
	_test_11_permission_denied()
	_test_12_consecutive_drags_no_residual()
	_test_13_orientation_preserved()
	_test_14_ui_and_consistency_callbacks()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用桩 =====

## 机关节点桩：保存 mechanism_id/cell/orientation 与可见性/预览状态，供控制器事务与 DragFlowController 调用。
class _StubToken extends Node2D:
	var mechanism_id: StringName = &""
	var cell: Vector2i = Vector2i.ZERO
	var orientation: Variant = null
	var placed_visible: bool = true
	var drag_preview_visible: bool = true
	var drag_preview_is_preview: bool = false
	var drag_preview_is_valid: bool = false
	var world_position: Vector2 = Vector2.ZERO
	func configure(id: StringName, c: Vector2i) -> void:
		mechanism_id = id
		cell = c
	func set_cell(c: Vector2i) -> void:
		cell = c
	func set_orientation(o: Variant) -> void:
		orientation = o
	func set_drag_preview(p: bool, v: bool) -> void:
		drag_preview_is_preview = p
		drag_preview_is_valid = v
	func set_drag_preview_visible(v: bool) -> void:
		drag_preview_visible = v
	func set_placed_visible(v: bool) -> void:
		placed_visible = v
	func set_world_position(p: Vector2) -> void:
		world_position = p


## 节点工厂桩：create_formal 供 PlacementController，create_preview 供 DragFlowController；记录预览节点供校验销毁。
## 桩节点挂到 SceneTree.root，由树在退出时统一释放，避免 --script 无帧循环导致 queue_free 不生效而泄漏。
class _StubFactory:
	var created_previews: Array[Variant] = []
	var tree: SceneTree = null
	func create_formal(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
		var token: _StubToken = _new_token(mechanism_id, cell)
		token.set_orientation(orientation)
		return token
	func create_preview(mechanism_id: StringName, cell: Vector2i) -> Variant:
		var token: _StubToken = _new_token(mechanism_id, cell)
		created_previews.append(token)
		return token
	func _new_token(mechanism_id: StringName, cell: Vector2i) -> _StubToken:
		var token: _StubToken = _StubToken.new()
		token.configure(mechanism_id, cell)
		if tree != null and tree.root != null:
			tree.root.add_child(token)
		return token


## 占用表桩：仅对指定 ID 令 unregister 失败，用于伪造回收失败。
class _FailUnregisterForIdRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var fail_id: StringName = &""
	func unregister(mechanism_id: StringName) -> bool:
		if mechanism_id == fail_id:
			return false
		return super.unregister(mechanism_id)


## 库存桩：try_consume_one 强制失败，用于伪造首次放置事务失败。
class _FailConsumeInventory extends "res://gameplay/placement/inventory_controller.gd":
	func try_consume_one() -> bool:
		return false


## 指针解析桩：返回预设的 PointerScene（命中机关栏/槽位/世界格），由测试按需配置。
class _PointerResolver:
	var scene: Variant = null
	func resolve(_p: Vector2) -> Variant:
		return scene


## 权限查询桩：返回预设的 DragPermission（运行状态 + 剩余次数），由测试按需配置。
class _PermissionQuery:
	var permission: Variant = null
	func query() -> Variant:
		return permission


## 扣次桩：记录被请求扣除的次数。
class _MoveConsumer:
	var count: int = 0
	func consume() -> void:
		count += 1


## UI 刷新桩：记录刷新次数。
class _UiRefresher:
	var count: int = 0
	func refresh() -> void:
		count += 1


## 一致性断言桩：记录断言次数。
class _ConsistencyAsserter:
	var count: int = 0
	func assert_() -> void:
		count += 1


## 测试上下文：聚合一次用例所需的控制器、桩与 Callable。
class _Ctx:
	var fc: Variant = null
	var pc: _PlacementController = null
	var inv: _InventoryController = null
	var occ: _OccupancyRegistry = null
	var factory: _StubFactory = null
	var resolver: _PointerResolver = null
	var permission: _PermissionQuery = null
	var move_consumer: _MoveConsumer = null
	var ui_refresher: _UiRefresher = null
	var asserter: _ConsistencyAsserter = null


## 构造测试上下文：用真实 PlacementController/LevelWorldQuery + 桩 Callable 装配 DragFlowController。
func _make_ctx(
		occ: _OccupancyRegistry,
		inv: _InventoryController,
		run_state: int,
		moves_remaining: int
) -> _Ctx:
	var ctx: _Ctx = _Ctx.new()
	ctx.occ = occ
	ctx.inv = inv
	ctx.factory = _StubFactory.new()
	ctx.factory.tree = self
	_factory_holder = ctx.factory
	ctx.pc = _PlacementController.new(occ, inv, Callable(ctx.factory, "create_formal"))
	var walls: Array[Vector2i] = []
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, Vector2i(-1, -1), registry, occ,
		Callable(ctx.pc, "get_placed_node")
	)
	ctx.pc.set_level_world_query(lwq)
	ctx.resolver = _PointerResolver.new()
	ctx.permission = _PermissionQuery.new()
	ctx.permission.permission = _DragFlowController.DragPermission.new(run_state, moves_remaining)
	ctx.move_consumer = _MoveConsumer.new()
	ctx.ui_refresher = _UiRefresher.new()
	ctx.asserter = _ConsistencyAsserter.new()
	ctx.fc = _DragFlowController.new(
		ctx.pc, inv, lwq,
		Callable(ctx.resolver, "resolve"),
		Callable(ctx.factory, "create_preview"),
		Callable(ctx.permission, "query"),
		Callable(ctx.move_consumer, "consume"),
		Callable(ctx.ui_refresher, "refresh"),
		Callable(ctx.asserter, "assert_")
	)
	return ctx


## 设置指针命中：是否机关栏、是否原型槽位、世界格。
func _set_pointer(ctx: _Ctx, over_bar: bool, over_slot: bool, world_cell: Vector2i) -> void:
	ctx.resolver.scene = _DragFlowController.PointerScene.new(over_bar, over_slot, world_cell)


## 设置当前权限：运行状态与剩余次数。
func _set_permission(ctx: _Ctx, run_state: int, moves_remaining: int) -> void:
	ctx.permission.permission = _DragFlowController.DragPermission.new(run_state, moves_remaining)


# ===== 测试用例 =====

## 1. 库存拖拽开始：Context 激活、预览创建、库存不变。
func _test_01_inventory_drag_begin() -> void:
	const NAME: String = "01_库存拖拽开始"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx, false, true, Vector2i(5, 5))
	var ok: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ok, "try_begin_drag 应返回 true。")
	_check(NAME, ctx.fc.is_dragging(), "应处于拖拽中。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.factory.created_previews.size() == 1, "应创建一个预览节点。")
	_check(NAME, ctx.fc.is_dragging(), "Context 应激活。")


## 2. 库存合法放置成功：PlacementController 被调用、库存扣一、预览清理、Context 清空。
func _test_02_inventory_place_success() -> void:
	const NAME: String = "02_库存放置成功"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx, false, true, Vector2i(5, 5))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, false, false, Vector2i(5, 5))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "放置后应结束拖拽。")
	_check(NAME, ctx.pc.get_placed_count() == 1, "应已放置一个机关。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "库存应扣一，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.factory.created_previews.size() == 1, "应只创建过一个预览。")
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "预览应被 queue_free。")
	_check(NAME, ctx.ui_refresher.count >= 1, "应刷新 UI。")
	_check(NAME, ctx.asserter.count >= 1, "应执行一致性断言。")


## 3. 库存非法或事务失败：库存不变、无正式机关残留、拖拽清理。
func _test_03_inventory_illegal_and_transaction_fail() -> void:
	const NAME: String = "03_库存非法或事务失败"
	# 非法格（边界外）。
	var ctx_a: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx_a, false, true, Vector2i(100, 100))
	ctx_a.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx_a, false, false, Vector2i(100, 100))
	ctx_a.fc.update_preview(Vector2.ZERO)
	ctx_a.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx_a.fc.is_dragging(), "非法放置后应结束拖拽。")
	_check(NAME, ctx_a.pc.get_placed_count() == 0, "非法格不应创建正式机关。")
	_check(NAME, ctx_a.inv.get_remaining() == _TOTAL, "非法格库存应不变，实际 %d。" % [ctx_a.inv.get_remaining()])
	_check(NAME, ctx_a.factory.created_previews[0].is_queued_for_deletion(), "非法格预览应被清理。")
	# 事务失败（扣库存失败）。
	var ctx_b: _Ctx = _make_ctx(_OccupancyRegistry.new(), _FailConsumeInventory.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx_b, false, true, Vector2i(5, 5))
	ctx_b.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx_b, false, false, Vector2i(5, 5))
	ctx_b.fc.update_preview(Vector2.ZERO)
	ctx_b.fc.finish_drag(Vector2.ZERO)
	_check(NAME, ctx_b.pc.get_placed_count() == 0, "事务失败不应残留正式机关。")
	_check(NAME, ctx_b.inv.get_remaining() == _TOTAL, "事务失败库存应不变，实际 %d。" % [ctx_b.inv.get_remaining()])
	_check(NAME, not ctx_b.fc.is_dragging(), "事务失败后应结束拖拽。")


## 4. 已放置机关拖拽开始：原节点隐藏、原占用与映射仍存在。
func _test_04_placed_drag_begin() -> void:
	const NAME: String = "04_已放置拖拽开始"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	var ok: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ok, "try_begin_drag 应返回 true。")
	_check(NAME, ctx.fc.is_dragging(), "应处于拖拽中。")
	_check(NAME, not token.placed_visible, "正式节点应被隐藏。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")
	_check(NAME, ctx.pc.has_placed(placed.mechanism_id), "映射应保留。")
	_check(NAME, ctx.factory.created_previews.size() == 1, "应创建预览。")


## 5. 原格松手：节点恢复、不请求扣移动次数。
func _test_05_original_cell_release() -> void:
	const NAME: String = "05_原格松手"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "原格松手应结束拖拽。")
	_check(NAME, token.placed_visible, "节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应仍在原格。")
	_check(NAME, ctx.move_consumer.count == 0, "原格松手不应扣移动次数。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


## 6. 非法格松手：节点恢复原格和显示、不扣次数。
func _test_06_illegal_cell_release() -> void:
	const NAME: String = "06_非法格松手"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, false, false, Vector2i(100, 100))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "非法格松手应结束拖拽。")
	_check(NAME, token.placed_visible, "节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应回原格，实际 %s。" % [token.cell])
	_check(NAME, ctx.move_consumer.count == 0, "非法格不应扣次数。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


## 7. 成功跨格：调用 move_placed、节点最终显示、只请求扣一次移动次数。
func _test_07_cross_cell_move_success() -> void:
	const NAME: String = "07_成功跨格"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, false, false, Vector2i(3, 3))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "跨格成功应结束拖拽。")
	_check(NAME, token.cell == Vector2i(3, 3), "节点应移至目标格，实际 %s。" % [token.cell])
	_check(NAME, token.placed_visible, "节点应最终显示。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(3, 3)) == placed.mechanism_id, "新占用应成立。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == &"", "旧占用应移除。")
	_check(NAME, ctx.move_consumer.count == 1, "应只扣一次移动次数，实际 %d。" % [ctx.move_consumer.count])
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "移动不应改变库存。")


## 8. 回收成功：调用 recycle_placed、不扣移动次数、库存增加。
func _test_08_recycle_success() -> void:
	const NAME: String = "08_回收成功"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, true, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "回收后应结束拖拽。")
	_check(NAME, not ctx.pc.has_placed(placed.mechanism_id), "映射应已移除。")
	_check(NAME, not ctx.occ.has_mechanism(placed.mechanism_id), "占用应已移除。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.move_consumer.count == 0, "回收不应扣移动次数。")


## 9. 回收失败：正式节点恢复、库存不变。
func _test_09_recycle_failure() -> void:
	const NAME: String = "09_回收失败"
	var occ: _FailUnregisterForIdRegistry = _FailUnregisterForIdRegistry.new()
	var ctx: _Ctx = _make_ctx(occ, _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	occ.fail_id = placed.mechanism_id
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, true, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "回收失败后应结束拖拽。")
	_check(NAME, ctx.pc.has_placed(placed.mechanism_id), "回收失败映射应保留。")
	_check(NAME, ctx.occ.has_mechanism(placed.mechanism_id), "回收失败占用应保留。")
	_check(NAME, token.placed_visible, "正式节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "正式节点应回原格。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "回收失败库存应不变。")


## 10. cancel_current_drag：预览清理、正式节点恢复、Context 清空。
func _test_10_cancel_current_drag() -> void:
	const NAME: String = "10_cancel_current_drag"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	ctx.fc.cancel_current_drag()
	_check(NAME, not ctx.fc.is_dragging(), "取消后应结束拖拽。")
	_check(NAME, token.placed_visible, "正式节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "正式节点应回原格。")
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "预览应被清理。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


## 11. 权限拒绝：不开始拖拽、不创建预览。
func _test_11_permission_denied() -> void:
	const NAME: String = "11_权限拒绝"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.COMPLETED, 0)
	_set_pointer(ctx, false, true, Vector2i(5, 5))
	var ok_inv: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, not ok_inv, "COMPLETED 库存拖拽应被拒绝。")
	_check(NAME, not ctx.fc.is_dragging(), "不应进入拖拽。")
	_check(NAME, ctx.factory.created_previews.size() == 0, "不应创建预览。")
	# COMPLETED 下已放置机关拖起亦被拒绝。
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	var ok_placed: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, not ok_placed, "COMPLETED 已放置拖拽应被拒绝。")
	_check(NAME, ctx.factory.created_previews.size() == 0, "COMPLETED 不应创建预览。")


## 12. 连续拖拽之间无旧节点或旧事实残留。
func _test_12_consecutive_drags_no_residual() -> void:
	const NAME: String = "12_连续拖拽无残留"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	# 第一次：库存拖拽后取消。
	_set_pointer(ctx, false, true, Vector2i(5, 5))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ctx.fc.is_dragging(), "第一次应进入拖拽。")
	ctx.fc.cancel_current_drag()
	_check(NAME, not ctx.fc.is_dragging(), "第一次取消后应结束拖拽。")
	# 第二次：已放置机关拖拽。
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ctx.fc.is_dragging(), "第二次应进入拖拽。")
	_check(NAME, ctx.factory.created_previews.size() == 2, "应累计创建两个预览，实际 %d。" % [ctx.factory.created_previews.size()])
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "第一次预览应已清理。")
	_check(NAME, not ctx.factory.created_previews[1].is_queued_for_deletion(), "第二次预览应仍存活。")
	ctx.fc.cancel_current_drag()


## 13. orientation 保持：拖拽/移动/取消不改写正式机关 orientation。
func _test_13_orientation_preserved() -> void:
	const NAME: String = "13_orientation保持"
	var ctx: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _StubToken
	token.set_orientation(2)
	_set_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx, false, false, Vector2i(3, 3))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, token.orientation == 2, "跨格移动后 orientation 应保持为 2，实际 %s。" % [token.orientation])
	_check(NAME, token.cell == Vector2i(3, 3), "节点应已移至目标格。")


## 14. UI 刷新与一致性回调只在正确时点执行。
func _test_14_ui_and_consistency_callbacks() -> void:
	const NAME: String = "14_回调时点"
	# 取消（无状态变化）：触发断言，不刷新 UI。
	var ctx_a: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx_a, false, true, Vector2i(5, 5))
	ctx_a.fc.try_begin_drag(Vector2.ZERO)
	ctx_a.fc.cancel_current_drag()
	_check(NAME, ctx_a.ui_refresher.count == 0, "取消不应刷新 UI，实际 %d。" % [ctx_a.ui_refresher.count])
	_check(NAME, ctx_a.asserter.count >= 1, "普通取消应执行一致性断言。")
	# R 取消（should_assert_consistency=false）：不触发断言，不刷新 UI。
	var ctx_b: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx_b, false, true, Vector2i(5, 5))
	ctx_b.fc.try_begin_drag(Vector2.ZERO)
	ctx_b.fc.cancel_current_drag(false)
	_check(NAME, ctx_b.ui_refresher.count == 0, "R 取消不应刷新 UI。")
	_check(NAME, ctx_b.asserter.count == 0, "R 取消不应执行一致性断言。")
	# 库存放置成功：刷新 UI + 断言各至少一次。
	var ctx_c: _Ctx = _make_ctx(_OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_set_pointer(ctx_c, false, true, Vector2i(5, 5))
	ctx_c.fc.try_begin_drag(Vector2.ZERO)
	_set_pointer(ctx_c, false, false, Vector2i(5, 5))
	ctx_c.fc.update_preview(Vector2.ZERO)
	ctx_c.fc.finish_drag(Vector2.ZERO)
	_check(NAME, ctx_c.ui_refresher.count >= 1, "放置成功应刷新 UI。")
	_check(NAME, ctx_c.asserter.count >= 1, "放置成功应执行断言。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 14
	var passed_checks: int = _checks - _failures.size()
	print("==== DragFlowController 测试摘要 ====")
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
