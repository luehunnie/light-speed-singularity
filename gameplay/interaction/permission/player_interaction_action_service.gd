class_name PlayerInteractionActionService
extends RefCounted

## Typed Player Interaction Action 提交服务（AF-03 / P0-4，Guide §12 链路）：
## Input → ActionRequest(target Stable ID, action) → Permission → 机关提案 Candidate Configuration →
## Placement 校验（若 footprint 变化）→ Atomic Commit。
## 本服务只编排链路：判权经 RuntimeInteractionPermission 统一入口，提案经 PlayerInteractionAction
## 纯函数（无节点类型分支 / 无字符串方法名 / 无自由参数 Dictionary），原子提交委托
## DefinitionSpawnService.commit_configuration；自身不持任何玩法事实。
## Profile 语义：Inventory Spawn 实例固定 PLAYER_TOOL（Guide 15.3），本服务按该 Profile 判权。


const _DefinitionSpawnService: GDScript = preload(
	"res://gameplay/placement/inventory/definition_spawn_service.gd"
)
const _RuntimeInteractionPermission: GDScript = preload(
	"res://gameplay/interaction/permission/runtime_interaction_permission.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)
const _InteractionProfile: GDScript = preload(
	"res://gameplay/interaction/permission/interaction_profile.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)

var _spawn_service: _DefinitionSpawnService
var _content_registry_get_definition: Callable


## 构造服务；spawn_service 提供 target 解析/配置读取/原子提交，definition_resolver 为
## [br]Callable(content_type_id) -> MechanismDefinition（正式来源为 FormalContentRegistry，注入以保持只读边界）。
func _init(spawn_service: _DefinitionSpawnService, definition_resolver: Callable) -> void:
	_spawn_service = spawn_service
	_content_registry_get_definition = definition_resolver


## 执行一次 Typed 玩家动作请求（Guide §12 全链）。
## [br]run_state / moves_remaining 为只读运行事实（本服务不读控制器）；返回统一结果
## [br]（allowed=false 时 reason 为 machine-readable 拒绝原因；提交失败沿用服务原因 token）。
## [br]同一实例的 MOVE / RECOVER 属基础设施域，不经本入口（见 RuntimeInteractionPermission）。
func execute_action(
	request: _PlayerInteractionAction.ActionRequest,
	run_state: _RuntimeInteractionTypes.RunState,
	moves_remaining: int
) -> _RuntimeInteractionPermission.PermissionResult:
	var target_valid: bool = _spawn_service.has_instance(request.target_stable_id)
	var definition_variant: Variant = _content_registry_get_definition.call(_type_of(request.target_stable_id))
	var definition: _MechanismDefinition = definition_variant as _MechanismDefinition
	var declared_actions: Array[StringName] = []
	if definition != null:
		declared_actions = definition.player_interaction_actions
	# 1. 统一判权（Profile=PLAYER_TOOL ∩ Definition 声明能力；COMPLETED / 配置锁在权限层拦截）。
	var permission: _RuntimeInteractionPermission.PermissionResult = _RuntimeInteractionPermission.evaluate(
		request.action,
		_InteractionProfile.PLAYER_TOOL,
		declared_actions,
		false,
		run_state,
		moves_remaining,
		target_valid
	)
	if not permission.is_allowed():
		return permission
	# 2. 机关提案候选配置（纯函数；无驱动字段 → 不可达，防御回 CONFIGURATION_LOCKED）。
	var current := _spawn_service.get_instance_configuration(request.target_stable_id)
	if current == null or definition == null:
		return _RuntimeInteractionPermission.PermissionResult.new(false, _RuntimeInteractionPermission.REASON_INVALID_TARGET)
	var candidate: _MechanismConfiguration = _PlayerInteractionAction.propose_candidate_configuration(
		definition.configuration_fields, current, request.action
	)
	if candidate == null:
		return _RuntimeInteractionPermission.PermissionResult.new(false, _RuntimeInteractionPermission.REASON_CONFIGURATION_LOCKED)
	# 3. 原子提交（Schema 校验 + 足迹影响判定 + 节点 Typed 应用 + 记录换绑全在服务内）。
	var commit := _spawn_service.commit_configuration(request.target_stable_id, candidate)
	if not commit.is_success():
		return _RuntimeInteractionPermission.PermissionResult.new(false, commit.reason)
	return permission


## 解析目标实例的内容类型（经 Registry 快照；未登记返回空 token）。
func _type_of(stable_id: String) -> StringName:
	return _spawn_service.get_content_type_of(stable_id)
