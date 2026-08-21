extends SceneTree

## AF-05 ControlDispatcher 定向合同测试（Guide §26.1 / §29-§33 + §36.5 Control Fixtures）。
## 覆盖：Event → Connection → Action 真实链路（含经 AF-02 真实 LightInteractionResult 的 Source 桥接）、
##   dedupe、显式互斥冲突、同 Action 不同 Params 冲突、invalid Target / 无能力 / 未知动作 / 参数
##   不符的 safe no-op 且其它合法命令继续、组内多命令顺序执行与原子回滚、Batch N→N+1 级联、
##   未声明级联事件丢弃（§31）、到达序无关确定性（§29）、级联深度安全上限、Reset 集成（§33）。
## headless extends SceneTree；preload 引用避开全局 class_name 缓存问题；Node2D fixture 用后 free。


const _Dispatcher: GDScript = preload(
	"res://gameplay/control/dispatch/control_dispatcher.gd"
)
const _ConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)
const _Connection: GDScript = preload(
	"res://gameplay/control/control_connection.gd"
)
const _OutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)
const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _LightInteractionResult: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)
const _GateFixture: GDScript = preload(
	"res://tests/unit/control/fixtures/gate_target_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 本轮创建的 Node2D fixture（用后统一 free）。
var _spawned_nodes: Array = []


func _initialize() -> void:
	_test_01_event_connection_action_chain()
	_test_02_light_result_source_bridge()
	_test_03_dedupe()
	_test_04_mutex_conflict()
	_test_05_same_action_different_params_conflict()
	_test_06_invalid_target_no_op_others_continue()
	_test_07_no_capability_and_unknown_action()
	_test_08_params_mismatch_no_op()
	_test_09_multi_command_group()
	_test_10_atomic_rollback()
	_test_11_cascade_batch_n_to_n_plus_1()
	_test_12_undeclared_cascade_event_dropped()
	_test_13_order_independence()
	_test_14_reset_integration()
	_test_15_cascade_cap()
	_cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 01 真实链路：事件 → 连接 → 动作提交；无订阅事件零副作用。
func _test_01_event_connection_action_chain() -> void:
	var env = _make_env()
	var report = env.dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"request_open", 1),
	])
	_check(env.gates.a.current_open == true, "01 事件应经连接打开闸门 A")
	_check(report.executed.size() == 1, "01 应恰好执行一条命令")
	_check(report.batch_count == 1, "01 无级联时批次数应为 1")
	var idle = env.dispatcher.dispatch_events([
		_OutputEvent.create("unregistered-source", &"nobody_listens", 1),
	])
	_check(idle.executed.is_empty() and idle.no_ops.is_empty(), "01 无订阅事件应零副作用")


