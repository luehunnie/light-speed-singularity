extends SceneTree

## PlayerInteractionController 定向自动测试：只通过 translate 公开接口验证 InputEvent 分类与鼠标坐标保存。
## 使用 InputEvent 子类直接构造事件，不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _PlayerInteractionController: GDScript = preload(
	"res://gameplay/interaction/player_interaction_controller.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_pointer_motion()
	_test_02_primary_press()
	_test_03_primary_release()
	_test_04_secondary_press()
	_test_05_fire_space()
	_test_06_reset_r()
	_test_07_key_release_no_command()
	_test_08_unrelated_key_none()
	_test_09_unrelated_mouse_button_none()
	_test_10_pointer_position_preserved()
	_test_11_translate_no_side_effects()
	_test_12_switch_form_q()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 事件构造 =====

## 构造鼠标移动事件。
func _make_motion(pos: Vector2) -> InputEventMouseMotion:
	var e: InputEventMouseMotion = InputEventMouseMotion.new()
	e.position = pos
	return e


## 构造鼠标按键事件。
func _make_button(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var e: InputEventMouseButton = InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	return e


## 构造键盘事件；fire_light/reset_level 输入动作以 physical_keycode 绑定，故用 physical_keycode 触发匹配。
func _make_key(physical_keycode: int, pressed: bool) -> InputEventKey:
	var e: InputEventKey = InputEventKey.new()
	e.physical_keycode = physical_keycode
	e.pressed = pressed
	e.echo = false
	return e


# ===== 测试用例 =====

## 1. 鼠标移动 → POINTER_MOTION。
func _test_01_pointer_motion() -> void:
	const NAME: String = "01_鼠标移动"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_motion(Vector2(10, 20)))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.POINTER_MOTION, "期望 POINTER_MOTION，实际 %s。" % [c.kind])


## 2. 左键按下 → PRIMARY_PRESS。
func _test_02_primary_press() -> void:
	const NAME: String = "02_左键按下"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_button(MOUSE_BUTTON_LEFT, true, Vector2(0, 0)))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.PRIMARY_PRESS, "期望 PRIMARY_PRESS，实际 %s。" % [c.kind])


## 3. 左键释放 → PRIMARY_RELEASE。
func _test_03_primary_release() -> void:
	const NAME: String = "03_左键释放"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_button(MOUSE_BUTTON_LEFT, false, Vector2(0, 0)))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.PRIMARY_RELEASE, "期望 PRIMARY_RELEASE，实际 %s。" % [c.kind])


## 4. 右键按下 → SECONDARY_PRESS。
func _test_04_secondary_press() -> void:
	const NAME: String = "04_右键按下"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_button(MOUSE_BUTTON_RIGHT, true, Vector2(0, 0)))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.SECONDARY_PRESS, "期望 SECONDARY_PRESS，实际 %s。" % [c.kind])


## 5. Space 按下 → FIRE。
func _test_05_fire_space() -> void:
	const NAME: String = "05_Space按下"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_SPACE, true))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.FIRE, "期望 FIRE，实际 %s。" % [c.kind])


## 6. R 按下 → RESET。
func _test_06_reset_r() -> void:
	const NAME: String = "06_R按下"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_R, true))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.RESET, "期望 RESET，实际 %s。" % [c.kind])


## 7. 按键释放不触发业务命令：Space 释放 → NONE。
func _test_07_key_release_no_command() -> void:
	const NAME: String = "07_按键释放无命令"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_SPACE, false))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.NONE, "Space 释放期望 NONE，实际 %s。" % [c.kind])
	var c2: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_R, false))
	_check(NAME, c2.kind == _PlayerInteractionController.Command.Kind.NONE, "R 释放期望 NONE，实际 %s。" % [c2.kind])


## 8. 无关键返回 NONE：未绑定为输入动作的按键按下 → NONE。
func _test_08_unrelated_key_none() -> void:
	const NAME: String = "08_无关键NONE"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_A, true))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.NONE, "未绑定按键期望 NONE，实际 %s。" % [c.kind])


## 9. 无关鼠标键返回 NONE：中键按下 → NONE。
func _test_09_unrelated_mouse_button_none() -> void:
	const NAME: String = "09_无关鼠标键NONE"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_button(MOUSE_BUTTON_MIDDLE, true, Vector2(0, 0)))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.NONE, "中键期望 NONE，实际 %s。" % [c.kind])


## 10. 命令正确保留鼠标位置：按键事件 pointer_position 应等于事件 position。
func _test_10_pointer_position_preserved() -> void:
	const NAME: String = "10_鼠标位置保留"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var motion_c: _PlayerInteractionController.Command = pic.translate(_make_motion(Vector2(12, 34)))
	_check(NAME, motion_c.pointer_position == Vector2(12, 34), "移动事件 pointer_position 应为 (12,34)，实际 %s。" % [motion_c.pointer_position])
	var press_c: _PlayerInteractionController.Command = pic.translate(_make_button(MOUSE_BUTTON_LEFT, true, Vector2(56, 78)))
	_check(NAME, press_c.pointer_position == Vector2(56, 78), "按键事件 pointer_position 应为 (56,78)，实际 %s。" % [press_c.pointer_position])
	# 非鼠标事件 pointer_position 保持 ZERO。
	var fire_c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_SPACE, true))
	_check(NAME, fire_c.pointer_position == Vector2.ZERO, "非鼠标事件 pointer_position 应为 ZERO，实际 %s。" % [fire_c.pointer_position])


## 11. translate 不产生业务副作用：连续调用结果独立、控制器无可观测状态变化。
func _test_11_translate_no_side_effects() -> void:
	const NAME: String = "11_无副作用"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var a: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_SPACE, true))
	var b: _PlayerInteractionController.Command = pic.translate(_make_motion(Vector2(1, 2)))
	# 两次调用各自独立分类，互不干扰。
	_check(NAME, a.kind == _PlayerInteractionController.Command.Kind.FIRE, "首次调用应为 FIRE。")
	_check(NAME, b.kind == _PlayerInteractionController.Command.Kind.POINTER_MOTION, "二次调用应为 POINTER_MOTION。")
	# 返回的 Command 是独立对象，互不共享可变状态。
	_check(NAME, a != b, "两次 translate 应返回独立 Command 对象。")
	_check(NAME, a.kind == _PlayerInteractionController.Command.Kind.FIRE, "二次调用后首次结果 kind 不应被改动。")
	# 再次 translate 同一 FIRE 事件仍得 FIRE，证明控制器自身无累积状态。
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_SPACE, true))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.FIRE, "重复 FIRE 事件仍应为 FIRE。")


## 12. Q 按下 → SWITCH_FORM（M4-E4 switch_light_form 输入动作，physical_keycode 绑定）；Q 释放 → NONE。
func _test_12_switch_form_q() -> void:
	const NAME: String = "12_Q按下SWITCH_FORM"
	var pic: _PlayerInteractionController = _PlayerInteractionController.new()
	var c: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_Q, true))
	_check(NAME, c.kind == _PlayerInteractionController.Command.Kind.SWITCH_FORM, "期望 SWITCH_FORM，实际 %s。" % [c.kind])
	var c2: _PlayerInteractionController.Command = pic.translate(_make_key(KEY_Q, false))
	_check(NAME, c2.kind == _PlayerInteractionController.Command.Kind.NONE, "Q 释放期望 NONE，实际 %s。" % [c2.kind])


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 12
	var passed_checks: int = _checks - _failures.size()
	print("==== PlayerInteractionController 测试摘要 ====")
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
