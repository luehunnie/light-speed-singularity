extends SceneTree

## S3-04 Viewport Preview 预设测试（GUI 冻结总结 v1.0 §85）。
## 覆盖：四预设冻结像素（实现期冻结值）、detached、Ad-hoc 非正式标记。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _ViewportPresets: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_viewport_presets.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service


func _initialize() -> void:
	_service = _ViewportPresets.new()
	_test_frozen_pixels()
	_test_detached()
	_test_adhoc()
	_report()
	quit(0 if _failures.is_empty() else 1)


## G1 冻结像素：四预设 ID/顺序/精确尺寸/全部 formal。
func _test_frozen_pixels() -> void:
	const NAME: String = "G1_冻结像素"
	_check(NAME, _service.PRESET_IDS == ["standard_16_9", "small_16_9", "large_16_9", "minimum_supported"], "四预设 ID 应与 §85 冻结一致。")
	var expected: Dictionary = {
		"standard_16_9": Vector2i(1920, 1080),
		"small_16_9": Vector2i(1280, 720),
		"large_16_9": Vector2i(2560, 1440),
		"minimum_supported": Vector2i(1024, 576),
	}
	for preset_id: String in expected.keys():
		var preset: Dictionary = _service.build_preset(preset_id)
		_check(NAME, preset["size"] == expected[preset_id], "预设 %s 像素应为 %s，实际 %s。" % [preset_id, expected[preset_id], preset.get("size", null)])
		_check(NAME, bool(preset["formal"]), "预设 %s 应为正式标准。" % preset_id)
	_check(NAME, _service.build_preset("nonexistent").is_empty(), "未知预设应返回空字典。")
	var all: Array = _service.get_presets()
	_check(NAME, all.size() == 4, "get_presets 应返回 4 项，实际 %d。" % all.size())


## G2 detached：修改副本不影响冻结源。
func _test_detached() -> void:
	const NAME: String = "G2_detached语义"
	var preset: Dictionary = _service.build_preset("standard_16_9")
	preset["size"] = Vector2i(1, 1)
	preset["formal"] = false
	var fresh: Dictionary = _service.build_preset("standard_16_9")
	_check(NAME, fresh["size"] == Vector2i(1920, 1080), "修改副本不应影响冻结源。")
	_check(NAME, bool(fresh["formal"]), "formal 标记不应被副本污染。")


## G3 Ad-hoc 视口：formal=false 且不影响正式预设（§85 不自动成为正式标准）。
func _test_adhoc() -> void:
	const NAME: String = "G3_Adhoc视口"
	var adhoc: Dictionary = _service.build_adhoc_viewport(Vector2i(800, 600))
	_check(NAME, String(adhoc["id"]) == "adhoc_viewport" and adhoc["size"] == Vector2i(800, 600), "Ad-hoc 视口应携带临时尺寸。")
	_check(NAME, not bool(adhoc["formal"]), "Ad-hoc 视口必须标记非正式。")
	_check(NAME, _service.get_presets().all(func(p): return bool(p["formal"])), "正式预设列表不得混入 Ad-hoc。")


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Viewport Preview 预设测试摘要 ====")
	print("测试组数：3")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
