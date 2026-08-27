extends Node2D

## 核心闭环原型关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入，发起普通主发射源最小脉冲光线（Vector2i 逐格路径，无 Area2D/Tween/物理射线），
## 通过 OccupancyRegistry 解析单格镜面并改向、点亮普通独立水晶、保持关卡完成结果；实现最小镜面库存、拖拽放置/移动/回收与 SETUP 右键朝向配置。
## 状态事实所有权：五态（SETUP/READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）由 _run_state_controller 持有；pulse_generation、runtime_moves_used、
## 发射请求编排、异步脉冲结束与完整 R 重置顺序由 _level_runtime_controller 唯一持有；玩家机关映射 placed_tokens_by_id 与机关序号由 _placement_controller 唯一持有；
## 玩家机关库存剩余由 _inventory_controller 持有；目标完成事实（水晶激活、完成判断、运行期重置）由 _objective_controller 唯一持有。OccupancyRegistry 是格子占用唯一事实来源。
## 核心只保留接线、输入转发、右键镜面配置入口、节点工厂、UI 适配与启动自检入口；七项启动自检编排与摘要日志由 _startup_self_check_coordinator 整块负责。
## 正式运行权限：SETUP 允许完整布置且移动不计次，但 Space 须先「开始运行」进入 READY_TO_FIRE 才可发射；READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW 允许拿取/放置/移动/回收但右键配置锁定，READY_TO_FIRE/MOVE_WINDOW/PULSE_ACTIVE 可 Space 发射（SETUP/COMPLETED 禁止 Space）；
## Q 切换主发射器光形态（M4-E4）：关卡 allow_form_switch=true 时 SETUP/READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW 均可（COMPLETED 禁止），只影响后续发射；成功切换显示上方居中 1 秒形态提示。
## 仅“已放置机关跨格直接移动”成功提交后消耗 runtime_move_limit 一次；COMPLETED 冻结全部交互，只允许 R。
## R 是完整关卡重置（由 _level_runtime_controller.reset_runtime 执行）：递增 pulse_generation 使旧异步失效 → 安全取消拖拽 → 清光路/水晶/完成状态 → 逐个注销玩家机关占用并退回库存 → 清零 runtime_moves_used → 回 SETUP；不删除发射器/墙体/水晶/静态内容。
## AF-07 起本脚本同时作为统一 LevelRuntimeHost（gameplay/runtime/level_runtime_host.gd）的关卡控制器基类：
## 内容角色经 LevelRoot 子节点间接解析（见 _content_root），运行链与 HUD 接线单一来源，不复制第二套 Runtime。
## AF-10 第一批：启动扫描 RuntimeObjects 直属预置机关（PlaceableToken 契约）经 _PreplacedMechanismAdopter 注册进
## 占用/查询（不扣库存、不进玩家放置映射、R 不清理）；库存总量改读关卡根 metadata inventory_entries
## （MetadataInventoryReader 复用 LevelInventoryEntry schema），缺失时退回 PROTOTYPE_TOKEN_TOTAL 兼容。


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
## AF-10：原型槽位机关的稳定 content_type_id，与 gameplay/content/definitions/basic_single_cell_mirror.tres
## 声明一致；用于从关卡根 metadata inventory_entries 读取该类型的初始库存数量。
const PROTOTYPE_TOKEN_TYPE_ID: StringName = &"basic_single_cell_mirror"
const INVALID_CELL: Vector2i = Vector2i(-999999, -999999)


@export var map_bounds: Rect2i = Rect2i(0, 0, 16, 16)
@export var wall_cells: Array[Vector2i] = [Vector2i(5, 3)]

## 运行期移动次数上限。仅在 PULSE_ACTIVE 或 MOVE_WINDOW 中成功跨格移动已放置机关时消耗；SETUP 移动不受此限制。
@export_range(0, 99, 1) var runtime_move_limit: int = 1

