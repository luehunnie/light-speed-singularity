extends Node2D

## 核心闭环原型关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入，发起普通主发射源最小脉冲光线（Vector2i 逐格路径，无 Area2D/Tween/物理射线），
## 通过 OccupancyRegistry 解析单格镜面并改向、点亮普通独立水晶、保持关卡完成结果；实现最小镜面库存、拖拽放置/移动/回收与 SETUP 右键朝向配置。
## 状态事实所有权：四态（SETUP/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）由 _run_state_controller 持有；pulse_generation、runtime_moves_used、
## 发射请求编排、异步脉冲结束与完整 R 重置顺序由 _level_runtime_controller 唯一持有；玩家机关映射 placed_tokens_by_id 与机关序号由 _placement_controller 唯一持有；
## 玩家机关库存剩余由 _inventory_controller 持有；目标完成事实（水晶激活、完成判断、运行期重置）由 _objective_controller 唯一持有。OccupancyRegistry 是格子占用唯一事实来源。
## 核心只保留接线、输入转发、右键镜面配置入口、节点工厂、UI 适配与启动自检入口；七项启动自检编排与摘要日志由 _startup_self_check_coordinator 整块负责。
## 正式运行权限：SETUP 允许完整布置且移动不计次；PULSE_ACTIVE/MOVE_WINDOW 允许拿取/放置/移动/回收但右键配置锁定、PULSE_ACTIVE 禁止 Space；
## 仅“已放置机关跨格直接移动”成功提交后消耗 runtime_move_limit 一次；COMPLETED 冻结全部交互，只允许 R。
## R 是完整关卡重置（由 _level_runtime_controller.reset_runtime 执行）：递增 pulse_generation 使旧异步失效 → 安全取消拖拽 → 清光路/水晶/完成状态 → 逐个注销玩家机关占用并退回库存 → 清零 runtime_moves_used → 回 SETUP；不删除发射器/墙体/水晶/静态内容。


# 世界格尺寸唯一来源（preload 共享常量，不加 class_name）；64 世界格对应半格 32。
# 格↔世界换算统一走 _GridCoordinateRules（cell_to_world / world_to_cell），不在本脚本重复维护坐标公式。
# 以下 preload 常量均以 const 路径引用，避开 MCP run_project 不重建全局 class_name 缓存的问题；嵌套枚举通过常量限定访问。
const GridMetrics: GDScript = preload("res://gameplay/grid/grid_metrics.gd")
const CELL_SIZE: int = GridMetrics.CELL_SIZE
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const MAX_PROPAGATION_STEPS: int = 128
const PULSE_VISUAL_DURATION_SECONDS: float = 1.0
const PROTOTYPE_TOKEN_TOTAL: int = 1
const INVALID_CELL: Vector2i = Vector2i(-999999, -999999)


# 以下两项仅为 Inspector 初始配置；_ready 中据此构造 _fixed_emitter，运行期格子/方向只由 FixedEmitter 提供。
@export var emitter_cell: Vector2i = Vector2i(1, 3)
@export var emitter_direction: Vector2i = Vector2i.RIGHT
@export var map_bounds: Rect2i = Rect2i(0, 0, 16, 16)
@export var wall_cells: Array[Vector2i] = [Vector2i(5, 3)]

## 运行期移动次数上限。仅在 PULSE_ACTIVE 或 MOVE_WINDOW 中成功跨格移动已放置机关时消耗；SETUP 移动不受此限制。
@export_range(0, 99, 1) var runtime_move_limit: int = 1

