@tool
extends RefCounted

## 视觉配置创建并绑定服务（AF-Artwork：缺 visual_profile 时的最小无代码创建流程）。
## 职责：为缺 visual_profile 的 ObjectVisualView 在确定性安全路径创建最小合法 ObjectVisualProfile，
##       写入 .tres 后经 UndoRedo 把 profile 绑定到该 View（属性写在当前编辑场景内，可撤销）。
## 路径规则：res://assets/visual_profiles/<编辑场景文件名去扩展名>_visuals.tres
##       （与既有 single_cell_mirror_visuals.tres / emitter_visuals.tres 命名一致）。
## 输入输出：输入 View / 编辑场景根 / 默认状态纹理，返回 {ok, reason, path, profile}。
## 副作用：成功时 ResourceSaver 写入新 .tres 并通过传入 undo_redo 提交一次绑定动作；
##         do/undo 只改写 View.visual_profile 属性并 refresh_visual，不改已存在资源。
## 边界：目标文件已存在时拒绝覆盖（不读不改）；View 的 owner 不是编辑场景根（实例化子场景 /
##       继承场景内部、外部资源）时给出可操作错误而非假成功；场景未保存时无法确定路径，拒绝；
##       不迁移既有场景、不为任何具体机制写死特判；保存后端可注入用于测试避免磁盘写入。
## 已知上限（ponytail）：Undo 只解绑不删除已写入的 .tres（文件删除不可安全撤销）；
##       撤销后再次创建会命中“已存在拒绝覆盖”，错误信息给出路径供作者自行处理。

const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)

# 唯一允许的创建根目录；与 ProfileSaveService._VISUAL_PROFILES_ROOT 一致。
const _PROFILES_ROOT: String = "res://assets/visual_profiles/"
# 路径后缀；与既有 <场景名>_visuals.tres 命名约定一致。
const _PATH_SUFFIX: String = "_visuals.tres"
# 新 Profile 的唯一初始状态 ID；作者后续可在 Inspector 增补状态。
const _DEFAULT_STATE_ID: StringName = &"default"

# 可注入的保存后端，签名为 (profile, path) -> int（Error 整数）。
# 默认空 Callable 时使用 ResourceSaver；仅供测试注入以避免磁盘写入。
var _save_backend: Callable = Callable()


## 由编辑场景根推导新 Profile 的确定性保存路径。
## scene_root 为当前编辑场景根；返回 {ok, reason, path}；无副作用，不写盘。
func derive_profile_path(scene_root: Node) -> Dictionary:
	if scene_root == null or not is_instance_valid(scene_root):
		return _deny("未提供当前编辑场景根。", "")
	var scene_path: String = scene_root.scene_file_path
	if scene_path == "":
		return _deny("当前场景尚未保存为文件，无法确定视觉配置保存路径；请先保存场景。", "")
	var stem: String = scene_path.get_file().get_basename()
	return {ok = true, reason = "", path = _PROFILES_ROOT + stem + _PATH_SUFFIX}


## 校验创建并绑定前置条件（不含默认纹理检查）。
## view 为编辑目标；scene_root 为编辑场景根；返回 {ok, reason, path}；无副作用。
func can_create_and_bind(view: ObjectVisualView, scene_root: Node) -> Dictionary:
	if view == null or not is_instance_valid(view):
		return _deny("未选择视觉目标。", "")
	if view.visual_profile != null:
		return _deny("该视觉节点已配置视觉配置文件，无需创建。", "")
	var path_check: Dictionary = derive_profile_path(scene_root)
	if not path_check.ok:
		return path_check
	# owner 边界：只有属于当前编辑场景的节点才能安全写属性；
	# owner 指向其它场景（实例化子场景 / 继承场景内部）时写入会越过作者的编辑意图。
	if view.owner == null or view.owner != scene_root:
		return _deny(
			"该视觉节点不属于当前编辑场景（可能位于实例化子场景内）；请打开它所属的场景后重试。",
			path_check.path
		)
	var path: String = path_check.path
	if FileAccess.file_exists(path):
		return _deny(
			"已存在 %s，拒绝覆盖；如需重建请先在文件系统中处理该文件。" % path,
			path
		)
	return {ok = true, reason = "", path = path}


## 创建最小合法 Profile（default 状态 + 默认纹理）并经 UndoRedo 绑定到 View。
## undo_redo 为 EditorUndoRedoManager 或 UndoRedo；default_texture 用作 default 状态的
## world_texture（通常取美术浏览器当前选中素材）；action_name 为撤销动作名。
## 返回 {ok, reason, path, profile}；失败时 View 与磁盘均无变化（保存失败在动作创建前返回）。
func create_and_bind(
		undo_redo,
		view: ObjectVisualView,
		scene_root: Node,
		default_texture: Texture2D,
		action_name: String
) -> Dictionary:
	if undo_redo == null:
		return _deny("未提供 UndoRedo。", "")
	var check: Dictionary = can_create_and_bind(view, scene_root)
	if not check.ok:
		return check
	if default_texture == null or not is_instance_valid(default_texture):
		return _deny("请先从美术浏览器选择一张图片作为默认状态纹理。", check.path)
	var path: String = check.path
	var profile: ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = _DEFAULT_STATE_ID
	var default_state: VisualStateTexture = _VisualStateTexture.new()
	default_state.state_id = _DEFAULT_STATE_ID
	default_state.world_texture = default_texture
	profile.states = [default_state]
	# 先写盘再绑定：保存失败时 View 无变化；take_over_path 显式接管确定性路径
	# （避免重复创建会话内同路径资源时的 set_path 冲突报错）。
	profile.take_over_path(path)
	var err: int = _invoke_save(profile, path)
	if err != OK:
		return _deny("视觉配置写入失败，错误码：%d" % err, path)
	undo_redo.create_action(action_name)
	undo_redo.add_do_property(view, "visual_profile", profile)
	undo_redo.add_undo_property(view, "visual_profile", null)
	# EditorUndoRedoManager / UndoRedo 双兼容分发与纹理替换服务共用同一约定，本地最小实现。
	if undo_redo.get_class() == "EditorUndoRedoManager":
		undo_redo.add_do_method(view, "refresh_visual")
		undo_redo.add_undo_method(view, "refresh_visual")
	else:
		undo_redo.add_do_method(Callable(view, "refresh_visual"))
		undo_redo.add_undo_method(Callable(view, "refresh_visual"))
	undo_redo.commit_action()
	return {ok = true, reason = "已创建并绑定。", path = path, profile = profile}


## 注入保存后端用于测试；签名为 (profile, path) -> int。无返回值。
func set_save_backend(backend: Callable) -> void:
	_save_backend = backend


## 清除已注入的保存后端，恢复默认 ResourceSaver。无返回值。
func clear_save_backend() -> void:
	_save_backend = Callable()


## 调用保存后端；默认走 ResourceSaver.save。返回 Error 整数。
func _invoke_save(profile: ObjectVisualProfile, path: String) -> int:
	if _save_backend.is_valid():
		var result = _save_backend.call(profile, path)
		if result is int:
			return result
		return OK
	return ResourceSaver.save(profile, path)


## 构造拒绝结果。reason 为中文可操作原因；path 透传供调用方定位。无副作用。
func _deny(reason: String, path: String) -> Dictionary:
	return {ok = false, reason = reason, path = path}
