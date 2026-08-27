@tool
class_name LightSpeedVisualWorkbenchChangeSet
extends RefCounted

## Workbench 单对象 Change Set（S3-03；GUI 冻结总结 v1.0 §55/§56/§57）。
## 职责：围绕单一 ObjectVisualProfile 暂存状态纹理/库存图标替换（Before/After 内存快照），
##       提供 Preflight 通过后经单一 UndoRedo 动作的 Apply All。
## 输入输出：stage_* 返回 {ok, reason}；apply_all 返回 {ok, reason, applied, skipped}；
##           get_entries 返回 detached 条目数组（含 old/new 路径，供 UI 与 Impact 使用）。
## 副作用：仅内存暂存；apply_all 委托 backend 编辑服务在
##           一次 UndoRedo 动作内改写正式资源字段（world_texture / inventory_icon）。
## 边界：构造即绑定单一 Profile——§55 单逻辑视觉对象范围由结构保证，无法跨对象混批；
##       Before/After 只是当前编辑事务内存快照，不生成 _old/_new 文件（§56）；
##       不修改 state_id / default_state_id；drag_texture 不参与首批；Apply 成功后批次清空。

var _profile: ObjectVisualProfile
var _profile_path: String
# state_id -> {old_texture: Texture2D, new_texture: Texture2D}；重复暂存同状态时保留最早 old。
var _state_changes: Dictionary = {}
# 存在即有图标变更：{old_texture: Texture2D 或 null, new_texture: Texture2D 或 null}。
var _icon_change: Dictionary = {}


## 构造：绑定本批次唯一的逻辑视觉对象（Profile 及其正式路径）。
func _init(profile: ObjectVisualProfile, profile_path: String) -> void:
	_profile = profile
	_profile_path = profile_path


## 本批次目标 Profile（只读引用，不复制）。
func get_profile() -> ObjectVisualProfile:
	return _profile


## 本批次目标 Profile 正式路径（供 Usage Impact 扫描与 UI 展示）。
func get_profile_path() -> String:
	return _profile_path


## 暂存一次状态纹理替换。state 必须存在于 Profile；new_texture 非空；
## 同状态重复暂存覆盖 new、保留首次记录的 old。返回 {ok, reason}。
func stage_state_texture(state_id: StringName, new_texture: Texture2D) -> Dictionary:
	if _profile == null:
		return { ok = false, reason = "Change Set 未绑定 Profile。" }
	if not _profile.has_state(state_id):
		return { ok = false, reason = "目标状态不存在：%s。" % state_id }
	if new_texture == null or not is_instance_valid(new_texture):
		return { ok = false, reason = "新纹理不可用（状态 %s）。" % state_id }
	var old_texture: Texture2D = _current_world_texture(state_id)
	if _state_changes.has(state_id):
		_state_changes[state_id]["new_texture"] = new_texture
	else:
		_state_changes[state_id] = { old_texture = old_texture, new_texture = new_texture }
	return { ok = true, reason = "已暂存状态 %s 的纹理替换。" % state_id }


## 暂存库存图标变更（new_texture 为 null 表示显式清除，合法操作）。
## 重复暂存覆盖 new、保留首次记录的 old。返回 {ok, reason}。
func stage_inventory_icon(new_texture) -> Dictionary:
	if _profile == null:
		return { ok = false, reason = "Change Set 未绑定 Profile。" }
	if new_texture != null and not is_instance_valid(new_texture):
		return { ok = false, reason = "新库存图标不可用。" }
	var old_icon: Texture2D = _profile.inventory_icon
	if _icon_change.is_empty():
		_icon_change = { old_texture = old_icon, new_texture = new_texture }
	else:
		_icon_change["new_texture"] = new_texture
	return { ok = true, reason = "已暂存库存图标变更。" }


## 当前 Profile 中指定状态的 world_texture（未找到返回 null；忽略 null 元素）。
func _current_world_texture(state_id: StringName) -> Texture2D:
	if _profile == null:
		return null
	for state: VisualStateTexture in _profile.states:
		if state != null and state.state_id == state_id:
			return state.world_texture
	return null