# terrain_layer 保留以满足 plan §3.1 节点树约定；当前原型不使用 TileSet，格↔世界换算由 GridCoordinateRules 实现，不依赖 map_to_local。
@onready var terrain_layer: TileMapLayer = $TerrainLayer
@onready var runtime_objects: Node2D = $RuntimeObjects
@onready var light_path_layer: Node2D = $LightPathLayer
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var complete_label: Label = $CanvasLayer/CompleteLabel
@onready var inventory_bar: Control = $CanvasLayer/InventoryBar
@onready var prototype_token_slot: _InventorySlotViewScript = $CanvasLayer/InventoryBar/MarginContainer/HBoxContainer/PrototypeTokenSlot
@onready var runtime_move_label: Label = $CanvasLayer/RuntimeMoveLabel
@onready var crystals: Array[BasicCrystal] = [$RuntimeObjects/Crystal]

## 轻量机关占用表：格子坐标 ↔ 机关 ID 双向索引，用于单格镜面放置/移动/回收与传播循环中的镜面节点解析。
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
# 库存一致性只读快照与共享纯规则；运行期断言与启动自检共用同一采集函数与规则来源，A/B/C 规则不在核心保留副本。
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)
const _InventoryConsistencyRules: GDScript = preload(
	"res://gameplay/placement/rules/inventory_consistency_rules.gd"
)
# 玩家机关库存事实所有者：核心持有的唯一实例，保存总量与剩余量，提供扣除/归还/重置与一致性判断；不持有 placed_tokens_by_id、不访问占用/UI/RunState。
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
# 玩家机关放置/移动/回收原子事务控制器：唯一持有 placed_tokens_by_id 与机关序号，负责事务提交与回滚；核心只发请求并按结果清理拖拽。
const _PlacementController: GDScript = preload(
	"res://gameplay/placement/placement_controller.gd"
)
# 启动自检协调器：核心持有的唯一实例，整块负责七项启动自检编排、三层 Debug 硬断言与启动摘要日志；核心只采集场景数据并调用 run_all。
const _StartupSelfCheckCoordinator: GDScript = preload(
	"res://gameplay/diagnostics/startup_self_check_coordinator.gd"
)
const _SingleCellMirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
const _InventorySlotViewScript: GDScript = preload("res://gameplay/ui/inventory_slot_view.gd")
# 普通光线路径视觉控制器：完整拥有光路视觉节点集合与四方向接线，核心只调用 show_step / clear_path。
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
# 运行交互共享类型契约（RunState / DragSource）。
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
# 运行期移动纯规则；正式玩法调用与 runtime_move 启动自检共用同一规则来源。
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
# RunStateController：核心持有的唯一运行状态所有者，负责四态事实、最小合法转换与 state_changed 信号；不加入场景树、不设为 Autoload。
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
# 拖拽业务流程控制器：完整拥有一次拖拽的生命周期（拿取/预览/隐藏/提交/回收/取消/清理）；核心只转发指针位置、取消请求与场景适配 Callable。
const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
# 玩家输入分类器：把 InputEvent 分类为业务命令；不查询状态、不命中 UI、不转网格、不执行业务。
const _PlayerInteractionController: GDScript = preload("res://gameplay/interaction/player_interaction_controller.gd")
# 世界只读查询门面与光线层薄适配器；不加入场景树、不设为 Autoload。
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
# 关卡稳定对象索引所有者（D3-C）：水晶按显式 crystal_id 与 cell 双向索引，LevelWorldQuery 据此查询水晶，不暴露可写字典。
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
# 目标完成事实唯一所有者（D3-D）：按 cell 激活水晶、判断完成、运行期重置水晶；核心只读取 is_completed()/reset_runtime()，不保留第二套目标业务实现。
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
# 固定发射器与发射请求数据；运行期格子和方向唯一所有者为 FixedEmitter，emitter_cell/emitter_direction 仅作 Inspector 初始配置。
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
# 正式运行期编排控制器（D3-E）：完整拥有 pulse_generation、runtime_moves_used、发射编排、异步脉冲结束与 R 重置顺序；核心只调 request_fire/reset_runtime 与运行期移动次数查询。
const _LevelRuntimeController: GDScript = preload("res://gameplay/runtime/level_runtime_controller.gd")
var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()

