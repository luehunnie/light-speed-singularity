class_name ControlActionResult
extends RefCounted

## ControlActionResult（Guide §31）：Target 一次动作计算的正式返回——
##   Candidate Runtime State（§28 状态转换产物，对本基础设施不透明）+ 0..N Typed Output Events。
## Target 不得在执行 Action 时递归调用 Dispatcher（§31 冻结）：级联事件只经本结果返回，
##   由 Dispatcher 在批次提交后汇成 Batch N+1。
## Definition 未声明的 Event ID 不允许由实现偷偷返回（§31）：声明校验由 Dispatcher
##   对照目标 get_output_event_ids() 声明面执行，未声明事件被丢弃并记录 Diagnostic。


const _ControlOutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)


## 候选运行状态（§28：Current + Action → Candidate；对基础设施为不透明 Variant，null=无状态/不变）。
var candidate_state: Variant = null

## 本次动作产生的级联 Typed Output Events（0..N；运行期不可变意图，构造后只读）。
var output_events: Array = []


## 构造正式结果；非法事件清单（null / 非正式类型成员）返回 null 并 push_error。
static func create(candidate_state: Variant, output_events: Array = []) -> ControlActionResult:
	var result: ControlActionResult = ControlActionResult.new()
	result.candidate_state = candidate_state
	result.output_events = output_events
	var problems: PackedStringArray = result.validate()
	if not problems.is_empty():
		push_error("ControlActionResult：非法构造——%s。" % ["；".join(problems)])
		return null
	return result


## 校验：output_events 成员均为正式 ControlOutputEvent。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	for event: Variant in output_events:
		if event == null or not (event is _ControlOutputEvent):
			problems.append("output_events 含非正式 ControlOutputEvent 成员。")
			break
	return problems
