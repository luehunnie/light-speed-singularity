extends SceneTree

## S3-07 五 Slot 运行期正式绑定集成测试。
##
## 实例化真实 core_loop_prototype.tscn 挂入 SceneTree 触发真实 _ready（运行期接线打标记），
## 只读断言五类正式宿主已挂合同 meta ui_binding_slot_id 且指向正确节点。
## 节点经公开场景角色路径观测（与 core_loop_start_run_test 同一冻结约定：
## CanvasLayer/HintLabel、CanvasLayer/StartRunButton 等），不访问私有字段。
##
## 覆盖：
##   01 五宿主标记就位（inventory=InventoryBar / objective=CompleteLabel /
##      move_counter=RuntimeMoveLabel / hint=HintLabel / fire_reset=StartRunButton），
##      宿主无脚本绑定（合同 script_binding_forbidden 冻结红线），
##      合同 find_slots 发现一致（恰好五类、每类唯一、与公开路径宿主同节点）；
##   02 Start Run → R 重置后标记保持；每用例全新实例即「重新装载由 _ready 重建」覆盖。
##
## 由 Godot --headless --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _Contract: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_binding_slot_contract.gd"
)

## 五宿主期望表 [slot_id, 公开场景角色路径]；顺序与合同 SLOT_IDS 一致。
## 火重置宿主为 RunStartView 运行期创建的「开始运行」按钮（core_loop_start_run_test 冻结的公开角色路径）。
const _HOSTS: Array = [
	["inventory_host", "CanvasLayer/InventoryBar"],
	["objective_host", "CanvasLayer/CompleteLabel"],
	["move_counter_host", "CanvasLayer/RuntimeMoveLabel"],
	["hint_host", "CanvasLayer/HintLabel"],
	["fire_reset_host", "CanvasLayer/StartRunButton"],
]

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：逐用例独立实例化场景，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_five_hosts_marked(scene)
	await _test_02_reset_keeps_marks(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _ready（运行期打标记）。
func _ready_instance(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	root.add_child(node)
	await process_frame
	return node


## 释放实例（无脉冲发射，无需脉冲沉淀等待）。
func _free_instance(node: Node2D) -> void:
	if is_instance_valid(node):
		node.free()
	await process_frame


## 按期望表逐宿主断言 meta 就位；返回 false 时上层仍继续其余断言。
func _assert_hosts_marked(node: Node2D, contract, group_name: String) -> void:
	for entry: Array in _HOSTS:
		var slot_id: String = String(entry[0])
		var path: String = String(entry[1])
		_check(group_name, slot_id in contract.SLOT_IDS, "期望表 %s 应在冻结合同五 Slot 内。" % slot_id)
		var host: Control = node.get_node_or_null(path) as Control
		_check(group_name, host != null, "宿主缺失或非 Control：%s。" % path)
		if host == null:
			continue
		var actual_id: String = String(host.get_meta(contract.META_KEY, ""))
		_check(group_name, actual_id == slot_id, "%s 应挂正式标记 %s，实际「%s」。" % [path, slot_id, actual_id])
		_check(group_name, host.get_script() == null, "%s 为受保护 Slot 宿主，不得挂脚本绑定。" % path)


# ===== 用例 =====

## 1. 五宿主正式标记：真实 _ready 后五宿主各挂合同 meta、无脚本绑定；
##    合同 find_slots 发现恰好五类且每类唯一，发现节点与公开路径宿主为同一节点（无合同外标记）。
func _test_01_five_hosts_marked(scene: PackedScene) -> void:
	const NAME: String = "01_五宿主正式标记"
	var node: Node2D = await _ready_instance(scene)
	var contract = _Contract.new()
	_assert_hosts_marked(node, contract, NAME)
	var slots: Dictionary = contract.find_slots(node)
	_check(NAME, slots.size() == 5, "find_slots 应发现五类 Slot，实际 %d。" % slots.size())
	for entry: Array in _HOSTS:
		var slot_id: String = String(entry[0])
		var owners: Array = slots.get(slot_id, [])
		_check(NAME, owners.size() == 1, "Slot %s 应唯一，实际 %d 处。" % [slot_id, owners.size()])
		if owners.size() == 1:
			_check(NAME, owners[0] == node.get_node_or_null(String(entry[1])), "Slot %s 发现节点应与公开路径宿主一致。" % slot_id)
	await _free_instance(node)


## 2. 生命周期保持：Start Run 进 READY → R 完整重置回 SETUP 后五宿主标记仍在
##    （R 不重建 CanvasLayer 子节点）；本用例为全新实例即覆盖「重新装载由 _ready 重建」。
func _test_02_reset_keeps_marks(scene: PackedScene) -> void:
	const NAME: String = "02_R重置保持标记"
	var node: Node2D = await _ready_instance(scene)
	var contract = _Contract.new()
	node.start_run()
	node.reset_runtime()
	await process_frame
	_assert_hosts_marked(node, contract, NAME)
	await _free_instance(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== core_loop 五 Slot 运行期正式绑定集成测试摘要（S3-07）====")
	print("测试组数：2")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