## 玩家机关库存事实所有者：运行期剩余数量唯一事实来源，扣除/归还/重置经此实例；拖拽开始时不提前扣数量，仅合法放置成功后才扣除。
var _inventory_controller: _InventoryController = _InventoryController.new(PROTOTYPE_TOKEN_TOTAL)

## 玩家机关放置/移动/回收事务控制器；唯一持有 placed_tokens_by_id 与机关序号，_ready 中构造并注入依赖。核心只发事务请求并按结果清理拖拽。
var _placement_controller: _PlacementController = null

## 拖拽业务流程控制器：核心持有的唯一实例，拥有一次拖拽的完整业务生命周期；核心只转发指针位置、取消请求与场景适配 Callable。
var _drag_flow_controller: _DragFlowController = null

## 玩家输入分类器：把 _input 收到的 InputEvent 分类为业务命令，自身不执行任何业务副作用。
var _player_interaction_controller: _PlayerInteractionController = _PlayerInteractionController.new()

## 启动自检协调器：核心持有的唯一实例，整块负责七项启动自检编排与摘要日志；不作为 Node、不设为 Autoload。
var _startup_self_check_coordinator: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()

## 运行状态控制器：核心持有的唯一运行状态所有者，负责四态事实、最小合法转换与 state_changed 信号；核心不持有 current_run_state 副本。
## COMPLETED 前取消拖拽与 pulse_generation 异步回调保护由 LevelRuntimeController 完成；核心不持有 pulse_generation。不作为 Node、不设为 Autoload。
var _run_state_controller: _RunStateController = _RunStateController.new()

## 普通光线路径视觉控制器：完整拥有光路视觉节点集合（逐格创建/记录/cell→世界定位/四方向接线/路径清理）；核心只调用 show_step 与 clear_path，不持有第二套视觉创建实现。
var _light_visual_controller: _LightVisualController = null

## 世界只读查询门面：在所有真实依赖初始化后构造，持有容器引用而非复制（容器运行期只原地增删，从不整体重赋值）；只读，不修改世界事实。
var _level_world_query: _LevelWorldQuery = null

## 关卡稳定对象索引：_ready 中遍历 crystals 按显式 crystal_id 与 cell 注册，LevelWorldQuery 据此查询水晶；不暴露内部字典。
var _level_object_registry: _LevelObjectRegistry = _LevelObjectRegistry.new()

## 目标完成事实所有者：按 cell 激活水晶、判断完成、运行期重置；_ready 中在 Registry 填充后构造，核心只读取事实，不持有完成字段副本。
var _objective_controller: _ObjectiveController = null

## 普通光线只读薄适配层：内部依赖 _level_world_query，只组合既有边界与墙体规则，不新增规则、不执行传播循环或副作用。
var _light_world_query: _LightWorldQuery = null

## 固定发射器：运行期格子与方向的唯一所有者；_ready 中由 Inspector 初始配置构造一次，此后 fire_light 与 LevelWorldQuery 只读取本实例。
var _fixed_emitter: _FixedEmitter = null

## 正式运行期编排控制器：_ready 中构造并 add_child；核心只调 request_fire/reset_runtime 与运行期移动次数查询/扣除委托，不持有 pulse_generation 或 runtime_moves_used。
var _level_runtime_controller: _LevelRuntimeController = null


