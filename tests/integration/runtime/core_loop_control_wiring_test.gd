extends SceneTree

## S3-06 Control 运行期接线集成测试（真实 core_loop_prototype.tscn，不改场景文件）。
## 实例化真实场景、入树前注入 control_connections meta 与 GridPlacedObject 控制目标 fixture，
## 经私有契约 seam（_control_dispatcher，同 core_loop_preplaced_inventory_test 读
## _inventory_controller 先例）观察：无/非法 meta → 无 Control 链（null 原型回退、关卡正常就绪）；
## 合法 meta → Dispatcher 建立；经 Dispatcher 派发 Typed 事件 → 注入目标动作面被提交（meta → 连接 →
## 解析 → 批次管线共享路径端到端）；R 重置 → §33 Reset 钩子被调用；引用不存在目标 → 安全 no-op 诊断。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _ControlOutputEvent: GDScript = preload("res://gameplay/control/control_output_event.gd")
const _GridControlTarget: GDScript = preload(
	"res://tests/unit/control/fixtures/grid_control_target_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_no_meta_no_control_chain(scene)
	await _test_02_invalid_meta_safe_fallback(scene)
	var target: Variant = await _test_03_valid_meta_dispatches_to_target(scene)
	await _test_04_reset_calls_control_hook(target)
	await _test_05_unknown_target_safe_no_op(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _ready；可选注入 control_connections meta 与控制目标 fixture。
func _ready_instance(scene: PackedScene, connections_meta: Variant, inject_target: bool) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	if connections_meta != null:
		node.set_meta("control_connections", connections_meta)
	var target: Variant = null
	if inject_target:
		target = _GridControlTarget.new()
		target.stable_instance_id = "ctl_tgt_1"
		(node.get_node("RuntimeObjects") as Node2D).add_child(target)
	root.add_child(node)
	await process_frame
	return node


## 控制派发器（私有契约 seam）。
func _dispatcher(node: Node2D) -> Variant:
	return node.get("_control_dispatcher")


## 释放实例（本测试不发射，无脉冲结算等待）。
func _free_instance(node: Node2D) -> void:
	if is_instance_valid(node):
		node.free()
	await process_frame


## 取注入目标实例（RuntimeObjects 下 fixture；实例无效返回 null）。
func _find_target(node: Node2D) -> Variant:
	if not is_instance_valid(node):
		return null
	for child: Node in (node.get_node("RuntimeObjects") as Node2D).get_children():
		if child.get_script() == _GridControlTarget:
			return child
	return null


# ===== 用例 =====

## 1. 无 meta：无 Control 链（dispatcher null），关卡正常就绪（现状行为零变化）。
func _test_01_no_meta_no_control_chain(scene: PackedScene) -> void:
	const NAME: String = "01_无meta无Control链"
	var node: Node2D = await _ready_instance(scene, null, false)
	_check(NAME, _dispatcher(node) == null, "无 control_connections meta 时派发器应为 null。")
	_check(NAME, node.get("_level_runtime_controller") != null, "关卡运行链应正常就绪（原型回退零影响）。")
	await _free_instance(node)


## 2. 非法 meta（条目非字典）：安全拒绝（dispatcher null），关卡仍正常就绪。
func _test_02_invalid_meta_safe_fallback(scene: PackedScene) -> void:
	const NAME: String = "02_非法meta安全回退"
	var node: Node2D = await _ready_instance(scene, ["not_a_dict"], false)
	_check(NAME, _dispatcher(node) == null, "非法 meta 应整体拒绝，派发器为 null。")
	_check(NAME, node.get("_level_runtime_controller") != null, "安全拒绝后关卡运行链仍应正常就绪。")
	await _free_instance(node)


## 3. 合法 meta + 注入 GridPlacedObject 控制目标：Dispatcher 建立；Typed 事件经共享路径派发到目标动作面。
##    返回目标实例供用例 4 继续验证 Reset 集成。
func _test_03_valid_meta_dispatches_to_target(scene: PackedScene) -> Variant:
	const NAME: String = "03_合法meta端到端派发"
	var node: Node2D = await _ready_instance(scene, [
		{
			"source_stable_id": "ctl_src_1", "event_id": "beam_redirected",
			"target_stable_id": "ctl_tgt_1", "action_id": "toggle_enabled", "params": {},
		},
	], true)
	var target: Variant = _find_target(node)
	if not _check(NAME, target != null, "注入的控制目标 fixture 应存在于 RuntimeObjects。"):
		await _free_instance(node)
		return null
	var dispatcher: Variant = _dispatcher(node)
	if not _check(NAME, dispatcher != null, "合法 meta 应建立 Control 派发器。"):
		await _free_instance(node)
		return null
	var report: Variant = dispatcher.dispatch_events([
		_ControlOutputEvent.create("ctl_src_1", &"beam_redirected", 3),
	])
	_check(NAME, report.executed.size() == 1, "真实场景内派发应执行 1 条命令，实际 %d。" % [report.executed.size()])
	_check(NAME, target.enabled == true and target.apply_calls == 1,
		"注入目标动作面应被提交一次且状态翻转（enabled=%s apply=%d）。" % [target.enabled, target.apply_calls])
	return target


## 4. R 重置：core_loop.reset_runtime() → Dispatcher.reset_control_targets → 目标 §33 钩子被调用并回初始态。
func _test_04_reset_calls_control_hook(target: Variant) -> void:
	const NAME: String = "04_R重置调用Control钩子"
	if not _check(NAME, target != null and is_instance_valid(target), "前置：目标实例应有效。"):
		return
	var node: Node2D = target.get_parent().get_parent()
	var calls_before: int = target.reset_calls
	node.reset_runtime()
	await process_frame
	await process_frame
	_check(NAME, target.reset_calls == calls_before + 1,
		"R 重置应恰好一次调用目标 reset 钩子（before=%d after=%d）。" % [calls_before, target.reset_calls])
	_check(NAME, target.enabled == false, "R 重置后目标状态应回初始 false，实际 %s。" % [target.enabled])
	await _free_instance(node)


## 5. 合法 meta 但连接引用不存在目标：Dispatcher 仍建立；派发安全 no-op（target_not_found 诊断）。
func _test_05_unknown_target_safe_no_op(scene: PackedScene) -> void:
	const NAME: String = "05_未知目标安全no-op"
	var node: Node2D = await _ready_instance(scene, [
		{
			"source_stable_id": "ctl_src_2", "event_id": "ghost_event",
			"target_stable_id": "ctl_tgt_absent", "action_id": "toggle_enabled", "params": {},
		},
	], false)
	var dispatcher: Variant = _dispatcher(node)
	if not _check(NAME, dispatcher != null, "引用不存在目标的连接集合仍应建立派发器。"):
		await _free_instance(node)
		return
	var report: Variant = dispatcher.dispatch_events([
		_ControlOutputEvent.create("ctl_src_2", &"ghost_event", 0),
	])
	_check(NAME, report.no_ops.size() == 1 and report.executed.is_empty(),
		"未解析目标应记 1 条 no-op 且零执行（no_ops=%d executed=%d）。" % [report.no_ops.size(), report.executed.size()])
	await _free_instance(node)


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== S3-06 Control 运行期接线集成测试摘要 ====")
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
