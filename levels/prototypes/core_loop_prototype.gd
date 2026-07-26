extends Node2D

## 核心闭环原型关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入、发起普通主发射源的最小脉冲光线、
## 用 Vector2i 计算路径、查询墙体与边界、通过 OccupancyRegistry 解析单格镜面并在光进入镜面格后更新传播方向、通知普通独立水晶点亮、
## 判断并保持关卡完成结果、在脉冲结束时只清理光路视觉、在 R 完整关卡重置时清除光路、水晶、完成状态、运行次数并将全部玩家放置机关退回库存；
## 持有轻量占用表 OccupancyRegistry，提供“格子—机关”统一查询入口，并实现最小镜面库存、拖拽放置、移动、回收与 SETUP 右键朝向配置。
## 最小运行状态职责：在当前原型内保存 SETUP、PULSE_ACTIVE、MOVE_WINDOW、COMPLETED。
## 正式运行权限：SETUP 允许完整布置（拿取、首次放置、移动、回收、右键配置）且移动不计次；
## PULSE_ACTIVE 与 MOVE_WINDOW 同样允许拿取、首次放置、移动与回收，但右键配置锁定、PULSE_ACTIVE 禁止 Space；只有"已放置机关跨格直接移动"在成功提交后消耗 runtime_move_limit 一次，拿取/首次放置/回收均不消耗次数；
## COMPLETED 冻结全部关卡交互，只允许 R。已知临时边界：当前 runtime_move_limit 只限制已有机关从世界格 A 直接移动到世界格 B，运行期回收后重新放置不消耗直接移动次数；单纯 MoveRequest 不能自动解决该问题，后续需要机关身份跨库存保留或运行期迁移事务规则，本阶段如实记录，不改变用户确认的拿取和回收权限。
## R 是完整关卡重置：安全取消拖拽，正常情况下删除全部玩家放置机关，逐个注销玩家机关 OccupancyRegistry 占用，清空 placed_tokens_by_id，恢复完整库存，清零 runtime_moves_used，重置光路、水晶和完成状态并返回 SETUP；若检测到 OccupancyRegistry 残留且无法通过公共 unregister 接口确认清理，相关机关会保留在场上且不会重复退回库存，以避免制造重复机关；不删除发射器、墙体、水晶或未来关卡静态内容。R 后重新从库存拿出的镜面使用 single_cell_mirror.tscn 默认 SLASH 朝向。
## 依赖：OccupancyRegistry（gameplay/placement/occupancy_registry.gd）、BasicCrystal 的 activate() / reset_runtime()、SingleCellMirror 场景。
## 运行期移动次数职责：由本关卡控制器持有 runtime_move_limit / runtime_moves_used，remaining = max(limit - used, 0)；
## 开始拖拽与提交移动均做权限检查，提交前在修改 OccupancyRegistry 之前再次校验状态与剩余次数，成功原子提交后才扣次；
## SETUP 移动不计次，失败、取消、原格松手、回滚均不扣。RuntimeMoveLabel 只显示剩余 / 上限，不直接修改次数。
## 当前普通光线原型采用同步提交前二次校验与 OccupancyRegistry 原子迁移，已满足第二阶段安全要求；当前不是 deferred 批次系统。
## 正式 MoveRequest 请求队列延后到光粒/Tick 传播引入时实现，不得把 MoveRequest 写成第二阶段未完成阻塞项，本分支不引入第二套移动次数系统。
## 不负责：分光、颜色、光粒、成就、存档、正式关卡加载、MoveRequest 请求队列、Tick 批次提交、完整 RunStateController、
## 同时组、顺序组、通用水晶条件系统或正式机关继承体系。
## 光路判定完全基于 Vector2i 格子坐标，不使用 Area2D 碰撞、Tween 或物理射线检测作为核心逻辑。


## 基本参数
# 世界格尺寸唯一来源：preload 共享常量模块，避免 64 世界格尺寸分散手写；不加 class_name 以避开 MCP 全局类型缓存问题。
const GridMetrics: GDScript = preload("res://gameplay/grid/grid_metrics.gd")
# 当前原型在正式 TileMapLayer 接管坐标转换前，统一通过 GridMetrics.CELL_SIZE 做格↔世界换算；64 世界格对应半格 32。
const CELL_SIZE: int = GridMetrics.CELL_SIZE
# 格↔世界纯换算规则共享模块（批次 4B-E2）：cell_to_world / world_to_cell 已迁出本脚本，统一通过此 preload 调用，
# 避免坐标公式在关卡控制器与网格坐标自检之间重复维护；新 class_name 缓存未刷新时仍通过 preload 引用。
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const MAX_PROPAGATION_STEPS: int = 128
const PULSE_VISUAL_DURATION_SECONDS: float = 1.0
const PROTOTYPE_TOKEN_TOTAL: int = 1
const MIRROR_TOKEN_TYPE_ID: StringName = &"basic_single_cell_mirror"
const INVALID_CELL: Vector2i = Vector2i(-999999, -999999)

## 原型光路视觉颜色：当前普通脉冲光路的黄色显示色。
## 仅用于 LightSegmentView 的占位块 color 与正式纹理 self_modulate 调制，不参与任何 RGB 玩法逻辑。
const LIGHT_PATH_COLOR: Color = Color(1.0, 0.95, 0.2, 0.75)

@export var emitter_cell: Vector2i = Vector2i(1, 3)
@export var emitter_direction: Vector2i = Vector2i.RIGHT
@export var map_bounds: Rect2i = Rect2i(0, 0, 16, 16)
@export var wall_cells: Array[Vector2i] = [Vector2i(5, 3)]

## 运行期移动次数上限。仅在 PULSE_ACTIVE 或 MOVE_WINDOW 中成功跨格移动已放置机关时消耗；SETUP 移动不受此限制。
@export_range(0, 99, 1) var runtime_move_limit: int = 1

# terrain_layer 保留以满足 plan §3.1 / step 5 的节点树与成员约定；
# 当前核心闭环原型不使用 TileSet，格↔世界换算由 GridCoordinateRules 用 CELL_SIZE 常量实现，不依赖 map_to_local。
@onready var terrain_layer: TileMapLayer = $TerrainLayer
@onready var runtime_objects: Node2D = $RuntimeObjects
@onready var light_path_layer: Node2D = $LightPathLayer
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var complete_label: Label = $CanvasLayer/CompleteLabel
@onready var inventory_bar: Control = $CanvasLayer/InventoryBar
@onready var prototype_token_slot: _InventorySlotViewScript = $CanvasLayer/InventoryBar/MarginContainer/HBoxContainer/PrototypeTokenSlot
@onready var runtime_move_label: Label = $CanvasLayer/RuntimeMoveLabel
@onready var crystals: Array[BasicCrystal] = [$RuntimeObjects/Crystal]

## 轻量机关占用表：格子坐标 ↔ 机关 ID 的双向索引。
## 本阶段用于基础单格镜面放置、移动、回收和传播循环中的镜面节点解析。
# 用 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析。
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
# 批次 4B-B1 抽离的两项启动自检模块；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
# 批次 4B-B2 起，两项检查通过单项 SelfCheckRunner 执行；核心脚本不再直接调用 run()，但仍保留 Debug 硬断言边界。
const _OccupancyRegistryCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/occupancy_registry_check.gd")
const _MirrorReflectionCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/mirror_reflection_check.gd")
# 批次 4B-C2 抽离的玩家机关 ID 快照自检模块；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
const _PlayerMechanismIdSnapshotCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/player_mechanism_id_snapshot_check.gd")
# 批次 4B-D4 抽离的运行期移动规则自检模块；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
const _RuntimeMoveCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/runtime_move_check.gd")
# 批次 4B-E3 抽离的网格坐标启动自检模块；持有只读采样快照，用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
const _GridCoordinateCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/grid_coordinate_check.gd")
# 批次 4B-F3 抽离的运行状态纯规则启动自检模块；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
const _RuntimeStateCheck: GDScript = preload("res://gameplay/diagnostics/self_check/checks/runtime_state_check.gd")
# 批次 4B-G4 接入的库存一致性只读纯数据快照、共享纯规则与启动期自检模块；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题。
# 运行期 _assert_inventory_consistency() 与启动期 _run_inventory_consistency_self_check() 共用同一采集函数与同一规则来源，A/B/C 规则不在核心中保留副本。
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)
const _InventoryConsistencyRules: GDScript = preload(
	"res://gameplay/placement/rules/inventory_consistency_rules.gd"
)
const _InventoryConsistencyCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/inventory_consistency_check.gd"
)
# 批次 5A-H3：诊断控制器（Diagnostics 最外层协调器）。核心只持有一个实例，统一协调七项启动自检的执行；
# Controller 每次调用内部新建 SelfCheckRunner 并返回 SelfCheckRunResult，不执行 assert，失败策略仍由核心决定。
# 用 preload 引用以避开 MCP run_project 不重建全局 class_name 缓存的问题，同时作为本脚本内强类型注解。
const _DiagnosticsController: GDScript = preload(
	"res://gameplay/diagnostics/diagnostics_controller.gd"
)
# 批次 5A-H4：启动摘要日志所需的等级与条目数据契约；用 preload 引用以避开 MCP run_project 不重建全局 class_name 缓存的问题。
# 核心只构造 DiagnosticLogEntry 并通过 DiagnosticsController.write_entry_to_file 落盘，不直接 new RuntimeLogger，不接入 RuntimeSnapshotData。
const _DiagnosticSeverity: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_severity.gd"
)
const _DiagnosticLogEntry: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_log_entry.gd"
)
# 批次 4B-C2 抽离的玩家机关 R 重置共享纯规则；正式 R 重置与自检共用同一玩法层规则来源。
const _PlayerMechanismResetRules: GDScript = preload("res://gameplay/placement/rules/player_mechanism_reset_rules.gd")
const _SingleCellMirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
# InventorySlotView 是本批新增 class_name 脚本；用 preload 引用以避开 MCP run_project 不重建全局类型缓存的问题，
# 使 prototype_token_slot 拥有等效静态类型引用，可直接调用 refresh_slot()。
const _InventorySlotViewScript: GDScript = preload("res://gameplay/ui/inventory_slot_view.gd")
# LightSegmentView / LightSegmentVisualProfile 是 B2 批新增 class_name 脚本；同样用 preload 引用以避开 MCP run_project 全局类型缓存问题。
const _LightSegmentViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _LightSegmentViewScene: PackedScene = preload("res://gameplay/visuals/light_segments/light_segment_view.tscn")
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
# 批次 4B-D2 抽离的运行交互共享类型契约（RunState / DragSource）；用 preload 路径引用以避开 MCP run_project 不重建全局类型缓存的问题，
# 嵌套枚举一律通过本常量限定访问，不依赖全局 class_name 缓存。
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
# 批次 4B-D3-B 抽离的运行期移动纯规则共享模块；正式玩法调用与 runtime_move 启动自检共用同一规则来源。
# 用 preload 路径引用以避开 MCP run_project 不重建全局类型缓存的问题，新 class_name 缓存可能尚未刷新，必须通过本常量调用。
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
# 批次 4B-F2 抽离的运行状态纯规则共享模块；正式玩法查询与 post_pulse_state 启动自检共用同一规则来源。
# 用 preload 路径引用以避开 MCP run_project 不重建全局类型缓存的问题，新 class_name 缓存可能尚未刷新，必须通过本常量调用。
const _RuntimeStateRules: GDScript = preload("res://gameplay/interaction/runtime_state_rules.gd")
# 阶段 02A 批次 3A：运行状态控制器 RunStateController。核心持有的唯一运行状态所有者，负责四态事实、最小合法转换与 state_changed 信号。
# 用 preload 路径引用以避开 MCP run_project 不重建全局 class_name 缓存的问题；与 _DiagnosticsController 一致以 const 作静态类型注解，不加入场景树、不 add_child、不设为 Autoload。
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
# 默认光线路段视觉资源（四字段全空 → 运行时由 LightSegmentView 静默回退到黄色占位块）。
# 以 Resource 类型 preload，调用 set_profile 时再 as 为 profile 脚本类型，避免常量类型解析对全局类型缓存的依赖。
const _DefaultLightSegmentProfile: Resource = preload("res://assets/visual_profiles/basic_light_segment_visuals.tres")
var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()