## 取已暂存状态的最新新纹理（Preflight 后置模拟与 UI 使用）；未暂存返回 null。
func get_staged_new_texture(state_id: StringName) -> Texture2D:
	if not _state_changes.has(state_id):
		return null
	return _state_changes[state_id]["new_texture"]


## 是否暂存了指定状态的纹理替换。
func has_staged_state(state_id: StringName) -> bool:
	return _state_changes.has(state_id)


## 是否暂存了库存图标变更。
func has_staged_icon() -> bool:
	return not _icon_change.is_empty()


## 取已暂存的库存图标新纹理（可为 null = 清除；未暂存且调用方需要区分时先查 has_staged_icon）。
func get_staged_icon_texture() -> Texture2D:
	if _icon_change.is_empty():
		return null
	return _icon_change["new_texture"]


## detached 条目列表：[{kind: "state"|"icon", state_id, old_path, new_path}]。
## 路径取自资源 resource_path（内存构造资源为空串）；不返回纹理对象本身。
func get_entries() -> Array:
	var entries: Array = []
	for state_id: StringName in _state_changes:
		var change: Dictionary = _state_changes[state_id]
		entries.append({
			kind = "state",
			state_id = state_id,
			old_path = _texture_path(change["old_texture"]),
			new_path = _texture_path(change["new_texture"]),
		})
	if not _icon_change.is_empty():
		entries.append({
			kind = "icon",
			state_id = &"",
			old_path = _texture_path(_icon_change["old_texture"]),
			new_path = _texture_path(_icon_change["new_texture"]),
		})
	return entries


## 本批次全部旧纹理正式路径（供 Usage Impact 扫描“实际使用当前槽位的关卡”）。
func get_old_texture_paths() -> Array:
	var paths: Array = []
	for state_id: StringName in _state_changes:
		var path: String = _texture_path(_state_changes[state_id]["old_texture"])
		if path != "":
			paths.append(path)
	if not _icon_change.is_empty():
		var icon_path: String = _texture_path(_icon_change["old_texture"])
		if icon_path != "":
			paths.append(icon_path)
	return paths


## 批次是否为空。
func is_empty() -> bool:
	return _state_changes.is_empty() and _icon_change.is_empty()


## 清空批次（不触碰 Profile 本身）。
func clear() -> void:
	_state_changes = {}
	_icon_change = {}


## Apply All（§55）：Preflight 通过（result.passed == true）后，把全部暂存变更经
## edit_service 在单一 UndoRedo 动作内提交（一次 Undo 步恢复整批）。成功后批次清空。
## 返回 edit_service 结果原样（{ok, reason, applied, skipped}）；拒绝时 applied=0。
func apply_all(undo_redo, edit_service, preflight_result: Dictionary, action_name: String) -> Dictionary:
	if is_empty():
		return { ok = false, reason = "Change Set 为空，无变更可应用。", applied = 0, skipped = 0 }
	if not bool(preflight_result.get("passed", false)):
		return { ok = false, reason = "Preflight 未通过，已阻止 Apply All（§57）。", applied = 0, skipped = 0 }
	var state_changes: Array = []
	for state_id: StringName in _state_changes:
		state_changes.append({ state_id = state_id, new_texture = _state_changes[state_id]["new_texture"] })
	var icon_arg: Dictionary = {}
	if not _icon_change.is_empty():
		icon_arg = { new_texture = _icon_change["new_texture"] }
	var result: Dictionary = edit_service.apply_profile_changes_with_undo_redo(
		undo_redo, _profile, state_changes, icon_arg, action_name)
	if bool(result.get("ok", false)):
		clear()
	return result


## 纹理资源路径的空安全读取（null / 未落盘返回 ""）。
func _texture_path(texture: Texture2D) -> String:
	if texture == null:
		return ""
	return texture.resource_path
