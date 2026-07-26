extends SceneTree

## StartupSelfCheckCoordinator 定向自动测试：只通过公开接口 run_all 观察七项启动自检的执行顺序、
## 成功/失败汇总、摘要日志结构与 Release/Debug 注入边界。
## 使用真实 DiagnosticsController（协调器内部构造）与最小纯数据探针（采样格、库存一致性快照），
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _StartupSelfCheckCoordinator: GDScript = preload(
	"res://gameplay/diagnostics/startup_self_check_coordinator.gd"
)
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0

# 七项执行 ID 的固定期望顺序，与原 _ready 调用顺序一致。
const _EXPECTED_ORDER: Array[StringName] = [
	&"startup_occupancy_registry",
	&"startup_grid_coordinate",
	&"startup_single_cell_mirror_reflection",
	&"startup_runtime_state_rules",
	&"startup_runtime_move_rules",
	&"startup_player_mechanism_id_snapshot",
	&"startup_inventory_consistency",
]


func _initialize() -> void:
	_test_01_debug_runs_seven_in_fixed_order()
	_test_02_all_pass_on_valid_probes()
	_test_03_any_failure_marks_summary_failed()
	_test_04_failure_does_not_falsify_success()
	_test_05_check_count_always_seven()
	_test_06_summary_log_structure_preserved()
	_test_07_release_skip_boundary_injectable()
	_test_08_does_not_modify_game_facts()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造合法库存一致性快照：total=1、remaining=1、无条目，满足 remaining + entry_count == total。
func _make_valid_snapshot() -> _InventoryConsistencySnapshot:
	var dict_ids: Array[StringName] = []
	var token_ids: Array[StringName] = []
	var token_cells: Array[Vector2i] = []
	var occ_ids: Array[StringName] = []
	var occ_counts: PackedInt32Array = PackedInt32Array()
	var occ_first: Array[Vector2i] = []
	return _InventoryConsistencySnapshot.new(
		1, 1, true,
		dict_ids, token_ids, token_cells, occ_ids, occ_counts, occ_first
	)


## 构造非法库存一致性快照：total=1、remaining=0、无条目，remaining + entry_count = 0 != 1，触发第七项失败。
func _make_invalid_snapshot() -> _InventoryConsistencySnapshot:
	var dict_ids: Array[StringName] = []
	var token_ids: Array[StringName] = []
	var token_cells: Array[Vector2i] = []
	var occ_ids: Array[StringName] = []
	var occ_counts: PackedInt32Array = PackedInt32Array()
	var occ_first: Array[Vector2i] = []
	return _InventoryConsistencySnapshot.new(
		1, 0, true,
		dict_ids, token_ids, token_cells, occ_ids, occ_counts, occ_first
	)


## 1. Debug 注入下按固定顺序执行七项。
func _test_01_debug_runs_seven_in_fixed_order() -> void:
	const NAME: String = "01_固定顺序执行七项"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_valid_snapshot(), true, false)
	_check(NAME, summary.ran, "Debug 注入应真正执行。")
	_check(NAME, summary.execution_ids.size() == 7, "应执行 7 项，实际 %d。" % [summary.execution_ids.size()])
	for index: int in range(_EXPECTED_ORDER.size()):
		var actual: StringName = summary.execution_ids[index]
		var expected: StringName = _EXPECTED_ORDER[index]
		_check(NAME, actual == expected, "第 %d 项期望 %s，实际 %s。" % [index, expected, actual])


## 2. 合法探针下七项全部通过。
func _test_02_all_pass_on_valid_probes() -> void:
	const NAME: String = "02_七项全部成功"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_valid_snapshot(), true, false)
	_check(NAME, summary.all_passed, "合法探针应全部通过。")
	_check(NAME, summary.passed_flags.size() == 7, "应记录 7 项结果，实际 %d。" % [summary.passed_flags.size()])
	for flag: bool in summary.passed_flags:
		_check(NAME, flag, "每项 passed 应为 true。")


## 3. 任一失败时汇总标记失败。
func _test_03_any_failure_marks_summary_failed() -> void:
	const NAME: String = "03_任一失败标记失败"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_invalid_snapshot(), true, false)
	_check(NAME, not summary.all_passed, "非法快照应使汇总失败。")
	_check(NAME, summary.passed_flags.size() == 7, "失败时仍应跑完 7 项，实际 %d。" % [summary.passed_flags.size()])
	# 第七项（库存一致性）应失败。
	_check(NAME, not summary.passed_flags[6], "第七项库存一致性应失败。")


