extends SceneTree

## AF-06 ValidatorCore 定向合同测试（Guide §35：单一 Core / 三 Scope / machine-readable issue / Go To / 扩展注册）。
## 覆盖：project 域（Registry 定义复用 + Discovery 重复 ID 复用）；current_level 域
##   （placement 委派 / control 委派 / interaction 镜像缺失与偏差 / inventory Spawn 资格）；
##   change_set（同一套规则、按变更实例过滤）；Rule Provider 独立注册与重复拒绝；
##   issue schema Go To 字段与确定性排序；Core 全程只读证明。
## headless extends SceneTree；preload 引用避开全局 class_name 缓存问题；Node2D fixture 用后 free。


const _ValidatorCore: GDScript = preload("res://gameplay/validation/validator_core.gd")
const _ValidationIssue: GDScript = preload("res://gameplay/validation/validation_issue.gd")
const _ValidationRuleProvider: GDScript = preload("res://gameplay/validation/validation_rule_provider.gd")
const _MechDef: GDScript = preload("res://gameplay/content/mechanism_definition.gd")
const _ContentRegistry: GDScript = preload("res://gameplay/content/formal_content_registry.gd")
const _ObjectRegistry: GDScript = preload("res://gameplay/content/formal_object_registry.gd")
const _ConnectionSet: GDScript = preload("res://gameplay/control/control_connection_set.gd")
const _Connection: GDScript = preload("res://gameplay/control/control_connection.gd")
const _FakeMechanism: GDScript = preload("res://tests/unit/validation/fixtures/fake_mechanism_fixture.gd")
const _RuleProviderFixture: GDScript = preload(
	"res://tests/unit/validation/fixtures/mechanism_rule_provider_fixture.gd"
)

const _FIXTURE_DIR: String = "user://af06_validation_fixture"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 本轮创建的 Node fixture（用后统一 free）。
var _spawned_nodes: Array = []


func _initialize() -> void:
	_test_01_project_valid_registry_zero_issues()
	_test_02_project_invalid_definition_reported()
	_test_03_project_discovery_duplicate_id_reused()
	_test_04_current_level_control_delegate()
	_test_05_current_level_interaction_mirror_mismatch()
	_test_06_current_level_interaction_mirror_missing()
	_test_07_current_level_inventory_spawn_ineligible()
	_test_08_current_level_placement_delegate()
	_test_09_change_set_shared_rules_filtered()
	_test_10_rule_provider_independent_registration()
	_test_11_issue_schema_and_determinism()
	_test_12_core_read_only_proof()
	_cleanup()
	_report()


# ===== project Scope =====

## 01：全合法定义的 Registry → project 校验零 issue。
func _test_01_project_valid_registry_zero_issues() -> void:
	var core: Object = _ValidatorCore.new()
	var result: Object = core.validate_project(_build_registry([_make_definition(&"mech_ok", "合格机关")]))
	_check(result.get_issue_count() == 0 and result.is_valid(), "01 合法 Registry 应零 issue。")


## 02：display_name 为空的定义 → definition_invalid ERROR + content_type_id Go To 定位。
func _test_02_project_invalid_definition_reported() -> void:
	var bad: Resource = _make_definition(&"mech_bad", "")
	var core: Object = _ValidatorCore.new()
	var result: Object = core.validate_project(_build_registry([bad]))
	var issues: Array = result.get_issues()
	_check(issues.size() == 1, "02 应恰好 1 条 issue（实际 %d）。" % issues.size())
	if issues.is_empty():
		return
	var issue: Object = issues[0]
	_check(
		issue.get_code() == &"definition_invalid" and issue.get_severity() == _ValidationIssue.Severity.ERROR,
		"02 应为 definition_invalid ERROR。"
	)
	_check(
		issue.get_domain() == &"definition" and issue.get_content_type_id() == &"mech_bad",
		"02 域与类型定位应正确。"
	)
	_check(issue.has_location(), "02 issue 应具备 Go To 定位。")


