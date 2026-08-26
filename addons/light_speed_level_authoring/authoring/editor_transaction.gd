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
# [br]anchor：可选历史锚点（关卡根）。仅真实 EditorUndoRedoManager 分支生效，作 create_action 的
# [br]  custom_object 把动作钉进锚点所在场景历史，避免按“当前场景”归属产生歧义；UndoRedo 的
# [br]  create_action 第 3 参是 bool（无 custom_object），故游戏模式下忽略 anchor。
# [br]真实编辑器守卫（AF-09 P0）：EURM 分支拒绝在 Node 入树前登记其 undo 段——引擎对无共同祖先的
# [br]  节点做路径解析会触发 node.cpp common_parent is null；do 段不受限（与引擎实例化事务同形）。
# [br]返回 true 表示已提交（或 do 段已直发执行）；结构非法整体拒绝并 push_error，不产生半登记事务。
static func commit(undo: Object, action_name: String, operations: Array, anchor: Object = null) -> bool:
	if operations.is_empty():
		push_error("EditorTransaction：空操作列表，拒绝提交事务 %s。" % [action_name])
		return false
	if undo == null:
		for operation: Variant in operations:
			if not _apply_direct(operation):
				return false
		return true
	var is_editor_manager: bool = undo.get_class() == "EditorUndoRedoManager"
	if is_editor_manager:
		var offender: Node = _first_out_of_tree_undo_target(operations)
		if offender != null:
			push_error("EditorTransaction：节点 %s 尚未入树，禁止为其登记 undo 段（真实编辑器 common_parent 风险），拒绝提交事务 %s。" % [offender.name, action_name])
			return false
	if is_editor_manager and anchor != null:
		undo.create_action(action_name, 0, anchor)
	else:
		undo.create_action(action_name)
	for operation: Variant in operations:
		if not _register(undo, operation, is_editor_manager):
			return false
	undo.commit_action()
	return true


# EURM 守卫辅助：返回首个“登记了 undo 段却未入树”的 Node target；无则 null。
# [br]do-only 操作（如 owner 只登记 do 侧）不在此列——引擎 SceneTreeDock 实例化事务即此形状。
static func _first_out_of_tree_undo_target(operations: Array) -> Node:
	for operation: Variant in operations:
		var target: Object = operation.get("target", null)
		if not (target is Node):
			continue
		var undo_entries: Array = operation.get("undo", []) as Array
		var undo_properties: Array = operation.get("undo_properties", []) as Array
		if (not undo_entries.is_empty() or not undo_properties.is_empty()) \
				and not (target as Node).is_inside_tree():
			return target
	return null


# 登记单条 do/undo 方法对（分发两套 API）；结构非法返回 false。
static func _register(undo: Object, operation: Dictionary, is_editor_manager: bool) -> bool:
	var target: Object = operation.get("target", null)
	var do_entry: Variant = operation.get("do", [])
	var undo_entry: Variant = operation.get("undo", [])
	if target == null or not (do_entry is Array) or not (undo_entry is Array):
		push_error("EditorTransaction：操作结构非法（须含 target/do/undo），拒绝登记。")
		return false
	if is_editor_manager:
		if not (do_entry as Array).is_empty():
			undo.callv("add_do_method", [target, do_entry[0]] + (do_entry[1] as Array))
		if not (undo_entry as Array).is_empty():
			undo.callv("add_undo_method", [target, undo_entry[0]] + (undo_entry[1] as Array))
	else:
		if not (do_entry as Array).is_empty():
			undo.callv("add_do_method", [Callable(target, do_entry[0]).bindv(do_entry[1] as Array)])
		if not (undo_entry as Array).is_empty():
			undo.callv("add_undo_method", [Callable(target, undo_entry[0]).bindv(undo_entry[1] as Array)])
	for do_property: Variant in operation.get("do_properties", []):
		undo.callv("add_do_property", [target, do_property[0], do_property[1]])
	for undo_property: Variant in operation.get("undo_properties", []):
		undo.callv("add_undo_property", [target, undo_property[0], undo_property[1]])
	return true


# 无撤销直发模式：立即调用 do 方法并落 do_properties（供 headless 服务路径或确认无撤销需要的调用方）。
# do 可为空数组（纯属性操作）；target 缺失或结构非法才拒绝。
static func _apply_direct(operation: Dictionary) -> bool:
	var target: Object = operation.get("target", null)
	var do_entry: Variant = operation.get("do", [])
	if target == null or not (do_entry is Array):
		push_error("EditorTransaction：直发操作结构非法，拒绝执行。")
		return false
	if not (do_entry as Array).is_empty():
		target.callv(do_entry[0], (do_entry[1] as Array))
	for do_property: Variant in operation.get("do_properties", []):
		target.set(do_property[0], do_property[1])
	return true
