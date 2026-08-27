@tool
class_name LightSpeedVisualWorkbenchUsageImpactService
extends RefCounted

## Workbench Usage Impact 服务（S3-03；GUI 冻结总结 v1.0 §56）。
## 职责：修改已被引用的全局视觉资源前，只读扫描关卡场景文本，给出影响报告：
##       受影响关卡数、实际使用当前槽位的关卡、Validator 问题；不要求逐关卡确认。
## 输入输出：输入 Profile 正式路径、旧纹理路径列表与 Profile 对象，返回报告字典
##           {affected_level_count, levels_using, variant_override_count, fallback_count,
##            validator_issues, degraded_notes}。
## 副作用：只读（DirAccess 枚举 + FileAccess 读文本）；不修改任何文件。
## 边界：Variant Override 与 fallback 属主题系统语义，首批降级为 0 并在 degraded_notes
##       声明；Validator 问题来自 ObjectVisualProfile.validate_profile()（既有正式校验，
##       不重复造第二套）；扫描按资源路径字符串匹配 .tscn 文本（ext_resource 引用形态），
##       不解析节点树、不猜 Node.name / NodePath / 场景坐标。

const DEFAULT_LEVELS_ROOT: String = "res://levels/"
const _SCENE_EXTENSION: String = "tscn"


## 构建影响报告。profile_path 为目标 Profile 正式路径；old_texture_paths 为本批次
## 将被替换的旧纹理路径列表（Change Set.get_old_texture_paths()）；profile 传 null 时
## validator_issues 记“无法校验”而不崩溃；levels_root 可注入测试根目录（user:// 等）。
func build_report(
		profile_path: String,
		old_texture_paths: Array,
		profile: ObjectVisualProfile,
		levels_root: String = DEFAULT_LEVELS_ROOT
) -> Dictionary:
	var needles: Array = []
	if profile_path != "":
		needles.append(profile_path)
	for path: String in old_texture_paths:
		if path != "" and not (path in needles):
			needles.append(path)
	var levels_using: Array = []
	if not needles.is_empty():
		for scene_path: String in _collect_scene_files(levels_root):
			if _scene_references_any(scene_path, needles):
				levels_using.append(scene_path)
	var validator_issues: PackedStringArray = PackedStringArray()
	if profile == null:
		validator_issues.append("Profile 未加载，无法运行正式校验。")
	else:
		validator_issues = profile.validate_profile()
	return {
		affected_level_count = levels_using.size(),
		levels_using = levels_using,
		variant_override_count = 0,
		fallback_count = 0,
		validator_issues = validator_issues,
		degraded_notes = PackedStringArray([
			"variant_override / fallback 属主题系统语义，首批未开通（降级为 0）。",
		]),
	}


## 递归收集根目录下全部 .tscn 场景路径。
## current_is_dir 必须紧跟 get_next 使用（两段式收集会读到失效状态）。
func _collect_scene_files(root_dir: String) -> Array:
	var found: Array = []
	var dir: DirAccess = DirAccess.open(root_dir)
	if dir == null:
		return found
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not name.begins_with("."):
			if dir.current_is_dir():
				found.append_array(_collect_scene_files(root_dir.path_join(name)))
			elif name.get_extension() == _SCENE_EXTENSION:
				found.append(root_dir.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	return found


## 只读读取场景文本，判断是否引用任一目标资源路径。
func _scene_references_any(scene_path: String, needles: Array) -> bool:
	var text: String = FileAccess.get_file_as_string(scene_path)
	if text == "":
		return false
	for needle: String in needles:
		if text.contains(needle):
			return true
	return false