## 03：目录内重复 content_type_id → 复用 Discovery 检出并以 definition_discovery_error 上报。
func _test_03_project_discovery_duplicate_id_reused() -> void:
	_prepare_fixture_dir()
	_save_definition("a_dup.tres", &"mech_dup", "重复 A")
	_save_definition("b_dup.tres", &"mech_dup", "重复 B")
	var core: Object = _ValidatorCore.new()
	var result: Object = core.validate_project(null, _FIXTURE_DIR)
	var issues: Array = result.get_issues()
	_check(issues.size() == 1, "03 Discovery 应报 1 条重复 ID（实际 %d）。" % issues.size())
	if issues.is_empty():
		return
	_check(
		issues[0].get_code() == &"definition_discovery_error"
			and issues[0].get_domain() == &"id" and not result.is_valid(),
		"03 重复 ID 应为 id 域 definition_discovery_error 且结果非法。"
	)


# ===== current_level Scope =====

## 04：指向不存在稳定 ID 的连接 → 委派 Preflight，映射 control 域 + target Go To 定位。
func _test_04_current_level_control_delegate() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_bad_connection("ghost_target").build()
	var result: Object = env.core.validate_current_level(env.context)
	var codes := _codes_of_domain(result, &"control")
	_check(codes.has(&"control_target_not_found"), "04 应含 control_target_not_found。")
	var located: Object = _first_with_code(result, &"control_target_not_found")
	_check(
		located != null and located.get_stable_instance_id() == "ghost_target"
			and located.get_scope() == &"current_level",
		"04 定位应为 ghost_target 且 scope 正确。"
	)


## 05：定义声明 RAY、实例镜像 RAY+PARTICLE → interaction_mirror_mismatch + cell 定位。
func _test_05_current_level_interaction_mirror_mismatch() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_mismatch().build()
	var result: Object = env.core.validate_current_level(env.context)
	var issue: Object = _first_with_code(result, &"interaction_mirror_mismatch")
	_check(issue != null, "05 应报 interaction_mirror_mismatch。")
	if issue != null:
		_check(
			issue.get_stable_instance_id() == env.bad_mirror_id
				and issue.has_cell() and issue.get_cell() == Vector2i(2, 3),
			"05 应带实例 ID 与 cell 定位。"
		)


## 06：声明形态但实例无镜像方法 → interaction_mirror_missing。
func _test_06_current_level_interaction_mirror_missing() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_missing().build()
	var result: Object = env.core.validate_current_level(env.context)
	_check(_first_with_code(result, &"interaction_mirror_missing") != null, "06 应报 interaction_mirror_missing。")


## 07：Spawn 实例类型未声明 inventory_eligible → inventory_spawn_ineligible。
func _test_07_current_level_inventory_spawn_ineligible() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_ineligible_spawn().build()
	var result: Object = env.core.validate_current_level(env.context)
	var issue: Object = _first_with_code(result, &"inventory_spawn_ineligible")
	_check(issue != null, "07 应报 inventory_spawn_ineligible。")
	if issue != null:
		_check(issue.get_stable_instance_id() == env.bad_spawn_id, "07 应定位到违规 Spawn 实例。")


## 08：空关卡根 → 委派 LevelValidator，placement 域结构 issue 映射保留 severity/node_path。
func _test_08_current_level_placement_delegate() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_empty_level_root().build()
	var result: Object = env.core.validate_current_level(env.context)
	var codes := _codes_of_domain(result, &"placement")
	_check(codes.has(&"required_node_missing"), "08 应含 required_node_missing。")
	var issue: Object = _first_with_code(result, &"required_node_missing")
	_check(
		issue != null and issue.get_severity() == _ValidationIssue.Severity.ERROR
			and issue.get_node_path() == NodePath(),
		"08 severity 与空 node_path 应保留。"
	)


# ===== change_set Scope =====

