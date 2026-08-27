extends SceneTree

## S3-03 Workbench 冻结九步导入流水线测试（GUI 冻结总结 v1.0 §36/§38/§39）。
## 覆盖：九步全过、格式拒绝、Strict 尺寸阻止、Recommended 警告可继续、
##       覆盖策略、钩子缺省降级。
## 由 Godot --headless --script 运行；任一失败 quit(1)。载体全部使用 user:// 临时目录。

const _ImportServiceScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/formal_asset_import_service.gd"
)

const _SRC_DIR: String = "user://wb_import_test/src/"
const _FORMAL_DIR: String = "user://wb_import_test/formal/"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service = null
var _g1_bound_paths: Array = []


## G1 钩子桩：preset 步 pass。
func _g1_preset(_formal_path: String) -> Dictionary:
	return { status = "pass", detail = "preset ok" }


## G1 钩子桩：import 步 pass。
func _g1_import(_formal_path: String) -> Dictionary:
	return { status = "pass", detail = "import ok" }


## G1 钩子桩：记录收到的 formal_path 并返回绑定成功。
func _g1_binder(formal_path: String) -> Dictionary:
	_g1_bound_paths.append(formal_path)
	return { ok = true, detail = "bound" }


## G1 钩子桩：preview 步 pass。
func _g1_preview(_formal_path: String) -> Dictionary:
	return { status = "pass", detail = "refreshed" }


func _initialize() -> void:
	_service = _ImportServiceScript.new()
	_prepare_dirs()
	_test_full_nine_steps_pass()
	_test_format_rejected()
	_test_strict_size_blocks()
	_test_recommended_size_warns()
	_test_overwrite_policy()
	_test_hooks_default_degraded()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 建立干净的 user:// 测试目录（重复运行幂等）。
func _prepare_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(_SRC_DIR)
	DirAccess.make_dir_recursive_absolute(_FORMAL_DIR)
	_clear_formal()


## 清空正式目录（组间隔离，保证空目录断言与覆盖策略不受前组产物影响）。
func _clear_formal() -> void:
	for existing: String in DirAccess.get_files_at(_FORMAL_DIR):
		DirAccess.remove_absolute(_FORMAL_DIR + existing)


## 生成指定尺寸的纯色 PNG 并返回其路径。
func _make_png(file_name: String, size: Vector2i) -> String:
	var image: Image = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var path: String = _SRC_DIR + file_name
	image.save_png(path)
	return path


## G1 九步全过：9 项步骤、顺序冻结、全 pass、产物落盘、规范名正确、绑定钩子收到 formal_path。
func _test_full_nine_steps_pass() -> void:
	const NAME: String = "G1_九步全过"
	var source: String = _make_png("src_img.png", Vector2i(64, 64))
	var hooks: Dictionary = {
		preset_applier = Callable(self, "_g1_preset"),
		import_trigger = Callable(self, "_g1_import"),
		slot_binder = Callable(self, "_g1_binder"),
		preview_refresher = Callable(self, "_g1_preview"),
	}
	var result: Dictionary = _service.run_import({
		source_path = source,
		formal_dir = _FORMAL_DIR,
		identity = "WbTest", slot = "State", state = "Idle", direction = "", usage = "World",
		size_mode = "strict", expected_size = Vector2i(64, 64),
		overwrite = true,
		hooks = hooks,
	})
	_check(NAME, bool(result["ok"]), "九步应全部成功。")
	_check(NAME, result["steps"].size() == 9, "步骤数应恒为 9，实际 %d。" % result["steps"].size())
	var ids: PackedStringArray = PackedStringArray()
	for step: Dictionary in result["steps"]:
		ids.append(String(step["id"]))
		_check(NAME, String(step["status"]) == "pass", "步骤 %s 应 pass，实际 %s。" % [step["id"], step["status"]])
	_check(NAME, ",".join(ids) == ",".join(PackedStringArray(_service.STEP_IDS)), "九步顺序应与冻结一致。")
	_check(NAME, result["canonical_name"] == "wbtest_state_idle_world.png", "规范名应为 wbtest_state_idle_world.png，实际 %s。" % result["canonical_name"])
	_check(NAME, FileAccess.file_exists(String(result["formal_path"])), "产物应复制到正式目录。")
	_check(NAME, _g1_bound_paths == [String(result["formal_path"])], "绑定钩子应收到 formal_path。")


