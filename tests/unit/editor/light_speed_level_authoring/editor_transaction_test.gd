extends SceneTree

# AF-08 编辑事务（EditorTransaction）测试（游戏模式 UndoRedo 口径；真实 EditorUndoRedoManager
# do-path 由 GUI Human Gate 覆盖——两套 API 分发逻辑同源，游戏模式证明 Callable 侧）。
# 覆盖：commit 即执行 do、undo 恢复、redo 重放、do/undo properties、null 直发模式、结构非法拒绝。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _EditorTransaction: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_transaction.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_run_tests()


## 顺序运行全部用例；06 前泵一帧——守卫判据 is_inside_tree 需节点真实入树，
## 而 _initialize 期间 get_root().add_child 不会同步触发 ENTER_TREE（headless --script 事实）。
func _run_tests() -> void:
	_test_01_commit_undo_redo()
	_test_02_properties()
	_test_03_null_direct_mode()
	_test_04_invalid_structure_rejected()
	_test_05_palette_shape_anchor()
	await process_frame
	_test_06_eurm_undo_target_guard()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _test_01_commit_undo_redo() -> void:
	const NAME: String = "01_提交/撤销/重做"
	var node := Node2D.new()
	node.position = Vector2.ZERO
	var undo := UndoRedo.new()
	var operations: Array = [{
		"target": node,
		"do": ["set_position", [Vector2(100, 0)]],
		"undo": ["set_position", [Vector2.ZERO]],
	}]
	_check(NAME, _EditorTransaction.commit(undo, "移动", operations), "事务应提交成功。")
	_check(NAME, node.position == Vector2(100, 0), "commit 应立即执行 do 段。")
	undo.undo()
	_check(NAME, node.position == Vector2.ZERO, "undo 应恢复原状。")
	undo.redo()
	_check(NAME, node.position == Vector2(100, 0), "redo 应重放 do 段。")
	node.free()


func _test_02_properties() -> void:
	const NAME: String = "02_属性登记"
	var node := Node2D.new()
	node.name = &"Before"
	var undo := UndoRedo.new()
	var operations: Array = [{
		"target": node,
		"do": ["set_position", [Vector2(5, 5)]],
		"undo": ["set_position", [Vector2.ZERO]],
		"do_properties": [["name", &"After"]],
		"undo_properties": [["name", &"Before"]],
	}]
	_EditorTransaction.commit(undo, "改名", operations)
	_check(NAME, node.name == &"After", "do_properties 应生效。")
	undo.undo()
	_check(NAME, node.name == &"Before", "undo_properties 应恢复。")
	node.free()


func _test_03_null_direct_mode() -> void:
	const NAME: String = "03_直发模式"
	var node := Node2D.new()
	var operations: Array = [{
		"target": node,
		"do": ["set_position", [Vector2(7, 7)]],
		"undo": ["set_position", [Vector2.ZERO]],
	}]
	_check(NAME, _EditorTransaction.commit(null, "直发", operations), "null 撤销管理器应直发 do 段。")
	_check(NAME, node.position == Vector2(7, 7), "直发应已执行。")
	node.free()


func _test_04_invalid_structure_rejected() -> void:
	const NAME: String = "04_结构非法拒绝"
	var node := Node2D.new()
	var undo := UndoRedo.new()
	var bad: Array = [{"target": null, "do": [], "undo": []}]
	_check(NAME, not _EditorTransaction.commit(undo, "非法", bad), "缺 target 应整体拒绝。")
	_check(NAME, not _EditorTransaction.commit(undo, "空操作", []), "空操作列表应拒绝。")
	node.free()


## 5. Palette 放置事务形状（AF-09 P0）：owner 只登记 do 侧；anchor 传关卡根。
## commit 即 add_child+owner；undo 仅 remove_child（无 owner undo 属性）；redo 恢复同一节点与 owner。
## 真实 EditorUndoRedoManager 的 common_parent 修复验收留编辑器 Human Gate。
func _test_05_palette_shape_anchor() -> void:
	const NAME: String = "05_放置形状与锚点"
	var root := Node2D.new()
	var container := Node2D.new()
	container.name = &"RuntimeObjects"
	root.add_child(container)
	var placed := Node2D.new()
	var undo := UndoRedo.new()
	var operations: Array = [
		{"target": container, "do": ["add_child", [placed]], "undo": ["remove_child", [placed]]},
		{"target": placed, "do_properties": [["owner", root]]},
	]
	_check(NAME, _EditorTransaction.commit(undo, "Palette 放置", operations, root),
		"带锚点（第 4 参）事务应提交成功。")
	_check(NAME, placed.get_parent() == container, "commit 应立即把 placed 加入容器。")
	_check(NAME, placed.owner == root, "do_properties 应把 owner 设为关卡根。")
	undo.undo()
	_check(NAME, placed.get_parent() == null, "undo 应仅移除节点（不再登记 owner undo 属性）。")
	_check(NAME, is_instance_valid(placed), "undo 后节点应仍存活（供 redo 重放同一节点）。")
	undo.redo()
	_check(NAME, placed.get_parent() == container and placed.owner == root,
		"redo 应恢复同一节点与 owner。")
	undo.undo()
	placed.free()
	root.free()


## 6. EURM undo 段守卫：未入树节点的 undo 段应被识别（真实编辑器分支整体拒绝的判定依据）；
## do-only（引擎实例化事务同形）不受限。headless 无法实例化 EditorUndoRedoManager，直测判定函数。
func _test_06_eurm_undo_target_guard() -> void:
	const NAME: String = "06_EURM_undo目标守卫"
	var root := Node2D.new()
	var container := Node2D.new()
	root.add_child(container)
	# 守卫判据是 is_inside_tree：root 须真实入树（headless 下挂在 SceneTree 根），才与编辑器事实一致。
	get_root().add_child(root)
	var detached := Node2D.new()
	var bad: Array = [
		{"target": container, "do": ["add_child", [detached]], "undo": ["remove_child", [detached]]},
		{"target": detached, "undo_properties": [["owner", null]]},
	]
	_check(NAME, _EditorTransaction._first_out_of_tree_undo_target(bad) == detached,
		"未入树节点登记 undo 属性应被守卫识别。")
	var shaped: Array = [
		{"target": container, "do": ["add_child", [detached]], "undo": ["remove_child", [detached]]},
		{"target": detached, "do_properties": [["owner", root]]},
	]
	_check(NAME, _EditorTransaction._first_out_of_tree_undo_target(shaped) == null,
		"修复后的放置形状（do-only owner）不应触发守卫。")
	get_root().remove_child(root)
	detached.free()
	root.free()


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("editor_transaction_test: %d checks, %d failures" % [_checks, _failures.size()])
