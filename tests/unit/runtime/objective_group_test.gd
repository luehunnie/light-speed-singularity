extends SceneTree

## AF-04 / P0-6 定向测试 2/3：ObjectiveGroup 冻结语义（Guide A §15 Sequence / §16 Simultaneous）。
## Sequence 覆盖：首步无计时、按序推进、超时回滚一步并重开窗口、未来成员错误触发回滚、
##   期望成员条件错误 Hit 只算 Invalid Attempt、旧成员重 Hit 进度忽略、完成锁定直到 Reset。
## Simultaneous 覆盖：滑动窗口内全员有效即完成、旧成员超时只失效自身（其它记录保留）、
##   正确重复触发刷新时间、条件错误 Hit 不清已有记录。
## 共同覆盖：构造校验（≥2 成员 / 重复成员 / 窗口 > 0 / 非法类型）、未知成员命中忽略、reset 归零。
## 时间戳全部由测试注入（时间 seam），不读引擎时钟。


const _ObjectiveGroup: GDScript = preload("res://gameplay/objectives/objective_group.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	_test_01_create_validation()
	_test_02_sequence_first_step_no_timer()
	_test_03_sequence_advance_in_order()
	_test_04_sequence_timeout_rollback()
	_test_05_sequence_invalid_attempt_no_rollback()
	_test_06_sequence_future_hit_rollback()
	_test_07_sequence_old_member_rehit_ignored()
	_test_08_sequence_future_failed_hit_ignored()
	_test_09_sequence_lock_until_reset()
	_test_10_sequence_rollback_to_first_no_timer()
	_test_11_simultaneous_requires_all_members()
	_test_12_simultaneous_sliding_window_complete()
	_test_13_simultaneous_expiry_only_member()
	_test_14_simultaneous_repeat_refreshes()
	_test_15_simultaneous_failed_hit_keeps_records()
	_test_16_unknown_member_ignored()
	_test_17_reset_clears_state()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造三成员序列组 A→B→C（窗口 10 秒）。
func _sequence_abc() -> _ObjectiveGroup:
	var members: Array = [&"A", &"B", &"C"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members, true, 10.0)
	return group


## 1. 构造校验：非法类型 / 成员不足 / 重复成员 / 非法窗口全部拒绝；合法构造读回身份。
func _test_01_create_validation() -> void:
	const NAME: String = "01_组构造校验"
	var members: Array = [&"A", &"B"]
	_check(NAME, _ObjectiveGroup.create(5, members, true, 10.0) == null, "非法组类型 5 应拒绝。")
	_check(NAME, _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"A"], true, 10.0) == null, "单成员应拒绝（至少 2）。")
	var duplicated: Array = [&"A", &"A"]
	_check(NAME, _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, duplicated, true, 10.0) == null, "重复成员应拒绝。")
	_check(NAME, _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members, true, 0.0) == null, "窗口 0 应拒绝。")
	_check(NAME, _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members, true, -1.0) == null, "负窗口应拒绝。")
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members, true, 10.0)
	_check(NAME, group != null, "合法构造应成功。")
	if group != null:
		_check(NAME, group.get_member_ids() == [&"A", &"B"], "成员顺序应读回。")
		_check(NAME, group.is_required(), "required 应读回 true。")
		_check(NAME, group.get_window_seconds() == 10.0, "窗口应读回 10.0。")
		_check(NAME, group.get_group_type() == _ObjectiveGroup.GroupType.SEQUENCE, "类型应读回 SEQUENCE。")


## 2. Sequence 首步无等待计时：任意大时间读取期望仍是首成员。
func _test_02_sequence_first_step_no_timer() -> void:
	const NAME: String = "02_首步无等待计时"
	var group: _ObjectiveGroup = _sequence_abc()
	_check(NAME, group != null, "序列组应构造成功。")
	if group == null:
		return
	_check(NAME, group.get_expected_member_id(0.0) == &"A", "初始期望应为 A。")
	_check(NAME, group.get_expected_member_id(1000000.0) == &"A", "首步无计时，超长时间期望仍为 A。")
	_check(NAME, group.get_completed_steps(1000000.0) == 0, "首步超长等待不应回滚（无成功步骤）。")
	_check(NAME, not group.is_complete(1000000.0), "未推进不应完成。")


