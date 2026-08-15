class_name FireRequestPreflight
extends RefCounted

## 正式玩家发射零副作用预检（M4-E3）。
## 职责：实现 M4-E3 冻结 transaction 第一阶段“Preflight（零副作用）→ Immutable Fire Snapshot”——
##   依次校验 拖拽 → 发射状态权限 → 0.5 秒 cooldown ready → 光形态合法 → 八方向合法，
##   全部通过才读取 FixedEmitter 快照并返回 detached 发射快照 Dictionary；任一拒绝立即返回空 Dictionary。
##   本组件绝无 gameplay 副作用：不切 RunState、不 begin_pulse、不 allocate emission、不创建视觉/光粒、
##   不消费 / 不刷新 / 不延长 cooldown（on_fire_success 只在 dispatch 成功提交后由 LRC 调用）。
## 位置：gameplay/runtime 下；纯预检组件，由 LevelRuntimeController 唯一持有并在 request_fire 首步调用
##   （M4-E3 自然职责拆分：LRC 只保留事务编排——状态事务 / dispatch / 回滚 / cooldown 提交，预检与快照构造下沉本组件）。
## 依赖：DragFlowController（is_dragging）/ RunStateController（can_fire_light 发射权限；M4-E3 起 PULSE_ACTIVE 允许 repeated fire）/
##   FixedEmitter（快照 get_light_form/get_cell/get_direction）/ EmitterFireCooldown（is_ready 硬门）；
##   方向合法性与光形态唯一公共来源 LightEmissionTypes（is_valid_direction / LightForm），不复制第二套八方向或形态集合。
## 不负责（硬边界）：状态切换、begin_pulse、emission allocate/dispatch、回滚、cooldown 消费（on_fire_success）、
##   Ray/Particle 执行、视觉、水晶、结算、RunState 聚合。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。

const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _EmitterFireCooldown: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_fire_cooldown.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


var _drag_flow_controller: _DragFlowController
var _run_state_controller: _RunStateController
var _fixed_emitter: _FixedEmitter
var _emitter_fire_cooldown: _EmitterFireCooldown


## 构造预检组件；四个依赖全部由 LevelRuntimeController 注入（与 LRC 持有同一实例，不建第二套事实）。
func _init(
		drag_flow_controller: _DragFlowController,
		run_state_controller: _RunStateController,
		fixed_emitter: _FixedEmitter,
		emitter_fire_cooldown: _EmitterFireCooldown
) -> void:
	_drag_flow_controller = drag_flow_controller
	_run_state_controller = run_state_controller
	_fixed_emitter = fixed_emitter
	_emitter_fire_cooldown = emitter_fire_cooldown


## 执行零副作用发射预检并构造 immutable 发射快照（M4-E3 冻结顺序）。
## [br]顺序：拖拽 → 状态权限（SETUP/COMPLETED 拒绝；READY_TO_FIRE/MOVE_WINDOW 首发；PULSE_ACTIVE repeated fire）→
##   0.5 秒 cooldown ready → 光形态合法（RAY/PARTICLE）→ 八方向合法 → FixedEmitter 快照。
## [br]返回：全部通过返回 detached 快照 Dictionary { light_form: int, emitter_cell: Vector2i, direction: Vector2i }
##   （全为值类型副本，后续修改 FixedEmitter 不影响已返回快照）；任一拒绝返回空 Dictionary。
## [br]副作用：无——不切状态、不 begin_pulse、不 allocate emission、不触视觉/光粒、不消费 cooldown；
##   拒绝路径仅可能 print_debug（Debug 构建）或 push_error（非法配置），不改任何 gameplay 事实。
## [br]失败：不会失败；所有拒绝路径均返回空 Dictionary。
## [br]边界：非法方向 / 未知形态按“非法配置”在 begin_pulse 之前拒绝（与旧 request_fire 时点一致）；
##   cooldown 只回答 ready 维度，不代表发射权限；本方法不解释 form、不执行发射。
func evaluate() -> Dictionary:
	# 1. 拖拽中拒绝：一次拖拽事务未完成时不得启动新发射。
	if _drag_flow_controller.is_dragging():
		_debug("拖拽中拒绝发射。")
		return {}
	# 2. 发射状态权限：SETUP/COMPLETED 拒绝；READY_TO_FIRE/MOVE_WINDOW 首发；PULSE_ACTIVE repeated fire（M4-E3）。
	if not _run_state_controller.can_fire_light():
		_debug("当前运行状态拒绝 Space 发射：%s。" % [_run_state_controller.get_current_state()])
		return {}
	# 3. 0.5 秒发射 cooldown 硬门（M4-E3）：RAY/PARTICLE 共用；未到 ready 的重试零副作用（不消费、不刷新、不延长）。
	if not _emitter_fire_cooldown.is_ready():
		_debug("0.5 秒发射 cooldown 未到，拒绝再次发射。")
		return {}
	# 4. 光形态合法（非法配置先于快照与 begin_pulse 拒绝；RAY=0/PARTICLE=1 之外为未知 form）。
	var light_form: int = _fixed_emitter.get_light_form()
	if light_form != _LightEmissionTypes.LightForm.RAY and light_form != _LightEmissionTypes.LightForm.PARTICLE:
		push_error("FireRequestPreflight: 未知 light_form %d，零副作用拒绝发射。" % [light_form])
		return {}
	# 5. 读取 FixedEmitter Runtime 快照（light_form / emitter_cell / direction）并校验八方向合法性。
	var emitter_cell: Vector2i = _fixed_emitter.get_cell()
	var direction: Vector2i = _fixed_emitter.get_direction()
	if not _LightEmissionTypes.is_valid_direction(direction):
		push_error("Invalid emitter direction: %s" % [direction])
		return {}
	# 6. 全部通过：返回 detached immutable 快照（值类型副本；调用方据此进入 transaction，不再重读 _fixed_emitter）。
	return {
		"light_form": light_form,
		"emitter_cell": emitter_cell,
		"direction": direction,
	}


## Debug 构建下的拒绝诊断输出（与旧 request_fire 内联 print_debug 保持一致口径；正式构建零输出）。
func _debug(message: String) -> void:
	if OS.is_debug_build():
		print_debug("LevelRuntimeController: %s" % [message])
