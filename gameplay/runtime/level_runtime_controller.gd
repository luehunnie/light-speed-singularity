class_name LevelRuntimeController
extends Node

## 正式关卡运行期编排控制器（Day 3 D3-E）。
## 完整拥有普通脉冲发射请求编排、异步脉冲结束、pulse_generation 过期保护、运行期移动次数与 R 完整重置顺序。
## 状态事实仍由 RunStateController 唯一持有；本控制器只请求状态转换，不保存第二份 current_state，不定义第二份 RunState 枚举。
## 发射顺序、视觉→水晶顺序、非法方向先于 begin_pulse 拒绝、完成事实由 ObjectiveController 唯一提供等边界与旧 fire_light/reset_runtime 严格一致。
## 生命周期：extends Node，由核心 _ready 构造并 add_child，跟随关卡场景；异步 await 依赖 SceneTreeTimer，对象在树期间不被释放，无需核心继续保存异步编排。

const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _RuntimeStateRules: GDScript = preload("res://gameplay/interaction/runtime_state_rules.gd")
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _FireRequest: GDScript = preload("res://gameplay/light/fire_request.gd")
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")


var _run_state_controller: _RunStateController
var _fixed_emitter: _FixedEmitter
var _light_world_query: _LightWorldQuery
var _light_visual_controller: _LightVisualController
var _objective_controller: _ObjectiveController
var _placement_controller: _PlacementController
var _inventory_controller: _InventoryController
var _drag_flow_controller: _DragFlowController
var _max_propagation_steps: int
var _pulse_visual_duration_seconds: float
var _runtime_move_limit: int
# 高层 UI/一致性回调：刷新全部运行 UI、显隐完成标签、执行库存一致性断言；不传入 UI 节点，不拆成十几个细碎 Callable。
var _refresh_runtime_ui: Callable
var _set_complete_label_visible: Callable
var _assert_inventory_consistency: Callable

## 当前脉冲版本号；每次开始脉冲或 R 重置递增，用于让旧异步等待回调失效，避免误清理新脉冲。
var _pulse_generation: int = 0
## 运行期已使用移动次数（R 清零）；唯一事实来源，核心与 DragFlowController 不持有同步副本，规则全部委托 RuntimeMoveRules。
var _runtime_moves_used: int = 0


## 构造运行期编排控制器；依赖全部由核心注入，不在本类构造场景节点或第二套事实。drag_flow_controller 直接注入以安全取消拖拽。
func _init(
		run_state_controller: _RunStateController,
		fixed_emitter: _FixedEmitter,
		light_world_query: _LightWorldQuery,
		light_visual_controller: _LightVisualController,
		objective_controller: _ObjectiveController,
		placement_controller: _PlacementController,
		inventory_controller: _InventoryController,
		drag_flow_controller: _DragFlowController,
		max_propagation_steps: int,
		pulse_visual_duration_seconds: float,
		runtime_move_limit: int,
		refresh_runtime_ui: Callable,
		set_complete_label_visible: Callable,
		assert_inventory_consistency: Callable
) -> void:
	_run_state_controller = run_state_controller
	_fixed_emitter = fixed_emitter
	_light_world_query = light_world_query
	_light_visual_controller = light_visual_controller
	_objective_controller = objective_controller
	_placement_controller = placement_controller
	_inventory_controller = inventory_controller
	_drag_flow_controller = drag_flow_controller
	_max_propagation_steps = max_propagation_steps
	_pulse_visual_duration_seconds = pulse_visual_duration_seconds
	_runtime_move_limit = runtime_move_limit
	_refresh_runtime_ui = refresh_runtime_ui
	_set_complete_label_visible = set_complete_label_visible
	_assert_inventory_consistency = assert_inventory_consistency