## 3. Sequence 按序推进：A→B→C 每步 ADVANCED，窗口为下一步重开。
func _test_03_sequence_advance_in_order() -> void:
	const NAME: String = "03_按序推进"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	_check(NAME, group.on_member_hit(&"A", true, 1.0) == _ObjectiveGroup.HitOutcome.ADVANCED, "A 正确命中应 ADVANCED。")
	_check(NAME, group.get_expected_member_id(1.5) == &"B", "推进后期望应为 B。")
	_check(NAME, group.get_completed_steps(1.5) == 1, "已完成步数应为 1。")
	_check(NAME, group.on_member_hit(&"B", true, 5.0) == _ObjectiveGroup.HitOutcome.ADVANCED, "B 正确命中应 ADVANCED。")
	_check(NAME, group.get_expected_member_id(5.5) == &"C", "推进后期望应为 C。")
	_check(NAME, group.on_member_hit(&"C", true, 8.0) == _ObjectiveGroup.HitOutcome.ADVANCED, "C 正确命中应 ADVANCED。")
	_check(NAME, group.is_locked_complete(), "末步完成应锁定。")
	_check(NAME, group.is_complete(100.0), "锁定后任意时间应完成。")


## 4. Sequence 超时回滚：等待 C 时窗口耗尽 → 回滚 B，期望退回 B 并重开窗口。
func _test_04_sequence_timeout_rollback() -> void:
	const NAME: String = "04_超时回滚一步"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	group.on_member_hit(&"B", true, 2.0)
	_check(NAME, group.get_expected_member_id(2.5) == &"C", "A、B 完成后应等待 C。")
	_check(NAME, group.get_completed_steps(2.5) == 2, "已完成步数应为 2。")
	# C 的窗口自 2.0 起算，10 秒窗口在 12.0 耗尽；12.5 读取触发回滚：移除 B，期望退回 B。
	_check(NAME, group.get_expected_member_id(12.5) == &"B", "超时应回滚一步，期望退回 B。")
	_check(NAME, group.get_completed_steps(12.5) == 1, "超时后已完成步数应为 1。")
	_check(NAME, not group.is_complete(12.5), "回滚后不应完成。")
	# 回滚后 B 的窗口自读取时刻 12.5 重开；20.0 再次读取窗口未耗尽（12.5+10=22.5）不应再回滚。
	_check(NAME, group.get_expected_member_id(20.0) == &"B", "回滚重开窗口内不应再次回滚。")
	_check(NAME, group.get_completed_steps(20.0) == 1, "窗口内已完成步数应保持 1。")


## 5. Sequence Invalid Attempt：期望成员条件错误 Hit 只算无效尝试，不回滚、计时继续。
func _test_05_sequence_invalid_attempt_no_rollback() -> void:
	const NAME: String = "05_条件错误Hit不回滚"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	_check(NAME, group.on_member_hit(&"B", false, 3.0) == _ObjectiveGroup.HitOutcome.INVALID_ATTEMPT, "期望成员失败命中应 INVALID_ATTEMPT。")
	_check(NAME, group.get_expected_member_id(3.5) == &"B", "无效尝试后期望应仍为 B。")
	_check(NAME, group.get_completed_steps(3.5) == 1, "无效尝试不应回滚已完成步数。")
	# 计时继续：B 的窗口自 0.0 起算，9.5+10=10.0 边界内仍在窗口中。
	_check(NAME, group.get_expected_member_id(9.5) == &"B", "窗口边界内计时继续，不应回滚。")


## 6. Sequence 未来成员错误触发：期望 B 时 C 通过条件命中 → 回滚一步退回 A（移除 A 的成功）。
func _test_06_sequence_future_hit_rollback() -> void:
	const NAME: String = "06_未来成员触发回滚"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	_check(NAME, group.on_member_hit(&"C", true, 1.0) == _ObjectiveGroup.HitOutcome.ROLLED_BACK, "未来成员正确命中应 ROLLED_BACK。")
	_check(NAME, group.get_expected_member_id(1.5) == &"A", "回滚后期望应退回 A。")
	_check(NAME, group.get_completed_steps(1.5) == 0, "回滚后已完成步数应为 0。")


## 7. Sequence 旧成员重 Hit：进度忽略（不推进不回滚）。
func _test_07_sequence_old_member_rehit_ignored() -> void:
	const NAME: String = "07_旧成员重Hit忽略"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	_check(NAME, group.on_member_hit(&"A", true, 4.0) == _ObjectiveGroup.HitOutcome.IGNORED, "已完成旧成员重 Hit 应 IGNORED。")
	_check(NAME, group.get_expected_member_id(4.5) == &"B", "旧成员重 Hit 后期望应仍为 B。")
	_check(NAME, group.get_completed_steps(4.5) == 1, "旧成员重 Hit 不应改变步数。")


