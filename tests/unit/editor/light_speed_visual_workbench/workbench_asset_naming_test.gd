extends SceneTree

## S3-03 Workbench 正式资源命名服务测试（GUI 冻结总结 v1.0 §37）。
## 覆盖：基本生成、段清洗与空维度、禁用命名 lint、必填维度缺失。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _NamingScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/visual_asset_naming.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	var naming = _NamingScript.new()
	_test_build_basic(naming)
	_test_sanitize_and_empty_dims(naming)
	_test_lint_forbidden(naming)
	_test_missing_required(naming)
	_report()
	quit(0 if _failures.is_empty() else 1)


## G1 基本生成：全维度小写蛇形拼接 + 扩展名归一化。
func _test_build_basic(naming) -> void:
	const NAME: String = "G1_基本生成"
	var got: String = naming.build_formal_name("Basic Crystal", "State", "Unlit", "", "World", "PNG")
	_check(NAME, got == "basic_crystal_state_unlit_world.png", "应生成规范名，实际：%s。" % got)


## G2 段清洗与空维度：非法字符折叠、空维度跳过、非 ASCII 身份折叠为空（拒绝）。
func _test_sanitize_and_empty_dims(naming) -> void:
	const NAME: String = "G2_段清洗与空维度"
	var got: String = naming.build_formal_name("Mirror", "State", "NE", "", "", ".png")
	_check(NAME, got == "mirror_state_ne.png", "空维度应跳过且扩展名去点，实际：%s。" % got)
	var folded: String = naming.build_formal_name("水晶", "State", "Unlit", "", "", "png")
	_check(NAME, folded == "", "非 ASCII 身份折叠为空应返回空串拒绝，实际：%s。" % folded)


## G3 禁用命名 lint：final/_v2/新最终版 应被拦截；干净名合法。
func _test_lint_forbidden(naming) -> void:
	const NAME: String = "G3_禁用命名lint"
	_check(NAME, naming.lint_formal_name("crystal_state_final.png").size() == 1, "final 段应被 §37 拦截。")
	_check(NAME, naming.lint_formal_name("mirror_old.png").size() == 1, "old 段应被 §37 拦截。")
	_check(NAME, naming.lint_formal_name("beam_v3.png").size() == 1, "v3 段应被 §37 拦截。")
	_check(NAME, naming.lint_formal_name("镜面_新最终版.png").size() == 1, "新最终版子串应被 §37 拦截。")
	_check(NAME, naming.lint_formal_name("crystal_state_unlit.png").is_empty(), "干净名应合法。")
	_check(NAME, naming.lint_formal_name("").size() == 1, "空名应报问题。")


## G4 必填维度缺失：identity / slot / 扩展名缺失均返回空串。
func _test_missing_required(naming) -> void:
	const NAME: String = "G4_必填缺失"
	_check(NAME, naming.build_formal_name("", "state", "unlit", "", "", "png") == "", "缺 identity 应返回空。")
	_check(NAME, naming.build_formal_name("crystal", "", "unlit", "", "", "png") == "", "缺 slot 应返回空。")
	_check(NAME, naming.build_formal_name("crystal", "state", "unlit", "", "", "") == "", "缺扩展名应返回空。")


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench 命名服务测试摘要 ====")
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
