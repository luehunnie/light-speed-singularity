extends Node2D

## 核心闭环原型关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入，发起普通主发射源最小脉冲光线（Vector2i 逐格路径，无 Area2D/Tween/物理射线），
## 通过 OccupancyRegistry 解析单格镜面并改向、点亮普通独立水晶、保持关卡完成结果；实现最小镜面库存、拖拽放置/移动/回收与 SETUP 右键朝向配置。
## 状态事实所有权：四态（SETUP/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）由 _run_state_controller 持有；核心持有 is_level_completed、
## pulse_generation、prototype_token_remaining、runtime_moves_used 与 placed_tokens_by_id。OccupancyRegistry 是格子占用唯一事实来源。
## 正式运行权限：SETUP 允许完整布置且移动不计次；PULSE_ACTIVE/MOVE_WINDOW 允许拿取/放置/移动/回收但右键配置锁定、PULSE_ACTIVE 禁止 Space；
## 仅“已放置机关跨格直接移动”成功提交后消耗 runtime_move_limit 一次；COMPLETED 冻结全部交互，只允许 R。
## R 是完整关卡重置：安全取消拖拽 → 递增 pulse_generation → 清光路/水晶/完成状态 → 逐个注销玩家机关占用并退回库存 → 清零 runtime_moves_used → 回 SETUP；不删除发射器/墙体/水晶/静态内容。


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
const MIRROR_TOKEN_TYPE_ID: StringName = &"basic_single_cell_mirror"
const INVALID_CELL: Vector2i = Vector2i(-999999, -999999)

