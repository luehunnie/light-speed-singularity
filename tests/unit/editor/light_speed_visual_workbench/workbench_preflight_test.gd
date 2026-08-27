extends SceneTree

## S3-03 Workbench Change Set Preflight 测试（GUI 冻结总结 v1.0 §57/§39）。
## 覆盖：全过、Required Slot 拦截（Profile 声明状态集为视觉合同）、Strict/Recommended
##       尺寸、§57 降级项、import_complete 拦截。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _ChangeSetScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/visual_change_set.gd"
)
const _PreflightScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/change_set_preflight.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
const _NORMAL_UNLIT: String = "res://assets/art/crystal/crystal_normal_unlit.png"
const _NORMAL_LIT: String = "res://assets/art/crystal/crystal_normal_lit.png"
const _BLUE: String = "res://assets/art/crystal/blue_crystal_unactivate.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	var preflight = _PreflightScript.new()
	_test_all_pass(preflight)
	_test_required_slot_blocks(preflight)
	_test_strict_size_blocks(preflight)
	_test_recommended_warns(preflight)
	_test_degraded_checks(preflight)
	_test_import_complete_blocks(preflight)
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造 unlit/lit 双状态 Profile；lit_texture 为空时 lit 状态缺纹理。
func _make_profile(lit_texture: Texture2D) -> ObjectVisualProfile:
	var profile: ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var unlit: VisualStateTexture = _VisualStateTexture.new()
	unlit.state_id = &"unlit"
	unlit.world_texture = load(_NORMAL_UNLIT)
	var lit: VisualStateTexture = _VisualStateTexture.new()
	lit.state_id = &"lit"
	lit.world_texture = lit_texture
	profile.states = [unlit, lit]
	return profile


## 取指定检查项结果。
func _check_result(result: Dictionary, check_id: String) -> Dictionary:
	for check: Dictionary in result["checks"]:
		if String(check["id"]) == check_id:
			return check
	return {}


## G1 全过：合法批次 Free 尺寸 → pass，7 项检查，前两项 pass。
func _test_all_pass(preflight) -> void:
	const NAME: String = "G1_全过"
	var cs = _ChangeSetScript.new(_make_profile(load(_NORMAL_LIT)), "user://wb_pf/fake.tres")
	cs.stage_state_texture(&"lit", load(_BLUE))
	var result: Dictionary = preflight.run(cs, { mode = "free" })
	_check(NAME, bool(result["passed"]), "合法批次应通过。")
	_check(NAME, result["checks"].size() == 7, "应呈现 §57 清单 7 项，实际 %d。" % result["checks"].size())
	_check(NAME, String(_check_result(result, "import_complete")["status"]) == "pass", "import_complete 应 pass。")
	_check(NAME, String(_check_result(result, "required_slot")["status"]) == "pass", "required_slot 应 pass。")


## G2 Required Slot 拦截：Profile 声明状态 lit 无纹理且未暂存 → fail（零扩张合同）。
func _test_required_slot_blocks(preflight) -> void:
	const NAME: String = "G2_RequiredSlot拦截"
	var cs = _ChangeSetScript.new(_make_profile(null), "user://wb_pf/fake.tres")
	cs.stage_state_texture(&"unlit", load(_BLUE))
	var result: Dictionary = preflight.run(cs, { mode = "free" })
	_check(NAME, not bool(result["passed"]), "声明状态缺纹理应整体不通过。")
	var required: Dictionary = _check_result(result, "required_slot")
	_check(NAME, String(required["status"]) == "fail", "required_slot 应 fail。")
	_check(NAME, String(required["detail"]).contains("lit"), "问题详情应指出 lit 状态。")


## G3 Strict 尺寸阻止：暂存纹理尺寸不符 Strict 合同 → fail。
func _test_strict_size_blocks(preflight) -> void:
	const NAME: String = "G3_Strict尺寸阻止"
	var cs = _ChangeSetScript.new(_make_profile(load(_NORMAL_LIT)), "user://wb_pf/fake.tres")
	cs.stage_state_texture(&"lit", load(_BLUE))
	var expected: Vector2i = Vector2i((load(_BLUE) as Texture2D).get_size()) + Vector2i(1, 1)
	var result: Dictionary = preflight.run(cs, { mode = "strict", expected_size = expected })
	_check(NAME, not bool(result["passed"]), "Strict 尺寸不符应整体不通过。")
	_check(NAME, String(_check_result(result, "size_contract")["status"]) == "fail", "size_contract 应 fail。")


## G4 Recommended 警告：尺寸不符但 mode=recommended → warning 且整体通过（§39 可继续）。
func _test_recommended_warns(preflight) -> void:
	const NAME: String = "G4_Recommended警告"
	var cs = _ChangeSetScript.new(_make_profile(load(_NORMAL_LIT)), "user://wb_pf/fake.tres")
	cs.stage_state_texture(&"lit", load(_BLUE))
	var expected: Vector2i = Vector2i((load(_BLUE) as Texture2D).get_size()) + Vector2i(1, 1)
	var result: Dictionary = preflight.run(cs, { mode = "recommended", expected_size = expected })
	_check(NAME, bool(result["passed"]), "Recommended 警告不应阻断。")
	_check(NAME, String(_check_result(result, "size_contract")["status"]) == "warning", "size_contract 应 warning。")


## G5 降级项：animation/successor/theme/fallback 四项 skipped 且带降级说明。
func _test_degraded_checks(preflight) -> void:
	const NAME: String = "G5_降级项"
	var cs = _ChangeSetScript.new(_make_profile(load(_NORMAL_LIT)), "user://wb_pf/fake.tres")
	var result: Dictionary = preflight.run(cs, {})
	for id: String in ["animation_assets", "successor_cycle", "theme_required_semantics", "legal_fallback"]:
		var check: Dictionary = _check_result(result, id)
		_check(NAME, String(check["status"]) == "skipped", "%s 应 skipped，实际 %s。" % [id, check["status"]])
		_check(NAME, String(check["detail"]).contains("降级"), "%s 详情应注明降级。" % id)


## G6 import_complete 拦截：未落盘正式路径的内存纹理 → fail。
func _test_import_complete_blocks(preflight) -> void:
	const NAME: String = "G6_import_complete拦截"
	var profile: ObjectVisualProfile = _make_profile(load(_NORMAL_LIT))
	var cs = _ChangeSetScript.new(profile, "user://wb_pf/fake.tres")
	var memory_texture: ImageTexture = ImageTexture.create_from_image(
		Image.create_empty(4, 4, false, Image.FORMAT_RGBA8))
	cs.stage_state_texture(&"lit", memory_texture)
	var result: Dictionary = preflight.run(cs, { mode = "free" })
	_check(NAME, not bool(result["passed"]), "未落盘纹理应整体不通过。")
	_check(NAME, String(_check_result(result, "import_complete")["status"]) == "fail", "import_complete 应 fail。")


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench Preflight 测试摘要 ====")
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
