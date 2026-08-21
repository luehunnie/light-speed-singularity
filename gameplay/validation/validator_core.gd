class_name ValidatorCore
extends RefCounted

## 单一 Validator Core（AF-06 / Guide §35）：Runtime / Authoring / Project 检查共享的唯一校验核心。
## 三种 Scope：project / current_level / change_set；规则不写机关类型 if-chain、不维护中央白名单
##   （Guide §5.2 / Q41），机制特有约束经 ValidationRuleProvider 独立注册接入。
## 复用既有规则源、不复制第二套规则：Definition/ID → FormalContentDiscovery + Definition.validate_definition
##   （AF-01）；Placement → LevelValidator（D6）；Control → ControlConnectionPreflight（AF-05 §32）。
## 本类只读：不改场景 / Registry / 连接集；issue 一律 machine-readable（ValidationIssue，Go To 定位字段）。
## v1 裁定：Inventory 域 = Spawn 资格最小规则（AF-03 深化）；Objective 域保留常量、规则待 AF-04；
##   change_set 只保留携带变更实例稳定 ID 的 issue（结构级全场景规则不属增量域）；Auto-fix 后置。


const _ValidationIssue: GDScript = preload("res://gameplay/validation/validation_issue.gd")
const _ValidationResult: GDScript = preload("res://gameplay/validation/validation_result.gd")
const _ValidationRuleProvider: GDScript = preload("res://gameplay/validation/validation_rule_provider.gd")
const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _Preflight: GDScript = preload("res://gameplay/control/dispatch/control_connection_preflight.gd")
const _FormalContentDiscovery: GDScript = preload("res://gameplay/content/formal_content_discovery.gd")

## Scope token（Guide §35 冻结三域）。
const SCOPE_PROJECT: StringName = &"project"
const SCOPE_CURRENT_LEVEL: StringName = &"current_level"
const SCOPE_CHANGE_SET: StringName = &"change_set"

## 校验域 token（issue.domain 取值）。
const DOMAIN_DEFINITION: StringName = &"definition"
const DOMAIN_ID: StringName = &"id"
const DOMAIN_INTERACTION: StringName = &"interaction"
const DOMAIN_PLACEMENT: StringName = &"placement"
const DOMAIN_INVENTORY: StringName = &"inventory"
const DOMAIN_OBJECTIVE: StringName = &"objective"
const DOMAIN_CONTROL: StringName = &"control"

## 上下文固定键（change_set / current_level / provider 共享只读上下文）。
const K_LEVEL_ROOT: String = "level_root"
const K_OBJECT_REGISTRY: String = "object_registry"
const K_CONNECTION_SET: String = "connection_set"
const K_CONTENT_REGISTRY: String = "content_registry"
const K_CHANGED_STABLE_IDS: String = "changed_stable_ids"
const K_DEFINITIONS_DIR: String = "definitions_dir"

## provider_id → provider（登记序；GDScript Dictionary 保插入序，保证确定性）。
var _providers_by_id: Dictionary = {}


# ===== Rule Provider 注册（机制扩展独立接入点） =====

## 注册一个 Rule Provider；拒绝非 Provider 实例 / 空 provider_id / 重复 ID，零副作用返回 false。
func register_rule_provider(provider: Variant) -> bool:
	if provider == null or not (provider is _ValidationRuleProvider):
		push_error("ValidatorCore: 拒绝非 ValidationRuleProvider 扩展。")
		return false
	var provider_id: StringName = provider.get_provider_id()
	if provider_id == &"":
		push_error("ValidatorCore: 拒绝空 provider_id。")
		return false
	if _providers_by_id.has(provider_id):
		push_error("ValidatorCore: 拒绝重复 provider_id：%s" % provider_id)
		return false
	_providers_by_id[provider_id] = provider
	return true


## 已注册 provider_id 副本（登记序）。
func get_rule_provider_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for provider_id: StringName in _providers_by_id.keys():
		ids.append(provider_id)
	return ids


func get_rule_provider_count() -> int:
	return _providers_by_id.size()


# ===== Scope：Project =====

## 项目级校验：定义域（Registry 内逐定义复用 validate_definition）+ ID 域
##   （提供 definitions_dir 时复用 Discovery 发现管线，重复 type_id 等以稳定码上报）。
func validate_project(content_registry: Variant, definitions_dir: String = "") -> _ValidationResult:
	var issues: Array = []
	if content_registry != null and content_registry.has_method(&"get_type_ids"):
		_validate_definitions_in_registry(content_registry, issues)
	if not definitions_dir.is_empty():
		_run_discovery_errors(definitions_dir, issues)
	_collect_provider_issues(
		SCOPE_PROJECT, {K_CONTENT_REGISTRY: content_registry, K_DEFINITIONS_DIR: definitions_dir}, issues
	)
	return _ValidationResult.new(issues)


# ===== Scope：Current Level =====