## 02 真实 Source 桥接：AF-02 光交互 Result 的 OUTPUT_EVENT 效果 → Typed Event → 派发。
func _test_02_light_result_source_bridge() -> void:
	var env = _make_env()
	var light_result = _LightInteractionResult.continue_result().add_output_event(&"request_open")
	var problems = light_result.validate(_LightEmissionTypes.LightForm.PARTICLE)
	_check(problems.is_empty(), "02 光交互 Result 应自带合法 OUTPUT_EVENT")
	var events: Array = []
	for event_id: StringName in light_result.get_output_event_ids():
		events.append(_OutputEvent.create("speed-monitor-1", event_id, 5))
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("speed-monitor-1", &"request_open", env.gate_ids.a, &"open", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events(events)
	_check(env.gates.a.current_open == true, "02 光事件桥接应打开闸门 A")
	_check(report.executed.size() == 1, "02 应执行一条命令")


## 03 去重：两来源同动作同参数 → 只执行一次。
func _test_03_dedupe() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"open", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	_check(env.gates.a.apply_calls == 1, "03 OPEN+OPEN 应只 apply 一次")
	_check(report.executed.size() == 1, "03 报告应只记一条执行")
	_check(report.conflicts.is_empty(), "03 去重不应产生冲突")


## 04 显式互斥冲突：OPEN+CLOSE → 都不执行、状态保持批次前、有 Diagnostic。
func _test_04_mutex_conflict() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"close", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	_check(env.gates.a.current_open == false, "04 冲突时目标应保持批次前状态")
	_check(env.gates.a.apply_calls == 0, "04 冲突时不应调用 apply")
	_check(report.conflicts.size() == 1, "04 应记录一条冲突")
	_check(report.conflicts[0]["reason"] == _Dispatcher.REASON_MUTEX_DECLARED, "04 冲突原因应为显式互斥")
	_check(report.executed.is_empty(), "04 冲突组应零执行")


## 05 同 Action 不同 Params：默认冲突，都不执行。
func _test_05_same_action_different_params_conflict() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"set_mode", {&"mode": 1}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"set_mode", {&"mode": 2}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	_check(env.gates.a.current_mode == 0, "05 冲突时模式应保持初始")
	_check(report.conflicts.size() == 1, "05 应记录一条冲突")
	_check(
		report.conflicts[0]["reason"] == _Dispatcher.REASON_SAME_ACTION_DIFFERENT_PARAMS,
		"05 冲突原因应为同 Action 不同 Params"
	)


## 06 invalid Target：safe no-op + Diagnostic + 其它合法命令继续（§32 Runtime）。
func _test_06_invalid_target_no_op_others_continue() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", "missing-target", &"open", {}))
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([_OutputEvent.create("src-1", &"e", 1)])
	_check(report.no_ops.size() == 1, "06 未知目标应记录一条 no-op")
	_check(report.no_ops[0]["reason"] == _Dispatcher.REASON_TARGET_NOT_FOUND, "06 原因应为目标不存在")
	_check(env.gates.a.current_open == true, "06 其它合法命令应继续执行")


## 07 无能力目标与未知动作：safe no-op + Diagnostic。
func _test_07_no_capability_and_unknown_action() -> void:
	var env = _make_env()
	var plain_id = env.registry.register_preplaced(&"plain", Vector2i(5, 0), RefCounted.new())
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", plain_id, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"explode", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	_check(report.no_ops.size() == 2, "07 应记录两条 no-op")
	var reasons: Array = []
	for entry: Dictionary in report.no_ops:
		reasons.append(entry["reason"])
	_check(reasons.has(_Dispatcher.REASON_TARGET_NO_CAPABILITY), "07 应含无目标能力 no-op")
	_check(reasons.has(_Dispatcher.REASON_ACTION_UNKNOWN), "07 应含未知动作 no-op")
	_check(env.gates.a.apply_calls == 0, "07 未知动作不应触达 apply")


## 08 参数不符 schema：运行期 safe no-op。
func _test_08_params_mismatch_no_op() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"set_mode", {&"mode": true}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([_OutputEvent.create("src-1", &"e", 1)])
	_check(report.no_ops.size() == 1, "08 参数不符应记录一条 no-op")
	_check(
		report.no_ops[0]["reason"] == _Dispatcher.REASON_ACTION_PARAMS_INVALID,
		"08 原因应为参数不符"
	)
	_check(env.gates.a.apply_calls == 0, "08 参数不符不应触达 apply")


## 09 组内多命令：不同非冲突动作按确定性顺序全部执行并链式生效。
func _test_09_multi_command_group() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"set_mode", {&"mode": 5}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-2", &"e", 1),
		_OutputEvent.create("src-1", &"e", 1),
	])
	_check(env.gates.a.current_open == true and env.gates.a.current_mode == 5, "09 两命令都应生效")
	_check(env.gates.a.apply_calls == 2, "09 应调用两次 apply")
	_check(report.executed.size() == 2, "09 应记录两条执行")


## 10 原子回滚：组内后一命令 apply 失败 → 整组回滚批次前状态。
func _test_10_atomic_rollback() -> void:
	var env = _make_env()
	env.gates.a.fail_on_action = &"set_mode"
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", env.gate_ids.a, &"set_mode", {&"mode": 5}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	_check(env.gates.a.current_open == false, "10 回滚后应回到批次前状态")
	_check(env.gates.a.current_mode == 0, "10 回滚后模式应保持初始")
	_check(
		report.no_ops[0]["reason"] == _Dispatcher.REASON_APPLY_INVALID_RESULT,
		"10 应记录 apply 失效 no-op"
	)
	_check(report.executed.is_empty(), "10 失败组不应记录执行")


## 11 级联：Batch N 提交产生新事件 → Batch N+1 派发（§31）。
func _test_11_cascade_batch_n_to_n_plus_1() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"relay", {}))
	set.add_connection(_Connection.create(env.gate_ids.a, &"gate_relayed", env.gate_ids.b, &"open", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([_OutputEvent.create("src-1", &"e", 2)])
	_check(env.gates.b.current_open == true, "11 级联事件应打开闸门 B")
	_check(report.batch_count == 2, "11 应形成两个批次")
	_check(report.executed.size() == 2, "11 两批各执行一条")


## 12 未声明级联事件：目标未声明该事件 → 丢弃 + Diagnostic（§31）。
func _test_12_undeclared_cascade_event_dropped() -> void:
	var env = _make_env()
	env.gates.a.declare_relay_event = false
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"relay", {}))
	set.add_connection(_Connection.create(env.gate_ids.a, &"gate_relayed", env.gate_ids.b, &"open", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([_OutputEvent.create("src-1", &"e", 1)])
	_check(env.gates.b.current_open == false, "12 未声明事件不应级联")
	_check(report.dropped_events.size() == 1, "12 应记录一条丢弃")
	_check(
		report.dropped_events[0]["reason"] == _Dispatcher.REASON_EVENT_NOT_DECLARED,
		"12 丢弃原因应为事件未声明"
	)
	_check(report.batch_count == 1, "12 无有效级联时批次应为 1")


## 13 确定性：相同命令集以不同到达序派发 → 相同终态与执行清单（§29）。
func _test_13_order_independence() -> void:
	var first = _make_env()
	var second = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", first.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-2", &"e", first.gate_ids.a, &"set_mode", {&"mode": 7}))
	var dispatcher_one = _Dispatcher.new(set, first.registry)
	var dispatcher_two = _Dispatcher.new(set, second.registry)
	var report_one = dispatcher_one.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
		_OutputEvent.create("src-2", &"e", 1),
	])
	var report_two = dispatcher_two.dispatch_events([
		_OutputEvent.create("src-2", &"e", 1),
		_OutputEvent.create("src-1", &"e", 1),
	])
	_check(first.gates.a.current_open == second.gates.a.current_open, "13 终态 open 应一致")
	_check(first.gates.a.current_mode == second.gates.a.current_mode, "13 终态 mode 应一致")
	_check(
		_executed_key(report_one) == _executed_key(report_two),
		"13 执行清单应与到达序无关"
	)