# 四层 TileMapLayer 接线（D5-B.1）：Terrain/Wall/LegalArea/Decoration 均已接入对应 TileSet，visible=false 不改变当前运行画面；
# 启动构造只读快照 _tile_layer_snapshot 复制四层 used cells（D5-B.2A）：快照作为正式运行 Terrain/LegalArea/Wall 唯一事实接入 LevelWorldQuery，map_bounds/wall_cells 退化为 Diagnostics/导出与旧兼容路径。
# 格↔世界换算仍由 GridCoordinateRules 实现，不依赖 map_to_local。
# AF-07 内容根解析：Host 模式下纯关卡 Scene 实例挂在子节点 LevelRoot 上（由 level_runtime_host.gd 装载），
# 全部内容角色（四层 TileMapLayer / RuntimeObjects / LightPathLayer / 发射器配置 / 水晶）在其下解析；
# 原型场景无 LevelRoot 子节点时内容根为自身，行为与 AF-07 前保持不变。本变量声明须早于其余内容 @onready。
@onready var _content_root: Node2D = _resolve_content_root()
@onready var terrain_layer: TileMapLayer = _content_root.get_node("TerrainLayer") as TileMapLayer
@onready var wall_layer: TileMapLayer = _content_root.get_node("WallLayer") as TileMapLayer
@onready var legal_area_layer: TileMapLayer = _content_root.get_node("LegalAreaLayer") as TileMapLayer
@onready var decoration_layer: TileMapLayer = _content_root.get_node("DecorationLayer") as TileMapLayer
@onready var runtime_objects: Node2D = _content_root.get_node("RuntimeObjects") as Node2D
@onready var light_path_layer: Node2D = _content_root.get_node("LightPathLayer") as Node2D
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var hint_label: Label = $CanvasLayer/HintLabel
@onready var complete_label: Label = $CanvasLayer/CompleteLabel
@onready var inventory_bar: Control = $CanvasLayer/InventoryBar
@onready var prototype_token_slot: _InventorySlotViewScript = $CanvasLayer/InventoryBar/MarginContainer/HBoxContainer/PrototypeTokenSlot
@onready var runtime_move_label: Label = $CanvasLayer/RuntimeMoveLabel
## AF-07 内容根水晶采集：原型场景保持原固定路径 RuntimeObjects/Crystal 单水晶；Host 模式递归发现纯关卡 Scene 内全部水晶。
@onready var crystals: Array[BasicCrystal] = _collect_content_crystals()
## 发射器关卡配置节点（固定角色路径 RuntimeObjects/Emitter，仅预制场景内部接线，不作为稳定 emitter_id）。
## 运行时启动读取一次其 position 与 ray_default_direction 构造 FixedEmitter，不监听运行期节点移动或配置变化。
@onready var _emitter_config: _EmitterConfigNode = _content_root.get_node_or_null("RuntimeObjects/Emitter") as _EmitterConfigNode

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
# AF-10 预置机关收编器：扫描 RuntimeObjects 直属正式机关契约节点注册进占用/查询；不进玩家放置映射、不扣库存。
const _PreplacedMechanismAdopter: GDScript = preload(
	"res://gameplay/placement/preplaced_mechanism_adopter.gd"
)
# AF-10 关卡根 inventory_entries metadata 只读解析器：复用 LevelInventoryEntry 冻结 schema，缺失时退回原型默认值。
const _MetadataInventoryReader: GDScript = preload(
	"res://gameplay/placement/inventory/metadata_inventory_reader.gd"
)
# AF-10 第二批 关卡根 move_limit metadata 只读解析器：镜像 Authoring 冻结 schema {enabled,max_count}，
# 启用时覆盖场景导出上限，缺失/禁用保持 @export runtime_move_limit 原值兼容。
const _MetadataMoveLimitReader: GDScript = preload(
	"res://gameplay/placement/rules/metadata_move_limit_reader.gd"
)
# AF-10 第三批 多类型库存门面 / 道具卡 Presenter / 运行期 Definition 索引：
# metadata inventory_entries 有合法条目时按类型独立扣还并动态建卡（图标唯一来源 ObjectVisualProfile.inventory_icon）；
# 工厂场景经 Registry 解析（未知类型安全失败回滚），无条目保持旧单类型路径行为不变。
const _MultiTypeInventory: GDScript = preload(
	"res://gameplay/placement/inventory/multi_type_inventory.gd"
)
const _InventoryCardBar: GDScript = preload(
	"res://gameplay/ui/inventory_card_bar.gd"
)
const _RuntimeDefinitionIndex: GDScript = preload(
	"res://gameplay/placement/inventory/runtime_definition_index.gd"
)
# 启动自检协调器：核心持有的唯一实例，整块负责七项启动自检编排、三层 Debug 硬断言与启动摘要日志；核心只采集场景数据并调用 run_all。
const _StartupSelfCheckCoordinator: GDScript = preload(
	"res://gameplay/diagnostics/startup_self_check_coordinator.gd"
)
const _SingleCellMirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
# 速度型机关脚本（右键类型分发用）：preload 引用以规避 Godot MCP run_project 不重建全局
# class_name 缓存导致新类型解析失败的问题（与 AGENTS.md「preload 常量模式」约定一致）。
# 仅用于 is/as 类型收窄后调用机关自身入口；不在核心复制方向枚举 / cycle_direction 逻辑——
# direction 唯一事实与八方向循环逻辑唯一存在于各机关脚本，核心保持「只转发、不实现」的边界。
const _ParticleAccelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_accelerator.gd")
const _ParticleDecelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_decelerator.gd")
const _InventorySlotViewScript: GDScript = preload("res://gameplay/ui/inventory_slot_view.gd")
# D7-3 正式「开始运行」UI 视图：拥有按钮/状态提示/invalid 最小反馈，只由真实 RunState 驱动；core_loop 只构造接线与公开转发。
const _RunStartView: GDScript = preload("res://gameplay/ui/run_start_view.gd")
# M4-E4 形态切换提示 UI（用户冻结视觉）：Q 成功切换时屏幕上方居中提示 1 秒；core_loop 只构造接线。
const _FormSwitchToastView: GDScript = preload("res://gameplay/ui/form_switch_toast_view.gd")
# D7-R1 Runtime 只读采样器（Runtime → Sampler → RuntimeSnapshotData）与 Debug-only 游戏内控制台；
# 均只读诊断链路，核心只构造接线（控制台仅 Debug 构造，Release 零接线）。
const _RuntimeSnapshotSampler: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_sampler.gd")
const _DebugConsoleView: GDScript = preload("res://gameplay/diagnostics/console/debug_console_view.gd")
# D7-3 start_run() 返回结构化 LevelValidationResult 供 UI 最小反馈（runtime → level/validation 依赖方向）。
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
# 普通光线路径视觉控制器：完整拥有光路视觉节点集合与四方向接线，核心只调用 show_step / clear_path。
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
# Particle 视觉控制器（D7-4 B4a）：完整拥有光粒视觉节点集合（runtime_id→View 映射/创建/更新/terminate/清理）；核心只构造并把 Runtime detached 事件接给它。
const _ParticleVisualController: GDScript = preload("res://gameplay/visuals/particles/particle_visual_controller.gd")
# 运行交互共享类型契约（RunState / DragSource）。
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
# 运行期移动纯规则；正式玩法调用与 runtime_move 启动自检共用同一规则来源。
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
# RunStateController：核心持有的唯一运行状态所有者，负责五态事实、最小合法转换与 state_changed 信号；不加入场景树、不设为 Autoload。
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
# 拖拽业务流程控制器：完整拥有一次拖拽的生命周期（拿取/预览/隐藏/提交/回收/取消/清理）；核心只转发指针位置、取消请求与场景适配 Callable。
const _DragFlowController: GDScript = preload("res://gameplay/interaction/drag_flow_controller.gd")
# 玩家输入分类器：把 InputEvent 分类为业务命令；不查询状态、不命中 UI、不转网格、不执行业务。
const _PlayerInteractionController: GDScript = preload("res://gameplay/interaction/player_interaction_controller.gd")
# 世界只读查询门面与光线层薄适配器；不加入场景树、不设为 Autoload。
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LightWorldQuery: GDScript = preload("res://gameplay/world/light_world_query.gd")
# 四层 TileMapLayer 只读快照（D5-B.1）：validate_layers 校验后 new() 构造，构造时复制 used cells，不持有 TileMapLayer；D5-B.2A 起作为正式运行事实接入 LevelWorldQuery。
const _LevelTileLayerSnapshot: GDScript = preload("res://gameplay/world/level_tile_layer_snapshot.gd")
# 关卡稳定对象索引所有者（D3-C）：水晶按显式 crystal_id 与 cell 双向索引，LevelWorldQuery 据此查询水晶，不暴露可写字典。
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
# 目标完成事实唯一所有者（D3-D）：按 cell 激活水晶、判断完成、运行期重置水晶；核心只读取 is_completed()/reset_runtime()，不保留第二套目标业务实现。
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
# 固定发射器与发射请求数据；运行期格子和方向唯一所有者为 FixedEmitter，由 EmitterConfigNode 启动快照构造。
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
# 发射器关卡配置节点：承载唯一持久化位置事实 position 与光线方向事实 ray_default_direction。
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
# 正式运行期编排控制器（D3-E）：完整拥有 pulse_generation、runtime_moves_used、发射编排、异步脉冲结束与 R 重置顺序；核心只调 request_fire/reset_runtime 与运行期移动次数查询。
const _LevelRuntimeController: GDScript = preload("res://gameplay/runtime/level_runtime_controller.gd")
var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()

