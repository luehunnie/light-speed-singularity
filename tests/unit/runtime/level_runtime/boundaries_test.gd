extends SceneTree

## LevelRuntimeController 单元测试（拆分片 5/5 · 无效输入、边界与源码契约）。
## 覆盖：Controller 不直接持 UI 节点、不直接修改水晶/库存/占用/放置事实（静态源码契约）。
## 只读取生产脚本做令牌扫描，不执行运行期事务；桩与装配见 fixtures/runtime_controller_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 持有装配夹具（本片虽不装配控制器，但保持与其他片一致的释放边界）。
var _fixture: _Fixture = null


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 get_tree() 可用。
	await process_frame
	_fixture = _Fixture.new(self)
	_run_all_tests()
	_report()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	_test_25_controller_holds_no_ui_nodes()
	_test_26_controller_does_not_mutate_facts_directly()


# ===== 测试用例 =====

## 25. Controller 不直接持 UI 节点：源码不引用 @onready UI 节点、场景路径、get_node 或 UI 节点类型。
func _test_25_controller_holds_no_ui_nodes() -> void:
	const NAME: String = "25_Controller不持UI节点"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	# 检查 UI 节点访问模式（@onready/$路径/get_node）与 UI 节点类型，不匹配 Callable 名中的小写 label。
	var forbidden: Array = [
		"@onready", "$", "get_node(", ": Label", ": Control",
		"CanvasLayer", "LightPathLayer", "TextureRect", "RuntimeMoveLabel"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "Controller 不应引用 UI 节点/场景路径令牌：%s" % [token])


## 26. Controller 不直接修改水晶/库存字典/占用表：源码不直接调 crystal.activate、_inventory.try_、_occupancy.register/unregister。
func _test_26_controller_does_not_mutate_facts_directly() -> void:
	const NAME: String = "26_Controller不直接改事实"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var forbidden: Array = [
		"crystal.activate", "crystal.reset_runtime", "_inventory_controller.try_consume",
		"_inventory_controller.try_return", "_inventory_controller.reconcile",
		"_occupancy.register", "_occupancy.unregister", "_occupancy.clear",
		"_placement_controller.place_from_inventory", "_placement_controller.move_placed",
		"_placement_controller.recycle_placed"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "Controller 不应直接修改水晶/库存/占用/放置事实：%s" % [token])
	# 水晶激活经 ObjectiveController 间接进行，库存/占用经 PlacementController 原子事务，Controller 只读事实。


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 2
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController 边界与源码契约测试摘要 ====")
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
