class_name FormSwitchToastView
extends RefCounted

## 形态切换提示 UI（M4-E4 用户冻结视觉：每次成功 Q 切换时屏幕上方居中提示 1 秒后消失）。
##
## 职责：
##   拥有形态提示 Label 与其 1 秒自动隐藏 Timer 的最小 toast 视图；只由调用方传入的
##   LevelRuntimeController.request_switch_light_form 返回值（成功的新形态）驱动显示，
##   被拒绝/无效的 Q 由调用方不调用本视图体现（本视图绝不被"假装成功"触发）。
##
## 在当前系统中的位置：
##   gameplay/ui 下的 RefCounted UI 组件，由 core_loop_prototype 在 _ready 构造并 setup 到 CanvasLayer。
##   调度链：Q 按下 → PlayerInteractionController(SWITCH_FORM) → core_loop._switch_light_form →
##   LevelRuntimeController.request_switch_light_form（allow_form_switch + 非 COMPLETED 门）→
##   返回 >=0 的新形态才 show_for_form；返回 -1（禁止/无效）不显示任何提示。
##
## 主要依赖：
##   LightEmissionTypes（LightForm 数值契约，preload 引用）。不依赖 RunState/LevelRuntimeController/
##   FixedEmitter/cooldown——本视图只做显示，不做任何权限判定。
##
## 明确不负责：
##   - 不判定 Q 是否被允许（权限在 LevelRuntimeController）；
##   - 不切换形态、不发射、不改 RunState、不触 cooldown；
##   - 不接管发射器本体视觉（EmitterVisual）与既有提示标签（HintLabel）。
##
## 关键边界：
##   - 文案冻结：切到 RAY 显示"射线模式"，切到 PARTICLE 显示"粒子模式"；
##   - 位置冻结：屏幕上方居中（水平锚点 0.5，顶部小偏移，不随窗口尺寸漂移）；
##   - 生命周期冻结：显示 1 秒后自动隐藏；1 秒内再次成功切换则重置计时并更新文案；
##   - 未知形态值防御：push_error 且不显示，不产生错误文案的假提示。

## 公共光形态契约唯一来源（preload 避开全局 class 缓存问题）。
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

## 提示显示时长（用户冻结：1 秒后消失）。
const TOAST_DURATION_SECONDS: float = 1.0

## 切到 RAY 的冻结文案。
const _TEXT_RAY: String = "射线模式"
## 切到 PARTICLE 的冻结文案。
const _TEXT_PARTICLE: String = "粒子模式"

## 提示 Label；默认隐藏，仅 show_for_form 成功路径可见。
var _toast_label: Label = null
## 1 秒自动隐藏 Timer（one_shot）；1 秒内再次 show 时重置计时。
var _toast_timer: Timer = null


## 一次性创建提示 Label 与自动隐藏 Timer 并挂到传入 CanvasLayer。
## [br]边界：只创建本 toast 侧 UI 节点；Label 初始隐藏；Timer 不 autostart（由 show_for_form 启动）。
func setup(canvas_layer: CanvasLayer) -> void:
	# 提示 Label：屏幕上方居中（水平锚点 0.5 + 左右对称偏移；顶部小偏移），文本居中对齐。
	_toast_label = Label.new()
	_toast_label.name = "FormSwitchToastLabel"
	_toast_label.anchor_left = 0.5
	_toast_label.anchor_right = 0.5
	_toast_label.anchor_top = 0.0
	_toast_label.anchor_bottom = 0.0
	_toast_label.offset_left = -120.0
	_toast_label.offset_right = 120.0
	_toast_label.offset_top = 12.0
	_toast_label.offset_bottom = 44.0
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	canvas_layer.add_child(_toast_label)
	# 自动隐藏 Timer：one_shot 1 秒；随 Label 同一 CanvasLayer 生命周期释放。
	_toast_timer = Timer.new()
	_toast_timer.name = "FormSwitchToastTimer"
	_toast_timer.one_shot = true
	_toast_timer.wait_time = TOAST_DURATION_SECONDS
	_toast_timer.timeout.connect(_on_toast_timeout)
	canvas_layer.add_child(_toast_timer)


## 显示一次形态提示：按新形态写冻结文案并显示，启动（或重置）1 秒自动隐藏计时。
## [br]输入：light_form 为 LevelRuntimeController.request_switch_light_form 成功返回的 LightForm 数值。
## [br]边界：未知形态值 push_error 且不显示（不产生假提示）；1 秒内连续成功切换重置计时并覆盖文案。
func show_for_form(light_form: int) -> void:
	if _toast_label == null or _toast_timer == null:
		return
	match light_form:
		_LightEmissionTypes.LightForm.RAY:
			_toast_label.text = _TEXT_RAY
		_LightEmissionTypes.LightForm.PARTICLE:
			_toast_label.text = _TEXT_PARTICLE
		_:
			push_error("FormSwitchToastView: 未知 light_form %d，不显示形态提示。" % light_form)
			return
	_toast_label.visible = true
	# 重置计时：stop 后 start 使"1 秒内再次切换"从新切换时刻重新计 1 秒。
	_toast_timer.stop()
	_toast_timer.start()


## 查询提示当前是否可见；供 UI 测试只读断言（拒绝路径不显示=本值 false）。
func is_toast_visible() -> bool:
	return _toast_label != null and _toast_label.visible


## 查询提示当前文案；供 UI 测试断言冻结文案（射线模式/粒子模式）。
func get_toast_text() -> String:
	if _toast_label == null:
		return ""
	return _toast_label.text


## 查询提示 Label（只读诊断；供 UI 测试断言上方居中锚点与可见性）。
func get_toast_label() -> Label:
	return _toast_label


## 查询自动隐藏 Timer（只读诊断；供 UI 测试断言 wait_time==1.0 / one_shot / 计时进行中）。
func get_toast_timer() -> Timer:
	return _toast_timer


## 1 秒计时到期回调：隐藏提示（不删除节点，下次成功切换复用）。
func _on_toast_timeout() -> void:
	if _toast_label != null:
		_toast_label.visible = false
