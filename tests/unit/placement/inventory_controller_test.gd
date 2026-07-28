extends SceneTree

## InventoryController 定向自动测试：只通过公开接口观察总量、剩余、扣除/归还/重置与一致性判断。
## 不读取私有字段，不创建场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 通过 preload 引用 Controller，避开 MCP run_project 不重建全局 class_name 缓存的问题。


const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_initial_total_and_remaining()
	_test_02_consume_one_success()
	_test_03_consume_down_to_zero()
	_test_04_consume_at_zero_fails_no_negative()
	_test_05_return_one_success()
	_test_06_return_at_total_clamps()
	_test_07_reset_to_total()
	_test_08_consistent_with_placed_count()
	_test_09_inconsistent_returns_false()
	_test_10_mixed_consume_return_no_overflow()
	_test_11_reserve_success_when_returnable()
	_test_12_reserve_does_not_increase_remaining()
	_test_13_commit_increases_remaining_once()
	_test_14_commit_clears_reservation()
	_test_15_cancel_keeps_remaining()
	_test_16_cancel_clears_reservation()
	_test_17_full_inventory_cannot_reserve()
	_test_18_multiple_reserves_within_capacity()
	_test_19_commit_without_reservation_fails()
	_test_20_reset_to_total_clears_reservation()
	_test_21_reconcile_clears_reservation()
	_test_22_remaining_and_reservation_bounded()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 初始 total 与 remaining：构造后剩余等于总量。
func _test_01_initial_total_and_remaining() -> void:
	const NAME: String = "01_初始total与remaining"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.get_total() == 3, "get_total 期望 3，实际 %d。" % [c.get_total()])
	_check(NAME, c.get_remaining() == 3, "get_remaining 期望 3，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.can_consume_one() == true, "初始 can_consume_one 期望 true。")


## 成功扣除：扣除一个后剩余减一，返回 true。
func _test_02_consume_one_success() -> void:
	const NAME: String = "02_成功扣除"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "try_consume_one 期望返回 true。")
	_check(NAME, c.get_remaining() == 2, "扣除后 remaining 期望 2，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.can_consume_one() == true, "扣除后仍可继续扣除。")


## 连续扣除到 0：连续扣除 total 次后剩余为 0。
func _test_03_consume_down_to_zero() -> void:
	const NAME: String = "03_连续扣除到0"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "第 1 次扣除期望 true。")
	_check(NAME, c.try_consume_one() == true, "第 2 次扣除期望 true。")
	_check(NAME, c.try_consume_one() == true, "第 3 次扣除期望 true。")
	_check(NAME, c.get_remaining() == 0, "三次扣除后 remaining 期望 0，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.can_consume_one() == false, "剩余 0 时 can_consume_one 期望 false。")


## 0 时继续扣除失败且不变负数。
func _test_04_consume_at_zero_fails_no_negative() -> void:
	const NAME: String = "04_零库存扣除失败不变负"
	var c: _InventoryController = _InventoryController.new(1)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.get_remaining() == 0, "前置剩余期望 0。")
	_check(NAME, c.try_consume_one() == false, "零库存 try_consume_one 期望 false。")
	_check(NAME, c.get_remaining() == 0, "零库存扣除后 remaining 仍期望 0，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.can_consume_one() == false, "零库存 can_consume_one 期望 false。")


## 成功归还：扣除后归还一个，剩余加一，返回 true。
func _test_05_return_one_success() -> void:
	const NAME: String = "05_成功归还"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.get_remaining() == 2, "前置剩余期望 2。")
	_check(NAME, c.try_return_one() == true, "try_return_one 期望返回 true。")
	_check(NAME, c.get_remaining() == 3, "归还后 remaining 期望 3，实际 %d。" % [c.get_remaining()])


## 满库存继续归还的旧行为：已达总量时归还不再增加，返回 false，剩余不变。
func _test_06_return_at_total_clamps() -> void:
	const NAME: String = "06_满库存归还钳制"
	var c: _InventoryController = _InventoryController.new(2)
	_check(NAME, c.get_remaining() == 2, "前置满库存 remaining 期望 2。")
	_check(NAME, c.try_return_one() == false, "满库存 try_return_one 期望 false。")
	_check(NAME, c.get_remaining() == 2, "满库存归还后 remaining 仍期望 2，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.get_total() == 2, "满库存归还不应改变 total。")


## reset_to_total：扣除若干后重置回满库存。
func _test_07_reset_to_total() -> void:
	const NAME: String = "07_reset_to_total"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除 1 期望 true。")
	_check(NAME, c.try_consume_one() == true, "前置扣除 2 期望 true。")
	_check(NAME, c.get_remaining() == 1, "前置剩余期望 1。")
	c.reset_to_total()
	_check(NAME, c.get_remaining() == 3, "reset 后 remaining 期望 3，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.can_consume_one() == true, "reset 后可再次扣除。")


## remaining + placed_count 一致：扣除数等于已放置数时返回 true。
func _test_08_consistent_with_placed_count() -> void:
	const NAME: String = "08_一致性成立"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.is_consistent_with_placed_count(0) == true, "满库存 placed=0 期望一致。")
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.is_consistent_with_placed_count(1) == true, "remaining=2 placed=1 期望一致。")
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.is_consistent_with_placed_count(3) == true, "remaining=0 placed=3 期望一致。")