## 当前运行是否已经完成关卡。
## 与光路视觉生命周期分离；普通独立水晶和完成结果都保持到 R 重置。
## 命中时可先于运行状态变为 true，运行状态会在脉冲视觉结束后由 RunStateController 进入 COMPLETED。
var is_level_completed: bool = false

## 当前脉冲版本号。
## 每次开始脉冲或 R 重置都会递增，用于让旧的异步等待回调失效，避免误清理新脉冲。
var pulse_generation: int = 0

## 原型单格机关库存剩余数量。
## 只在成功从库存放置后减少，只在拖回机关栏回收后增加；拖拽开始时不提前扣数量。
var prototype_token_remaining: int = PROTOTYPE_TOKEN_TOTAL

## 运行期已使用移动次数。仅在 PULSE_ACTIVE 或 MOVE_WINDOW 中成功跨格移动已放置机关后递增；R 重置清零。
## runtime_move_limit 是上限，runtime_moves_used 是已用，remaining = max(limit - used, 0) 是运行期可提交的已有机关跨格直接移动配额。remaining=0 不禁止拖起（拖起仍承担取消和回收），只禁止提交到另一个世界格。
var runtime_moves_used: int = 0

## 玩家已放置原型机关 ID → PlaceableToken 节点。
## 格子是否被占用仍以 OccupancyRegistry 为唯一事实来源，本映射只用于找到正式视觉节点。
var placed_tokens_by_id: Dictionary[StringName, Variant] = {}

var _next_prototype_token_serial: int = 1
var _drag_source: _RuntimeInteractionTypes.DragSource = _RuntimeInteractionTypes.DragSource.NONE
var _drag_mechanism_id: StringName = &""
var _drag_original_cell: Vector2i = INVALID_CELL
var _drag_preview_cell: Vector2i = INVALID_CELL
var _drag_preview_token: Variant = null
var _dragged_placed_token: Variant = null

## 诊断控制器（批次 5A-H3）：核心持有的唯一 DiagnosticsController 实例，仅用于协调七项启动自检的执行。
## Controller 只负责每次调用内部新建 SelfCheckRunner 并返回 SelfCheckRunResult；核心仍决定启动失败时的 Debug 硬 assert。
## 真实样本仍由各包装函数采集后构造 SelfCheckCallable 传入；运行期库存断言不经过本 Controller。
## 不作为 Node、不 add_child、不设为 Autoload、不传入 core_loop；本批不调用其 Logger 或 Snapshot 接口。
var _diagnostics_controller: _DiagnosticsController = _DiagnosticsController.new()

## 运行状态控制器（阶段 02A 批次 3A）：核心持有的唯一运行状态所有者。
## 四态事实、最小合法转换与 state_changed 信号全部由它负责；核心不再持有 current_run_state 事实字段，也不保留同步/缓存副本。
## 核心仍负责业务副作用（取消拖拽、pulse_generation、is_level_completed、光路/水晶/占用清理、库存、UI 刷新、R 完整重置）。
## state_changed 在 Controller 状态字段更新后发出；COMPLETED 前取消拖拽必须在请求转换前由核心完成；generation 仍由核心保护异步回调。
## 当前不包含 READY_TO_FIRE 或任何第五态。不作为 Node、不 add_child、不设为 Autoload。
var _run_state_controller: _RunStateController = _RunStateController.new()


## 初始化核心闭环原型关卡。
## [br]本函数无参数、无返回值。
## [br]副作用：刷新机关栏 UI；仅在调试构建中执行 OccupancyRegistry、64 像素逻辑格坐标换算、基础单格镜面反射、运行状态、运行期移动次数、玩家机关 ID 快照和库存一致性断言。
## 自检结束后真实占用表、运行状态、布局编辑权限、水晶、玩家布局、镜面朝向和完成标签不被改变。
## [br]边界条件：发布构建不执行自检，避免把调试断言作为运行期必需流程。
func _ready() -> void:
	# 早期连接运行状态信号：在任何可能依赖状态 UI 的初始化之前连接，避免错过首次状态变化。
	# 当前场景只执行一次 _ready()；state_changed 在 Controller 状态字段更新后发出，本回调只刷新机关栏 UI。
	_run_state_controller.state_changed.connect(_on_run_state_changed)
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
		# 批次 5A-H4：只有第七项（库存一致性）成功返回后才写一条启动摘要日志；
		# 任一自检硬断言失败时执行不会到达此处，摘要自然不写入。日志调用不得移出 Debug 守卫。
		_write_startup_self_check_summary_log()


## 查询当前真实 OccupancyRegistry 是否仍有任一索引引用指定机关 ID（只读，无副作用）。
## [br]mechanism_id 是要查找的玩家机关 ID。
## [br]返回 true 表示当前真实 occupancy 的 ID→格子或格子→ID 任一方向仍引用该 ID；返回 false 表示未发现引用。
## [br]边界条件：本函数只委托纯查询函数读取真实 occupancy，不调用 occupancy.clear()，不删除索引，不修改玩家节点或库存；R 重置用它决定 unregister 失败时是否必须失败关闭。
## [br]批次 4B-C2 起真实规则位于 PlayerMechanismResetRules；本函数仅作为薄包装把当前 occupancy 传入共享纯规则，不保留规则实现。
func _occupancy_has_any_reference_to_mechanism(mechanism_id: StringName) -> bool:
	return _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(occupancy, mechanism_id)


## 执行玩家机关 ID 快照、R 库存恢复计算与临时占用残留查询自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中作为第六项调用。
## [br]检查逻辑已迁至独立模块 PlayerMechanismIdSnapshotCheck（gameplay/diagnostics/self_check/checks/player_mechanism_id_snapshot_check.gd），
## 真实规则位于 PlayerMechanismResetRules（gameplay/placement/rules/player_mechanism_reset_rules.gd）。
## [br]批次 4B-C2 起本函数通过单项 SelfCheckRunner 执行该检查：构造 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验，不再直接调用 PlayerMechanismIdSnapshotCheck.run()，也不再在核心脚本内保留测试案例。
## [br]本函数只通过 Runner 保持 Debug 失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第六项；不参与业务状态修改，不写文件，不写日志。
func _run_player_mechanism_id_snapshot_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"player_mechanism_id_snapshot",
			"玩家机关 ID 快照、R 库存计算与残留引用自检",
			_PlayerMechanismIdSnapshotCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_player_mechanism_id_snapshot")


## 启动期单项自检执行入口：通过 DiagnosticsController 执行一项启动自检定义（批次 5A-H3）。
## [br]职责：把单项自检交由核心持有的 DiagnosticsController 协调执行；Controller 负责临时 SelfCheckRunner 的创建、注册与执行，
## [br]注册失败与协调错误统一表达为 SelfCheckRunResult.errors；Controller 不执行 assert，失败策略仍由核心决定。
## [br]核心职责：解释 SelfCheckRunResult，保留执行错误、结构错误和检查失败三层 Debug 硬断言。
## [br]输入：definition 为已构造的 SelfCheckCallable，不得为 null；execution_id 为本次运行的稳定 StringName。
## [br]返回：无返回值。
## [br]真实数据：由各启动包装函数采集后构造 SelfCheckCallable 传入；本函数不采集玩法数据。
## [br]副作用：仅委托 Controller.run_self_check；核心不在本函数内 new SelfCheckRunner、不调用 Check.run()、不写文件、不写日志、不修改玩法状态、不访问场景树。
## [br]失败方式（三层 Debug 硬断言）：第一层 run_result 为 null 或 errors 非空（执行级错误）；
## [br]第二层 validate() 非空（结果结构错误）；第三层 is_success() 为 false（任一 Check 未通过）。
## [br]断言信息汇总 execution_id、errors、validate 错误与每项 check_id/summary/details，不降级为 warning。
## [br]边界：本函数只用于启动期自检，不用于运行期事务硬不变量（运行期库存一致性由 _assert_inventory_consistency 直接断言，不经本函数）。
## [br]保持启动顺序的边界：本函数只执行传入的单项定义，不合并多项，不改变 _ready 调用顺序。
func _run_startup_self_check_via_controller(
		definition: SelfCheckCallable,
		execution_id: StringName
) -> void:
	# 拒绝 null 定义，避免后续访问空对象。
	assert(definition != null, "启动自检：definition 为 null，必须传入 SelfCheckCallable。")
	# 通过核心持有的唯一 DiagnosticsController 协调执行：Controller 内部新建 SelfCheckRunner，
	# 注册失败/协调错误统一表达为 run_result.errors；Controller 不执行 assert，三层失败判定仍由核心负责。
	var run_result: SelfCheckRunResult = _diagnostics_controller.run_self_check(
		definition,
		execution_id
	)
	# 执行级前置：Controller 必须返回非 null 结果。
	assert(run_result != null, "启动自检：Controller 返回 null execution_id=%s。" % [execution_id])
	# 结果结构校验：validate() 一次返回全部字段问题，结构错误也用于断言信息汇总。
	var structure_problems: PackedStringArray = run_result.validate()
	# 汇总断言信息：execution_id、errors、validate 错误、每项 check_id/summary/details；
	# 用 PackedStringArray 拼装，不使用 Dictionary、无类型 Array 或 Variant。
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
	# 第一层：执行级错误——注册失败或协调错误由 Controller 表达为 run_result.errors，必须硬断言，不降级为 warning。
	assert(run_result.errors.is_empty(), "启动自检：执行级错误（注册/协调失败）：\n%s" % [assert_message])
	# 第二层：结果结构——validate() 返回的字段问题必须硬断言，不吞掉 validation details。
	assert(structure_problems.is_empty(), "启动自检：结果结构无效：\n%s" % [assert_message])
	# 第三层：检查未通过——任一 SelfCheckResult.passed=false 使 is_success() 为 false，必须硬断言，
	# 错误信息包含失败 Check 的 check_id/summary/details，不只输出模糊"自检失败"。
	assert(run_result.is_success(), "启动自检：检查未通过：\n%s" % [assert_message])


