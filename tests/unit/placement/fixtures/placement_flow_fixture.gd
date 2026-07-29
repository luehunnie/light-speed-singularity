extends RefCounted

## Placement 流程单元测试共享装配夹具（D4.6-T2 起；D4.6-T3 扩展 DragFlowController 装配）。
## 只负责构造测试对象、占用/库存桩与基础接线；不含断言、不含 PlacementController/DragFlowController 业务规则、不隐藏被测事务操作。
## PlacementController 片用 make_controller + _StubToken/_StubFactory；DragFlowController 片用 make_drag_flow + _Drag* 系列桩。
## 各 *_test.gd 以成员持有本夹具实例，避免工厂 RefCounted 在 Callable 单引用下被提前回收（见 GDScript Callable 不保留 RefCounted 坑）。

const _PlacementController: GDScript = preload(
	"res://gameplay/placement/placement_controller.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)
const _LevelObjectRegistry: GDScript = preload(
	"res://gameplay/level/level_object_registry.gd"
)
const _DragFlowController: GDScript = preload(
	"res://gameplay/interaction/drag_flow_controller.gd"
)

const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)


# ===== 测试用桩 =====

## 占用表桩：仅对指定格令 register_single_cell 失败，其余继承真实行为。
class _FailRegisterForCellRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var fail_cell: Vector2i = Vector2i(-888888, -888888)
	func register_single_cell(mechanism_id: StringName, cell: Vector2i) -> bool:
		if cell == fail_cell:
			return false
		return super.register_single_cell(mechanism_id, cell)


## 占用表桩：register_single_cell 首次继承真实行为、第二次起返回 false，用于伪造回收回滚恢复占用失败（不变量破坏）。
## 放置时第 1 次注册成功，回收回滚时第 2 次注册失败；仅模拟接口结果，不含业务判断。
class _FailRegisterOnSecondCallRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var _register_count: int = 0
	func register_single_cell(mechanism_id: StringName, cell: Vector2i) -> bool:
		_register_count += 1
		if _register_count >= 2:
			return false
		return super.register_single_cell(mechanism_id, cell)


## 占用表桩：仅对指定 ID 令 unregister 失败，其余继承真实行为。
class _FailUnregisterForIdRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var fail_id: StringName = &""
	func unregister(mechanism_id: StringName) -> bool:
		if mechanism_id == fail_id:
			return false
		return super.unregister(mechanism_id)


## 占用表桩：令 move_single_cell 直接返回 false，伪造原子占用迁移失败（不修改任何事实）。
class _FailMoveRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var fail_move: bool = false
	func move_single_cell(mechanism_id: StringName, source_cell: Vector2i, target_cell: Vector2i) -> bool:
		if fail_move:
			return false
		return super.move_single_cell(mechanism_id, source_cell, target_cell)


## 库存桩：try_reserve_return_one 强制失败，用于伪造回收预留失败（库存已满或预留超容量）。
class _FailReserveInventory extends "res://gameplay/placement/inventory_controller.gd":
	func try_reserve_return_one() -> bool:
		return false


## 库存桩：commit_reserved_return 强制失败，用于伪造预留已锁定后提交归还失败（不变量破坏）。
class _FailCommitReturnInventory extends "res://gameplay/placement/inventory_controller.gd":
	func commit_reserved_return() -> bool:
		return false


## 库存桩：commit_reserved_return 首次返回 false、之后继承真实行为，用于验证 commit 失败事务回滚后再次回收成功（库存只归还一次）。
class _FailCommitOnceInventory extends "res://gameplay/placement/inventory_controller.gd":
	var _commit_failed_once: bool = false
	func commit_reserved_return() -> bool:
		if not _commit_failed_once:
			_commit_failed_once = true
			return false
		return super.commit_reserved_return()


## 库存桩：can_consume_one 继承真实行为，try_consume_one 强制失败，用于伪造扣库存失败。
class _FailConsumeInventory extends "res://gameplay/placement/inventory_controller.gd":
	func try_consume_one() -> bool:
		return false


## 机关节点桩：保存 mechanism_id/cell/orientation，提供控制器事务所需的 set_cell/queue_free 等接口。
class _StubToken extends Node2D:
	var mechanism_id: StringName = &""
	var cell: Vector2i = Vector2i.ZERO
	var orientation: Variant = null
	func configure(id: StringName, c: Vector2i) -> void:
		mechanism_id = id
		cell = c
	func set_cell(c: Vector2i) -> void:
		cell = c
	func set_orientation(o: Variant) -> void:
		orientation = o
	func set_drag_preview(_p: bool, _v: bool) -> void:
		pass
	func set_world_position(_p: Vector2) -> void:
		pass
	func set_placed_visible(_v: bool) -> void:
		pass