## G2 格式拒绝：不支持的扩展在第 2 步失败，后续步骤 not_run，不复制文件。
func _test_format_rejected() -> void:
	const NAME: String = "G2_格式拒绝"
	_clear_formal()
	var source: String = _SRC_DIR + "bad.bmp"
	var writer: FileAccess = FileAccess.open(source, FileAccess.WRITE)
	writer.store_buffer(PackedByteArray([1, 2, 3]))
	writer.close()
	var result: Dictionary = _service.run_import({
		source_path = source, formal_dir = _FORMAL_DIR,
		identity = "Wb", slot = "State", state = "Idle", direction = "", usage = "World",
		overwrite = true,
	})
	_check(NAME, not bool(result["ok"]), "不支持的格式应失败。")
	_check(NAME, String(result["steps"][1]["status"]) == "fail", "第 2 步应 fail。")
	_check(NAME, result["steps"].size() == 9, "失败也应补齐 9 步记录。")
	var not_run: int = 0
	for step: Dictionary in result["steps"]:
		if String(step["status"]) == "not_run":
			not_run += 1
	_check(NAME, not_run == 7, "第 2 步失败后应有 7 步 not_run，实际 %d。" % not_run)
	_check(NAME, DirAccess.get_files_at(_FORMAL_DIR).is_empty(), "失败时不应复制任何文件。")


## G3 Strict 尺寸阻止：尺寸不符即 fail 且不复制（§39 不自动缩放）。
func _test_strict_size_blocks() -> void:
	const NAME: String = "G3_Strict尺寸阻止"
	_clear_formal()
	var source: String = _make_png("small.png", Vector2i(32, 32))
	var result: Dictionary = _service.run_import({
		source_path = source, formal_dir = _FORMAL_DIR,
		identity = "Wb", slot = "State", state = "Idle", direction = "", usage = "World",
		size_mode = "strict", expected_size = Vector2i(64, 64), overwrite = true,
	})
	_check(NAME, not bool(result["ok"]), "Strict 尺寸不符应失败。")
	_check(NAME, String(result["steps"][2]["status"]) == "fail", "第 3 步（尺寸合同）应 fail。")
	_check(NAME, DirAccess.get_files_at(_FORMAL_DIR).is_empty(), "Strict 阻止时不应复制文件。")


## G4 Recommended 尺寸警告可继续：warning 不阻断（§39）。
func _test_recommended_size_warns() -> void:
	const NAME: String = "G4_Recommended警告可继续"
	_clear_formal()
	var source: String = _make_png("small2.png", Vector2i(32, 32))
	var result: Dictionary = _service.run_import({
		source_path = source, formal_dir = _FORMAL_DIR,
		identity = "Wb", slot = "State", state = "Idle", direction = "", usage = "World",
		size_mode = "recommended", expected_size = Vector2i(64, 64), overwrite = true,
	})
	_check(NAME, bool(result["ok"]), "Recommended 警告应可继续。")
	_check(NAME, String(result["steps"][2]["status"]) == "warning", "第 3 步应为 warning。")


## G5 覆盖策略：目标存在且未允许覆盖 → 失败；显式 overwrite → 成功（§38 Replace）。
func _test_overwrite_policy() -> void:
	const NAME: String = "G5_覆盖策略"
	_clear_formal()
	var source: String = _make_png("over.png", Vector2i(64, 64))
	var request: Dictionary = {
		source_path = source, formal_dir = _FORMAL_DIR,
		identity = "Wb", slot = "State", state = "Idle", direction = "", usage = "World",
		overwrite = false,
	}
	var first: Dictionary = _service.run_import(request)
	_check(NAME, bool(first["ok"]), "首次导入应成功。")
	var second: Dictionary = _service.run_import(request)
	_check(NAME, not bool(second["ok"]), "未允许覆盖时再次导入应失败。")
	_check(NAME, String(second["steps"][4]["status"]) == "fail", "第 5 步（复制）应 fail。")
	request["overwrite"] = true
	var third: Dictionary = _service.run_import(request)
	_check(NAME, bool(third["ok"]), "显式 overwrite=true 应成功替换正式文件。")


## G6 钩子缺省降级：preset/import/bind/preview 四步 skipped，流水线整体仍 ok。
func _test_hooks_default_degraded() -> void:
	const NAME: String = "G6_钩子缺省降级"
	var source: String = _make_png("nohook.png", Vector2i(64, 64))
	var result: Dictionary = _service.run_import({
		source_path = source, formal_dir = _FORMAL_DIR,
		identity = "Wb", slot = "State", state = "Idle", direction = "", usage = "World",
		overwrite = true,
	})
	_check(NAME, bool(result["ok"]), "钩子缺省不应判失败（降级）。")
	for index: int in [5, 6, 7, 8]:
		_check(NAME, String(result["steps"][index]["status"]) == "skipped", "第 %d 步应 skipped，实际 %s。" % [index + 1, result["steps"][index]["status"]])


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench 九步导入流水线测试摘要 ====")
	print("测试组数：6")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