## 原型光路视觉黄色显示色；仅用于 LightSegmentView 占位块 color 与正式纹理 self_modulate 调制，不参与 RGB 玩法。
const LIGHT_PATH_COLOR: Color = Color(1.0, 0.95, 0.2, 0.75)

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
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
# 七项启动自检模块；通过单项 SelfCheckRunner 执行，核心不再直接调用 run()，仍保留 Debug 硬断言边界。
const _OccupancyRegistryCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/occupancy_registry_check.gd")
const _MirrorReflectionCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/mirror_reflection_check.gd")
const _PlayerMechanismIdSnapshotCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/player_mechanism_id_snapshot_check.gd")
const _RuntimeMoveCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/runtime_move_check.gd")
# 持有只读采样快照的网格坐标自检模块。
const _GridCoordinateCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/grid_coordinate_check.gd")
const _RuntimeStateCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/runtime_state_check.gd")
# 库存一致性只读快照、共享纯规则与启动期自检；运行期断言与启动期自检共用同一采集函数与规则来源，A/B/C 规则不在核心保留副本。
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)
const _InventoryConsistencyRules: GDScript = preload(
	"res://gameplay/placement/rules/inventory_consistency_rules.gd"
)
const _InventoryConsistencyCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/inventory_consistency_check.gd"
)
# 诊断控制器：核心持有的唯一实例，协调七项启动自检；每次调用内部新建 SelfCheckRunner 并返回结果，不执行 assert，失败策略由核心决定。
const _DiagnosticsController: GDScript = preload(
	"res://gameplay/diagnostics/diagnostics_controller.gd"
)
# 启动摘要日志的等级与条目数据契约；核心只构造 DiagnosticLogEntry 并通过 write_entry_to_file 落盘，不直接 new RuntimeLogger。
const _DiagnosticSeverity: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_severity.gd"
)
const _DiagnosticLogEntry: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_log_entry.gd"
)
# 玩家机关 R 重置共享纯规则；正式 R 重置与自检共用同一玩法层规则来源。
const _PlayerMechanismResetRules: GDScript = preload("res://gameplay/placement/rules/player_mechanism_reset_rules.gd")
const _SingleCellMirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
const _InventorySlotViewScript: GDScript = preload("res://gameplay/ui/inventory_slot_view.gd")
const _LightSegmentViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _LightSegmentViewScene: PackedScene = preload("res://gameplay/visuals/light_segments/light_segment_view.tscn")
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
# 运行交互共享类型契约（RunState / DragSource）。
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
# 运行期移动纯规则；正式玩法调用与 runtime_move 启动自检共用同一规则来源。
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
# 运行状态纯规则；正式玩法查询与 post_pulse_state 启动自检共用同一规则来源。
const _RuntimeStateRules: GDScript = preload("res://gameplay/interaction/runtime_state_rules.gd")
# RunStateController：核心持有的唯一运行状态所有者，负责四态事实、最小合法转换与 state_changed 信号；不加入场景树、不设为 Autoload。
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
# 世界只读查询门面与光线层薄适配器；不加入场景树、不设为 Autoload。
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
# 普通光线机关光学适配器与结果协议；核心只调用 _RayMechanismAdapter.evaluate()，机关识别/镜面反射/未知机关/出射方向全部迁入适配器。
const _RayMechanismAdapter: GDScript = preload("res://gameplay/light/ray_mechanism_adapter.gd")
const _RayMechanismResult: GDScript = preload("res://gameplay/light/ray_mechanism_result.gd")
# 普通光线执行模块与结果协议；核心只调用 _RayExecutionModule.execute()，逐格传播循环全部迁入模块，结果只保存事实。
const _RayExecutionModule: GDScript = preload("res://gameplay/light/ray_execution_module.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
# 默认光线路段视觉资源（四字段全空 → LightSegmentView 静默回退到黄色占位块）；以 Resource 类型 preload，set_profile 时再 as 为 profile 脚本类型，避免常量类型解析对全局类型缓存的依赖。
const _DefaultLightSegmentProfile: Resource = preload("res://assets/visual_profiles/basic_light_segment_visuals.tres")
var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()

## 当前运行是否已经完成关卡；与光路视觉生命周期分离，可先于运行状态变为 true，运行状态在脉冲视觉结束后才进入 COMPLETED。
var is_level_completed: bool = false

## 当前脉冲版本号；每次开始脉冲或 R 重置递增，用于让旧异步等待回调失效，避免误清理新脉冲。
var pulse_generation: int = 0

## 原型单格机关库存剩余数量；只在成功从库存放置后减少、拖回机关栏回收后增加，拖拽开始时不提前扣数量。
var prototype_token_remaining: int = PROTOTYPE_TOKEN_TOTAL

## 运行期已使用移动次数（R 重置清零）。remaining = max(limit - used, 0)；remaining=0 不禁止拖起（仍可取消/回收），只禁止提交到另一世界格。
var runtime_moves_used: int = 0

## 玩家已放置机关 ID → PlaceableToken 节点；格子占用以 OccupancyRegistry 为唯一事实来源，本映射只用于找到正式视觉节点。
var placed_tokens_by_id: Dictionary[StringName, Variant] = {}

var _next_prototype_token_serial: int = 1
var _drag_source: _RuntimeInteractionTypes.DragSource = _RuntimeInteractionTypes.DragSource.NONE
var _drag_mechanism_id: StringName = &""
var _drag_original_cell: Vector2i = INVALID_CELL
var _drag_preview_cell: Vector2i = INVALID_CELL
var _drag_preview_token: Variant = null
var _dragged_placed_token: Variant = null

## 诊断控制器：核心持有的唯一实例，仅协调七项启动自检；不作为 Node、不设为 Autoload，运行期库存断言不经本 Controller。
var _diagnostics_controller: _DiagnosticsController = _DiagnosticsController.new()

## 运行状态控制器：核心持有的唯一运行状态所有者，负责四态事实、最小合法转换与 state_changed 信号；核心不持有 current_run_state 副本。
## COMPLETED 前取消拖拽必须在请求转换前由核心完成；pulse_generation 仍由核心保护异步回调。不作为 Node、不设为 Autoload。
var _run_state_controller: _RunStateController = _RunStateController.new()

## 世界只读查询门面：在所有真实依赖初始化后构造，持有容器引用而非复制（容器运行期只原地增删，从不整体重赋值）；只读，不修改世界事实。
var _level_world_query: _LevelWorldQuery = null

## 普通光线只读薄适配层：内部依赖 _level_world_query，只组合既有边界与墙体规则，不新增规则、不执行传播循环或副作用。
var _light_world_query: _LightWorldQuery = null


## 初始化核心闭环原型关卡：刷新机关栏 UI；仅调试构建执行七项启动自检与摘要日志，发布构建跳过，避免把调试断言作为运行期必需流程。
func _ready() -> void:
	# 早期连接运行状态信号，避免错过首次状态变化；本回调只刷新机关栏 UI。
	_run_state_controller.state_changed.connect(_on_run_state_changed)
	# 在所有真实依赖（@onready crystals、occupancy、placed_tokens_by_id 与 @export 边界/墙体/发射器格）初始化后构造只读查询门面。
	_level_world_query = _LevelWorldQuery.new(
		map_bounds,
		wall_cells,
		emitter_cell,
		crystals,
		occupancy,
		placed_tokens_by_id
	)
	_light_world_query = _LightWorldQuery.new(_level_world_query, crystals)
	_update_inventory_ui()
	_update_runtime_move_ui()
	if OS.is_debug_build():
		_run_occupancy_registry_self_check()
		_run_grid_coordinate_self_check()
		_run_single_cell_mirror_reflection_self_check()
		_run_post_pulse_state_self_check()
		_run_runtime_move_self_check()
		_run_player_mechanism_id_snapshot_self_check()
		_run_inventory_consistency_self_check()
		# 只有第七项（库存一致性）成功后才写一条启动摘要日志；任一自检硬断言失败时执行不会到达此处。日志调用不得移出 Debug 守卫。
		_write_startup_self_check_summary_log()


## 查询真实 OccupancyRegistry 是否仍有任一索引引用指定机关 ID（只读）；R 重置用它决定 unregister 失败时是否必须失败关闭。规则位于 PlayerMechanismResetRules。
func _occupancy_has_any_reference_to_mechanism(mechanism_id: StringName) -> bool:
	return _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(occupancy, mechanism_id)


## 玩家机关 ID 快照、R 库存恢复计算与残留占用查询自检（_ready 第六项）；规则位于 PlayerMechanismResetRules，保留 Debug 硬断言边界。
func _run_player_mechanism_id_snapshot_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"player_mechanism_id_snapshot",
			"玩家机关 ID 快照、R 库存计算与残留引用自检",
			_PlayerMechanismIdSnapshotCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_player_mechanism_id_snapshot")


## 启动期单项自检执行入口：把 SelfCheckCallable 交由 DiagnosticsController 协调执行（Controller 不 assert，失败策略由核心决定）。
## 保留三层 Debug 硬断言——执行级（run_result null 或 errors 非空）、结构级（validate() 非空）、检查级（is_success() 为 false），断言信息汇总 execution_id/errors/validate/每项 check 详情，不降级为 warning。仅用于启动期自检，运行期库存一致性由 _assert_inventory_consistency 直接断言。
func _run_startup_self_check_via_controller(
		definition: SelfCheckCallable,
		execution_id: StringName
) -> void:
	assert(definition != null, "启动自检：definition 为 null，必须传入 SelfCheckCallable。")
	var run_result: SelfCheckRunResult = _diagnostics_controller.run_self_check(
		definition,
		execution_id
	)
	# 执行级前置：Controller 必须返回非 null 结果。
	assert(run_result != null, "启动自检：Controller 返回 null execution_id=%s。" % [execution_id])
	var structure_problems: PackedStringArray = run_result.validate()
	# 汇总断言信息：execution_id、errors、validate 错误、每项 check_id/summary/details。
	var assert_lines: PackedStringArray = PackedStringArray()
	assert_lines.append("execution_id=%s" % [execution_id])
	assert_lines.append("errors=%s" % [run_result.errors])
	assert_lines.append("validate=%s" % [structure_problems])
	for index: int in range(run_result.results.size()):
		var item: SelfCheckResult = run_result.results[index]
		if item == null:
			assert_lines.append("results[%d]=null" % [index])
		else:
			assert_lines.append("results[%d] check_id=%s summary=%s details=%s" % [index, item.check_id, item.summary, item.details])
	var assert_message: String = "\n".join(assert_lines)
	# 第一层：执行级错误（注册/协调失败）。
	assert(run_result.errors.is_empty(), "启动自检：执行级错误（注册/协调失败）：\n%s" % [assert_message])
	# 第二层：结果结构（validate() 字段问题）。
	assert(structure_problems.is_empty(), "启动自检：结果结构无效：\n%s" % [assert_message])
	# 第三层：检查未通过（任一 passed=false）。
	assert(run_result.is_success(), "启动自检：检查未通过：\n%s" % [assert_message])


## 在七项启动自检全部通过后写一条 INFO 启动摘要日志（DiagnosticLogEntry，经 DiagnosticsController.write_entry_to_file 落盘）。
## 日志属 Diagnostics 而非玩法事务：写入失败只逐项 push_warning，不 assert、不中断主场景启动、不改变 RunState；同一次启动只写一条摘要，不逐项记录 PASS。
func _write_startup_self_check_summary_log() -> void:
	# 时间戳取 Unix 毫秒，满足 DiagnosticLogEntry 契约。
	var timestamp_unix_msec: int = int(Time.get_unix_time_from_system() * 1000.0)
	# 构造参数顺序严格匹配 DiagnosticLogEntry 签名（timestamp, severity, module, execution, message）。
	var entry: _DiagnosticLogEntry = _DiagnosticLogEntry.new(
		timestamp_unix_msec,
		_DiagnosticSeverity.Level.INFO,
		&"startup_self_check",
		&"startup_all_self_checks",
		"七项启动自检全部通过"
	)
	var write_problems: PackedStringArray = _diagnostics_controller.write_entry_to_file(entry)
	for problem: String in write_problems:
		push_warning("启动摘要日志写入失败：%s" % [problem])


## OccupancyRegistry 启动期轻量自检（_ready 第一项）；构造 SelfCheckCallable 交由 _run_startup_self_check_via_controller，保留 Debug 硬断言边界。
func _run_occupancy_registry_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"occupancy_registry",
			"OccupancyRegistry 启动期轻量自检",
			_OccupancyRegistryCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_occupancy_registry")


## 64 像素逻辑格坐标换算自检（_ready 第二项）；按原顺序采集真实格子构造 GridCoordinateCheck，只把 Vector2i 传入 Diagnostics，不传真实对象，不改遍历顺序。
func _run_grid_coordinate_self_check() -> void:
	# 按原自检顺序采集真实格子；只收集 Vector2i，不把 Crystal/Node 等真实对象传入 Diagnostics。
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, emitter_cell]
	for crystal: BasicCrystal in crystals:
		sample_cells.append(crystal.cell)
	for wall_cell: Vector2i in wall_cells:
		sample_cells.append(wall_cell)
	sample_cells.append(Vector2i(map_bounds.end.x - 1, map_bounds.end.y - 1))

	var check: _GridCoordinateCheck = _GridCoordinateCheck.new(sample_cells)
	# 无参实例 Callable，不使用 bind/lambda/捕获。
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"grid_coordinate",
			"网格坐标规则自检",
			Callable(check, "run")
	)
	_run_startup_self_check_via_controller(definition, &"startup_grid_coordinate")

