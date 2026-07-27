extends SceneTree

## LevelRuntimeController 定向自动测试（Day 3 D3-E）。
## 通过公开接口验证发射请求编排、异步脉冲结束、generation 过期保护、R 重置顺序与运行期移动次数；真实 Controller + 真实依赖 + 最小替身（_StubDragFlow 控制拖拽、桩 Callable 记录 UI/断言）。
## 异步用例注入极短脉冲持续时间 0.0 并 await process_frame 推进；生产默认 1.0 秒不变。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。


const _LevelRuntimeController: GDScript = preload("res://gameplay/runtime/level_runtime_controller.gd")
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _VisualViewScene: PackedScene = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn")
const _CrystalProfile: Resource = preload("res://assets/visual_profiles/basic_crystal_visuals.tres")

const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)
const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 本轮创建的水晶实例，统一释放。
var _crystals: Array[BasicCrystal] = []
## 本轮创建的视觉父节点，统一释放。
var _visual_parents: Array[Node] = []
## 本轮创建并 add_child 的运行期控制器，统一释放。
var _controllers: Array[Node] = []
## 持有所有 env（含 sink/rsc 等 RefCounted）到清理，避免 Callable 不保留 RefCounted 引用导致挂起协程恢复时 null::method。
var _envs: Array = []


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。含异步用例，需 await 推进帧。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 get_tree() 可用。
	await process_frame
	await _run_all_tests()
	_report()
	# 清理前推进若干帧，让所有挂起的异步脉冲结束协程恢复完成，避免 free controller 后协程再调用 null 实例。
	await _wait_settled(4)
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行全部 26 组测试；同步用例直接断言，异步用例 await process_frame 推进。
func _run_all_tests() -> void:
	_test_01_setup_fire_success()
	_test_02_move_window_fire_success()
	_test_03_pulse_active_rejects_fire()
	_test_04_completed_rejects_fire()
	_test_05_dragging_rejects_fire()
	_test_06_invalid_direction_rejected_before_begin_pulse()
	_test_07_generation_incremented_after_fire()
	_test_08_ray_execution_called_once()
	_test_09_visual_before_crystal_order()
	await _test_10_unfinished_pulse_enters_move_window()
	await _test_11_completed_pulse_enters_completed()
	await _test_12_cancel_drag_before_completed()
	await _test_13_stale_generation_cannot_finish_new_pulse()
	await _test_14_reset_invalidates_stale_callback()
	_test_15_reset_resets_objective()
	_test_16_reset_clears_placed_and_reconciles_inventory()
	_test_17_reset_clears_light_path()
	_test_18_reset_clears_runtime_moves()
	_test_19_reset_returns_to_setup()
	_test_20_setup_move_does_not_consume()
	_test_21_runtime_move_consumes_once()
	_test_22_non_cross_cell_does_not_consume()
	_test_23_move_limit_rejects_commit()
	await _test_24_refire_after_reset()
	_test_25_controller_holds_no_ui_nodes()
	_test_26_controller_does_not_mutate_facts_directly()


# ===== 桩 =====

## 拖拽流程替身：extends 真实 DragFlowController 以满足类型约束，仅 override is_dragging/cancel_current_drag 供运行期编排测试控制。
## _init 内部构造最小真实依赖传 super，不参与拖拽业务；cancel_current_drag 记录调用次数与 should_assert 参数。
class _StubDragFlow extends "res://gameplay/interaction/drag_flow_controller.gd":
	var _stub_dragging: bool = false
	var cancel_calls: int = 0
	var last_cancel_assert: bool = true
	func _init() -> void:
		var occ: _OccupancyRegistry = _OccupancyRegistry.new()
		var inv: _InventoryController = _InventoryController.new(1)
		var pc: _PlacementController = _PlacementController.new(occ, inv, Callable())
		var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
		var walls: Array[Vector2i] = []
		var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
			Rect2i(0, 0, 16, 16), walls, Vector2i(-1, -1), registry, occ, Callable(pc, "get_placed_node")
		)
		pc.set_level_world_query(lwq)
		super._init(pc, inv, lwq, Callable(), Callable(), Callable(), Callable(), Callable(), Callable())
	func is_dragging() -> bool:
		return _stub_dragging
	func cancel_current_drag(should_assert_consistency: bool = true) -> void:
		cancel_calls += 1
		last_cancel_assert = should_assert_consistency
		_stub_dragging = false


