extends SceneTree

## S3-03 Workbench Usage Impact 测试（GUI 冻结总结 v1.0 §56）。
## 覆盖：关卡文本扫描命中（含子目录）、Validator 问题来源、降级注记。
## 由 Godot --headless --script 运行；任一失败 quit(1)。载体使用 user:// 临时关卡文本。

const _ImpactServiceScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/visual_usage_impact_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)

const _LEVELS_ROOT: String = "user://wb_impact_test/levels/"
const _FAKE_PROFILE_PATH: String = "res://assets/visual_profiles/fake_profile.tres"
const _OLD_TEXTURE: String = "res://assets/art/crystal/blue_crystal_unactivate.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_prepare_levels()
	var service = _ImpactServiceScript.new()
	_test_scan_hits(service)
	_test_validator_issues(service)
	_test_degraded_notes(service)
	_report()
	quit(0 if _failures.is_empty() else 1)


## 建立三级 fixture：level_a 引用 Profile 路径、level_b 无引用、sub/level_c 引用旧纹理路径。
func _prepare_levels() -> void:
	DirAccess.make_dir_recursive_absolute(_LEVELS_ROOT + "sub")
	_write(_LEVELS_ROOT + "level_a.tscn",
		'[gd_scene format=3]\n[ext_resource type="Resource" path="%s" id="1"]\n' % _FAKE_PROFILE_PATH)
	_write(_LEVELS_ROOT + "level_b.tscn", '[gd_scene format=3]\n')
	_write(_LEVELS_ROOT + "sub/level_c.tscn",
		'[gd_scene format=3]\n[ext_resource type="Texture2D" path="%s" id="2"]\n' % _OLD_TEXTURE)


## 写入文本文件（覆盖式）。
func _write(path: String, text: String) -> void:
	var writer: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	writer.store_string(text)
	writer.close()


## 构造合法 Profile（unlit 状态绑定既有正式纹理）。
func _make_valid_profile() -> ObjectVisualProfile:
	var profile: ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var state: VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"unlit"
	state.world_texture = load("res://assets/art/crystal/crystal_normal_unlit.png")
	profile.states = [state]
	return profile


## G1 扫描命中：Profile 路径与旧纹理路径都能命中引用关卡，未引用关卡不进列表。
func _test_scan_hits(service) -> void:
	const NAME: String = "G1_扫描命中"
	var report: Dictionary = service.build_report(
		_FAKE_PROFILE_PATH, [_OLD_TEXTURE], _make_valid_profile(), _LEVELS_ROOT)
	_check(NAME, int(report["affected_level_count"]) == 2, "受影响关卡应为 2，实际 %d。" % int(report["affected_level_count"]))
	var levels: Array = report["levels_using"]
	_check(NAME, (_LEVELS_ROOT + "level_a.tscn") in levels, "引用 Profile 路径的 level_a 应命中。")
	_check(NAME, (_LEVELS_ROOT + "sub/level_c.tscn") in levels, "子目录引用旧纹理的 level_c 应命中。")
	_check(NAME, not ((_LEVELS_ROOT + "level_b.tscn") in levels), "无引用的 level_b 不应命中。")


## G2 Validator 问题：合法 Profile 零问题；损坏 Profile / 未加载 Profile 给出问题文案。
func _test_validator_issues(service) -> void:
	const NAME: String = "G2_Validator问题"
	var clean: Dictionary = service.build_report(_FAKE_PROFILE_PATH, [], _make_valid_profile(), _LEVELS_ROOT)
	_check(NAME, report_issues(clean).is_empty(), "合法 Profile 应零 Validator 问题。")
	var broken: ObjectVisualProfile = _ObjectVisualProfile.new()
	broken.default_state_id = &"unlit"
	var empty_state: VisualStateTexture = _VisualStateTexture.new()
	empty_state.state_id = &"unlit"
	broken.states = [empty_state]
	var broken_report: Dictionary = service.build_report(_FAKE_PROFILE_PATH, [], broken, _LEVELS_ROOT)
	_check(NAME, report_issues(broken_report).size() >= 1, "损坏 Profile 应报告 Validator 问题。")
	var unloaded: Dictionary = service.build_report(_FAKE_PROFILE_PATH, [], null, _LEVELS_ROOT)
	_check(NAME, report_issues(unloaded).size() == 1, "未加载 Profile 应给出单条问题文案。")


## G3 降级注记：variant_override / fallback 首批为 0 且声明降级（§56 主题语义）。
func _test_degraded_notes(service) -> void:
	const NAME: String = "G3_降级注记"
	var report: Dictionary = service.build_report(_FAKE_PROFILE_PATH, [], _make_valid_profile(), _LEVELS_ROOT)
	_check(NAME, int(report["variant_override_count"]) == 0 and int(report["fallback_count"]) == 0, "降级计数应为 0。")
	_check(NAME, (report["degraded_notes"] as PackedStringArray).size() >= 1, "应携带降级声明。")


## 报告字典中 validator_issues 的 PackedStringArray 视图。
func report_issues(report: Dictionary) -> PackedStringArray:
	return report["validator_issues"]


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench Usage Impact 测试摘要 ====")
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
