@tool
extends RefCounted

# AF-08 编辑事务辅助（Guide §Undo/Redo 与 atomic editor transaction）。
# 统一 UndoRedo（headless 测试 / 游戏模式）与 EditorUndoRedoManager（真实编辑器）两套 API 差异：
#   UndoRedo.add_do_method 收单 Callable；EditorUndoRedoManager 仍为 (object, method, ...) 旧式变参——
#   两者不兼容，本类按 get_class() 分发（项目已冻结该坑的既定结论）。
# 事务原子性：一次 commit = 一个 create_action 域；全部 do/undo 方法登记完毕才 commit，无中间态。
# 注意：Callable 不保留 RefCounted 引用，事务 target 必须是 Node（场景节点）或 Object。


# 提交一个原子编辑事务。
# [br]undo：UndoRedo 或 EditorUndoRedoManager 实例（按 get_class 分发）；传 null 直接顺序执行 do 段（无撤销）。
# [br]action_name：撤销历史显示名。
# [br]operations：Array of Dictionary：
# [br]  {target: Object, do: [method, args], undo: [method, args]}；
# [br]  可选 do_properties / undo_properties: Array of [property, value]（两套 API 此项签名一致）。
# [br]返回 true 表示已提交（或 do 段已直发执行）；结构非法整体拒绝并 push_error，不产生半登记事务。
static func commit(undo: Object, action_name: String, operations: Array) -> bool:
	if operations.is_empty():
		push_error("EditorTransaction：空操作列表，拒绝提交事务 %s。" % [action_name])
		return false
	if undo == null:
		for operation: Variant in operations:
			if not _apply_direct(operation):
				return false
		return true
	undo.create_action(action_name)
	for operation: Variant in operations:
		if not _register(undo, operation, undo.get_class() == "EditorUndoRedoManager"):
			return false
	undo.commit_action()
	return true


# 登记单条 do/undo 方法对（分发两套 API）；结构非法返回 false。
static func _register(undo: Object, operation: Dictionary, is_editor_manager: bool) -> bool:
	var target: Object = operation.get("target", null)
	var do_entry: Variant = operation.get("do", [])
	var undo_entry: Variant = operation.get("undo", [])
	if target == null or not (do_entry is Array) or not (undo_entry is Array):
		push_error("EditorTransaction：操作结构非法（须含 target/do/undo），拒绝登记。")
		return false
	if is_editor_manager:
		undo.callv("add_do_method", [target, do_entry[0]] + (do_entry[1] as Array))
		undo.callv("add_undo_method", [target, undo_entry[0]] + (undo_entry[1] as Array))
	else:
		undo.callv("add_do_method", [Callable(target, do_entry[0]).bindv(do_entry[1] as Array)])
		undo.callv("add_undo_method", [Callable(target, undo_entry[0]).bindv(undo_entry[1] as Array)])
	for do_property: Variant in operation.get("do_properties", []):
		undo.callv("add_do_property", [target, do_property[0], do_property[1]])
	for undo_property: Variant in operation.get("undo_properties", []):
		undo.callv("add_undo_property", [target, undo_property[0], undo_property[1]])
	return true


# 无撤销直发模式：立即调用 do 方法（供 headless 服务路径或确认无撤销需要的调用方）。
static func _apply_direct(operation: Dictionary) -> bool:
	var target: Object = operation.get("target", null)
	var do_entry: Variant = operation.get("do", [])
	if target == null or not (do_entry is Array) or (do_entry as Array).is_empty():
		push_error("EditorTransaction：直发操作结构非法，拒绝执行。")
		return false
	target.callv(do_entry[0], (do_entry[1] as Array))
	return true
