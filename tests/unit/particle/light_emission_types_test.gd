extends SceneTree

## LightEmissionTypes 定向测试（D7-4 B1）。
## 覆盖：LightForm 数值 RAY=0 / PARTICLE=1；八个合法方向均合法；Vector2i.ZERO 与超范围方向非法；
##   斜向 / 正交识别（is_diagonal_direction）。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)

const _GROUP_COUNT: int = 5

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 5 组后统一报告并退出。
func _initialize() -> void:
	_test_01_lightform_values()
	_test_02_eight_directions_valid()
	_test_03_invalid_directions()
	_test_04_diagonal_identification()
	_test_05_orthogonal_identification()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. LightForm 数值冻结：RAY=0 / PARTICLE=1。
func _test_01_lightform_values() -> void:
	const G: String = "01_LightForm数值"
	_check(G, _LightEmissionTypes.LightForm.RAY == 0, "RAY 期望 0，实际 %d。" % _LightEmissionTypes.LightForm.RAY)
	_check(G, _LightEmissionTypes.LightForm.PARTICLE == 1, "PARTICLE 期望 1，实际 %d。" % _LightEmissionTypes.LightForm.PARTICLE)


## 2. 八个合法方向均通过 is_valid_direction。
func _test_02_eight_directions_valid() -> void:
	const G: String = "02_八方向合法"
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	]
	for d: Vector2i in dirs:
		_check(G, _LightEmissionTypes.is_valid_direction(d),
			"合法方向 (%d, %d) 期望 true。" % [d.x, d.y])


## 3. ZERO 与超范围方向非法。
func _test_03_invalid_directions() -> void:
	const G: String = "03_非法方向"
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i.ZERO) == false, "ZERO 期望非法。")
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i(2, 0)) == false, "(2,0) 期望非法。")
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i(0, 2)) == false, "(0,2) 期望非法。")
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i(1, 2)) == false, "(1,2) 期望非法。")
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i(-2, -1)) == false, "(-2,-1) 期望非法。")
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i(1, -2)) == false, "(1,-2) 期望非法。")


## 4. 斜向识别：四个斜向为 true。
func _test_04_diagonal_identification() -> void:
	const G: String = "04_斜向识别"
	var diags: Array[Vector2i] = [
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	for d: Vector2i in diags:
		_check(G, _LightEmissionTypes.is_diagonal_direction(d) == true,
			"斜向 (%d, %d) 期望 true。" % [d.x, d.y])
	# 非法方向不应被误判为斜向。
	_check(G, _LightEmissionTypes.is_diagonal_direction(Vector2i(2, 2)) == false, "(2,2) 不应判为斜向。")
	_check(G, _LightEmissionTypes.is_diagonal_direction(Vector2i.ZERO) == false, "ZERO 不应判为斜向。")


## 5. 正交识别：四个正交方向与超范围方向均为 false。
func _test_05_orthogonal_identification() -> void:
	const G: String = "05_正交识别"
	var orthos: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
	]
	for d: Vector2i in orthos:
		_check(G, _LightEmissionTypes.is_diagonal_direction(d) == false,
			"正交 (%d, %d) 期望 is_diagonal=false。" % [d.x, d.y])
	_check(G, _LightEmissionTypes.is_diagonal_direction(Vector2i(2, 0)) == false, "(2,0) 不应判为斜向。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== LightEmissionTypes 测试摘要（D7-4 B1）====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