## 14 Reset 集成：有状态实例经可选 Hook 回到初始 Configuration 运行状态（§33）。
func _test_14_reset_integration() -> void:
	var env = _make_env()
	var open_gate = _make_gate(true, 3)
	var open_id = env.registry.register_preplaced(&"gate", Vector2i(7, 0), open_gate)
	open_gate.stable_id = open_id
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"open", {}))
	set.add_connection(_Connection.create("src-1", &"e", open_id, &"set_mode", {&"mode": 9}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	dispatcher.dispatch_events([_OutputEvent.create("src-1", &"e", 1)])
	_check(env.gates.a.current_open == true, "14 派发后闸门 A 应已打开")
	_check(open_gate.current_mode == 9, "14 派发后模式应已修改")
	var reset_count = dispatcher.reset_control_targets()
	_check(env.gates.a.current_open == false, "14 Reset 应回到初始 false")
	_check(open_gate.current_open == true, "14 Reset 应回到初始 true（配置而非硬编码）")
	_check(open_gate.current_mode == 3, "14 Reset 应回到初始模式")
	_check(reset_count == 3, "14 三个有状态实例应全部被 Reset")


## 15 级联深度上限：互发事件环安全截断并记录 Diagnostic。
func _test_15_cascade_cap() -> void:
	var env = _make_env()
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"e", env.gate_ids.a, &"relay", {}))
	set.add_connection(_Connection.create(env.gate_ids.a, &"gate_relayed", env.gate_ids.b, &"relay", {}))
	set.add_connection(_Connection.create(env.gate_ids.b, &"gate_relayed", env.gate_ids.a, &"relay", {}))
	var dispatcher = _Dispatcher.new(set, env.registry)
	var report = dispatcher.dispatch_events([
		_OutputEvent.create("src-1", &"e", 1),
	])
	_check(report.cascade_capped == true, "15 事件环应被安全截断")
	_check(report.batch_count == _Dispatcher.MAX_CASCADE_BATCHES, "15 批次应达上限值")
	_check(report.executed.size() == _Dispatcher.MAX_CASCADE_BATCHES, "15 每批恰一条执行")


## 构造测试环境：两个真实 Gate fixture 入正式注册表 + 空连接集 + Dispatcher。
func _make_env() -> Dictionary:
	var registry = _FormalObjectRegistry.new()
	var gate_a = _make_gate(false, 0)
	var gate_b = _make_gate(false, 0)
	var id_a = registry.register_preplaced(&"gate", Vector2i.ZERO, gate_a)
	var id_b = registry.register_preplaced(&"gate", Vector2i(1, 0), gate_b)
	gate_a.stable_id = id_a
	gate_b.stable_id = id_b
	var set = _ConnectionSet.new()
	set.add_connection(_Connection.create("src-1", &"request_open", id_a, &"open", {}))
	var dispatcher = _Dispatcher.new(set, registry)
	return {
		"registry": registry,
		"gates": {"a": gate_a, "b": gate_b},
		"gate_ids": {"a": id_a, "b": id_b},
		"set": set,
		"dispatcher": dispatcher,
	}


## 创建并登记待清理的 Gate fixture（Node2D，不入树）。
func _make_gate(initial_open: bool, initial_mode: int):
	var gate = _GateFixture.new(initial_open, initial_mode)
	_spawned_nodes.append(gate)
	return gate


## 执行清单的确定性排序键。
func _executed_key(report: Variant) -> String:
	var keys: Array = []
	for entry: Dictionary in report.executed:
		keys.append("%s|%s" % [entry["target_stable_id"], entry["action_id"]])
	keys.sort()
	return ",".join(keys)


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
	print("control_dispatcher_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL：%s" % failure)