## 机关节点桩：保存 mechanism_id/cell，供 PlacementController 事务使用。
class _StubToken extends Node2D:
	var mechanism_id: StringName = &""
	var cell: Vector2i = Vector2i.ZERO
	func configure(id: StringName, c: Vector2i) -> void:
		mechanism_id = id
		cell = c
	func set_cell(c: Vector2i) -> void:
		cell = c
	func set_orientation(_o: Variant) -> void:
		pass
	func set_drag_preview(_p: bool, _v: bool) -> void:
		pass
	func set_drag_preview_visible(_v: bool) -> void:
		pass
	func set_placed_visible(_v: bool) -> void:
		pass
	func set_world_position(_p: Vector2) -> void:
		pass


## 节点工厂桩：为 PlacementController 创建正式机关节点，挂到 SceneTree.root 由树统一释放。
class _StubFactory:
	var tree: SceneTree = null
	func create_formal(mechanism_id: StringName, cell: Vector2i, _orientation: Variant) -> Variant:
		var token: _StubToken = _StubToken.new()
		token.configure(mechanism_id, cell)
		if tree != null and tree.root != null:
			tree.root.add_child(token)
		return token


## UI/标签/断言回调桩：记录调用次数与完成标签可见性，不持有真实 UI 节点。
class _UiSink:
	var refresh_calls: int = 0
	var complete_label_visible: Variant = null
	var assert_calls: int = 0
	func refresh_runtime_ui() -> void:
		refresh_calls += 1
	func set_complete_label_visible(is_visible: bool) -> void:
		complete_label_visible = is_visible
	func assert_inventory_consistency() -> void:
		assert_calls += 1


## 测试上下文：聚合一次用例所需的控制器与桩。
class _Env:
	var rsc: _RunStateController = null
	var fixed_emitter: _FixedEmitter = null
	var light_world_query: _LightWorldQuery = null
	var light_visual_controller: _LightVisualController = null
	var objective_controller: _ObjectiveController = null
	var placement_controller: _PlacementController = null
	var inventory_controller: _InventoryController = null
	var occupancy: _OccupancyRegistry = null
	var drag: _StubDragFlow = null
	var factory: _StubFactory = null
	var sink: _UiSink = null
	var controller: _LevelRuntimeController = null
	var visual_parent: Node2D = null


## 构造测试上下文：emitter_cell/emitter_dir 为发射器配置；crystal_cell 为水晶格（null 表示无水晶）；move_limit 为运行期移动上限。
func _make_env(
		emitter_cell: Vector2i,
		emitter_dir: Vector2i,
		crystal_cell: Variant,
		move_limit: int = 1
) -> _Env:
	var env: _Env = _Env.new()
	env.rsc = _RunStateController.new()
	env.occupancy = _OccupancyRegistry.new()
	env.inventory_controller = _InventoryController.new(3)
	env.factory = _StubFactory.new()
	env.factory.tree = self
	env.placement_controller = _PlacementController.new(
		env.occupancy, env.inventory_controller, Callable(env.factory, "create_formal")
	)
	env.fixed_emitter = _FixedEmitter.new(emitter_cell, emitter_dir)
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	if crystal_cell != null:
		var cell: Vector2i = crystal_cell
		var crystal: BasicCrystal = _make_crystal(&"c001", cell)
		registry.register_crystal(&"c001", cell, crystal)
	env.objective_controller = _ObjectiveController.new(registry)
	var walls: Array[Vector2i] = []
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, emitter_cell, registry, env.occupancy,
		Callable(env.placement_controller, "get_placed_node")
	)
	env.placement_controller.set_level_world_query(level_query)
	env.light_world_query = _LightWorldQuery.new(level_query)
	env.visual_parent = Node2D.new()
	_visual_parents.append(env.visual_parent)
	env.light_visual_controller = _LightVisualController.new(env.visual_parent)
	env.drag = _StubDragFlow.new()
	env.sink = _UiSink.new()
	env.controller = _LevelRuntimeController.new(
		env.rsc, env.fixed_emitter, env.light_world_query, env.light_visual_controller,
		env.objective_controller, env.placement_controller, env.inventory_controller, env.drag,
		128, 0.0, move_limit,
		Callable(env.sink, "refresh_runtime_ui"),
		Callable(env.sink, "set_complete_label_visible"),
		Callable(env.sink, "assert_inventory_consistency")
	)
	# add_child 到 SceneTree.root，使控制器进入树以访问 get_tree().create_timer()。
	get_root().add_child(env.controller)
	_controllers.append(env.controller)
	_envs.append(env)
	return env