## 09：镜像偏差 + 违规 Spawn + 坏连接并存；change_set 与 current_level 同码（共用规则），
##   且仅保留携带变更实例稳定 ID 的 issue。
func _test_09_change_set_shared_rules_filtered() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_mismatch().with_ineligible_spawn().with_bad_connection("ghost_target").build()
	var full: Object = env.core.validate_current_level(env.context)
	var full_codes := _codes_of_domain(full, &"interaction") + _codes_of_domain(full, &"inventory")
	env.context[_ValidatorCore.K_CHANGED_STABLE_IDS] = [env.bad_mirror_id]
	var change: Object = env.core.validate_change_set(env.context)
	var issues: Array = change.get_issues()
	_check(issues.size() == 1, "09 变更集应仅保留 1 条（实际 %d）。" % issues.size())
	if issues.size() == 1:
		_check(
			issues[0].get_code() == &"interaction_mirror_mismatch"
				and issues[0].get_stable_instance_id() == env.bad_mirror_id
				and issues[0].get_scope() == &"change_set",
			"09 应只保留变更实例的镜像 issue。"
		)
	env.context[_ValidatorCore.K_CHANGED_STABLE_IDS] = [env.bad_spawn_id]
	var change_b: Object = env.core.validate_change_set(env.context)
	var codes_b := _all_codes(change_b)
	_check(
		codes_b.has(&"inventory_spawn_ineligible") and not codes_b.has(&"interaction_mirror_mismatch")
			and not codes_b.has(&"control_target_not_found"),
		"09 换变更集后应只含 Spawn 实例 issue（共用规则、无第二套）。"
	)
	_check(full_codes.has(&"interaction_mirror_mismatch") and full_codes.has(&"inventory_spawn_ineligible"),
		"09 current_level 应同码全覆盖（规则共用证明）。")


# ===== Rule Provider 扩展 =====

## 10：机制扩展独立注册生效、project/current_level 两 Scope 均被询问、重复 ID 拒绝。
func _test_10_rule_provider_independent_registration() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_mismatch().build()
	var provider: Object = _RuleProviderFixture.new(&"fixture_barrier", &"mech_mirror", Vector2i(2, 3))
	_check(env.core.register_rule_provider(provider), "10 注册应成功。")
	_check(env.core.get_rule_provider_count() == 1, "10 应有 1 个扩展。")
	var duplicate: Object = _RuleProviderFixture.new(&"fixture_barrier", &"mech_mirror", Vector2i.ZERO)
	_check(
		not env.core.register_rule_provider(duplicate) and env.core.get_rule_provider_count() == 1,
		"10 重复 provider_id 应拒绝且计数不变。"
	)
	_check(not env.core.register_rule_provider(_ValidationRuleProvider.new()), "10 空 provider_id 应拒绝。")
	var result: Object = env.core.validate_current_level(env.context)
	var issue: Object = _first_with_code(result, &"fixture_forbidden_cell")
	_check(
		issue != null and issue.get_stable_instance_id() == env.bad_mirror_id
			and issue.get_domain() == &"extension" and issue.get_severity() == _ValidationIssue.Severity.WARNING,
		"10 扩展 issue 应为 extension 域 WARNING 并定位实例。"
	)
	env.core.validate_project(env.content_registry)
	_check(
		provider.received_scopes.has("current_level") and provider.received_scopes.has("project"),
		"10 扩展应在两个 Scope 被询问。"
	)


# ===== schema / 确定性 =====

## 11：to_dictionary 固定键齐全；两次运行 issue 序列完全一致（确定性排序）。
func _test_11_issue_schema_and_determinism() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_mismatch().with_ineligible_spawn().build()
	var run_a: Object = env.core.validate_current_level(env.context)
	var run_b: Object = env.core.validate_current_level(env.context)
	_check(_sequence_of(run_a) == _sequence_of(run_b), "11 两次运行序列应一致。")
	var dict: Dictionary = run_a.get_issues()[0].to_dictionary()
	var keys_present := true
	for key: String in [
		"severity", "code", "message", "domain", "scope", "content_type_id",
		"definition_path", "stable_instance_id", "node_path", "has_cell", "cell"
	]:
		if not dict.has(key):
			keys_present = false
	_check(keys_present, "11 schema 固定键应齐全。")
	var domains: Dictionary = run_a.count_by_domain()
	_check(
		int(domains.get("interaction", 0)) == 1 and int(domains.get("inventory", 0)) == 1,
		"11 域统计应正确。"
	)


# ===== 只读证明 =====

## 12：全部 Scope 校验后 Registry / 连接集 / 对象注册表事实不变。
func _test_12_core_read_only_proof() -> void:
	var env: _EnvBuilder = _EnvBuilder.new(_spawned_nodes).with_mirror_mismatch().with_ineligible_spawn().with_bad_connection("ghost_target").build()
	var before_types: Array = env.content_registry.get_type_ids()
	var before_objects: int = env.object_registry.get_count()
	var before_connections: int = env.connection_set.get_all_connections().size()
	env.core.validate_project(env.content_registry)
	env.core.validate_current_level(env.context)
	env.context[_ValidatorCore.K_CHANGED_STABLE_IDS] = [env.bad_mirror_id]
	env.core.validate_change_set(env.context)
	_check(
		env.content_registry.get_type_ids() == before_types
			and env.object_registry.get_count() == before_objects
			and env.connection_set.get_all_connections().size() == before_connections,
		"12 校验全程只读，事实不得改变。"
	)


