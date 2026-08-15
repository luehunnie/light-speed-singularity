extends SceneTree

## FormSwitchToastView 定向自动测试（M4-E4 用户冻结视觉合同）。
## 覆盖：冻结文案（RAY→“射线模式”/PARTICLE→“粒子模式”）、上方居中锚点、1 秒生命周期
##   （Timer 配置 + 手动 timeout 证伪 + 真实 1 秒自动隐藏）、1 秒内重复切换重置计时、
##   未知形态不显示假提示、初始隐藏。
## 真实自动隐藏用例等待约 1.2 秒真实时间（SceneTreeTimer），仅此一组产生真实等待。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)。

const _FormSwitchToastView: GDScript = preload("res://gameplay/ui/form_switch_toast_view.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	var canvas: CanvasLayer = CanvasLayer.new()
	root.add_child(canvas)
	var view: _FormSwitchToastView = _FormSwitchToastView.new()
	view.setup(canvas)
	_test_01_initial_hidden(view)
	_test_02_ray_text_and_show(view)
	_test_03_particle_text_and_timer_reset(view)
	_test_04_top_center_anchors(view)
	_test_05_manual_timeout_hides(view)
	_test_06_unknown_form_no_fake_toast(view)
	await _test_07_real_one_second_auto_hide(view)
	canvas.free()
	await process_frame
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 初始隐藏：setup 后 Label 存在且不可见、文本为空。
func _test_01_initial_hidden(view: _FormSwitchToastView) -> void:
	const NAME: String = "01_初始隐藏"
	_check(NAME, not view.is_toast_visible(), "setup 后提示应隐藏。")
	_check(NAME, view.get_toast_text() == "", "初始文本应为空。")
	_check(NAME, view.get_toast_label() != null, "提示 Label 应已创建。")
	_check(NAME, view.get_toast_timer() != null, "自动隐藏 Timer 应已创建。")


## 2. RAY 文案与显示：show_for_form(RAY) → 可见 + “射线模式” + Timer 以 1 秒启动。
func _test_02_ray_text_and_show(view: _FormSwitchToastView) -> void:
	const NAME: String = "02_RAY文案与显示"
	view.show_for_form(_LightEmissionTypes.LightForm.RAY)
	_check(NAME, view.is_toast_visible(), "show(RAY) 后提示应可见。")
	_check(NAME, view.get_toast_text() == "射线模式", "RAY 文案应为「射线模式」，实际：%s。" % [view.get_toast_text()])
	var timer: Timer = view.get_toast_timer()
	_check(NAME, timer.wait_time == 1.0, "Timer 时长应为 1.0 秒（用户冻结），实际 %s。" % [timer.wait_time])
	_check(NAME, timer.one_shot, "Timer 应为 one_shot。")
	_check(NAME, timer.time_left > 0.0, "show 后 Timer 应在计时（time_left > 0）。")


## 3. PARTICLE 文案与计时重置：先等约 0.15 秒使计时推进（time_left 离开满值），1 秒内再 show(PARTICLE)
##    → 文案覆盖 + 计时重置（time_left 回到接近 1.0）。
func _test_03_particle_text_and_timer_reset(view: _FormSwitchToastView) -> void:
	const NAME: String = "03_PARTICLE文案与计时重置"
	var timer: Timer = view.get_toast_timer()
	await create_timer(0.15).timeout
	var left_before: float = timer.time_left
	_check(NAME, left_before < 0.9, "前置等待后计时应已推进（time_left < 0.9），实际 %s。" % [left_before])
	view.show_for_form(_LightEmissionTypes.LightForm.PARTICLE)
	_check(NAME, view.is_toast_visible(), "再次 show 后提示应保持可见。")
	_check(NAME, view.get_toast_text() == "粒子模式", "PARTICLE 文案应为「粒子模式」，实际：%s。" % [view.get_toast_text()])
	_check(NAME, timer.time_left > 0.9, "再次 show 应重置 1 秒计时（time_left 回到接近 1.0），实际 %s。" % [timer.time_left])


## 4. 上方居中锚点：水平锚点 0.5（左右对称偏移）、顶部锚点 0、文本居中。
func _test_04_top_center_anchors(view: _FormSwitchToastView) -> void:
	const NAME: String = "04_上方居中锚点"
	var label: Label = view.get_toast_label()
	_check(NAME, is_equal_approx(label.anchor_left, 0.5) and is_equal_approx(label.anchor_right, 0.5), "水平锚点应为 0.5（屏幕水平居中），实际 L=%s R=%s。" % [label.anchor_left, label.anchor_right])
	_check(NAME, is_equal_approx(label.anchor_top, 0.0), "顶部锚点应为 0（屏幕上方），实际 %s。" % [label.anchor_top])
	_check(NAME, label.offset_top > 0.0 and label.offset_top < 60.0, "顶部偏移应为小正值（上方非贴边），实际 %s。" % [label.offset_top])
	_check(NAME, absf(label.offset_left + label.offset_right) < 0.001, "左右偏移应对称（居中不漂移），实际 %s/%s。" % [label.offset_left, label.offset_right])
	_check(NAME, label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "文本应水平居中对齐。")


## 5. timeout 隐藏：手动 emit timeout（与 B4b-2 Tween finished 同模式）→ 提示隐藏且节点保留可复用。
func _test_05_manual_timeout_hides(view: _FormSwitchToastView) -> void:
	const NAME: String = "05_timeout隐藏"
	view.get_toast_timer().timeout.emit()
	_check(NAME, not view.is_toast_visible(), "1 秒计时到期后提示应隐藏。")
	_check(NAME, view.get_toast_label() != null, "隐藏后 Label 保留（下次成功切换复用）。")
	# 复用：隐藏后再次 show 仍可显示。
	view.show_for_form(_LightEmissionTypes.LightForm.RAY)
	_check(NAME, view.is_toast_visible() and view.get_toast_text() == "射线模式", "隐藏后再次 show 应可复用显示。")


## 6. 未知形态不显示假提示：隐藏状态下 show(99) → 仍隐藏、文本不变。
func _test_06_unknown_form_no_fake_toast(view: _FormSwitchToastView) -> void:
	const NAME: String = "06_未知形态不假提示"
	view.get_toast_timer().timeout.emit()
	_check(NAME, not view.is_toast_visible(), "前置应已隐藏。")
	view.show_for_form(99)
	_check(NAME, not view.is_toast_visible(), "未知形态不得显示假提示。")
	_check(NAME, view.get_toast_text() == "射线模式", "未知形态不覆盖文本（保持上次合法文案），实际：%s。" % [view.get_toast_text()])


## 7. 真实 1 秒自动隐藏：show 后不手动干预，等待约 1.2 秒真实时间 → Timer 自然到期隐藏。
func _test_07_real_one_second_auto_hide(view: _FormSwitchToastView) -> void:
	const NAME: String = "07_真实1秒自动隐藏"
	view.show_for_form(_LightEmissionTypes.LightForm.PARTICLE)
	_check(NAME, view.is_toast_visible(), "前置 show 后应可见。")
	await create_timer(1.2).timeout
	_check(NAME, not view.is_toast_visible(), "真实 1 秒到期后应自动隐藏（1 秒生命周期）。")


# ===== 断言与报告 =====

## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== FormSwitchToastView 测试摘要（M4-E4）====")
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
