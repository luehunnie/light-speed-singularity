class_name LevelValidationIssue
extends RefCounted

## 单条关卡校验问题（D6-A）：不可变值对象，描述一处结构或四层规则违例。
## 仅承载事实字段，不持有 Node/Resource/Callable/TileMapLayer 引用；创建后不暴露任何修改入口。
## 由 LevelValidator 构造、LevelValidationResult 聚合并确定性排序。

enum Severity { ERROR, WARNING }


## 严重级别（Severity 枚举值）；ERROR 取值小于 WARNING，排序时 ERROR 居前。
var _severity: int = Severity.WARNING
## 稳定问题码（如 terrain_empty、required_node_missing），便于上层按码归类，参与确定性排序。
var _code: StringName = &""
## 面向人类的问题说明（不参与排序，仅展示）。
var _message: String = ""
## 关联节点相对关卡根的路径；无关联节点时为空 NodePath。
var _node_path: NodePath = NodePath()
## 是否携带具体出问题格；结构级问题为 false，cell 级问题为 true。
var _has_cell: bool = false
## 出问题的格（仅 has_cell=true 时有效；结构级问题保持 Vector2i.ZERO 占位）。
var _cell: Vector2i = Vector2i.ZERO
## 关联对象 ID（稳定业务 ID，非 Node.name）。D6-B 起真实合同：
## Emitter 无稳定业务 ID，故为空；Crystal 的 Issue 在 crystal_id 非空时填 crystal_id；
## 结构/格层级且不归属稳定对象 ID 的 Issue 可为空。不得以 Node.name 作为业务 ID。
var _object_id: StringName = &""


## 构造不可变问题。输入：严重级别、问题码、说明、节点路径；has_cell 默认 false（结构级），
## cell 级问题须显式传 has_cell=true 与 cell。无副作用；创建后字段不再可变。
func _init(
		severity: int,
		code: StringName,
		message: String,
		node_path: NodePath,
		has_cell: bool = false,
		cell: Vector2i = Vector2i.ZERO,
		object_id: StringName = &""
) -> void:
	_severity = severity
	_code = code
	_message = message
	_node_path = node_path
	_has_cell = has_cell
	_cell = cell
	_object_id = object_id


func get_severity() -> int:
	return _severity


func get_code() -> StringName:
	return _code


func get_message() -> String:
	return _message


func get_node_path() -> NodePath:
	return _node_path


func has_cell() -> bool:
	return _has_cell


func get_cell() -> Vector2i:
	return _cell


func get_object_id() -> StringName:
	return _object_id
