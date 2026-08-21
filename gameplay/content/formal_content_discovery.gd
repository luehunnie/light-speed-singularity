class_name FormalContentDiscovery
extends RefCounted

## 定义发现管线（AF-01 / P0-1，Guide 5）：扫描定义目录 → 逐个校验 → 冲突检测 → 产出合法定义集。
## 冻结原则：Definition = Truth，Registry = Index；发现结果不依赖第二份人工类型名单（Guide 5.2）。
## 新增正式类型 = 在定义目录新增自身声明文件，零中心修改。
## 本批检测域（Guide 5.3 最小集）：重复 content_type_id、Definition 非法、PackedScene 缺失、非定义资源混入。
## 稳定 Field / Event / Action ID 冲突检测属 P0-4 / P1 各域，到位后 additive 接入。
## 打包导出下的目录扫描在后续阶段以自动 Manifest / Cache 收口（Guide 5.2 允许），本批路径可注入。


## 默认定义目录。
const DEFAULT_DEFINITIONS_DIR: String = "res://gameplay/content/definitions"


## 扫描并校验一个定义目录。
## [br]返回 Dictionary：ok: bool、definitions: Array[FormalContentDefinition]（合法集，按文件名序）、errors: PackedStringArray。
## [br]任一错误即 ok=false（fail-fast，不产出可用的半成品索引）。
static func discover(definitions_dir: String = DEFAULT_DEFINITIONS_DIR) -> Dictionary:
	var errors := PackedStringArray()
	var definitions: Array[FormalContentDefinition] = []
	var seen_type_paths: Dictionary[StringName, String] = {}
	var dir := DirAccess.open(definitions_dir)
	if dir == null:
		errors.append("定义目录不可打开：%s" % definitions_dir)
		return {"ok": false, "definitions": definitions, "errors": errors}
	var file_names := PackedStringArray()
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not file_name.begins_with("."):
			file_names.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	file_names.sort()
	for name: String in file_names:
		if not (name.ends_with(".tres") or name.ends_with(".res")):
			continue
		var path := definitions_dir.path_join(name)
		var resource := ResourceLoader.load(path)
		if resource == null:
			errors.append("资源加载失败：%s" % path)
			continue
		if not (resource is FormalContentDefinition):
			errors.append("非 FormalContentDefinition 资源：%s" % path)
			continue
		var definition := resource as FormalContentDefinition
		var def_errors := definition.validate_definition()
		for def_error: String in def_errors:
			errors.append("%s：%s" % [path, def_error])
		var type_id := definition.content_type_id
		if type_id == &"":
			continue
		if seen_type_paths.has(type_id):
			errors.append("重复 content_type_id %s：%s 与 %s" % [type_id, seen_type_paths[type_id], path])
			continue
		if def_errors.is_empty():
			seen_type_paths[type_id] = path
			definitions.append(definition)
	return {"ok": errors.is_empty(), "definitions": definitions, "errors": errors}
