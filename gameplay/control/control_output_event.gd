class_name ControlOutputEvent
extends RefCounted

## 运行期 Typed Output Event（Guide §26.3）：只表达“发生了什么”，无 gameplay payload。
## 最小运行时字段：source_stable_id + event_id + runtime_generation（§26.3 冻结）。
## 禁止携带任何玩法负载（速度值 / 方向 / 计数等），Action 参数由 Connection 作者期固定。
## 事件由 Runtime 从光交互 Result 的 OUTPUT_EVENT 效果或 ControlActionResult 级联收集，
##   本类只做携带与合法性校验，不解析、不分发。


## 事件来源实例的稳定 ID（非空）。
var source_stable_id: String = ""

## 稳定事件 ID（非空 StringName）。
var event_id: StringName = &""

## 运行代（>=0；由 Runtime 传入，本类不生成）。
var runtime_generation: int = -1


## 构造合法事件；任一字段非法返回 null 并 push_error（fail-fast，零副作用）。
static func create(
		source_stable_id: String,
		event_id: StringName,
		runtime_generation: int
) -> ControlOutputEvent:
	var event: ControlOutputEvent = ControlOutputEvent.new()
	event.source_stable_id = source_stable_id
	event.event_id = event_id
	event.runtime_generation = runtime_generation
	var problems: PackedStringArray = event.validate()
	if not problems.is_empty():
		push_error("ControlOutputEvent：非法构造——%s。" % ["；".join(problems)])
		return null
	return event


## 校验合法性：来源 / 事件 ID 非空、运行代 >= 0；返回问题清单（空 = 合法）。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if source_stable_id.is_empty():
		problems.append("source_stable_id 不能为空。")
	if event_id == &"":
		problems.append("event_id 不能为空。")
	if runtime_generation < 0:
		problems.append("runtime_generation 须 >= 0（实际 %d）。" % [runtime_generation])
	return problems
