extends SceneTree

## PlacementController 定向自动测试：只通过公开接口观察放置/移动/回收/R 清理的事务结果与原子回滚。
## 使用最小测试替身（继承 OccupancyRegistry 的桩、桩节点、桩工厂）伪造占用失败与节点创建失败，不修改正式 OccupancyRegistry。
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

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

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"
const _TOTAL: int = 3
const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 保留当前测试的工厂实例，避免 RefCounted 在 Callable 单引用下被提前回收导致 null::create。
var _factory_holder: Variant = null


func _initialize() -> void:
	_test_01_place_from_inventory_success()
	_test_02_place_invalid_cell_no_change()
	_test_03_place_node_creation_failure_rollback()
	_test_04_place_occupancy_register_failure_rollback()
	_test_05_place_inventory_consume_failure_rollback()
	_test_06_move_success()
	_test_07_move_same_cell_no_change()
	_test_08_move_new_cell_register_failure_restore()
	_test_09_recycle_success()
	_test_10_recycle_unregister_failure_keep()
	_test_11_clear_all_success()
	_test_12_clear_all_partial_failure()
	_test_13_move_preserves_orientation()
	_test_14_serial_ids_unique()
	_report()
	quit(0 if _failures.is_empty() else 1)


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


## 构造已注入 LevelWorldQuery 的控制器；occupancy/inventory/factory 由调用方提供。
func _make_controller(
		occupancy: _OccupancyRegistry,
		inventory: _InventoryController,
		factory: _StubFactory
) -> _PlacementController:
	_factory_holder = factory
	factory.tree = self
	var pc: _PlacementController = _PlacementController.new(occupancy, inventory, Callable(factory, "create"))
	var walls: Array[Vector2i] = []
	var crystals: Array[BasicCrystal] = []
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS,
		walls,
		Vector2i(-1, -1),
		crystals,
		occupancy,
		pc.get_placed_tokens_by_id_reference()
	)
	pc.set_level_world_query(lwq)
	return pc


# ===== 测试用例 =====

## 1. 新机关放置成功：占用存在、映射存在、库存减一。
func _test_01_place_from_inventory_success() -> void:
	const NAME: String = "01_放置成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s（%s）。" % [r.status, r.error_message])
	_check(NAME, r.mechanism_id != &"", "期望非空 mechanism_id。")
	_check(NAME, occ.has_mechanism(r.mechanism_id), "占用表应存在该机关。")
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == r.mechanism_id, "目标格应指向该机关。")
	_check(NAME, pc.has_placed(r.mechanism_id), "映射应存在该机关。")
	_check(NAME, pc.get_placed_count() == 1, "已放置数期望 1，实际 %d。" % [pc.get_placed_count()])
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存剩余期望 %d，实际 %d。" % [_TOTAL - 1, inv.get_remaining()])
	_check(NAME, r.consumes_runtime_move == false, "新机关放置不应消耗运行期移动次数。")


## 2. 非法格放置：无占用、无映射、库存不变。
func _test_02_place_invalid_cell_no_change() -> void:
	const NAME: String = "02_非法格放置"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	# 边界外格子非法。
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(100, 100), 1)
	_check(NAME, r.status == _PlacementController.Status.INVALID, "期望 INVALID，实际 %s。" % [r.status])
	_check(NAME, pc.get_placed_count() == 0, "映射应为空。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [inv.get_remaining()])
	# 预先占用目标格后放置也应 INVALID。
	occ.register_single_cell(&"other", Vector2i(2, 2))
	var r2 := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), 1)
	_check(NAME, r2.status == _PlacementController.Status.INVALID, "被占用格期望 INVALID，实际 %s。" % [r2.status])
	_check(NAME, pc.get_placed_count() == 0, "映射仍应为空。")


## 3. 节点创建失败：无残留占用、无映射、库存不变。
func _test_03_place_node_creation_failure_rollback() -> void:
	const NAME: String = "03_节点创建失败回滚"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var factory: _StubFactory = _StubFactory.new()
	factory.return_null = true
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, pc.get_placed_count() == 0, "映射应为空。")
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [inv.get_remaining()])
	_check(NAME, factory.created_tokens.is_empty(), "不应创建任何节点。")


