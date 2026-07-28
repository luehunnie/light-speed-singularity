extends SceneTree

## ArtAssetBrowserModel D4.5-B2A 状态模型测试。
## 覆盖：初始为空、设置数据、根目录全量、子目录精确筛选、文件名/路径搜索、大小写不敏感、
##       空查询恢复、目录+搜索组合、选择存在/不存在、刷新保留/清空选择、返回数组副本、
##       错误与空状态传递、不修改入参与 Entry、刷新后失效目录回根。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ModelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/browser/art_asset_browser_model.gd"
)
const _EntryScript: GDScript = preload(
	"res://addons/light_speed_art_profile/browser/art_asset_entry.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_initially_empty()
	_test_02_set_catalog_data()
	_test_03_root_shows_all()
	_test_04_subdirectory_precise_filter()
	_test_05_file_name_search()
	_test_06_path_search()
	_test_07_search_case_insensitive()
	_test_08_empty_query_restores()
	_test_09_directory_and_search_combined()
	_test_10_select_existing_entry()
	_test_11_select_nonexistent_path_fails()
	_test_12_refresh_preserves_existing_selection()
	_test_13_refresh_clears_stale_selection()
	_test_14_returned_arrays_are_copies()
	_test_15_errors_and_empty_state_propagate()
	_test_16_does_not_mutate_inputs_or_entries()
	_test_17_refresh_resets_missing_directory_to_root()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一个测试用 Entry；texture 置空，模型不读取纹理。
func _make_entry(path: String, file: String, dir: String, ext: String, size: Vector2i) -> RefCounted:
	var entry: RefCounted = _EntryScript.new()
	entry.resource_path = path
	entry.file_name = file
	entry.relative_directory = dir
	entry.extension = ext
	entry.texture_size = size
	entry.texture = null
	return entry


## 构造标准测试数据集：5 个条目分布在根/crystals/mechanisms/mirrors/tilesets。
func _make_entries() -> Array:
	return [
		_make_entry("res://assets/art/crystals/crystal_blue_unlit.png", "crystal_blue_unlit.png", "crystals", "png", Vector2i(64, 64)),
		_make_entry("res://assets/art/crystals/crystal_red_lit.png", "crystal_red_lit.png", "crystals", "png", Vector2i(64, 64)),
		_make_entry("res://assets/art/mechanisms/mirrors/flat_mirror.png", "flat_mirror.png", "mechanisms/mirrors", "png", Vector2i(128, 128)),
		_make_entry("res://assets/art/tilesets/tilesets_32.png", "tilesets_32.png", "tilesets", "png", Vector2i(32, 32)),
		_make_entry("res://assets/art/background_01.png", "background_01.png", "", "png", Vector2i(256, 256)),
	]


const _DIRS: Array = ["crystals", "mechanisms/mirrors", "tilesets", "ui/items"]


## 1. 初始为空：新模型无条目、无目录、无错误、无选中。
func _test_01_initially_empty() -> void:
	const NAME: String = "01_初始为空"
	var model = _ModelScript.new()
	_check(NAME, model.get_filtered_entries().is_empty(), "初始过滤结果应为空。")
	_check(NAME, model.get_directories().is_empty(), "初始目录列表应为空。")
	_check(NAME, model.get_errors().is_empty(), "初始错误列表应为空。")
	_check(NAME, model.get_selected_entry() == null, "初始无选中。")
	_check(NAME, model.get_current_directory() == "", "初始目录应为根。")


## 2. 设置 Catalog 数据：目录与过滤结果就绪。
func _test_02_set_catalog_data() -> void:
	const NAME: String = "02_设置数据"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	_check(NAME, model.get_directories() == _DIRS, "目录列表应与注入一致。")
	_check(NAME, model.get_filtered_entries().size() == 5, "根目录应返回全部 5 项。")


## 3. 根目录显示全部：默认 current_directory 为根。
func _test_03_root_shows_all() -> void:
	const NAME: String = "03_根目录全量"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("")
	_check(NAME, model.get_filtered_entries().size() == 5, "根目录应显示全部资源。")


## 4. 子目录精确筛选：仅直属图片，不包含孙级。
func _test_04_subdirectory_precise_filter() -> void:
	const NAME: String = "04_子目录精确筛选"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("crystals")
	_check(NAME, model.get_filtered_entries().size() == 2, "crystals 应有 2 项。")
	model.set_directory("mechanisms/mirrors")
	_check(NAME, model.get_filtered_entries().size() == 1, "mechanisms/mirrors 应有 1 项。")
	model.set_directory("ui/items")
	_check(NAME, model.get_filtered_entries().is_empty(), "ui/items 无直属图片应为空。")
	# mechanisms 不是 mechanisms/mirrors，点击 mechanisms 不应返回孙级
	model.set_directory("mechanisms")
	_check(NAME, model.get_filtered_entries().is_empty(), "mechanisms 不应包含 mechanisms/mirrors 的孙级条目。")


## 5. 文件名搜索：以文件名片段命中。
func _test_05_file_name_search() -> void:
	const NAME: String = "05_文件名搜索"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("")
	model.set_query("blue")
	var result = model.get_filtered_entries()
	_check(NAME, result.size() == 1, "blue 应命中 1 项。")
	_check(NAME, result.size() == 1 and result[0].file_name == "crystal_blue_unlit.png", "应命中 blue 条目。")


## 6. 路径搜索：以路径片段命中（文件名不含该片段）。
func _test_06_path_search() -> void:
	const NAME: String = "06_路径搜索"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("")
	model.set_query("mechanisms/mirrors")
	var result = model.get_filtered_entries()
	_check(NAME, result.size() == 1, "路径搜索应命中 1 项。")
	_check(NAME, result.size() == 1 and result[0].file_name == "flat_mirror.png", "应命中 flat_mirror。")


## 7. 搜索大小写不敏感：大写查询命中小写文件名。
func _test_07_search_case_insensitive() -> void:
	const NAME: String = "07_大小写不敏感"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("")
	model.set_query("BLUE")
	_check(NAME, model.get_filtered_entries().size() == 1, "BLUE 应命中 blue。")
	model.set_query("CRYSTAL")
	_check(NAME, model.get_filtered_entries().size() == 2, "CRYSTAL 应命中 2 个 crystal。")


## 8. 空查询恢复：清空搜索后恢复当前目录全部。
func _test_08_empty_query_restores() -> void:
	const NAME: String = "08_空查询恢复"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("")
	model.set_query("blue")
	_check(NAME, model.get_filtered_entries().size() == 1, "前置：blue 命中 1 项。")
	model.set_query("")
	_check(NAME, model.get_filtered_entries().size() == 5, "空查询应恢复全部 5 项。")


## 9. 目录和搜索组合：在当前目录内搜索。
func _test_09_directory_and_search_combined() -> void:
	const NAME: String = "09_目录与搜索组合"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("crystals")
	model.set_query("red")
	_check(NAME, model.get_filtered_entries().size() == 1, "crystals+red 应命中 1 项。")
	model.set_query("")
	_check(NAME, model.get_filtered_entries().size() == 2, "crystals+空查询应返回 crystals 全部 2 项。")


## 10. 选择存在条目：select_entry 成功并返回该条目。
func _test_10_select_existing_entry() -> void:
	const NAME: String = "10_选择存在条目"
	var model = _ModelScript.new()
	var entries = _make_entries()
	model.set_catalog_data(entries, _DIRS, [])
	var ok: bool = model.select_entry("res://assets/art/crystals/crystal_blue_unlit.png")
	_check(NAME, ok, "选择存在路径应返回 true。")
	var sel = model.get_selected_entry()
	_check(NAME, sel != null and sel.resource_path == "res://assets/art/crystals/crystal_blue_unlit.png", "应返回已选中条目。")


## 11. 选择不存在路径失败：返回 false 且不改变选择。
func _test_11_select_nonexistent_path_fails() -> void:
	const NAME: String = "11_选择不存在失败"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.select_entry("res://assets/art/crystals/crystal_blue_unlit.png")
	var ok: bool = model.select_entry("res://assets/art/__nonexistent__.png")
	_check(NAME, ok == false, "选择不存在路径应返回 false。")
	_check(NAME, model.get_selected_entry() != null, "失败选择不应清空既有选择。")
	_check(NAME, model.get_selected_entry().resource_path == "res://assets/art/crystals/crystal_blue_unlit.png", "既有选择应保持不变。")


## 12. 刷新后保留仍存在的选择。
func _test_12_refresh_preserves_existing_selection() -> void:
	const NAME: String = "12_刷新保留选择"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.select_entry("res://assets/art/crystals/crystal_blue_unlit.png")
	model.set_catalog_data(_make_entries(), _DIRS, [])
	_check(NAME, model.get_selected_entry() != null, "刷新后仍存在的选择应保留。")
	_check(NAME, model.get_selected_entry().resource_path == "res://assets/art/crystals/crystal_blue_unlit.png", "保留的选择路径应一致。")


## 13. 刷新后清除失效选择。
func _test_13_refresh_clears_stale_selection() -> void:
	const NAME: String = "13_刷新清空失效选择"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.select_entry("res://assets/art/crystals/crystal_blue_unlit.png")
	# 新数据集不含被选中的条目
	var shrunk: Array = [
		_make_entry("res://assets/art/tilesets/tilesets_32.png", "tilesets_32.png", "tilesets", "png", Vector2i(32, 32)),
	]
	model.set_catalog_data(shrunk, ["tilesets"], [])
	_check(NAME, model.get_selected_entry() == null, "刷新后失效选择应被清空。")


## 14. 返回数组不暴露内部引用：修改返回数组不影响内部状态。
func _test_14_returned_arrays_are_copies() -> void:
	const NAME: String = "14_返回数组为副本"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, ["err1", "err2"])
	var f1 = model.get_filtered_entries()
	var before: int = f1.size()
	f1.append("pollute")
	_check(NAME, model.get_filtered_entries().size() == before, "get_filtered_entries 应返回副本。")
	var d1 = model.get_directories()
	d1.append("pollute")
	_check(NAME, model.get_directories().size() == _DIRS.size(), "get_directories 应返回副本。")
	var e1 = model.get_errors()
	e1.append("pollute")
	_check(NAME, model.get_errors().size() == 2, "get_errors 应返回副本。")


