extends SceneTree

## PlacementController 单元测试（拆分片 2/4 · 已放置对象移动事务）。
## 覆盖：移动成功、原格 NO_CHANGE、原子占用迁移失败保持原格、目标被占 INVALID、移动后 orientation 保持。
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
	_test_06_move_success()
	_test_07_move_same_cell_no_change()
	_test_08_move_atomic_failure_keep_old()
	_test_09_move_target_occupied_invalid()
	_test_16_move_preserves_orientation()
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

## 6. 移动成功：旧占用移除、新占用成立、节点位置更新、consumes_runtime_move=true。
func _test_06_move_success() -> void:
	const NAME: String = "06_移动成功"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
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
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(1, 1))
	_check(NAME, r.status == _PlacementController.Status.NO_CHANGE, "期望 NO_CHANGE，实际 %s。" % [r.status])
	_check(NAME, r.consumes_runtime_move == false, "原格不应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "占用应保持不变。")


## 8. 原子占用迁移失败：节点保持原格、旧占用不丢失、不消耗移动次数；证明不存在“先注销后恢复”中间态。
func _test_08_move_atomic_failure_keep_old() -> void:
	const NAME: String = "08_原子移动失败保持原格"
	var occ: _Fixture._FailMoveRegistry = _Fixture._FailMoveRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: Variant = pc.get_placed_node(placed.mechanism_id)
	occ.fail_move = true
	var r := pc.move_placed(placed.mechanism_id, Vector2i(3, 3))
	_check(NAME, r.status == _PlacementController.Status.FAILED, "期望 FAILED，实际 %s。" % [r.status])
	_check(NAME, r.error_message == "原子占用迁移失败", "期望错误为“原子占用迁移失败”，实际 %s。" % [r.error_message])
	_check(NAME, r.consumes_runtime_move == false, "失败事务不应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "旧占用应保持，不出现注销后丢失。")
	_check(NAME, occ.get_mechanism_at(Vector2i(3, 3)) == &"", "新占用不应成立。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应保持原格，实际 %s。" % [token.cell])
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "失败移动不应改变库存，实际 %d。" % [inv.get_remaining()])


## 9. 目标格已被其他机关占用：INVALID，节点保持原格、占用不变。
func _test_09_move_target_occupied_invalid() -> void:
	const NAME: String = "09_目标被占INVALID"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: Variant = pc.get_placed_node(placed.mechanism_id)
	occ.register_single_cell(&"blocker", Vector2i(3, 3))
	var r := pc.move_placed(placed.mechanism_id, Vector2i(3, 3))
	_check(NAME, r.status == _PlacementController.Status.INVALID, "期望 INVALID，实际 %s。" % [r.status])
	_check(NAME, r.consumes_runtime_move == false, "INVALID 不应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保持。")
	_check(NAME, occ.get_mechanism_at(Vector2i(3, 3)) == &"blocker", "阻挡机关占用应保持。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应保持原格。")


## 16. orientation 在移动后保持。
func _test_16_move_preserves_orientation() -> void:
	const NAME: String = "16_移动后orientation保持"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv, _Fixture._StubFactory.new())
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._StubToken = pc.get_placed_node(placed.mechanism_id) as _Fixture._StubToken
	token.set_orientation(2)
	var r := pc.move_placed(placed.mechanism_id, Vector2i(4, 4))
	_check(NAME, r.is_success(), "期望 SUCCESS，实际 %s。" % [r.status])
	_check(NAME, token.orientation == 2, "移动后 orientation 应保持为 2，实际 %s。" % [token.orientation])
	_check(NAME, token.cell == Vector2i(4, 4), "节点应已移至目标格。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== PlacementController 移动事务 测试摘要 ====")
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
