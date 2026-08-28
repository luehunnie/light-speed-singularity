class_name RunStartView
extends RefCounted

## 正式「开始运行」UI 视图（D7-3 Start Run 正式入口）。
##
## 职责：
##   拥有「开始运行」按钮、invalid 最小反馈标签与状态提示文本的运行入口侧 UI；只由真实 RunState 驱动
##   按钮显隐/可用与提示文本，绝不持有第二套“是否已开始运行”布尔真值。
##
## 在当前系统中的位置：
##   gameplay/ui 下的 RefCounted UI 组件，由 core_loop_prototype 在 _ready 构造并接线。
##   调度链：按钮 pressed → 经 start_run_callback 回调 core_loop 公开 start_run() →
##   LevelRuntimeController.request_begin_runtime → RuntimeValidationGate → LevelValidationResult。
##   本视图不直接访问 Gate / RunStateController 私有字段 / LevelRuntimeController，只回调 core_loop 公开入口。
##
## 主要依赖：
##   RuntimeInteractionTypes（RunState 枚举契约）、LevelValidationResult / LevelValidationIssue
##   （读取既有公开 is_valid / get_error_count / get_issues / Severity.ERROR，不建立第二套严重度规则）。
##   均以 preload 引用，避开全局 class_name 缓存坑。
##
## 明确不负责：
##   - 不持有“是否已开始”布尔；按钮显隐完全由 update_for_state 传入的真实 RunState 决定；
##   - 不复制 Validator 的 issue code→文本映射；invalid 文案只取错误数量与（若可得）首条 ERROR 可读文本；
##   - 不创建第二套 RunState 枚举或权限规则；
##   - 不发射、不切状态、不访问 LevelRuntimeController / Gate；
##   - 不接管库存/移动次数/完成标签等既有 UI（仍由 core_loop 既有刷新路径负责）。
##
## 关键状态生命周期：
##   setup 一次构造按钮与反馈标签（父节点为传入 CanvasLayer）；update_for_state 在每次 RunState 变化与
##   初始刷新时调用；_on_start_run_pressed 在按钮按下时回调 core_loop.start_run() 并按返回结果显隐 invalid 反馈。
##
## 关键边界：
##   - 仅 SETUP 显示并启用「开始运行」按钮；READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 均隐藏按钮；
##   - SETUP 提示不再宣称 Space 当前可发射；READY_TO_FIRE/MOVE_WINDOW 恢复 Space 发射提示；
##     PULSE_ACTIVE 不把 Space 表现为可重复发射；COMPLETED 不显示可发射；
##   - invalid 反馈在“停留在 SETUP 且未发生状态变化”时显示；valid（→READY_TO_FIRE）与 R 回 SETUP 触发的
##     update_for_state 会清除过期反馈；WARNING-only 不阻断（is_valid 仍 true → 进 READY → 清反馈）。

const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _LevelValidationResult: GDScript = preload(
	"res://gameplay/level/validation/level_validation_result.gd"
)
const _LevelValidationIssue: GDScript = preload(
	"res://gameplay/level/validation/level_validation_issue.gd"
)

# SETUP 提示：引导点击「开始运行」，不再误导为 Space 可发射。
const _HINT_SETUP: String = "点击「开始运行」进入运行状态    R：重置"
# READY/MOVE 提示：Space 可发射。
const _HINT_CAN_FIRE: String = "Space：发射    R：重置"
# PULSE 提示：运行中，不表现为 Space 可重复发射。
const _HINT_PULSE: String = "运行中…    R：重置"
# COMPLETED 提示：仅 R 可用。
const _HINT_COMPLETED: String = "R：重置"