## 初始化核心闭环原型关卡：刷新机关栏 UI；仅调试构建执行七项启动自检与摘要日志，发布构建跳过，避免把调试断言作为运行期必需流程。
func _ready() -> void:
	# 早期连接运行状态信号，避免错过首次状态变化；本回调只刷新机关栏 UI。
	_run_state_controller.state_changed.connect(_on_run_state_changed)
	# 光路视觉控制器先构造：注入 LightPathLayer 作为视觉父节点，视觉资源与颜色由控制器自持。
	_light_visual_controller = _LightVisualController.new(light_path_layer)
	# 放置事务控制器先于只读查询门面构造：LevelWorldQuery 需持有控制器映射引用，供光线层 cell→ID→节点解析。
	_placement_controller = _PlacementController.new(
		occupancy,
		_inventory_controller,
		Callable(self, "_create_formal_token_node")
	)
	# 固定发射器先于只读查询门面构造：LevelWorldQuery 与 fire_light 的运行期格子只取自本实例，emitter_cell 仅在此处作为初始配置读入。
	_fixed_emitter = _FixedEmitter.new(emitter_cell, emitter_direction)
	# 稳定对象索引：遍历 @onready crystals，按显式 crystal_id 与 cell 注册；任一失败 push_error 并 assert 暴露，不静默跳过。
	for crystal: BasicCrystal in crystals:
		assert(_level_object_registry.register_crystal(crystal.get_crystal_id(), crystal.cell, crystal),
				"水晶注册失败：crystal_id=%s cell=%s" % [crystal.get_crystal_id(), crystal.cell])
	# 目标完成事实所有者：在 Registry 填充后构造，唯一持有水晶激活/完成判断/运行期重置。
	_objective_controller = _ObjectiveController.new(_level_object_registry)
	# 在所有真实依赖初始化后构造只读查询门面；水晶查询走 Registry，机关节点走 PlacementController.get_placed_node 只读 Callable，不共享可写映射。
	_level_world_query = _LevelWorldQuery.new(
		map_bounds,
		wall_cells,
		_fixed_emitter.get_cell(),
		_level_object_registry,
		occupancy,
		Callable(_placement_controller, "get_placed_node")
	)
	_placement_controller.set_level_world_query(_level_world_query)
	_light_world_query = _LightWorldQuery.new(_level_world_query)
	# 拖拽流程控制器在放置/库存/世界查询门面就绪后构造；场景适配 Callable 注入指针解析、预览创建、权限查询、扣次、UI 刷新与一致性断言。
	_drag_flow_controller = _DragFlowController.new(
		_placement_controller,
		_inventory_controller,
		_level_world_query,
		Callable(self, "_resolve_drag_pointer"),
		Callable(self, "_create_token_node"),
		Callable(self, "_query_drag_permission"),
		Callable(self, "_consume_runtime_move"),
		Callable(self, "_refresh_drag_ui"),
		Callable(self, "_assert_inventory_consistency")
	)
	# 正式运行期编排控制器：在放置/库存/世界查询/拖拽流程就绪后构造，注入全部依赖与高层 UI/一致性 Callable；add_child 跟随关卡场景以安全访问 SceneTreeTimer。
	_level_runtime_controller = _LevelRuntimeController.new(
		_run_state_controller,
		_fixed_emitter,
		_light_world_query,
		_light_visual_controller,
		_objective_controller,
		_placement_controller,
		_inventory_controller,
		_drag_flow_controller,
		MAX_PROPAGATION_STEPS,
		PULSE_VISUAL_DURATION_SECONDS,
		runtime_move_limit,
		Callable(self, "_refresh_runtime_ui"),
		Callable(self, "_set_complete_label_visible"),
		Callable(self, "_assert_inventory_consistency")
	)
	add_child(_level_runtime_controller)
	_update_inventory_ui()
	_update_runtime_move_ui()
	if OS.is_debug_build():
		# 采集网格采样格（含 Registry 完整性前置断言）与库存一致性只读快照，交由协调器按固定顺序执行七项自检并写摘要日志。
		var sample_cells: Array[Vector2i] = _collect_grid_coordinate_sample_cells()
		var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
		_startup_self_check_coordinator.run_all(sample_cells, snapshot, true, true)


