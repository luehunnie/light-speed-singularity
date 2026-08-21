class_name ValidationResult
extends RefCounted

## 校验结果聚合（AF-06）：私有持有不可变 ValidationIssue 列表，最小只读接口 + 确定性排序。
## is_valid / has_errors 由 issues 实时派生（不缓存布尔，避免漂移）；
## get_issues 返回数组副本，调用方增删改不污染内部列表。


const _ValidationIssue: GDScript = preload("res://gameplay/validation/validation_issue.gd")


## 内部 issues；构造时防御性复制入参并确定性排序后持有。
var _issues: Array = []


## 构造结果。副作用：复制入参（隔离调用方）并就地确定性排序。
func _init(issues: Array = []) -> void:
	_issues = issues.duplicate()
	_issues.sort_custom(Callable(self, "_compare"))


## issues 数组副本（浅拷贝；Issue 为不可变值对象，浅拷贝足以隔离）。
func get_issues() -> Array:
	return _issues.duplicate()


## 是否合法：不存在任何 ERROR 时为 true。
func is_valid() -> bool:
	return get_error_count() == 0


func has_errors() -> bool:
	return get_error_count() > 0


func get_error_count() -> int:
	var count: int = 0
	for issue in _issues:
		if issue.get_severity() == _ValidationIssue.Severity.ERROR:
			count += 1
	return count


func get_warning_count() -> int:
	var count: int = 0
	for issue in _issues:
		if issue.get_severity() == _ValidationIssue.Severity.WARNING:
			count += 1
	return count


## issues 总数。
func get_issue_count() -> int:
	return _issues.size()


## 按校验域统计 issue 数（domain token → 数量；确定性遍历）。
func count_by_domain() -> Dictionary:
	var counts: Dictionary = {}
	for issue in _issues:
		var domain: String = String(issue.get_domain())
		counts[domain] = int(counts.get(domain, 0)) + 1
	return counts


## 确定性比较（a 应否排在 b 前）：ERROR→WARNING；再依次 code、domain、
## stable_instance_id、content_type_id、definition_path、node_path、cell。
## message 不参与排序，保证结果稳定可复现。
func _compare(a, b) -> bool:
	if a.get_severity() != b.get_severity():
		return a.get_severity() < b.get_severity()
	var key_a: String = _sort_key(a)
	var key_b: String = _sort_key(b)
	if key_a != key_b:
		return key_a < key_b
	if a.has_cell() != b.has_cell():
		return not a.has_cell()
	var cell_a: Vector2i = a.get_cell()
	var cell_b: Vector2i = b.get_cell()
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	return cell_a.x < cell_b.x


## 拼 issue 排序主键（message 除外）。
func _sort_key(issue) -> String:
	return "%s|%s|%s|%s|%s" % [
		String(issue.get_code()),
		String(issue.get_domain()),
		issue.get_stable_instance_id(),
		String(issue.get_content_type_id()),
		"%s|%s" % [String(issue.get_node_path()), issue.get_definition_path()],
	]
