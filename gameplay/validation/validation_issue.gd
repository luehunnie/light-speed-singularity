class_name ValidationIssue
extends RefCounted

## 校验问题值对象（AF-06 / Guide §35）：machine-readable、不可变、detached。
## 单一 Validator Core 与全部机制 Rule Provider 共用本 schema；
## 不持有 Node/Resource/Callable 引用；定位字段（Go To 基础）按可用性填空串/空路径。
## 身份边界（Guide §6/§7）：stable_instance_id / content_type_id 是唯一定位身份，
##   绝不以 Node.name / NodePath / 坐标充当正式身份；node_path 仅作展示级导航辅助。


enum Severity { ERROR, WARNING }

## to_dictionary 固定键（machine-readable schema，供 Panel / Go To / 工具消费）。
const K_SEVERITY: String = "severity"
const K_CODE: String = "code"
const K_MESSAGE: String = "message"
const K_DOMAIN: String = "domain"
const K_SCOPE: String = "scope"
const K_CONTENT_TYPE_ID: String = "content_type_id"
const K_DEFINITION_PATH: String = "definition_path"
const K_STABLE_INSTANCE_ID: String = "stable_instance_id"
const K_NODE_PATH: String = "node_path"
const K_HAS_CELL: String = "has_cell"
const K_CELL: String = "cell"


## 严重级别（Severity 枚举值）；ERROR 取值小于 WARNING，排序时 ERROR 居前。
var _severity: int = Severity.WARNING
## 稳定问题码（如 definition_invalid、control_target_not_found），参与确定性排序。
var _code: StringName = &""
## 面向人类的问题说明（不参与排序，仅展示）。
var _message: String = ""
## 校验域 token（definition / id / interaction / placement / inventory / objective / control / extension）。
var _domain: StringName = &""
## 产生该问题的 Scope（project / current_level / change_set）。
var _scope: StringName = &""
## 关联定义的稳定类型身份；无关联定义为空。
var _content_type_id: StringName = &""
## 关联定义资源路径（_loaded .tres 时有效；运行期构造的定义为空串）。
var _definition_path: String = ""
## 关联实例的稳定实例身份；无关联实例为空串。
var _stable_instance_id: String = ""
## 展示级节点路径（关卡场景结构问题）；无关为空 NodePath。
var _node_path: NodePath = NodePath()
## 是否携带具体出问题格。
var _has_cell: bool = false
## 出问题的格（仅 has_cell=true 时有效；否则保持 ZERO 占位）。
var _cell: Vector2i = Vector2i.ZERO


## 构造不可变问题。定位字段按可用性填入；创建后不暴露任何修改入口。
func _init(
		severity: int,
		code: StringName,
		message: String,
		domain: StringName,
		scope: StringName,
		content_type_id: StringName = &"",
		definition_path: String = "",
		stable_instance_id: String = "",
		node_path: NodePath = NodePath(),
		has_cell: bool = false,
		cell: Vector2i = Vector2i.ZERO
) -> void:
	_severity = severity
	_code = code
	_message = message
	_domain = domain
	_scope = scope
	_content_type_id = content_type_id
	_definition_path = definition_path
	_stable_instance_id = stable_instance_id
	_node_path = node_path
	_has_cell = has_cell
	_cell = cell


## 是否具备至少一种 Go To 定位信息（类型身份 / 定义路径 / 实例身份 / 节点路径 / 格）。
func has_location() -> bool:
	return (
		_content_type_id != &""
		or not _definition_path.is_empty()
		or not _stable_instance_id.is_empty()
		or not _node_path.is_empty()
		or _has_cell
	)


## detached machine-readable 字典副本（键见 K_* 常量；不暴露内部状态引用）。
func to_dictionary() -> Dictionary:
	return {
		K_SEVERITY: _severity,
		K_CODE: String(_code),
		K_MESSAGE: _message,
		K_DOMAIN: String(_domain),
		K_SCOPE: String(_scope),
		K_CONTENT_TYPE_ID: String(_content_type_id),
		K_DEFINITION_PATH: _definition_path,
		K_STABLE_INSTANCE_ID: _stable_instance_id,
		K_NODE_PATH: String(_node_path),
		K_HAS_CELL: _has_cell,
		K_CELL: _cell,
	}


func get_severity() -> int:
	return _severity


func get_code() -> StringName:
	return _code


func get_message() -> String:
	return _message


func get_domain() -> StringName:
	return _domain


func get_scope() -> StringName:
	return _scope


func get_content_type_id() -> StringName:
	return _content_type_id


func get_definition_path() -> String:
	return _definition_path


func get_stable_instance_id() -> String:
	return _stable_instance_id


func get_node_path() -> NodePath:
	return _node_path


func has_cell() -> bool:
	return _has_cell


func get_cell() -> Vector2i:
	return _cell
