extends SceneTree

## AF-03 Typed Player Interaction Action 定向合同测试（Guide §12 链路 + §11 配置提案）。
## 覆盖：动作 token 域、按 Definition player_action 声明定位驱动字段、候选配置纯函数提案
## （镜 orientation 0↔1 回绕、加速器 direction 0..7 回绕、无驱动字段拒绝）、
## ActionService 全链（SETUP 提交成功并投影到真实节点 / COMPLETED 拒绝 / 运行期配置锁 /
## 未知目标拒绝 / 未声明动作拒绝），真实镜面经 DefinitionSpawnService 走完整 Spawn → 动作链。
## headless extends SceneTree；全部通过 quit(0)，任一失败 quit(1)。


const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)
const _PlayerInteractionActionService: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action_service.gd"
)
const _InteractionProfile: GDScript = preload(
	"res://gameplay/interaction/permission/interaction_profile.gd"
)
const _RuntimeInteractionPermission: GDScript = preload(
	"res://gameplay/interaction/permission/runtime_interaction_permission.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _FormalContentRegistry: GDScript = preload(
	"res://gameplay/content/formal_content_registry.gd"
)
const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _LevelInventoryEntry: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_entry.gd"
)
const _LevelInventoryRuntime: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_runtime.gd"
)
const _SharedPlacementQuery: GDScript = preload(
	"res://gameplay/placement/contracts/shared_placement_query.gd"
)
const _DefinitionSpawnService: GDScript = preload(
	"res://gameplay/placement/inventory/definition_spawn_service.gd"
)
const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)
const _LevelObjectRegistry: GDScript = preload(
	"res://gameplay/level/level_object_registry.gd"
)
const _SingleCellMirrorScript: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)

const _MIRROR: StringName = &"basic_single_cell_mirror"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _spawn_service: _DefinitionSpawnService = null
var _action_service: _PlayerInteractionActionService = null
var _content_registry: _FormalContentRegistry = null
var _object_registry: _FormalObjectRegistry = null
# Definition 解析桩成员持有：Callable 不保留 RefCounted，局部实例会在 setup 返回后被回收（null::resolve 坑）。
var _resolver: _Resolver = null


func _initialize() -> void:
	await process_frame
	_setup_environment()
	_test_01_action_token_domain()
	_test_02_propose_candidate_pure_function()
	await _test_03_full_chain_success()
	_test_04_permission_rejections()
	_test_05_invalid_target_and_schema_guard()
	await _cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 环境：真实镜面 Definition + Spawn Service（单镜库存）+ 动作服务（Registry 解析注入）。
func _setup_environment() -> void:
	var definition := _make_mirror_definition()
	_content_registry = _FormalContentRegistry.build([definition])
	_object_registry = _FormalObjectRegistry.new(_content_registry)
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var inventory: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	inventory.setup([_LevelInventoryEntry.new(_MIRROR, 1, 0)])
	var world_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10),
		[Vector2i(0, 9)] as Array[Vector2i],
		Vector2i(9, 9),
		_LevelObjectRegistry.new(),
		occupancy,
		Callable()
	)
	_spawn_service = _DefinitionSpawnService.new(
		_content_registry, _object_registry, occupancy, inventory,
		_SharedPlacementQuery.new(world_query), root
	)
	_resolver = _Resolver.new()
	_resolver.registry = _content_registry
	_action_service = _PlayerInteractionActionService.new(_spawn_service, _resolver.resolve)


## 1. 动作 token 域与驱动字段定位。
func _test_01_action_token_domain() -> void:
	const NAME: String = "01_动作域"
	_check(NAME, _PlayerInteractionAction.is_valid_action(_PlayerInteractionAction.CYCLE_INTERNAL_STATE), "CYCLE_INTERNAL_STATE 合法。")
	_check(NAME, _PlayerInteractionAction.is_valid_action(_PlayerInteractionAction.CYCLE_DIRECTION), "CYCLE_DIRECTION 合法。")
	_check(NAME, not _PlayerInteractionAction.is_valid_action(&"explode"), "未知动作非法。")
	var definition := _make_mirror_definition()
	_check(NAME, _PlayerInteractionAction.find_driven_field_id(definition.configuration_fields, _PlayerInteractionAction.CYCLE_INTERNAL_STATE) == &"orientation", "镜 CYCLE_INTERNAL_STATE 驱动 orientation 字段。")
	_check(NAME, _PlayerInteractionAction.find_driven_field_id(definition.configuration_fields, _PlayerInteractionAction.CYCLE_DIRECTION) == &"", "镜未声明 CYCLE_DIRECTION 驱动。")


