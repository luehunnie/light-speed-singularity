extends SceneTree

## MultiTypeInventory 定向自动测试（AF-10 第三批）。
## 只通过公开接口观察：构造（顺序/重复/钳非负）、每类型独立总量与剩余、显式按类型事务
## （消费/预留/提交/取消 + 类型失配防御）、旧名 selected 路由、Σ 聚合口径、reset_to_total、
## reconcile_with_placed_count 确定性与合法性、未知类型安全。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _MultiTypeInventory: GDScript = preload(
	"res://gameplay/placement/inventory/multi_type_inventory.gd"
)

const _TYPE_A: StringName = &"type_alpha"
const _TYPE_B: StringName = &"type_beta"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_construction_order_dup_clamp()
	_test_02_per_type_independent_totals()
	_test_03_consume_for_unknown_safe()
	_test_04_legacy_names_route_selected()
	_test_05_reserve_commit_roundtrip_for_type()
	_test_06_commit_type_mismatch_rejected()
	_test_07_cancel_reserved_restores()
	_test_08_sum_aggregation()
	_test_09_reset_to_total_all_stacks()
	_test_10_reconcile_deterministic_and_legality()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 标准两类型计划：A=3（order 0）、B=2（order 1）。
func _make_two_type() -> Variant:
	return _MultiTypeInventory.new([
		{"content_type_id": "type_alpha", "initial_quantity": 3, "order": 0},
		{"content_type_id": "type_beta", "initial_quantity": 2, "order": 1},
	])


# ===== 用例 =====

## 1. 构造：展示顺序按传入序、重复类型首个为准、负数量钳 0。
func _test_01_construction_order_dup_clamp() -> void:
	const NAME: String = "01_构造顺序重复钳非负"
	var inv: Variant = _MultiTypeInventory.new([
		{"content_type_id": "type_beta", "initial_quantity": 2, "order": 5},
		{"content_type_id": "type_alpha", "initial_quantity": 3, "order": 1},
		{"content_type_id": "type_beta", "initial_quantity": 9, "order": 0},
		{"content_type_id": "type_gamma", "initial_quantity": -4, "order": 2},
	])
	var types: Array = inv.get_type_ids()
	_check(NAME, types.size() == 3, "重复类型应只建一个栈，期望 3 个类型，实际 %d。" % [types.size()])
	_check(NAME, StringName(types[0]) == _TYPE_B and StringName(types[1]) == _TYPE_A,
		"展示顺序应为传入序 beta,alpha，实际 %s。" % [str(types)])
	_check(NAME, inv.get_total_for(_TYPE_B) == 2, "重复类型应以首个数量 2 为准，实际 %d。" % [inv.get_total_for(_TYPE_B)])
	_check(NAME, inv.get_total_for(&"type_gamma") == 0, "负数量应钳为 0。")
	_check(NAME, inv.selected_type_id == _TYPE_B, "默认选中应为首个类型 beta。")
	_check(NAME, inv.has_type(_TYPE_A) and not inv.has_type(&"missing"), "has_type 应按类型判定。")


## 2. 每类型独立：扣 A 不影响 B 的总量与剩余。
func _test_02_per_type_independent_totals() -> void:
	const NAME: String = "02_每类型独立"
	var inv: Variant = _make_two_type()
	_check(NAME, inv.try_consume_one_for(_TYPE_A), "A 首次扣减应成功。")
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 2, "A 剩余期望 2，实际 %d。" % [inv.get_remaining_for(_TYPE_A)])
	_check(NAME, inv.get_remaining_for(_TYPE_B) == 2, "B 剩余应不受影响保持 2。")
	_check(NAME, inv.get_total_for(_TYPE_A) == 3 and inv.get_total_for(_TYPE_B) == 2, "总量不应随扣减变化。")


## 3. 未知类型消费安全：can/try 均 false 且不变更任何栈。
func _test_03_consume_for_unknown_safe() -> void:
	const NAME: String = "03_未知类型安全"
	var inv: Variant = _make_two_type()
	_check(NAME, not inv.can_consume_one_for(&"missing"), "未知类型 can 应 false。")
	_check(NAME, not inv.try_consume_one_for(&"missing"), "未知类型 try 应 false。")
	_check(NAME, inv.get_remaining() == 5, "失败尝试不应变更任何栈，Σ剩余期望 5。")
	_check(NAME, not inv.can_consume_one_for(&""), "空类型 can 应 false。")