## 请求发射一次普通脉冲；保持旧 fire_light 顺序：拖拽拒绝→状态校验→构建 FireRequest→非法方向先于 begin_pulse 拒绝→清旧光路→begin_pulse→递增 generation→执行→逐 step 视觉→水晶→完成标签→异步结束。
## [br]返回 true 表示已成功启动脉冲（已进入 PULSE_ACTIVE 并开始异步结束等待）；false 表示被拖拽、状态或方向拒绝。
## [br]不得让 RayExecutionModule 执行视觉、水晶或状态副作用；逐 step 副作用顺序由本控制器应用。
func request_fire() -> bool:
	# 1. 拖拽中拒绝：一次拖拽事务未完成时不得启动新脉冲。
	if _drag_flow_controller.is_dragging():
		if OS.is_debug_build():
			print_debug("LevelRuntimeController: 拖拽中拒绝发射。")
		return false
	# 2. 查询当前状态是否允许发射（SETUP/MOVE_WINDOW 可发射；PULSE_ACTIVE/COMPLETED 拒绝）。
	if not _run_state_controller.can_fire_light():
		if OS.is_debug_build():
			print_debug("LevelRuntimeController: 当前运行状态拒绝 Space 发射：%s。" % [_run_state_controller.get_current_state()])
		return false
	# 3. FixedEmitter 构建 FireRequest。
	# 4. 方向非法时 build_fire_request 返回 null，先于 _prepare_for_new_pulse 与 begin_pulse 拒绝（与旧 fire_light 时点一致）。
	var fire_request: _FireRequest = _fixed_emitter.build_fire_request(_max_propagation_steps)
	if fire_request == null:
		push_error("Invalid emitter direction: %s" % [_fixed_emitter.get_direction()])
		return false
	# 5. 清除上一轮普通光路视觉，不改水晶、机关、运行状态、完成状态或 pulse_generation。
	_light_visual_controller.clear_path()
	# 6. 请求 RunStateController.begin_pulse；失败时停止发射（Controller 已 push_error 拒绝原因）。
	if not _run_state_controller.begin_pulse():
		return false
	# 7. pulse_generation 递增，使此前挂起的旧异步回调全部失效。
	_pulse_generation += 1
	var current_generation: int = _pulse_generation
	# 8. 传播计算在 RayExecutionModule 内无副作用完成，本控制器只应用结果。
	var execution_result: _RayExecutionResult = _RayExecutionModule.execute(
		fire_request.get_start_cell(),
		fire_request.get_direction(),
		fire_request.get_max_steps(),
		_light_world_query
	)
	if execution_result.reached_step_limit:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")
	# 9. 逐格按结果顺序应用副作用：同一格先 show_step 再 try_activate_crystal_at。
	_apply_ray_execution_result(execution_result)
	# 10. 通关事实立即成立；CompleteLabel 立刻显示，运行状态保持 PULSE_ACTIVE 到脉冲视觉结束。
	_set_complete_label_visible.call(_objective_controller.is_completed())
	# 11. 启动异步脉冲结束等待。
	_finish_pulse_after_delay(current_generation)
	return true


## 逐格按 steps 顺序应用副作用：同一格先创建光路视觉再尝试激活水晶；不重新计算路径、不改占用/机关/RunState/库存。
func _apply_ray_execution_result(result: _RayExecutionResult) -> void:
	for step in result.steps:
		_light_visual_controller.show_step(step.cell, step.incoming_direction)
		if step.has_crystal:
			_objective_controller.try_activate_crystal_at(step.cell)


## 等待脉冲视觉持续时间后尝试结束；若 R 重置或新脉冲已递增 pulse_generation，本回调视为过期直接返回，不清理或改变新脉冲状态。
func _finish_pulse_after_delay(expected_generation: int) -> void:
	await get_tree().create_timer(_pulse_visual_duration_seconds).timeout
	# 过期回调保护：旧脉冲等待结束后不得清理 R 后新发射的脉冲或改变新脉冲状态。
	if expected_generation != _pulse_generation:
		return
	if not _run_state_controller.is_current_pulse_active():
		return
	_finish_current_pulse(expected_generation)


## 结束当前仍有效的脉冲：清光路视觉，按完成事实请求切换到 MOVE_WINDOW 或 COMPLETED；COMPLETED 进入冻结前先安全取消拖拽。
## [br]不改水晶、机关、库存或占用表；完成状态与 CompleteLabel 保持到 R。generation 不匹配或无活动脉冲时直接返回；finish_pulse 失败时安全退出。
func _finish_current_pulse(expected_generation: int) -> void:
	# 过期回调保护：结束清理前再次确认这是当前有效脉冲。
	if expected_generation != _pulse_generation:
		return
	if not _run_state_controller.is_current_pulse_active():
		return
	# 脉冲结束：普通光路视觉消失，普通独立水晶继续保持点亮。
	_light_visual_controller.clear_path()
	var level_completed: bool = _objective_controller.is_completed()
	var next_state: _RuntimeInteractionTypes.RunState = _RuntimeStateRules.get_post_pulse_state(level_completed)
	# COMPLETED 进入冻结前由本控制器取消当前拖拽，必须在请求状态转换前完成，避免冻结后鼠标松开仍提交移动/回收。
	if next_state == _RuntimeInteractionTypes.RunState.COMPLETED and _drag_flow_controller.is_dragging():
		_drag_flow_controller.cancel_current_drag()
	# 请求 RunStateController 切换状态；失败通过现有错误边界暴露并安全退出。
	if not _run_state_controller.finish_pulse(level_completed):
		push_error("LevelRuntimeController: RunStateController.finish_pulse 被拒绝，无法结束脉冲。")
		return
	# 完成结果保留：路径消失后，已经成立的关卡完成标签继续显示。
	if _run_state_controller.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED:
		_set_complete_label_visible.call(true)
	_refresh_runtime_ui.call()