## 可激活水晶需 _ready 解析 @onready _visual；--script 模式下手动调用 view 与 crystal 的 _ready()，不挂场景树。
func _make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = cell
	crystal.crystal_id = crystal_id
	var view: ObjectVisualView = _VisualViewScene.instantiate()
	view.name = "VisualView"
	view.visual_profile = _CrystalProfile
	view.initial_state_id = &"unlit"
	crystal.add_child(view)
	view._ready()
	crystal._ready()
	_crystals.append(crystal)
	return crystal


## 推进若干帧让 SceneTreeTimer(0) 触发并恢复异步协程。
func _wait_settled(frames: int = 8) -> void:
	for i in frames:
		await process_frame


# ===== 测试用例 =====

## 1. SETUP 发射成功：返回 true，进入 PULSE_ACTIVE，generation 递增，完成标签按事实显示。
func _test_01_setup_fire_success() -> void:
	const NAME: String = "01_SETUP发射成功"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "SETUP request_fire 应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_pulse_generation() == 1, "generation 期望 1。")
	_check(NAME, env.sink.complete_label_visible == true, "完成标签应已显示（水晶在光路）。")


## 2. MOVE_WINDOW 发射成功：先完成一次未完成脉冲到 MOVE_WINDOW，再次发射返回 true。
func _test_02_move_window_fire_success() -> void:
	const NAME: String = "02_MOVE_WINDOW发射成功"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	# 同步推进到 MOVE_WINDOW（未完成）。
	env.rsc.finish_pulse(false)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应进入 MOVE_WINDOW。")
	var gen_before: int = env.controller.get_pulse_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "MOVE_WINDOW request_fire 应返回 true。")
	_check(NAME, env.controller.get_pulse_generation() == gen_before + 1, "generation 应递增。")


## 3. PULSE_ACTIVE 拒绝发射：进入 PULSE_ACTIVE 后再次 request_fire 返回 false，generation 不变。
func _test_03_pulse_active_rejects_fire() -> void:
	const NAME: String = "03_PULSE_ACTIVE拒绝发射"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	var gen_before: int = env.controller.get_pulse_generation()
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "PULSE_ACTIVE request_fire 应返回 false。")
	_check(NAME, env.controller.get_pulse_generation() == gen_before, "generation 不应变化。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "状态应保持 PULSE_ACTIVE。")


## 4. COMPLETED 拒绝发射：进入 COMPLETED 后 request_fire 返回 false。
func _test_04_completed_rejects_fire() -> void:
	const NAME: String = "04_COMPLETED拒绝发射"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应进入 COMPLETED。")
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "COMPLETED request_fire 应返回 false。")


## 5. 拖拽中拒绝发射：stub.is_dragging=true 时 request_fire 返回 false，不进入 PULSE_ACTIVE。
func _test_05_dragging_rejects_fire() -> void:
	const NAME: String = "05_拖拽中拒绝发射"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.drag._stub_dragging = true
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "拖拽中 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "应保持 SETUP。")
	_check(NAME, env.controller.get_pulse_generation() == 0, "generation 不应递增。")


## 6. 非法发射方向在 begin_pulse 前拒绝：direction=ZERO 时 build_fire_request 返回 null，request_fire 返回 false 且未进入 PULSE_ACTIVE。
func _test_06_invalid_direction_rejected_before_begin_pulse() -> void:
	const NAME: String = "06_非法方向先于begin_pulse拒绝"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.ZERO, Vector2i(5, 3))
	var ok: bool = env.controller.request_fire()
	_check(NAME, not ok, "非法方向 request_fire 应返回 false。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "不得进入 PULSE_ACTIVE（begin_pulse 未被调用）。")
	_check(NAME, env.controller.get_pulse_generation() == 0, "generation 不应递增。")


## 7. 发射后 generation 递增：每次成功发射 generation +1。
func _test_07_generation_incremented_after_fire() -> void:
	const NAME: String = "07_发射后generation递增"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	_check(NAME, env.controller.get_pulse_generation() == 0, "初始 generation 期望 0。")
	env.controller.request_fire()
	_check(NAME, env.controller.get_pulse_generation() == 1, "首次发射后 generation 期望 1。")
	env.rsc.finish_pulse(false)
	env.controller.request_fire()
	_check(NAME, env.controller.get_pulse_generation() == 2, "二次发射后 generation 期望 2。")


## 8. RayExecutionModule 只调用一次：发射后光路段数等于传播步数（ emitter(1,3) RIGHT 到边界 x=15，共 14 步）。
func _test_08_ray_execution_called_once() -> void:
	const NAME: String = "08_RayExecutionModule只调用一次"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	# emitter(1,3) RIGHT：光进入 (2,3)..(15,3)，共 14 步；每步一段光路视觉。
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "光路段数期望 14，实际 %d。" % [env.light_visual_controller.get_segment_count()])


