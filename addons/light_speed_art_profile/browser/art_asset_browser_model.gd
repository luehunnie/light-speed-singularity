@tool
class_name LightSpeedArtProfileArtAssetBrowserModel
extends RefCounted

## 美术资产浏览器纯状态模型。
## 职责：保存 Catalog 扫描结果副本，维护当前目录/搜索/过滤/选中/错误状态。
## 输入输出：set_catalog_data 注入 entries/directories/errors；get_* 返回副本，不暴露内部引用。
## 副作用：无文件系统访问、不持有节点、不修改 Entry；仅维护内部状态。
## 边界：返回数组均为副本；刷新后失效目录回根、失效选择清空；过滤保持 Catalog 原排序。

var _entries: Array = []                 # Entry 引用副本（Entry 只读语义，不修改）
var _directories: Array = []             # 子目录字符串副本（相对 ART_ROOT，不含根）
var _errors: Array = []                  # 错误字符串副本
var _current_directory: String = ""      # 当前目录；"" 表示根（显示全部）
var _query: String = ""                  # 当前搜索文本
var _filtered: Array = []                # 当前过滤结果（按目录+搜索重算）
var _selected_resource_path: String = "" # 当前选中资源路径


## 注入 Catalog 扫描结果副本；保留仍存在的选择，失效目录回根，失效选择清空。
## entries/directories/errors 为 Catalog 返回的数组；无返回；不修改入参数组与 Entry。
func set_catalog_data(entries: Array, directories: Array, errors: Array) -> void:
	_entries = entries.duplicate()
	_directories = directories.duplicate()
	_errors = errors.duplicate()
	# 刷新后旧目录已不存在则回到根目录
	if _current_directory != "" and not _directories.has(_current_directory):
		_current_directory = ""
	# 刷新后选中资源已不存在则清空选择
	if _selected_resource_path != "" and _find_entry(_selected_resource_path) == null:
		_selected_resource_path = ""
	_recompute_filtered()


## 设置当前目录；"" 表示根（全部资源）；不影响选择与搜索文本。
func set_directory(relative_directory: String) -> void:
	_current_directory = relative_directory
	_recompute_filtered()


## 设置搜索文本；空串恢复当前目录全部资源；即时更新过滤，不重新扫描。
func set_query(query: String) -> void:
	_query = query
	_recompute_filtered()


## 返回当前过滤结果副本；调用方修改返回数组不影响内部状态。
func get_filtered_entries() -> Array:
	return _filtered.duplicate()


## 返回子目录列表副本（相对 ART_ROOT，不含根）。
func get_directories() -> Array:
	return _directories.duplicate()


## 返回错误列表副本；空表示无错误或尚未扫描。
func get_errors() -> Array:
	return _errors.duplicate()


## 返回当前目录；"" 表示根。
func get_current_directory() -> String:
	return _current_directory


## 返回当前搜索文本。
func get_query() -> String:
	return _query


## 选中指定 resource_path 的条目；存在则选中并返回 true，否则不变返回 false。
func select_entry(resource_path: String) -> bool:
	if resource_path == "" or _find_entry(resource_path) == null:
		return false
	_selected_resource_path = resource_path
	return true


## 返回当前选中条目；无选择或失效时返回 null。
## 返回单个只读 Entry 引用，非内部数组引用；调用方不得修改其字段。
func get_selected_entry() -> RefCounted:
	if _selected_resource_path == "":
		return null
	return _find_entry(_selected_resource_path)


## 返回当前选中资源路径；无选择为空串。
func get_selected_resource_path() -> String:
	return _selected_resource_path


## 清空当前选择。
func clear_selection() -> void:
	_selected_resource_path = ""


## 按当前目录与搜索重算过滤结果；保持 Catalog 原排序，不重新扫描。
func _recompute_filtered() -> void:
	var q := _query.to_lower()
	var result: Array = []
	for entry in _entries:
		if _current_directory != "" and entry.relative_directory != _current_directory:
			continue
		if q != "":
			var matched: bool = entry.file_name.to_lower().contains(q) \
					or entry.resource_path.to_lower().contains(q)
			if not matched:
				continue
		result.append(entry)
	_filtered = result


## 按 resource_path 查找内部条目；返回 Entry 或 null。
func _find_entry(resource_path: String) -> RefCounted:
	for entry in _entries:
		if entry.resource_path == resource_path:
			return entry
	return null