# ===== env 构建（内部类） =====

## 测试环境构建器：内容/对象注册表 + 连接集 + 可选关卡根 + 独立 Core。
## [br]created_nodes 传入外层收集数组，builder 创建的 Node fixture 统一由外层 free。
class _EnvBuilder:
	var core: Object
	var content_registry: Object
	var object_registry: Object
	var connection_set: Object
	var context: Dictionary = {}
	var bad_mirror_id: String = ""
	var bad_spawn_id: String = ""
	var _definitions: Array = []
	var _pending_targets: Array = []
	var _created_nodes: Array

	func _init(created_nodes: Array) -> void:
		_created_nodes = created_nodes

	const _Core: GDScript = preload("res://gameplay/validation/validator_core.gd")
	const _MechDefInner: GDScript = preload("res://gameplay/content/mechanism_definition.gd")
	const _ContentRegInner: GDScript = preload("res://gameplay/content/formal_content_registry.gd")
	const _ObjectRegInner: GDScript = preload("res://gameplay/content/formal_object_registry.gd")
	const _ConnectionSetInner: GDScript = preload("res://gameplay/control/control_connection_set.gd")
	const _ConnectionInner: GDScript = preload("res://gameplay/control/control_connection.gd")
	const _FakeMechInner: GDScript = preload("res://tests/unit/validation/fixtures/fake_mechanism_fixture.gd")
	const _CoreKeys: GDScript = preload("res://gameplay/validation/validator_core.gd")

	## 镜像偏差用机关：声明 RAY、实例返回 RAY+PARTICLE、落格 (2,3)。
	func with_mirror_mismatch() -> _EnvBuilder:
		_definitions.append(_make_def(&"mech_mirror", "镜像机关", [&"RAY"], true))
		return self

	## 镜像缺失用机关：声明 RAY、实例为无镜像方法的普通 Node2D、落格 (7,7)。
	func with_mirror_missing() -> _EnvBuilder:
		_definitions.append(_make_def(&"mech_missing", "缺失镜像机关", [&"RAY"], true))
		return self

	## 违规 Spawn 用机关：不可入库存。
	func with_ineligible_spawn() -> _EnvBuilder:
		_definitions.append(_make_def(&"mech_spawn", "违规 Spawn 类型", [], false))
		return self

	## 追加一条指向不存在稳定 ID 的连接。
	func with_bad_connection(target_id: String) -> _EnvBuilder:
		context[_CoreKeys.K_CONNECTION_SET] = _placeholder_for(target_id)
		return self

	## 空关卡根（LevelValidator 结构 issue 来源）。
	func with_empty_level_root() -> _EnvBuilder:
		var root := Node2D.new()
		_created_nodes.append(root)
		context[_CoreKeys.K_LEVEL_ROOT] = root
		return self

	## 组装全部事实并建立 Core 上下文。
	func build() -> _EnvBuilder:
		if context.get(_CoreKeys.K_CONNECTION_SET, null) == null:
			var set: Object = _ConnectionSetInner.new()
			for target_id: String in _pending_targets:
				set.add_connection(_ConnectionInner.create("src_stable", &"evt_open", target_id, &"act_open", {}))
			connection_set = set
			context[_CoreKeys.K_CONNECTION_SET] = set
		content_registry = _ContentRegInner.build(_definitions)
		object_registry = _ObjectRegInner.new(content_registry)
		core = _Core.new()
		context[_CoreKeys.K_CONTENT_REGISTRY] = content_registry
		context[_CoreKeys.K_OBJECT_REGISTRY] = object_registry
		_commit_objects()
		return self

	## 全部 builder 创建的 Node fixture 已汇入外层 _created_nodes（构造注入，无 static 状态）。

	func _placeholder_for(target_id: String) -> Variant:
		# 连接集合延迟到 build 组装（此处只登记目标 ID）。
		_pending_targets.append(target_id)
		return null

		## 构造机关定义（typed 形态数组按需为空）。
	func _make_def(type_id: StringName, name: String, forms: Array, eligible: bool) -> Resource:
		var definition: Resource = _MechDefInner.new()
		definition.content_type_id = type_id
		definition.display_name = name
		definition.inventory_eligible = eligible
		if not forms.is_empty():
			var typed_forms: Array[StringName] = []
			for form: StringName in forms:
				typed_forms.append(form)
			definition.light_interaction_forms = typed_forms
		var root := Node2D.new()
		var packed := PackedScene.new()
		packed.pack(root)
		root.free()
		definition.scene = packed
		return definition

	## 按用例登记对象实例并记录目标稳定 ID。
	func _commit_objects() -> void:
		for definition: Variant in _definitions:
			var type_id: StringName = definition.content_type_id
			if type_id == &"mech_mirror":
				var instance: Object = _FakeMechInner.new()
				instance.interaction_forms = [&"RAY", &"PARTICLE"]
				_created_nodes.append(instance)
				bad_mirror_id = object_registry.register_preplaced(type_id, Vector2i(2, 3), instance)
			elif type_id == &"mech_missing":
				var plain := Node2D.new()
				_created_nodes.append(plain)
				object_registry.register_preplaced(type_id, Vector2i(7, 7), plain)
			elif type_id == &"mech_spawn":
				bad_spawn_id = object_registry.register_spawn(type_id, Vector2i(5, 5))


