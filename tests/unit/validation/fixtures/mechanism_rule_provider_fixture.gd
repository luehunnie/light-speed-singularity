extends "res://gameplay/validation/validation_rule_provider.gd"

## AF-06 测试 fixture：机制特有只读 Rule Provider 示例（光屏障式局部规则）。
## 证明扩展点可独立注册：自定义 provider_id + 监听类型 + 禁格，只读遍历对象注册表，
## 命中即返回带 stable_instance_id + cell 定位的 WARNING（Go To 可用）；
## 记录收到的 scope / context 供测试观察，绝不修改传入上下文。


const _ValidationIssue: GDScript = preload("res://gameplay/validation/validation_issue.gd")
const _ValidatorCore: GDScript = preload("res://gameplay/validation/validator_core.gd")


var _provider_id: StringName = &""
var _watched_type_id: StringName = &""
var _forbidden_cell: Vector2i = Vector2i.ZERO
## 测试观察面：本 Provider 被 Core 询问过的 scope 序列。
var received_scopes: Array = []
## 测试观察面：最近一次收到的 context（detached 引用，仅只读断言用）。
var last_context: Dictionary = {}


func _init(provider_id: StringName, watched_type_id: StringName, forbidden_cell: Vector2i) -> void:
	_provider_id = provider_id
	_watched_type_id = watched_type_id
	_forbidden_cell = forbidden_cell


func get_provider_id() -> StringName:
	return _provider_id


## 只读校验：被监听类型的实例落在禁格 → WARNING（机制特有局部约束示例）。
func validate(scope: StringName, context: Dictionary) -> Array:
	received_scopes.append(String(scope))
	last_context = context
	var object_registry: Variant = context.get(_ValidatorCore.K_OBJECT_REGISTRY, null)
	var issues: Array = []
	if object_registry == null or not object_registry.has_method(&"get_object_snapshot"):
		return issues
	for stable_id: String in _all_stable_ids(object_registry):
		var snapshot: Dictionary = object_registry.get_object_snapshot(stable_id)
		if snapshot.get("content_type_id", &"") != _watched_type_id:
			continue
		if snapshot.get("cell", Vector2i.ZERO) == _forbidden_cell:
			issues.append(
				_ValidationIssue.new(
					_ValidationIssue.Severity.WARNING, &"fixture_forbidden_cell",
					"机关 %s 位于机制特有禁格 %s。" % [stable_id, str(_forbidden_cell)],
					get_rule_domain(), scope, _watched_type_id, "", stable_id,
					NodePath(), true, _forbidden_cell
				)
			)
	return issues


## 全部稳定 ID（preplaced 后 spawned；origin token 为 FormalObjectRegistry 冻结值）。
func _all_stable_ids(object_registry: Variant) -> Array[String]:
	var ids: Array[String] = []
	for origin: StringName in [&"preplaced", &"spawned"]:
		ids.append_array(object_registry.get_stable_ids_by_origin(origin))
	return ids