## 玩家机关库存事实所有者：运行期剩余数量唯一事实来源，扣除/归还/重置经此实例；拖拽开始时不提前扣数量，仅合法放置成功后才扣除。
## AF-10 第三批：metadata 有合法条目时此位注入 MultiTypeInventory 子类实例（每类型独立栈，Σ 聚合口径兼容旧读取方）。
var _inventory_controller: _InventoryController = _InventoryController.new(PROTOTYPE_TOKEN_TOTAL)

## AF-10 第三批 多类型库存门面（_inventory_controller 的多类型形态；null = 旧单类型标量路径）。
var _multi_inventory: Variant = null

## AF-10 第三批 道具卡 Presenter（动态多类型道具栏；null = metadata 无条目，旧 PrototypeTokenSlot 路径）。
var _inventory_card_bar: Variant = null

## AF-10 第三批 运行期 Definition 索引：懒构建 FormalContentRegistry，供工厂场景解析与卡数据构建。
var _definition_index: _RuntimeDefinitionIndex = null

## 玩家机关放置/移动/回收事务控制器；唯一持有 placed_tokens_by_id 与机关序号，_ready 中构造并注入依赖。核心只发事务请求并按结果清理拖拽。
var _placement_controller: _PlacementController = null

## AF-10 预置机关收编器：_ready 中构造并扫描 RuntimeObjects 直属机关契约节点；持有预置机关只读映射，
## R 清理（clear_all_placed 只遍历玩家放置映射）与库存一致性断言均不涉及预置机关。
var _preplaced_adopter: _PreplacedMechanismAdopter = null

## 拖拽业务流程控制器：核心持有的唯一实例，拥有一次拖拽的完整业务生命周期；核心只转发指针位置、取消请求与场景适配 Callable。
var _drag_flow_controller: _DragFlowController = null

## 玩家输入分类器：把 _input 收到的 InputEvent 分类为业务命令，自身不执行任何业务副作用。
var _player_interaction_controller: _PlayerInteractionController = _PlayerInteractionController.new()

## 启动自检协调器：核心持有的唯一实例，整块负责七项启动自检编排与摘要日志；不作为 Node、不设为 Autoload。
var _startup_self_check_coordinator: _StartupSelfCheckCoordinator = _StartupSelfCheckCoordinator.new()

## 运行状态控制器：核心持有的唯一运行状态所有者，负责五态事实、最小合法转换与 state_changed 信号；核心不持有 current_run_state 副本。
## COMPLETED 前取消拖拽与 pulse_generation 异步回调保护由 LevelRuntimeController 完成；核心不持有 pulse_generation。不作为 Node、不设为 Autoload。
var _run_state_controller: _RunStateController = _RunStateController.new()

## 普通光线路径视觉控制器：完整拥有光路视觉节点集合（逐格创建/记录/cell→世界定位/四方向接线/路径清理）；核心只调用 show_step 与 clear_path，不持有第二套视觉创建实现。
var _light_visual_controller: _LightVisualController = null

## Particle 视觉控制器（D7-4 B4a）：完整拥有光粒视觉节点集合（runtime_id→View 映射/创建/更新/terminate/清理）；核心只构造并把 Runtime detached 事件接给它，不解释事件/维护映射。
var _particle_visual_controller: _ParticleVisualController = null

## 世界只读查询门面：在所有真实依赖初始化后构造，持有容器引用而非复制（容器运行期只原地增删，从不整体重赋值）；只读，不修改世界事实。
var _level_world_query: _LevelWorldQuery = null

## 四层 TileMapLayer 只读快照（D5-B.1）：_ready 中由四层 used cells 构造；缺层时保持 null，不退回 map_bounds。D5-B.2A 起非空时接入 LevelWorldQuery 作为正式运行 Terrain/LegalArea/Wall 唯一事实，放置/光线据此区分越界与墙体。
var _tile_layer_snapshot: _LevelTileLayerSnapshot = null

## 关卡稳定对象索引：_ready 中遍历 crystals 按显式 crystal_id 与 cell 注册，LevelWorldQuery 据此查询水晶；不暴露内部字典。
var _level_object_registry: _LevelObjectRegistry = _LevelObjectRegistry.new()

## 目标完成事实所有者：按 cell 激活水晶、判断完成、运行期重置；_ready 中在 Registry 填充后构造，核心只读取事实，不持有完成字段副本。
var _objective_controller: _ObjectiveController = null