## 4. 旧名单类型接口按 selected 路由；selected 为空时安全 false。
func _test_04_legacy_names_route_selected() -> void:
	const NAME: String = "04_旧名selected路由"
	var inv: Variant = _make_two_type()
	inv.selected_type_id = _TYPE_B
	_check(NAME, inv.can_consume_one(), "旧名 can 应路由到 B。")
	_check(NAME, inv.try_consume_one(), "旧名扣减应路由到 B。")
	_check(NAME, inv.get_remaining_for(_TYPE_B) == 1 and inv.get_remaining_for(_TYPE_A) == 3,
		"旧名扣减应只动 B（1），A 保持 3。")
	inv.selected_type_id = &""
	_check(NAME, not inv.can_consume_one() and not inv.try_consume_one(), "selected 为空旧名应 false。")


## 5. 两阶段归还得 type 匹配：预留→提交加回该类型；数量回满后不可再预留。
func _test_05_reserve_commit_roundtrip_for_type() -> void:
	const NAME: String = "05_归还预留提交"
	var inv: Variant = _make_two_type()
	inv.try_consume_one_for(_TYPE_A)
	inv.try_consume_one_for(_TYPE_A)
	inv.try_consume_one_for(_TYPE_A)
	inv.try_consume_one_for(_TYPE_B)
	inv.try_consume_one_for(_TYPE_B)
	_check(NAME, inv.try_reserve_return_one_for(_TYPE_A), "A 归还预留应成功。")
	_check(NAME, inv.commit_reserved_return_for(_TYPE_A), "A 归还提交应成功。")
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 1, "A 归还后剩余期望 1，实际 %d。" % [inv.get_remaining_for(_TYPE_A)])
	_check(NAME, inv.get_remaining_for(_TYPE_B) == 0, "B 应不受 A 归还影响保持 0。")
	# 提交后无遗留预留：再次提交按防御失败，数量不变。
	_check(NAME, not inv.commit_reserved_return_for(_TYPE_A), "无遗留预留时提交应防御失败。")
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 1, "防御失败提交不应变更 A 数量。")


## 6. 提交类型与锁定不一致：防御失败，数量不变。
func _test_06_commit_type_mismatch_rejected() -> void:
	const NAME: String = "06_提交类型失配防御"
	var inv: Variant = _make_two_type()
	inv.try_consume_one_for(_TYPE_A)
	_check(NAME, inv.try_reserve_return_one_for(_TYPE_A), "A 预留应成功。")
	_check(NAME, not inv.commit_reserved_return_for(_TYPE_B), "B 提交错配预留应失败。")
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 2, "失配提交不应变更 A 数量。")
	# 预留仍锁在 A：取消 A 才能解锁（不残留）。
	_check(NAME, inv.cancel_reserved_return_for(_TYPE_A), "取消锁定类型 A 应成功。")
	_check(NAME, inv.try_consume_one_for(_TYPE_A), "取消预留后 A 可再次扣减。")


## 7. 取消预留：容量解锁且数量不变；再预留→取消不叠加。
func _test_07_cancel_reserved_restores() -> void:
	const NAME: String = "07_取消预留"
	var inv: Variant = _make_two_type()
	inv.try_consume_one_for(_TYPE_A)
	inv.try_consume_one_for(_TYPE_A)
	_check(NAME, inv.try_reserve_return_one_for(_TYPE_A), "预留应成功。")
	_check(NAME, inv.cancel_reserved_return_for(_TYPE_A), "取消应成功。")
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 1, "取消后剩余保持 1。")
	_check(NAME, inv.try_reserve_return_one_for(_TYPE_A) and inv.cancel_reserved_return_for(_TYPE_A),
		"取消后应可再次预留并取消。")


