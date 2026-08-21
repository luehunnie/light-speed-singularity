extends SceneTree

## AF-05 控制域数据层定向合同测试（Guide §26.2 / §26.3 / §30 + §4.1 声明面）。
## 覆盖：ControlEventDefinition / ControlActionDefinition 声明与校验、params schema 匹配与
##   确定性比较、ControlOutputEvent 构造、ControlConnection 结构与 schema 校验、
##   ControlConnectionSet 收录 / 事件检索 / 重复拒绝、ControlActionResult 构造校验、
##   MechanismDefinition 控制域能力字段校验（作者可枚举元数据）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _EventDefinition: GDScript = preload(
	"res://gameplay/control/control_event_definition.gd"
)
const _ActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)
const _OutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)
const _Connection: GDScript = preload(
	"res://gameplay/control/control_connection.gd"
)
const _ConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)
const _ActionResult: GDScript = preload(
	"res://gameplay/control/control_action_result.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_event_definition()
	_test_02_action_definition_validation()
	_test_03_params_check()
	_test_04_params_equality()
	_test_05_output_event()
	_test_06_connection_structure()
	_test_07_connection_schema()
	_test_08_connection_set()
	_test_09_action_result()
	_test_10_mechanism_definition_control_fields()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 01 事件声明：合法 / 空 ID / 空展示名。
func _test_01_event_definition() -> void:
	var valid = _EventDefinition.new()
	valid.event_id = &"speed_matched"
	valid.display_name = "速度匹配"
	_check(valid.validate().is_empty(), "01 合法事件声明应通过")
	var no_id = _EventDefinition.new()
	no_id.display_name = "缺 ID"
	_check(not no_id.validate().is_empty(), "01 空 event_id 应被拒绝")
	var no_name = _EventDefinition.new()
	no_name.event_id = &"e"
	_check(not no_name.validate().is_empty(), "01 空 display_name 应被拒绝")


## 02 动作声明：合法 / 空 ID / 非法 schema 条目 / 重复 param_id / 非法值类型 token / 自指互斥 / 重复互斥。
func _test_02_action_definition_validation() -> void:
	var valid = _ActionDefinition.new()
	valid.action_id = &"set_mode"
	valid.display_name = "设置模式"
	valid.param_schema = [
		{"param_id": &"mode", "value_type": _ActionDefinition.VALUE_TYPE_INT},
		{"param_id": &"force", "value_type": _ActionDefinition.VALUE_TYPE_BOOL},
	]
	valid.add_mutually_exclusive([&"set_speed"])
	_check(valid.validate().is_empty(), "02 合法动作声明应通过")
	var empty_id = _ActionDefinition.new()
	empty_id.display_name = "缺 ID"
	_check(not empty_id.validate().is_empty(), "02 空 action_id 应被拒绝")
	var bad_entry = _ActionDefinition.new()
	bad_entry.action_id = &"a"
	bad_entry.display_name = "A"
	bad_entry.param_schema = ["not_a_dict"]
	_check(not bad_entry.validate().is_empty(), "02 非 Dictionary schema 条目应被拒绝")
	var dup_param = _ActionDefinition.new()
	dup_param.action_id = &"a"
	dup_param.display_name = "A"
	dup_param.param_schema = [
		{"param_id": &"x", "value_type": _ActionDefinition.VALUE_TYPE_BOOL},
		{"param_id": &"x", "value_type": _ActionDefinition.VALUE_TYPE_BOOL},
	]
	_check(not dup_param.validate().is_empty(), "02 重复 param_id 应被拒绝")
	var bad_token = _ActionDefinition.new()
	bad_token.action_id = &"a"
	bad_token.display_name = "A"
	bad_token.param_schema = [{"param_id": &"x", "value_type": &"STRING"}]
	_check(not bad_token.validate().is_empty(), "02 非法值类型 token 应被拒绝")
	var self_mutex = _ActionDefinition.new()
	self_mutex.action_id = &"a"
	self_mutex.display_name = "A"
	self_mutex.add_mutually_exclusive([&"a"])
	_check(not self_mutex.validate().is_empty(), "02 自指互斥应被拒绝")
	var dup_mutex = _ActionDefinition.new()
	dup_mutex.action_id = &"a"
	dup_mutex.display_name = "A"
	dup_mutex.add_mutually_exclusive([&"b", &"b"])
	_check(not dup_mutex.validate().is_empty(), "02 重复互斥声明应被拒绝")


## 03 params 匹配：精确键集 / 缺参 / 多参 / 类型不符（bool≠int）/ 非法键类型。
func _test_03_params_check() -> void:
	var definition = _ActionDefinition.new()
	definition.action_id = &"set_mode"
	definition.display_name = "设置模式"
	definition.param_schema = [
		{"param_id": &"mode", "value_type": _ActionDefinition.VALUE_TYPE_INT},
		{"param_id": &"force", "value_type": _ActionDefinition.VALUE_TYPE_BOOL},
	]
	_check(
		definition.check_params({&"mode": 2, &"force": false}).is_empty(),
		"03 精确匹配应通过"
	)
	_check(
		not definition.check_params({&"mode": 2}).is_empty(),
		"03 缺参应被拒绝"
	)
	_check(
		not definition.check_params({&"mode": 2, &"force": false, &"extra": 1}).is_empty(),
		"03 多余参数应被拒绝"
	)
	_check(
		not definition.check_params({&"mode": true, &"force": false}).is_empty(),
		"03 INT 参数收到 bool 应被拒绝"
	)
	_check(
		not definition.check_params({&"mode": 2, &"force": 1}).is_empty(),
		"03 BOOL 参数收到 int 应被拒绝"
	)
	_check(
		not definition.check_params({"mode": 2, &"force": false}).is_empty(),
		"03 String 键应被拒绝（键须为 StringName）"
	)


## 04 params 确定性：canonical key 与顺序无关；等价判定；类型前缀区分 bool/int。
func _test_04_params_equality() -> void:
	var a := {&"mode": 3, &"force": true}
	var b := {&"force": true, &"mode": 3}
	_check(
		_ActionDefinition.canonical_params_key(a) == _ActionDefinition.canonical_params_key(b),
		"04 canonical key 应与键序无关"
	)
	_check(_ActionDefinition.params_equal(a, b), "04 等价 params 应判定相等")
	_check(
		not _ActionDefinition.params_equal(a, {&"mode": 4, &"force": true}),
		"04 不同值应判定不等"
	)
	_check(
		_ActionDefinition.canonical_params_key({&"x": 1}) != _ActionDefinition.canonical_params_key({&"x": true}),
		"04 bool 与 int 同值应产生不同 canonical key"
	)


## 05 Output Event：合法构造 / 空来源 / 空事件 / 负运行代。
func _test_05_output_event() -> void:
	var event = _OutputEvent.create("obj-1", &"speed_matched", 3)
	_check(event != null, "05 合法事件应构造成功")
	_check(event.source_stable_id == "obj-1" and event.event_id == &"speed_matched", "05 事件字段应原样携带")
	_check(event.runtime_generation == 3, "05 运行代应原样携带")
	_check(_OutputEvent.create("", &"e", 1) == null, "05 空来源应拒绝构造")
	_check(_OutputEvent.create("obj-1", &"", 1) == null, "05 空事件 ID 应拒绝构造")
	_check(_OutputEvent.create("obj-1", &"e", -1) == null, "05 负运行代应拒绝构造")


## 06 Connection 结构：合法 / 空 ID 段 / 非法 params 键 / 非法 params 值类型。
func _test_06_connection_structure() -> void:
	var connection = _Connection.create("src-1", &"e", "dst-1", &"open", {&"mode": 2})
	_check(connection != null, "06 合法连接应构造成功")
	_check(connection.get_params_key() == "mode=i:2", "06 params key 应为确定性 token")
	_check(_Connection.create("", &"e", "dst-1", &"open", {}) == null, "06 空 source 应拒绝")
	_check(_Connection.create("src-1", &"", "dst-1", &"open", {}) == null, "06 空 event_id 应拒绝")
	_check(_Connection.create("src-1", &"e", "", &"open", {}) == null, "06 空 target 应拒绝")
	_check(_Connection.create("src-1", &"e", "dst-1", &"", {}) == null, "06 空 action_id 应拒绝")
	_check(
		_Connection.create("src-1", &"e", "dst-1", &"open", {"mode": 1}) == null,
		"06 String 键 params 应拒绝"
	)
	_check(
		_Connection.create("src-1", &"e", "dst-1", &"open", {&"mode": 1.5}) == null,
		"06 float 值 params 应拒绝"
	)
	_check(
		_Connection.create("src-1", &"e", "dst-1", &"open", {&"mode": "fast"}) == null,
		"06 String 值 params 应拒绝"
	)


## 07 Connection 对照动作 schema：匹配 / 缺参 / 类型不符 / 非法声明对象。
func _test_07_connection_schema() -> void:
	var definition = _ActionDefinition.new()
	definition.action_id = &"set_mode"
	definition.display_name = "设置模式"
	definition.param_schema = [{"param_id": &"mode", "value_type": _ActionDefinition.VALUE_TYPE_INT}]
	var matched = _Connection.create("s", &"e", "t", &"set_mode", {&"mode": 1})
	var missing = _Connection.create("s", &"e", "t", &"set_mode", {})
	var wrong_type = _Connection.create("s", &"e", "t", &"set_mode", {&"mode": false})
	_check(matched.validate_against_action(definition).is_empty(), "07 匹配 schema 应通过")
	_check(not missing.validate_against_action(definition).is_empty(), "07 缺参应被拒绝")
	_check(not wrong_type.validate_against_action(definition).is_empty(), "07 类型不符应被拒绝")
	_check(not matched.validate_against_action(RefCounted.new()).is_empty(), "07 非动作声明对象应被拒绝")


## 08 ConnectionSet：收录 / 事件检索 / 重复五元组拒绝 / 计数。
func _test_08_connection_set() -> void:
	var set = _ConnectionSet.new()
	var first = _Connection.create("src-1", &"e", "dst-1", &"open", {})
	var second = _Connection.create("src-1", &"e", "dst-2", &"close", {})
	var duplicate = _Connection.create("src-1", &"e", "dst-1", &"open", {})
	_check(set.add_connection(first), "08 首次收录应成功")
	_check(set.add_connection(second), "08 第二条收录应成功")
	_check(not set.add_connection(duplicate), "08 重复五元组应被拒绝")
	_check(set.get_count() == 2, "08 计数应为 2")
	var hits = set.get_connections_for_event("src-1", &"e")
	_check(hits.size() == 2, "08 事件检索应命中两条")
	_check(set.get_connections_for_event("src-1", &"other").is_empty(), "08 无订阅事件应返回空")
	_check(set.get_connections_for_event("src-9", &"e").is_empty(), "08 未知来源应返回空")
	_check(not set.add_connection(null), "08 null 条目应被拒绝")


## 09 ControlActionResult：合法构造 / 非正式事件成员拒绝 / 空事件合法。
func _test_09_action_result() -> void:
	var event = _OutputEvent.create("t-1", &"gate_relayed", 2)
	var valid = _ActionResult.create({"open": true}, [event])
	_check(valid != null, "09 合法结果应构造成功")
	_check(valid.candidate_state["open"] == true, "09 候选状态应原样携带")
	var empty_events = _ActionResult.create(null, [])
	_check(empty_events != null, "09 无状态无事件结果应合法")
	_check(_ActionResult.create(null, [RefCounted.new()]) == null, "09 非正式事件成员应拒绝构造")


## 10 MechanismDefinition 控制域字段：合法声明 / 非成员拒绝 / 重复 event_id / 重复 action_id。
func _test_10_mechanism_definition_control_fields() -> void:
	var definition = _MechanismDefinition.new()
	definition.content_type_id = &"test_gate"
	definition.display_name = "测试闸门"
	definition.scene = PackedScene.new()
	definition.has_control_runtime_state = true
	var event_definition = _EventDefinition.new()
	event_definition.event_id = &"gate_relayed"
	event_definition.display_name = "闸门转发"
	var action_definition = _ActionDefinition.new()
	action_definition.action_id = &"open"
	action_definition.display_name = "打开"
	definition.control_output_events = [event_definition]
	definition.control_actions = [action_definition]
	_check(definition.validate_definition().is_empty(), "10 合法控制域声明应通过")
	definition.control_output_events = [RefCounted.new()]
	_check(not definition.validate_definition().is_empty(), "10 非事件成员应被拒绝")
	definition.control_output_events = [event_definition]
	definition.control_actions = [action_definition, action_definition]
	_check(not definition.validate_definition().is_empty(), "10 重复 action_id 应被拒绝")
	definition.control_actions = [action_definition]
	var duplicate_event = _EventDefinition.new()
	duplicate_event.event_id = &"gate_relayed"
	duplicate_event.display_name = "重复事件"
	definition.control_output_events = [event_definition, duplicate_event]
	_check(not definition.validate_definition().is_empty(), "10 重复 event_id 应被拒绝")


## 断言与汇报（AF-02 测试惯例）。
func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _report() -> void:
	print("control_contract_data_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL：%s" % failure)