## 处理关卡输入动作和鼠标拖拽事件：fire_light 转发到 LevelRuntimeController.request_fire（拖拽中/PULSE_ACTIVE/COMPLETED 拒绝在控制器内）；reset_level 转发到 reset_runtime()；鼠标左键按运行权限驱动放置/移动/回收。
## 拖拽中按 Space 由控制器拒绝；拖拽中按 R 不依赖 _input 预取消，由 reset_runtime() 统一安全取消拖拽；PULSE_ACTIVE 期间布局变化只影响后续发射，不回溯当前脉冲。
func _input(event: InputEvent) -> void:
	var command: _PlayerInteractionController.Command = _player_interaction_controller.translate(event)
	match command.kind:
		_PlayerInteractionController.Command.Kind.RESET:
			reset_runtime()
		_PlayerInteractionController.Command.Kind.FIRE:
			fire_light()
		_PlayerInteractionController.Command.Kind.PRIMARY_PRESS:
			_drag_flow_controller.try_begin_drag(command.pointer_position)
		_PlayerInteractionController.Command.Kind.PRIMARY_RELEASE:
			if is_dragging():
				_drag_flow_controller.finish_drag(command.pointer_position)
		_PlayerInteractionController.Command.Kind.SECONDARY_PRESS:
			_try_toggle_mirror_at_mouse()
		_PlayerInteractionController.Command.Kind.POINTER_MOTION:
			_drag_flow_controller.update_preview(command.pointer_position)
		_PlayerInteractionController.Command.Kind.NONE:
			pass


## state_changed 回调：只刷新机关栏 UI；不在此取消拖拽或修改 pulse_generation/水晶/光路/占用/完成事实。COMPLETED 前取消拖拽由 LevelRuntimeController 在请求转换前完成。
func _on_run_state_changed(
		_previous_state: _RuntimeInteractionTypes.RunState,
		_new_state: _RuntimeInteractionTypes.RunState
) -> void:
	_update_inventory_ui()


## 查询当前运行状态；纯读取转发 _run_state_controller.get_current_state()，用于把状态值传给玩法规则层，不把 Controller 实例传入规则层。
func _get_current_run_state() -> _RuntimeInteractionTypes.RunState:
	return _run_state_controller.get_current_state()


## 是否允许编辑内部配置（仅 SETUP）。本权限只用于主发射源方向、机关内部模式等内部配置，不代表布局编辑权限，不得用于控制拖拽放置/移动/回收。
func can_edit_configuration() -> bool:
	return _run_state_controller.can_edit_configuration()


## 剩余运行期移动次数 max(limit - used, 0)；委托 LevelRuntimeController，核心不持有 runtime_moves_used 副本。
func get_runtime_moves_remaining() -> int:
	return _level_runtime_controller.get_runtime_moves_remaining()


## 刷新运行期移动次数 UI（"运行期移动：剩余 / 上限"）；只读取控制器剩余次数与本地配置上限，不修改事实。
func _update_runtime_move_ui() -> void:
	runtime_move_label.text = "运行期移动：%d / %d" % [_level_runtime_controller.get_runtime_moves_remaining(), runtime_move_limit]


## 发射入口：转发到 LevelRuntimeController.request_fire；发射顺序、逐 step 视觉→水晶、异步脉冲结束与 generation 过期保护全部由控制器拥有，核心不保留第二套实现。
func fire_light() -> void:
	_level_runtime_controller.request_fire()


## R 完整重置入口：转发到 LevelRuntimeController.reset_runtime；重置顺序、旧异步失效与移动次数清零全部由控制器拥有。
func reset_runtime() -> void:
	_level_runtime_controller.reset_runtime()


## 查询指定格子被哪个机关占用（薄包装，转发 _level_world_query.get_mechanism_id_at）；未被占用返回空 StringName（&""），不报错。
func get_mechanism_at(cell: Vector2i) -> StringName:
	return _level_world_query.get_mechanism_id_at(cell)