## core_loop 公开 start_run() 的回调；返回 LevelValidationResult（SETUP 下）或 null（非 SETUP 被忽略）。
var _start_run_callback: Callable
## 「开始运行」按钮；SETUP 外隐藏，由 CanvasLayer 统一释放。
var _start_run_button: Button = null
## invalid 最小反馈标签；仅在 SETUP 下校验失败时可见。
var _feedback_label: Label = null
## 既有状态提示标签（CanvasLayer/HintLabel）；文本由 RunState 驱动。
var _hint_label: Label = null


## 构造视图；start_run_callback 为 core_loop 公开 start_run() 的 Callable，按钮按下时回调。
## [br]边界：本视图不在此构造按钮节点；节点由 setup 在场景接线阶段创建并挂到 CanvasLayer。
func _init(start_run_callback: Callable) -> void:
	_start_run_callback = start_run_callback


## 一次性创建按钮与反馈标签并挂到传入 CanvasLayer；hint_label 为既有 CanvasLayer/HintLabel，文本由本视图按状态驱动。
## [br]边界：只创建 Start Run 入口侧 UI 节点；不接管库存/移动/完成标签等既有 UI。
func setup(canvas_layer: CanvasLayer, hint_label: Label) -> void:
	_hint_label = hint_label
	# 「开始运行」按钮：置于提示行右侧；初始显隐/可用由 update_for_state 统一驱动。
	_start_run_button = Button.new()
	_start_run_button.name = "StartRunButton"
	_start_run_button.text = "开始运行"
	_start_run_button.offset_left = 440.0
	_start_run_button.offset_top = 16.0
	_start_run_button.offset_right = 600.0
	_start_run_button.offset_bottom = 52.0
	_start_run_button.pressed.connect(_on_start_run_pressed)
	canvas_layer.add_child(_start_run_button)
	# invalid 最小反馈标签：置于运行期移动行下方；默认隐藏，仅在 SETUP 校验失败时显示。
	_feedback_label = Label.new()
	_feedback_label.name = "StartRunFeedbackLabel"
	_feedback_label.offset_left = 16.0
	_feedback_label.offset_top = 120.0
	_feedback_label.offset_right = 700.0
	_feedback_label.offset_bottom = 152.0
	_feedback_label.visible = false
	canvas_layer.add_child(_feedback_label)


## 按真实 RunState 刷新按钮显隐/可用与提示文本；在初始刷新与每次 state_changed 时调用。
## [br]边界：SETUP 外一律隐藏按钮（不靠 disabled 维持第二套可见态）；SETUP/READY 进入时清除过期 invalid 反馈，
## [br]  invalid 反馈本身在“停留 SETUP 未切换”时由 _on_start_run_pressed 写入，不被本方法误清。
func update_for_state(state: _RuntimeInteractionTypes.RunState) -> void:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			_start_run_button.visible = true
			_start_run_button.disabled = false
			_set_hint(_HINT_SETUP)
			_clear_invalid_feedback()
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			_start_run_button.visible = false
			_set_hint(_HINT_CAN_FIRE)
			_clear_invalid_feedback()
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			_start_run_button.visible = false
			_set_hint(_HINT_PULSE)
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			_start_run_button.visible = false
			_set_hint(_HINT_CAN_FIRE)
		_RuntimeInteractionTypes.RunState.COMPLETED:
			_start_run_button.visible = false
			_set_hint(_HINT_COMPLETED)


## 查询「开始运行」按钮当前是否可见（SETUP 入口态）；供 UI 集成测试只读断言。
func is_start_run_button_visible() -> bool:
	return _start_run_button != null and _start_run_button.visible


## 查询「开始运行」按钮当前是否可用（非禁用）；供 UI 集成测试只读断言。
func is_start_run_button_disabled() -> bool:
	return _start_run_button == null or _start_run_button.disabled


## S3-07：取「开始运行」按钮节点本身（fire_reset_host 正式 Control 宿主）。
## [br]供 core_loop 运行期接线对其 set_meta 正式 ui_binding_slot_id（界面编辑辅助插件 Binding Slot 合同标记）；
## [br]只读返回既有节点，不创建第二宿主、不改按钮行为；setup 前返回 null 由调用方安全忽略。
func get_fire_reset_host_control() -> Control:
	return _start_run_button


