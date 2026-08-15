class_name RuntimeSnapshotSampler
extends RefCounted

## Runtime 只读采样器（D7-R1 正式链路：Runtime → read-only Sampler → RuntimeSnapshotData）。
##
## 职责：
## 经只读访问器把当前 Runtime 事实组装为一份 RuntimeSnapshotData——运行期事实（generation / 移动次数 /
## cooldown / 活动 emission / 绑定光粒 / Particle tick / Ray 段数）经 runtime_provider Callable 取
## LevelRuntimeController.get_runtime_diagnostics_snapshot() 的 detached Dictionary；其余事实
## （RunState / 发射器 / 水晶 / 完成 / 库存 / 放置摘要）直接只读采集自注入的 RefCounted 控制器。
## 并测量本次采样耗时（snapshot_duration_usec，最小性能观测）。
##
## 在当前系统中的位置：
## gameplay/diagnostics/snapshot 下采样层；由 core_loop_prototype 在 _ready 构造一次并注入 Debug Console。
##
## 主要依赖：
## RunStateController / FixedEmitter / ObjectiveController / LevelObjectRegistry / InventoryController /
## PlacementController（均 RefCounted，只调用只读访问器）+ runtime_provider Callable（指向 LRC 只读出口）。
## 不持有任何 Node；不 preload LevelRuntimeController；不依赖场景树 / 文件系统 / Time（仅读取系统时钟时间戳）。
##
## 明确不负责：
## 序列化 JSON、写盘、Debug Console UI（分别由 RuntimeSnapshot / DebugConsoleView 负责）。
##
## 关键边界（Diagnostics 红线）：
## - 只读：本类只调用被采对象的只读访问器，绝不推进 Tick、finish emission、触发 Objective、重置/消费
##   cooldown、修改 Q 形态、产生 Ray/Particle 或修改任何玩法状态；连续两次采样之间玩法状态不变。
## - 身份：emission_id / runtime_id / crystal_id 均取自各组件正式业务身份，绝不使用 Node.name / instance_id
##   冒充持久业务 ID；level_id 无正式来源时保持空（unavailable 政策）。
## - 依赖方向：Runtime 不依赖 Diagnostics（反向）；本类持有的全部为 RefCounted 只读引用。


const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _RuntimeSnapshotData: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_data.gd")
const _EmissionSnapshotState: GDScript = preload("res://gameplay/diagnostics/snapshot/emission_snapshot_state.gd")
const _ParticleSnapshotState: GDScript = preload("res://gameplay/diagnostics/snapshot/particle_snapshot_state.gd")
const _CrystalSnapshotState: GDScript = preload("res://gameplay/diagnostics/snapshot/crystal_snapshot_state.gd")


## LevelRuntimeController.get_runtime_diagnostics_snapshot 只读出口（Callable 不持有 Node 引用语义）。
var _runtime_provider: Callable
var _run_state_controller: _RunStateController
var _fixed_emitter: _FixedEmitter
var _objective_controller: _ObjectiveController
var _registry: _LevelObjectRegistry
var _inventory_controller: _InventoryController
var _placement_controller: _PlacementController


## 构造采样器；runtime_provider 为 () -> Dictionary（LevelRuntimeController 只读诊断快照，detached 纯值），
## 其余为只读事实控制器（与 core_loop 持有同一实例，不建第二套事实）。
## [br]边界：本构造零副作用；不调用任何 provider，不采样。
func _init(
		runtime_provider: Callable,
		run_state_controller: _RunStateController,
		fixed_emitter: _FixedEmitter,
		objective_controller: _ObjectiveController,
		registry: _LevelObjectRegistry,
		inventory_controller: _InventoryController,
		placement_controller: _PlacementController
) -> void:
	_runtime_provider = runtime_provider
	_run_state_controller = run_state_controller
	_fixed_emitter = fixed_emitter
	_objective_controller = objective_controller
	_registry = registry
	_inventory_controller = inventory_controller
	_placement_controller = placement_controller


