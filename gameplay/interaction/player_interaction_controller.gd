extends RefCounted

## 玩家输入分类器：把 InputEvent 分类为业务命令，保存鼠标事件坐标。
## 不查询 RunState、不命中 UI、不转网格坐标、不开始/结束拖拽、不调用库存/PlacementController、不发射光线、不切换光形态、不执行 R、不修改 Node、不调用 set_input_as_handled、不访问场景树。
## 按键释放、无关键与无关鼠标键统一返回 NONE；FIRE/RESET/SWITCH_FORM 经 fire_light/reset_level/switch_light_form 输入动作识别，与核心原有一致。


## 业务命令；kind 区分指针与按键类别，pointer_position 保存鼠标事件坐标（非鼠标事件为 ZERO）。
class Command:
	enum Kind {
		NONE,
		POINTER_MOTION,
		PRIMARY_PRESS,
		PRIMARY_RELEASE,
		SECONDARY_PRESS,
		FIRE,
		RESET,
		SWITCH_FORM,
	}
	var kind: Kind = Kind.NONE
	var pointer_position: Vector2 = Vector2.ZERO


const _RESET_ACTION: StringName = &"reset_level"
const _FIRE_ACTION: StringName = &"fire_light"
## M4-E4：Q 切换主发射器光形态（权限门在 LevelRuntimeController，本分类器只识别按键）。
const _SWITCH_FORM_ACTION: StringName = &"switch_light_form"


## 把单个 InputEvent 分类为一条业务命令；按键释放、无关键与无关鼠标键返回 NONE。
func translate(event: InputEvent) -> Command:
	var command: Command = Command.new()
	if event.is_action_pressed(_RESET_ACTION):
		command.kind = Command.Kind.RESET
		return command
	if event.is_action_pressed(_FIRE_ACTION):
		command.kind = Command.Kind.FIRE
		return command
	if event.is_action_pressed(_SWITCH_FORM_ACTION):
		command.kind = Command.Kind.SWITCH_FORM
		return command
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		command.pointer_position = mb.position
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				command.kind = Command.Kind.PRIMARY_PRESS if mb.pressed else Command.Kind.PRIMARY_RELEASE
			MOUSE_BUTTON_RIGHT:
				command.kind = Command.Kind.SECONDARY_PRESS if mb.pressed else Command.Kind.NONE
			_:
				command.kind = Command.Kind.NONE
		return command
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		command.pointer_position = mm.position
		command.kind = Command.Kind.POINTER_MOTION
		return command
	return command