## 普通光线只读薄适配层：内部依赖 _level_world_query，只组合既有边界与墙体规则，不新增规则、不执行传播循环或副作用。
var _light_world_query: _LightWorldQuery = null

## 固定发射器：运行期格子与方向的唯一所有者；_ready 中由 EmitterConfigNode 启动快照构造一次，此后 fire_light 与 LevelWorldQuery 只读取本实例。
var _fixed_emitter: _FixedEmitter = null

## 正式运行期编排控制器：_ready 中构造并 add_child；核心只调 request_fire/reset_runtime 与运行期移动次数查询/扣除委托，不持有 pulse_generation 或 runtime_moves_used。
var _level_runtime_controller: _LevelRuntimeController = null

## D7-3 正式「开始运行」UI 视图：拥有按钮/状态提示/invalid 最小反馈；只由真实 RunState 驱动，核心只构造接线并公开 start_run() 转发。
var _run_start_view: _RunStartView = null

## M4-E4 形态切换提示 UI：Q 成功切换时由本核心把新形态交给它显示（上方居中 1 秒）；被拒 Q 不触发。
var _form_switch_toast_view: _FormSwitchToastView = null

## D7-R1 Runtime 只读采样器（Debug 构造）：经 LRC 只读诊断出口 + 各 RefCounted 控制器只读访问器采样。
var _runtime_snapshot_sampler: _RuntimeSnapshotSampler = null

## D7-R1 Debug-only 游戏内控制台（仅 Debug 构造；只读 + 手动快照触发；Release 不存在本实例）。
var _debug_console_view: _DebugConsoleView = null

## 关卡 Q 形态切换开关（M4-E4）：_ready 中由 EmitterConfigNode 启动快照读取一次，注入 LevelRuntimeController；运行期不再监听配置变化。
var _allow_form_switch: bool = false


## 初始化核心闭环原型关卡：刷新机关栏 UI；仅调试构建执行七项启动自检与摘要日志，发布构建跳过，避免把调试断言作为运行期必需流程。
func _ready() -> void:
	# 早期连接运行状态信号，避免错过首次状态变化；本回调只刷新机关栏 UI。
	_run_state_controller.state_changed.connect(_on_run_state_changed)
	# 光路视觉控制器先构造：注入 LightPathLayer 作为视觉父节点，视觉资源与颜色由控制器自持。
	_light_visual_controller = _LightVisualController.new(light_path_layer)
	# Particle 视觉控制器（D7-4 B4a）：注入同一 LightPathLayer 作为视觉父节点；Runtime detached 事件经 LRC publish Callable 接给它。
	_particle_visual_controller = _ParticleVisualController.new(light_path_layer)
	# 四层 TileMapLayer 只读快照（D5-B.1）：先 validate_layers 校验四层再 new() 复制 used cells；缺层 push_error 且保持 null，不退回 map_bounds。
	_build_tile_layer_snapshot()
	# 快照为正式运行 Terrain/LegalArea/Wall 唯一事实来源（D5-B.2A）：构造失败则停止后续世界查询接线，避免空快照静默退回 map_bounds+wall_cells 成为正式运行事实。
	if _tile_layer_snapshot == null:
		_abort_runtime_initialization("四层 TileMapLayer 只读快照构造失败，已停止世界查询初始化。")
		return
	# AF-10 运行时库存初始化：metadata inventory_entries 有合法条目时走多类型门面（每类型独立栈 + 道具卡
	# Presenter 动态建卡 + PlacementController 按类型扣/还路由）；无条目保持旧单类型标量路径
	# （read_initial_total_for_type 兼容：缺失退回原型默认 PROTOTYPE_TOKEN_TOTAL）。
	_definition_index = _RuntimeDefinitionIndex.new()
	var inventory_entries: Array[Dictionary] = _MetadataInventoryReader.read_ordered_entries(_content_root)
	if inventory_entries.is_empty():
		_inventory_controller = _InventoryController.new(_resolve_initial_inventory_total())
	else:
		_inventory_controller = _MultiTypeInventory.new(inventory_entries)
		_multi_inventory = _inventory_controller
		_inventory_card_bar = _InventoryCardBar.new()
		_inventory_card_bar.setup(prototype_token_slot.get_parent(), prototype_token_slot)
		_inventory_card_bar.build_cards(
			_InventoryCardBar.build_card_models(_definition_index.get_registry(), inventory_entries)
		)
	# AF-10 第二批 运行期移动上限：读关卡根 metadata move_limit（Authoring 冻结 schema），启用时覆盖场景导出值；
	# 缺失/禁用保持 @export runtime_move_limit 原值兼容。须在 LevelRuntimeController 构造与首次运行 UI 刷新前生效。
	runtime_move_limit = _MetadataMoveLimitReader.read_runtime_move_limit(_content_root, runtime_move_limit)
	# 放置事务控制器先于只读查询门面构造：LevelWorldQuery 需持有控制器映射引用，供光线层 cell→ID→节点解析。
	_placement_controller = _PlacementController.new(
		occupancy,
		_inventory_controller,
		Callable(self, "_create_formal_token_node")
	)
	# 发射配置来源为场景内 EmitterConfigNode：读取一次启动快照构造不可变 FixedEmitter。
	# B3b-1 起 RAY/PARTICLE 均为合法 Runtime form（is_runtime_form_supported 与真实 Runtime 能力同步）；返回 false 仅在引入第三种未接形态时安全中止。
	if not _build_fixed_emitter_from_config():
		return
	# 稳定对象索引：遍历 @onready crystals，按显式 crystal_id 与 cell 注册；任一失败 push_error 并 assert 暴露，不静默跳过。
	for crystal: BasicCrystal in crystals:
		assert(_level_object_registry.register_crystal(crystal.get_crystal_id(), crystal.cell, crystal),
				"水晶注册失败：crystal_id=%s cell=%s" % [crystal.get_crystal_id(), crystal.cell])
	# 目标完成事实所有者：在 Registry 填充后构造，唯一持有水晶激活/完成判断/运行期重置。
	_objective_controller = _ObjectiveController.new(_level_object_registry)
	# 在所有真实依赖初始化后构造只读查询门面；水晶查询走 Registry，机关节点经核心 _resolve_mechanism_node
	# 只读 Callable 解析（玩家放置映射 PlacementController.get_placed_node 优先，AF-10 起回退预置机关收编映射），
	# 不共享可写映射。
	# 首个粗筛边界参数取快照 Terrain 外包矩形（D5-B.2B）：正式运行边界事实即 Terrain bounds，构造现场不再误传 map_bounds 为边界；快照作为末参接入为 Terrain/LegalArea/Wall 唯一事实。
	# wall_cells 仍传入仅供 LevelWorldQuery 无快照兼容路径（本场景已由上方守卫保证非空快照，不触发）；map_bounds 退化为导出与旧兼容，不作为正式运行边界。
	_level_world_query = _LevelWorldQuery.new(
		_tile_layer_snapshot.get_terrain_bounds(),
		wall_cells,
		_fixed_emitter.get_cell(),
		_level_object_registry,
		occupancy,
		Callable(self, "_resolve_mechanism_node"),
		_tile_layer_snapshot
	)
	_placement_controller.set_level_world_query(_level_world_query)
	# AF-10 预置机关收编：扫描 RuntimeObjects 直属正式机关契约节点注册进占用表；预置机关不扣库存、
	# 不进玩家放置映射（玩家拖拽/回收/右键配置经 has_placed 守卫安全忽略预置机关），R 重置不清理，保持场景原状。
	_preplaced_adopter = _PreplacedMechanismAdopter.new(
		occupancy,
		Callable(self, "_is_preplaced_cell_adoptable")
	)
	_preplaced_adopter.adopt_all(runtime_objects)
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
		Callable(self, "_assert_inventory_consistency"),
		Callable(_particle_visual_controller, "handle_event"),
		null,
		Callable(),
		_allow_form_switch
	)
	add_child(_level_runtime_controller)
	_update_inventory_ui()
	_update_runtime_move_ui()
	# D7-3 正式「开始运行」UI：构造 RunStartView（拥有按钮/提示/invalid 最小反馈）挂到 CanvasLayer，
	# 注入 start_run 公开回调与初始真实 RunState；后续刷新由 _on_run_state_changed 转发，禁止第二套“是否已开始”布尔。
	_run_start_view = _RunStartView.new(Callable(self, "start_run"))
	_run_start_view.setup(canvas_layer, hint_label)
	_run_start_view.update_for_state(_get_current_run_state())
	# M4-E4 形态切换提示 UI：挂到同一 CanvasLayer；只显示成功切换结果（被拒 Q 由 _switch_light_form 不触发体现）。
	_form_switch_toast_view = _FormSwitchToastView.new()
	_form_switch_toast_view.setup(canvas_layer)
	# D7-R1 Debug 诊断链路：Runtime 只读采样器 + Debug-only 控制台（F3 开关）；仅 Debug 构造，Release 零接线。
	# 采样器/控制台均只读（不推进 Tick、不改 RunState/emission/cooldown）；写盘仅控制台显式按钮手动触发。
	if OS.is_debug_build():
		_runtime_snapshot_sampler = _RuntimeSnapshotSampler.new(
			Callable(_level_runtime_controller, "get_runtime_diagnostics_snapshot"),
			_run_state_controller,
			_fixed_emitter,
			_objective_controller,
			_level_object_registry,
			_inventory_controller,
			_placement_controller
		)
		_debug_console_view = _DebugConsoleView.new(Callable(_runtime_snapshot_sampler, "sample"))
		_debug_console_view.setup(canvas_layer)
	if OS.is_debug_build():
		# 采集网格采样格（含 Registry 完整性前置断言）与库存一致性只读快照，交由协调器按固定顺序执行七项自检并写摘要日志。
		var sample_cells: Array[Vector2i] = _collect_grid_coordinate_sample_cells()
		var snapshot: _InventoryConsistencySnapshot = _collect_inventory_consistency_snapshot()
		_startup_self_check_coordinator.run_all(sample_cells, snapshot, true, true)


