extends GridPlacedObject

## S3-06 控制域运行期测试固定目标（格上正式对象形态）。
## 与 gate_target_fixture.gd（Node2D 形态）同一契约面语义，但 extends GridPlacedObject：
## ControlRuntimeTargetIndex 按 AF-08 正式对象口径（PlaceableToken / GridPlacedObject 派生 +
## 非空 stable_instance_id）发现实例，本 fixture 使端到端链（meta → 连接 → Dispatcher → 目标动作面）
## 可在真实发现口径下被测试。契约面四件 + 可选 Reset 面；无 Source 面（本 fixture 不发级联事件）。
## 供 control_runtime_wiring_test / core_loop_control_wiring_test 复用；非 *_test.gd，不在测试发现范围。


const _ControlActionDefinition: GDScript = preload(
	"res://gameplay/control/control_action_definition.gd"
)
const _ControlActionResult: GDScript = preload(
	"res://gameplay/control/control_action_result.gd"
)

## 唯一声明动作 toggle_enabled（无参数；与 particle_accelerator 声明示例同 id）。
const ACTION_TOGGLE_ENABLED: StringName = &"toggle_enabled"


## 当前 Typed Runtime State（对 Dispatcher 不透明；本 fixture 为单布尔）。
var enabled: bool = false

## apply_control_action 被调用次数（no-op / 原子性断言用）。
var apply_calls: int = 0

## reset_control_runtime_state 被调用次数（§33 Reset 集成断言用）。
var reset_calls: int = 0


## 动作声明面：仅 toggle_enabled，无互斥、无参数。
func get_control_action_definitions() -> Array:
	var definition = _ControlActionDefinition.new()
	definition.action_id = ACTION_TOGGLE_ENABLED
	definition.display_name = "切换启用状态"
	return [definition]


## 读状态面：返回当前 Typed Runtime State。
func get_control_runtime_state() -> Variant:
	return enabled


## 纯计算面：toggle_enabled → 候选态取反；未知动作返回非法结果（Dispatcher 记 no-op）。
func apply_control_action(action_id: StringName, _params: Dictionary) -> Variant:
	apply_calls += 1
	if action_id != ACTION_TOGGLE_ENABLED:
		return null
	return _ControlActionResult.create(not enabled, [])


## 唯一提交写点：写入候选态。
func commit_control_runtime_state(state: Variant) -> bool:
	if not (state is bool):
		return false
	enabled = state
	return true


## 可选 Reset 面（§33）：回到初始运行状态 false。
func reset_control_runtime_state() -> void:
	reset_calls += 1
	enabled = false
