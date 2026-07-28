@tool
class_name LightSpeedArtProfileProfileSaveService
extends RefCounted

## 视觉配置文件保存服务（D4.5-C1）。
## 职责：把已有外部 ObjectVisualProfile 写回其 resource_path 指向的 .tres。
## 输入输出：输入 ObjectVisualProfile，返回 {ok: bool, reason: String, path: String}。
## 副作用：save() 成功时通过 ResourceSaver 写入既有 .tres；失败时不抛出，返回错误。
## 边界：只保存已有外部 Profile；不创建副本、不修改 state / default 字段、不扫描场景、不决定共享策略；
##       禁止保存到 res://assets/art/、res://addons/、.godot/ 或绝对 / user:// 路径；
##       仅写入 profile.resource_path，绝不生成新路径。

# 允许保存的唯一根目录；其余路径一律拒绝。
const _VISUAL_PROFILES_ROOT: String = "res://assets/visual_profiles/"
# 显式禁止的前缀（兜底防御；正常路径已被 _VISUAL_PROFILES_ROOT 前缀检查排除）。
const _FORBIDDEN_PREFIXES: Array = [
	"res://assets/art/",
	"res://addons/",
	"res://.godot/",
]

# 可注入的保存后端，签名为 (profile, path) -> int（Error 整数）。
# 默认空 Callable 时使用 ResourceSaver；仅供测试注入以避免磁盘写入。
var _save_backend: Callable = Callable()


## 校验保存前置条件。
## profile 可为空；返回 {ok, reason, path}；无副作用，不写盘，不修改 Profile 内容。
func can_save(profile: ObjectVisualProfile) -> Dictionary:
	if profile == null:
		return _deny("未提供视觉配置文件。", "")
	var path: String = profile.resource_path
	if path == "":
		return _deny("当前视觉配置尚未保存为独立资源，暂不支持正式保存。", "")
	if not path.begins_with(_VISUAL_PROFILES_ROOT):
		return _deny("保存路径必须位于 res://assets/visual_profiles/。", path)
	for forbidden in _FORBIDDEN_PREFIXES:
		if path.begins_with(forbidden):
			return _deny("禁止保存到该路径：%s" % path, path)
	# 绝对路径、user:// 等非 res:// 路径已被 _VISUAL_PROFILES_ROOT 前缀检查排除。
	var problems: PackedStringArray = profile.validate_profile()
	if not problems.is_empty():
		return _deny("配置校验失败：%s" % problems[0], path)
	return {ok = true, reason = "", path = path}


## 保存已有外部 Profile 到其 resource_path。
## profile 为待保存资源；返回 {ok, reason, path}。
## 失败时不抛出；不修改 Profile 内容（state / default 字段不变）；不创建新路径，仅写入 profile.resource_path。
func save(profile: ObjectVisualProfile) -> Dictionary:
	var check: Dictionary = can_save(profile)
	if not check.ok:
		return check
	var path: String = profile.resource_path
	var err: int = _invoke_save(profile, path)
	if err != OK:
		return {ok = false, reason = "保存失败，错误码：%d" % err, path = path}
	return {ok = true, reason = "已保存。", path = path}


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


## 构造拒绝结果。reason 为中文原因；path 透传供调用方定位。无副作用。
func _deny(reason: String, path: String) -> Dictionary:
	return {ok = false, reason = reason, path = path}