## 解析关卡内容根（AF-07）：存在 Node2D 子节点 LevelRoot（Host 装载的纯关卡 Scene 实例）时以其为内容根；否则内容根为自身（原型场景）。
func _resolve_content_root() -> Node2D:
	var level_root: Node = get_node_or_null("LevelRoot")
	if level_root is Node2D:
		return level_root
	return self


## 采集内容根下的水晶（AF-07）：原型场景走原固定路径单水晶；Host 模式递归发现（owned=false 覆盖运行期实例化的场景，owner 为空）。
func _collect_content_crystals() -> Array[BasicCrystal]:
	if _content_root == self:
		return [$RuntimeObjects/Crystal]
	var discovered: Array[BasicCrystal] = []
	for node: Node in _content_root.find_children("*", "BasicCrystal", true, false):
		discovered.append(node as BasicCrystal)
	return discovered


## AF-10：解析原型槽位类型的初始库存总量（关卡根 metadata inventory_entries → 缺失时原型默认值兼容）。
## 纯读取转发 MetadataInventoryReader，不在核心复制解析规则。
func _resolve_initial_inventory_total() -> int:
	return _MetadataInventoryReader.read_initial_total_for_type(
		_content_root,
		PROTOTYPE_TOKEN_TYPE_ID,
		PROTOTYPE_TOKEN_TOTAL
	)


## AF-10 预置机关收编格合法性：Terrain 边界内且非静态阻挡（墙/发射器格/水晶）。
## 只读组合 LevelWorldQuery 既有判定，不建第二套格合法性规则；占用冲突由收编器经 OccupancyRegistry 原子拒绝。
## 不检查 LegalArea：合法区约束的是玩家可放置范围，预置机关为作者事实，边界/静态阻挡即非法格下限。
func _is_preplaced_cell_adoptable(cell: Vector2i) -> bool:
	return _level_world_query.is_in_bounds(cell) and not _level_world_query.is_static_blocked_for_placement(cell)