## 基础单格镜面八方向反射纯函数自检（_ready 第三项，位于网格坐标自检之后，不得前移）。
func _run_single_cell_mirror_reflection_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"single_cell_mirror_reflection",
			"基础单格镜面八方向反射纯函数自检",
			_MirrorReflectionCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_single_cell_mirror_reflection")


## 运行状态纯规则自检（_ready 第四项）；规则位于 RuntimeStateRules，检查失败也不修改或泄漏核心运行状态。
func _run_post_pulse_state_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"runtime_state_rules",
			"运行状态规则自检",
			_RuntimeStateCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_runtime_state_rules")


## 运行期移动次数纯函数自检（_ready 第五项）；规则位于 RuntimeMoveRules，本函数不参与实际移动判定。
func _run_runtime_move_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"runtime_move_rules",
			"运行期移动规则自检",
			_RuntimeMoveCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_runtime_move_rules")


## 处理关卡输入动作和鼠标拖拽事件：fire_light 在 SETUP/MOVE_WINDOW 且未拖拽时触发一次脉冲；reset_level 直接调用 reset_runtime() 完整重置；鼠标左键按运行权限驱动放置/移动/回收。
## 拖拽中按 Space 安全忽略；拖拽中按 R 不依赖 _input 预取消，由 reset_runtime() 统一安全取消拖拽；PULSE_ACTIVE 期间布局变化只影响后续发射，不回溯当前脉冲。
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("reset_level"):
		reset_runtime()
		return

	if event.is_action_pressed("fire_light"):
		# 拖拽中拒绝 Space：一次拖拽事务未完成时不得启动新脉冲。
		if is_dragging():
			if OS.is_debug_build():
				print_debug("CoreLoopPrototype: 拖拽中忽略 Space 发射。")
			return
		fire_light()
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_update_drag_preview_from_mouse()


## state_changed 回调：只刷新机关栏 UI；不在此取消拖拽或修改 is_level_completed/pulse_generation/水晶/光路/占用。COMPLETED 前取消拖拽由 _finish_current_pulse 在请求转换前完成。
func _on_run_state_changed(
		previous_state: _RuntimeInteractionTypes.RunState,
		new_state: _RuntimeInteractionTypes.RunState
) -> void:
	_update_inventory_ui()


## 查询当前运行状态；纯读取转发 _run_state_controller.get_current_state()，用于把状态值传给玩法规则层，不把 Controller 实例传入规则层。
func _get_current_run_state() -> _RuntimeInteractionTypes.RunState:
	return _run_state_controller.get_current_state()


## 是否允许发射普通脉冲（SETUP/MOVE_WINDOW 可发射）。完成标签已显示但脉冲视觉未结束时状态仍为 PULSE_ACTIVE，重复 Space 仍被拒绝。
func can_fire_light() -> bool:
	return _run_state_controller.can_fire_light()


## 粗粒度冻结门：非 COMPLETED 返回 true。不是拿取/移动/回收的唯一守卫——拿取/回收在所有非 COMPLETED 状态允许，拖起由 _can_begin_placed_drag 限制（与剩余次数分离），跨格提交由 _can_commit_placed_move 按剩余次数限制。
func can_edit_layout() -> bool:
	return _run_state_controller.can_edit_layout()


## 是否允许编辑内部配置（仅 SETUP）。本权限只用于主发射源方向、机关内部模式等内部配置，不代表布局编辑权限，不得用于控制拖拽放置/移动/回收。
func can_edit_configuration() -> bool:
	return _run_state_controller.can_edit_configuration()


## 是否处于普通脉冲活动窗口（PULSE_ACTIVE）。通关目标可在 PULSE_ACTIVE 期间已成立，脉冲活动仍以运行状态为准。
func is_current_pulse_active() -> bool:
	return _run_state_controller.is_current_pulse_active()


## 是否处于运行期移动状态（PULSE_ACTIVE 或 MOVE_WINDOW）。运行期移动次数只在这两态扣除，SETUP 不计次，COMPLETED 冻结全部布局交互。
func is_runtime_move_state() -> bool:
	return _run_state_controller.is_runtime_move_state()


## 剩余运行期移动次数 max(limit - used, 0)；UI 与跨格提交权限只读取本结果，不在此处递增。
func get_runtime_moves_remaining() -> int:
	return _RuntimeMoveRules.compute_runtime_moves_remaining(runtime_move_limit, runtime_moves_used)


## 是否仍有运行期跨格移动提交次数；返回 false 时不禁止拖起机关，玩家仍可松回原格取消或拖回机关栏回收。SETUP 移动不受该次数限制。
func has_runtime_moves_remaining() -> bool:
	return get_runtime_moves_remaining() > 0


## 刷新运行期移动次数 UI（“运行期移动：剩余 / 上限”）；不修改 runtime_moves_used 或 runtime_move_limit。
func _update_runtime_move_ui() -> void:
	runtime_move_label.text = "运行期移动：%d / %d" % [get_runtime_moves_remaining(), runtime_move_limit]


## 决定脉冲结束后目标状态：完成→COMPLETED，未完成→MOVE_WINDOW。只转发 level_completed，规则位于 RuntimeStateRules。
func _get_post_pulse_state(level_completed: bool) -> _RuntimeInteractionTypes.RunState:
	return _RuntimeStateRules.get_post_pulse_state(level_completed)


## 发射入口：SETUP/MOVE_WINDOW 且未拖拽时清理上一轮光路视觉，调用 RayExecutionModule.execute() 无副作用计算路径，按结果顺序创建视觉并激活水晶，再启动约 1 秒脉冲视觉保持。
## 副作用边界：begin_pulse() 进入 PULSE_ACTIVE 并递增 pulse_generation；完成状态先置位，运行状态等脉冲视觉结束后才进入 COMPLETED。方向非法中止；拖拽中/PULSE_ACTIVE/COMPLETED 忽略 Space。
func fire_light() -> void:
	if is_dragging():
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 拖拽中拒绝发射。")
		return
	if not can_fire_light():
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态拒绝 Space 发射：%s。" % [_get_current_run_state()])
		return

	var direction: Vector2i = emitter_direction
	if not is_valid_direction(direction):
		push_error("Invalid emitter direction: %s" % [direction])
		return

	_prepare_for_new_pulse()

	# 必须确认状态成功进入 PULSE_ACTIVE 后才继续本次发射；begin_pulse 返回 false 时停止发射（Controller 已 push_error 拒绝原因）。
	if not _run_state_controller.begin_pulse():
		return
	pulse_generation += 1
	var current_pulse_generation: int = pulse_generation

	# 传播计算在 RayExecutionModule 内无副作用完成，核心只应用结果。
	var execution_result: _RayExecutionResult = _RayExecutionModule.execute(
		emitter_cell,
		direction,
		MAX_PROPAGATION_STEPS,
		_light_world_query
	)
	if execution_result.reached_step_limit:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")

	# 逐格按结果顺序应用副作用：同一格先创建光路视觉再尝试激活水晶，不先遍历全部视觉再遍历水晶。
	_apply_ray_execution_result(execution_result)

	# 通关判断立即完成；CompleteLabel 可立刻显示，但运行状态保持 PULSE_ACTIVE 到脉冲视觉结束。
	update_completion_state()

	_finish_pulse_after_delay(current_pulse_generation)


