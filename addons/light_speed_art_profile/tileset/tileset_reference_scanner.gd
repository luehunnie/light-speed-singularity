@tool
extends RefCounted

## TileSet 引用扫描器（TileSet 美术工作流 v1；自 tileset_atlas_replace_service 抽出）。
## 职责：枚举扫描根下全部 .tscn；读取文本并按「资源路径或 uid 文本」匹配引用；收集不可读/无法解析
##       的扫描根与场景错误；产出排序后的影响引用快照与指纹。纯只读，绝不修改任何文件。
## 输入输出：scan(resource_path, uid_text) -> {ok, references, errors, fingerprint}：
##   ok          bool — 仅当 errors 为空才为 true；任何不可读场景都令整体失败，绝不静默跳过。
##   references  PackedStringArray — 引用该资源的场景路径，已排序（即影响引用快照）。
##   errors      Array — [{path, reason}]，打不开的扫描根 / 读不出文本的 .tscn。
##   fingerprint String — 排序后快照逐行拼接的 sha256，供分析/替换两阶段比对（新增/删除必变）。
## 边界：不持有 TileSet（输入为路径与 uid 文本）；不做场景语法解析（v1 文本匹配）；
##       匹配语义与抽出前的服务实现一致（contains 命中即引用）。
## 已知天花板（ponytail: 文本 contains 匹配）：路径字符串出现在注释等非引用位置也计为引用，
##       误报仅放大确认面（更保守），不会漏报；需要精确语义时升级为逐 ext_resource 解析。

# 扫描根；默认整个 res://（跳过 . 开头目录如 .godot、.claude）。测试可注入 user:// fixture 根。
var _scan_roots: PackedStringArray = PackedStringArray(["res://"])


## 注入扫描根（覆盖默认 res://）。无返回值。
func set_scan_roots(roots: PackedStringArray) -> void:
	_scan_roots = roots


## 扫描引用：枚举 + 读取 + 匹配 + 错误收集；返回 {ok, references, errors, fingerprint}。
func scan(resource_path: String, uid_text: String) -> Dictionary:
	var errors: Array = []
	var references: PackedStringArray = PackedStringArray()
	var scenes: PackedStringArray = PackedStringArray()
	for scan_root in _scan_roots:
		_collect_tscn_files(String(scan_root), scenes, errors)
	for scene_path in scenes:
		var read: Dictionary = _read_scene_text(scene_path)
		if not bool(read.ok):
			errors.append({path = scene_path, reason = String(read.reason)})
			continue
		var content: String = String(read.text)
		if content.contains(resource_path) or (uid_text != "" and content.contains(uid_text)):
			references.append(scene_path)
	references.sort()
	return {
		ok = errors.is_empty(),
		references = references,
		errors = errors,
		fingerprint = "\n".join(references).sha256_text(),
	}


## 递归收集 root 下全部 .tscn 路径（跳过 . 开头目录与文件）；打不开的目录记入 errors。无返回值。
func _collect_tscn_files(dir_path: String, out: PackedStringArray, errors: Array) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		errors.append({path = dir_path, reason = "无法打开扫描目录。"})
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				_collect_tscn_files(dir_path.path_join(entry), out, errors)
			elif entry.ends_with(".tscn"):
				out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


## 读取场景文本；打开失败或 0 字节（非合法场景文本）均记为不可读。返回 {ok, reason, text}。
func _read_scene_text(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {ok = false, reason = "无法读取（错误码 %d）。" % FileAccess.get_open_error(), text = ""}
	var text: String = file.get_as_text()
	file.close()
	if text.is_empty():
		return {ok = false, reason = "场景文件为空，无法解析。", text = ""}
	return {ok = true, reason = "", text = text}