## AF-10 机关节点统一解析（注入 LevelWorldQuery 的 get_placed_node_by_id Callable）：
## 先查玩家放置映射（PlacementController.get_placed_node），再回退预置机关收编映射；均未命中返回 null。
## 玩家机关与预置机关共用 OccupancyRegistry 占用事实与本解析入口，光线层/光粒层解析无感切换。
func _resolve_mechanism_node(mechanism_id: StringName) -> Variant:
	var placed_node: Variant = _placement_controller.get_placed_node(mechanism_id)
	if placed_node != null:
		return placed_node
	if _preplaced_adopter != null:
		return _preplaced_adopter.get_preplaced_node(mechanism_id)
	return null


## 构造四层 TileMapLayer 只读快照（D5-B.1；D5-B.1R 两段式构造）：先调静态校验 validate_layers 检查四层有效；校验失败保持 _tile_layer_snapshot 为 null 并安全返回，不退回 map_bounds；成功则直接 new() 构造快照。
## D5-B.2A 起校验失败（null 快照）由 _ready 中止后续世界查询初始化；成功则接入 LevelWorldQuery 作为正式运行 Terrain/LegalArea/Wall 唯一事实。
func _build_tile_layer_snapshot() -> void:
	if not _LevelTileLayerSnapshot.validate_layers(
		terrain_layer, wall_layer, legal_area_layer, decoration_layer
	):
		_tile_layer_snapshot = null
		return
	_tile_layer_snapshot = _LevelTileLayerSnapshot.new(
		terrain_layer, wall_layer, legal_area_layer, decoration_layer
	)


## 由 EmitterConfigNode 构造启动快照与不可变 FixedEmitter；节点缺失或形态未接运行时则安全中止。
## 返回 true 表示已构造 _fixed_emitter；false 表示已输出明确错误并中止初始化，调用方应停止后续接线。
## B3b-1 起读取 form + 活动方向（RAY→ray_default / PARTICLE→particle_default）构造对应形态 FixedEmitter；不再因 PARTICLE 拒绝初始化。
func _build_fixed_emitter_from_config() -> bool:
	if _emitter_config == null:
		_abort_runtime_initialization("RuntimeObjects/Emitter 节点缺失或类型不符，无法构造发射器。")
		return false
	# 执行阶段闸门与真实 Runtime 能力同步（B3b-1：RAY/PARTICLE 均已接）；返回 false 时安全中止，不静默降级为另一形态。
	if not _emitter_config.is_runtime_form_supported():
		_abort_runtime_initialization("default_light_form 未接运行时发射，已拒绝初始化。")
		return false
	# 启动快照：position 派生 cell 为唯一位置事实；活动方向（随形态取 ray/particle）为唯一方向事实；form 为唯一形态事实。
	# 本组局部值仅用于本次构造，不作为第二份持久事实；FixedEmitter 三参构造写入 cell/direction/form。
	var start_cell: Vector2i = _emitter_config.get_cell()
	var active_direction: Vector2i = _emitter_config.get_active_direction_vector()
	var light_form: int = _emitter_config.get_default_light_form()
	# M4-E4：Q 形态切换关卡开关同属启动快照，读取一次注入 LevelRuntimeController（运行期不监听配置变化）。
	_allow_form_switch = _emitter_config.is_form_switch_allowed()
	_fixed_emitter = _FixedEmitter.new(start_cell, active_direction, light_form)
	return true


## 安全中止运行时初始化：输出明确错误，阻止后续空对象接线与输入持续崩溃。
func _abort_runtime_initialization(reason: String) -> void:
	push_error("CoreLoopPrototype: %s" % reason)


## 处理关卡输入动作和鼠标拖拽事件：fire_light 转发到 LevelRuntimeController.request_fire（拖拽中/SETUP/COMPLETED/0.5s cooldown 未到在控制器内拒绝；PULSE_ACTIVE repeated fire 已于 M4-E3 开放）；switch_light_form（Q）转发到 _switch_light_form（M4-E4；关卡 allow_form_switch + 非 COMPLETED 权限门在控制器内，被拒不显示提示）；reset_level 转发到 reset_runtime()；鼠标左键按运行权限驱动放置/移动/回收。
## 拖拽中按 Space 由控制器拒绝；拖拽中按 R 不依赖 _input 预取消，由 reset_runtime() 统一安全取消拖拽；PULSE_ACTIVE 期间布局变化只影响后续发射，不回溯当前脉冲。
func _input(event: InputEvent) -> void:
	# 运行时初始化被中止（如 PARTICLE 未接运行时）时忽略全部输入，避免空对象持续崩溃。
	if _level_runtime_controller == null:
		return
	var command: _PlayerInteractionController.Command = _player_interaction_controller.translate(event)
	match command.kind:
		_PlayerInteractionController.Command.Kind.RESET:
			reset_runtime()
		_PlayerInteractionController.Command.Kind.FIRE:
			fire_light()
		_PlayerInteractionController.Command.Kind.SWITCH_FORM:
			_switch_light_form()
		_PlayerInteractionController.Command.Kind.PRIMARY_PRESS:
			_drag_flow_controller.try_begin_drag(command.pointer_position)
		_PlayerInteractionController.Command.Kind.PRIMARY_RELEASE:
			if is_dragging():
				_drag_flow_controller.finish_drag(command.pointer_position)
		_PlayerInteractionController.Command.Kind.SECONDARY_PRESS:
			_try_toggle_mechanism_at_mouse()
		_PlayerInteractionController.Command.Kind.POINTER_MOTION:
			_drag_flow_controller.update_preview(command.pointer_position)
		_PlayerInteractionController.Command.Kind.NONE:
			pass


## state_changed 回调：刷新机关栏 UI 与 Start Run UI；不在此取消拖拽或修改 pulse_generation/水晶/光路/占用/完成事实。COMPLETED 前取消拖拽由 LevelRuntimeController 在请求转换前完成。
func _on_run_state_changed(
		_previous_state: _RuntimeInteractionTypes.RunState,
		_new_state: _RuntimeInteractionTypes.RunState
) -> void:
	_update_inventory_ui()
	if _run_start_view != null:
		# D7-3：只由真实 RunState 驱动按钮显隐/提示/invalid 反馈，不读第二套“是否已开始”布尔。
		_run_start_view.update_for_state(_new_state)


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