## 应用一次光线执行结果的副作用：逐格按 steps 顺序，同一格先创建光路视觉再按 has_crystal 激活水晶。不重新计算路径、不修改占用或机关、不访问 RunState。
func _apply_ray_execution_result(result: _RayExecutionResult) -> void:
	for step in result.steps:
		add_light_visual(step.cell, step.incoming_direction)
		if step.has_crystal:
			try_activate_crystal_at(step.cell)


## 下一次脉冲前的光路视觉清理；只清除旧光路视觉，不改变水晶、机关、运行状态、完成状态或 pulse_generation。不承担 R 完整重置职责。
func _prepare_for_new_pulse() -> void:
	clear_light_path()


## 等待脉冲视觉保持时间后尝试结束脉冲；若 R 重置或新脉冲已递增 pulse_generation，本回调视为过期直接返回，不清理或改变新脉冲状态。
func _finish_pulse_after_delay(expected_generation: int) -> void:
	await get_tree().create_timer(PULSE_VISUAL_DURATION_SECONDS).timeout
	# 过期回调保护：旧脉冲等待结束后不得清理 R 后新发射的脉冲或改变新脉冲状态。
	if expected_generation != pulse_generation:
		return
	if not is_current_pulse_active():
		return
	_finish_current_pulse(expected_generation)


## 结束当前仍有效的脉冲：清除光路视觉，请求 Controller 切换到 MOVE_WINDOW 或 COMPLETED。
## 不清除水晶、机关、库存或占用表，完成状态和 CompleteLabel 保持到 R。版本不匹配或无活动脉冲时直接返回；finish_pulse 失败时安全退出。
## generation 与计时器仍由核心保护，不移入 Controller。
func _finish_current_pulse(expected_generation: int) -> void:
	# 过期回调保护：结束清理前再次确认这是当前有效脉冲。
	if expected_generation != pulse_generation:
		return
	if not is_current_pulse_active():
		return

	# 脉冲结束：普通光路视觉消失，普通独立水晶继续保持点亮。
	clear_light_path()

	var next_state: _RuntimeInteractionTypes.RunState = _get_post_pulse_state(is_level_completed)

	# COMPLETED 进入冻结前由核心取消当前拖拽，必须在请求状态转换前完成，避免冻结后鼠标松开仍提交移动/回收。
	# 顺序：取消拖拽 → 更新状态 → 发 state_changed → 刷新机关栏 UI。转 MOVE_WINDOW 时已开始的合法拖拽可继续，提交时由 _commit_placed_drag_or_cancel() 重新校验。
	if next_state == _RuntimeInteractionTypes.RunState.COMPLETED and is_dragging():
		_cancel_current_drag()

	# 请求 Controller 切换状态；失败通过现有错误边界暴露并安全退出。
	if not _run_state_controller.finish_pulse(is_level_completed):
		push_error("CoreLoopPrototype: RunStateController.finish_pulse 被拒绝，无法结束脉冲。")
		return

	# 完成结果保留：路径消失后，已经成立的关卡完成标签继续显示。
	if _get_current_run_state() == _RuntimeInteractionTypes.RunState.COMPLETED:
		complete_label.visible = true


## R 完整重置：安全取消拖拽 → 递增 pulse_generation 使旧等待回调失效 → 清光路/水晶/完成状态 → 逐个注销并删除可确认清理的玩家机关 → 按未清理数量恢复库存 → 回 SETUP。
## 不依赖 _input 预取消拖拽；拖动已放置机关时先恢复正式节点原格和可见性，再统一注销占用并删除节点。只清理玩家放置机关，不调用 occupancy.clear()，不删除发射器/墙体/水晶/静态内容。
## 残留边界：若 OccupancyRegistry 残留且无法通过公共 unregister 确认清理，相关机关保留在场上且不重复退回库存，避免制造重复机关。
func reset_runtime() -> void:
	# R 完整重置首先取消拖拽：库存预览只删预览；已放置机关先恢复旧格/旧位置/可见性，再由玩家机关清理流程统一删除。
	if is_dragging():
		_cancel_current_drag(false)

	# 递增版本号使已挂起的旧等待回调全部失效，不能再清理或切换 R 后的新状态。
	pulse_generation += 1
	is_level_completed = false
	runtime_moves_used = 0

	clear_light_path()
	_reset_independent_crystals()
	complete_label.visible = false

	var all_player_tokens_returned: bool = _return_all_player_placed_tokens_to_inventory()
	if not all_player_tokens_returned:
		push_error("CoreLoopPrototype: R重置玩家机关清理未完全成功，部分机关已保留在场上且未退回库存。")

	# 状态回 SETUP 必须在玩家机关清理、库存恢复与 UI 刷新之后；reset_to_setup 幂等，已在 SETUP 时不发信号。
	# 机关栏 UI 不依赖该信号唯一触发——_return_all_player_placed_tokens_to_inventory 内部已先行 _update_inventory_ui()。
	_run_state_controller.reset_to_setup()
	_update_runtime_move_ui()

	if OS.is_debug_build():
		_assert_inventory_consistency()


## 将全部可确认清理的玩家放置机关退回库存；返回 true 表示全部完成注销/删除/移除，false 表示至少一个因 OccupancyRegistry 残留引用而未清理。
## 复制 mechanism_id 快照逐个 unregister（必须先快照，遍历中 erase 会改变迭代集合）；不得调用 occupancy.clear()，不得强制修改内部索引——未来可能含预置/静态机关占用，R 只清理 placed_tokens_by_id 登记的玩家机关。
## 异常处理：unregister 失败且无残留引用时继续删除节点回库；仍有残留引用时失败关闭（保留节点与映射、不退回库存）；节点失效但占用已清理时移除映射并回库，节点失效且占用仍残留时不 queue_free、不回库，保留异常事实供一致性断言暴露。
func _return_all_player_placed_tokens_to_inventory() -> bool:
	var mechanism_ids: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(placed_tokens_by_id)
	var all_tokens_returned: bool = true

	for mechanism_id: StringName in mechanism_ids:
		var token: PlaceableToken = placed_tokens_by_id.get(mechanism_id) as PlaceableToken

		var was_unregistered: bool = occupancy.unregister(mechanism_id)
		var has_residual_reference: bool = _occupancy_has_any_reference_to_mechanism(mechanism_id)

		if has_residual_reference:
			all_tokens_returned = false
			push_error(
				"CoreLoopPrototype: R重置无法清理玩家机关占用，机关将保留在场上且不会退回库存：%s"
				% [mechanism_id]
			)
			if not is_instance_valid(token):
				push_error(
					"CoreLoopPrototype: R重置时玩家机关节点已失效且占用仍有残留，保留映射供一致性断言暴露：%s"
					% [mechanism_id]
				)
			continue

		if not was_unregistered and OS.is_debug_build():
			push_warning(
				"CoreLoopPrototype: R重置时玩家机关占用已提前不存在，继续清理玩家节点：%s"
				% [mechanism_id]
			)

		if is_instance_valid(token):
			token.queue_free()
		elif OS.is_debug_build():
			push_error("CoreLoopPrototype: R重置时玩家机关节点已失效：%s" % [mechanism_id])

		placed_tokens_by_id.erase(mechanism_id)

	prototype_token_remaining = _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(
		PROTOTYPE_TOKEN_TOTAL,
		placed_tokens_by_id.size()
	)
	_update_inventory_ui()
	return all_tokens_returned