## 4. 占用登记失败：正式节点被清理、无映射、库存不变。
func _test_04_place_occupancy_register_failure_rollback() -> void:
	const NAME: String = "04_占用登记失败回滚"
	var occ: _FailRegisterForCellRegistry = _FailRegisterForCellRegistry.new()
	occ.fail_cell = Vector2i(1, 1)
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var factory: _StubFactory = _StubFactory.new()
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, pc.get_placed_count() == 0, "映射应为空。")
	_check(NAME, not occ.has_mechanism(r.mechanism_id), "占用表不应残留该机关。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [inv.get_remaining()])
	_check(NAME, factory.created_tokens.size() == 1, "应已创建一个节点。")
	_check(NAME, factory.created_tokens[0].is_queued_for_deletion(), "已创建节点应被清理（queue_free）。")


## 5. 库存扣除失败：占用、映射、节点全部回滚。
func _test_05_place_inventory_consume_failure_rollback() -> void:
	const NAME: String = "05_库存扣除失败回滚"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _FailConsumeInventory = _FailConsumeInventory.new(_TOTAL)
	var factory: _StubFactory = _StubFactory.new()
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, pc.get_placed_count() == 0, "映射应已回滚为空。")
	_check(NAME, not occ.has_mechanism(r.mechanism_id), "占用应已回滚。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [inv.get_remaining()])
	_check(NAME, factory.created_tokens.size() == 1, "应已创建一个节点。")
	_check(NAME, factory.created_tokens[0].is_queued_for_deletion(), "节点应已回滚清理。")


## 6. 移动成功：旧占用移除、新占用成立、节点位置更新、consumes_runtime_move=true。
func _test_06_move_success() -> void:
	const NAME: String = "06_移动成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(3, 3))
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s（%s）。" % [r.status, r.error_message])
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == &"", "旧占用应已移除。")
	_check(NAME, occ.get_mechanism_at(Vector2i(3, 3)) == placed.mechanism_id, "新占用应成立。")
	var token: Variant = pc.get_placed_node(placed.mechanism_id)
	_check(NAME, token.cell == Vector2i(3, 3), "节点 cell 应更新为目标格，实际 %s。" % [token.cell])
	_check(NAME, r.consumes_runtime_move == true, "成功跨格移动应返回 consumes_runtime_move=true。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "移动不应改变库存，实际 %d。" % [inv.get_remaining()])


## 7. 原格移动：NO_CHANGE、不扣次数。
func _test_07_move_same_cell_no_change() -> void:
	const NAME: String = "07_原格NO_CHANGE"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(1, 1))
	_check(NAME, r.status == _PlacementController.Status.NO_CHANGE, "期望 NO_CHANGE，实际 %s。" % [r.status])
	_check(NAME, r.consumes_runtime_move == false, "原格不应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "占用应保持不变。")


## 8. 新格登记失败：恢复旧占用、节点回原格。
func _test_08_move_new_cell_register_failure_restore() -> void:
	const NAME: String = "08_新格登记失败恢复"
	var occ: _FailRegisterForCellRegistry = _FailRegisterForCellRegistry.new()
	occ.fail_cell = Vector2i(3, 3)
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: Variant = pc.get_placed_node(placed.mechanism_id)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(3, 3))
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "旧占用应已恢复。")
	_check(NAME, occ.get_mechanism_at(Vector2i(3, 3)) == &"", "新占用不应成立。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应回原格，实际 %s。" % [token.cell])
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应不变。")