## 在七项 Debug 启动自检全部通过后写入一条最小启动摘要日志（批次 5A-H4）。
## [br]职责：构造一条强类型 DiagnosticLogEntry（severity=INFO），通过核心持有的 DiagnosticsController.write_entry_to_file
## [br]落盘到 RuntimeLogger 默认目录（user://diagnostics/logs）与默认文件名（runtime.log）；不接入 RuntimeSnapshotData 采集，不修改任何玩法行为。
## [br]输入：无参数；调用方保证仅在七项启动自检全部硬断言通过后才调用本函数（任一自检失败时执行不会到达此处）。
## [br]输出：无返回值；写入问题只逐项 push_warning，不 assert、不抛异常、不改变 RunState、不阻止主场景启动。
## [br]副作用：可能向默认诊断日志追加一条 INFO 摘要；目录创建、文件轮转与容量收敛继续由 RuntimeLogger 负责。
## [br]失败与边界：日志属于 Diagnostics 而非玩法事务，写入失败只 push_warning，不触发 R、不修复目录、不复制轮转或文件清理算法；
## [br]核心不直接创建 RuntimeLogger，不调用 record_entry——write_entry_to_file 已是独立正式写盘操作，不重复记录同一条目；
## [br]同一次主场景启动只通过本函数写一条摘要，不逐项记录每个自检的 PASS，不记录鼠标、拖拽、光传播或 Snapshot JSON。
func _write_startup_self_check_summary_log() -> void:
	# 时间戳取 Unix 毫秒：Time.get_unix_time_from_system 返回自纪元起的秒数（浮点），乘 1000 取整即为非负毫秒时间戳，满足 DiagnosticLogEntry 契约。
	var timestamp_unix_msec: int = int(Time.get_unix_time_from_system() * 1000.0)
	# 构造强类型日志条目：等级 INFO、稳定 module_name 与 execution_id、稳定中文摘要正文；
	# 构造参数顺序严格匹配 DiagnosticLogEntry 当前真实签名（timestamp, severity, module, execution, message）。
	var entry: _DiagnosticLogEntry = _DiagnosticLogEntry.new(
		timestamp_unix_msec,
		_DiagnosticSeverity.Level.INFO,
		&"startup_self_check",
		&"startup_all_self_checks",
		"七项启动自检全部通过"
	)
	# 通过 DiagnosticsController 正式写盘：返回空 PackedStringArray 表示成功；非空表示 RuntimeLogger 现有错误契约的全部中文错误。
	var write_problems: PackedStringArray = _diagnostics_controller.write_entry_to_file(entry)
	# 写入成功不额外输出；写入失败逐项 push_warning，不 assert、不中断主场景启动、不改变玩法状态。
	for problem: String in write_problems:
		push_warning("启动摘要日志写入失败：%s" % [problem])


## 执行 OccupancyRegistry 启动期轻量自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中调用。
## [br]检查逻辑已迁至独立模块 OccupancyRegistryCheck（gameplay/diagnostics/self_check/checks/occupancy_registry_check.gd）。
## [br]批次 4B-B2 起本函数通过单项 SelfCheckRunner 执行该检查：构造 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验，不再直接调用 OccupancyRegistryCheck.run()。
## [br]失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第一项；不参与业务状态修改，不写文件，不写日志。
func _run_occupancy_registry_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"occupancy_registry",
			"OccupancyRegistry 启动期轻量自检",
			_OccupancyRegistryCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_occupancy_registry")


## 执行当前原型 64 像素逻辑格坐标换算自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中作为第二项调用。
## [br]检查逻辑已迁至独立模块 GridCoordinateCheck（gameplay/diagnostics/self_check/checks/grid_coordinate_check.gd），
## 该模块在构造时复制采样快照，不保存 core_loop、Node、Crystal 或其他玩法对象引用。
## [br]批次 4B-E3 起本函数通过单项 SelfCheckRunner 执行该检查：按原自检顺序采集真实格子
## （Vector2i.ZERO、emitter_cell、每个 crystal.cell、每个 wall_cells 格、map_bounds.end - Vector2i.ONE 角点）
## 构造 GridCoordinateCheck，再包装为 SelfCheckCallable 交由 _run_startup_self_check_via_controller 注册、运行与校验，
## 不再在核心脚本内保留 cell↔world 断言或相邻格中心距测试案例。
## [br]本函数只通过 Runner 保持 Debug 失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第二项；采样数组只在本函数局部使用，不存为字段，
## 不排序、不去重，不改变 crystals 或 wall_cells 遍历顺序；只把 Vector2i 格子传入 Diagnostics，不把真实对象传给 Diagnostics；
## 不使用 Callable.bind 或 lambda；不参与业务状态修改，不写文件，不写日志。
func _run_grid_coordinate_self_check() -> void:
	# 按原自检顺序采集真实格子；只收集 Vector2i，不把 Crystal/Node 等真实对象传入 Diagnostics。
	var sample_cells: Array[Vector2i] = [Vector2i.ZERO, emitter_cell]
	for crystal: BasicCrystal in crystals:
		sample_cells.append(crystal.cell)
	for wall_cell: Vector2i in wall_cells:
		sample_cells.append(wall_cell)
	sample_cells.append(Vector2i(map_bounds.end.x - 1, map_bounds.end.y - 1))

	# 构造持有只读采样快照的检查实例；用 preload 常量作最强静态类型注解，避开新 class_name 缓存未刷新问题。
	var check: _GridCoordinateCheck = _GridCoordinateCheck.new(sample_cells)
	# 无参实例 Callable：Callable(check, "run") 不使用 Callable.bind、lambda 或捕获。
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"grid_coordinate",
			"网格坐标规则自检",
			Callable(check, "run")
	)
	_run_startup_self_check_via_controller(definition, &"startup_grid_coordinate")

## 执行基础单格镜面八方向反射纯函数自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中调用。
## [br]检查逻辑已迁至独立模块 MirrorReflectionCheck（gameplay/diagnostics/self_check/checks/mirror_reflection_check.gd）。
## [br]批次 4B-B2 起本函数通过单项 SelfCheckRunner 执行该检查：构造 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验，不再直接调用 MirrorReflectionCheck.run()。
## [br]失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中网格坐标自检之后，不得前移至网格检查之前；不参与业务状态修改，不写文件，不写日志。
func _run_single_cell_mirror_reflection_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"single_cell_mirror_reflection",
			"基础单格镜面八方向反射纯函数自检",
			_MirrorReflectionCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_single_cell_mirror_reflection")


## 执行当前原型运行状态纯规则自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中作为第四项调用。
## [br]检查逻辑已迁至独立模块 RuntimeStateCheck（gameplay/diagnostics/self_check/checks/runtime_state_check.gd），
## 正式规则位于 RuntimeStateRules（gameplay/interaction/runtime_state_rules.gd）。
## [br]批次 4B-F3 起本函数通过单项 SelfCheckRunner 执行该检查：构造 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验，
## 不再直接调用 RuntimeStateCheck.run()，也不再在核心脚本内保留测试案例或直接改写核心运行状态进行自检。
## [br]本函数只通过 Runner 保持 Debug 失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，
## 保留原 Debug 硬断言边界，不降级为 warning。
## [br]测试案例位于 RuntimeStateCheck（22 项：2 项脉冲结束目标状态 + 四个 RunState × 五条纯权限规则）；
## [br]正式规则位于 RuntimeStateRules；本函数只通过 Runner 保留 Debug 硬断言，不修改真实运行状态。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第四项；新实现相较旧实现改善为即使检查失败也不会修改或泄漏核心运行状态，
## 不再需要保存/恢复 original_state/original_level_completed/original_pulse_generation，不触发 UI、拖拽或状态事务；不参与业务状态修改，不写文件，不写日志。
func _run_post_pulse_state_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"runtime_state_rules",
			"运行状态规则自检",
			_RuntimeStateCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_runtime_state_rules")


## 执行运行期移动次数纯函数自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中作为第五项调用。
## [br]检查逻辑已迁至独立模块 RuntimeMoveCheck（gameplay/diagnostics/self_check/checks/runtime_move_check.gd），
## 真实规则位于 RuntimeMoveRules（gameplay/placement/rules/runtime_move_rules.gd）。
## [br]批次 4B-D4 起本函数通过单项 SelfCheckRunner 执行该检查：构造 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验，不再直接调用 RuntimeMoveCheck.run()，也不再在核心脚本内保留测试案例。
## [br]本函数只通过 Runner 保持 Debug 失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第五项；测试案例已迁入 RuntimeMoveCheck，正式规则位于 RuntimeMoveRules，本函数只通过 Runner 保留 Debug 硬断言，不参与实际移动判定，不写文件，不写日志。
func _run_runtime_move_self_check() -> void:
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"runtime_move_rules",
			"运行期移动规则自检",
			_RuntimeMoveCheck.run
	)
	_run_startup_self_check_via_controller(definition, &"startup_runtime_move_rules")


## 处理关卡输入动作和鼠标拖拽事件。
## [br]event 是 Godot 传入的输入事件。
## [br]无返回值；副作用是 fire_light 动作在 SETUP 或 MOVE_WINDOW 且未拖拽时触发一次脉冲，reset_level 动作直接调用 reset_runtime() 执行完整关卡重置；鼠标左键按正式运行权限驱动放置、移动和回收。
## [br]边界条件：拖拽中按 Space 会被安全忽略，玩家必须先松手完成放置、移动、回收或取消；拖拽中按 R 不依赖 _input 预先取消，而由 reset_runtime() 统一安全取消拖拽并回收全部玩家放置机关；SETUP/PULSE_ACTIVE/MOVE_WINDOW 均允许拿取、放置、移动与回收（仅已放置机关跨格直接移动受 runtime_move_limit 限制），COMPLETED 中只有 R 可用。PULSE_ACTIVE 中的布局变化只影响后续发射，不回溯当前脉冲。
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("reset_level"):
		reset_runtime()
		return

	if event.is_action_pressed("fire_light"):
		# 拖拽中拒绝 Space：一次拖拽事务尚未完成时不得启动新脉冲；运行期未拖拽时仍可有限移动已放置机关。
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


## 运行状态变化信号处理（阶段 02A 批次 3A）。
## [br]职责：RunStateController 是唯一运行状态所有者，状态字段更新后发出 state_changed；本回调只负责状态变化后的核心协调副作用——刷新机关栏 UI。
## [br]参数：previous_state 为切换前运行状态；new_state 为切换后运行状态（均由 Controller 在更新字段后传入）。
## [br]无返回值；副作用：只调用 _update_inventory_ui()。
## [br]边界：不在此取消拖拽、不修改 is_level_completed、不修改 pulse_generation、不清理水晶/光路/占用、不执行完整重置、不再次切换状态。
## [br]COMPLETED 前取消拖拽由 _finish_current_pulse 在请求转换前完成，不放在本回调中。
func _on_run_state_changed(
		previous_state: _RuntimeInteractionTypes.RunState,
		new_state: _RuntimeInteractionTypes.RunState
) -> void:
	_update_inventory_ui()