## R 完整重置：递增 generation 使旧异步失效→安全取消拖拽→清光路→重置水晶→隐藏完成标签→PlacementController.clear_all_placed 逐项复用回收事务清理玩家机关→清零移动次数→回 SETUP→刷新 UI→一致性断言。
## [br]不删除发射器/墙体/水晶/静态内容；不调用 occupancy.clear()；clear_all_placed 逐项复用 recycle_placed 回收事务，每项通过 InventoryController 库存归还预留（reserve→commit）提交，部分失败项完整保留节点/映射/占用，不由本控制器建立第二套 reconcile 计算。
## [br]R 在 SETUP/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 均可执行；旧异步回调因 generation 不匹配不再清理或改变新状态。
func reset_runtime() -> void:
	# 1. 递增版本号使已挂起的旧等待回调全部失效，不能再清理或切换 R 后的新状态。
	_pulse_generation += 1
	# 2. 安全取消当前拖拽：should_assert_consistency=false，把断言延后到玩家机关统一清理之后。
	if _drag_flow_controller.is_dragging():
		_drag_flow_controller.cancel_current_drag(false)
	# 3. 清理普通光路视觉。
	_light_visual_controller.clear_path()
	# 4. 重置水晶点亮与完成事实。
	_objective_controller.reset_runtime()
	# 5. 隐藏完成标签。
	_set_complete_label_visible.call(false)
	# 6/7. 玩家机关清理由 PlacementController.clear_all_placed 逐项复用 recycle_placed 回收事务负责；每项通过 InventoryController 库存归还预留（reserve→commit）提交，部分失败项完整保留节点/映射/占用，不由本控制器建立第二套 reconcile 计算。
	var clear_result: _PlacementController.ClearPlacedResult = _placement_controller.clear_all_placed()
	if clear_result.unresolved_count > 0:
		push_error("LevelRuntimeController: R重置玩家机关清理未完全成功，残留 %d 个机关，库存按残留数对齐。" % [clear_result.unresolved_count])
	# 8. 运行期移动次数清零。
	_runtime_moves_used = 0
	# 9. 状态回 SETUP（幂等，已在 SETUP 时不发信号）。
	_run_state_controller.reset_to_setup()
	# 10. 刷新运行 UI（库存 + 移动次数 + 完成标签）。
	_refresh_runtime_ui.call()
	# 11. 库存、映射、占用一致性断言（仅 Debug 构建）。
	if OS.is_debug_build():
		_assert_inventory_consistency.call()


## 剩余运行期移动次数 max(limit - used, 0)；委托 RuntimeMoveRules，不在此递增，不复制规则。
func get_runtime_moves_remaining() -> int:
	return _RuntimeMoveRules.compute_runtime_moves_remaining(_runtime_move_limit, _runtime_moves_used)


## 已使用运行期移动次数（只读）。
func get_runtime_moves_used() -> int:
	return _runtime_moves_used


## 运行期移动次数上限（构造时由核心传入的配置值）。
func get_runtime_move_limit() -> int:
	return _runtime_move_limit


## 当前脉冲版本号（只读，供测试与诊断）。
func get_pulse_generation() -> int:
	return _pulse_generation


## 是否处于 PULSE_ACTIVE；转发 RunStateController.is_current_pulse_active，不保存第二份状态。
func is_pulse_active() -> bool:
	return _run_state_controller.is_current_pulse_active()


## 是否允许正式提交一次已放置机关跨格移动；委托 RuntimeMoveRules.can_commit_placed_move，传入当前状态与剩余次数，不复制规则。
func can_commit_placed_move(original_cell: Vector2i, target_cell: Vector2i) -> bool:
	return _RuntimeMoveRules.can_commit_placed_move(
		_run_state_controller.get_current_state(),
		get_runtime_moves_remaining(),
		original_cell,
		target_cell
	)


## 若本次跨格移动应计入运行期次数则扣除一次并返回 true；原格、SETUP、COMPLETED、取消、回收、新放置不扣。委托 RuntimeMoveRules 判定。
func consume_runtime_move_if_required(original_cell: Vector2i, target_cell: Vector2i) -> bool:
	if not _RuntimeMoveRules.should_count_runtime_move(
		_run_state_controller.get_current_state(), original_cell, target_cell
	):
		return false
	_runtime_moves_used += 1
	return true


## 无条件扣除一次运行期移动次数；供 DragFlowController 在已通过 should_count_runtime_move 校验后经核心 Callable 委托调用，避免重复判定。
func consume_runtime_move() -> void:
	_runtime_moves_used += 1
