@tool
class_name LightSpeedArtProfileVisualStateEditService
extends RefCounted

## 视觉状态纹理替换编辑服务（D4.5-C1）。
## 职责：定位 Profile 中的 VisualStateTexture、校验新纹理、通过 UndoRedo 构建 do/undo 替换动作。
## 输入输出：输入 ObjectVisualView / state_id / Texture2D，返回 {ok: bool, reason: String, skipped: bool}。
## 副作用：仅在 replace_with_undo_redo 中通过传入的 undo_redo 记录并提交一次替换动作；
##         该动作的 do/undo 会改写 state.world_texture、触发 profile.emit_changed() 与 view.refresh_visual()。
## 边界：不访问 EditorSelection、不扫描素材、不保存资源、不创建 Profile 副本；
##       不修改 state_id / default_state_id、不替换整个 Profile 对象、不切换 View 当前状态。

# 正式美术源目录前缀；素材 resource_path 必须位于其下才允许替换。
const _ART_ROOT_PREFIX: String = "res://assets/art/"


## 定位 Profile 中指定 state_id 对应的 VisualStateTexture。
## profile 可为空；state_id 为空或未找到时返回 null；忽略 states 中的 null 元素；无副作用。
func find_state(profile: ObjectVisualProfile, state_id: StringName) -> VisualStateTexture:
	if profile == null or state_id == &"":
		return null
	for state: VisualStateTexture in profile.states:
		if state == null:
			continue
		if state.state_id == state_id:
			return state
	return null


## 校验是否可替换当前状态的纹理。
## view / state_id / texture / resource_path 为替换所需输入；返回 {ok, reason, skipped}。
## 无副作用；不修改 view、profile 或 texture；不扫描素材，resource_path 由调用方提供。
func can_replace(view: ObjectVisualView, state_id: StringName, texture: Texture2D, resource_path: String) -> Dictionary:
	if view == null or not is_instance_valid(view):
		return _deny("未选择视觉目标。")
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		return _deny("该视觉节点未配置视觉配置文件。")
	var state: VisualStateTexture = find_state(profile, state_id)
	if state == null:
		return _deny("目标状态不存在。")
	if texture == null or not is_instance_valid(texture):
		return _deny("所选素材纹理不可用。")
	if resource_path == "" or not resource_path.begins_with(_ART_ROOT_PREFIX):
		return _deny("素材必须位于 res://assets/art/。")
	return {ok = true, reason = "", skipped = false}


## 通过 UndoRedo 执行一次纹理替换并立即刷新视图。
## undo_redo 可为 EditorUndoRedoManager 或 UndoRedo（鸭子类型，需提供 create_action / add_do_* / commit_action）。
## 提交后 do 立即执行：state.world_texture = new_texture → profile.emit_changed() → view.refresh_visual()。
## 返回 {ok, reason, skipped}；新旧纹理完全相同时不创建动作并返回 skipped=true。
## 不修改 state_id / default_state_id、不替换整个 Profile 对象、不切换 View 当前内容状态。
func replace_with_undo_redo(undo_redo, view: ObjectVisualView, state_id: StringName, new_texture: Texture2D, action_name: String) -> Dictionary:
	if undo_redo == null:
		return _deny("未提供 UndoRedo。")
	if view == null or not is_instance_valid(view):
		return _deny("未选择视觉目标。")
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		return _deny("该视觉节点未配置视觉配置文件。")
	var state: VisualStateTexture = find_state(profile, state_id)
	if state == null:
		return _deny("目标状态不存在。")
	if new_texture == null or not is_instance_valid(new_texture):
		return _deny("所选素材纹理不可用。")
	var old_texture: Texture2D = state.world_texture
	# 新旧纹理完全相同：不创建动作，避免无效 Undo 记录。
	# old 与 new 同时为空的情形已被上方 new_texture == null 拦截，此处不会产生两端皆空的无效动作。
	if old_texture == new_texture:
		return {ok = true, reason = "纹理未变化，已跳过替换。", skipped = true}
	undo_redo.create_action(action_name)
	# Do / Undo 三步：改写 world_texture 属性 → 通知资源变化 → 立即刷新视图。
	# add_do_method/add_undo_method 的参数形式随撤销管理器类型不同：UndoRedo 收单 Callable，
	# EditorUndoRedoManager 仍为 (object, method) 旧式两参（单 Callable 会触发 Invalid call）；
	# 由 _add_do_method/_add_undo_method 按 get_class() 统一分发，兼容两种管理器。
	undo_redo.add_do_property(state, "world_texture", new_texture)
	undo_redo.add_undo_property(state, "world_texture", old_texture)
	_add_do_method(undo_redo, profile, &"emit_changed")
	_add_undo_method(undo_redo, profile, &"emit_changed")
	_add_do_method(undo_redo, view, &"refresh_visual")
	_add_undo_method(undo_redo, view, &"refresh_visual")
	undo_redo.commit_action()
	return {ok = true, reason = "已替换。", skipped = false}


## 统一 UndoRedo 与 EditorUndoRedoManager 的 add_do_method 调用形式。
## EditorUndoRedoManager.add_do_method 仍为 (object, method) 旧式两参，传单 Callable 会触发 Invalid call；
## UndoRedo.add_do_method 收单 Callable。据此按 get_class() 分发。无返回值；不持有 object 引用。
func _add_do_method(undo_redo, object: Object, method: StringName) -> void:
	if undo_redo.get_class() == "EditorUndoRedoManager":
		undo_redo.add_do_method(object, method)
	else:
		undo_redo.add_do_method(Callable(object, method))


## 统一 UndoRedo 与 EditorUndoRedoManager 的 add_undo_method 调用形式。语义同 _add_do_method。
func _add_undo_method(undo_redo, object: Object, method: StringName) -> void:
	if undo_redo.get_class() == "EditorUndoRedoManager":
		undo_redo.add_undo_method(object, method)
	else:
		undo_redo.add_undo_method(Callable(object, method))


## 构造拒绝结果。reason 为中文原因；无副作用。
func _deny(reason: String) -> Dictionary:
	return {ok = false, reason = reason, skipped = false}