## 查询当前运行状态（阶段 02A 批次 3A）。
## [br]本函数无参数。
## [br]返回 Controller 持有的当前 RunState；核心不再持有 current_run_state 事实字段。
## [br]本函数无副作用；只转发 _run_state_controller.get_current_state()，用于需要把状态值传给 RuntimeMoveRules 等玩法规则层的调用点。
## [br]边界：纯读取，不切换状态、不发信号；不把 Controller 实例传入玩法规则层。
func _get_current_run_state() -> _RuntimeInteractionTypes.RunState:
	return _run_state_controller.get_current_state()


## 查询当前是否允许发射普通脉冲。
## [br]本函数无参数。
## [br]返回 true 表示 SETUP 或 MOVE_WINDOW 可以发射；返回 false 表示 PULSE_ACTIVE 或 COMPLETED 必须拒绝 Space。
## [br]本函数无副作用；边界条件：完成标签已显示但脉冲尚未视觉结束时，状态仍是 PULSE_ACTIVE，因此重复 Space 仍被拒绝。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2）；本薄包装保持函数名，内部转发 RunStateController，不在此函数内执行状态切换。
func can_fire_light() -> bool:
	return _run_state_controller.can_fire_light()


## 查询当前是否处于非冻结状态（粗粒度冻结门）。
## [br]本函数无参数。
## [br]返回 true 表示当前不是 COMPLETED（关卡未冻结）；返回 false 表示 COMPLETED 已冻结整个关卡交互。
## [br]本函数无副作用；边界条件：本函数只是粗粒度冻结门（非 COMPLETED 返回 true），不是拿取、移动、回收的唯一守卫。拿取/回收在所有非 COMPLETED 状态允许（_can_take_from_inventory_for_state / _can_recycle_placed_token_for_state），拖起已放置机关由 _can_begin_placed_drag 限制（所有非 COMPLETED 状态允许，与剩余次数分离），跨格提交由 _can_commit_placed_move 按剩余次数限制（SETUP 不限，PULSE_ACTIVE/MOVE_WINDOW 需 remaining>0）。PULSE_ACTIVE 中的布局变化只影响后续再次发射，不回溯当前脉冲。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2）；本薄包装保持函数名，内部转发 RunStateController，不在此函数内执行状态切换。
func can_edit_layout() -> bool:
	return _run_state_controller.can_edit_layout()


## 查询当前是否允许人工编辑内部配置。
## [br]本函数无参数。
## [br]返回 true 仅表示当前处于 SETUP；其他状态全部返回 false。
## [br]本函数无副作用；边界条件：本权限只用于主发射源方向、机关内部模式等内部配置，不代表布局编辑权限，不得用于控制拖拽放置、移动或回收。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2）；本薄包装保持函数名，内部转发 RunStateController，不在此函数内执行状态切换。
func can_edit_configuration() -> bool:
	return _run_state_controller.can_edit_configuration()


## 查询当前是否处于普通脉冲活动窗口。
## [br]本函数无参数。
## [br]返回 true 表示当前运行状态为 PULSE_ACTIVE；其他状态返回 false。
## [br]本函数无副作用；边界条件：通关目标可在 PULSE_ACTIVE 期间已成立，脉冲活动仍以运行状态为准。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2，接口名 is_pulse_active）；本薄包装保持函数名，内部转发 RunStateController，不在此函数内执行状态切换。
func is_current_pulse_active() -> bool:
	return _run_state_controller.is_current_pulse_active()


## 查询当前是否处于运行期移动状态。
## [br]本函数无参数。
## [br]返回 true 表示当前处于 PULSE_ACTIVE 或 MOVE_WINDOW；SETUP 与 COMPLETED 返回 false。
## [br]本函数无副作用；边界条件：运行期移动次数只在 PULSE_ACTIVE 和 MOVE_WINDOW 中扣除，SETUP 移动不计次，COMPLETED 冻结全部布局交互。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2）；本薄包装保持函数名，内部转发 RunStateController，不在此函数内执行状态切换。
func is_runtime_move_state() -> bool:
	return _run_state_controller.is_runtime_move_state()


## 查询当前剩余运行期移动次数。
## [br]本函数无参数。
## [br]返回 max(runtime_move_limit - runtime_moves_used, 0)；used 超过 limit 时返回 0。
## [br]本函数无副作用；边界条件：次数由关卡控制器持有，UI 与跨格提交权限只读取本结果，不在此处递增。
func get_runtime_moves_remaining() -> int:
	return _RuntimeMoveRules.compute_runtime_moves_remaining(runtime_move_limit, runtime_moves_used)


## 查询当前是否仍有运行期跨格移动提交次数。
## [br]本函数无参数。
## [br]返回 true 表示当前仍可在运行期成功提交一次已有机关跨格直接移动。
## [br]返回 false 表示跨格提交次数已耗尽，但不禁止拖起机关；玩家仍可松回原格取消或拖回机关栏回收。
## [br]本函数无副作用；SETUP 移动不受该次数限制，COMPLETED 由布局权限单独冻结。
func has_runtime_moves_remaining() -> bool:
	return get_runtime_moves_remaining() > 0


## 刷新运行期移动次数 UI。
## [br]本函数无参数、无返回值。
## [br]副作用：只把 RuntimeMoveLabel 文本设为"运行期移动：剩余 / 上限"；不修改 runtime_moves_used 或 runtime_move_limit。
## [br]边界条件：UI 只读取状态，剩余为 max(limit - used, 0)；limit 为 0 时显示 0 / 0。
func _update_runtime_move_ui() -> void:
	runtime_move_label.text = "运行期移动：%d / %d" % [get_runtime_moves_remaining(), runtime_move_limit]


## 决定有效普通脉冲结束后应进入的目标状态。
## [br]level_completed 表示脉冲结算后关卡完成条件是否已经成立。
## [br]返回 COMPLETED 表示已完成，返回 MOVE_WINDOW 表示未完成且可等待未来移动或再次发射。
## [br]本函数无副作用，不读取或修改真实场景状态。
## [br]边界条件：只负责 PULSE_ACTIVE 结束后的二选一状态，不处理 R、非法发射、拖拽或移动次数。
## [br]正式规则位于 RuntimeStateRules（批次 4B-F2，接口名 get_post_pulse_state）；本包装函数只转发 level_completed 参数，不在此函数内执行状态切换。
func _get_post_pulse_state(level_completed: bool) -> _RuntimeInteractionTypes.RunState:
	return _RuntimeStateRules.get_post_pulse_state(level_completed)


## 发射一次核心闭环原型最小脉冲光线。
## [br]本函数无参数、无返回值。
## [br]副作用：SETUP 或 MOVE_WINDOW 且未拖拽时，清理上一轮光路视觉，按发射瞬间的当前布局计算完整路径，
## 光进入镜面格后先显示路径和点亮同格水晶，再通过 OccupancyRegistry 找到 SingleCellMirror 并使用其 orientation 更新传播方向，随后启动约 1 秒的光路视觉保持流程。
## [br]状态变化：开始时通过 _run_state_controller.begin_pulse() 进入脉冲活动并递增 pulse_generation；
## 若全部必需水晶被本次脉冲满足，update_completion_state() 会先设置 is_level_completed，运行状态等脉冲视觉结束后再由 Controller 进入 COMPLETED。
## [br]失败条件：方向非法时报告错误并不创建脉冲；拖拽中、PULSE_ACTIVE 或 COMPLETED 中忽略 Space；镜面反射返回 Vector2i.ZERO 时安全停止传播。
## [br]边界条件：遇到地图边界、墙体或 MAX_PROPAGATION_STEPS 上限时停止传播；未知机关本轮保持无光学效果且不得崩溃。PULSE_ACTIVE 期间玩家可拿取/放置/回收，且可按剩余次数移动已放置机关，但不会重新计算或回溯修改这一次已经完成逻辑计算的光路结果。
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

	# 脉冲开始：请求 Controller 进入 PULSE_ACTIVE，同时表示配置已锁定且存在活动脉冲。
	# 必须确认状态成功进入 PULSE_ACTIVE 后才继续本次发射流程；begin_pulse 意外返回 false 时停止本次发射，不继续传播。
	# Controller 已通过 push_error 报告拒绝原因，此处不再重复输出第二条无意义错误。
	if not _run_state_controller.begin_pulse():
		return
	pulse_generation += 1
	var current_pulse_generation: int = pulse_generation

	# 初始化传播状态。
	var current_cell: Vector2i = emitter_cell
	var steps: int = 0

	# 逐格传播，直到遇到边界、墙体、非法反射或安全步数上限。
	while steps < MAX_PROPAGATION_STEPS:
		var next_cell: Vector2i = current_cell + direction

		# 1. 边界停止。
		if not map_bounds.has_point(next_cell):
			break

		# 2. 墙体停止。
		if is_cell_blocking_light(next_cell):
			break

		# 3-5. 光先进入 next_cell，再显示该格光路并结算该格普通独立水晶。
		# 镜面方向只在进入镜面格之后影响后续传播方向，不回头改变已经进入的当前格。
		# direction 在此处仍是进入 next_cell 的入射方向（镜面反射发生在本调用之后），
		# 因此镜面格只显示入射方向，反射后的出射方向从下一格开始显示。
		add_light_visual(next_cell, direction)
		try_activate_crystal_at(next_cell)

		# 6-8. 通过 OccupancyRegistry 按格查 ID，再从 placed_tokens_by_id 找正式节点；orientation 是镜面方向唯一事实来源。
		var mechanism_id: StringName = get_mechanism_at(next_cell)
		if mechanism_id != &"":
			var reflected_direction: Vector2i = _get_reflected_direction_from_mechanism(mechanism_id, direction)
			if reflected_direction == Vector2i.ZERO:
				break
			direction = reflected_direction

		# 9. 更新当前位置；下一轮循环使用反射后的 direction。
		current_cell = next_cell
		steps += 1

	# 达到传播步数上限时停止，避免非法方向或未来反射逻辑造成无限循环。
	if steps >= MAX_PROPAGATION_STEPS:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")

	# 通关判断立即完成；CompleteLabel 可立刻显示，但运行状态保持 PULSE_ACTIVE 到脉冲视觉结束。
	update_completion_state()

	_finish_pulse_after_delay(current_pulse_generation)


## 执行下一次脉冲前的光路视觉清理。
## [br]本函数无参数、无返回值。
## [br]副作用：清除旧光路视觉，不改变已经点亮的普通独立水晶或已放置原型机关。
## [br]状态变化：不改变运行状态、is_level_completed、CompleteLabel、库存、占用表或 pulse_generation。
## [br]边界条件：只作为 Space 发射前的轻量清理，不承担 R 的完整运行重置职责。
func _prepare_for_new_pulse() -> void:
	clear_light_path()