## 2. 候选提案纯函数：枚举 +1 回绕；不修改源配置；无驱动字段返回 null。
func _test_02_propose_candidate_pure_function() -> void:
	const NAME: String = "02_候选提案"
	var definition := _make_mirror_definition()
	var current: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults(definition.configuration_fields)
	var candidate: _MechanismConfiguration = _PlayerInteractionAction.propose_candidate_configuration(definition.configuration_fields, current, _PlayerInteractionAction.CYCLE_INTERNAL_STATE)
	_check(NAME, candidate != null and candidate.get_value(&"orientation") == 1, "0 → 1 提案。")
	_check(NAME, current.get_value(&"orientation") == 0, "提案不修改源配置。")
	var wrapped: _MechanismConfiguration = _PlayerInteractionAction.propose_candidate_configuration(definition.configuration_fields, candidate, _PlayerInteractionAction.CYCLE_INTERNAL_STATE)
	_check(NAME, wrapped != null and wrapped.get_value(&"orientation") == 0, "1 → 0 回绕。")
	_check(NAME, _PlayerInteractionAction.propose_candidate_configuration(definition.configuration_fields, current, _PlayerInteractionAction.CYCLE_DIRECTION) == null, "无驱动字段返回 null。")
	# 加速器方向 0..7 回绕。
	var direction_definition := _make_direction_only_fields()
	var direction_config: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults(direction_definition)
	direction_config.apply_override(&"direction", 7)
	var direction_next: _MechanismConfiguration = _PlayerInteractionAction.propose_candidate_configuration(direction_definition, direction_config, _PlayerInteractionAction.CYCLE_DIRECTION)
	_check(NAME, direction_next != null and direction_next.get_value(&"direction") == 0, "7 → 0 回绕。")


## 3. 全链成功：Spawn 真实镜 → SETUP 执行 CYCLE_INTERNAL_STATE → 配置记录与节点 orientation 同步为 BACKSLASH。
func _test_03_full_chain_success() -> void:
	const NAME: String = "03_全链成功"
	_spawn_service.begin_drag_reservation(_MIRROR)
	var spawn := _spawn_service.commit_spawn(_MIRROR, Vector2i(4, 4))
	_check(NAME, spawn.is_success(), "Spawn 应成功（%s）。" % [spawn.message])
	var stable_id: String = spawn.stable_id
	var request: _PlayerInteractionAction.ActionRequest = _PlayerInteractionAction.ActionRequest.new(stable_id, _PlayerInteractionAction.CYCLE_INTERNAL_STATE)
	var permission := _action_service.execute_action(request, _RuntimeInteractionTypes.RunState.SETUP, 0)
	_check(NAME, permission.is_allowed() and permission.reason == _RuntimeInteractionPermission.REASON_OK, "SETUP 动作应允许。")
	var record: _MechanismConfiguration = _spawn_service.get_instance_configuration(stable_id)
	_check(NAME, record.get_value(&"orientation") == 1, "配置记录应更新为 1。")
	await process_frame
	var snapshot: Dictionary = _object_registry.get_object_snapshot(stable_id)
	var mirror: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
	_check(NAME, is_instance_valid(mirror) and mirror.orientation == _SingleCellMirrorScript.MirrorOrientation.BACKSLASH, "真实节点 orientation 应投影为 BACKSLASH。")
	# 再执行一次回绕到 0。
	var second := _action_service.execute_action(request, _RuntimeInteractionTypes.RunState.SETUP, 0)
	_check(NAME, second.is_allowed(), "第二次动作应允许。")
	_check(NAME, _spawn_service.get_instance_configuration(stable_id).get_value(&"orientation") == 0, "记录回绕为 0。")


