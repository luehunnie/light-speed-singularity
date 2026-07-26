extends SceneTree

## OccupancyRegistry 定向自动测试：只通过公开接口观察 register/unregister/move_single_cell 的事实与原子性。
## 验证原子移动校验在前、更新在后，失败不修改任何事实，不出现“先注销后恢复”中间态。
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_move_single_cell_success()
	_test_02_move_clears_source_cell()
	_test_03_move_assigns_target_to_mechanism()
	_test_04_move_source_not_owned_fails_unchanged()
	_test_05_move_target_occupied_fails_unchanged()
	_test_06_move_empty_id_rejected()
	_test_07_move_failure_keeps_source()
	_test_08_move_same_cell_rejected()
	_test_09_move_unregistered_mechanism_rejected()
	_test_10_move_preserves_index_consistency()
	_test_11_register_unregister_baseline()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 合法单格原子移动：返回 true。
func _test_01_move_single_cell_success() -> void:
	const NAME: String = "01_合法原子移动"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(2, 2)) == true, "合法移动期望 true。")


## 2. 移动后旧格为空：source 不再被任何机关占用。
func _test_02_move_clears_source_cell() -> void:
	const NAME: String = "02_移动后旧格为空"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(2, 2)) == true, "移动期望 true。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"", "旧格应为空，实际 %s。" % [r.get_mechanism_at(Vector2i(1, 1))])
	_check(NAME, not r.has_mechanism_at(Vector2i(1, 1)), "旧格不应再被占用。")


## 3. 移动后新格归原 mechanism：target 指向同一机关 ID。
func _test_03_move_assigns_target_to_mechanism() -> void:
	const NAME: String = "03_新格归原mechanism"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(2, 2)) == true, "移动期望 true。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"m1", "新格应指向 m1。")
	_check(NAME, r.get_cells_of(&"m1") == [Vector2i(2, 2)], "机关占用列表应只含新格，实际 %s。" % [r.get_cells_of(&"m1")])


## 4. source 不属于该 mechanism 时失败且事实不变。
func _test_04_move_source_not_owned_fails_unchanged() -> void:
	const NAME: String = "04_source不属于该mechanism失败"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	# m1 实际在 (1,1)，传入错误 source (5,5) 应失败。
	_check(NAME, r.move_single_cell(&"m1", Vector2i(5, 5), Vector2i(2, 2)) == false, "错误 source 期望 false。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"m1", "原占用应保持。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"", "新格不应被写入。")
	_check(NAME, r.get_cells_of(&"m1") == [Vector2i(1, 1)], "机关占用列表应不变。")


## 5. target 已占用时失败且事实不变。
func _test_05_move_target_occupied_fails_unchanged() -> void:
	const NAME: String = "05_target已占用失败"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	_check(NAME, r.register_single_cell(&"m2", Vector2i(2, 2)), "前置登记 m2 应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(2, 2)) == false, "目标被占期望 false。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"m1", "m1 原占用应保持。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"m2", "m2 占用应保持。")
	_check(NAME, r.get_cells_of(&"m1") == [Vector2i(1, 1)], "m1 占用列表应不变。")


## 6. 空 mechanism_id 拒绝：返回 false 且不写入。
func _test_06_move_empty_id_rejected() -> void:
	const NAME: String = "06_空ID拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	_check(NAME, r.move_single_cell(&"", Vector2i(1, 1), Vector2i(2, 2)) == false, "空 ID 期望 false。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"m1", "原占用应保持。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"", "新格不应被写入。")


## 7. 原子移动失败后旧格仍保持：失败不丢失源占用，证明无“先注销后恢复”中间态。
func _test_07_move_failure_keeps_source() -> void:
	const NAME: String = "07_失败后旧格保持"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	# 目标被占导致失败。
	_check(NAME, r.register_single_cell(&"m2", Vector2i(2, 2)), "前置登记 m2 应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(2, 2)) == false, "目标被占期望 false。")
	_check(NAME, r.has_mechanism_at(Vector2i(1, 1)), "失败后旧格应仍被占用。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"m1", "失败后旧格应仍指向 m1。")


## 8. 不出现需要恢复旧占用的中间态：移动失败时 source 从未被擦除（直接查询未中断的占用）。
func _test_08_move_same_cell_rejected() -> void:
	const NAME: String = "08_原格移动被拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	# source == target 不视为成功移动，返回 false，事实不变。
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(1, 1)) == false, "原格移动期望 false。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"m1", "原格拒绝后占用应保持。")
	_check(NAME, r.get_cells_of(&"m1") == [Vector2i(1, 1)], "占用列表应不变。")


## 9. 未登记机关移动被拒绝：返回 false 且不写入。
func _test_09_move_unregistered_mechanism_rejected() -> void:
	const NAME: String = "09_未登记mechanism拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.move_single_cell(&"ghost", Vector2i(1, 1), Vector2i(2, 2)) == false, "未登记机关期望 false。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 1)) == &"", "源格不应被写入。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"", "目标格不应被写入。")


## 10. 移动后正向与反向索引保持一致：is_consistent 返回 true。
func _test_10_move_preserves_index_consistency() -> void:
	const NAME: String = "10_移动后索引一致"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "前置登记 m1 应成功。")
	_check(NAME, r.register_single_cell(&"m2", Vector2i(3, 3)), "前置登记 m2 应成功。")
	_check(NAME, r.move_single_cell(&"m1", Vector2i(1, 1), Vector2i(4, 4)) == true, "移动 m1 期望 true。")
	_check(NAME, r.is_consistent(), "移动后两向索引应一致。")
	# 多次移动后仍一致。
	_check(NAME, r.move_single_cell(&"m2", Vector2i(3, 3), Vector2i(1, 1)) == true, "移动 m2 到 m1 旧格期望 true。")
	_check(NAME, r.is_consistent(), "再次移动后两向索引应一致。")


## 11. 基线：register/unregister/clear 既有行为不回归。
func _test_11_register_unregister_baseline() -> void:
	const NAME: String = "11_register基线不回归"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(1, 1)), "登记应成功。")
	_check(NAME, not r.register_single_cell(&"m2", Vector2i(1, 1)), "重复占用同格应被拒绝。")
	_check(NAME, not r.register_single_cell(&"m1", Vector2i(2, 2)), "同 ID 重复登记应被拒绝。")
	_check(NAME, r.unregister(&"m1"), "解除已登记机关应成功。")
	_check(NAME, not r.unregister(&"m1"), "重复解除应返回 false。")
	_check(NAME, r.is_consistent(), "基线操作后应一致。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 11
	var passed_checks: int = _checks - _failures.size()
	print("==== OccupancyRegistry 测试摘要 ====")
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