## 当前关卡级校验：placement（LevelValidator 委派）+ control（Preflight 委派）
##   + interaction 镜像一致性 + inventory Spawn 资格 + 机制扩展；键见 K_* 常量，缺项跳过对应域。
func validate_current_level(context: Dictionary) -> _ValidationResult:
	return _ValidationResult.new(_run_shared_level_rules(context, SCOPE_CURRENT_LEVEL))


# ===== Scope：Change Set =====

## 变更集级校验：与 current_level 完全同一套共享规则，仅保留携带变更实例稳定 ID 的 issue
##   （K_CHANGED_STABLE_IDS：Array[String]；结构级无实例定位的 issue 不属增量域，天然被过滤）。
func validate_change_set(context: Dictionary) -> _ValidationResult:
	var all_issues := _run_shared_level_rules(context, SCOPE_CHANGE_SET)
	var changed: Dictionary = {}
	for stable_id: Variant in context.get(K_CHANGED_STABLE_IDS, []):
		changed[String(stable_id)] = true
	var filtered: Array = []
	for issue in all_issues:
		if changed.has(issue.get_stable_instance_id()):
			filtered.append(issue)
	return _ValidationResult.new(filtered)


# ===== 共享规则（Scope 共用，不按 Scope 复制第二套） =====

## current_level / change_set 共用的全部域规则；scope token 仅写入 issue 元数据。
func _run_shared_level_rules(context: Dictionary, scope: StringName) -> Array:
	var issues: Array = []
	var level_root: Variant = context.get(K_LEVEL_ROOT, null)
	if level_root != null and level_root is Node:
		var level_result: Variant = _LevelValidator.new().validate(level_root)
		for level_issue: Variant in level_result.get_issues():
			issues.append(_map_level_issue(level_issue, scope))
	_validate_control_connections(context, scope, issues)
	var object_registry: Variant = context.get(K_OBJECT_REGISTRY, null)
	var content_registry: Variant = context.get(K_CONTENT_REGISTRY, null)
	if object_registry != null and object_registry.has_method(&"get_object_snapshot"):
		_validate_interaction_mirrors(object_registry, content_registry, scope, issues)
		_validate_inventory_eligibility(object_registry, content_registry, scope, issues)
	_collect_provider_issues(scope, context, issues)
	return issues


# ===== 域规则 =====

## 定义域：Registry 内逐定义复用 Definition.validate_definition（不复制规则）。
func _validate_definitions_in_registry(content_registry: Variant, issues: Array) -> void:
	for type_id: StringName in content_registry.get_type_ids():
		var definition: Variant = content_registry.get_definition(type_id)
		for problem: String in definition.validate_definition():
			issues.append(
				_issue(
					_ValidationIssue.Severity.ERROR, &"definition_invalid", problem,
					DOMAIN_DEFINITION, SCOPE_PROJECT, type_id, definition.resource_path
				)
			)


## ID 域：复用 Discovery 发现管线错误（重复 content_type_id 等），不另写第二套发现规则。
func _run_discovery_errors(definitions_dir: String, issues: Array) -> void:
	var result: Dictionary = _FormalContentDiscovery.discover(definitions_dir)
	for problem: String in result.errors:
		issues.append(
			_issue(
				_ValidationIssue.Severity.ERROR, &"definition_discovery_error", problem,
				DOMAIN_ID, SCOPE_PROJECT
			)
		)


## Control 域：整份连接集合委派 ControlConnectionPreflight（AF-05 §32 Authoring 清单）。
func _validate_control_connections(context: Dictionary, scope: StringName, issues: Array) -> void:
	var connection_set: Variant = context.get(K_CONNECTION_SET, null)
	var object_registry: Variant = context.get(K_OBJECT_REGISTRY, null)
	if connection_set == null or object_registry == null:
		return
	for control_issue: Dictionary in _Preflight.validate(connection_set, object_registry):
		issues.append(_map_control_issue(control_issue, scope))


## Interaction 域：机关实例 get_light_interaction_forms() 镜像须与 Definition 声明一致
##   （capability ↔ implementation；声明透明或无可验证实例则跳过）。
func _validate_interaction_mirrors(
		object_registry: Variant, content_registry: Variant, scope: StringName, issues: Array
) -> void:
	for stable_id: String in _all_stable_ids(object_registry):
		var snapshot: Dictionary = object_registry.get_object_snapshot(stable_id)
		var definition: Variant = _definition_of(content_registry, snapshot)
		if definition == null or definition.get_content_domain() != &"mechanism":
			continue
		var declared: Variant = definition.get(&"light_interaction_forms")
		if not (declared is Array) or (declared as Array).is_empty():
			continue
		var instance: Variant = snapshot.get("instance", null)
		if instance == null:
			continue
		if not instance.has_method(&"get_light_interaction_forms"):
			issues.append(
				_issue(
					_ValidationIssue.Severity.ERROR, &"interaction_mirror_missing",
					"机关 %s 声明光交互形态但实例未提供 get_light_interaction_forms()。" % stable_id,
					DOMAIN_INTERACTION, scope, snapshot.get("content_type_id", &""),
					"", stable_id, NodePath(), true, snapshot.get("cell", Vector2i.ZERO)
				)
			)
			continue
		var mirror: Variant = instance.call(&"get_light_interaction_forms")
		if not (mirror is Array) or not _same_token_set(declared as Array, mirror as Array):
			issues.append(
				_issue(
					_ValidationIssue.Severity.ERROR, &"interaction_mirror_mismatch",
					"机关 %s 声明 %s 但实例镜像 %s。" % [stable_id, str(declared), str(mirror)],
					DOMAIN_INTERACTION, scope, snapshot.get("content_type_id", &""),
					"", stable_id, NodePath(), true, snapshot.get("cell", Vector2i.ZERO)
				)
			)