## 尝试右键切换鼠标所在已放置镜面的内部朝向；仅 SETUP 且未拖拽、鼠标位于世界已放置 SingleCellMirror 时调用 toggle_orientation()。拖拽中、InventoryBar 区域、未知机关和空格安全忽略。
func _try_toggle_mirror_at_mouse() -> void:
	if is_dragging():
		return
	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	if _is_mouse_over_inventory_bar(viewport_mouse_position):
		return
	if not can_edit_configuration():
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态锁定内部配置，忽略镜面右键切换：%s。" % [_get_current_run_state()])
		return

	var target_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	var mechanism_id: StringName = get_mechanism_at(target_cell)
	if mechanism_id == &"" or not _placement_controller.has_placed(mechanism_id):
		return

	var token: Variant = _placement_controller.get_placed_node(mechanism_id)
	if not is_instance_valid(token):
		return
	if token is not SingleCellMirror:
		return
	var mirror: SingleCellMirror = token as SingleCellMirror
	mirror.toggle_orientation()


## 解析指针命中场景供 DragFlowController 使用：是否位于机关栏、是否位于原型槽位、世界格坐标。
## 世界格用 get_global_mouse_position() 换算（与原拖拽实现一致），UI 命中用传入的视口坐标。
func _resolve_drag_pointer(viewport_position: Vector2) -> _DragFlowController.PointerScene:
	var world_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	return _DragFlowController.PointerScene.new(
		_is_mouse_over_inventory_bar(viewport_position),
		_is_mouse_over_prototype_slot(viewport_position),
		world_cell
	)


## 拖拽权限只读快照：当前运行状态与剩余运行期移动次数；运行期移动次数由 LevelRuntimeController 唯一持有，本函数只读取，不保存副本。
func _query_drag_permission() -> _DragFlowController.DragPermission:
	return _DragFlowController.DragPermission.new(
		_get_current_run_state(),
		_level_runtime_controller.get_runtime_moves_remaining()
	)


## 扣除一次运行期移动次数；委托 LevelRuntimeController.consume_runtime_move，核心不持有计数，DragFlowController 已通过 should_count 校验。
func _consume_runtime_move() -> void:
	_level_runtime_controller.consume_runtime_move()


## 刷新机关栏与运行期移动 UI（纯显示，不修改库存或次数事实）；供 DragFlowController 提交后回调。
func _refresh_drag_ui() -> void:
	_update_inventory_ui()
	_update_runtime_move_ui()


## 刷新全部运行 UI（库存 + 运行期移动次数）；供 LevelRuntimeController 在脉冲结束与 R 重置后调用，不传入 UI 节点。
func _refresh_runtime_ui() -> void:
	_update_inventory_ui()
	_update_runtime_move_ui()


## 显隐完成标签；供 LevelRuntimeController 在发射、脉冲结束与 R 重置时调用，不传入 UI 节点。
## 参数命名为 should_be_visible，避免与 CanvasItem.is_visible() 同名遮蔽。
func _set_complete_label_visible(should_be_visible: bool) -> void:
	complete_label.visible = should_be_visible


## 创建拖拽预览节点（DragFlowController 的 create_preview_token 适配）：实例化 SingleCellMirror 并加入 RuntimeObjects，配置 ID/格/世界坐标与预览模式。
## 不写库存、不写 OccupancyRegistry、不判断合法性；新建镜面默认 SLASH，拖动已有镜面由控制器复制原 orientation。
func _create_token_node(mechanism_id: StringName, cell: Vector2i) -> Variant:
	var token = _SingleCellMirrorScene.instantiate()
	runtime_objects.add_child(token)
	token.configure(mechanism_id, cell)
	token.set_world_position(_GridCoordinateRules.cell_to_world(cell))
	token.set_drag_preview(true, true)
	return token