## 重置普通独立水晶为未点亮；只在 R 完整重置中调用（不由脉冲结束调用），普通独立水晶保持到 R 才恢复。
func _reset_independent_crystals() -> void:
	for crystal: BasicCrystal in crystals:
		crystal.reset_runtime()


## 清除当前光路视觉节点（对 LightPathLayer 子节点 queue_free，实际释放由 Godot 帧流程完成）；只清理视觉层，不修改水晶/完成状态/墙体/库存/占用。
func clear_light_path() -> void:
	for child: Node in light_path_layer.get_children():
		child.queue_free()


## 判断传播方向是否合法：非零且每分量在 -1..1；Vector2i.ZERO、超过一格的方向和非法斜率都会被拒绝。
func is_valid_direction(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 查询指定格子被哪个机关占用（薄包装，转发 _level_world_query.get_mechanism_id_at）；未被占用返回空 StringName（&""），不报错。
func get_mechanism_at(cell: Vector2i) -> StringName:
	return _level_world_query.get_mechanism_id_at(cell)


## 判断指定格子是否被任意机关占用（薄包装，转发 _level_world_query.has_mechanism_at）；空占用表时始终返回 false。
func has_mechanism_at(cell: Vector2i) -> bool:
	return _level_world_query.has_mechanism_at(cell)


## 尝试点亮指定格子上的普通独立水晶；无匹配水晶时安全无效果。不处理颜色/形式/同时组/顺序组，普通独立水晶保持到 R 重置。
func try_activate_crystal_at(cell: Vector2i) -> void:
	for crystal: BasicCrystal in crystals:
		if crystal.cell == cell:
			crystal.activate()


## 判断所有必需水晶是否已点亮；crystals 为空（未配置必需水晶）时输出错误并返回 false，防止误判通关。
func all_required_crystals_activated() -> bool:
	if crystals.is_empty():
		push_error("CoreLoopPrototype: 当前关卡未配置任何必需水晶，不能判定为完成。")
		return false

	for crystal: BasicCrystal in crystals:
		if not crystal.is_activated:
			return false
	return true


## 根据当前水晶状态更新完成状态和完成标签：首次满足条件时置 is_level_completed=true 并显示 CompleteLabel，但运行状态仍保持 PULSE_ACTIVE 到脉冲视觉结束。完成状态和标签保持到 R。
func update_completion_state() -> void:
	if is_level_completed:
		complete_label.visible = true
		return

	if all_required_crystals_activated():
		is_level_completed = true
		complete_label.visible = true
	else:
		complete_label.visible = false


## 为指定格子添加一段光路视觉；direction 仅用于选择四方向纹理，不修改传播逻辑。
## 镜面格只显示入射方向，反射出射方向从下一格开始；同一格允许多个 LightSegmentView 共存，不做去重或对象池；四方向纹理为空时静默回退到黄色占位块。
func add_light_visual(cell: Vector2i, direction: Vector2i) -> void:
	# 冻结算子顺序：实例化 → profile → 方向 → 颜色 → 定位 → add_child。set_* 在 add_child 前调用，此时 @onready 子节点未就绪，
	# refresh_visual() 安全返回；字段已写入，add_child 触发 _ready() 时由 refresh_visual() 统一应用。
	var view: _LightSegmentViewScript = _LightSegmentViewScene.instantiate()
	view.set_profile(_DefaultLightSegmentProfile as _LightSegmentVisualProfile)
	view.set_direction(direction)
	view.set_light_color(LIGHT_PATH_COLOR)
	# 根节点局部原点表示光路格中心，由 LightSegmentView 内部 offset 居中。
	view.position = _GridCoordinateRules.cell_to_world(cell)
	light_path_layer.add_child(view)


## 处理鼠标左键拖拽与右键镜面朝向配置：左键按运行权限开始库存拖拽或已放置机关拖起，松开时提交/回收/取消；右键仅 SETUP 且未拖拽时切换已放置镜面 orientation。
## 其他按键忽略；运行期内部配置锁定，右键不改镜面方向；COMPLETED 冻结全部交互；InventoryBar 区域阻止右键穿透到世界镜面。
func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_try_toggle_mirror_at_mouse()
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed:
		_try_begin_drag()
		return

	if is_dragging():
		_finish_drag_at_mouse()


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
	if mechanism_id == &"" or not placed_tokens_by_id.has(mechanism_id):
		return

	var token: Variant = placed_tokens_by_id[mechanism_id]
	if not is_instance_valid(token):
		return
	if token is not SingleCellMirror:
		return
	var mirror: SingleCellMirror = token as SingleCellMirror
	mirror.toggle_orientation()


## 尝试根据鼠标位置开始一次拖拽。库存拿取在所有非 COMPLETED 状态允许；已放置机关拖起由 _can_begin_placed_drag 限制（与剩余次数分离），remaining=0 仍允许拖起以便回收/取消，跨格提交由 _commit_placed_drag_or_cancel 二次校验。
## 整个 InventoryBar 阻止点击传递到世界机关，空白区域不换算世界格子/查询占用/启动拖拽；COMPLETED 冻结并拒绝一切新拖拽。
func _try_begin_drag() -> void:
	if is_dragging():
		return
	if not can_edit_layout():
		return

	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	if _is_mouse_over_prototype_slot(viewport_mouse_position):
		# 库存拿取权限：所有非 COMPLETED 状态允许从机关栏拿取新机关（用户最终权限）。
		if prototype_token_remaining > 0 and _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state()):
			_begin_inventory_drag()
		elif OS.is_debug_build() and not _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state()):
			print_debug("CoreLoopPrototype: 当前运行状态禁止从机关栏拿取：%s。" % [_get_current_run_state()])
		return
	if _is_mouse_over_inventory_bar(viewport_mouse_position):
		return

	var target_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	var mechanism_id: StringName = get_mechanism_at(target_cell)
	if mechanism_id == &"":
		return
	if not placed_tokens_by_id.has(mechanism_id):
		return
	# 已放置机关拖起权限：所有非 COMPLETED 状态允许拖起（与跨格提交权限分离）。
	# 剩余次数为 0 时仍允许拖起，以便回收或取消；跨格提交由 _commit_placed_drag_or_cancel 的二次校验拒绝。
	# 失败时不创建预览、不隐藏正式机关、不改占用与库存。
	if not _RuntimeMoveRules.can_begin_placed_drag(_get_current_run_state()):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态不允许拖起已放置机关：%s。" % [_get_current_run_state()])
		return
	_begin_placed_drag(mechanism_id, target_cell)