## Inventory 域（v1 最小）：Spawn 来源实例的类型必须声明 inventory_eligible（AF-03 深化）。
func _validate_inventory_eligibility(
		object_registry: Variant, content_registry: Variant, scope: StringName, issues: Array
) -> void:
	for stable_id: String in _all_stable_ids(object_registry):
		var snapshot: Dictionary = object_registry.get_object_snapshot(stable_id)
		if snapshot.get("origin", &"") != &"spawned":
			continue
		var definition: Variant = _definition_of(content_registry, snapshot)
		if definition == null:
			continue
		if definition.get(&"inventory_eligible") == false:
			issues.append(
				_issue(
					_ValidationIssue.Severity.ERROR, &"inventory_spawn_ineligible",
					"Spawn 实例 %s 的类型未声明 inventory_eligible。" % stable_id,
					DOMAIN_INVENTORY, scope, snapshot.get("content_type_id", &""),
					"", stable_id, NodePath(), true, snapshot.get("cell", Vector2i.ZERO)
				)
			)


## 机制扩展：按登记序询问各 Provider（supports_scope 决定参与），非 Issue 条目防御性丢弃。
func _collect_provider_issues(scope: StringName, context: Dictionary, issues: Array) -> void:
	for provider: Variant in _providers_by_id.values():
		if not provider.supports_scope(scope):
			continue
		for extension_issue: Variant in provider.validate(scope, context):
			if extension_issue is _ValidationIssue:
				issues.append(extension_issue)


# ===== 转换与辅助 =====

## LevelValidationIssue → ValidationIssue（placement 域；object_id 即稳定业务 ID）。
func _map_level_issue(level_issue: Variant, scope: StringName) -> _ValidationIssue:
	return _ValidationIssue.new(
		level_issue.get_severity(), level_issue.get_code(), level_issue.get_message(),
		DOMAIN_PLACEMENT, scope, &"", "",
		String(level_issue.get_object_id()), level_issue.get_node_path(),
		level_issue.has_cell(), level_issue.get_cell()
	)


## Preflight issue 字典 → ValidationIssue（control 域；定位取最相关实例：Target 优先，否则 Source）。
func _map_control_issue(control_issue: Dictionary, scope: StringName) -> _ValidationIssue:
	var locator: String = String(control_issue.get(_Preflight.K_TARGET_STABLE_ID, ""))
	if locator.is_empty():
		locator = String(control_issue.get(_Preflight.K_SOURCE_STABLE_ID, ""))
	return _ValidationIssue.new(
		_ValidationIssue.Severity.ERROR, control_issue.get(_Preflight.K_CODE, &""),
		String(control_issue.get(_Preflight.K_MESSAGE, "")), DOMAIN_CONTROL, scope,
		&"", "", locator
	)


## 组装一条 ERROR/WARNING issue（长参数列统一入口）。
func _issue(
		severity: int, code: StringName, message: String, domain: StringName,
		scope: StringName, content_type_id: StringName = &"", definition_path: String = "",
		stable_instance_id: String = "", node_path: NodePath = NodePath(),
		has_cell: bool = false, cell: Vector2i = Vector2i.ZERO
) -> _ValidationIssue:
	return _ValidationIssue.new(
		severity, code, message, domain, scope, content_type_id,
		definition_path, stable_instance_id, node_path, has_cell, cell
	)


## 全部稳定 ID（登记序 = preplaced 后 spawned；origin token 为 FormalObjectRegistry 冻结值）。
func _all_stable_ids(object_registry: Variant) -> Array[String]:
	var ids: Array[String] = []
	for origin: StringName in [&"preplaced", &"spawned"]:
		ids.append_array(object_registry.get_stable_ids_by_origin(origin))
	return ids


## 按 snapshot 的 content_type_id 查定义；无 Registry 或未知类型返回 null。
func _definition_of(content_registry: Variant, snapshot: Dictionary) -> Variant:
	if content_registry == null or not content_registry.has_method(&"get_definition"):
		return null
	return content_registry.get_definition(snapshot.get("content_type_id", &""))


## 两个 token 数组是否为同一集合（去重比较，不依赖顺序）。
func _same_token_set(a: Array, b: Array) -> bool:
	var set_a: Dictionary = {}
	for token: Variant in a:
		set_a[String(token)] = true
	var set_b: Dictionary = {}
	for token: Variant in b:
		set_b[String(token)] = true
	return set_a == set_b
