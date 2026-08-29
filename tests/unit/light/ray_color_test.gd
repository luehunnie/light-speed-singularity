extends SceneTree

## RayColor 定向测试（改动 2.3 / API 契约 §38.3 光线颜色枚举）。
## 覆盖：ColorValue 枚举数值冻结（NONE=-1/WHITE=0/RED=1/GREEN=2/BLUE=3）、
##   is_valid 真实四色判定（WHITE/RED/GREEN/BLUE true；NONE 哨兵与越界值 false）。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_enum_values()
	_test_02_is_valid()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 枚举数值冻结：逐一断言 ColorValue 各成员数值与契约冻结值一致。
func _test_01_enum_values() -> void:
	const G: String = "01_枚举数值"
	_check(G, _RayColor.ColorValue.NONE == -1, "NONE 应等于 -1。")
	_check(G, _RayColor.ColorValue.WHITE == 0, "WHITE 应等于 0。")
	_check(G, _RayColor.ColorValue.RED == 1, "RED 应等于 1。")
	_check(G, _RayColor.ColorValue.GREEN == 2, "GREEN 应等于 2。")
	_check(G, _RayColor.ColorValue.BLUE == 3, "BLUE 应等于 3。")


## 2. is_valid 合法性：真实四色 true；NONE 哨兵与越界值 false。
func _test_02_is_valid() -> void:
	const G: String = "02_合法性"
	_check(G, _RayColor.is_valid(_RayColor.ColorValue.WHITE), "WHITE 应合法。")
	_check(G, _RayColor.is_valid(_RayColor.ColorValue.RED), "RED 应合法。")
	_check(G, _RayColor.is_valid(_RayColor.ColorValue.GREEN), "GREEN 应合法。")
	_check(G, _RayColor.is_valid(_RayColor.ColorValue.BLUE), "BLUE 应合法。")
	_check(G, not _RayColor.is_valid(_RayColor.ColorValue.NONE), "NONE 哨兵应非法。")
	_check(G, not _RayColor.is_valid(-2), "-2 越界应非法。")
	_check(G, not _RayColor.is_valid(4), "4 越界应非法。")
	_check(G, not _RayColor.is_valid(99), "99 越界应非法。")


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 2
	var passed_checks: int = _checks - _failures.size()
	print("==== RayColor 测试摘要 ====")
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