# ===== fixture 文件辅助 =====

## 重建 user:// fixture 目录。
func _prepare_fixture_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir.dir_exists(_FIXTURE_DIR.replace("user://", "")):
		var inner := DirAccess.open(_FIXTURE_DIR)
		inner.list_dir_begin()
		var names: Array[String] = []
		var entry := inner.get_next()
		while not entry.is_empty():
			if not entry.begins_with("."):
				names.append(entry)
			entry = inner.get_next()
		inner.list_dir_end()
		for name: String in names:
			inner.remove(name)
		dir.remove(_FIXTURE_DIR.replace("user://", ""))
	dir.make_dir_recursive(_FIXTURE_DIR)


## 保存一个最小机关定义 .tres。
func _save_definition(file_name: String, type_id: StringName, display: String) -> void:
	var definition: Resource = _MechDef.new()
	definition.content_type_id = type_id
	definition.display_name = display
	var root := Node2D.new()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	definition.scene = packed
	ResourceSaver.save(definition, "%s/%s" % [_FIXTURE_DIR, file_name])


# ===== 断言辅助 =====

## 指定域的全部问题码集合。
func _codes_of_domain(result: Object, domain: StringName) -> Array:
	var codes: Array = []
	for issue: Variant in result.get_issues():
		if issue.get_domain() == domain:
			codes.append(issue.get_code())
	return codes


## 首个指定码 issue；无则 null。
func _first_with_code(result: Object, code: StringName) -> Variant:
	for issue: Variant in result.get_issues():
		if issue.get_code() == code:
			return issue
	return null


## 全部问题码序列。
func _all_codes(result: Object) -> Array:
	var codes: Array = []
	for issue: Variant in result.get_issues():
		codes.append(issue.get_code())
	return codes


## issue 排序序列指纹（code|domain|stable_id）。
func _sequence_of(result: Object) -> Array:
	var sequence: Array = []
	for issue: Variant in result.get_issues():
		sequence.append("%s|%s|%s" % [issue.get_code(), issue.get_domain(), issue.get_stable_instance_id()])
	return sequence


# ===== 构造与清理 =====

## 构造一个最小合法机关定义。
func _make_definition(type_id: StringName, display: String) -> Resource:
	var builder := _EnvBuilder.new(_spawned_nodes)
	return builder._make_def(type_id, display, [], true)


## 由定义数组构建 Registry。
func _build_registry(definitions: Array) -> Object:
	return _ContentRegistry.build(definitions)


## 释放 Node fixture（builder 汇总 + 本层直建）。
func _cleanup() -> void:
	var all: Array = _spawned_nodes.duplicate()
	for node: Variant in all:
		if node != null and is_instance_valid(node):
			node.free()


## 断言与汇报（AF-02/05 测试惯例）。
func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _report() -> void:
	print("validator_core_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL：%s" % failure)