## 不一致时返回 false：remaining 与 placed_count 之和不等于 total。
func _test_09_inconsistent_returns_false() -> void:
	const NAME: String = "09_不一致返回false"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.is_consistent_with_placed_count(0) == false, "remaining=2 placed=0 期望不一致。")
	_check(NAME, c.is_consistent_with_placed_count(2) == false, "remaining=2 placed=2 期望不一致。")
	_check(NAME, c.is_consistent_with_placed_count(3) == false, "remaining=2 placed=3 期望不一致。")


## 多次扣除和归还后仍不越界：剩余始终夹在 [0, total]。
func _test_10_mixed_consume_return_no_overflow() -> void:
	const NAME: String = "10_多次扣除归还不越界"
	var c: _InventoryController = _InventoryController.new(2)
	_check(NAME, c.try_consume_one() == true, "扣除 1 期望 true。")
	_check(NAME, c.try_consume_one() == true, "扣除 2 期望 true。")
	_check(NAME, c.get_remaining() == 0, "两次扣除后期望 0。")
	_check(NAME, c.try_consume_one() == false, "零库存再扣期望 false。")
	_check(NAME, c.get_remaining() == 0, "仍期望 0，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.try_return_one() == true, "归还 1 期望 true。")
	_check(NAME, c.try_return_one() == true, "归还 2 期望 true。")
	_check(NAME, c.get_remaining() == 2, "两次归还后期望 2。")
	_check(NAME, c.try_return_one() == false, "满库存再归还期望 false。")
	_check(NAME, c.get_remaining() == 2, "仍期望 2，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.get_total() == 2, "total 不应改变。")


## 11. 可归还时预留成功：扣除后剩余 < total，预留返回 true。
func _test_11_reserve_success_when_returnable() -> void:
	const NAME: String = "11_可归还时预留成功"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "可归还时预留期望 true。")
	_check(NAME, c.get_reserved_return_count() == 1, "预留数期望 1，实际 %d。" % [c.get_reserved_return_count()])


## 12. 预留不立即增加 remaining：预留成功后 remaining 仍为扣除后的值。
func _test_12_reserve_does_not_increase_remaining() -> void:
	const NAME: String = "12_预留不立即增加remaining"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.get_remaining() == 2, "扣除后 remaining 期望 2。")
	_check(NAME, c.try_reserve_return_one() == true, "预留期望 true。")
	_check(NAME, c.get_remaining() == 2, "预留后 remaining 应不变，实际 %d。" % [c.get_remaining()])


## 13. commit 后 remaining 增加一次：预留提交后 remaining +1。
func _test_13_commit_increases_remaining_once() -> void:
	const NAME: String = "13_commit后remaining加一"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "预留期望 true。")
	_check(NAME, c.commit_reserved_return() == true, "commit 期望 true。")
	_check(NAME, c.get_remaining() == 3, "commit 后 remaining 期望 3，实际 %d。" % [c.get_remaining()])


## 14. commit 后预留清零：提交成功后 reserved_return_count 归零。
func _test_14_commit_clears_reservation() -> void:
	const NAME: String = "14_commit后预留清零"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "预留期望 true。")
	_check(NAME, c.commit_reserved_return() == true, "commit 期望 true。")
	_check(NAME, c.get_reserved_return_count() == 0, "commit 后预留应清零，实际 %d。" % [c.get_reserved_return_count()])


## 15. cancel 后 remaining 不变：取消预留不修改 remaining。
func _test_15_cancel_keeps_remaining() -> void:
	const NAME: String = "15_cancel后remaining不变"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "预留期望 true。")
	_check(NAME, c.cancel_reserved_return() == true, "cancel 期望 true。")
	_check(NAME, c.get_remaining() == 2, "cancel 后 remaining 应不变，实际 %d。" % [c.get_remaining()])


## 16. cancel 后预留清零：取消预留后 reserved_return_count 归零。
func _test_16_cancel_clears_reservation() -> void:
	const NAME: String = "16_cancel后预留清零"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "预留期望 true。")
	_check(NAME, c.cancel_reserved_return() == true, "cancel 期望 true。")
	_check(NAME, c.get_reserved_return_count() == 0, "cancel 后预留应清零，实际 %d。" % [c.get_reserved_return_count()])


## 17. 满库存不能预留：remaining == total 时预留失败。
func _test_17_full_inventory_cannot_reserve() -> void:
	const NAME: String = "17_满库存不能预留"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.get_remaining() == 3, "前置满库存。")
	_check(NAME, c.try_reserve_return_one() == false, "满库存预留期望 false。")
	_check(NAME, c.get_reserved_return_count() == 0, "失败后预留应仍为 0。")
	_check(NAME, c.get_remaining() == 3, "失败后 remaining 应不变。")


