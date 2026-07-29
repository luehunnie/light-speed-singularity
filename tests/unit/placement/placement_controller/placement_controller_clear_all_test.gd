extends SceneTree

## PlacementController 单元测试（拆分片 4/4 · R 清理事务）。
## 覆盖：clear_all 全部成功、clear_all 部分失败（残留映射保留、unresolved_count 正确、库存与残留一致）。
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
	_test_14_clear_all_success()
	_test_15_clear_all_partial_failure()
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

## 14. clear_all 全部成功：placed_count=0、库存恢复满、无残留预留。
func _test_14_clear_all_success() -> void:
	const NAME: String = "14_clear_all成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), 1)
	_check(NAME, pc.get_placed_count() == 2, "前置：应已放置 2 个。")
	var r := pc.clear_all_placed()
	_check(NAME, r.removed_count == 2, "removed_count 期望 2，实际 %d。" % [r.removed_count])
	_check(NAME, r.unresolved_count == 0, "unresolved_count 期望 0，实际 %d。" % [r.unresolved_count])
	_check(NAME, pc.get_placed_count() == 0, "清理后已放置数应为 0。")
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")
	_check(NAME, inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.get_reserved_return_count() == 0, "清理后不应残留归还预留。")


## 15. clear_all 部分失败：残留映射保留、unresolved_count 正确、库存与残留数一致、无残留预留。
func _test_15_clear_all_partial_failure() -> void:
	const NAME: String = "15_clear_all部分失败"
	var occ: _Fixture._FailUnregisterForIdRegistry = _Fixture._FailUnregisterForIdRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var a := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var b := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), 1)
	occ.fail_id = a.mechanism_id
	var r := pc.clear_all_placed()
	_check(NAME, r.removed_count == 1, "removed_count 期望 1，实际 %d。" % [r.removed_count])
	_check(NAME, r.unresolved_count == 1, "unresolved_count 期望 1，实际 %d。" % [r.unresolved_count])
	_check(NAME, r.unresolved_ids.has(a.mechanism_id), "未清理 ID 应包含被锁定的机关。")
	_check(NAME, not pc.has_placed(b.mechanism_id), "可清理机关映射应已移除。")
	_check(NAME, pc.has_placed(a.mechanism_id), "未清理机关映射应保留。")
	_check(NAME, occ.has_mechanism(a.mechanism_id), "未清理机关占用应保留。")
	_check(NAME, pc.get_placed_node(a.mechanism_id) != null, "未清理机关节点应保留。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存应与残留数一致（total-1），实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.is_consistent_with_placed_count(pc.get_placed_count()), "remaining + placed_count == total 应成立。")
	_check(NAME, inv.get_reserved_return_count() == 0, "部分失败后不应残留归还预留。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 2
	var passed_checks: int = _checks - _failures.size()
	print("==== PlacementController R 清理事务 测试摘要 ====")
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
