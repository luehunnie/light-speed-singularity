class_name SharedPlacementQuery
extends RefCounted

## Shared Placement Query（AF-03 / P0-4，Guide §17）：Editor / Runtime / Validator 共用的正式空间规则入口。
## 结果不只返回 Bool，返回 PlacementQueryResult（allowed + machine-readable reason codes）。
## 典型 reason（Guide §17 冻结命名）：OUTSIDE_TERRAIN / NOT_IN_LEGAL_AREA / WALL_BLOCKED /
## OBJECT_OCCUPIED / SHAPE_OUT_OF_BOUNDS。同一规则只实现一次：空间事实判定全部委托
## LevelWorldQuery 既有原语（is_in_bounds / is_legal_placement_cell / is_wall_cell /
## is_static_blocked_for_placement / is_occupied_by_other），本模块只负责逐格归因与结果聚合。


## reason code token。
const REASON_OUTSIDE_TERRAIN: StringName = &"OUTSIDE_TERRAIN"
const REASON_NOT_IN_LEGAL_AREA: StringName = &"NOT_IN_LEGAL_AREA"
const REASON_WALL_BLOCKED: StringName = &"WALL_BLOCKED"
const REASON_OBJECT_OCCUPIED: StringName = &"OBJECT_OCCUPIED"
const REASON_SHAPE_OUT_OF_BOUNDS: StringName = &"SHAPE_OUT_OF_BOUNDS"

const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)


## 放置查询结果：allowed + issues（machine-readable reason code 列表，按判定顺序去重）。
class PlacementQueryResult:
	var allowed: bool = false
	var issues: Array[StringName] = []

	func _init(p_allowed: bool = false, p_issues: Array[StringName] = []) -> void:
		allowed = p_allowed
		issues = p_issues

	func is_allowed() -> bool:
		return allowed


var _level_world_query: _LevelWorldQuery


## 构造共享查询；level_world_query 为唯一空间事实来源（只读使用）。
func _init(level_world_query: _LevelWorldQuery) -> void:
	_level_world_query = level_world_query


## 评估一组候选绝对占格的整体可放置性（Guide §17 统一入口）。
## [br]ignored_occupant_id 为移动/旋转中允许忽略自身既有占用的占用人 ID（其余占用仍阻止）。
## [br]空格列表 / 含重复格 → SHAPE_OUT_OF_BOUNDS；逐格归因收集全部 issue（去重保序）；
## [br]allowed 当且仅当 issues 为空；非法结果不产生任何世界状态变更（本查询只读）。
func evaluate(cells: Array[Vector2i], ignored_occupant_id: StringName = &"") -> PlacementQueryResult:
	var issues: Array[StringName] = []
	if cells.is_empty():
		issues.append(REASON_SHAPE_OUT_OF_BOUNDS)
		return PlacementQueryResult.new(false, issues)
	var seen_cells: Dictionary = {}
	var seen_issues: Dictionary = {}
	for cell: Vector2i in cells:
		if seen_cells.has(cell):
			_append_issue(issues, seen_issues, REASON_SHAPE_OUT_OF_BOUNDS)
			continue
		seen_cells[cell] = true
		_append_issue(issues, seen_issues, _reason_for_cell(cell, ignored_occupant_id))
	return PlacementQueryResult.new(issues.is_empty(), issues)


## 单格归因（判定顺序与 LevelWorldQuery.is_valid_placement_cell 一致；返回空表示该格合法）。
func _reason_for_cell(cell: Vector2i, ignored_occupant_id: StringName) -> StringName:
	if not _level_world_query.is_in_bounds(cell):
		return REASON_OUTSIDE_TERRAIN
	if not _level_world_query.is_legal_placement_cell(cell):
		return REASON_NOT_IN_LEGAL_AREA
	if _level_world_query.is_wall_cell(cell):
		return REASON_WALL_BLOCKED
	if _level_world_query.is_static_blocked_for_placement(cell):
		return REASON_OBJECT_OCCUPIED
	if _level_world_query.is_occupied_by_other(cell, ignored_occupant_id):
		return REASON_OBJECT_OCCUPIED
	return &""


## 去重保序追加 issue；空 reason（合法格）不追加。
func _append_issue(issues: Array[StringName], seen_issues: Dictionary, reason: StringName) -> void:
	if reason == &"" or seen_issues.has(reason):
		return
	seen_issues[reason] = true
	issues.append(reason)