## 从机关栏开始一次基础单格镜面拖拽；创建默认 SLASH 朝向的预览节点，拖拽来源设为 INVENTORY。从库存拖拽但不提前扣数量，非法松手或松回机关栏时库存和占用都不变化。
func _begin_inventory_drag() -> void:
	var start_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	_drag_source = _RuntimeInteractionTypes.DragSource.INVENTORY
	_drag_mechanism_id = &""
	_drag_original_cell = INVALID_CELL
	_drag_preview_cell = start_cell
	_dragged_placed_token = null
	# 只有合法松手提交后才减少 prototype_token_remaining；新拿出的镜面默认 SLASH。
	_drag_preview_token = _create_token_node(StringName("preview_%s" % MIRROR_TOKEN_TYPE_ID), start_cell, true)
	_update_drag_preview_from_mouse()


## 从已放置机关开始一次拖拽移动；检查通过后隐藏正式视觉、创建预览并记录原始占用。返回 false 表示一致性检查失败，未进入拖拽、未创建预览、未隐藏节点。
## 写入拖拽字段前必须先确认 placed_tokens_by_id 存在该 ID、节点有效、mechanism_id 与 cell 与参数一致；任一失败输出错误并返回 false。拖拽期间保留旧逻辑占用，预览不写入 OccupancyRegistry，非法松手恢复正式节点。
func _begin_placed_drag(mechanism_id: StringName, original_cell: Vector2i) -> bool:
	# 写入拖拽字段前完成全部一致性检查，避免半写入或对失效节点解引用。
	if not placed_tokens_by_id.has(mechanism_id):
		push_error("CoreLoopPrototype: 拖起失败，placed_tokens_by_id 缺少机关 %s。" % [mechanism_id])
		return false
	var token: Variant = placed_tokens_by_id[mechanism_id]
	if not is_instance_valid(token):
		push_error("CoreLoopPrototype: 拖起失败，机关 %s 节点已失效。" % [mechanism_id])
		return false
	if token.mechanism_id != mechanism_id:
		push_error("CoreLoopPrototype: 拖起失败，机关 ID 失配：参数=%s，节点=%s。" % [mechanism_id, token.mechanism_id])
		return false
	if token.cell != original_cell:
		push_error("CoreLoopPrototype: 拖起失败，机关 %s cell 失配：参数=%s，节点=%s。" % [mechanism_id, original_cell, token.cell])
		return false
	_drag_source = _RuntimeInteractionTypes.DragSource.PLACED
	_drag_mechanism_id = mechanism_id
	_drag_original_cell = original_cell
	_drag_preview_cell = original_cell
	_dragged_placed_token = token
	# 拖拽期间保留旧逻辑占用，只隐藏正式视觉，松手后再原子更新；预览复制当前镜面朝向。
	_dragged_placed_token.set_placed_visible(false)
	_drag_preview_token = _create_token_node(mechanism_id, original_cell, true)
	_copy_mirror_orientation_if_possible(_dragged_placed_token, _drag_preview_token)
	_update_drag_preview_from_mouse()
	return true


## 根据鼠标位置更新拖拽预览：位于 InventoryBar 时只隐藏世界预览（不把 UI 坐标转成虚假地图格子），离开后恢复显示、吸附 cell_to_world 格中心，按空间合法性与松手提交权限刷新合法/非法颜色。
## 隐藏预览不等于取消拖拽；预览颜色只是视觉反馈，不替代正式提交的二次校验。
func _update_drag_preview_from_mouse() -> void:
	if not is_dragging() or _drag_preview_token == null:
		return

	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	if _is_mouse_over_inventory_bar(viewport_mouse_position):
		_drag_preview_token.set_drag_preview_visible(false)
		return

	_drag_preview_token.set_drag_preview_visible(true)
	_drag_preview_cell = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	# 预览合法性同时反映空间合法性与当前是否允许松手提交；不替代正式提交的二次校验。
	var spatially_valid: bool = _is_valid_prototype_placement_cell(_drag_preview_cell, _drag_mechanism_id)
	var is_valid: bool = _RuntimeMoveRules.is_world_drop_preview_valid(
		_drag_source,
		_get_current_run_state(),
		get_runtime_moves_remaining(),
		_drag_original_cell,
		_drag_preview_cell,
		spatially_valid
	)
	_drag_preview_token.set_cell(_drag_preview_cell)
	_drag_preview_token.set_world_position(_GridCoordinateRules.cell_to_world(_drag_preview_cell))
	_drag_preview_token.set_drag_preview(true, is_valid)


## 在鼠标松开位置完成当前拖拽：根据来源和松手区域执行库存放置、已放置机关移动、拖回机关栏回收或取消。
## 从库存释放回机关栏只取消；只有 PLACED 拖拽可回收，且回收在所有非 COMPLETED 状态允许。COMPLETED 中释放到机关栏改为安全取消，恢复原机关显示与原占用，不增库存、不扣次数。
func _finish_drag_at_mouse() -> void:
	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	var is_released_over_inventory: bool = _is_mouse_over_inventory_bar(viewport_mouse_position)

	if _drag_source == _RuntimeInteractionTypes.DragSource.INVENTORY:
		if is_released_over_inventory:
			_cancel_current_drag()
			return
		_commit_inventory_drag_or_cancel()
		return

	if _drag_source == _RuntimeInteractionTypes.DragSource.PLACED:
		if is_released_over_inventory:
			# 回收在所有非 COMPLETED 状态允许；COMPLETED 释放到机关栏改为安全取消，保留原占用与原位置，不增库存、不扣次数。
			if _RuntimeMoveRules.can_recycle_placed_token_for_state(_get_current_run_state()):
				_recycle_dragged_placed_token()
			else:
				if OS.is_debug_build():
					print_debug("CoreLoopPrototype: 当前运行状态禁止回收，改为取消拖拽并恢复原机关：%s。" % [_get_current_run_state()])
				_cancel_current_drag()
			return
		_commit_placed_drag_or_cancel()


## 提交从库存开始的拖拽，或在非法位置取消：合法时创建正式机关、登记 OccupancyRegistry、库存减一并删除预览；非法时只删除预览（库存和占用不变化）。
## 提交前防御性重检 _can_take_from_inventory_for_state：COMPLETED/未知状态取消拖拽，不扣库存、不创建正式机关、不登记占用。运行期首次放置不消耗 runtime_moves_used。
func _commit_inventory_drag_or_cancel() -> void:
	# 首次放置在所有非 COMPLETED 状态允许；COMPLETED/未知状态取消拖拽，不扣库存、不创建正式机关。
	if not _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state()):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态禁止首次放置，取消库存拖拽：%s。" % [_get_current_run_state()])
		_cancel_current_drag()
		return
	if not _is_valid_prototype_placement_cell(_drag_preview_cell, &""):
		# 非法位置取消：不扣库存、不写占用、不留残影。
		_cancel_current_drag()
		return
	if prototype_token_remaining <= 0:
		_cancel_current_drag()
		return

	var mechanism_id: StringName = _make_next_prototype_token_id()
	if not occupancy.register_single_cell(mechanism_id, _drag_preview_cell):
		push_error("CoreLoopPrototype: 原型机关登记占用失败：%s at %s" % [mechanism_id, _drag_preview_cell])
		_cancel_current_drag()
		return

	var placed_token = _create_token_node(mechanism_id, _drag_preview_cell, false)
	placed_tokens_by_id[mechanism_id] = placed_token
	prototype_token_remaining -= 1
	_update_inventory_ui()
	_clear_drag_preview_only()
	_reset_drag_state()
	_assert_inventory_consistency()