## 4. 失败后不伪报全部成功。
func _test_04_failure_does_not_falsify_success() -> void:
	const NAME: String = "04_不伪报全部成功"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_invalid_snapshot(), true, false)
	_check(NAME, summary.all_passed == false, "失败时 all_passed 必须为 false，不得伪报。")
	_check(NAME, summary.summary_log_written == false, "失败时不应写摘要日志。")
	_check(NAME, summary.summary_entry == null, "失败时不应构造摘要条目。")


## 5. 汇总数量始终为七（Debug 执行与 Release 跳过两种路径）。
func _test_05_check_count_always_seven() -> void:
	const NAME: String = "05_汇总数量始终为七"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var ran_summary := coord.run_all(sample_cells, _make_valid_snapshot(), true, false)
	_check(NAME, ran_summary.check_count == 7, "Debug 执行 check_count 期望 7，实际 %d。" % [ran_summary.check_count])
	var skipped_summary := coord.run_all(sample_cells, _make_valid_snapshot(), false, false)
	_check(NAME, skipped_summary.check_count == 7, "Release 跳过 check_count 仍期望 7，实际 %d。" % [skipped_summary.check_count])


## 6. Diagnostics 摘要数据保持当前结构（severity/module/execution/message）。
func _test_06_summary_log_structure_preserved() -> void:
	const NAME: String = "06_摘要结构不变"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_valid_snapshot(), true, false)
	_check(NAME, summary.summary_log_written, "全部通过应写摘要日志。")
	_check(NAME, summary.summary_entry != null, "应构造摘要条目。")
	if summary.summary_entry != null:
		var entry: Variant = summary.summary_entry
		_check(NAME, entry.severity == 1, "severity 期望 INFO(1)，实际 %s。" % [entry.severity])
		_check(NAME, entry.module_name == &"startup_self_check", "module_name 期望 startup_self_check，实际 %s。" % [entry.module_name])
		_check(NAME, entry.execution_id == &"startup_all_self_checks", "execution_id 期望 startup_all_self_checks，实际 %s。" % [entry.execution_id])
		_check(NAME, entry.message == "七项启动自检全部通过", "message 期望固定文本，实际 %s。" % [entry.message])


## 7. Release 跳过与 Debug 执行边界可被注入测试。
func _test_07_release_skip_boundary_injectable() -> void:
	const NAME: String = "07_Release跳过边界可注入"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var summary := coord.run_all(sample_cells, _make_valid_snapshot(), false, false)
	_check(NAME, summary.ran == false, "is_debug=false 应跳过执行。")
	_check(NAME, summary.execution_ids.is_empty(), "跳过时不应执行任何项。")
	_check(NAME, summary.passed_flags.is_empty(), "跳过时不应记录任何结果。")
	_check(NAME, summary.all_passed == false, "跳过时不得伪报成功。")
	_check(NAME, summary.summary_log_written == false, "跳过时不应写摘要日志。")


## 8. 不修改游戏运行事实：传入的快照与采样格在 run_all 后内容不变。
func _test_08_does_not_modify_game_facts() -> void:
	const NAME: String = "08_不修改游戏运行事实"
	var coord: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 3)]
	var snapshot: _InventoryConsistencySnapshot = _make_valid_snapshot()
	var summary := coord.run_all(sample_cells, snapshot, true, false)
	_check(NAME, summary.ran, "应真正执行以便检验副作用。")
	# 快照标量与条目数在自检后保持不变。
	_check(NAME, snapshot.get_total_count() == 1, "快照 total_count 不应被修改。")
	_check(NAME, snapshot.get_remaining_count() == 1, "快照 remaining_count 不应被修改。")
	_check(NAME, snapshot.get_entry_count() == 0, "快照 entry_count 不应被修改。")
	# 调用方采样格数组不被修改。
	_check(NAME, sample_cells.size() == 2, "调用方采样格数组长度不应改变。")
	_check(NAME, sample_cells[0] == Vector2i.ZERO and sample_cells[1] == Vector2i(1, 3), "调用方采样格内容不应改变。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 8
	var passed_checks: int = _checks - _failures.size()
	print("==== StartupSelfCheckCoordinator 测试摘要 ====")
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
