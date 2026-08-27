@tool
class_name LightSpeedArtProfileArtAssetCatalog
extends RefCounted

## 美术资产只读扫描目录。
## 职责：递归扫描 res://assets/art/，产出 ArtAssetEntry 列表、子目录列表与错误列表，并提供搜索。
## 输入输出：scan() 触发文件系统只读遍历；get_* 与 search 返回新数组，不暴露内部引用。
## 副作用：仅读取目录与加载已导入资源；不创建、修改、删除任何文件或 .import/.godot 缓存。
## 边界：隐藏项、.import、.gd/.tscn/.tres 等非美术扩展名与不可加载为 Texture2D 的文件一律跳过；
##       单资源失败只记录错误并跳过，不中断整体扫描；art 不存在时返回空结果与明确错误，不创建目录。

# 通过 preload 引用 Entry 脚本，规避新 class_name 在运行期尚未注册时的 "Could not find type" 坑。
const _EntryScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/browser/art_asset_entry.gd"
)

## 正式美术源目录。注：任务冻结事实 #1 写 res://art/，但仓库实际美术资产位于 res://assets/art/，
## 经确认以仓库真实路径为准；改为单一常量便于后续统一调整。
const ART_ROOT: String = "res://assets/art/"

# 明确不读取的扩展名（小写）；命中即静默跳过，不视为加载失败。
# 使用数组字面量以符合 const 常量表达式要求。
const _IGNORED_EXTS: Array = [
	"import", "gd", "tscn", "tres", "gduid", "uid", "godot",
	"gitkeep", "gitignore", "md", "txt", "tmp", "bak", "old", "swp",
	"csv", "json", "cfg", "shader", "gdshader",
]

var _entries: Array = []
var _directories: Array = []
var _errors: Array = []


## 触发一次完整扫描，覆盖既有结果。
## 无参数无返回；副作用为重置并重建 _entries/_directories/_errors；重复调用不产生重复条目。
func scan() -> void:
	_scan_at(ART_ROOT)


## 内部扫描入口；暴露 root 仅供测试注入不存在路径，不作为公开写入口。
## root 为 res:// 目录路径；无返回；失败时填充 _errors 并保持空结果。
func _scan_at(root: String) -> void:
	_entries.clear()
	_directories.clear()
	_errors.clear()
	if not DirAccess.dir_exists_absolute(root):
		_errors.append("美术源目录不存在: %s" % root)
		return
	_walk(root)


## 递归遍历目录，收集子目录与可加载为 Texture2D 的资源。
## dir_res_path 为 res:// 目录路径；无返回；只读访问 DirAccess，不创建或删除条目外文件。
func _walk(dir_res_path: String) -> void:
	var dir := DirAccess.open(dir_res_path)
	if dir == null:
		_errors.append("无法打开目录: %s" % dir_res_path)
		return
	var rel_dir := _relative_directory(dir_res_path)
	if rel_dir != "" and not _directories.has(rel_dir):
		_directories.append(rel_dir)
	dir.list_dir_begin() # Godot 4.6 不再接受参数；隐藏项与导航项由下方名称判断兜底
	var name := dir.get_next()
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		if is_hidden_name(name):
			name = dir.get_next()
			continue
		var child_path := dir_res_path.path_join(name)
		if dir.current_is_dir():
			_walk(child_path)
		else:
			_try_add_file(child_path)
		name = dir.get_next()
	dir.list_dir_end()
	# 仅对根目录结果排序一次；递归返回后由 scan 统一排序亦可，此处保证 get_* 在部分扫描下也稳定。
	if rel_dir == "":
		_entries.sort_custom(Callable(self, "_compare_entries"))
		_directories.sort()


## 尝试将单个文件加入为条目；命中忽略扩展名或非 Texture2D 时静默跳过，加载失败时记录错误。
## res_path 为文件 res:// 路径；无返回；成功时追加一个 ArtAssetEntry 到 _entries。
func _try_add_file(res_path: String) -> void:
	var ext := res_path.get_extension().to_lower()
	if is_ignored_extension(ext):
		return
	var resource := ResourceLoader.load(res_path)
	if resource == null:
		_errors.append("资源加载失败: %s" % res_path)
		return
	if not (resource is Texture2D):
		return
	var texture: Texture2D = resource
	var entry: RefCounted = _EntryScript.new()
	entry.resource_path = res_path
	entry.file_name = res_path.get_file()
	entry.relative_directory = _relative_directory(res_path.get_base_dir())
	entry.extension = ext
	entry.texture = texture
	entry.texture_size = Vector2i(texture.get_size())
	_entries.append(entry)


## 计算 res:// 路径相对 ART_ROOT 的子目录；根目录返回空串。
## dir_res_path 为目录 res:// 路径；返回去除前后斜杠的相对目录字符串；无副作用。
func _relative_directory(dir_res_path: String) -> String:
	# 以去尾斜杠的 ART_ROOT 为前缀比较，兼容 base_dir 不带尾斜杠与根目录自身两种情况。
	var rel := dir_res_path.trim_prefix(ART_ROOT.rstrip("/"))
	rel = rel.trim_prefix("/")
	rel = rel.trim_suffix("/")
	return rel


## 条目排序比较：先按 relative_directory，再按 file_name，均为大小写敏感字典序。
## 返回 true 表示 a 应排在 b 之前；无副作用；键唯一故排序确定性不受稳定性影响。
func _compare_entries(a, b) -> bool:
	var a_dir: String = a.relative_directory
	var b_dir: String = b.relative_directory
	if a_dir != b_dir:
		return a_dir < b_dir
	return a.file_name < b.file_name


## 返回条目列表的副本；调用方修改返回数组不影响内部状态。
## 无参数；返回 Array（元素为 ArtAssetEntry）；无副作用。
func get_entries() -> Array:
	return _entries.duplicate()


## 返回子目录列表的副本（相对 ART_ROOT，已排序，不含根）。
## 无参数；返回 Array（元素为 String）；无副作用。
func get_directories() -> Array:
	return _directories.duplicate()


## 返回错误列表的副本；空表示无错误或尚未扫描。
## 无参数；返回 Array（元素为 String）；无副作用。
func get_errors() -> Array:
	return _errors.duplicate()


## 在已扫描结果中搜索；不重新扫描文件系统，不修改排序。
## query 为空且未指定目录时返回全部；目录筛选按 relative_directory 精确匹配；
## 文件名与资源路径均大小写不敏感包含匹配。返回新数组，不影响内部状态。
func search(query: String, optional_directory: String = "") -> Array:
	var q := query.to_lower()
	var result: Array = []
	for entry in _entries:
		if optional_directory != "" and entry.relative_directory != optional_directory:
			continue
		if q != "":
			var matched: bool = entry.file_name.to_lower().contains(q) \
					or entry.resource_path.to_lower().contains(q)
			if not matched:
				continue
		result.append(entry)
	return result


## 判断名称是否为隐藏项（点前缀）。name 为文件或目录名；返回 bool；无副作用。
static func is_hidden_name(name: String) -> bool:
	return name.begins_with(".")


## 判断扩展名是否在忽略集合内（不可读取或非美术资源）。ext 为小写扩展名；返回 bool；无副作用。
static func is_ignored_extension(ext: String) -> bool:
	var e := ext.to_lower()
	for forbidden in _IGNORED_EXTS:
		if e == forbidden:
			return true
	return false
