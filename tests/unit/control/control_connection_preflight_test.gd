extends SceneTree

## AF-05 ControlConnectionPreflight 定向合同测试（Guide §32 Authoring ERROR 清单 + 成环）。
## 覆盖：合法连接集零 issue；目标稳定 ID 不存在；动态 Spawn 目标；目标无 Control Target 能力；
##   动作 ID 未声明；参数不符 schema；Self-target；控制图成环；Source 事件未声明；
##   issue 为 machine-readable detached 字典且确定性排序。
## headless extends SceneTree；preload 引用避开全局 class_name 缓存问题；Node2D fixture 用后 free。


const _Preflight: GDScript = preload(
	"res://gameplay/control/dispatch/control_connection_preflight.gd"
)
const _ConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)
const _Connection: GDScript = preload(
	"res://gameplay/control/control_connection.gd"
)
const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _GateFixture: GDScript = preload(
	"res://tests/unit/control/fixtures/gate_target_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 本轮创建的 Node2D fixture（用后统一 free）。
var _spawned_nodes: Array = []


func _initialize() -> void:
	_test_01_valid_set_zero_issues()
	_test_02_unknown_target()
	_test_03_dynamic_spawn_target()
	_test_04_no_capability_target()
	_test_05_unknown_action()
	_test_06_params_mismatch()
	_test_07_self_target()
	_test_08_graph_cycle()
	_test_09_event_not_declared_by_source()
	_test_10_issue_shape_and_order()
	_cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 01 合法连接集：目标预置、有能力、动作与参数合法 → 零 issue。
func _test_01_valid_set_zero_issues() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"speed_matched", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("sensor-2", &"speed_matched", env.gate_ids.a, &"set_mode", {&"mode": 4}))
	var issues = _Preflight.validate(set, env.registry)
	_check(issues.is_empty(), "01 合法连接集应零 issue")


## 02 目标稳定 ID 不存在。
func _test_02_unknown_target() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", "ghost", &"open", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues) == [_Preflight.CODE_TARGET_NOT_FOUND], "02 未知目标应产生唯一 target_not_found")


## 03 动态 Spawn 目标：不允许作为普通 Target（§32）。
func _test_03_dynamic_spawn_target() -> void:
	var env = _make_env()
	var spawned_id = env.registry.register_spawn(&"gate", Vector2i(9, 0), _make_gate())
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", spawned_id, &"open", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues).has(_Preflight.CODE_TARGET_DYNAMIC_SPAWN), "03 动态 Spawn 目标应被拒绝")


## 04 目标无 Control Target 能力（契约面缺失）。
func _test_04_no_capability_target() -> void:
	var env = _make_env()
	var plain_id = env.registry.register_preplaced(&"plain", Vector2i(9, 0), RefCounted.new())
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", plain_id, &"open", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues) == [_Preflight.CODE_TARGET_NO_CAPABILITY], "04 无能力目标应产生 target_no_capability")


## 05 动作 ID 未被目标声明。
func _test_05_unknown_action() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", env.gate_ids.a, &"explode", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues) == [_Preflight.CODE_ACTION_UNKNOWN], "05 未知动作应产生 action_unknown")


## 06 参数不符 schema。
func _test_06_params_mismatch() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", env.gate_ids.a, &"set_mode", {&"mode": true}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues) == [_Preflight.CODE_ACTION_PARAMS_INVALID], "06 参数不符应产生 params_invalid")


## 07 Self-target：Source 与 Target 同一稳定 ID。
func _test_07_self_target() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create(env.gate_ids.a, &"gate_relayed", env.gate_ids.a, &"open", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues).has(_Preflight.CODE_SELF_TARGET), "07 Self-target 应被拒绝")


## 08 控制图成环：A→B、B→A（连接级 Self-target 之外的有向环）。
func _test_08_graph_cycle() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create(env.gate_ids.a, &"gate_relayed", env.gate_ids.b, &"open", {}))
	set.add_connection(_Connection.create(env.gate_ids.b, &"gate_relayed", env.gate_ids.a, &"close", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues).has(_Preflight.CODE_GRAPH_CYCLE), "08 有向环应被拒绝")
	_check(
		issues[0][_Preflight.K_MESSAGE].contains("→"),
		"08 环 issue 应带路径定位信息"
	)


## 09 Source 事件未声明（Source 实例提供声明面时）。
func _test_09_event_not_declared_by_source() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create(env.gate_ids.a, &"unknown_event", env.gate_ids.b, &"open", {}))
	var issues = _Preflight.validate(set, env.registry)
	_check(_codes(issues) == [_Preflight.CODE_EVENT_NOT_DECLARED], "09 未声明事件应被拒绝")


## 10 issue 形状与确定性排序：固定键、code→index 序稳定。
func _test_10_issue_shape_and_order() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("sensor-1", &"e", "ghost", &"open", {}))
	set.add_connection(_Connection.create("sensor-2", &"e", env.gate_ids.a, &"explode", {}))
	var first = _Preflight.validate(set, env.registry)
	var second = _Preflight.validate(set, env.registry)
	_check(first.size() == 2, "10 应产生两条 issue")
	var keys = (first[0] as Dictionary).keys()
	for required: String in [
		_Preflight.K_CODE,
		_Preflight.K_MESSAGE,
		_Preflight.K_CONNECTION_INDEX,
		_Preflight.K_SOURCE_STABLE_ID,
		_Preflight.K_TARGET_STABLE_ID,
	]:
		_check(keys.has(required), "10 issue 应含固定键 %s" % required)
	_check(
		first[0][_Preflight.K_CODE] == _Preflight.CODE_ACTION_UNKNOWN
			and first[1][_Preflight.K_CODE] == _Preflight.CODE_TARGET_NOT_FOUND,
		"10 issue 应按 code 确定性排序"
	)
	_check(_signatures(first) == _signatures(second), "10 两次校验结果应一致（确定性）")


## 构造测试环境：两个真实 Gate fixture 入正式注册表。
func _make_env() -> Dictionary:
	var registry = _FormalObjectRegistry.new()
	var gate_a = _make_gate()
	var gate_b = _make_gate()
	var id_a = registry.register_preplaced(&"gate", Vector2i.ZERO, gate_a)
	var id_b = registry.register_preplaced(&"gate", Vector2i(1, 0), gate_b)
	gate_a.stable_id = id_a
	gate_b.stable_id = id_b
	return {"registry": registry, "gate_ids": {"a": id_a, "b": id_b}}


## 创建并登记待清理的 Gate fixture（Node2D，不入树）。
func _make_gate():
	var gate = _GateFixture.new()
	_spawned_nodes.append(gate)
	return gate


## 提取 issue 的 code 数组。
func _codes(issues: Array) -> Array:
	var codes: Array = []
	for issue: Dictionary in issues:
		codes.append(issue[_Preflight.K_CODE])
	return codes


## 提取 issue 签名（排序确定性比较用）。
func _signatures(issues: Array) -> Array:
	var signatures: Array = []
	for issue: Dictionary in issues:
		signatures.append("%s|%d" % [issue[_Preflight.K_CODE], issue[_Preflight.K_CONNECTION_INDEX]])
	return signatures


## 释放 Node2D fixture（不入树，直接 free）。
func _cleanup() -> void:
	for node: Variant in _spawned_nodes:
		if node != null and is_instance_valid(node):
			node.free()


## 断言与汇报（AF-02 测试惯例）。
func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _report() -> void:
	print("control_connection_preflight_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL：%s" % failure)