## 执行一次只读采样并返回 RuntimeSnapshotData。
## [br]返回值为 detached 数据契约：构造时已深复制全部子状态，调用方修改零影响 Runtime。
## [br]副作用：无玩法副作用——只调用只读访问器；仅读取系统时钟（时间戳与采样耗时，均为纯观测）。
## [br]边界：level_id 恒为空（无正式来源，unavailable 政策）；水晶 state_label 按 BasicCrystal 内容状态契约取
## lit / unlit；Runtime Dictionary 缺键时按 0 / 空处理（防御，不 push_error、不中断采样）。
func sample() -> _RuntimeSnapshotData:
	var started_usec: int = Time.get_ticks_usec()
	var runtime: Dictionary = _runtime_provider.call()
	var emissions: Array[_EmissionSnapshotState] = _build_emission_states(runtime.get("emissions", []))
	var particles: Array[_ParticleSnapshotState] = _build_particle_states(runtime.get("particles", []))
	var crystals: Array[_CrystalSnapshotState] = _build_crystal_states()
	var data: _RuntimeSnapshotData = _RuntimeSnapshotData.new(
		int(Time.get_unix_time_from_system() * 1000.0),
		&"",
		_run_state_name(_run_state_controller.get_current_state()),
		_objective_controller.is_completed(),
		int(runtime.get("runtime_generation", 0)),
		int(runtime.get("runtime_moves_used", 0)),
		int(runtime.get("runtime_moves_remaining", 0)),
		int(runtime.get("runtime_move_limit", 0)),
		_fixed_emitter.get_cell(),
		_fixed_emitter.get_direction(),
		_fixed_emitter.get_light_form(),
		bool(runtime.get("allow_form_switch", false)),
		bool(runtime.get("fire_cooldown_ready", false)),
		int(runtime.get("active_emission_count", 0)),
		emissions,
		particles,
		int(runtime.get("particle_tick", 0)),
		int(runtime.get("particle_active_count", 0)),
		int(runtime.get("ray_segment_count", 0)),
		_inventory_controller.get_remaining(),
		_inventory_controller.get_total(),
		_placement_controller.get_placed_ids().size(),
		crystals,
		Time.get_ticks_usec() - started_usec
	)
	return data


## 由 Runtime detached emission 列表构造强类型快照子契约（保持原顺序）。
func _build_emission_states(p_records: Array) -> Array[_EmissionSnapshotState]:
	var states: Array[_EmissionSnapshotState] = []
	for record: Variant in p_records:
		var runtime_ids: Array[int] = []
		for runtime_id: Variant in record.get("runtime_ids", []):
			runtime_ids.append(int(runtime_id))
		states.append(_EmissionSnapshotState.new(
			int(record.get("emission_id", 0)),
			int(record.get("generation", 0)),
			int(record.get("form", 0)),
			runtime_ids
		))
	return states


## 由 Runtime detached 光粒列表构造强类型快照子契约（保持原顺序；cell/direction 为纯值拷贝）。
func _build_particle_states(p_records: Array) -> Array[_ParticleSnapshotState]:
	var states: Array[_ParticleSnapshotState] = []
	for record: Variant in p_records:
		states.append(_ParticleSnapshotState.new(
			int(record.get("runtime_id", 0)),
			int(record.get("emission_id", 0)),
			int(record.get("generation", 0)),
			record.get("cell", Vector2i.ZERO),
			record.get("direction", Vector2i.ZERO),
			int(record.get("speed_tier", 0)),
			int(record.get("step_started_tick", 0)),
			int(record.get("next_move_tick", 0)),
			bool(record.get("active", false))
		))
	return states


## 由 Registry 只读副本构造水晶快照子契约（crystal_id 为显式配置稳定 ID；state_label 按 lit / unlit）。
func _build_crystal_states() -> Array[_CrystalSnapshotState]:
	var states: Array[_CrystalSnapshotState] = []
	for crystal: _BasicCrystal in _registry.get_all_crystals():
		states.append(_CrystalSnapshotState.new(
			crystal.get_crystal_id(),
			crystal.cell,
			crystal.is_activated,
			&"lit" if crystal.is_activated else &"unlit"
		))
	return states


## RunState 枚举值映射为稳定 StringName（与 RuntimeInteractionTypes.RunState 成员名一致）。
func _run_state_name(state: int) -> StringName:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return &"SETUP"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return &"PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return &"MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return &"COMPLETED"
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			return &"READY_TO_FIRE"
		_:
			return &"UNKNOWN"
