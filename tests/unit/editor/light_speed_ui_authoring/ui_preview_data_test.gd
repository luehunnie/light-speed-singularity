extends SceneTree

## S3-04 UI Preview Data 测试（GUI 冻结总结 v1.0 §84）。
## 覆盖：四冻结预设、detached 语义、Ad-hoc 白名单/不改 base/会话临时、零落盘。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _PreviewData: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_preview_data_service.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service


func _initialize() -> void:
	_service = _PreviewData.new()
	_test_frozen_presets()
	_test_detached()
	_test_adhoc()
	_test_no_disk_write()
	_report()
	quit(0 if _failures.is_empty() else 1)


## G1 四冻结预设：ID 顺序、字段齐全、内容递进（Minimal→Stress）。
func _test_frozen_presets() -> void:
	const NAME: String = "G1_四冻结预设"
	_check(NAME, _service.PRESET_IDS == ["minimal", "typical", "long_content", "stress_test"], "四预设 ID 应与 §84 冻结一致。")
	for preset_id: String in _service.PRESET_IDS:
		var preset: Dictionary = _service.build_preset(preset_id)
		_check(NAME, not preset.is_empty(), "预设 %s 应存在。" % preset_id)
		_check(NAME, preset.has("inventory_count") and preset.has("objective_text") and preset.has("hint_text") and preset.has("counter_value"), "预设 %s 应含四个模拟维度。" % preset_id)
	var minimal: Dictionary = _service.build_preset("minimal")
	var stress: Dictionary = _service.build_preset("stress_test")
	_check(NAME, int(stress["inventory_count"]) > int(minimal["inventory_count"]), "Stress 库存数应大于 Minimal。")
	_check(NAME, String(stress["objective_text"]).length() > String(minimal["objective_text"]).length(), "Stress 目标文本应长于 Minimal。")
	_check(NAME, _service.build_preset("nonexistent").is_empty(), "未知预设应返回空字典。")


## G2 detached：修改返回副本不影响冻结源（再取仍为原值）。
func _test_detached() -> void:
	const NAME: String = "G2_detached语义"
	var preset: Dictionary = _service.build_preset("typical")
	preset["inventory_count"] = 999
	preset["nested_mark"] = true
	var fresh: Dictionary = _service.build_preset("typical")
	_check(NAME, int(fresh["inventory_count"]) == 4, "修改副本不应影响冻结源（应仍为 4）。")
	_check(NAME, not fresh.has("nested_mark"), "副本新增键不应进入冻结源。")


## G3 Ad-hoc：白名单外键拒绝、base 不变、id 标记 adhoc。
func _test_adhoc() -> void:
	const NAME: String = "G3_Adhoc临时数据"
	var base: Dictionary = _service.build_preset("typical")
	var merged: Dictionary = _service.build_adhoc(base, { inventory_count = 9 })
	_check(NAME, String(merged["id"]) == "adhoc", "Ad-hoc 结果应标记为 adhoc。")
	_check(NAME, int(merged["inventory_count"]) == 9, "覆盖库存数应为 9。")
	_check(NAME, int(base["inventory_count"]) == 4, "base 预设不得被 Ad-hoc 修改（§84）。")
	var rejected: Dictionary = _service.build_adhoc(base, { evil_key = 1 })
	_check(NAME, rejected.has("error") and not rejected.has("evil_key"), "白名单外键应拒绝。")
	_check(NAME, _service.build_adhoc({}, {}).has("error"), "base 缺失应报错而非崩溃。")


## G4 零落盘：全部构造/Ad-hoc 操作后 user:// 下无 Preview 产物文件。
func _test_no_disk_write() -> void:
	const NAME: String = "G4_零落盘"
	var before: Array = _list_user_files()
	for preset_id: String in _service.PRESET_IDS:
		_service.build_preset(preset_id)
	_service.build_adhoc(_service.build_preset("typical"), { counter_value = 3 })
	var after: Array = _list_user_files()
	_check(NAME, before.size() == after.size(), "Preview 操作不得产生磁盘文件（前 %d 后 %d）。" % [before.size(), after.size()])


## 枚举 user:// 根与一级子目录文件（单遍 DirAccess）。
func _list_user_files() -> Array:
	var found: Array = []
	var dir: DirAccess = DirAccess.open("user://")
	if dir == null:
		return found
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not name.begins_with("."):
			if dir.current_is_dir():
				found.append_array(DirAccess.get_files_at("user://".path_join(name)))
			else:
				found.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return found


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== UI Preview Data 测试摘要 ====")
	print("测试组数：4")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