## 等待当前脉冲的视觉保持时间并尝试结束脉冲。
## [br]expected_generation 是发起等待时记录的脉冲版本号。
## [br]无返回值；副作用是在等待约 PULSE_VISUAL_DURATION_SECONDS 后，若版本仍有效则结束当前脉冲并进入 MOVE_WINDOW 或 COMPLETED。
## [br]失败条件：若 R 重置或新脉冲已递增 pulse_generation，本回调视为过期并直接返回。
## [br]边界条件：该等待只控制统一脉冲结束事件和光路视觉清理，不参与路径、墙体、水晶命中、普通独立水晶保持或通关结果计算。
func _finish_pulse_after_delay(expected_generation: int) -> void:
	await get_tree().create_timer(PULSE_VISUAL_DURATION_SECONDS).timeout
	# 过期回调保护：旧脉冲等待结束后不得清理 R 后新发射的脉冲或改变新脉冲状态。
	if expected_generation != pulse_generation:
		return
	if not is_current_pulse_active():
		return
	_finish_current_pulse(expected_generation)


## 结束当前仍有效的普通脉冲。
## [br]expected_generation 是调用方确认的脉冲版本号。
## [br]无返回值；副作用：清除当前光路视觉，并根据完成结果请求 Controller 把状态切换到 MOVE_WINDOW 或 COMPLETED。
## [br]状态变化：通过 _run_state_controller.finish_pulse(is_level_completed) 将 PULSE_ACTIVE 转为目标状态；
## 不清除普通独立水晶、原型机关、库存或占用表，完成状态和 CompleteLabel 都保持到 R 重置。
## [br]失败条件：版本不匹配或当前无活动脉冲时直接返回，避免重复结束或旧回调误清理；finish_pulse 返回 false 时通过现有错误边界暴露并安全退出。
## [br]边界条件：不处理同时组、顺序组、移动次数或完整 RunStateController；等待、计时器与 generation 仍由核心保护，不移入 Controller。
func _finish_current_pulse(expected_generation: int) -> void:
	# 过期回调保护：结束清理前再次确认这是当前有效脉冲。
	if expected_generation != pulse_generation:
		return
	if not is_current_pulse_active():
		return

	# 脉冲结束：普通光路视觉消失，普通独立水晶继续保持点亮。
	clear_light_path()

	# 脉冲结束后的目标状态：完成则进入 COMPLETED，否则进入 MOVE_WINDOW。
	var next_state: _RuntimeInteractionTypes.RunState = _get_post_pulse_state(is_level_completed)

	# COMPLETED 是唯一冻结全部布局交互的状态；进入冻结前由核心取消当前拖拽，必须在请求状态转换前完成，
	# 避免冻结后鼠标松开仍提交移动或回收。取消拖拽不放在状态信号回调中，保证顺序为：取消拖拽 → 更新状态 → 发 state_changed → 刷新机关栏 UI。
	# PULSE_ACTIVE 转入 MOVE_WINDOW 时已开始的合法已放置机关拖拽可继续，正式提交时仍按 MOVE_WINDOW 与剩余次数由 _commit_placed_drag_or_cancel() 重新校验。
	if next_state == _RuntimeInteractionTypes.RunState.COMPLETED and is_dragging():
		_cancel_current_drag()

	# 请求 Controller 切换状态；失败通过现有错误边界暴露并安全退出，不再通过旧 _set_run_state() 切换，不继续后续完成标签处理。
	if not _run_state_controller.finish_pulse(is_level_completed):
		push_error("CoreLoopPrototype: RunStateController.finish_pulse 被拒绝，无法结束脉冲。")
		return

	# 完成结果保留：路径消失后，已经成立的关卡完成标签继续显示。
	if _get_current_run_state() == _RuntimeInteractionTypes.RunState.COMPLETED:
		complete_label.visible = true


## 重置本次原型关卡到完整初始运行状态。
## [br]本函数无参数、无返回值。
## [br]副作用：最先安全取消当前拖拽；随后递增 pulse_generation 使旧脉冲等待回调失效；清除当前光路视觉、普通独立水晶点亮状态、完成状态和完成标签；逐个注销并删除可确认清理的玩家 PlaceableToken；按未能清理的玩家机关数量恢复机关栏库存；刷新机关栏与运行期移动 UI。
## [br]状态变化：is_level_completed 设为 false，runtime_moves_used 清零，运行状态通过 _run_state_controller.reset_to_setup() 返回 SETUP；正常情况下 placed_tokens_by_id 清空且 prototype_token_remaining 恢复为 PROTOTYPE_TOKEN_TOTAL。
## [br]边界条件：reset_runtime() 是 R 和脚本直接调用的唯一完整重置入口，不依赖 _input 预先取消拖拽；拖动已放置机关时先恢复正式节点原格和可见性，再统一注销占用并删除节点，避免隐藏节点遗留；只清理玩家放置机关，不调用 occupancy.clear()，不删除发射器、墙体、水晶或未来静态/预置机关。正常情况下 R 将全部玩家机关退回库存；若检测到 OccupancyRegistry 残留且无法通过公共 unregister 接口确认清理，相关机关会保留在场上且不会重复退回库存，以避免制造重复机关。
func reset_runtime() -> void:
	# R完整重置首先取消拖拽：库存预览只删除预览；已放置机关先恢复旧格、旧世界位置和可见性，随后再由玩家机关清理流程统一删除。
	if is_dragging():
		_cancel_current_drag(false)

	# R取消当前脉冲：递增版本号，使已经挂起的旧等待回调全部失效，不能再清理或切换 R 后的新状态。
	pulse_generation += 1
	is_level_completed = false
	runtime_moves_used = 0

	clear_light_path()
	_reset_independent_crystals()
	complete_label.visible = false

	var all_player_tokens_returned: bool = _return_all_player_placed_tokens_to_inventory()
	if not all_player_tokens_returned:
		push_error("CoreLoopPrototype: R重置玩家机关清理未完全成功，部分机关已保留在场上且未退回库存。")

	# 状态回到 SETUP 必须位于完整重置的收尾阶段：在玩家机关清理、库存恢复与 UI 刷新之后才请求 Controller 回归 SETUP。
	# reset_to_setup 幂等：已在 SETUP 时不发信号；非 SETUP 时先更新状态再发 state_changed，由 _on_run_state_changed 刷新机关栏 UI。
	# 机关栏 UI 不依赖该信号唯一触发——_return_all_player_placed_tokens_to_inventory 内部已先行调用 _update_inventory_ui()。
	_run_state_controller.reset_to_setup()
	_update_runtime_move_ui()

	if OS.is_debug_build():
		_assert_inventory_consistency()


## 将全部可确认清理的玩家放置机关退回机关栏库存。
## [br]本函数无参数；输入事实来自 placed_tokens_by_id 中登记的玩家 PlaceableToken 映射。
## [br]返回 true 表示全部玩家机关均确认完成占用注销、节点删除和映射移除；返回 false 表示至少一个玩家机关因为 OccupancyRegistry 仍残留引用而未被清理和退回库存。
## [br]副作用：复制玩家 mechanism_id 快照，按 ID 逐个调用 occupancy.unregister() 注销玩家机关占用；成功注销或确认 registry 已无残留引用时，安全 queue_free() 对应玩家机关节点并移除 placed_tokens_by_id 记录；最终按仍留在 placed_tokens_by_id 中的未清理数量计算 prototype_token_remaining，并刷新机关栏 UI。
## [br]状态变化：只修改可确认清理的玩家机关映射、玩家机关节点、玩家机关 OccupancyRegistry 占用和库存数量；不修改发射器、墙体、水晶、LightPathLayer、运行状态、runtime_moves_used、pulse_generation 或完成状态。
## [br]异常处理：unregister 返回 false 且 registry 已无该 ID 任一方向引用时，说明占用可能已提前缺失，调试构建输出 warning 后继续删除节点和回库；unregister 返回 false 且 registry 仍有该 ID 任一方向残留引用时，失败关闭：输出错误、保留节点、保留 placed_tokens_by_id 记录、不退回库存，并继续处理其他玩家机关。节点失效但占用已清理时输出错误、移除映射并恢复对应库存；节点失效且占用仍残留时不试图 queue_free，也不回库，保留异常事实供一致性断言暴露。
## [br]边界条件：必须先使用 ID 快照，因为遍历 Dictionary 时直接 erase 会改变迭代中的集合，可能导致漏删或未定义行为；不得调用 occupancy.clear()，不得强制修改 OccupancyRegistry 内部索引修复异常，因为未来 OccupancyRegistry 可能包含关卡预置机关或静态机关占用，完整 R 只允许清理 placed_tokens_by_id 登记的玩家放置机关。
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


## 重置普通独立水晶为未点亮状态。
## [br]本函数无参数、无返回值。
## [br]副作用：对当前 crystals 中的每个 BasicCrystal 调用 reset_runtime()，恢复其半透明未点亮视觉。
## [br]状态变化：只在 R 完整重置中清除普通独立水晶状态；不由普通脉冲结束调用。
## [br]边界条件：当前 BasicCrystal 只作为普通独立水晶使用；本函数不实现同时组、顺序组或通用水晶条件系统。
func _reset_independent_crystals() -> void:
	# R完整重置：普通独立水晶保持到玩家重置时才恢复未点亮。
	for crystal: BasicCrystal in crystals:
		crystal.reset_runtime()


## 清除当前光路视觉节点。
## [br]本函数无参数、无返回值。
## [br]副作用：对 LightPathLayer 下的所有子节点调用 queue_free()，实际释放由 Godot 帧流程完成。
## [br]边界条件：子节点为空时安全无效果；只清理视觉层，不修改水晶、完成状态、墙体、库存或占用表。
func clear_light_path() -> void:
	for child: Node in light_path_layer.get_children():
		child.queue_free()


