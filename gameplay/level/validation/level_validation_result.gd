class_name LevelValidationResult
extends RefCounted

## 关卡校验结果聚合（D6-A）：私有持有不可变 LevelValidationIssue 列表，提供最小只读接口与确定性排序。
## 不缓存 success 布尔：is_valid/has_errors 由 issues 实时派生，避免与 issues 漂移。
## get_issues 返回数组副本，调用方对返回数组的增删改不污染内部列表。

# preload 引用 Issue 类型，避开全局 class_name 缓存坑（与既有模块同款）。
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")


## 内部 issues；构造时防御性复制入参并确定性排序后持有。
var _issues: Array = []


## 构造结果。输入：issue 数组（可空，默认空）。副作用：复制入参（隔离调用方后续改动）并就地确定性排序。
func _init(issues: Array = []) -> void:
	_issues = issues.duplicate()
	_issues.sort_custom(Callable(self, "_compare"))


## 返回 issues 数组副本（浅拷贝；Issue 为不可变值对象，浅拷贝足以隔离调用方对数组的增删改）。无副作用。
func get_issues() -> Array:
	return _issues.duplicate()


## 关卡是否合法：仅当不存在任何 ERROR 时为 true。由 issues 实时派生，不缓存。
func is_valid() -> bool:
	return get_error_count() == 0


## 是否存在 ERROR。
func has_errors() -> bool:
	return get_error_count() > 0


## ERROR 数量。
func get_error_count() -> int:
	var count: int = 0
	for issue in _issues:
		if issue.get_severity() == _LevelValidationIssue.Severity.ERROR:
			count += 1
	return count


## WARNING 数量。
func get_warning_count() -> int:
	var count: int = 0
	for issue in _issues:
		if issue.get_severity() == _LevelValidationIssue.Severity.WARNING:
			count += 1
	return count


## 确定性比较（a 应否排在 b 前）：ERROR→WARNING；再依次按 code、node_path、has_cell（false 居前）、
## cell.y、cell.x、object_id。message 不参与，保证结果稳定可复现。
func _compare(a: _LevelValidationIssue, b: _LevelValidationIssue) -> bool:
	if a.get_severity() != b.get_severity():
		return a.get_severity() < b.get_severity()
	var code_a: String = str(a.get_code())
	var code_b: String = str(b.get_code())
	if code_a != code_b:
		return code_a < code_b
	var path_a: String = str(a.get_node_path())
	var path_b: String = str(b.get_node_path())
	if path_a != path_b:
		return path_a < path_b
	if a.has_cell() != b.has_cell():
		return not a.has_cell()
	var cell_a: Vector2i = a.get_cell()
	var cell_b: Vector2i = b.get_cell()
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	if cell_a.x != cell_b.x:
		return cell_a.x < cell_b.x
	return str(a.get_object_id()) < str(b.get_object_id())