## 8. Σ 聚合口径：get_total/get_remaining 为全类型求和，一致性规则 Σ 成立。
func _test_08_sum_aggregation() -> void:
	const NAME: String = "08_Σ聚合口径"
	var inv: Variant = _make_two_type()
	inv.try_consume_one_for(_TYPE_A)
	_check(NAME, inv.get_total() == 5, "Σ总量期望 5，实际 %d。" % [inv.get_total()])
	_check(NAME, inv.get_remaining() == 4, "Σ剩余期望 4，实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.is_consistent_with_placed_count(1), "Σ口径 remaining+placed==total 应成立。")
	_check(NAME, not inv.is_consistent_with_placed_count(0), "placed=1 时一致性应失败。")


## 9. reset_to_total：全部类型栈恢复满、清遗留预留；selected 保持。
func _test_09_reset_to_total_all_stacks() -> void:
	const NAME: String = "09_全量重置"
	var inv: Variant = _make_two_type()
	inv.selected_type_id = _TYPE_B
	inv.try_consume_one_for(_TYPE_A)
	inv.try_consume_one_for(_TYPE_B)
	inv.try_consume_one_for(_TYPE_B)
	inv.reset_to_total()
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 3 and inv.get_remaining_for(_TYPE_B) == 2,
		"重置后各类型应恢复满（3/2）。")
	_check(NAME, inv.selected_type_id == _TYPE_B, "重置不应改选中类型。")
	inv.try_consume_one_for(_TYPE_B)
	inv.try_reserve_return_one_for(_TYPE_B)
	inv.reset_to_total()
	# 预留清除证明：重置后扣 1 再预留应成功（若遗留 reserved=1，则 1+1>=2 会被拒）。
	_check(NAME, inv.try_consume_one_for(_TYPE_B), "重置后应可再扣减。")
	_check(NAME, inv.try_reserve_return_one_for(_TYPE_B), "重置应清除遗留归还预留。")


## 10. reconcile：Σ公式 + 展示顺序贪心确定性（扣减向/补足向）+ 越界钳制返回 false。
func _test_10_reconcile_deterministic_and_legality() -> void:
	const NAME: String = "10_重协调确定合法"
	# 扣减向：满库存（Σ5）对 placed=2 → 目标 3，差额从首个栈 A 贪心扣（A 3→1），B 保持 2。
	var inv: Variant = _make_two_type()
	_check(NAME, inv.reconcile_with_placed_count(2), "placed=2 在 [0,5] 内应合法。")
	_check(NAME, inv.get_remaining() == 3, "Σ目标应为 5-2=3，实际 %d。" % [inv.get_remaining()])
	_check(NAME, inv.get_remaining_for(_TYPE_A) == 1 and inv.get_remaining_for(_TYPE_B) == 2,
		"扣减向应从首个栈 A 贪心扣到 1（B 保持 2），实际 %d/%d。" % [inv.get_remaining_for(_TYPE_A), inv.get_remaining_for(_TYPE_B)])
	# 补足向：扣成 A=1、B=0（Σ1）对 placed=2 → 目标 3，差额按顺序先回满 A（3），B 保持 0。
	var inv2: Variant = _make_two_type()
	inv2.try_consume_one_for(_TYPE_A)
	inv2.try_consume_one_for(_TYPE_A)
	inv2.try_consume_one_for(_TYPE_B)
	inv2.try_consume_one_for(_TYPE_B)
	inv2.reconcile_with_placed_count(2)
	_check(NAME, inv2.get_remaining_for(_TYPE_A) == 3 and inv2.get_remaining_for(_TYPE_B) == 0,
		"补足向应先回满 A（3/0），实际 %d/%d。" % [inv2.get_remaining_for(_TYPE_A), inv2.get_remaining_for(_TYPE_B)])
	# 补足跨栈：Σ1 对 placed=1 → 目标 4，A 回满后 B 补到 1（顺序贪心确定性）。
	inv2.reconcile_with_placed_count(1)
	_check(NAME, inv2.get_remaining_for(_TYPE_A) == 3 and inv2.get_remaining_for(_TYPE_B) == 1,
		"跨栈补足应为 A 先回满再 B（3/1），实际 %d/%d。" % [inv2.get_remaining_for(_TYPE_A), inv2.get_remaining_for(_TYPE_B)])
	# 越界：placed=9 返回 false 且按公式钳到 Σ剩余 0；负 placed 返回 false 且目标钳满不变。
	_check(NAME, not inv2.reconcile_with_placed_count(9), "placed=9 越界应返回 false。")
	_check(NAME, inv2.get_remaining() == 0, "越界仍按公式钳到 Σ剩余 0。")
	var inv3: Variant = _make_two_type()
	_check(NAME, not inv3.reconcile_with_placed_count(-1), "placed=-1 越界应返回 false。")
	_check(NAME, inv3.get_remaining() == 5, "负 placed 目标钳满应保持 Σ5，实际 %d。" % [inv3.get_remaining()])


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== 多类型库存定向测试摘要 ====")
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