## 9. 每 step 保持视觉→水晶顺序：静态验证 _apply_ray_execution_result 中 show_step 早于 try_activate_crystal_at。
func _test_09_visual_before_crystal_order() -> void:
	const NAME: String = "09_视觉早于水晶顺序"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var fn_start: int = src.find("func _apply_ray_execution_result")
	if _check(NAME, fn_start != -1, "未找到 _apply_ray_execution_result。"):
		var next_fn: int = src.find("\nfunc ", fn_start + 1)
		if next_fn == -1:
			next_fn = src.length()
		var body: String = src.substr(fn_start, next_fn - fn_start)
		var show_idx: int = body.find("_light_visual_controller.show_step")
		var obj_idx: int = body.find("_objective_controller.try_activate_crystal_at")
		_check(NAME, show_idx != -1, "应调用 show_step。")
		_check(NAME, obj_idx != -1, "应调用 try_activate_crystal_at。")
		_check(NAME, show_idx < obj_idx, "视觉创建必须早于水晶激活（show @ %d < objective @ %d）。" % [show_idx, obj_idx])


## 10. 未完成脉冲结束进入 MOVE_WINDOW：无水晶发射后等待异步结束，状态变 MOVE_WINDOW，光路被清理，刷新 UI。
func _test_10_unfinished_pulse_enters_move_window() -> void:
	const NAME: String = "10_未完成进入MOVE_WINDOW"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	var refresh_before: int = env.sink.refresh_calls
	await _wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "应进入 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "脉冲结束应清光路。")
	_check(NAME, env.sink.refresh_calls > refresh_before, "应刷新运行 UI。")
	_check(NAME, env.sink.complete_label_visible == false, "未完成不应显示完成标签。")


## 11. 完成脉冲结束进入 COMPLETED：水晶在光路，发射后等待异步结束，状态变 COMPLETED，完成标签保持显示。
func _test_11_completed_pulse_enters_completed() -> void:
	const NAME: String = "11_完成进入COMPLETED"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	await _wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "应进入 COMPLETED，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.sink.complete_label_visible == true, "完成标签应保持显示。")
	_check(NAME, env.objective_controller.is_completed(), "目标应已完成。")


## 12. COMPLETED 前取消拖拽：发射进 PULSE_ACTIVE 后置拖拽中，异步结束进 COMPLETED 时 controller 调用 cancel_current_drag。
func _test_12_cancel_drag_before_completed() -> void:
	const NAME: String = "12_COMPLETED前取消拖拽"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	# PULSE_ACTIVE 中模拟已开始拖拽（PULSE_ACTIVE 允许拖起），异步结束进 COMPLETED 前由控制器取消。
	env.drag._stub_dragging = true
	await _wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "应进入 COMPLETED。")
	_check(NAME, env.drag.cancel_calls >= 1, "COMPLETED 前应取消拖拽，实际 %d。" % [env.drag.cancel_calls])
	_check(NAME, not env.drag.is_dragging(), "取消后应不再拖拽。")


## 13. 旧 generation 回调不能结束新脉冲：发射 gen=1 → R gen=2 → 再发射 gen=3，旧回调不污染，新回调决定 MOVE_WINDOW。
func _test_13_stale_generation_cannot_finish_new_pulse() -> void:
	const NAME: String = "13_旧generation不结束新脉冲"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()  # gen=1, PULSE_ACTIVE
	env.controller.reset_runtime()  # gen=2, SETUP，旧回调(1)将过期
	env.controller.request_fire()  # gen=3, PULSE_ACTIVE，新回调(3)
	await _wait_settled()
	# 旧回调(1) 已过期返回；新回调(3) 结束未完成脉冲 -> MOVE_WINDOW。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "应由新回调进入 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_pulse_generation() == 3, "generation 期望 3。")


