extends RefCounted

## RunStateController 测试共享支持（D7-2 五态合同测试拆分）。
## 只提供 state_changed 信号记录器、Controller→记录器接线与 RunState 可读名称映射；
## 不含任何业务状态转换规则、不复制 RunStateController 内部实现、不读取其私有字段。
## 被 run_state_controller_lifecycle_test.gd 与 run_state_controller_guards_test.gd 复用，避免两份重复的记录器/名称样板。
## 不含 class_name、不依赖全局缓存、不创建场景、不注册 Autoload、不读写游戏节点或项目资源。

const _Types: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")


## 单次 state_changed 信号记录：previous/new 与回调内查询到的当前状态。
## 用于同时验证信号参数与字段更新时序（信号在状态字段更新后发出，回调内查询应已是新状态）。
class _Emission:
	extends RefCounted
	var previous_state: int
	var new_state: int
	var state_during_callback: int


## 信号记录器：只通过 state_changed 公开信号观察 Controller，不读取其私有字段。
## 在回调内查询 Controller 当前状态以验证“先更新字段、后发信号”的时序约定。
class _SignalRecorder:
	extends RefCounted
	var _controller: RefCounted
	var emissions: Array[_Emission] = []

	func _init(controller: RefCounted) -> void:
		_controller = controller

	## state_changed 信号回调：记录 previous/new，并在回调内查询当前状态以验证字段先于信号更新。
	func on_changed(previous_state: int, new_state: int) -> void:
		var emission: _Emission = _Emission.new()
		emission.previous_state = previous_state
		emission.new_state = new_state
		## 回调内立即查询当前状态；若字段先于信号更新，此处应已等于 new_state。
		emission.state_during_callback = _controller.get_current_state()
		emissions.append(emission)

	## 返回已记录的信号次数。
	func count() -> int:
		return emissions.size()

	## 清空记录，用于每组测试开始前重置计数，避免跨组污染。
	func clear() -> void:
		emissions.clear()


## 为已构造的 Controller 接线 state_changed 记录器并返回该记录器。
## 调用方须以局部/成员保留返回的记录器，避免 Callable 单引用下被提前回收（见 GDScript Callable 不保留 RefCounted 坑）。
static func wire(controller: RefCounted) -> _SignalRecorder:
	var recorder: _SignalRecorder = _SignalRecorder.new(controller)
	controller.state_changed.connect(Callable(recorder, "on_changed"))
	return recorder


## 把 RunState 值映射为稳定的人类可读名称，用于失败明细。
static func state_label(state: int) -> String:
	match state:
		_Types.RunState.SETUP:
			return "SETUP"
		_Types.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_Types.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_Types.RunState.COMPLETED:
			return "COMPLETED"
		_Types.RunState.READY_TO_FIRE:
			return "READY_TO_FIRE"
		_:
			return "未知(%d)" % [state]