## 提交已放置机关移动，或在非法位置/原格松手时取消：合法新格时原子清除旧占用并登记新占用，更新正式机关节点；非法时恢复原节点可见性。
## 原格松手视为取消，库存不变；新占用提交失败必须尝试恢复原占用和原位置。
## 提交前二次校验：修改 OccupancyRegistry 前重新验证节点有效、mechanism_id/from_cell 仍正确、to_cell 仍合法、状态与剩余次数仍允许提交；失败安全取消并恢复原机关，不注销旧占用、不登记新占用、不扣次数。
## 运行期扣次：仅 PULSE_ACTIVE/MOVE_WINDOW 且跨格成功提交后扣一次 runtime_moves_used；SETUP、非法、原格、取消与回滚均在此前 return。
func _commit_placed_drag_or_cancel() -> void:
	if _drag_preview_cell == _drag_original_cell:
		_cancel_current_drag()
		return
	if not _is_valid_prototype_placement_cell(_drag_preview_cell, _drag_mechanism_id):
		# 非法移动取消：旧占用从拖拽开始到取消一直保留，正式机关只需恢复显示。
		_cancel_current_drag()
		return

	var token = _dragged_placed_token
	var mechanism_id: StringName = _drag_mechanism_id
	var from_cell: Vector2i = _drag_original_cell
	var to_cell: Vector2i = _drag_preview_cell

	# 提交前第二次校验：状态转换或次数变化后正式提交前重新确认整次移动仍合法；失败安全取消，保留原占用，不扣次数。
	if not is_instance_valid(token):
		push_error("CoreLoopPrototype: 提交移动前拖拽节点已失效，取消拖拽。")
		_cancel_current_drag()
		return
	# 拖拽期间正式节点只隐藏未移动，cell 应仍在 from_cell。
	if token.mechanism_id != mechanism_id or token.cell != from_cell:
		push_error("CoreLoopPrototype: 提交移动前拖拽节点状态不一致，取消拖拽。")
		_cancel_current_drag()
		return
	if not _is_valid_prototype_placement_cell(to_cell, mechanism_id):
		_cancel_current_drag()
		return
	if not _RuntimeMoveRules.can_commit_placed_move(_get_current_run_state(), get_runtime_moves_remaining(), from_cell, to_cell):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 提交前二次校验拒绝移动：%s remaining=%d %s->%s。" % [_get_current_run_state(), get_runtime_moves_remaining(), from_cell, to_cell])
		_cancel_current_drag()
		return

	# 原子更新：先清除旧占用再登记新占用；失败必须恢复旧格，避免旧占用和新占用同时丢失。
	if not occupancy.unregister(mechanism_id):
		push_error("CoreLoopPrototype: 移动前旧占用不存在，恢复原机关。")
		_cancel_current_drag()
		return
	if not occupancy.register_single_cell(mechanism_id, to_cell):
		push_error("CoreLoopPrototype: 新占用登记失败，尝试恢复旧占用：%s -> %s" % [from_cell, to_cell])
		if not occupancy.register_single_cell(mechanism_id, from_cell):
			push_error("CoreLoopPrototype: 恢复旧占用失败，停止继续修改。")
		token.set_cell(from_cell)
		token.set_world_position(_GridCoordinateRules.cell_to_world(from_cell))
		token.set_placed_visible(true)
		_clear_drag_preview_only()
		_reset_drag_state()
		_assert_inventory_consistency()
		return

	token.set_cell(to_cell)
	token.set_world_position(_GridCoordinateRules.cell_to_world(to_cell))
	token.set_placed_visible(true)
	_clear_drag_preview_only()
	_reset_drag_state()
	_assert_inventory_consistency()
	# 占用原子更新与节点提交都成功后才扣一次；SETUP 跨格移动不计次，非法/原格/取消/回滚/新占用登记失败不会到达本处。
	if _RuntimeMoveRules.should_count_runtime_move(_get_current_run_state(), from_cell, to_cell):
		runtime_moves_used += 1
		_update_runtime_move_ui()


## 回收当前从已放置机关拖拽的原型机关：注销占用、移除映射、删除正式与预览节点、库存加一（不超过 PROTOTYPE_TOKEN_TOTAL）并刷新 UI。
## 只有 PLACED 拖拽可回收；内部含防御性 _can_recycle_placed_token_for_state 检查，COMPLETED/未知状态安全取消并恢复原机关，不依赖外层单一守卫。运行期回收不消耗 runtime_moves_used；注销失败时恢复正式机关并取消拖拽。
func _recycle_dragged_placed_token() -> void:
	if _drag_source != _RuntimeInteractionTypes.DragSource.PLACED or _dragged_placed_token == null:
		_cancel_current_drag()
		return
	# 防御性权限检查：COMPLETED/未知状态即使直接调用本函数也安全取消，不增库存。
	if not _RuntimeMoveRules.can_recycle_placed_token_for_state(_get_current_run_state()):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态禁止回收，安全取消并恢复原机关：%s。" % [_get_current_run_state()])
		_cancel_current_drag()
		return

	# 整个 InventoryBar 都是有效回收区域，不要求精准松回小栏位。
	if not occupancy.unregister(_drag_mechanism_id):
		push_error("CoreLoopPrototype: 回收时注销占用失败，恢复原机关。")
		_cancel_current_drag()
		return

	placed_tokens_by_id.erase(_drag_mechanism_id)
	_dragged_placed_token.queue_free()
	prototype_token_remaining = min(PROTOTYPE_TOKEN_TOTAL, prototype_token_remaining + 1)
	_update_inventory_ui()
	_clear_drag_preview_only()
	_reset_drag_state()
	_assert_inventory_consistency()


## 取消当前拖拽并恢复拖拽前状态：删除预览；已放置机关且节点有效则恢复原位置和可见性；随后清空拖拽状态字段。
## should_assert_consistency：普通取消默认 true；R 完整重置传 false，把断言延后到玩家机关统一清理完成之后，避免中间态断言早于后续删除/注销。
## 从库存取消不改变库存；已放置机关取消不改变 OccupancyRegistry（旧占用从未清除）。_dragged_placed_token 已失效时不再解引用，只清理预览与状态并在调试构建报告一致性异常，不静默重建映射或占用。
func _cancel_current_drag(should_assert_consistency: bool = true) -> void:
	if _drag_source == _RuntimeInteractionTypes.DragSource.PLACED and _dragged_placed_token != null:
		if is_instance_valid(_dragged_placed_token):
			# 拖拽期间保留旧逻辑占用，取消时只恢复正式视觉。
			_dragged_placed_token.set_cell(_drag_original_cell)
			_dragged_placed_token.set_world_position(_GridCoordinateRules.cell_to_world(_drag_original_cell))
			_dragged_placed_token.set_placed_visible(true)
		elif OS.is_debug_build():
			# 失效节点不得再次解引用；仅报告一致性异常，不静默重建占用或映射。
			push_error("CoreLoopPrototype: 取消拖拽时已放置机关节点已失效，未恢复视觉，请检查 placed_tokens_by_id 与 OccupancyRegistry 一致性。")
	_clear_drag_preview_only()
	_reset_drag_state()
	if should_assert_consistency:
		_assert_inventory_consistency()