## 8. Sequence 非期望成员失败命中：不构成触发，进度忽略。
func _test_08_sequence_future_failed_hit_ignored() -> void:
	const NAME: String = "08_未来成员失败Hit忽略"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	_check(NAME, group.on_member_hit(&"C", false, 1.0) == _ObjectiveGroup.HitOutcome.IGNORED, "未来成员失败命中应 IGNORED。")
	_check(NAME, group.get_expected_member_id(1.5) == &"B", "失败命中不应回滚。")
	_check(NAME, group.get_completed_steps(1.5) == 1, "失败命中不应改变步数。")


## 9. Sequence 完成锁定：锁定后旧命中与超时均不影响完成直到 Reset。
func _test_09_sequence_lock_until_reset() -> void:
	const NAME: String = "09_完成锁定直到Reset"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	group.on_member_hit(&"B", true, 1.0)
	group.on_member_hit(&"C", true, 2.0)
	_check(NAME, group.is_locked_complete(), "全部完成应锁定。")
	_check(NAME, group.on_member_hit(&"A", true, 100.0) == _ObjectiveGroup.HitOutcome.IGNORED, "锁定后命中应 IGNORED。")
	_check(NAME, group.is_complete(1000000.0), "锁定后超长时间仍应完成。")
	group.reset_runtime()
	_check(NAME, not group.is_locked_complete(), "Reset 后应解除锁定。")
	_check(NAME, group.get_expected_member_id(0.0) == &"A", "Reset 后期望应回到 A。")
	_check(NAME, not group.is_complete(0.0), "Reset 后不应完成。")