## 创建正式机关节点工厂（注入 PlacementController）：实例化 SingleCellMirror 并加入 RuntimeObjects，配置 ID/格/朝向/世界坐标。
## 不写占用、不写库存、不判断合法性；orientation 由 place_from_inventory 传入，新镜面为 SLASH。实例化失败返回 null 由控制器回滚。
func _create_formal_token_node(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
	var token = _SingleCellMirrorScene.instantiate()
	if not is_instance_valid(token):
		push_error("CoreLoopPrototype: 正式机关节点实例化失败：%s at %s" % [mechanism_id, cell])
		return null
	runtime_objects.add_child(token)
	token.configure(mechanism_id, cell)
	if token is SingleCellMirror:
		(token as SingleCellMirror).set_orientation(orientation)
	token.set_world_position(_GridCoordinateRules.cell_to_world(cell))
	token.set_drag_preview(false, true)
	return token


## 是否存在进行中的拖拽（转发到 DragFlowController）；预览节点可能因异常被释放，仍只以 DragContext 来源作为状态事实。
func is_dragging() -> bool:
	return _drag_flow_controller.is_dragging()


## 鼠标是否位于整个 InventoryBar 区域；用于回收判断，不要求精准拖到单个栏位。
func _is_mouse_over_inventory_bar(viewport_mouse_position: Vector2) -> bool:
	return inventory_bar.get_global_rect().has_point(viewport_mouse_position)


## 鼠标是否位于 PrototypeTokenSlot 区域；只用于从库存拿取，数量为 0 时即使命中也不会开始拖拽。
func _is_mouse_over_prototype_slot(viewport_mouse_position: Vector2) -> bool:
	return prototype_token_slot.get_global_rect().has_point(viewport_mouse_position)


## 刷新底部机关栏 UI：把库存剩余与是否允许拿取传给 InventorySlotView.refresh_slot()，由槽位组件统一负责剩余文本/占位符颜色/图标 self_modulate。UI 只显示库存事实，不自行修改库存。
func _update_inventory_ui() -> void:
	# 拿取可用性：库存大于 0 且当前运行状态允许从机关栏拿取（非 COMPLETED）。
	var remaining: int = _inventory_controller.get_remaining()
	var is_available: bool = (
		remaining > 0
		and _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state())
	)
	prototype_token_slot.refresh_slot(
		remaining,
		is_available
	)


## 采集网格坐标自检所需的真实采样格（_ready 第二项数据来源）。
## 按原自检顺序采集真实格子；只收集 Vector2i，不把 Crystal/Node 等真实对象传入 Diagnostics。
## Registry 完整性前置断言（数量、crystal_id 非空、cell 可反查原对象）保留在采集阶段，不迁入 Diagnostics，不新增第八项。
func _collect_grid_coordinate_sample_cells() -> Array[Vector2i]:
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, _fixed_emitter.get_cell()]
	# Registry 完整性：数量==crystals（注册已拒绝重复 ID 与 cell，数量一致即唯一），每个 crystal_id 非空，cell 可反查原对象。
	assert(_level_object_registry.get_crystal_count() == crystals.size(),
			"Registry 水晶数量与 crystals 不一致：%d vs %d" % [_level_object_registry.get_crystal_count(), crystals.size()])
	for crystal: BasicCrystal in crystals:
		sample_cells.append(crystal.cell)
		var crystal_id: StringName = crystal.get_crystal_id()
		assert(crystal_id != &"", "存在空 crystal_id 的水晶。")
		assert(_level_object_registry.get_crystal_at(crystal.cell) == crystal,
				"cell 反查水晶不一致：cell=%s crystal_id=%s" % [crystal.cell, crystal_id])
	for wall_cell: Vector2i in wall_cells:
		sample_cells.append(wall_cell)
	sample_cells.append(Vector2i(map_bounds.end.x - 1, map_bounds.end.y - 1))
	return sample_cells