## 4. 判权拒绝：COMPLETED 冻结 / 运行期配置锁；拒绝路径配置记录不变。
func _test_04_permission_rejections() -> void:
	const NAME: String = "04_判权拒绝"
	var stable_id: String = _object_registry.get_stable_ids_of_type(_MIRROR)[0]
	var request: _PlayerInteractionAction.ActionRequest = _PlayerInteractionAction.ActionRequest.new(stable_id, _PlayerInteractionAction.CYCLE_INTERNAL_STATE)
	var completed := _action_service.execute_action(request, _RuntimeInteractionTypes.RunState.COMPLETED, 5)
	_check(NAME, not completed.is_allowed() and completed.reason == _RuntimeInteractionPermission.REASON_COMPLETED_LOCKED, "COMPLETED 应回 COMPLETED_LOCKED。")
	var locked := _action_service.execute_action(request, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 5)
	_check(NAME, not locked.is_allowed() and locked.reason == _RuntimeInteractionPermission.REASON_CONFIGURATION_LOCKED, "MOVE_WINDOW 应回 CONFIGURATION_LOCKED。")
	var undeclared_request: _PlayerInteractionAction.ActionRequest = _PlayerInteractionAction.ActionRequest.new(stable_id, _PlayerInteractionAction.CYCLE_DIRECTION)
	var undeclared := _action_service.execute_action(undeclared_request, _RuntimeInteractionTypes.RunState.SETUP, 0)
	_check(NAME, not undeclared.is_allowed() and undeclared.reason == _RuntimeInteractionPermission.REASON_PROFILE_FORBIDS_ACTION, "未声明动作应回 PROFILE_FORBIDS_ACTION。")
	_check(NAME, _spawn_service.get_instance_configuration(stable_id).get_value(&"orientation") == 0, "拒绝路径配置不变。")


## 5. 未知目标拒绝；非法 Schema 候选直接提交服务被拒（防御边界）。
func _test_05_invalid_target_and_schema_guard() -> void:
	const NAME: String = "05_目标与Schema防御"
	var unknown_request: _PlayerInteractionAction.ActionRequest = _PlayerInteractionAction.ActionRequest.new("fci_9999999", _PlayerInteractionAction.CYCLE_INTERNAL_STATE)
	var unknown := _action_service.execute_action(unknown_request, _RuntimeInteractionTypes.RunState.SETUP, 0)
	_check(NAME, not unknown.is_allowed() and unknown.reason == _RuntimeInteractionPermission.REASON_INVALID_TARGET, "未知目标应回 INVALID_TARGET。")
	var stable_id: String = _object_registry.get_stable_ids_of_type(_MIRROR)[0]
	var forged: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults([])
	var forged_result := _spawn_service.commit_configuration(stable_id, forged)
	_check(NAME, not forged_result.is_success() and forged_result.reason == _DefinitionSpawnService.REASON_CONFIG_INVALID, "字段集不符的候选应被 Schema 防御拒绝。")


## 真实镜面 Definition。
func _make_mirror_definition() -> _MechanismDefinition:
	var orientation_field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	orientation_field.field_id = &"orientation"
	orientation_field.display_name = "镜面朝向"
	orientation_field.value_type = _MechanismFieldDefinition.ValueType.INT
	orientation_field.enum_min = 0
	orientation_field.enum_max = 1
	orientation_field.default_value = 0
	orientation_field.player_action = _PlayerInteractionAction.CYCLE_INTERNAL_STATE
	var definition: _MechanismDefinition = _MechanismDefinition.new()
	definition.content_type_id = _MIRROR
	definition.display_name = "基础单格镜"
	definition.scene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
	definition.inventory_eligible = true
	definition.static_footprint_offsets = [Vector2i.ZERO]
	definition.configuration_fields = [orientation_field]
	definition.player_interaction_actions = [_PlayerInteractionAction.CYCLE_INTERNAL_STATE]
	return definition


## 八方向字段声明清单（提案回绕测试用）。
func _make_direction_only_fields() -> Array:
	var direction_field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	direction_field.field_id = &"direction"
	direction_field.display_name = "方向"
	direction_field.value_type = _MechanismFieldDefinition.ValueType.INT
	direction_field.enum_min = 0
	direction_field.enum_max = 7
	direction_field.default_value = 0
	direction_field.player_action = _PlayerInteractionAction.CYCLE_DIRECTION
	return [direction_field]


## 清理 root 上的实例节点。
func _cleanup() -> void:
	for stable_id: String in _object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_SPAWNED):
		var snapshot: Dictionary = _object_registry.get_object_snapshot(stable_id)
		var token: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
		if is_instance_valid(token) and token is Node:
			(token as Node).queue_free()
	await process_frame
	_check("清理", root.get_child_count() == 0, "测试结束 root 不应有残留，实际 %d。" % [root.get_child_count()])


## Definition 解析桩：持 Registry 引用避免 Callable 不保留 RefCounted 坑。
class _Resolver extends RefCounted:
	var registry: _FormalContentRegistry = null

	func resolve(content_type_id: StringName) -> Variant:
		return registry.get_definition(content_type_id)


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("player_interaction_action_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
