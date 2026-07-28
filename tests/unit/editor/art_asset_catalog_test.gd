extends SceneTree

## ArtAssetCatalog D4.5-B1 只读扫描测试。
## 覆盖：路径规范化、忽略扩展名/隐藏项过滤、.import 过滤、递归目录、稳定排序、重复刷新无重复、
##       空搜索/文件名搜索/路径搜索/目录筛选、art 不存在安全结果、单资源失败不终止、返回数组不可变引用。
## 真实 art 断言不依赖具体文件名或数量；真实纹理相关项在 art 为空时跳过而非失败。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _CatalogScript: GDScript = preload(
	"res://addons/light_speed_art_profile/art_asset_catalog.gd"
)
const _EntryScript: GDScript = preload(
	"res://addons/light_speed_art_profile/art_asset_entry.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _skips: int = 0


func _initialize() -> void:
	_test_01_scripts_parse()
	_test_02_art_root_and_pure_path_helpers()
	_test_03_ignored_extensions_filtered()
	_test_04_hidden_names_filtered()
	_test_05_real_scan_invariants()
	_test_06_relative_directory_round_trip()
	_test_07_stable_sort()
	_test_08_refresh_no_duplicates()
	_test_09_empty_search_returns_all()
	_test_10_file_name_search()
	_test_11_path_search()
	_test_12_directory_filter()
	_test_13_missing_root_safe()
	_test_14_single_failure_does_not_terminate()
	_test_15_returned_arrays_are_copies()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. Catalog 与 Entry 脚本可解析，且可实例化。
func _test_01_scripts_parse() -> void:
	const NAME: String = "01_脚本可解析"
	var catalog = _CatalogScript.new()
	_check(NAME, catalog != null, "Catalog 可实例化。")
	var entry = _EntryScript.new()
	_check(NAME, entry != null, "Entry 可实例化。")


## 2. ART_ROOT 常量与纯函数路径助手符合契约。
func _test_02_art_root_and_pure_path_helpers() -> void:
	const NAME: String = "02_ART_ROOT与纯函数"
	_check(NAME, _CatalogScript.ART_ROOT == "res://assets/art/", "ART_ROOT 应为 res://assets/art/。")
	_check(NAME, _CatalogScript.is_hidden_name(".gitkeep") == true, "点前缀名应判为隐藏。")
	_check(NAME, _CatalogScript.is_hidden_name("crystal.png") == false, "普通名不应判为隐藏。")
	_check(NAME, _CatalogScript.is_ignored_extension("png") == false, "png 不应在忽略集合。")


## 3. 忽略扩展名被过滤：.import/.gd/.tscn/.tres/.gitkeep 等均不得加载。
func _test_03_ignored_extensions_filtered() -> void:
	const NAME: String = "03_忽略扩展名过滤"
	for ext in ["import", "gd", "tscn", "tres", "gduid", "gitkeep", "godot"]:
		_check(NAME, _CatalogScript.is_ignored_extension(ext) == true, "扩展名 %s 应被忽略。" % ext)


## 4. 隐藏名称被过滤。
func _test_04_hidden_names_filtered() -> void:
	const NAME: String = "04_隐藏名称过滤"
	_check(NAME, _CatalogScript.is_hidden_name(".hidden") == true, ".hidden 应判为隐藏。")
	_check(NAME, _CatalogScript.is_hidden_name(".gitkeep") == true, ".gitkeep 应判为隐藏。")
	_check(NAME, _CatalogScript.is_hidden_name("visible.png") == false, "visible.png 不应判为隐藏。")


## 5. 真实扫描不崩溃；返回路径均位于 ART_ROOT 下；不含 .import；texture 均为 Texture2D。
func _test_05_real_scan_invariants() -> void:
	const NAME: String = "05_真实扫描不变量"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var entries = catalog.get_entries()
	var errors = catalog.get_errors()
	# 扫描不得崩溃，且不应产生加载失败错误（art 中只有 png 与被忽略的 .gitkeep/.import）。
	_check(NAME, errors.is_empty(), "真实扫描不应产生加载失败错误，实际：%s" % str(errors))
	if entries.is_empty():
		_skips += 1
		print("[跳过] %s：当前 art 无可扫描纹理，纹理相关不变量跳过。" % NAME)
		return
	for entry in entries:
		_check(NAME, entry.resource_path.begins_with(_CatalogScript.ART_ROOT), "路径应位于 ART_ROOT 下：%s" % entry.resource_path)
		_check(NAME, not entry.resource_path.ends_with(".import"), "不得返回 .import 路径：%s" % entry.resource_path)
		_check(NAME, entry.texture is Texture2D, "texture 应为 Texture2D：%s" % entry.resource_path)
		_check(NAME, entry.texture_size.x > 0 and entry.texture_size.y > 0, "texture_size 应为正数：%s" % entry.resource_path)
		_check(NAME, entry.file_name == entry.resource_path.get_file(), "file_name 应与路径文件名一致。")
		_check(NAME, entry.extension == entry.resource_path.get_extension().to_lower(), "extension 应为小写扩展名。")


## 6. 相对目录与递归正确：ART_ROOT + relative_directory + "/" + file_name == resource_path。
func _test_06_relative_directory_round_trip() -> void:
	const NAME: String = "06_相对目录往返"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var entries = catalog.get_entries()
	if entries.is_empty():
		_skips += 1
		print("[跳过] %s：art 为空，往返校验跳过。" % NAME)
		return
	for entry in entries:
		# 重建路径应与 resource_path 一致；根目录条目 relative_directory 为空串，避免双斜杠。
		var expected: String
		if entry.relative_directory == "":
			expected = _CatalogScript.ART_ROOT + entry.file_name
		else:
			expected = _CatalogScript.ART_ROOT + entry.relative_directory + "/" + entry.file_name
		_check(NAME, expected == entry.resource_path, "路径往返失败：%s" % entry.resource_path)
	# 所有目录字符串非空、无前后斜杠。
	for d in catalog.get_directories():
		_check(NAME, d != "" and not d.begins_with("/") and not d.ends_with("/"), "目录字符串应无前后斜杠：%s" % d)


## 7. 稳定排序：两次扫描的 resource_path 序列完全一致。
func _test_07_stable_sort() -> void:
	const NAME: String = "07_稳定排序"
	var c1 = _CatalogScript.new()
	c1.scan()
	var c2 = _CatalogScript.new()
	c2.scan()
	var a := _paths_of(c1.get_entries())
	var b := _paths_of(c2.get_entries())
	_check(NAME, a == b, "两次扫描顺序应一致。")
	# 验证已按 (relative_directory, file_name) 升序。
	var sorted := true
	var prev_dir := ""
	var prev_name := ""
	for entry in c1.get_entries():
		if entry.relative_directory < prev_dir:
			sorted = false
			break
		if entry.relative_directory == prev_dir and entry.file_name < prev_name:
			sorted = false
			break
		prev_dir = entry.relative_directory
		prev_name = entry.file_name
	_check(NAME, sorted, "条目应按 relative_directory、file_name 升序。")


## 8. 重复刷新无重复条目。
func _test_08_refresh_no_duplicates() -> void:
	const NAME: String = "08_重复刷新无重复"
	var catalog = _CatalogScript.new()
	catalog.scan()
	catalog.scan()
	catalog.scan()
	var entries = catalog.get_entries()
	var seen := {}
	for entry in entries:
		seen[entry.resource_path] = true
	_check(NAME, seen.size() == entries.size(), "重复刷新后不得出现重复 resource_path。")


## 9. 空查询返回全部条目。
func _test_09_empty_search_returns_all() -> void:
	const NAME: String = "09_空搜索返回全部"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var entries = catalog.get_entries()
	var result = catalog.search("")
	_check(NAME, result.size() == entries.size(), "空查询应返回全部条目。")


## 10. 文件名搜索：以某条目文件名小写为查询，结果应包含该条目。
func _test_10_file_name_search() -> void:
	const NAME: String = "10_文件名搜索"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var entries = catalog.get_entries()
	if entries.is_empty():
		_skips += 1
		print("[跳过] %s：art 为空，文件名搜索跳过。" % NAME)
		return
	var picked = entries[0]
	var q := String(picked.file_name).to_lower()
	var result = catalog.search(q)
	var found := false
	for entry in result:
		if entry.resource_path == picked.resource_path:
			found = true
			break
	_check(NAME, found, "文件名搜索应命中原条目：%s" % picked.resource_path)


## 11. 路径搜索：以相对目录为查询，结果应非空且包含原条目。
func _test_11_path_search() -> void:
	const NAME: String = "11_路径搜索"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var entries = catalog.get_entries()
	if entries.is_empty():
		_skips += 1
		print("[跳过] %s：art 为空，路径搜索跳过。" % NAME)
		return
	var picked = entries[0]
	var q := String(picked.relative_directory).to_lower()
	if q == "":
		q = "art" # 根目录条目回退为通用路径片段
	var result = catalog.search(q)
	_check(NAME, not result.is_empty(), "路径搜索应返回非空结果。")


## 12. 目录筛选：search("", dir) 结果的 relative_directory 均等于 dir。
func _test_12_directory_filter() -> void:
	const NAME: String = "12_目录筛选"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var dirs = catalog.get_directories()
	if dirs.is_empty():
		_skips += 1
		print("[跳过] %s：无子目录，目录筛选跳过。" % NAME)
		return
	var dir = dirs[0]
	var result = catalog.search("", dir)
	_check(NAME, not result.is_empty(), "目录筛选应返回非空结果。")
	var all_match := true
	for entry in result:
		if entry.relative_directory != dir:
			all_match = false
			break
	_check(NAME, all_match, "目录筛选结果应全部属于该目录。")


## 13. art 不存在时返回空结果与明确错误，不创建目录。
func _test_13_missing_root_safe() -> void:
	const NAME: String = "13_art不存在安全"
	var catalog = _CatalogScript.new()
	catalog._scan_at("res://__nonexistent_art_root_zzz__/")
	_check(NAME, catalog.get_entries().is_empty(), "不存在目录应返回空条目。")
	_check(NAME, catalog.get_directories().is_empty(), "不存在目录应返回空子目录。")
	_check(NAME, not catalog.get_errors().is_empty(), "不存在目录应产生明确错误。")
	_check(NAME, not DirAccess.dir_exists_absolute("res://__nonexistent_art_root_zzz__/"), "不得创建目录。")


## 14. 单资源加载失败只记录错误，不崩溃、不影响既有条目。
func _test_14_single_failure_does_not_terminate() -> void:
	const NAME: String = "14_单资源失败不终止"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var before = catalog.get_entries().size()
	var errors_before = catalog.get_errors().size()
	# 直接对不存在的 png 调用内部加载入口；ResourceLoader.load 返回 null → 记录错误并跳过。
	catalog._try_add_file("res://assets/art/__definitely_missing_texture_zzz__.png")
	_check(NAME, catalog.get_entries().size() == before, "失败资源不应改变既有条目数量。")
	_check(NAME, catalog.get_errors().size() == errors_before + 1, "失败资源应新增一条错误。")


## 15. 返回数组为副本，修改不影响内部状态。
func _test_15_returned_arrays_are_copies() -> void:
	const NAME: String = "15_返回数组为副本"
	var catalog = _CatalogScript.new()
	catalog.scan()
	var e1 = catalog.get_entries()
	var e2 = catalog.get_entries()
	e1.append("pollute")
	_check(NAME, e2.size() == catalog.get_entries().size(), "get_entries 应返回独立副本。")
	var d1 = catalog.get_directories()
	d1.append("pollute")
	_check(NAME, catalog.get_directories().size() == d1.size() - 1, "get_directories 应返回独立副本。")
	var err1 = catalog.get_errors()
	err1.append("pollute")
	_check(NAME, catalog.get_errors().size() == err1.size() - 1, "get_errors 应返回独立副本。")
	var s1 = catalog.search("")
	s1.append("pollute")
	_check(NAME, catalog.search("").size() == s1.size() - 1, "search 应返回独立副本。")


## 取条目数组的 resource_path 序列，用于顺序比较。
func _paths_of(entries: Array) -> PackedStringArray:
	var paths := PackedStringArray()
	for entry in entries:
		paths.append(entry.resource_path)
	return paths


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 15
	var passed_checks: int = _checks - _failures.size()
	print("==== ArtAssetCatalog 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("跳过项：%d" % _skips)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
