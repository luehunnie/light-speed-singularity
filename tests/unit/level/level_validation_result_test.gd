extends SceneTree

## LevelValidationResult 定向测试（D6-A）：固化结果模型的最小只读接口与确定性排序契约。
## 覆盖：仅 WARNING 合法、任一 ERROR 非法、ERROR/WARNING 计数、get_issues 返回副本（构造入参与返回数组
##   双向隔离调用方改动）、确定性排序键序（severity→code→node_path→has_cell→cell.y→cell.x→object_id）。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")

const _GROUP_COUNT: int = 12

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 12 组后统一报告并退出。
func _initialize() -> void:
	_test_01_only_warning_valid()
	_test_02_any_error_invalid()
	_test_03_counts()
	_test_04_get_issues_isolation()
	_test_05_deterministic_sort()
	_test_06_sort_severity()
	_test_07_sort_code()
	_test_08_sort_node_path()
	_test_09_sort_has_cell()
	_test_10_sort_cell_y()
	_test_11_sort_cell_x()
	_test_12_sort_object_id()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 仅 WARNING 时 is_valid=true、has_errors=false。
func _test_01_only_warning_valid() -> void:
	const G: String = "01_仅WARNING合法"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"unexpected_tile_layer", "x", NodePath("ExtraLayer")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"legal_area_empty", "y", NodePath("LegalAreaLayer")),
	])
	_check(G, result.is_valid() == true, "仅 WARNING 期望 is_valid=true。")
	_check(G, result.has_errors() == false, "仅 WARNING 期望 has_errors=false。")
	_check(G, result.get_error_count() == 0, "仅 WARNING 期望 error_count=0。")
	_check(G, result.get_warning_count() == 2, "仅 WARNING 期望 warning_count=2，实际 %d。" % result.get_warning_count())


## 2. 任一 ERROR 时 is_valid=false、has_errors=true。
func _test_02_any_error_invalid() -> void:
	const G: String = "02_任一ERROR非法"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"unexpected_tile_layer", "x", NodePath("ExtraLayer")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"terrain_empty", "y", NodePath("TerrainLayer")),
	])
	_check(G, result.is_valid() == false, "含 ERROR 期望 is_valid=false。")
	_check(G, result.has_errors() == true, "含 ERROR 期望 has_errors=true。")


## 3. ERROR/WARNING 计数独立准确。
func _test_03_counts() -> void:
	const G: String = "03_计数准确"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"a", "", NodePath()),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"b", "", NodePath()),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"c", "", NodePath()),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"d", "", NodePath()),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"e", "", NodePath()),
	])
	_check(G, result.get_error_count() == 3, "期望 error_count=3，实际 %d。" % result.get_error_count())
	_check(G, result.get_warning_count() == 2, "期望 warning_count=2，实际 %d。" % result.get_warning_count())
	_check(G, result.get_issues().size() == 5, "期望 issues 总数=5，实际 %d。" % result.get_issues().size())


## 4. get_issues 返回副本：调用方改返回数组不污染；构造入参后续改动也不污染内部（双向隔离）。
func _test_04_get_issues_isolation() -> void:
	const G: String = "04_get_issues副本隔离"
	var i1: _LevelValidationIssue = _LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"a", "", NodePath())
	var i2: _LevelValidationIssue = _LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"b", "", NodePath())
	var result: _LevelValidationResult = _LevelValidationResult.new([i1, i2])
	# 返回数组副本：对其 clear 不影响 Result。
	var returned: Array = result.get_issues()
	returned.clear()
	_check(G, result.get_issues().size() == 2, "clear 返回数组后 Result 仍应保有 2 条，实际 %d。" % result.get_issues().size())
	# 返回数组副本：对其追加不影响 Result。
	result.get_issues().append(i1)
	_check(G, result.get_issues().size() == 2, "追加返回数组后 Result 仍应保有 2 条，实际 %d。" % result.get_issues().size())
	# 构造入参隔离：构造后改原数组不影响 Result。
	var input: Array = [i1]
	var result2: _LevelValidationResult = _LevelValidationResult.new(input)
	input.append(i2)
	_check(G, result2.get_issues().size() == 1, "改构造入参后 Result 仍应保有 1 条，实际 %d。" % result2.get_issues().size())