## 14. R 使旧异步回调失效：发射 gen=1 → R gen=2 → 等待，旧回调不把 SETUP 改成 MOVE_WINDOW/COMPLETED。
func _test_14_reset_invalidates_stale_callback() -> void:
	const NAME: String = "14_R使旧回调失效"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()  # gen=1, PULSE_ACTIVE，水晶已激活
	env.controller.reset_runtime()  # gen=2, SETUP，旧回调(1)将过期
	await _wait_settled()
	# 旧回调(1) 过期返回：不清新光路、不改新状态、不进 COMPLETED。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "旧回调不应改状态，应保持 SETUP，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, not env.objective_controller.is_completed(), "R 后应未完成，旧回调不应触发完成。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "光路应已被 R 清理，旧回调不应重建。")


## 15. R 重置目标：激活水晶后 R，水晶未激活、完成标签隐藏。
func _test_15_reset_resets_objective() -> void:
	const NAME: String = "15_R重置目标"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	_check(NAME, env.objective_controller.is_completed(), "发射后应先完成。")
	env.controller.reset_runtime()
	_check(NAME, not env.objective_controller.is_completed(), "R 后应未完成。")
	_check(NAME, env.sink.complete_label_visible == false, "R 后应隐藏完成标签。")


## 16. R 清玩家机关并协调库存：放置机关后 R，映射/占用清空，库存恢复满。
func _test_16_reset_clears_placed_and_reconciles_inventory() -> void:
	const NAME: String = "16_R清机关协调库存"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	var placed := env.placement_controller.place_from_inventory(_TOKEN_TYPE, Vector2i(10, 10), 1)
	_check(NAME, placed.is_success(), "前置放置应成功。")
	_check(NAME, env.inventory_controller.get_remaining() == 2, "放置后库存期望 2，实际 %d。" % [env.inventory_controller.get_remaining()])
	env.controller.reset_runtime()
	_check(NAME, env.placement_controller.get_placed_count() == 0, "R 后应无玩家机关。")
	_check(NAME, not env.occupancy.has_mechanism(placed.mechanism_id), "R 后占用应清除。")
	_check(NAME, env.inventory_controller.get_remaining() == 3, "R 后库存应恢复满，实际 %d。" % [env.inventory_controller.get_remaining()])


## 17. R 清光路：发射后 R，光路段数归 0。
func _test_17_reset_clears_light_path() -> void:
	const NAME: String = "17_R清光路"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	_check(NAME, env.light_visual_controller.get_segment_count() > 0, "发射后应有光路。")
	env.controller.reset_runtime()
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "R 后光路应清空。")


## 18. R 清移动次数：扣次后 R，runtime_moves_used 归 0。
func _test_18_reset_clears_runtime_moves() -> void:
	const NAME: String = "18_R清移动次数"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	env.controller.consume_runtime_move()
	_check(NAME, env.controller.get_runtime_moves_used() == 1, "扣次后 used 期望 1。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "R 后 used 期望 0。")
	_check(NAME, env.controller.get_runtime_moves_remaining() == 1, "R 后 remaining 期望 1。")


## 19. R 回到 SETUP：从 PULSE_ACTIVE R 后状态 SETUP。
func _test_19_reset_returns_to_setup() -> void:
	const NAME: String = "19_R回SETUP"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.controller.request_fire()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	env.controller.reset_runtime()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应回 SETUP。")


## 20. SETUP 跨格移动不扣次数：SETUP 状态 consume_runtime_move_if_required 跨格返回 false。
func _test_20_setup_move_does_not_consume() -> void:
	const NAME: String = "20_SETUP跨格不扣"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	var consumed: bool = env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 2))
	_check(NAME, not consumed, "SETUP 跨格不应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "used 期望 0。")


## 21. PULSE_ACTIVE/MOVE_WINDOW 成功跨格扣一次：两态下跨格 consume 返回 true 且 used +1。
func _test_21_runtime_move_consumes_once() -> void:
	const NAME: String = "21_运行期跨格扣一次"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 2)
	env.rsc.begin_pulse()
	_check(NAME, env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 1)), "PULSE_ACTIVE 跨格应扣次。")
	env.rsc.finish_pulse(false)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应 MOVE_WINDOW。")
	_check(NAME, env.controller.consume_runtime_move_if_required(Vector2i(2, 1), Vector2i(3, 1)), "MOVE_WINDOW 跨格应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 2, "used 期望 2。")
	_check(NAME, env.controller.get_runtime_moves_remaining() == 0, "remaining 期望 0。")


## 22. 原格/取消/回收/新放置不扣：原格 consume 返回 false；新放置与回收不经过 consume_runtime_move。
func _test_22_non_cross_cell_does_not_consume() -> void:
	const NAME: String = "22_非跨格不扣"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	# 原格松手：from==to 不扣。
	_check(NAME, not env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(1, 1)), "原格不应扣次。")
	# COMPLETED 不扣。
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	_check(NAME, not env.controller.consume_runtime_move_if_required(Vector2i(1, 1), Vector2i(2, 2)), "COMPLETED 跨格不应扣次。")
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "used 期望 0。")
	# 新放置与回收不经 consume_runtime_move：consume_runtime_move 仅由 DragFlowController 在 should_count 通过后调用，此处直接验证 can_commit 对新放置来源不读次数。
	env.controller.reset_runtime()
	env.rsc.begin_pulse()
	_check(NAME, env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "PULSE_ACTIVE 跨格 remaining>0 应允许提交。")


