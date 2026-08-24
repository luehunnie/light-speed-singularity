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
	_test_01_commit_undo_redo()
	_test_02_properties()
	_test_03_null_direct_mode()
	_test_04_invalid_structure_rejected()
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


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("editor_transaction_test: %d checks, %d failures" % [_checks, _failures.size()])