## 采集库存一致性只读纯数据快照：冻结库存标量、OccupancyRegistry 本体一致性标志与六组对齐的条目级事实。
## D 类 Node 生命周期检查（is_instance_valid、is_queued_for_deletion）保留在本函数不迁入 Diagnostics，验证通过后才读取 token.mechanism_id 与 token.cell；不把真实 Node 传给 Snapshot/Rules/Check，不把生命周期状态写进 Snapshot。
## 六组容器按 PlacementController.get_placed_ids() 当前迭代顺序严格同步追加，不排序、不去重，不修改 OccupancyRegistry 返回数组；is_consistent() 每次只调用一次，不在核心复制其内部算法；count==0 时 first_cell 用 Vector2i.ZERO 占位（规则只在 count==1 时比较）。
func _collect_inventory_consistency_snapshot() -> _InventoryConsistencySnapshot:
	var dictionary_ids: Array[StringName] = []
	var token_ids: Array[StringName] = []
	var token_cells: Array[Vector2i] = []
	var occupancy_ids_at_token_cells: Array[StringName] = []
	var occupancy_cell_counts: PackedInt32Array = PackedInt32Array()
	var occupancy_first_cells: Array[Vector2i] = []

	# 通过控制器只读接口取得 ID 快照与节点，避免核心直接读写 placed_tokens_by_id。
	for mechanism_id: StringName in _placement_controller.get_placed_ids():
		var token: Variant = _placement_controller.get_placed_node(mechanism_id)
		var token_is_valid: bool = is_instance_valid(token)
		assert(token_is_valid, "玩家机关映射失效：mechanism_id=%s" % [mechanism_id])
		if not token_is_valid:
			continue

		var token_is_pending_deletion: bool = token.is_queued_for_deletion()
		assert(not token_is_pending_deletion, "玩家机关节点已排队删除但仍在映射中：mechanism_id=%s" % [mechanism_id])
		if token_is_pending_deletion:
			continue

		# 生命周期验证通过后才读取 token.mechanism_id 与 token.cell；dictionary_id 与 token_id 是否相等由 B 类共享规则判定，本函数不重复 assert。
		var token_id: StringName = token.mechanism_id
		var token_cell: Vector2i = token.cell

		var occupancy_id_at_token_cell: StringName = occupancy.get_mechanism_at(token_cell)
		var occupied_cells: Array[Vector2i] = occupancy.get_cells_of(mechanism_id)
		var occupancy_cell_count: int = occupied_cells.size()
		# count==0 时 first_cell 用 Vector2i.ZERO 占位；规则只在 count==1 时比较 first_cell，占位值不参与比较。
		var occupancy_first_cell: Vector2i = Vector2i.ZERO if occupancy_cell_count == 0 else occupied_cells[0]

		dictionary_ids.append(mechanism_id)
		token_ids.append(token_id)
		token_cells.append(token_cell)
		occupancy_ids_at_token_cells.append(occupancy_id_at_token_cell)
		occupancy_cell_counts.append(occupancy_cell_count)
		occupancy_first_cells.append(occupancy_first_cell)

	# is_consistent() 每次采集只调用一次；保留 OccupancyRegistry 本体一致性判断的 push_error 行为，不在核心复制其内部算法。
	var occupancy_consistent: bool = occupancy.is_consistent()

	return _InventoryConsistencySnapshot.new(
			_inventory_controller.get_total(),
			_inventory_controller.get_remaining(),
			occupancy_consistent,
			dictionary_ids,
			token_ids,
			token_cells,
			occupancy_ids_at_token_cells,
			occupancy_cell_counts,
			occupancy_first_cells
	)


## 断言库存、玩家机关映射与占用表一致；调试构建采集快照并调用 InventoryConsistencyRules.collect_failures，失败列表非空则 Debug 硬 assert。发布构建直接返回。A/B/C 规则唯一来源为 InventoryConsistencyRules，核心无副本；不使用 SelfCheckRunner，不修复数据，不把 assert 降级为 warning/日志。
func _assert_inventory_consistency() -> void:
	if not OS.is_debug_build():
		return
	var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
	var failures: PackedStringArray = _InventoryConsistencyRules.collect_failures(snapshot)
	assert(failures.is_empty(),
			"库存一致性断言失败：\n%s" % ["\n".join(failures)])