## 18. 多次预留不超过容量：可预留数等于 total - remaining，再多则失败。
func _test_18_multiple_reserves_within_capacity() -> void:
	const NAME: String = "18_多次预留不超容量"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "扣除 1 期望 true。")
	_check(NAME, c.try_consume_one() == true, "扣除 2 期望 true。")
	_check(NAME, c.get_remaining() == 1, "扣除后 remaining 期望 1。")
	_check(NAME, c.try_reserve_return_one() == true, "第 1 次预留期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "第 2 次预留期望 true。")
	_check(NAME, c.get_reserved_return_count() == 2, "预留数期望 2。")
	_check(NAME, c.try_reserve_return_one() == false, "超出容量的第 3 次预留期望 false。")
	_check(NAME, c.get_reserved_return_count() == 2, "失败后预留数应仍为 2。")


## 19. 无预留时 commit 失败：不修改 remaining，不修改预留数。
func _test_19_commit_without_reservation_fails() -> void:
	const NAME: String = "19_无预留commit失败"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.get_reserved_return_count() == 0, "前置无预留。")
	_check(NAME, c.commit_reserved_return() == false, "无预留 commit 期望 false。")
	_check(NAME, c.get_remaining() == 2, "无预留 commit 不应改变 remaining，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.get_reserved_return_count() == 0, "无预留 commit 后预留应仍为 0。")


## 20. reset_to_total 清理预留：遗留预留被清除，remaining 恢复满。
func _test_20_reset_to_total_clears_reservation() -> void:
	const NAME: String = "20_reset清理预留"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "前置预留期望 true。")
	_check(NAME, c.get_reserved_return_count() == 1, "前置预留数期望 1。")
	c.reset_to_total()
	_check(NAME, c.get_remaining() == 3, "reset 后 remaining 期望 3。")
	_check(NAME, c.get_reserved_return_count() == 0, "reset 后预留应清零，实际 %d。" % [c.get_reserved_return_count()])


## 21. reconcile_with_placed_count 清理预留：遗留预留被清除，remaining 按残留数对齐。
func _test_21_reconcile_clears_reservation() -> void:
	const NAME: String = "21_reconcile清理预留"
	var c: _InventoryController = _InventoryController.new(3)
	_check(NAME, c.try_consume_one() == true, "前置扣除期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "前置预留期望 true。")
	_check(NAME, c.get_reserved_return_count() == 1, "前置预留数期望 1。")
	_check(NAME, c.reconcile_with_placed_count(1) == true, "reconcile placed=1 期望 true。")
	_check(NAME, c.get_remaining() == 2, "reconcile 后 remaining 期望 2。")
	_check(NAME, c.get_reserved_return_count() == 0, "reconcile 后预留应清零，实际 %d。" % [c.get_reserved_return_count()])


## 22. remaining 与 reservation 始终不越界：remaining 夹在 [0, total]，预留非负且不超 total。
func _test_22_remaining_and_reservation_bounded() -> void:
	const NAME: String = "22_remaining与reservation不越界"
	var c: _InventoryController = _InventoryController.new(3)
	# 扣到 0 后多次预留仍受 total 上限钳制。
	_check(NAME, c.try_consume_one() == true, "扣除 1 期望 true。")
	_check(NAME, c.try_consume_one() == true, "扣除 2 期望 true。")
	_check(NAME, c.try_consume_one() == true, "扣除 3 期望 true。")
	_check(NAME, c.get_remaining() == 0, "remaining 期望 0。")
	_check(NAME, c.try_reserve_return_one() == true, "第 1 次预留期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "第 2 次预留期望 true。")
	_check(NAME, c.try_reserve_return_one() == true, "第 3 次预留期望 true。")
	_check(NAME, c.try_reserve_return_one() == false, "第 4 次预留期望 false（不超 total）。")
	_check(NAME, c.get_reserved_return_count() == 3, "预留数应等于 total，实际 %d。" % [c.get_reserved_return_count()])
	# 全部提交后 remaining 不超过 total，预留归零。
	_check(NAME, c.commit_reserved_return() == true, "commit 1 期望 true。")
	_check(NAME, c.commit_reserved_return() == true, "commit 2 期望 true。")
	_check(NAME, c.commit_reserved_return() == true, "commit 3 期望 true。")
	_check(NAME, c.get_remaining() == 3, "全部提交后 remaining 期望 total，实际 %d。" % [c.get_remaining()])
	_check(NAME, c.get_reserved_return_count() == 0, "全部提交后预留应清零。")
	# 无预留 cancel 安全返回 false，不修改数据。
	_check(NAME, c.cancel_reserved_return() == false, "无预留 cancel 期望 false。")
	_check(NAME, c.get_remaining() == 3, "无预留 cancel 后 remaining 应不变。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 22
	var passed_checks: int = _checks - _failures.size()
	print("==== InventoryController 测试摘要 ====")
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