## Q 形态切换入口（M4-E4）：转发到 LevelRuntimeController.request_switch_light_form（关卡 allow_form_switch + 非 COMPLETED 权限门在控制器内）；
## 仅成功（返回新形态 >=0）才把新形态交给 FormSwitchToastView 显示上方居中 1 秒提示；被禁止/无效的 Q 不显示任何提示。
## 核心不复制权限规则；Q 不发射、不触 cooldown、不影响场上 emission（冻结语义由控制器保证）。
func _switch_light_form() -> void:
	var new_form: int = _level_runtime_controller.request_switch_light_form()
	if new_form < 0:
		if OS.is_debug_build():
			print_debug("CoreLoopPrototype: Q 形态切换被拒绝（关卡禁止或 COMPLETED），不显示提示。")
		return
	# 形态→视觉：成功切换后经 EmitterConfigNode 正式入口把 FixedEmitter 新形态写入 EmitterVisual
	# 内容状态（set_content_state 契约），不并行维护第二套纹理切换。
	_emitter_config.set_visual_light_form(new_form)
	_form_switch_toast_view.show_for_form(new_form)


## D7-3 正式「开始运行」入口：转发到 LevelRuntimeController.request_begin_runtime；核心不复制 Gate/严重度/RunState 转换/Ray 规则。
## [br]AF-07：校验目标改为内容根（Host 模式 = LevelRoot 纯关卡根，Gate 只认正式角色为直接子节点；原型场景内容根即自身，行为不变）。
## [br]返回：SETUP 下返回结构化 LevelValidationResult（valid=已进 READY_TO_FIRE / invalid=仍 SETUP 供 UI 最小反馈）；非 SETUP 返回 null（被忽略，正常 UI 此时按钮已隐藏）。
## [br]边界：按钮本身不发射；fire 仍走 fire_light()，且 fire_light 不隐式自动 Start Run。运行时初始化被中止（如 PARTICLE 未接运行时）时返回 null，不构造虚假开始。
func start_run() -> _LevelValidationResult:
	if _level_runtime_controller == null:
		return null
	var result: _LevelValidationResult = _level_runtime_controller.request_begin_runtime(_content_root)
	# 把结构化结果回写 RunStartView：invalid 时显示最小反馈；valid 时由后续 READY_TO_FIRE 状态刷新清除旧反馈。
	# 按钮与程序化 start_run() 调用方共用此路径，core_loop 只做转发，不复制 Gate/严重度规则。
	if _run_start_view != null:
		_run_start_view.handle_start_run_result(result)
	return result


## R 完整重置入口：转发到 LevelRuntimeController.reset_runtime；重置顺序、旧异步失效与移动次数清零全部由控制器拥有。
func reset_runtime() -> void:
	_level_runtime_controller.reset_runtime()
	# R 恢复初始形态后同步视觉：FixedEmitter 已复位到构造时快照，EmitterVisual 内容状态跟随同一形态事实。
	if _fixed_emitter != null and _emitter_config != null:
		_emitter_config.set_visual_light_form(_fixed_emitter.get_light_form())


## 查询指定格子被哪个机关占用（薄包装，转发 _level_world_query.get_mechanism_id_at）；未被占用返回空 StringName（&""），不报错。
func get_mechanism_at(cell: Vector2i) -> StringName:
	return _level_world_query.get_mechanism_id_at(cell)


## 尝试右键对鼠标所在已放置机关执行「循环内部配置」动作（Guide §12 过渡实现）。
## [br]正式通用方案应为 PlayerInteractionActionService.execute_action(ActionRequest(target_stable_id, action))，
## action token 由 Definition.player_interaction_actions 声明（镜面 cycle_internal_state、加减速器 cycle_direction），
## 全程无类型分支；但 DefinitionSpawnService 官方声明本批不接线 core_loop（mechanism_id → stable_id 身份迁移
## 留待 GUI 验收批次），故此处以 is/as 类型分发临时承担「动作 → 机关方法」映射，迁移时整段替换为 execute_action。
## [br]权限：所有内部配置仅 SETUP 可编辑；固定预放置不入 PlacementController 放置表，始终拒绝右键，
## 初始方向仅由 Inspector/Typed 配置写入；玩家库存放置实例只在 SETUP 内允许右键轮转。
func _try_toggle_mechanism_at_mouse() -> void:
	if is_dragging():
		return
	var viewport_mouse_position: Vector2 = get_viewport().get_mouse_position()
	if _is_mouse_over_inventory_bar(viewport_mouse_position):
		return
	if not can_edit_configuration():
		return

	var target_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	var mechanism_id: StringName = get_mechanism_at(target_cell)
	var is_player_placed: bool = mechanism_id != &"" and _placement_controller.has_placed(mechanism_id)
	if not is_player_placed:
		return

	var token: Variant = _placement_controller.get_placed_node(mechanism_id)
	if not is_instance_valid(token):
		return
	_apply_cycle_configuration_action(token)


## 过渡：把「循环内部配置」动作映射到具体机关方法。
## [br]Guide §12 禁止 Runtime UI 做类型判断，正式方案由 PlayerInteractionActionService 按 action token 驱动；
## 本函数是身份迁移前的临时映射器，未来接入 DefinitionSpawnService 后删除本函数、改调 execute_action。
## [br]边界：方向/朝向事实与循环逻辑唯一存在于各机关脚本（toggle_orientation / cycle_direction），核心不复制；
## 权限已由调用入口统一执行 can_edit_configuration（SETUP-only）及 has_placed 注册身份守卫。
func _apply_cycle_configuration_action(token: Variant) -> void:
	if token is SingleCellMirror:
		(token as SingleCellMirror).toggle_orientation()
	elif token is _ParticleAccelerator:
		(token as _ParticleAccelerator).cycle_direction()
	elif token is _ParticleDecelerator:
		(token as _ParticleDecelerator).cycle_direction()
	else:
		return

