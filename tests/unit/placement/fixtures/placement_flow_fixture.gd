extends RefCounted

## PlacementController 单元测试共享装配夹具（D4.6-T2）。
## 只负责构造测试对象、占用/库存桩与基础接线；不含断言、不含 PlacementController 业务规则、不隐藏被测事务操作。
## 各 placement_controller_*_test.gd 以成员持有本夹具实例，避免工厂 RefCounted 在 Callable 单引用下被提前回收（见 GDScript Callable 不保留 RefCounted 坑）。

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

const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)


# ===== 测试用桩 =====

## 占用表桩：仅对指定格令 register_single_cell 失败，其余继承真实行为。
class _FailRegisterForCellRegistry extends "res://gameplay/placement/occupancy_registry.gd":
	var fail_cell: Vector2i = Vector2i(-888888, -888888)
	func register_single_cell(mechanism_id: StringName, cell: Vector2i) -> bool:
		if cell == fail_cell:
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
