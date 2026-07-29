extends SceneTree

## PlacementController 单元测试（拆分片 1/4 · 新放置事务与稳定 ID）。
## 覆盖：新机关放置成功、非法格放置、节点创建/占用登记/库存扣除失败回滚，以及 serial ID 唯一与回收后不复用。
## 只通过公开接口观察事务结果与原子回滚；桩与装配见 fixtures/placement_flow_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 失败路径用例会产生预期 push_error 输出，不计入失败。

const _PlacementController: GDScript = preload(
	"res://gameplay/placement/placement_controller.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
const _Fixture: GDScript = preload(
	"res://tests/unit/placement/fixtures/placement_flow_fixture.gd"
)

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"
const _TOTAL: int = 3

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 持有装配夹具，避免工厂 RefCounted 在 Callable 单引用下被提前回收导致 null::create。
var _fixture: _Fixture = null


func _initialize() -> void:
	_fixture = _Fixture.new()
	_test_01_place_from_inventory_success()
	_test_02_place_invalid_cell_no_change()
	_test_03_place_node_creation_failure_rollback()
	_test_04_place_occupancy_register_failure_rollback()
	_test_05_place_inventory_consume_failure_rollback()
	_test_17_serial_ids_unique()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 装配 =====

## 构造已注入 LevelWorldQuery 的控制器；occupancy/inventory/factory 由调用方提供。
func _make_controller(
		occupancy: _OccupancyRegistry,
		inventory: _InventoryController,
		factory: _Fixture._StubFactory
) -> _PlacementController:
	return _fixture.make_controller(self, occupancy, inventory, factory)


# ===== 测试用例 =====

## 1. 新机关放置成功：占用存在、映射存在、库存减一。
func _test_01_place_from_inventory_success() -> void:
	const NAME: String = "01_放置成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
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
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
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
	var factory: _Fixture._StubFactory = _Fixture._StubFactory.new()
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
	var occ: _Fixture._FailRegisterForCellRegistry = _Fixture._FailRegisterForCellRegistry.new()
	occ.fail_cell = Vector2i(1, 1)
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var factory: _Fixture._StubFactory = _Fixture._StubFactory.new()
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
	var inv: _Fixture._FailConsumeInventory = _Fixture._FailConsumeInventory.new(_TOTAL)
	var factory: _Fixture._StubFactory = _Fixture._StubFactory.new()
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var r := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, pc.get_placed_count() == 0, "映射应已回滚为空。")
	_check(NAME, not occ.has_mechanism(r.mechanism_id), "占用应已回滚。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [inv.get_remaining()])
	_check(NAME, factory.created_tokens.size() == 1, "应已创建一个节点。")
	_check(NAME, factory.created_tokens[0].is_queued_for_deletion(), "节点应已回滚清理。")


## 17. serial 生成的 ID 不重复（与放置事务相邻：ID 在放置时生成，回收后不复用）。
func _test_17_serial_ids_unique() -> void:
	const NAME: String = "17_serial不重复"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
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
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== PlacementController 新放置事务 测试摘要 ====")
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
