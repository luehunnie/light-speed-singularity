extends RefCounted

## LevelRuntimeController 单元测试共享装配夹具（D4.6-T4）。
## 只负责构造测试对象、运行期桩与基础接线；不含断言、不含 LevelRuntimeController 业务规则、不隐藏 fire/reset/move/complete 等被测事务调用。
## 持有本轮创建的控制器/水晶/视觉父节点/env 到统一清理，避免异步脉冲结束协程在控制器 free 后恢复访问 null 实例（见 GDScript Callable 不保留 RefCounted 坑）。
## 与 tests/unit/placement/fixtures/placement_flow_fixture.gd 保持目录边界，互不引用。
## tree 由调用方在构造时传入（即运行测试的 SceneTree），用于把控制器与桩节点挂到 root 统一释放，并推进 process_frame。

const _LevelRuntimeController: GDScript = preload("res://gameplay/runtime/level_runtime_controller.gd")
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
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


## 光线世界查询计数替身：extends 真实 LightWorldQuery（字符串路径，与 _StubDragFlow 同模式）以满足控制器与 RayExecutionModule 的 _LightWorldQuery 类型约束。
## 用途：直接观测 RayExecutionModule.execute 是否被调用——该静态函数的唯一世界接触即传入的 world_query 参数，任意一次执行必至少调用 is_in_bounds 一次。
## 故 total_query_calls()==0 等价于“Ray 执行函数从未被调用”，比“光段数 0”更直接：光段 0 可能来自 Ray 执行后无步，而查询计数 0 才能证明 Ray 根本没启动。
## 每个 override 只计数后原样转发 super，返回值与裸 LightWorldQuery 完全一致，不引入第二套查询实现，对被测控制器透明。
class _SpyLightWorldQuery extends "res://gameplay/world/light_world_query.gd":
	var is_in_bounds_calls: int = 0
	var is_wall_cell_calls: int = 0
	var has_crystal_at_calls: int = 0
	var get_light_mechanism_at_calls: int = 0

	func _init(level_world_query: _LevelWorldQuery) -> void:
		super._init(level_world_query)

	## 边界查询：计数后转发，返回值不变。
	func is_in_bounds(cell: Vector2i) -> bool:
		is_in_bounds_calls += 1
		return super.is_in_bounds(cell)

	## 墙体查询：计数后转发，返回值不变。
	func is_wall_cell(cell: Vector2i) -> bool:
		is_wall_cell_calls += 1
		return super.is_wall_cell(cell)

	## 水晶查询：计数后转发，返回值不变。
	func has_crystal_at(cell: Vector2i) -> bool:
		has_crystal_at_calls += 1
		return super.has_crystal_at(cell)

	## 机关节点查询：计数后转发，返回值不变。
	func get_light_mechanism_at(cell: Vector2i) -> Variant:
		get_light_mechanism_at_calls += 1
		return super.get_light_mechanism_at(cell)

	## RayExecutionModule.execute 对本 world_query 的总查询次数；为 0 即证明 Ray 执行函数从未被调用。
	func total_query_calls() -> int:
		return is_in_bounds_calls + is_wall_cell_calls + has_crystal_at_calls + get_light_mechanism_at_calls


## 测试上下文：聚合一次用例所需的控制器与桩。
class _Env:
	var rsc: _RunStateController = null
	var fixed_emitter: _FixedEmitter = null
	var light_world_query: _LightWorldQuery = null
	## Ray 查询计数替身；仅当 make_env(observe_ray_queries=true) 时非 null，供测试直接断言 RayExecutionModule.execute 是否被调用。
	var light_world_query_spy: _SpyLightWorldQuery = null
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


# ===== 装配与清理 =====

var _tree: SceneTree = null
## 本轮创建的水晶实例，统一释放。
var _crystals: Array[BasicCrystal] = []
## 本轮创建的视觉父节点，统一释放。
var _visual_parents: Array[Node] = []
## 本轮创建并 add_child 的运行期控制器，统一释放。
var _controllers: Array[Node] = []
## 持有所有 env（含 sink/rsc 等 RefCounted）到清理，避免 Callable 不保留 RefCounted 引用导致挂起协程恢复时 null::method。
var _envs: Array = []


func _init(tree: SceneTree) -> void:
	_tree = tree


## 构造测试上下文：emitter_cell/emitter_dir 为发射器配置；crystal_cell 为水晶格（null 表示无水晶）；move_limit 为运行期移动上限。
## observe_ray_queries=true 时注入 _SpyLightWorldQuery 替身（对控制器透明），测试经 env.light_world_query_spy 直接观测 Ray 是否执行；默认 false 不影响既有用例。
func make_env(
		emitter_cell: Vector2i,
		emitter_dir: Vector2i,
		crystal_cell: Variant,
		move_limit: int = 1,
		observe_ray_queries: bool = false
) -> _Env:
	var env: _Env = _Env.new()
	env.rsc = _RunStateController.new()
	env.occupancy = _OccupancyRegistry.new()
	env.inventory_controller = _InventoryController.new(3)
	env.factory = _StubFactory.new()
	env.factory.tree = _tree
	env.placement_controller = _PlacementController.new(
		env.occupancy, env.inventory_controller, Callable(env.factory, "create_formal")
	)
	env.fixed_emitter = _FixedEmitter.new(emitter_cell, emitter_dir)
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	if crystal_cell != null:
		var cell: Vector2i = crystal_cell
		var crystal: BasicCrystal = make_crystal(&"c001", cell)
		registry.register_crystal(&"c001", cell, crystal)
	env.objective_controller = _ObjectiveController.new(registry)
	var walls: Array[Vector2i] = []
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, emitter_cell, registry, env.occupancy,
		Callable(env.placement_controller, "get_placed_node")
	)
	env.placement_controller.set_level_world_query(level_query)
	if observe_ray_queries:
		# 注入计数替身：extends LightWorldQuery 对控制器与 RayExecutionModule 透明，测试经 env.light_world_query_spy 直接观测 Ray 是否执行。
		var ray_spy: _SpyLightWorldQuery = _SpyLightWorldQuery.new(level_query)
		env.light_world_query = ray_spy
		env.light_world_query_spy = ray_spy
	else:
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
	_tree.get_root().add_child(env.controller)
	_controllers.append(env.controller)
	_envs.append(env)
	return env


## 可激活水晶需 _ready 解析 @onready _visual；--script 模式下手动调用 view 与 crystal 的 _ready()，不挂场景树。
func make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
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
func wait_settled(frames: int = 8) -> void:
	for i in frames:
		await _tree.process_frame


## 释放本轮创建的水晶、视觉父节点与控制器，跳过已释放实例；须在控制器 free 之后清 envs，避免协程再访问。
func cleanup() -> void:
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