## 10. Sequence 回滚退回首步：首步无等待计时（回滚后长时间等待不再回滚）。
func _test_10_sequence_rollback_to_first_no_timer() -> void:
	const NAME: String = "10_回滚退回首步无计时"
	var group: _ObjectiveGroup = _sequence_abc()
	if group == null:
		_check(NAME, false, "序列组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	group.on_member_hit(&"C", true, 1.0)
	_check(NAME, group.get_expected_member_id(1.5) == &"A", "回滚后期望应为 A。")
	_check(NAME, group.get_expected_member_id(1000000.0) == &"A", "退回首步后无等待计时，期望仍为 A。")
	_check(NAME, group.get_completed_steps(1000000.0) == 0, "退回首步后步数应保持 0。")


## 11. Simultaneous：任一成员无记录即未完成；全员记录后完成。
func _test_11_simultaneous_requires_all_members() -> void:
	const NAME: String = "11_全员记录才完成"
	var members: Array = [&"X", &"Y"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 10.0)
	_check(NAME, group != null, "同时组应构造成功。")
	if group == null:
		return
	_check(NAME, not group.is_complete(0.0), "无记录不应完成。")
	group.on_member_hit(&"X", true, 1.0)
	_check(NAME, not group.is_complete(1.5), "单成员记录不应完成。")
	group.on_member_hit(&"Y", true, 2.0)
	_check(NAME, group.is_complete(2.5), "全员记录应完成。")


## 12. Simultaneous 滑动窗口：全员最近完成时间须同窗（以读取时刻为窗口终点）。
func _test_12_simultaneous_sliding_window_complete() -> void:
	const NAME: String = "12_滑动窗口判定"
	var members: Array = [&"X", &"Y", &"Z"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, false, 10.0)
	if group == null:
		_check(NAME, false, "同时组构造失败。")
		return
	group.on_member_hit(&"X", true, 0.0)
	group.on_member_hit(&"Y", true, 1.0)
	group.on_member_hit(&"Z", true, 2.0)
	_check(NAME, group.is_complete(9.0), "全员在窗内（最旧 0.0，now=9.0 距离 9 ≤ 10）应完成。")
	_check(NAME, not group.is_complete(10.5), "X 过期（now=10.5 距 0.0 > 10）不应完成。")


## 13. Simultaneous 旧成员超时只失效自身：其它成员有效记录保留并可经刷新恢复完成。
func _test_13_simultaneous_expiry_only_member() -> void:
	const NAME: String = "13_过期只失效自身"
	var members: Array = [&"X", &"Y"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 5.0)
	if group == null:
		_check(NAME, false, "同时组构造失败。")
		return
	group.on_member_hit(&"X", true, 0.0)
	group.on_member_hit(&"Y", true, 1.0)
	_check(NAME, group.get_member_last_success(&"X") == 0.0, "X 最近完成时间应读回 0.0。")
	_check(NAME, group.get_member_last_success(&"Y") == 1.0, "Y 最近完成时间应读回 1.0。")
	_check(NAME, group.get_member_last_success(&"Q") == -1.0, "未知/无记录成员应返回 -1.0。")
	# now=6.0：X 距 0.0 已 6 > 5 过期；Y 距 1.0 为 5 ≤ 5 仍有效。
	_check(NAME, not group.is_complete(6.0), "X 过期不应完成。")
	_check(NAME, group.get_member_last_success(&"Y") == 1.0, "Y 有效记录应保留。")
	# 刷新过期成员 X 后全员重新同窗。
	group.on_member_hit(&"X", true, 6.0)
	group.on_member_hit(&"Y", true, 6.0)
	_check(NAME, group.is_complete(6.5), "刷新过期成员后应重新完成。")


## 14. Simultaneous 正确重复触发刷新该成员时间。
func _test_14_simultaneous_repeat_refreshes() -> void:
	const NAME: String = "14_重复触发刷新时间"
	var members: Array = [&"X", &"Y"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 3.0)
	if group == null:
		_check(NAME, false, "同时组构造失败。")
		return
	group.on_member_hit(&"X", true, 0.0)
	group.on_member_hit(&"Y", true, 1.0)
	_check(NAME, group.is_complete(1.5), "初始应完成。")
	group.on_member_hit(&"X", true, 4.0)
	_check(NAME, group.get_member_last_success(&"X") == 4.0, "重复触发应刷新 X 时间为 4.0。")
	_check(NAME, group.is_complete(4.0), "刷新后 Y 距 1.0 恰 3 ≤ 3 仍同窗，应完成。")
	_check(NAME, not group.is_complete(8.0), "全员距最近成功超 3 后不应完成。")


## 15. Simultaneous 条件错误 Hit：不清已有记录、不缩短剩余状态。
func _test_15_simultaneous_failed_hit_keeps_records() -> void:
	const NAME: String = "15_错误Hit不清记录"
	var members: Array = [&"X", &"Y"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 10.0)
	if group == null:
		_check(NAME, false, "同时组构造失败。")
		return
	group.on_member_hit(&"X", true, 0.0)
	group.on_member_hit(&"Y", true, 0.5)
	_check(NAME, group.on_member_hit(&"X", false, 1.0) == _ObjectiveGroup.HitOutcome.IGNORED, "失败命中应 IGNORED。")
	_check(NAME, group.get_member_last_success(&"X") == 0.0, "失败命中不应清除 X 记录。")
	_check(NAME, group.is_complete(1.0), "失败命中后仍应完成。")


## 16. 未知成员命中：两种组类型均忽略，零副作用。
func _test_16_unknown_member_ignored() -> void:
	const NAME: String = "16_未知成员忽略"
	var members: Array = [&"A", &"B"]
	var sequence: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members, true, 10.0)
	if sequence == null:
		_check(NAME, false, "序列组构造失败。")
		return
	_check(NAME, sequence.on_member_hit(&"Q", true, 0.0) == _ObjectiveGroup.HitOutcome.IGNORED, "序列组未知成员应 IGNORED。")
	_check(NAME, sequence.get_expected_member_id(0.0) == &"A", "未知成员命中不应改变期望。")
	var simultaneous: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 10.0)
	if simultaneous == null:
		_check(NAME, false, "同时组构造失败。")
		return
	_check(NAME, simultaneous.on_member_hit(&"Q", true, 0.0) == _ObjectiveGroup.HitOutcome.IGNORED, "同时组未知成员应 IGNORED。")
	_check(NAME, not simultaneous.is_complete(0.0), "未知成员命中不应完成。")


## 17. Reset：Sequence 与 Simultaneous 状态全部归零，身份结构不变。
func _test_17_reset_clears_state() -> void:
	const NAME: String = "17_Reset归零"
	var members: Array = [&"A", &"B"]
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, members, true, 10.0)
	if group == null:
		_check(NAME, false, "同时组构造失败。")
		return
	group.on_member_hit(&"A", true, 0.0)
	group.on_member_hit(&"B", true, 0.5)
	_check(NAME, group.is_complete(1.0), "Reset 前应完成。")
	group.reset_runtime()
	_check(NAME, not group.is_complete(1.0), "Reset 后不应完成。")
	_check(NAME, group.get_member_last_success(&"A") == -1.0, "Reset 后成员记录应清空。")
	_check(NAME, group.get_member_ids() == [&"A", &"B"], "Reset 不应改变成员结构。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 17
	var passed_checks: int = _checks - _failures.size()
	print("objective_group_test： %d/%d 组通过，%d/%d 断言通过。" % [group_count - _failures.size(), group_count, passed_checks, _checks])
	if not _failures.is_empty():
		for failure: String in _failures:
			print("  失败：%s" % [failure])
