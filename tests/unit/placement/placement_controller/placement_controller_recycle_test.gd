extends SceneTree

## PlacementController 单元测试（拆分片 3/4 · 回收事务）。
## 覆盖：回收成功无预留残留、注销失败取消预留、预留失败保持全部、提交归还失败（不变量破坏）。
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
	_test_10_recycle_success_no_reservation_residue()
	_test_11_recycle_unregister_failure_cancel_reservation()
	_test_12_recycle_reserve_failure_keep_all()
	_test_13_recycle_commit_failure_after_destroy()
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

## 10. 回收成功：占用、映射移除、库存加一，且无残留归还预留。
func _test_10_recycle_success_no_reservation_residue() -> void:
	const NAME: String = "10_回收成功无预留残留"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s（%s）。" % [r.status, r.error_message])
	_check(NAME, not occ.has_mechanism(placed.mechanism_id), "占用应已移除。")
	_check(NAME, not pc.has_placed(placed.mechanism_id), "映射应已移除。")
	_check(NAME, pc.get_placed_count() == 0, "已放置数应为 0。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.get_reserved_return_count() == 0, "成功回收后不应残留归还预留。")


## 11. 回收注销失败：取消预留，节点/映射/占用/库存全部保持。
func _test_11_recycle_unregister_failure_cancel_reservation() -> void:
	const NAME: String = "11_回收注销失败取消预留"
	var occ: _Fixture._FailUnregisterForIdRegistry = _Fixture._FailUnregisterForIdRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	occ.fail_id = placed.mechanism_id
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, r.error_message == "注销占用失败", "期望错误为“注销占用失败”，实际 %s。" % [r.error_message])
	_check(NAME, pc.has_placed(placed.mechanism_id), "映射应保持。")
	_check(NAME, occ.has_mechanism(placed.mechanism_id), "占用应保持。")
	_check(NAME, pc.get_placed_node(placed.mechanism_id) != null, "节点应保持。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应不变，实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.get_reserved_return_count() == 0, "注销失败应取消预留，不残留。")


## 12. 回收预留失败：节点/映射/占用/库存完全保持，不销毁节点。
func _test_12_recycle_reserve_failure_keep_all() -> void:
	const NAME: String = "12_回收预留失败保持"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _Fixture._FailReserveInventory = _Fixture._FailReserveInventory.new(_TOTAL)
	var factory: _Fixture._StubFactory = _Fixture._StubFactory.new()
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, r.error_message == "库存归还预留失败", "期望错误为“库存归还预留失败”，实际 %s。" % [r.error_message])
	_check(NAME, pc.has_placed(placed.mechanism_id), "预留失败应保留映射。")
	_check(NAME, occ.has_mechanism(placed.mechanism_id), "预留失败应保留占用。")
	_check(NAME, pc.get_placed_node(placed.mechanism_id) != null, "预留失败应保留节点。")
	_check(NAME, not factory.created_tokens[0].is_queued_for_deletion(), "预留失败不应销毁节点。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应不变。")
	_check(NAME, inv.get_reserved_return_count() == 0, "预留失败不应残留预留。")


## 13. 回收提交归还失败（预留已锁定后的不变量破坏）：FAILED，映射已清节点已销毁、库存未增。
func _test_13_recycle_commit_failure_after_destroy() -> void:
	const NAME: String = "13_回收提交归还失败"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _Fixture._FailCommitReturnInventory = _Fixture._FailCommitReturnInventory.new(_TOTAL)
	var factory: _Fixture._StubFactory = _Fixture._StubFactory.new()
	var pc: _PlacementController = _make_controller(occ, inv, factory)
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "前置：放置后剩余应为 %d。" % [_TOTAL - 1])
	var r := pc.recycle_placed(placed.mechanism_id)
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, r.error_message == "库存归还提交失败", "期望错误为“库存归还提交失败”，实际 %s。" % [r.error_message])
	_check(NAME, not pc.has_placed(placed.mechanism_id), "提交失败前映射已删除。")
	_check(NAME, not occ.has_mechanism(placed.mechanism_id), "提交失败前占用已注销。")
	_check(NAME, factory.created_tokens[0].is_queued_for_deletion(), "提交失败前节点已请求销毁。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "提交失败库存不应增加，实际 %d。" % [inv.get_remaining()])
	_check(NAME, not inv.is_consistent_with_placed_count(pc.get_placed_count()), "remaining + placed != total 应由一致性断言暴露。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 4
	var passed_checks: int = _checks - _failures.size()
	print("==== PlacementController 回收事务 测试摘要 ====")
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