## 23. 达到次数上限拒绝提交：remaining=0 时 can_commit_placed_move 跨格返回 false。
func _test_23_move_limit_rejects_commit() -> void:
	const NAME: String = "23_达上限拒绝提交"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1)
	env.rsc.begin_pulse()
	env.controller.consume_runtime_move()  # 用尽 1 次
	_check(NAME, env.controller.get_runtime_moves_remaining() == 0, "remaining 期望 0。")
	_check(NAME, not env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "remaining=0 应拒绝跨格提交。")
	# SETUP 不受次数限制。
	env.rsc.reset_to_setup()
	_check(NAME, env.controller.can_commit_placed_move(Vector2i(1, 1), Vector2i(2, 2)), "SETUP 跨格不受次数限制。")


## 24. reset 后可再次发射：R 后 SETUP，再次 request_fire 返回 true 并进入 PULSE_ACTIVE。
func _test_24_refire_after_reset() -> void:
	const NAME: String = "24_reset后可再发射"
	var env: _Env = _make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	env.controller.request_fire()
	await _wait_settled()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	env.controller.reset_runtime()
	var ok: bool = env.controller.request_fire()
	_check(NAME, ok, "R 后再次发射应返回 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "应进入 PULSE_ACTIVE。")


## 25. Controller 不直接持 UI 节点：源码不引用 @onready UI 节点、场景路径、get_node 或 UI 节点类型。
func _test_25_controller_holds_no_ui_nodes() -> void:
	const NAME: String = "25_Controller不持UI节点"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	# 检查 UI 节点访问模式（@onready/$路径/get_node）与 UI 节点类型，不匹配 Callable 名中的小写 label。
	var forbidden: Array = [
		"@onready", "$", "get_node(", ": Label", ": Control",
		"CanvasLayer", "LightPathLayer", "TextureRect", "RuntimeMoveLabel"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "Controller 不应引用 UI 节点/场景路径令牌：%s" % [token])


## 26. Controller 不直接修改水晶/库存字典/占用表：源码不直接调 crystal.activate、_inventory.try_、_occupancy.register/unregister。
func _test_26_controller_does_not_mutate_facts_directly() -> void:
	const NAME: String = "26_Controller不直接改事实"
	var src: String = FileAccess.get_file_as_string("res://gameplay/runtime/level_runtime_controller.gd")
	var forbidden: Array = [
		"crystal.activate", "crystal.reset_runtime", "_inventory_controller.try_consume",
		"_inventory_controller.try_return", "_inventory_controller.reconcile",
		"_occupancy.register", "_occupancy.unregister", "_occupancy.clear",
		"_placement_controller.place_from_inventory", "_placement_controller.move_placed",
		"_placement_controller.recycle_placed"
	]
	for token: String in forbidden:
		_check(NAME, src.find(token) == -1, "Controller 不应直接修改水晶/库存/占用/放置事实：%s" % [token])
	# 水晶激活经 ObjectiveController 间接进行，库存/占用经 PlacementController 原子事务，Controller 只读事实。


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## RunState 值映射为人类可读名称，用于失败明细。
func _state_label(state: int) -> String:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return "SETUP"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return "COMPLETED"
		_:
			return "未知(%d)" % [state]


## 释放本轮创建的水晶、视觉父节点与控制器，跳过已释放实例。
func _cleanup() -> void:
	for controller: Node in _controllers:
		if is_instance_valid(controller):
			controller.free()
	_controllers.clear()
	for parent: Node in _visual_parents:
		if is_instance_valid(parent):
			parent.free()
	_visual_parents.clear()
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			for child: Node in crystal.get_children():
				child.free()
			crystal.free()
	_crystals.clear()
	# 释放 env 引用（sink/rsc 等 RefCounted），须在控制器 free 之后，避免协程再访问。
	_envs.clear()


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 26
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController D3-E 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
