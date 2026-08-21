extends Node2D

## AF-05 控制域测试固定目标：闸门（Guide §28 “真正有状态的正式内容”正例语义）。
## 状态 {open, mode} 以 Dictionary 为载体，向 Dispatcher 证明 Typed Runtime State 对基础设施不透明；
## 契约面四件（动作声明 / 读状态 / 纯计算 / 提交）+ Source 面 + Reset 面与生产机关同一形状。
## 供 control_dispatcher_test / control_connection_preflight_test 复用；非 *_test.gd，不在测试发现范围。


const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)
const _ControlActionResult: GDScript = preload(
	"res://gameplay/control/control_action_result.gd"
)
const _ControlOutputEvent: GDScript = preload(
	"res://gameplay/control/control_output_event.gd"
)


## 配置（Configuration 对应的初始运行状态；Reset 回到这里，§33）。
var initial_open: bool = false
var initial_mode: int = 0

## 当前 Typed Runtime State（对 Dispatcher 不透明）。
var current_open: bool = false
var current_mode: int = 0

## 诊断计数：apply_control_action 被调用次数（去重 / no-op 断言用）。
var apply_calls: int = 0

## 本实例登记的稳定 ID（级联事件的 source_stable_id；由测试在注册后回填）。
var stable_id: String = ""

## 级联事件携带的运行代（测试注入；Dispatcher 透传不生成）。
var generation: int = 0

## 命中该动作时返回非正式结果（回滚 / 原子性测试用；空串 = 不失效）。
var fail_on_action: StringName = &""

## 是否在 Source 声明面声明 gate_relayed（关闭以测试未声明级联事件被丢弃，§31）。
var declare_relay_event: bool = true

## 构造：给定初始配置并回到初始运行状态。
func _init(initial_open_value: bool = false, initial_mode_value: int = 0) -> void:
	initial_open = initial_open_value
	initial_mode = initial_mode_value
	reset_control_runtime_state()


## 动作声明面：open / close 显式互斥；set_mode 带一个 INT 参数；relay 无参只发事件。
func get_control_action_definitions() -> Array:
	var open_definition = _ControlActionDefinition.new()
	open_definition.action_id = &"open"
	open_definition.display_name = "打开闸门"
	open_definition.add_mutually_exclusive([&"close"])
	var close_definition = _ControlActionDefinition.new()
	close_definition.action_id = &"close"
	close_definition.display_name = "关闭闸门"
	close_definition.add_mutually_exclusive([&"open"])
	var mode_definition = _ControlActionDefinition.new()
	mode_definition.action_id = &"set_mode"
	mode_definition.display_name = "设置模式"
	mode_definition.param_schema = [{"param_id": &"mode", "value_type": _ControlActionDefinition.VALUE_TYPE_INT}]
	var relay_definition = _ControlActionDefinition.new()
	relay_definition.action_id = &"relay"
	relay_definition.display_name = "转发事件"
	return [open_definition, close_definition, mode_definition, relay_definition]


## Source 声明面：本类型可发出的稳定事件。
func get_output_event_ids() -> Array[StringName]:
	if declare_relay_event:
		return [&"gate_relayed"]
	return []


## 当前 Typed Runtime State 快照（detached Dictionary）。
func get_control_runtime_state() -> Variant:
	return {"open": current_open, "mode": current_mode}


## 纯状态转换（§28：Current + Action → Candidate + Events；不自行提交、不递归派发）。
## 返回值保持 Variant：失效注入路径需能返回非正式结果供 Dispatcher 安全降级。
func apply_control_action(action_id: StringName, params: Dictionary) -> Variant:
	apply_calls += 1
	var candidate: Dictionary = {"open": current_open, "mode": current_mode}
	if action_id == fail_on_action:
		return RefCounted.new()
	if action_id == &"open":
		candidate["open"] = true
		return _ControlActionResult.create(candidate, [])
	if action_id == &"close":
		candidate["open"] = false
		return _ControlActionResult.create(candidate, [])
	if action_id == &"set_mode":
		candidate["mode"] = params[&"mode"]
		return _ControlActionResult.create(candidate, [])
	if action_id == &"relay":
		var event = _ControlOutputEvent.create(stable_id, &"gate_relayed", generation)
		return _ControlActionResult.create(candidate, [event])
	push_error("GateFixture：收到未声明动作 %s。" % [action_id])
	return null


## 唯一提交写点（成功返回 true）。
func commit_control_runtime_state(state: Variant) -> bool:
	if not (state is Dictionary):
		return false
	current_open = state["open"]
	current_mode = state["mode"]
	return true


## Reset Hook（§33）：只清理本实例临时状态，回到当前 Configuration 对应的初始运行状态。
func reset_control_runtime_state() -> void:
	current_open = initial_open
	current_mode = initial_mode