## 解析指针命中场景供 DragFlowController 使用：是否位于机关栏、是否位于原型槽位/道具卡、世界格坐标、
## 命中的库存类型。世界格用 get_global_mouse_position() 换算（与原拖拽实现一致），UI 命中用传入的视口坐标。
## AF-10 第三批：命中道具卡时携带该卡 type_id 并写入选中事实（未拖拽时；拖拽中不改选中防跨类型串扣）；
## 命中旧槽位区域（无卡覆盖）携带当前选中类型；旧单类型路径 type_id 恒空，DragFlow 退回镜像默认。
func _resolve_drag_pointer(viewport_position: Vector2) -> _DragFlowController.PointerScene:
	var world_cell: Vector2i = _GridCoordinateRules.world_to_cell(get_global_mouse_position())
	var over_slot: bool = false
	var inventory_type_id: StringName = &""
	if _inventory_card_bar != null:
		var card_type: StringName = _inventory_card_bar.get_card_type_id_at(viewport_position)
		over_slot = card_type != &"" or _is_mouse_over_prototype_slot(viewport_position)
		if not is_dragging():
			if card_type != &"":
				inventory_type_id = card_type
			elif over_slot:
				inventory_type_id = _inventory_card_bar.get_selected_type_id()
			if inventory_type_id != &"":
				_inventory_card_bar.set_selected_type(inventory_type_id)
				if _multi_inventory != null:
					_multi_inventory.selected_type_id = inventory_type_id
	else:
		over_slot = _is_mouse_over_prototype_slot(viewport_position)
	return _DragFlowController.PointerScene.new(
		_is_mouse_over_inventory_bar(viewport_position),
		over_slot,
		world_cell,
		inventory_type_id
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


## AF-10 第三批：按 mechanism_id/预览 ID 解析机关场景（Registry 驱动，未知类型返回 null 由调用方安全失败）。
func _scene_for_mechanism(mechanism_id: StringName) -> PackedScene:
	var scene: PackedScene = _definition_index.resolve_scene_for_mechanism_id(
		mechanism_id, PROTOTYPE_TOKEN_TYPE_ID, _SingleCellMirrorScene
	)
	if scene == null:
		push_error("CoreLoopPrototype: 机关类型场景解析失败，拒绝实例化：%s" % [mechanism_id])
	return scene


## 创建拖拽预览节点（DragFlowController 的 create_preview_token 适配）：按类型实例化机关场景并加入
## RuntimeObjects，配置 ID/格/世界坐标与预览模式。不写库存、不写 OccupancyRegistry、不判断合法性；
## 新库存拖拽默认 SLASH（仅镜面消费朝向），拖动已有机关由控制器复制原朝向；解析失败返回 null 安全取消。
func _create_token_node(mechanism_id: StringName, cell: Vector2i) -> Variant:
	var scene: PackedScene = _scene_for_mechanism(mechanism_id)
	if scene == null:
		return null
	var token = scene.instantiate()
	if not is_instance_valid(token):
		return null
	runtime_objects.add_child(token)
	token.configure(mechanism_id, cell)
	token.set_world_position(_GridCoordinateRules.cell_to_world(cell))
	token.set_drag_preview(true, true)
	return token


## 创建正式机关节点工厂（注入 PlacementController）：按类型实例化机关场景并加入 RuntimeObjects，
## 配置 ID/格/朝向/世界坐标。不写占用、不写库存、不判断合法性；orientation 仅镜面消费
## （place_from_inventory 传入，新镜面为 SLASH），非镜面类型走场景默认配置；解析/实例化失败返回 null 由控制器回滚。
func _create_formal_token_node(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
	var scene: PackedScene = _scene_for_mechanism(mechanism_id)
	if scene == null:
		push_error("CoreLoopPrototype: 正式机关场景解析失败，事务回滚：%s at %s" % [mechanism_id, cell])
		return null
	var token = scene.instantiate()
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
## AF-10 第三批：多类型模式下同时刷新道具卡 Presenter（每卡独立剩余/可用性/选中高亮，选中类型经 set_selected_type 维护）。
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
	if _inventory_card_bar != null:
		_inventory_card_bar.refresh(
			Callable(self, "_card_remaining_for_type"),
			Callable(self, "_card_available_for_type")
		)


## AF-10 第三批：道具卡只读数量查询（Presenter refresh 注入；多类型门面按类型剩余）。
func _card_remaining_for_type(type_id: StringName) -> int:
	return _multi_inventory.get_remaining_for(type_id) if _multi_inventory != null else 0


## AF-10 第三批：道具卡只读可用性查询（剩余 > 0 且当前状态允许拿取）。
func _card_available_for_type(type_id: StringName) -> bool:
	return (
		_card_remaining_for_type(type_id) > 0
		and _RuntimeMoveRules.can_take_from_inventory_for_state(_get_current_run_state())
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
	# 真实 Wall 采样：正式运行墙体事实来自 WallLayer 快照（D5-B.2B），不读旧 wall_cells 导出；get_wall_cells_copy 返回独立值拷贝。
	for wall_cell: Vector2i in _tile_layer_snapshot.get_wall_cells_copy():
		sample_cells.append(wall_cell)
	# 真实地图边界角：取 Terrain 外包矩形右下角（D5-B.2B），由真实 Terrain used cells 计算，不读旧 map_bounds.end。
	# 仅当 Terrain 有有效面积时才追加右下角样本；空 Terrain 的快照外包为 Rect2i(0,0,0,0)、端点为 (0,0)，不得减一伪造 (-1,-1) 边界样本。
	var terrain_bounds: Rect2i = _tile_layer_snapshot.get_terrain_bounds()
	if terrain_bounds.has_area():
		sample_cells.append(Vector2i(terrain_bounds.end.x - 1, terrain_bounds.end.y - 1))
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
