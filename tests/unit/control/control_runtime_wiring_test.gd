extends SceneTree

## S3-06 Control 运行期接线定向合同测试（G5 边界 + 发现口径 + 端到端共享路径）。
## 覆盖：①ControlConnectionsMetaReader——无/空 meta → null 原型回退、合法 meta → ControlConnectionSet
## 五元组事实与 String→StringName 边界转换（G5）、七类非法形状整体原子拒绝、五元组重复拒绝；
## ②ControlRuntimeTargetIndex——正式对象发现口径（GridPlacedObject/PlaceableToken 子树递归、
## 空 stable_id 跳过、非正式类跳过、重复 ID 保首）、has_object/get_object_snapshot/Reset 遍历契约面；
## ③端到端共享路径——meta → 连接集合 → Dispatcher（AF-05 冻结批次管线）→ 目标动作面四件 +
## §33 Reset 集成，使用 grid_control_target_fixture（真实 GridPlacedObject 发现口径）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _Reader: GDScript = preload(
	"res://gameplay/control/dispatch/control_connections_meta_reader.gd"
)
const _TargetIndex: GDScript = preload(
	"res://gameplay/control/dispatch/control_runtime_target_index.gd"
)
const _Dispatcher: GDScript = preload(
	"res://gameplay/control/dispatch/control_dispatcher.gd"
)
const _ControlOutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)
const _GridControlTarget: GDScript = preload(
	"res://tests/unit/control/fixtures/grid_control_target_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_reader_absent_and_empty_meta()
	_test_02_reader_valid_build_and_g5_conversion()
	_test_03_reader_invalid_shapes_atomic_reject()
	_test_04_index_discovery_scope()
	_test_05_index_contract_faces()
	_test_06_end_to_end_dispatch_and_reset()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 用例 =====

## 1. 无 meta / 空数组 → null 原型回退（静默，不构造 Control 链）。
func _test_01_reader_absent_and_empty_meta() -> void:
	const NAME: String = "01_reader无与空meta回退"
	var bare: Node2D = Node2D.new()
	_check(NAME, _Reader.build_connection_set(bare) == null, "无 meta 应返回 null。")
	bare.set_meta("control_connections", [])
	_check(NAME, _Reader.build_connection_set(bare) == null, "空数组应返回 null。")
	bare.free()


## 2. 合法构造：两条连接（含 bool/int 参数与空 params 默认）五元组事实 + G5 类型转换。
func _test_02_reader_valid_build_and_g5_conversion() -> void:
	const NAME: String = "02_reader合法构造与G5转换"
	var root: Node2D = Node2D.new()
	root.set_meta("control_connections", [
		{
			"source_stable_id": "src_1", "event_id": "beam_redirected",
			"target_stable_id": "tgt_1", "action_id": "toggle_enabled",
			"params": {"enabled": true, "mode": 2},
		},
		{
			"source_stable_id": "src_2", "event_id": "speed_checked",
			"target_stable_id": "tgt_2", "action_id": "open",
		},
	])
	var connection_set: Variant = _Reader.build_connection_set(root)
	if not _check(NAME, connection_set != null, "合法 meta 应构造连接集合。"):
		root.free()
		return
	_check(NAME, connection_set.get_count() == 2, "连接数期望 2，实际 %d。" % [connection_set.get_count()])
	var connections: Array = connection_set.get_all_connections()
	var first: Variant = connections[0]
	_check(NAME, first.source_stable_id == "src_1", "首条 source 应为 src_1。")
	_check(NAME, first.target_stable_id == "tgt_1", "首条 target 应为 tgt_1。")
	_check(NAME, typeof(first.event_id) == TYPE_STRING_NAME and first.event_id == &"beam_redirected",
		"event_id 应为 StringName 且值保持（G5）。")
	_check(NAME, typeof(first.action_id) == TYPE_STRING_NAME and first.action_id == &"toggle_enabled",
		"action_id 应为 StringName 且值保持（G5）。")
	var params: Dictionary = first.params
	_check(NAME, params.size() == 2, "首条 params 数期望 2。")
	var all_keys_stringname: bool = true
	for key: Variant in params.keys():
		if typeof(key) != TYPE_STRING_NAME:
			all_keys_stringname = false
	_check(NAME, all_keys_stringname, "params 键应全部转换为 StringName（G5）。")
	_check(NAME, params.get(&"enabled", null) == true and typeof(params.get(&"enabled")) == TYPE_BOOL,
		"bool 参数应原样透传且类型保持。")
	_check(NAME, params.get(&"mode", null) == 2 and typeof(params.get(&"mode")) == TYPE_INT,
		"int 参数应原样透传且类型保持。")
	var second: Variant = connections[1]
	_check(NAME, second.params.is_empty(), "缺省 params 应为空字典。")
	root.free()


## 3. 七类非法形状 + 五元组重复：整体原子拒绝返回 null（不返回半套集合）。
func _test_03_reader_invalid_shapes_atomic_reject() -> void:
	const NAME: String = "03_reader非法形状原子拒绝"
	var root: Node2D = Node2D.new()
	var cases: Dictionary = {
		"meta非数组": {"a": 1},
		"条目非字典": ["not_a_dict"],
		"四段ID空": [_entry_with("source_stable_id", "")],
		"params非字典": [_entry_with("params", "bad")],
		"params空键": [_entry_with("params", {"": true})],
		"params浮点值": [_entry_with("params", {"speed": 1.5})],
		"params字符串值": [_entry_with("params", {"speed": "2"})],
		"五元组重复": [_valid_entry(), _valid_entry()],
	}
	for case_name: String in cases.keys():
		root.set_meta("control_connections", cases[case_name])
		var result: Variant = _Reader.build_connection_set(root)
		_check(NAME, result == null, "非法形状 %s 应被整体拒绝返回 null。" % case_name)
	root.free()


## 合法连接条目模板（detached 副本）。
static func _valid_entry() -> Dictionary:
	return {
		"source_stable_id": "src_1", "event_id": "beam_redirected",
		"target_stable_id": "tgt_1", "action_id": "toggle_enabled", "params": {},
	}


## 覆盖单字段的合法条目变体。
static func _entry_with(field: String, value: Variant) -> Dictionary:
	var entry: Dictionary = _valid_entry()
	entry[field] = value
	return entry


## 4. 目标索引发现口径：正式类递归发现、空 ID 跳过、非正式类跳过、深层嵌套可达。
func _test_04_index_discovery_scope() -> void:
	const NAME: String = "04_index发现口径"
	var root: Node2D = Node2D.new()
	var grid_a: GridPlacedObject = GridPlacedObject.new()
	grid_a.stable_instance_id = "grid_a"
	root.add_child(grid_a)
	var token_b: PlaceableToken = PlaceableToken.new()
	token_b.stable_instance_id = "token_b"
	root.add_child(token_b)
	var grid_empty: GridPlacedObject = GridPlacedObject.new()
	grid_empty.stable_instance_id = ""
	root.add_child(grid_empty)
	var plain: Node2D = Node2D.new()
	root.add_child(plain)
	var nested_parent: Node2D = Node2D.new()
	root.add_child(nested_parent)
	var grid_nested: GridPlacedObject = GridPlacedObject.new()
	grid_nested.stable_instance_id = "grid_nested"
	nested_parent.add_child(grid_nested)
	var index: Variant = _TargetIndex.build_from(root)
	_check(NAME, index.get_count() == 3, "正式对象发现数期望 3（grid_a/token_b/grid_nested），实际 %d。" % [index.get_count()])
	_check(NAME, index.has_object("grid_a") and index.has_object("token_b") and index.has_object("grid_nested"),
		"三个正式对象应全部可解析。")
	_check(NAME, not index.has_object(""), "空 stable_id 不应入索引。")
	root.free()


## 5. 索引契约面：快照 detached 结构、缺席空字典、Reset 遍历面全量返回、重复 ID 保首。
func _test_05_index_contract_faces() -> void:
	const NAME: String = "05_index契约面"
	var root: Node2D = Node2D.new()
	var first: GridPlacedObject = GridPlacedObject.new()
	first.stable_instance_id = "dup_id"
	root.add_child(first)
	var second: GridPlacedObject = GridPlacedObject.new()
	second.stable_instance_id = "dup_id"
	root.add_child(second)
	var other: GridPlacedObject = GridPlacedObject.new()
	other.stable_instance_id = "other_id"
	root.add_child(other)
	var index: Variant = _TargetIndex.build_from(root)
	_check(NAME, index.get_count() == 2, "重复 stable_id 应保首去重，索引数期望 2，实际 %d。" % [index.get_count()])
	var snapshot: Dictionary = index.get_object_snapshot("dup_id")
	_check(NAME, snapshot.get("instance") == first, "重复 ID 快照应解析首个实例。")
	_check(NAME, snapshot.get("stable_instance_id") == "dup_id", "快照应携带 stable_instance_id 键。")
	_check(NAME, index.get_object_snapshot("absent_id") == {}, "未登记 ID 快照应返回空字典。")
	var preplaced_ids: Array = index.get_stable_ids_by_origin(&"preplaced")
	var spawned_ids: Array = index.get_stable_ids_by_origin(&"spawned")
	_check(NAME, preplaced_ids.size() == 2 and spawned_ids.is_empty(),
		"Reset 遍历面 preplaced 应全量返回 2、spawned 应为空（preplaced=%d spawned=%d）。" % [preplaced_ids.size(), spawned_ids.size()])
	root.free()


## 6. 端到端共享路径：meta → 连接集合 → Dispatcher → 目标动作面（四件套）+ §33 Reset 集成。
func _test_06_end_to_end_dispatch_and_reset() -> void:
	const NAME: String = "06_端到端派发与Reset"
	var root: Node2D = Node2D.new()
	var target: Variant = _GridControlTarget.new()
	target.stable_instance_id = "tgt_1"
	root.add_child(target)
	root.set_meta("control_connections", [
		{
			"source_stable_id": "src_1", "event_id": "beam_redirected",
			"target_stable_id": "tgt_1", "action_id": "toggle_enabled", "params": {},
		},
		{
			"source_stable_id": "src_9", "event_id": "ghost_event",
			"target_stable_id": "tgt_absent", "action_id": "toggle_enabled", "params": {},
		},
	])
	var connection_set: Variant = _Reader.build_connection_set(root)
	var index: Variant = _TargetIndex.build_from(root)
	if not _check(NAME, connection_set != null and index.has_object("tgt_1"), "前置：连接集合构造且目标可解析。"):
		root.free()
		return
	var dispatcher: Variant = _Dispatcher.new(connection_set, index)
	var report: Variant = dispatcher.dispatch_events([
		_ControlOutputEvent.create("src_1", &"beam_redirected", 0),
	])
	_check(NAME, report.executed.size() == 1, "合法事件应执行 1 条命令，实际 %d。" % [report.executed.size()])
	_check(NAME, target.enabled == true and target.apply_calls == 1,
		"目标动作面应被提交一次且状态翻转（enabled=%s apply=%d）。" % [target.enabled, target.apply_calls])
	var unrelated: Variant = dispatcher.dispatch_events([_ControlOutputEvent.create("src_1", &"unrelated_event", 1)])
	_check(NAME, target.apply_calls == 1 and unrelated.no_ops.is_empty(),
		"无订阅事件不应触发动作面且不产生诊断。")
	var ghost: Variant = dispatcher.dispatch_events([
		_ControlOutputEvent.create("src_9", &"ghost_event", 2),
	])
	_check(NAME, ghost.no_ops.size() == 1, "目标未解析的连接应记 target_not_found no-op，实际 %d。" % [ghost.no_ops.size()])
	target.enabled = true
	var reset_count: int = dispatcher.reset_control_targets()
	_check(NAME, reset_count == 1 and target.reset_calls == 1 and target.enabled == false,
		"Reset 集成应调用目标钩子并回初始状态（reset=%d enabled=%s）。" % [target.reset_calls, target.enabled])
	root.free()


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== S3-06 Control 运行期接线合同测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