## 9. 回收成功：占用、映射移除、库存加一。
func _test_09_recycle_success() -> void:
	const NAME: String = "09_回收成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s（%s）。" % [r.status, r.error_message])
	_check(NAME, not occ.has_mechanism(placed.mechanism_id), "占用应已移除。")
	_check(NAME, not pc.has_placed(placed.mechanism_id), "映射应已移除。")
	_check(NAME, pc.get_placed_count() == 0, "已放置数应为 0。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [inv.get_remaining()])


## 10. 回收注销失败：节点、映射、库存保持。
func _test_10_recycle_unregister_failure_keep() -> void:
	const NAME: String = "10_回收注销失败保持"
	var occ: _FailUnregisterForIdRegistry = _FailUnregisterForIdRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	occ.fail_id = placed.mechanism_id
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, pc.has_placed(placed.mechanism_id), "映射应保持。")
	_check(NAME, occ.has_mechanism(placed.mechanism_id), "占用应保持。")
	_check(NAME, pc.get_placed_node(placed.mechanism_id) != null, "节点应保持。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应不变，实际 %d。" % [inv.get_remaining()])


## 11. clear_all 全部成功：placed_count=0、库存恢复满。
func _test_11_clear_all_success() -> void:
	const NAME: String = "11_clear_all成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), 1)
	_check(NAME, pc.get_placed_count() == 2, "前置：应已放置 2 个。")
	var r := pc.clear_all_placed()
	_check(NAME, r.removed_count == 2, "removed_count 期望 2，实际 %d。" % [r.removed_count])
	_check(NAME, r.unresolved_count == 0, "unresolved_count 期望 0，实际 %d。" % [r.unresolved_count])
	_check(NAME, pc.get_placed_count() == 0, "清理后已放置数应为 0。")
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [inv.get_remaining()])


## 12. clear_all 部分失败：残留映射保留、unresolved_count 正确、库存与残留数一致。
func _test_12_clear_all_partial_failure() -> void:
	const NAME: String = "12_clear_all部分失败"
	var occ: _FailUnregisterForIdRegistry = _FailUnregisterForIdRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var a := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var b := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), 1)
	occ.fail_id = a.mechanism_id
	var r := pc.clear_all_placed()
	_check(NAME, r.removed_count == 1, "removed_count 期望 1，实际 %d。" % [r.removed_count])
	_check(NAME, r.unresolved_count == 1, "unresolved_count 期望 1，实际 %d。" % [r.unresolved_count])
	_check(NAME, r.unresolved_ids.has(a.mechanism_id), "未清理 ID 应包含被锁定的机关。")
	_check(NAME, not pc.has_placed(b.mechanism_id), "可清理机关映射应已移除。")
	_check(NAME, pc.has_placed(a.mechanism_id), "未清理机关映射应保留。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应与残留数一致（total-1），实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.is_consistent_with_placed_count(pc.get_placed_count()), "remaining + placed_count == total 应成立。")


## 13. orientation 在移动后保持。
func _test_13_move_preserves_orientation() -> void:
	const NAME: String = "13_移动后orientation保持"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _StubToken = pc.get_placed_node(placed.mechanism_id) as _StubToken
	token.set_orientation(2)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(4, 4))
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s。" % [r.status])
	_check(NAME, token.orientation == 2, "移动后 orientation 应保持为 2，实际 %s。" % [token.orientation])
	_check(NAME, token.cell == Vector2i(4, 4), "节点应已移至目标格。")


## 14. serial 生成的 ID 不重复。
func _test_14_serial_ids_unique() -> void:
	const NAME: String = "14_serial不重复"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _StubFactory.new())
	var ids: Array[StringName] = []
	for i: int in range(4):
		var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(i, 0), 1)
		_check(NAME, not ids.has(placed.mechanism_id), "第 %d 个 ID 不应重复：%s。" % [i, placed.mechanism_id])
		ids.append(placed.mechanism_id)
	# 回收后再放置也应生成新 ID，不复用旧 ID。
	var first: StringName = ids[0]
	pc.recycle_placed(first)
	var placed_after := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(0, 0), 1)
	_check(NAME, placed_after.mechanism_id != first, "回收后不应复用旧 ID。")
	_check(NAME, not ids.has(placed_after.mechanism_id), "新 ID 不应与历史 ID 重复。")


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
	print("==== PlacementController 测试摘要 ====")
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
