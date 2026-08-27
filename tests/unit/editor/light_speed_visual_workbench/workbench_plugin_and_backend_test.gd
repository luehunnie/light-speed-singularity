extends SceneTree

## S3-03 外观编辑器插件/后端迁移/中文名测试（GUI 冻结总结 v1.0 §2.2/§35 红线 + GUI FAIL 修复）。
## 覆盖：旧 light_speed_art_profile 插件已删除、Workbench 唯一 UI 注册、中文插件名与 Dock 标题、
##       Dock headless 可构造与业务入口呈现、Human 残留保护拦截、后端迁移无死引用。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _DockScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/workbench_dock.gd"
)
const _WORKBENCH_PLUGIN: String = "res://addons/light_speed_visual_workbench/plugin.gd"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_old_plugin_deleted()
	_test_workbench_single_ui_entry_and_chinese_names()
	_test_dock_constructs()
	_test_protected_profile_guard()
	_test_backend_migration()
	_report()
	quit(0 if _failures.is_empty() else 1)


## G1 旧插件删除红线：light_speed_art_profile 目录不存在；addons 下仅关卡编辑器与外观编辑器两插件。
func _test_old_plugin_deleted() -> void:
	const NAME: String = "G1_旧插件已删除"
	_check(NAME, not DirAccess.dir_exists_absolute("res://addons/light_speed_art_profile"), "旧 art_profile 插件目录应已删除。")
	var addons: Array = DirAccess.get_directories_at("res://addons")
	var expected: Array = ["light_speed_level_authoring", "light_speed_visual_workbench"]
	_check(NAME, _same_set(addons, expected), "addons 应只剩两个插件目录，实际 %s。" % ", ".join(PackedStringArray(addons)))


## G2 Workbench 唯一 UI 注册 + 中文名：恰一次 Dock 注册、DOCK_TITLE 中文化、两插件 cfg 均中文名。
func _test_workbench_single_ui_entry_and_chinese_names() -> void:
	const NAME: String = "G2_唯一入口与中文名"
	var source: String = FileAccess.get_file_as_string(_WORKBENCH_PLUGIN)
	var count: int = source.count("add_control_to_dock")
	_check(NAME, count == 1, "外观编辑器插件应恰一次 Dock 注册，实际 %d。" % count)
	_check(NAME, source.contains("_dock.name = DOCK_TITLE"), "注册前应设置中文 Dock 标题（禁 @VBoxContainer@ 自动名）。")
	_check(NAME, source.contains('DOCK_TITLE: String = "外观编辑器"'), "Dock 标题应为「外观编辑器」。")
	var wb_cfg: String = FileAccess.get_file_as_string("res://addons/light_speed_visual_workbench/plugin.cfg")
	_check(NAME, wb_cfg.contains('name="外观编辑器"'), "外观编辑器 plugin.cfg 应为中文插件名。")
	var la_cfg: String = FileAccess.get_file_as_string("res://addons/light_speed_level_authoring/plugin.cfg")
	_check(NAME, la_cfg.contains('name="关卡编辑器"'), "关卡编辑器 plugin.cfg 应为中文插件名。")
	var la_plugin: String = FileAccess.get_file_as_string("res://addons/light_speed_level_authoring/plugin.gd")
	_check(NAME, la_plugin.contains('DOCK_TITLE: String = "关卡编辑器"') and la_plugin.contains("_dock.name = DOCK_TITLE"), "关卡编辑器 Dock 标题应为中文且仅改名不改功能。")


## G3 Dock headless 构造：业务入口 7 项、Profile 列表加载、注入接口存在。
func _test_dock_constructs() -> void:
	const NAME: String = "G3_Dock可构造"
	var dock: Control = _DockScript.new()
	root.add_child(dock)
	dock._ready()
	_check(NAME, dock.has_method("set_editor_undo_redo"), "Dock 应提供 UndoRedo 注入接口。")
	_check(NAME, dock.BUSINESS_ENTRIES.size() == 7, "§35 业务入口应呈现 7 项，实际 %d。" % dock.BUSINESS_ENTRIES.size())
	_check(NAME, dock._profile_list.item_count == 6, "应列出 6 个正式 Profile，实际 %d。" % dock._profile_list.item_count)
	dock.set_editor_undo_redo(null)
	dock.free()


## G4 Human 残留保护：emitter_visuals 只读，动作层拒绝；非残留 Profile 可建 Change Set。
func _test_protected_profile_guard() -> void:
	const NAME: String = "G4_残留保护拦截"
	var dock: Control = _DockScript.new()
	root.add_child(dock)
	dock._ready()
	_check(NAME, dock.is_profile_protected("res://assets/visual_profiles/emitter_visuals.tres"), "emitter_visuals 应被标记保护。")
	_check(NAME, not dock.is_profile_protected("res://assets/visual_profiles/basic_crystal_visuals.tres"), "非残留 Profile 不应被保护。")
	var emitter_index: int = -1
	var basic_index: int = -1
	for i: int in range(dock._profile_paths.size()):
		var path: String = dock._profile_paths[i]
		if path.contains("emitter_visuals"):
			emitter_index = i
		elif path.contains("basic_crystal_visuals"):
			basic_index = i
	dock._profile_list.select(basic_index)
	dock._on_profile_selected(basic_index)
	_check(NAME, dock.get_change_set() != null, "非残留 Profile 应可建立 Change Set。")
	dock._profile_list.select(emitter_index)
	dock._on_profile_selected(emitter_index)
	dock._on_import_pressed()
	_check(NAME, dock._status_label.text.contains("保护"), "保护 Profile 的导入动作应被拦截并提示保护（实际：%s）。" % dock._status_label.text)
	dock.free()


## G5 后端迁移无死引用：Dock 引用 backend/ 服务路径且文件真实存在；后端脚本保留原 class_name（无重复实现）。
func _test_backend_migration() -> void:
	const NAME: String = "G5_后端迁移"
	var source: String = FileAccess.get_file_as_string(
		"res://addons/light_speed_visual_workbench/workbench_dock.gd")
	_check(NAME, source.contains("backend/editing/visual_state_edit_service.gd"), "Dock 应引用迁移后的 backend 编辑服务。")
	_check(NAME, source.contains("backend/browser/art_asset_catalog.gd"), "Dock 应引用迁移后的 backend Catalog。")
	for backend_path: String in [
		"res://addons/light_speed_visual_workbench/backend/editing/visual_state_edit_service.gd",
		"res://addons/light_speed_visual_workbench/backend/browser/art_asset_catalog.gd",
		"res://addons/light_speed_visual_workbench/backend/browser/art_asset_entry.gd",
		"res://addons/light_speed_visual_workbench/backend/target/visual_target_resolver.gd",
		"res://addons/light_speed_visual_workbench/backend/target/visual_target_result.gd",
	]:
		_check(NAME, FileAccess.file_exists(backend_path), "迁移后端文件应存在：%s。" % backend_path)


## 判断两个字符串数组是否为同集合（无序）。
func _same_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var pool: Array = b.duplicate()
	for item: String in a:
		var found: bool = false
		for candidate: String in pool:
			if candidate == item:
				pool.erase(candidate)
				found = true
				break
		if not found:
			return false
	return true


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench 插件与后端红线测试摘要 ====")
	print("测试组数：5")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