## 判断传播方向是否合法。
## [br]direction 是要检查的格子方向向量。
## [br]返回 true 表示方向非零且每个分量都在 -1 到 1 之间；返回 false 表示不能用于逐格传播。
## [br]本函数无副作用；边界条件是 Vector2i.ZERO、超过一格的方向和非法斜率都会被拒绝。
func is_valid_direction(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 判断指定格子是否阻挡光线。
## [br]cell 是要检查的格子坐标。
## [br]返回 true 表示该格在 wall_cells 中，应停止传播；返回 false 表示当前原型允许通过。
## [br]本函数无副作用；边界条件：只检查静态 wall_cells，不处理可消除墙、机关占用或电控门。
func is_cell_blocking_light(cell: Vector2i) -> bool:
	return wall_cells.has(cell)


## 查询指定格子被哪个机关占用（占用表对外查询入口）。
## [br]cell 是要查询的格子坐标。
## [br]返回占用该格的机关 ID；未被占用时返回空 StringName（&""），不报错。
## [br]本函数无副作用；当前核心闭环原型传播循环会据此解析基础单格镜面，未知机关保持无光学效果。
func get_mechanism_at(cell: Vector2i) -> StringName:
	return occupancy.get_mechanism_at(cell)


## 根据指定机关 ID 尝试取得反射后的传播方向。
## [br]mechanism_id 是 OccupancyRegistry 在当前光进入格查到的机关 ID，incoming_direction 是进入该格时的传播方向。
## [br]返回值为后续传播方向；SingleCellMirror 返回其 reflect_direction() 结果，未知机关返回原方向，镜面非法方向返回 Vector2i.ZERO 让传播安全停止。
## [br]本函数不修改 OccupancyRegistry、库存、节点位置或水晶状态；只读取 placed_tokens_by_id 中正式节点的 orientation 事实。
## [br]边界条件：传播循环已经先完成边界、墙体、入格视觉和水晶处理，本函数只处理“进入镜面格后再更新方向”的接入点；未知 PlaceableToken 派生机关本轮不产生光学效果，调试构建输出明确提示。
func _get_reflected_direction_from_mechanism(mechanism_id: StringName, incoming_direction: Vector2i) -> Vector2i:
	if not placed_tokens_by_id.has(mechanism_id):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 光路经过占用表机关 %s，但没有对应正式节点，本轮保持原方向。" % [mechanism_id])
		return incoming_direction

	var token: Variant = placed_tokens_by_id[mechanism_id]
	if not is_instance_valid(token):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 光路经过机关 %s，但节点已失效，停止传播。" % [mechanism_id])
		return Vector2i.ZERO

	if token is not SingleCellMirror:
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 光路经过未知机关 %s，本轮不产生光学效果。" % [mechanism_id])
		return incoming_direction

	var mirror: SingleCellMirror = token as SingleCellMirror
	var reflected_direction: Vector2i = mirror.reflect_direction(incoming_direction)
	if reflected_direction == Vector2i.ZERO and OS.is_debug_build():
		print_debug("CoreLoopPrototype: 镜面 %s 收到非法入射方向 %s，停止传播。" % [mechanism_id, incoming_direction])
	return reflected_direction


## 判断指定格子是否被任意机关占用（占用表对外查询入口）。
## [br]cell 是要查询的格子坐标。
## [br]返回 true 表示该格已被机关占用；返回 false 表示未占用。
## [br]本函数无副作用；边界条件：空占用表时始终返回 false。
func has_mechanism_at(cell: Vector2i) -> bool:
	return occupancy.has_mechanism_at(cell)


## 尝试点亮指定格子上的普通独立水晶。
## [br]cell 是当前光线进入的格子坐标。
## [br]无返回值；副作用是在存在坐标匹配的 BasicCrystal 时调用 activate() 改变其点亮状态和视觉。
## [br]边界条件：没有匹配水晶时安全无效果；当前核心闭环原型不处理颜色、形式、同时组或顺序组，普通独立水晶保持到 R 重置。
func try_activate_crystal_at(cell: Vector2i) -> void:
	for crystal: BasicCrystal in crystals:
		if crystal.cell == cell:
			crystal.activate()


## 判断所有必需普通独立水晶是否已点亮。
## [br]本函数无参数。
## [br]返回 true 表示 crystals 中全部水晶的 is_activated 都为 true；任一未激活则返回 false。
## [br]本函数无副作用；边界条件：crystals 为空表示关卡未配置必需水晶，会输出明确错误并返回 false，防止误判通关。
func all_required_crystals_activated() -> bool:
	if crystals.is_empty():
		push_error("CoreLoopPrototype: 当前关卡未配置任何必需水晶，不能判定为完成。")
		return false

	for crystal: BasicCrystal in crystals:
		if not crystal.is_activated:
			return false
	return true


## 根据当前水晶状态更新关卡完成状态和完成标签。
## [br]本函数无参数、无返回值。
## [br]副作用：当全部必需水晶在当前脉冲中已激活时立即显示 CompleteLabel。
## [br]状态变化：首次满足条件时将 is_level_completed 设为 true；运行状态仍保持 PULSE_ACTIVE，直到脉冲视觉结束后进入 COMPLETED。
## [br]边界条件：普通独立水晶和通关结果都保持到 R；只有 R 重置会清除完成状态和隐藏标签。
func update_completion_state() -> void:
	if is_level_completed:
		complete_label.visible = true
		return

	if all_required_crystals_activated():
		is_level_completed = true
		complete_label.visible = true
	else:
		complete_label.visible = false


## 为指定格子添加一段原型光路视觉。
## [br]cell 是要显示光路的格子坐标；direction 是光进入该格时的传播方向，仅用于选择四方向纹理，不修改传播逻辑。
## [br]无返回值；副作用是实例化 LightSegmentView，配置 profile、方向与光线颜色，定位到格中心并加入 LightPathLayer。
## [br]边界条件：四方向纹理为空时由 LightSegmentView 静默回退到黄色占位块，不输出 warning；
## [br]镜面格只显示进入该格的入射方向，反射后的出射方向从下一格开始显示；同一格允许多个 LightSegmentView 共存，不做去重或对象池。
func add_light_visual(cell: Vector2i, direction: Vector2i) -> void:
	# 按 B2 冻结算子顺序：实例化 → 设置 profile → 设置方向 → 设置颜色 → 定位 → 加入 LightPathLayer。
	# set_profile / set_direction / set_light_color 在 add_child 前调用，此时 LightSegmentView 的 @onready 子节点尚未就绪，
	# 其 refresh_visual() 会安全返回；字段值已写入，add_child 触发 _ready() 时由 refresh_visual() 统一应用。
	var view: _LightSegmentViewScript = _LightSegmentViewScene.instantiate()
	view.set_profile(_DefaultLightSegmentProfile as _LightSegmentVisualProfile)
	view.set_direction(direction)
	view.set_light_color(LIGHT_PATH_COLOR)
	# 根节点局部原点表示光路格中心；position 直接使用 _GridCoordinateRules.cell_to_world(cell)，由 LightSegmentView 内部 offset 居中。
	view.position = _GridCoordinateRules.cell_to_world(cell)
	light_path_layer.add_child(view)


## 处理鼠标左键拖拽与右键镜面朝向配置。
## [br]event 是 Godot 鼠标按键事件。
## [br]无返回值；副作用是左键按正式运行权限开始库存拖拽（非 COMPLETED 均允许）或已放置机关拖起（所有非 COMPLETED 状态允许，与剩余次数分离），并在松开时提交、回收（非 COMPLETED 均允许）或取消；运行期跨格提交由 _can_commit_placed_move 按 remaining 限制；右键仅在 SETUP 且未拖拽时切换已放置镜面的 orientation。
## [br]边界条件：其他按键忽略；SETUP/PULSE_ACTIVE/MOVE_WINDOW 均允许拿取、放置、移动与回收，仅已放置机关跨格直接移动受 runtime_move_limit 限制；运行期内部配置已锁定，右键不改变镜面方向；COMPLETED 冻结整个关卡交互；InventoryBar 区域阻止右键穿透到世界镜面。
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


## 尝试右键切换鼠标所在已放置镜面的内部朝向。
## [br]本函数无参数、无返回值。
## [br]副作用：仅当鼠标位于世界中已放置 SingleCellMirror 且 can_edit_configuration() 为 true 时调用 toggle_orientation() 修改该镜面的 orientation 和视觉。
## [br]状态变化：SETUP 可切换；PULSE_ACTIVE 和 MOVE_WINDOW 布局仍可移动但内部配置锁定，COMPLETED 冻结全部操作，三者都不会改变 orientation。
## [br]边界条件：拖拽进行中忽略右键；InventoryBar 整体区域阻止右键穿透到世界镜面；未知机关和空格安全忽略。
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


## 尝试根据当前鼠标位置开始一次拖拽。
## [br]本函数无参数、无返回值。
## [br]副作用：可能创建拖拽预览节点、隐藏已放置正式节点，并写入当前拖拽状态字段。
## [br]边界条件：库存拿取在所有非 COMPLETED 状态允许（_can_take_from_inventory_for_state）；已放置机关拖起由 _can_begin_placed_drag 限制（所有非 COMPLETED 状态允许，与剩余次数分离）。整个 InventoryBar 都会阻止点击继续传递到世界机关，InventoryBar 空白区域不会换算世界格子、查询 OccupancyRegistry 或启动任何拖拽。运行期剩余次数为 0 时仍允许拖起（以便回收或取消），跨格提交由 _commit_placed_drag_or_cancel 二次校验拒绝并恢复原位置；COMPLETED 冻结关卡交互并拒绝一切新拖拽。
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


## 从机关栏开始一次基础单格镜面拖拽。
## [br]本函数无参数、无返回值。
## [br]副作用：创建一个默认 SLASH 朝向的镜面预览节点并设置拖拽来源为 INVENTORY。
## [br]边界条件：从库存拖拽但不提前扣数量；若之后非法松手或松回机关栏，库存和 OccupancyRegistry 都不变化。
func _begin_inventory_drag() -> void:
	var start_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	_drag_source = _RuntimeInteractionTypes.DragSource.INVENTORY
	_drag_mechanism_id = &""
	_drag_original_cell = INVALID_CELL
	_drag_preview_cell = start_cell
	_dragged_placed_token = null
	# 从库存拖拽但不提前扣数量：只有合法松手提交后才减少 prototype_token_remaining；新拿出的镜面默认 SLASH。
	_drag_preview_token = _create_token_node(StringName("preview_%s" % MIRROR_TOKEN_TYPE_ID), start_cell, true)
	_update_drag_preview_from_mouse()


## 从已放置原型机关开始一次拖拽移动。
## [br]mechanism_id 是 OccupancyRegistry 查询到的机关 ID，original_cell 是鼠标按下的原始格子。
## [br]返回 true 表示已进入 PLACED 拖拽；返回 false 表示一致性检查失败，未进入拖拽、未创建预览、未隐藏节点。
## [br]副作用：检查通过后隐藏正式机关视觉、创建预览节点，并记录原始占用信息。
## [br]边界条件：写入任何拖拽字段前必须先确认 placed_tokens_by_id 存在该 ID、节点 is_instance_valid、mechanism_id 与参数一致、cell 与 original_cell 一致；任一失败则输出错误并返回 false，不进入 PLACED 拖拽状态。已放置机关拖拽期间保留旧逻辑占用，预览不写入 OccupancyRegistry，非法松手会恢复正式节点。
func _begin_placed_drag(mechanism_id: StringName, original_cell: Vector2i) -> bool:
	# 写入拖拽字段前完成全部一致性检查，避免半写入拖拽状态或对失效节点解引用。
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
	# 已放置机关拖拽期间保留旧逻辑占用，只隐藏正式视觉，直到松手后再原子更新；预览必须复制当前镜面朝向。
	_dragged_placed_token.set_placed_visible(false)
	_drag_preview_token = _create_token_node(mechanism_id, original_cell, true)
	_copy_mirror_orientation_if_possible(_dragged_placed_token, _drag_preview_token)
	_update_drag_preview_from_mouse()
	return true


## 根据当前鼠标位置更新拖拽预览。
## [br]本函数无参数、无返回值。
## [br]副作用：鼠标位于 InventoryBar 有效区域时，只隐藏 RuntimeObjects 下的世界拖拽预览，不把 UI 坐标转换成虚假的地图格子；离开 InventoryBar 后恢复预览显示、吸附到 cell_to_world() 的格子中心，并按空间合法性（静态阻挡黑名单 + OccupancyRegistry 动态占用）与当前松手提交权限（_is_world_drop_preview_valid）刷新合法/非法颜色。
## [br]边界条件：隐藏预览不等于取消拖拽，不改变拖拽来源、机关 ID、原始格子、库存或占用表；已放置机关拖拽期间旧逻辑占用继续保留，最终放置、取消或回收仍由 _finish_drag_at_mouse() 决定。预览颜色只是视觉反馈，不替代正式提交的二次校验。
func _update_drag_preview_from_mouse() -> void:
	if not is_dragging() or _drag_preview_token == null:
		return

	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	if _is_mouse_over_inventory_bar(viewport_mouse_position):
		_drag_preview_token.set_drag_preview_visible(false)
		return

	_drag_preview_token.set_drag_preview_visible(true)
	_drag_preview_cell = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	# 预览合法性同时反映空间合法性与当前是否允许该次松手提交；预览只是视觉反馈，不替代正式提交的二次校验。
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


## 在鼠标松开位置完成当前拖拽。
## [br]本函数无参数、无返回值。
## [br]副作用：根据拖拽来源和松手区域执行库存放置、已放置机关移动、拖回机关栏回收或取消。
## [br]边界条件：从库存释放回机关栏只取消；只有从已放置机关开始的 PLACED 拖拽可以被回收，且回收在所有非 COMPLETED 状态允许。COMPLETED 中释放到机关栏改为安全取消，恢复原机关显示与原占用，不增加库存、不扣次数。
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
			# 回收在所有非 COMPLETED 状态允许（用户最终权限）；COMPLETED 释放到机关栏改为安全取消，保留原占用与原位置，不增库存、不扣次数。
			if _RuntimeMoveRules.can_recycle_placed_token_for_state(_get_current_run_state()):
				_recycle_dragged_placed_token()
			else:
				if OS.is_debug_build():
					print_debug("CoreLoopPrototype: 当前运行状态禁止回收，改为取消拖拽并恢复原机关：%s。" % [_get_current_run_state()])
				_cancel_current_drag()
			return
		_commit_placed_drag_or_cancel()


## 提交从库存开始的拖拽，或在非法位置取消。
## [br]本函数无参数、无返回值。
## [br]副作用：合法时创建正式机关节点、登记 OccupancyRegistry、库存减一并删除预览；非法时只删除预览。
## [br]边界条件：松到非法格时取消拖拽，库存仍为 1 且 OccupancyRegistry 不变化；提交失败时也按取消处理。正式首次放置前再次检查 _can_take_from_inventory_for_state：拖拽中 Space 会被忽略、R 会取消，但本处仍防御性校验，若当前为 COMPLETED（或未知状态）则取消拖拽，不扣库存、不创建正式机关、不登记占用、不改 placed_tokens_by_id。运行期首次放置不消耗 runtime_moves_used，只影响下一次发射。
func _commit_inventory_drag_or_cancel() -> void:
	# 提交前防御性状态校验：首次放置在所有非 COMPLETED 状态允许；COMPLETED/未知状态取消拖拽，不扣库存、不创建正式机关。
	if not _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state()):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态禁止首次放置，取消库存拖拽：%s。" % [_get_current_run_state()])
		_cancel_current_drag()
		return
	if not _is_valid_prototype_placement_cell(_drag_preview_cell, &""):
		# 非法位置取消：不扣库存、不写占用、不留下残影。
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