## 查询当前状态提示文本；供 UI 集成测试断言 SETUP 不再误导为 Space 可发射。
func get_hint_text() -> String:
	if _hint_label == null:
		return ""
	return _hint_label.text


## 查询 invalid 最小反馈是否可见；供 UI 集成测试断言 invalid 出现 / valid 清除。
func is_invalid_feedback_visible() -> bool:
	return _feedback_label != null and _feedback_label.visible


## 查询 invalid 最小反馈文本；供 UI 集成测试断言只显示错误数量/首条 ERROR，不复制 Validator 规则。
func get_invalid_feedback_text() -> String:
	if _feedback_label == null:
		return ""
	return _feedback_label.text


## 模拟点击「开始运行」按钮：等价于按钮 pressed 信号，回调 core_loop.start_run() 并按返回结果显示/清除 invalid 反馈。
## [br]供 UI 集成测试在不依赖真实输入事件的前提下触发正式公开入口；与真实按钮 pressed 走同一条 _on_start_run_pressed。
func press_start_run() -> void:
	_on_start_run_pressed()


## 处理一次 start_run() 的结构化结果：非 null 且 invalid 时显示最小反馈；valid 的清除由后续 READY_TO_FIRE 状态刷新负责。
## [br]供 core_loop.start_run() 在拿到 LevelValidationResult 后调用，使「开始运行」按钮与任何程序化 start_run() 调用方共用同一条 invalid 反馈路径。
## [br]边界：null（非 SETUP 被忽略）不做任何事；valid 不在此显示反馈，其旧反馈由 update_for_state(READY_TO_FIRE) 清除；
## [br]  不复制 Validator 规则：错误数量与首条 ERROR 文本均取自 LevelValidationResult/Issue 既有公开 API。
func handle_start_run_result(result: Variant) -> void:
	if result == null:
		return
	var validation_result: _LevelValidationResult = result as _LevelValidationResult
	if validation_result == null:
		return
	if not validation_result.is_valid():
		_show_invalid_feedback(validation_result)


## 按钮按下回调：经 start_run_callback 调 core_loop 公开 start_run()；结果→反馈由 core_loop 经 handle_start_run_result 回写，
## 保证按钮 pressed 与程序化 start_run() 调用方共用同一条 invalid 反馈路径。
func _on_start_run_pressed() -> void:
	_start_run_callback.call()


## 显示 invalid 最小反馈：错误数量 +（若可得）首条 ERROR 可读文本；不映射 issue code，不建立第二套严重度。
func _show_invalid_feedback(result: _LevelValidationResult) -> void:
	var error_count: int = result.get_error_count()
	var first_message: String = ""
	# 仅取首条 ERROR 的既有可读文本（Result 已确定性排序，ERROR 居前），不复制 code→文本映射。
	for issue: _LevelValidationIssue in result.get_issues():
		if issue.get_severity() == _LevelValidationIssue.Severity.ERROR:
			first_message = issue.get_message()
			break
	if first_message.is_empty():
		_feedback_label.text = "无法开始运行：关卡校验未通过（%d 个错误）" % error_count
	else:
		_feedback_label.text = "无法开始运行：关卡校验未通过（%d 个错误）— %s" % [error_count, first_message]
	_feedback_label.visible = true


## 清除 invalid 反馈；在进入 SETUP（R 重置后）与 READY_TO_FIRE（Start Run 成功后）时调用，避免过期反馈残留。
func _clear_invalid_feedback() -> void:
	if _feedback_label == null:
		return
	_feedback_label.visible = false
	_feedback_label.text = ""


## 设置状态提示文本；hint_label 缺失时安全忽略（不阻断状态刷新）。
func _set_hint(text: String) -> void:
	if _hint_label == null:
		return
	_hint_label.text = text
