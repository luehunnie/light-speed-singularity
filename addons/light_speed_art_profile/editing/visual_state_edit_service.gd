@tool
class_name LightSpeedArtProfileVisualStateEditService
extends RefCounted

## 视觉状态纹理替换编辑服务（D4.5-C1；AF-Artwork 扩展库存图标事务与同 Profile 多实例刷新）。
## 职责：定位 Profile 中的 VisualStateTexture、校验新纹理、通过 UndoRedo 构建 do/undo 替换动作；
##       同一入口也支持 Profile 级 inventory_icon 的替换与清除。
## 输入输出：输入 ObjectVisualView / state_id / Texture2D，返回 {ok: bool, reason: String, skipped: bool}。
## 副作用：仅在 replace_with_undo_redo / replace_inventory_icon_with_undo_redo 中通过传入的 undo_redo
##         记录并提交一次替换动作；该动作的 do/undo 会改写 world_texture 或 inventory_icon、
##         触发 profile.emit_changed()，并刷新 scene_root 下引用同一 Profile 的全部 View。
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
## 提交后 do 立即执行：state.world_texture = new_texture → profile.emit_changed() → 同 Profile 全部 View refresh_visual()。
## scene_root 为当前编辑场景根（可空）：提供时刷新其下引用同一 Profile 的全部 ObjectVisualView（同 Profile
## 其它实例同步换图，AF-Artwork P0-4）；为空时仅刷新传入 view（保持 D4.5-C1 旧行为）。
## 返回 {ok, reason, skipped}；新旧纹理完全相同时不创建动作并返回 skipped=true。
## 不修改 state_id / default_state_id、不替换整个 Profile 对象、不切换 View 当前内容状态。
func replace_with_undo_redo(
		undo_redo,
		view: ObjectVisualView,
		state_id: StringName,
		new_texture: Texture2D,
		action_name: String,
		scene_root: Node = null
) -> Dictionary:
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
	# Do / Undo：改写 world_texture 属性 → 通知资源变化 → 刷新同 Profile 全部实例视图。
	undo_redo.add_do_property(state, "world_texture", new_texture)
	undo_redo.add_undo_property(state, "world_texture", old_texture)
	_commit_profile_views_refresh(undo_redo, profile, view, scene_root)
	return {ok = true, reason = "已替换。", skipped = false}


## 校验是否可设置库存图标（inventory_icon）。
## view 为编辑目标；new_texture 为新图标，null 表示显式清除（清除是合法操作）；
## 返回 {ok, reason, skipped}；无副作用。与 can_replace 共用 art 根目录约束。
func can_set_inventory_icon(view: ObjectVisualView, new_texture: Texture2D) -> Dictionary:
	if view == null or not is_instance_valid(view):
		return _deny("未选择视觉目标。")
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		return _deny("该视觉节点未配置视觉配置文件。")
	if new_texture == null:
		return {ok = true, reason = "", skipped = false}
	if not is_instance_valid(new_texture):
		return _deny("所选素材纹理不可用。")
	var resource_path: String = new_texture.resource_path
	if resource_path == "" or not resource_path.begins_with(_ART_ROOT_PREFIX):
		return _deny("素材必须位于 res://assets/art/。")
	return {ok = true, reason = "", skipped = false}


## 通过 UndoRedo 替换或清除 Profile 级库存图标（inventory_icon）。
## new_texture 为 null 表示显式清除（清除也是一次可撤销事务）；其余语义与
## replace_with_undo_redo 一致：emit_changed + 同 Profile 全部 View 刷新（inventory_icon
## 不参与世界纹理选取，刷新为无害重算，保持“改任一纹理后同 Profile 实例统一刷新”的单一语义）。
## 返回 {ok, reason, skipped}；新旧图标完全相同时跳过。
func replace_inventory_icon_with_undo_redo(
		undo_redo,
		view: ObjectVisualView,
		new_texture: Texture2D,
		action_name: String,
		scene_root: Node = null
) -> Dictionary:
	if undo_redo == null:
		return _deny("未提供 UndoRedo。")
	if view == null or not is_instance_valid(view):
		return _deny("未选择视觉目标。")
	var profile: ObjectVisualProfile = view.visual_profile
	if profile == null:
		return _deny("该视觉节点未配置视觉配置文件。")
	var old_texture: Texture2D = profile.inventory_icon
	# 新旧图标完全相同：不创建动作（与 world_texture 替换同一跳过语义，先于路径域校验）。
	if old_texture == new_texture:
		return {ok = true, reason = "库存图标未变化，已跳过。", skipped = true}
	var check: Dictionary = can_set_inventory_icon(view, new_texture)
	if not check.ok:
		return check
	undo_redo.create_action(action_name)
	undo_redo.add_do_property(profile, "inventory_icon", new_texture)
	undo_redo.add_undo_property(profile, "inventory_icon", old_texture)
	_commit_profile_views_refresh(undo_redo, profile, view, scene_root)
	return {ok = true, reason = "已更新库存图标。", skipped = false}


## 提交一次动作：emit_changed + 同 Profile 全部 View 的 do/undo refresh，随后 commit。
## profile 为被改资源；fallback_view 为 scene_root 缺失或未匹配到任何实例时的最小刷新目标。
func _commit_profile_views_refresh(
		undo_redo,
		profile: ObjectVisualProfile,
		fallback_view: ObjectVisualView,
		scene_root: Node
) -> void:
	_add_do_method(undo_redo, profile, &"emit_changed")
	_add_undo_method(undo_redo, profile, &"emit_changed")
	var views: Array = []
	if scene_root != null and is_instance_valid(scene_root):
		_collect_views_sharing_profile(scene_root, profile, views)
	if views.is_empty():
		views = [fallback_view]
	for share_view in views:
		_add_do_method(undo_redo, share_view, &"refresh_visual")
		_add_undo_method(undo_redo, share_view, &"refresh_visual")
	undo_redo.commit_action()


## 深度优先收集 root 下引用同一 Profile 的全部 ObjectVisualView（含实例化子场景内的实例）。
## 收集发生在动作创建时点，undo/redo 期间不重扫（ponytail：动作期间的增删实例不进本次刷新集，
## 依赖该时点的编辑场景快照；下次事务自然覆盖）。
func _collect_views_sharing_profile(node: Node, profile: ObjectVisualProfile, views: Array) -> void:
	if node is ObjectVisualView and node.visual_profile == profile:
		views.append(node)
	for child: Node in node.get_children():
		_collect_views_sharing_profile(child, profile, views)


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