## 提交已放置机关移动，或在非法位置/原格松手时取消。
## [br]本函数无参数、无返回值。
## [br]副作用：合法新格时原子清除旧占用并登记新占用，更新正式机关节点；非法时恢复原节点可见性。
## [br]边界条件：原格松手视为取消；库存不变化；若新占用提交意外失败，必须尝试恢复原占用和原位置。
## [br]运行期扣次：仅在 PULSE_ACTIVE 或 MOVE_WINDOW 且跨格成功提交后扣除一次 runtime_moves_used 并刷新 UI；SETUP、非法目标、原格松手、取消与回滚均在此前 return，不会到达扣次点。
## [br]提交前二次校验：在修改 OccupancyRegistry 之前重新验证拖拽节点有效、mechanism_id 与 from_cell 仍正确、to_cell 仍合法、当前状态与剩余次数仍允许提交；失败时安全取消并恢复原机关，不注销旧占用、不登记新占用、不改节点位置、不扣次数。
func _commit_placed_drag_or_cancel() -> void:
	if _drag_preview_cell == _drag_original_cell:
		_cancel_current_drag()
		return
	if not _is_valid_prototype_placement_cell(_drag_preview_cell, _drag_mechanism_id):
		# 非法移动取消：旧逻辑占用从拖拽开始到取消一直保留，正式机关只需恢复显示。
		_cancel_current_drag()
		return

	var token = _dragged_placed_token
	var mechanism_id: StringName = _drag_mechanism_id
	var from_cell: Vector2i = _drag_original_cell
	var to_cell: Vector2i = _drag_preview_cell

	# 提交前第二次校验：状态转换或次数变化后，正式提交前重新确认整次移动仍合法。
	# 失败时安全取消拖拽，恢复正式机关显示，保留原占用，不扣次数，不更新 UI。
	if not is_instance_valid(token):
		push_error("CoreLoopPrototype: 提交移动前拖拽节点已失效，取消拖拽。")
		_cancel_current_drag()
		return
	# 节点 mechanism_id 与 cell 必须仍与拖拽起始事实一致：拖拽期间正式节点只隐藏未移动，cell 应仍在 from_cell。
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

	# 松手后原子更新：先清除旧占用，再登记新占用；失败必须恢复旧格，避免旧占用和新占用同时丢失。
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
	# 运行期移动扣次：占用原子更新与节点提交都已成功后才扣除一次；同一次成功移动只扣一次。
	# SETUP 跨格移动不计次；非法、原格、取消、回滚与新占用登记失败均不会到达本处。
	if _RuntimeMoveRules.should_count_runtime_move(_get_current_run_state(), from_cell, to_cell):
		runtime_moves_used += 1
		_update_runtime_move_ui()


## 回收当前从已放置机关开始拖拽的原型机关。
## [br]本函数无参数、无返回值。
## [br]副作用：注销 OccupancyRegistry、移除 ID 到节点映射、删除正式节点和预览节点、库存加一并刷新 UI。
## [br]边界条件：只有 PLACED 拖拽可以回收；回收在所有非 COMPLETED 状态允许。本函数内部含防御性 _can_recycle_placed_token_for_state 检查，COMPLETED/未知状态调用时安全取消并恢复原机关，不增库存、不扣次数，不依赖外层 _finish_drag_at_mouse 这一单一守卫。运行期回收不消耗 runtime_moves_used，只影响下一次发射。库存不得超过 PROTOTYPE_TOKEN_TOTAL；注销失败时恢复正式机关并取消拖拽。
func _recycle_dragged_placed_token() -> void:
	if _drag_source != _RuntimeInteractionTypes.DragSource.PLACED or _dragged_placed_token == null:
		_cancel_current_drag()
		return
	# 防御性权限检查：回收在所有非 COMPLETED 状态允许；COMPLETED/未知状态即使直接调用本函数也安全取消，不增库存。
	if not _RuntimeMoveRules.can_recycle_placed_token_for_state(_get_current_run_state()):
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: 当前运行状态禁止回收，安全取消并恢复原机关：%s。" % [_get_current_run_state()])
		_cancel_current_drag()
		return

	# 拖回栏位回收：整个 InventoryBar 是有效区域，不要求精准松回小栏位。
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


## 取消当前拖拽并恢复拖拽前状态。
## [br]should_assert_consistency 表示取消完成后是否立即执行库存/占用一致性断言，普通拖拽取消使用默认 true；R 完整重置会传 false，把断言延后到玩家机关统一清理完成之后。
## [br]无返回值。
## [br]副作用：删除预览节点；若拖动的是已放置机关且节点仍有效，则恢复正式机关原位置和可见状态；随后清空拖拽状态字段。
## [br]边界条件：从库存取消不改变库存；已放置机关取消不改变 OccupancyRegistry，因为旧占用从未清除。若 _dragged_placed_token 已失效，不再解引用，只清理预览与拖拽状态，并在调试构建报告一致性异常；不静默重建 placed_tokens_by_id 或 OccupancyRegistry，也不实现自动恢复。R 完整重置传 false 是为了避免中间态断言早于后续玩家机关删除和占用注销流程。
func _cancel_current_drag(should_assert_consistency: bool = true) -> void:
	if _drag_source == _RuntimeInteractionTypes.DragSource.PLACED and _dragged_placed_token != null:
		if is_instance_valid(_dragged_placed_token):
			# 已放置机关拖拽期间保留旧逻辑占用，取消时只恢复正式视觉即可。
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


## 删除当前拖拽预览节点。
## [br]本函数无参数、无返回值。
## [br]副作用：对预览节点调用 queue_free() 并清空引用。
## [br]边界条件：预览节点为空时安全返回；不修改正式机关、库存或占用表。
func _clear_drag_preview_only() -> void:
	if _drag_preview_token != null:
		_drag_preview_token.queue_free()
		_drag_preview_token = null


## 清空当前拖拽状态字段。
## [br]本函数无参数、无返回值。
## [br]副作用：把拖拽来源、ID、格子和节点引用恢复为空状态。
## [br]边界条件：只在预览删除和正式机关状态已处理后调用，避免丢失恢复所需的原始格子信息。
func _reset_drag_state() -> void:
	_drag_source = _RuntimeInteractionTypes.DragSource.NONE
	_drag_mechanism_id = &""
	_drag_original_cell = INVALID_CELL
	_drag_preview_cell = INVALID_CELL
	_dragged_placed_token = null


## 创建一个 SingleCellMirror 节点并加入 RuntimeObjects。
## [br]mechanism_id 是节点显示和正式登记使用的 ID，cell 是初始逻辑格子，is_preview 表示是否为拖拽预览。
## [br]返回新创建的 SingleCellMirror 节点；副作用是实例化镜面场景并加入节点树。
## [br]边界条件：节点世界坐标由 cell_to_world() 统一计算；本函数不写库存、不写 OccupancyRegistry、不判断放置合法性；从机关栏新建镜面默认保持 SLASH，拖动已有镜面时由调用方复制原 orientation。
func _create_token_node(mechanism_id: StringName, cell: Vector2i, is_preview: bool) -> Variant:
	var token = _SingleCellMirrorScene.instantiate()
	runtime_objects.add_child(token)
	token.configure(mechanism_id, cell)
	token.set_world_position(_GridCoordinateRules.cell_to_world(cell))
	token.set_drag_preview(is_preview, true)
	return token