## 节点工厂桩：可切换返回 null 伪造创建失败，并记录已创建节点供测试校验销毁。
## 创建的桩节点挂到 SceneTree.root，由树在退出时统一释放，避免 --script 模式无帧循环导致 queue_free 不生效而泄漏。
class _StubFactory:
	var return_null: bool = false
	var created_tokens: Array[Variant] = []
	var tree: SceneTree = null
	func create(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
		if return_null:
			return null
		var token: _StubToken = _StubToken.new()
		token.configure(mechanism_id, cell)
		token.set_orientation(orientation)
		if tree != null and tree.root != null:
			tree.root.add_child(token)
		created_tokens.append(token)
		return token


# ===== 装配 =====

## 保留当前测试的工厂实例，避免 RefCounted 在 Callable 单引用下被提前回收导致 null::create。
var _factory_holder: Variant = null


## 构造已注入 LevelWorldQuery 的控制器；occupancy/inventory/factory 由调用方提供。
## tree 由调用方传入（即运行测试的 SceneTree），用于把桩节点挂到 root 统一释放。
func make_controller(
		tree: SceneTree,
		occupancy: _OccupancyRegistry,
		inventory: _InventoryController,
		factory: _StubFactory
) -> _PlacementController:
	_factory_holder = factory
	factory.tree = tree
	var pc: _PlacementController = _PlacementController.new(occupancy, inventory, Callable(factory, "create"))
	var walls: Array[Vector2i] = []
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS,
		walls,
		Vector2i(-1, -1),
		registry,
		occupancy,
		Callable(pc, "get_placed_node")
	)
	pc.set_level_world_query(lwq)
	return pc


# ===== DragFlowController 测试用桩 =====

## 机关节点桩（拖拽流）：保存 mechanism_id/cell/orientation 与可见性/预览状态，供控制器事务与 DragFlowController 调用。
class _DragStubToken extends Node2D:
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


## 节点工厂桩（拖拽流）：create_formal 供 PlacementController，create_preview 供 DragFlowController；记录预览节点供校验销毁。
## 桩节点挂到 SceneTree.root，由树在退出时统一释放，避免 --script 无帧循环导致 queue_free 不生效而泄漏。
class _DragStubFactory:
	var created_previews: Array[Variant] = []
	var tree: SceneTree = null
	func create_formal(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
		var token: _DragStubToken = _new_token(mechanism_id, cell)
		token.set_orientation(orientation)
		return token
	func create_preview(mechanism_id: StringName, cell: Vector2i) -> Variant:
		var token: _DragStubToken = _new_token(mechanism_id, cell)
		created_previews.append(token)
		return token
	func _new_token(mechanism_id: StringName, cell: Vector2i) -> _DragStubToken:
		var token: _DragStubToken = _DragStubToken.new()
		token.configure(mechanism_id, cell)
		if tree != null and tree.root != null:
			tree.root.add_child(token)
		return token


## 指针解析桩：返回预设的 PointerScene（命中机关栏/槽位/世界格），由测试按需配置。
class _DragPointerResolver:
	var scene: Variant = null
	func resolve(_p: Vector2) -> Variant:
		return scene


## 权限查询桩：返回预设的 DragPermission（运行状态 + 剩余次数），由测试按需配置。
class _DragPermissionQuery:
	var permission: Variant = null
	func query() -> Variant:
		return permission


## 扣次桩：记录被请求扣除的次数。
class _DragMoveConsumer:
	var count: int = 0
	func consume() -> void:
		count += 1


## UI 刷新桩：记录刷新次数。
class _DragUiRefresher:
	var count: int = 0
	func refresh() -> void:
		count += 1


## 一致性断言桩：记录断言次数（仅计数，不执行真实断言）。
class _DragConsistencyAsserter:
	var count: int = 0
	func assert_() -> void:
		count += 1


## 拖拽流测试上下文：聚合一次用例所需的控制器、桩与 Callable。
class _DragCtx:
	var fc: Variant = null
	var pc: _PlacementController = null
	var inv: _InventoryController = null
	var occ: _OccupancyRegistry = null
	var factory: _DragStubFactory = null
	var resolver: _DragPointerResolver = null
	var permission: _DragPermissionQuery = null
	var move_consumer: _DragMoveConsumer = null
	var ui_refresher: _DragUiRefresher = null
	var asserter: _DragConsistencyAsserter = null


# ===== DragFlowController 装配 =====

## 构造拖拽流测试上下文：用真实 PlacementController/LevelWorldQuery + 桩 Callable 装配 DragFlowController。
## tree 由调用方传入（即运行测试的 SceneTree），用于把桩节点挂到 root 统一释放。
func make_drag_flow(
		tree: SceneTree,
		occ: _OccupancyRegistry,
		inv: _InventoryController,
		run_state: int,
		moves_remaining: int
) -> _DragCtx:
	var ctx: _DragCtx = _DragCtx.new()
	ctx.occ = occ
	ctx.inv = inv
	ctx.factory = _DragStubFactory.new()
	ctx.factory.tree = tree
	_factory_holder = ctx.factory
	ctx.pc = _PlacementController.new(occ, inv, Callable(ctx.factory, "create_formal"))
	var walls: Array[Vector2i] = []
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, Vector2i(-1, -1), registry, occ,
		Callable(ctx.pc, "get_placed_node")
	)
	ctx.pc.set_level_world_query(lwq)
	ctx.resolver = _DragPointerResolver.new()
	ctx.permission = _DragPermissionQuery.new()
	ctx.permission.permission = _DragFlowController.DragPermission.new(run_state, moves_remaining)
	ctx.move_consumer = _DragMoveConsumer.new()
	ctx.ui_refresher = _DragUiRefresher.new()
	ctx.asserter = _DragConsistencyAsserter.new()
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
func set_drag_pointer(ctx: _DragCtx, over_bar: bool, over_slot: bool, world_cell: Vector2i) -> void:
	ctx.resolver.scene = _DragFlowController.PointerScene.new(over_bar, over_slot, world_cell)