## 15. 错误和空状态传递：空数据+错误可被读取。
func _test_15_errors_and_empty_state_propagate() -> void:
	const NAME: String = "15_错误与空状态传递"
	var model = _ModelScript.new()
	model.set_catalog_data([], [], ["美术源目录不存在: res://assets/art/"])
	_check(NAME, model.get_filtered_entries().is_empty(), "空数据过滤结果应为空。")
	_check(NAME, model.get_errors().size() == 1, "错误应被传递。")
	_check(NAME, model.get_selected_entry() == null, "空数据下无选中。")


## 16. 不修改输入数组或 Entry：操作后入参数组与 Entry 字段不变。
func _test_16_does_not_mutate_inputs_or_entries() -> void:
	const NAME: String = "16_不修改入参与Entry"
	var model = _ModelScript.new()
	var entries = _make_entries()
	var dirs: Array = _DIRS.duplicate()
	var entry_size_before: int = entries.size()
	var e0_file_before: String = entries[0].file_name
	var e0_path_before: String = entries[0].resource_path
	var e0_dir_before: String = entries[0].relative_directory
	model.set_catalog_data(entries, dirs, [])
	model.set_directory("crystals")
	model.set_query("red")
	model.select_entry(entries[0].resource_path)
	model.set_catalog_data(entries, dirs, [])
	model.clear_selection()
	_check(NAME, entries.size() == entry_size_before, "不应修改入参 entries 数组大小。")
	_check(NAME, dirs.size() == _DIRS.size(), "不应修改入参 directories 数组大小。")
	_check(NAME, entries[0].file_name == e0_file_before, "不应修改 Entry.file_name。")
	_check(NAME, entries[0].resource_path == e0_path_before, "不应修改 Entry.resource_path。")
	_check(NAME, entries[0].relative_directory == e0_dir_before, "不应修改 Entry.relative_directory。")


## 17. 刷新后失效目录回到根目录。
func _test_17_refresh_resets_missing_directory_to_root() -> void:
	const NAME: String = "17_失效目录回根"
	var model = _ModelScript.new()
	model.set_catalog_data(_make_entries(), _DIRS, [])
	model.set_directory("crystals")
	_check(NAME, model.get_current_directory() == "crystals", "前置：当前目录为 crystals。")
	# 新数据集目录不含 crystals
	model.set_catalog_data(_make_entries(), ["tilesets"], [])
	_check(NAME, model.get_current_directory() == "", "刷新后失效目录应回根。")
	_check(NAME, model.get_filtered_entries().size() == 5, "回根后应显示全部资源。")


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 17
	var passed_checks: int = _checks - _failures.size()
	print("==== ArtAssetBrowserModel 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