## 5. 确定性排序：打乱输入后输出严格按 severity→code→node_path→has_cell→cell.y→cell.x→object_id。
func _test_05_deterministic_sort() -> void:
	const G: String = "05_确定性排序"
	# 故意乱序：WARNING 在前、cell(5,3) 在 (2,1) 前、terrain_empty 夹在中间。
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"unexpected_tile_layer", "", NodePath("ExtraLayer")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"terrain_empty", "", NodePath("TerrainLayer")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"legal_outside_terrain", "", NodePath("LegalAreaLayer"), true, Vector2i(5, 3)),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"legal_outside_terrain", "", NodePath("LegalAreaLayer"), true, Vector2i(2, 1)),
	])
	var issues: Array = result.get_issues()
	# 期望序：legal_outside_terrain(2,1) → legal_outside_terrain(5,3) → terrain_empty → unexpected_tile_layer。
	_check(G, issues.size() == 4, "期望 4 条，实际 %d。" % issues.size())
	_check(G, str(issues[0].get_code()) == "legal_outside_terrain" and issues[0].get_cell() == Vector2i(2, 1), "第 1 条期望 legal_outside_terrain(2,1)。")
	_check(G, str(issues[1].get_code()) == "legal_outside_terrain" and issues[1].get_cell() == Vector2i(5, 3), "第 2 条期望 legal_outside_terrain(5,3)。")
	_check(G, str(issues[2].get_code()) == "terrain_empty", "第 3 条期望 terrain_empty，实际 %s。" % [issues[2].get_code()])
	_check(G, str(issues[3].get_code()) == "unexpected_tile_layer", "第 4 条期望 unexpected_tile_layer，实际 %s。" % [issues[3].get_code()])
	_check(G, issues[0].get_severity() == _LevelValidationIssue.Severity.ERROR, "ERROR 应排在 WARNING 前。")


## 6. 排序键 severity：同 code/node_path 下 ERROR 排在 WARNING 前。
func _test_06_sort_severity() -> void:
	const G: String = "06_排序severity"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.WARNING, &"same", "", NodePath("P")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P")),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, issues[0].get_severity() == _LevelValidationIssue.Severity.ERROR, "第 1 条期望 ERROR。")
	_check(G, issues[1].get_severity() == _LevelValidationIssue.Severity.WARNING, "第 2 条期望 WARNING。")


## 7. 排序键 code：同 severity/node_path 下 code 字典序升序。
func _test_07_sort_code() -> void:
	const G: String = "07_排序code"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"zzz_code", "", NodePath("P")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"aaa_code", "", NodePath("P")),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, str(issues[0].get_code()) == "aaa_code", "第 1 条期望 code=aaa_code。")
	_check(G, str(issues[1].get_code()) == "zzz_code", "第 2 条期望 code=zzz_code。")


## 8. 排序键 node_path：同 severity/code 下 node_path 字典序升序。
func _test_08_sort_node_path() -> void:
	const G: String = "08_排序node_path"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("Zeta")),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("Alpha")),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, str(issues[0].get_node_path()) == "Alpha", "第 1 条期望 node_path=Alpha。")
	_check(G, str(issues[1].get_node_path()) == "Zeta", "第 2 条期望 node_path=Zeta。")


## 9. 排序键 has_cell：同 severity/code/node_path 下 has_cell=false（结构级）排在 true（cell 级）前。
func _test_09_sort_has_cell() -> void:
	const G: String = "09_排序has_cell"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(0, 0)),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), false),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, issues[0].has_cell() == false, "第 1 条期望 has_cell=false。")
	_check(G, issues[1].has_cell() == true, "第 2 条期望 has_cell=true。")


## 10. 排序键 cell.y：同 severity/code/node_path/has_cell 下 cell.y 升序。
func _test_10_sort_cell_y() -> void:
	const G: String = "10_排序cell_y"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(3, 9)),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(3, 2)),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, issues[0].get_cell() == Vector2i(3, 2), "第 1 条期望 cell=(3,2)。")
	_check(G, issues[1].get_cell() == Vector2i(3, 9), "第 2 条期望 cell=(3,9)。")


## 11. 排序键 cell.x：同 severity/code/node_path/has_cell/cell.y 下 cell.x 升序。
func _test_11_sort_cell_x() -> void:
	const G: String = "11_排序cell_x"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(7, 5)),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(2, 5)),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, issues[0].get_cell() == Vector2i(2, 5), "第 1 条期望 cell=(2,5)。")
	_check(G, issues[1].get_cell() == Vector2i(7, 5), "第 2 条期望 cell=(7,5)。")


## 12. 排序键 object_id：同 severity/code/node_path/has_cell/cell 下 object_id 字典序升序。
func _test_12_sort_object_id() -> void:
	const G: String = "12_排序object_id"
	var result: _LevelValidationResult = _LevelValidationResult.new([
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(4, 4), &"z_id"),
		_LevelValidationIssue.new(_LevelValidationIssue.Severity.ERROR, &"same", "", NodePath("P"), true, Vector2i(4, 4), &"a_id"),
	])
	var issues: Array = result.get_issues()
	_check(G, issues.size() == 2, "期望 2 条，实际 %d。" % issues.size())
	_check(G, str(issues[0].get_object_id()) == "a_id", "第 1 条期望 object_id=a_id。")
	_check(G, str(issues[1].get_object_id()) == "z_id", "第 2 条期望 object_id=z_id。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelValidationResult 测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