## 删除当前拖拽预览节点；预览为空时安全返回，不修改正式机关、库存或占用表。
func _clear_drag_preview_only() -> void:
	if _drag_preview_token != null:
		_drag_preview_token.queue_free()
		_drag_preview_token = null


## 清空当前拖拽状态字段；只在预览删除和正式机关状态已处理后调用，避免丢失恢复所需的原始格子信息。
func _reset_drag_state() -> void:
	_drag_source = _RuntimeInteractionTypes.DragSource.NONE
	_drag_mechanism_id = &""
	_drag_original_cell = INVALID_CELL
	_drag_preview_cell = INVALID_CELL
	_dragged_placed_token = null


## 创建一个 SingleCellMirror 节点并加入 RuntimeObjects；世界坐标由 cell_to_world() 统一计算。不写库存、不写 OccupancyRegistry、不判断放置合法性；新建镜面默认 SLASH，拖动已有镜面由调用方复制原 orientation。
func _create_token_node(mechanism_id: StringName, cell: Vector2i, is_preview: bool) -> Variant:
	var token = _SingleCellMirrorScene.instantiate()
	runtime_objects.add_child(token)
	token.configure(mechanism_id, cell)
	token.set_world_position(_GridCoordinateRules.cell_to_world(cell))
	token.set_drag_preview(is_preview, true)
	return token


## 在两个镜面节点间复制朝向配置（拖动已有镜面时让预览保留当前“/”或“\”）；任一节点不是镜面则安全忽略，避免未来未知机关拖拽崩溃。只复制内部配置，不写占用/库存/位置。
func _copy_mirror_orientation_if_possible(source_token: Variant, target_token: Variant) -> void:
	if not is_instance_valid(source_token) or not is_instance_valid(target_token):
		return
	if source_token is not SingleCellMirror or target_token is not SingleCellMirror:
		return
	var source_mirror: SingleCellMirror = source_token as SingleCellMirror
	var target_mirror: SingleCellMirror = target_token as SingleCellMirror
	target_mirror.set_orientation(source_mirror.orientation)


## 生成下一个正式镜面机关唯一 ID；即使镜面被回收，旧 ID 不复用，避免占用表和节点映射调试时混淆。
func _make_next_prototype_token_id() -> StringName:
	var mechanism_id: StringName = StringName("%s_%d" % [MIRROR_TOKEN_TYPE_ID, _next_prototype_token_serial])
	_next_prototype_token_serial += 1
	return mechanism_id


## 是否存在拖拽操作（_drag_source != NONE）；预览节点可能因异常被释放，仍只以拖拽来源作为状态事实。
func is_dragging() -> bool:
	return _drag_source != _RuntimeInteractionTypes.DragSource.NONE


## 鼠标是否位于整个 InventoryBar 区域；用于回收判断，不要求精准拖到单个栏位。
func _is_mouse_over_inventory_bar(viewport_mouse_position: Vector2) -> bool:
	return inventory_bar.get_global_rect().has_point(viewport_mouse_position)


## 鼠标是否位于 PrototypeTokenSlot 区域；只用于从库存拿取，数量为 0 时即使命中也不会开始拖拽。
func _is_mouse_over_prototype_slot(viewport_mouse_position: Vector2) -> bool:
	return prototype_token_slot.get_global_rect().has_point(viewport_mouse_position)


## 原型机关是否可放到指定格子（薄包装，转发 _level_world_query.is_valid_placement_cell）；INVALID_CELL 永远非法，本函数保留该哨兵外层守卫，其余边界/静态/占用判定由查询对象组合。
func _is_valid_prototype_placement_cell(cell: Vector2i, ignored_mechanism_id: StringName = &"") -> bool:
	if cell == INVALID_CELL:
		return false
	return _level_world_query.is_valid_placement_cell(cell, ignored_mechanism_id)


## 目标格是否被静态对象阻挡（薄包装，转发 _level_world_query.is_static_blocked_for_placement）；集中不可覆盖的静态对象规则。
func _is_static_cell_blocked_for_placement(cell: Vector2i) -> bool:
	return _level_world_query.is_static_blocked_for_placement(cell)


## 目标格是否被其他机关占用（薄包装，转发 _level_world_query.is_occupied_by_other）；空占用返回 false，拖动已放置机关时原格自身占用可被忽略。
func _is_cell_occupied_by_other(cell: Vector2i, ignored_mechanism_id: StringName) -> bool:
	return _level_world_query.is_occupied_by_other(cell, ignored_mechanism_id)


## 刷新底部机关栏 UI：把库存剩余与是否允许拿取传给 InventorySlotView.refresh_slot()，由槽位组件统一负责剩余文本/占位符颜色/图标 self_modulate。UI 只显示库存事实，不自行修改库存。
func _update_inventory_ui() -> void:
	# 拿取可用性：库存大于 0 且当前运行状态允许从机关栏拿取（非 COMPLETED）。
	var is_available: bool = (
		prototype_token_remaining > 0
		and _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state())
	)
	prototype_token_slot.refresh_slot(
		prototype_token_remaining,
		is_available
	)


## 采集库存一致性只读纯数据快照：冻结库存标量、OccupancyRegistry 本体一致性标志与六组对齐的条目级事实。
## D 类 Node 生命周期检查（is_instance_valid、is_queued_for_deletion）保留在本函数不迁入 Diagnostics，验证通过后才读取 token.mechanism_id 与 token.cell；不把真实 Node 传给 Snapshot/Rules/Check，不把生命周期状态写进 Snapshot。
## 六组容器按 placed_tokens_by_id 当前迭代顺序严格同步追加，不排序、不去重，不修改 OccupancyRegistry 返回数组；is_consistent() 每次只调用一次，不在核心复制其内部算法；count==0 时 first_cell 用 Vector2i.ZERO 占位（规则只在 count==1 时比较）。
func _collect_inventory_consistency_snapshot() -> _InventoryConsistencySnapshot:
	var dictionary_ids: Array[StringName] = []
	var token_ids: Array[StringName] = []
	var token_cells: Array[Vector2i] = []
	var occupancy_ids_at_token_cells: Array[StringName] = []
	var occupancy_cell_counts: PackedInt32Array = PackedInt32Array()
	var occupancy_first_cells: Array[Vector2i] = []

	for mechanism_id: StringName in placed_tokens_by_id:
		var token: Variant = placed_tokens_by_id[mechanism_id]
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
			PROTOTYPE_TOKEN_TOTAL,
			prototype_token_remaining,
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


## 库存一致性启动期自检（_ready 第七项）；复用共享纯规则 InventoryConsistencyRules 与只读快照，采集快照构造 InventoryConsistencyCheck 包装为 SelfCheckCallable 交由 _run_startup_self_check_via_controller。启动采集前的 Node 生命周期保护仍在 _collect_inventory_consistency_snapshot 中。
func _run_inventory_consistency_self_check() -> void:
	var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
	var check: _InventoryConsistencyCheck = _InventoryConsistencyCheck.new(snapshot)
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"inventory_consistency",
			"库存与玩家机关占用一致性自检",
			Callable(check, "run")
	)
	_run_startup_self_check_via_controller(definition, &"startup_inventory_consistency")