## 在两个镜面节点之间复制朝向配置。
## [br]source_token 是已有正式镜面，target_token 是刚创建的拖拽预览镜面。
## [br]无返回值；副作用是在两者都是 SingleCellMirror 时把 source_token.orientation 写入 target_token，保证拖动已有镜面时预览保留当前“/”或“\”朝向。
## [br]边界条件：本函数只复制内部配置，不写 OccupancyRegistry、库存或位置；若任一节点不是镜面则安全忽略，避免未来未知机关拖拽崩溃。
func _copy_mirror_orientation_if_possible(source_token: Variant, target_token: Variant) -> void:
	if not is_instance_valid(source_token) or not is_instance_valid(target_token):
		return
	if source_token is not SingleCellMirror or target_token is not SingleCellMirror:
		return
	var source_mirror: SingleCellMirror = source_token as SingleCellMirror
	var target_mirror: SingleCellMirror = target_token as SingleCellMirror
	target_mirror.set_orientation(source_mirror.orientation)


## 生成下一个正式镜面机关唯一 ID。
## [br]本函数无参数。
## [br]返回新的 StringName 机关 ID；副作用是递增内部序号。
## [br]边界条件：即使镜面被回收，旧 ID 不复用，避免占用表和节点映射调试时混淆。
func _make_next_prototype_token_id() -> StringName:
	var mechanism_id: StringName = StringName("%s_%d" % [MIRROR_TOKEN_TYPE_ID, _next_prototype_token_serial])
	_next_prototype_token_serial += 1
	return mechanism_id


## 判断当前是否存在拖拽操作。
## [br]本函数无参数。
## [br]返回 true 表示 _drag_source 不是 NONE；返回 false 表示没有拖拽。
## [br]本函数无副作用；边界条件：预览节点可能因异常被释放，本函数仍只以拖拽来源作为状态事实。
func is_dragging() -> bool:
	return _drag_source != _RuntimeInteractionTypes.DragSource.NONE


## 判断鼠标是否位于整个机关栏区域。
## [br]viewport_mouse_position 是视口坐标系下的鼠标位置。
## [br]返回 true 表示位于 InventoryBar 全局矩形内。
## [br]本函数无副作用；边界条件：用于回收判断，不要求精准拖到单个栏位。
func _is_mouse_over_inventory_bar(viewport_mouse_position: Vector2) -> bool:
	return inventory_bar.get_global_rect().has_point(viewport_mouse_position)


## 判断鼠标是否位于原型机关栏位区域。
## [br]viewport_mouse_position 是视口坐标系下的鼠标位置。
## [br]返回 true 表示位于 PrototypeTokenSlot 全局矩形内。
## [br]本函数无副作用；边界条件：只用于从库存拿取，数量为 0 时即使命中也不会开始拖拽。
func _is_mouse_over_prototype_slot(viewport_mouse_position: Vector2) -> bool:
	return prototype_token_slot.get_global_rect().has_point(viewport_mouse_position)


## 判断原型普通机关是否可以放到指定格子。
## [br]cell 是目标格子，ignored_mechanism_id 是移动已放置机关时允许忽略的自身 ID；从库存放置时可省略或传空 ID。
## [br]返回 true 表示当前原型 map_bounds 允许区域内的目标格为空；“空”同时要求未命中静态阻挡黑名单，且 OccupancyRegistry 中没有其他动态机关占用。
## [br]本函数无副作用；边界条件：INVALID_CELL 永远非法，墙体仍是普通机关不可覆盖的静态对象，拖动已放置机关时自己的原始占用可被 ignored_mechanism_id 忽略但其他机关占用仍非法。
func _is_valid_prototype_placement_cell(cell: Vector2i, ignored_mechanism_id: StringName = &"") -> bool:
	if cell == INVALID_CELL:
		return false
	if not map_bounds.has_point(cell):
		return false
	if _is_static_cell_blocked_for_placement(cell):
		return false
	if _is_cell_occupied_by_other(cell, ignored_mechanism_id):
		return false
	return true


## 判断目标格是否被当前原型的静态对象阻挡，不能用于放置普通单格机关。
## [br]cell 是目标格子。
## [br]返回 true 表示该格命中静态阻挡黑名单：wall_cells 中的墙体、主发射源 emitter_cell、任一普通独立水晶所在格，或当前场景已有的固定对象格。
## [br]本函数无副作用；边界条件：当前原型尚未实现 TileMapLayer 正式 placeable 标记，因此允许区域由 _is_valid_prototype_placement_cell() 的 map_bounds 检查提供，本函数只集中维护不可覆盖的静态对象规则。
func _is_static_cell_blocked_for_placement(cell: Vector2i) -> bool:
	if wall_cells.has(cell):
		return true
	if cell == emitter_cell:
		return true
	for crystal: BasicCrystal in crystals:
		if crystal.cell == cell:
			return true
	return false


## 判断目标格是否被其他机关占用。
## [br]cell 是目标格子，ignored_mechanism_id 是允许忽略的自身 ID。
## [br]返回 true 表示该格被非 ignored_mechanism_id 的机关占用。
## [br]本函数无副作用；边界条件：空占用返回 false，拖动已放置机关时原格自身占用可被忽略。
func _is_cell_occupied_by_other(cell: Vector2i, ignored_mechanism_id: StringName) -> bool:
	var occupied_id: StringName = get_mechanism_at(cell)
	if occupied_id == &"":
		return false
	return occupied_id != ignored_mechanism_id


## 刷新底部原型机关栏 UI。
## [br]本函数无参数、无返回值。
## [br]副作用：计算当前库存剩余与是否允许从道具栏拿取，把这两项事实传给 InventorySlotView.refresh_slot()，
## [br]由槽位组件统一负责剩余文本、占位符颜色与正式图标 self_modulate 的显示，控制器不再直接修改 TokenIcon.color 或 RemainingLabel.text。
## [br]边界条件：UI 只显示库存事实，不能自行修改库存；is_available 在库存大于 0 且当前运行状态允许拿取时为 true，
## [br]COMPLETED 或库存为 0 时为 false，槽位组件据此显示禁用灰色；R 返回 SETUP 后若库存大于 0，会恢复可用显示。
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


## 采集库存一致性只读纯数据快照（Diagnostics 批次 4B-G4）。
## [br]本函数无参数。
## [br]返回：InventoryConsistencySnapshot，冻结当前库存标量事实、OccupancyRegistry 本体一致性标志与六组对齐的条目级事实。
## [br]职责：执行 Node 生命周期保护；从真实状态读取纯数据；构造 InventoryConsistencySnapshot；返回快照。
## [br]副作用：只读访问 placed_tokens_by_id 与 occupancy；不修改库存、不修改 placed_tokens_by_id、不修改 OccupancyRegistry、不修复状态、不 queue_free、不写日志、不调用 SelfCheckRunner、不执行 A/B/C 一致性判断。
## [br]边界条件：D 类 Node 生命周期检查（is_instance_valid、is_queued_for_deletion）保留在本函数，不迁入 Diagnostics，不降级为 details/warning/日志；
## 生命周期验证通过后才读取 token.mechanism_id 与 token.cell；不把真实 Node 传给 Snapshot、Rules 或 Check；不把生命周期状态写进 Snapshot；
## dictionary_id == token.mechanism_id 属于 B 类共享规则，本函数只记录两个值，不在核心中重复 assert 它们相等；
## 六组容器按 placed_tokens_by_id 当前迭代顺序严格同步追加，不排序、不去重，不修改 OccupancyRegistry 返回数组，不持有其返回数组；
## occupancy.is_consistent() 每次采集只调用一次，不在核心复制 OccupancyRegistry 内部一致性算法；count==0 时 first_cell 使用 Vector2i.ZERO 占位；快照构造后由 Snapshot 自行 duplicate 输入。
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
		# count==0 时 first_cell 使用 Vector2i.ZERO 占位；规则只在 count==1 时比较 first_cell，占位值不参与比较。
		var occupancy_first_cell: Vector2i = Vector2i.ZERO if occupancy_cell_count == 0 else occupied_cells[0]

		dictionary_ids.append(mechanism_id)
		token_ids.append(token_id)
		token_cells.append(token_cell)
		occupancy_ids_at_token_cells.append(occupancy_id_at_token_cell)
		occupancy_cell_counts.append(occupancy_cell_count)
		occupancy_first_cells.append(occupancy_first_cell)

	# occupancy.is_consistent() 每次采集只调用一次；保留旧实现中 OccupancyRegistry 本体一致性判断的 push_error 行为，不在核心复制其内部算法。
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


## 断言原型机关库存、玩家机关节点映射与占用表保持一致。
## [br]本函数无参数、无返回值。
## [br]副作用：调试构建中采集纯数据快照并调用 InventoryConsistencyRules.collect_failures，对失败列表为空执行 Debug 硬 assert，失败消息完整包含全部失败详情；发布构建因首部守卫直接返回，无副作用。
## [br]边界条件：六个运行期事务边界调用点继续调用本函数，事务完成不依赖本函数返回值；A/B/C 规则唯一来源为 InventoryConsistencyRules，核心中不存在其副本；D 类 Node 生命周期检查只存在于采集函数；不使用 SelfCheckRunner，不创建 InventoryConsistencyCheck，不修复任何数据，不把 assert 改为 push_warning、普通日志或返回 bool。
func _assert_inventory_consistency() -> void:
	if not OS.is_debug_build():
		return
	var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
	var failures: PackedStringArray = _InventoryConsistencyRules.collect_failures(snapshot)
	assert(failures.is_empty(),
			"库存一致性断言失败：\n%s" % ["\n".join(failures)])


## 执行库存一致性启动期自检（Diagnostics 批次 4B-G4）。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中作为第七项调用。
## [br]检查逻辑复用玩法层共享纯规则 InventoryConsistencyRules（单一来源）与只读快照 InventoryConsistencySnapshot，由 InventoryConsistencyCheck 包装为无参 run()。
## [br]本函数通过单项 SelfCheckRunner 执行该检查：采集快照、构造 Check、包装为 SelfCheckCallable 并交由 _run_startup_self_check_via_controller 注册、运行与校验。
## [br]失败语义：注册失败、Runner 结构错误或 SelfCheckResult.passed == false 时由 _run_startup_self_check_via_controller 立即 assert，保留原 Debug 硬断言边界，不降级为 warning；启动采集前的 Node 生命周期保护仍在 core_loop 的 _collect_inventory_consistency_snapshot 中。
## [br]边界条件：保持原启动顺序，本函数仍位于 _ready 中第七项；不使用 Callable.bind、不使用 lambda；不修改 SelfCheckRunner；不直接调用 check.run()；不在 Check 中采集真实状态；不让 Diagnostics 持有 Node 或 OccupancyRegistry；不参与业务状态修改，不写文件，不写日志。
func _run_inventory_consistency_self_check() -> void:
	var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
	var check: _InventoryConsistencyCheck = _InventoryConsistencyCheck.new(snapshot)
	var definition: SelfCheckCallable = SelfCheckCallable.new(
			&"inventory_consistency",
			"库存与玩家机关占用一致性自检",
			Callable(check, "run")
	)
	_run_startup_self_check_via_controller(definition, &"startup_inventory_consistency")
