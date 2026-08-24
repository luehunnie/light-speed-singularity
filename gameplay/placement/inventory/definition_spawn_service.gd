class_name DefinitionSpawnService
extends RefCounted

## Definition-driven Spawn / Recover / Move / Reset 服务（AF-03 / P0-5，Guide §15/§16/§14）。
## 统一链（Guide 15.3）：type_id → Content Registry → MechanismDefinition → PackedScene → Type Default
## Configuration → Inventory Spawn Profile（PLAYER_TOOL）→ Generic Spawn / Placement。
## 事务边界（Guide 14/16）：Candidate → Shared Placement Query → Atomic Commit / Reject；非法候选零占用/零注册/
## 零库存变更；Spawn 提交链 = 确认 reservation → instantiate → 生成 Stable ID → 应用默认配置/Profile →
## 注册 Registry → 提交 Occupancy → 正式消耗 quantity，任一步失败逆序回滚。
## 节点事实写入遵循 mirrors/single_cell_mirror_lifecycle_test 工厂先例：直写 mechanism_id / set_cell /
## apply_configuration 等非视觉事实，不调用依赖 @onready 的 configure()（视觉在入树 _ready 后自然成立）。
## 本批刻意不接线 core_loop_prototype / LevelRuntimeController（旧单类型原型路径原样并存，迁移留待 GUI 验收批次）。


const _FormalContentRegistry: GDScript = preload(
	"res://gameplay/content/formal_content_registry.gd"
)
const _FormalObjectRegistry: GDScript = preload(
	"res://gameplay/content/formal_object_registry.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _LevelInventoryRuntime: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_runtime.gd"
)
const _SharedPlacementQuery: GDScript = preload(
	"res://gameplay/placement/contracts/shared_placement_query.gd"
)
const _PlacementCandidate: GDScript = preload(
	"res://gameplay/placement/contracts/placement_candidate.gd"
)
const _FootprintContract: GDScript = preload(
	"res://gameplay/placement/contracts/footprint_contract.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _PlaceableToken: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _InteractionProfile: GDScript = preload(
	"res://gameplay/interaction/permission/interaction_profile.gd"
)

## 事务状态。
enum Status {
	SUCCESS,
	NO_CHANGE,
	REJECTED,
	FAILED,
}

## machine-readable 拒绝/失败原因 token。
const REASON_TYPE_UNKNOWN: StringName = &"TYPE_UNKNOWN"
const REASON_NOT_INVENTORY_ELIGIBLE: StringName = &"NOT_INVENTORY_ELIGIBLE"
const REASON_NO_RESERVATION: StringName = &"NO_RESERVATION"
const REASON_INVENTORY_EXHAUSTED: StringName = &"INVENTORY_EXHAUSTED"
const REASON_INVALID_TARGET: StringName = &"INVALID_TARGET"
const REASON_PLACEMENT_ILLEGAL: StringName = &"PLACEMENT_ILLEGAL"
const REASON_SCENE_ROOT_INVALID: StringName = &"SCENE_ROOT_INVALID"
const REASON_CONFIG_INVALID: StringName = &"CONFIG_INVALID"
const REASON_NODE_APPLY_FAILED: StringName = &"NODE_APPLY_FAILED"
const REASON_REGISTRY_REJECTED: StringName = &"REGISTRY_REJECTED"


## 服务事务结果：状态 + 稳定 ID + machine-readable 原因 + 人读消息（issue code 列表并入 message）。
class ServiceResult:
	var status: int = Status.FAILED
	var stable_id: String = ""
	var reason: StringName = &""
	var message: String = ""

	func _init(p_status: int = Status.FAILED, p_stable_id: String = "", p_reason: StringName = &"", p_message: String = "") -> void:
		status = p_status
		stable_id = p_stable_id
		reason = p_reason
		message = p_message

	func is_success() -> bool:
		return status == Status.SUCCESS


var _content_registry: _FormalContentRegistry
var _object_registry: _FormalObjectRegistry
var _occupancy: _OccupancyRegistry
var _inventory: _LevelInventoryRuntime
var _shared_query: _SharedPlacementQuery
## Spawn 实例挂载父节点；null 时拒绝 Spawn（正式路径必须入树，避免无树节点 @onready 悬空）。
var _parent_node: Node
## stable_id → 实例配置记录（Instance Override 层事实；节点为单向投影）。
var _configurations_by_stable_id: Dictionary[String, _MechanismConfiguration] = {}


## 构造服务；全部依赖注入（均为只读/事务边界使用，不持有 RunState / UI / 拖拽状态）。
func _init(
	content_registry: _FormalContentRegistry,
	object_registry: _FormalObjectRegistry,
	occupancy: _OccupancyRegistry,
	inventory: _LevelInventoryRuntime,
	shared_query: _SharedPlacementQuery,
	parent_node: Node
) -> void:
	_content_registry = content_registry
	_object_registry = object_registry
	_occupancy = occupancy
	_inventory = inventory
	_shared_query = shared_query
	_parent_node = parent_node


## §16 Drag Start：库存拿取预留一单位（不创建正式机关、不产生 Stable ID / Registry / Occupancy）。
## [br]类型未知、无库存资格或无可预留数量返回 false（零变更）。
func begin_drag_reservation(content_type_id: StringName) -> bool:
	var definition := _eligible_definition_or_null(content_type_id)
	if definition == null:
		return false
	return _inventory.try_reserve_spawn(content_type_id)


## §16 取消/非法路径：释放拿取预留，不产生正式实例、不消费 Stable ID。
func cancel_drag_reservation(content_type_id: StringName) -> bool:
	return _inventory.cancel_reserved_spawn(content_type_id)


## 构建 Spawn 候选（§14/§16 Preview：无 Stable ID、不入 Registry / Occupancy，仅 Definition + 候选配置 + Footprint）。
## [br]类型无资格返回 null；候选配置为 Type Default（Guide 11.2：Inventory Spawn 不读关卡层覆盖）。
func build_spawn_candidate(content_type_id: StringName, anchor_cell: Vector2i) -> _PlacementCandidate:
	var definition := _eligible_definition_or_null(content_type_id)
	if definition == null:
		return null
	var default_configuration: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults(definition.configuration_fields)
	if default_configuration == null and not definition.configuration_fields.is_empty():
		push_error("DefinitionSpawnService: 类型 %s 配置 Schema 非法，无法构建候选。" % [content_type_id])
		return null
	return _PlacementCandidate.new("", content_type_id, anchor_cell, definition, default_configuration)


## 评估候选可放置性（只读；返回 machine-readable issue 集）。
func evaluate_candidate(candidate: _PlacementCandidate) -> _SharedPlacementQuery.PlacementQueryResult:
	return _shared_query.evaluate(candidate.footprint_cells, &"")


## §16 合法 Placement Commit：确认预留并执行统一 Spawn 链（任一步失败逆序回滚，占用/注册/库存零脏残留）。
## [br]调用前应已 begin_drag_reservation 成功；无预留时 REJECTED(NO_RESERVATION)。
func commit_spawn(content_type_id: StringName, anchor_cell: Vector2i) -> ServiceResult:
	var definition := _eligible_definition_or_null(content_type_id)
	if definition == null:
		return ServiceResult.new(Status.REJECTED, "", REASON_TYPE_UNKNOWN, "类型未知或无库存资格。")
	if _inventory.get_reserved_spawn(content_type_id) <= 0:
		return ServiceResult.new(Status.REJECTED, "", REASON_NO_RESERVATION, "不存在拿取预留。")
	# 1. Candidate → Shared Placement Query（非法候选零提交，Guide 14）。
	var candidate := build_spawn_candidate(content_type_id, anchor_cell)
	if candidate == null:
		return ServiceResult.new(Status.REJECTED, "", REASON_TYPE_UNKNOWN, "候选构建失败。")
	var query_result: _SharedPlacementQuery.PlacementQueryResult = evaluate_candidate(candidate)
	if not query_result.is_allowed():
		return ServiceResult.new(
			Status.REJECTED, "", REASON_PLACEMENT_ILLEGAL,
			"目标格非法：%s" % [",".join(query_result.issues)]
		)
	# 2. instantiate PackedScene 并做正式 Typed 根契约检查。
	var token: Variant = definition.scene.instantiate()
	if not (token is _PlaceableToken):
		push_error("DefinitionSpawnService: 场景根非 PlaceableToken，拒绝 Spawn：%s" % [content_type_id])
		_destroy_token(token)
		return ServiceResult.new(Status.REJECTED, "", REASON_SCENE_ROOT_INVALID, "场景根非 PlaceableToken。")
	if _parent_node == null:
		_destroy_token(token)
		return ServiceResult.new(Status.REJECTED, "", REASON_SCENE_ROOT_INVALID, "未提供挂载父节点。")
	# 3. 应用 Type Default 配置（先写配置事实再入树：视觉在 _ready 后自然读取最终朝向）。
	var default_configuration := candidate.configuration
	if not _apply_configuration_to_token(token, default_configuration):
		_destroy_token(token)
		return ServiceResult.new(Status.REJECTED, "", REASON_NODE_APPLY_FAILED, "节点应用默认配置失败。")
	# 4. 生成 Stable Instance ID 并注册 Formal Object Registry。
	var stable_id: String = _object_registry.register_spawn(content_type_id, anchor_cell, token)
	if stable_id.is_empty():
		_destroy_token(token)
		return ServiceResult.new(Status.FAILED, "", REASON_REGISTRY_REJECTED, "Registry 拒绝注册。")
	var occupancy_id := StringName(stable_id)
	# 5. 写节点身份/位置事实并入树（先例：lifecycle 工厂直写非视觉事实）。
	token.mechanism_id = occupancy_id
	token.set_cell(anchor_cell)
	_parent_node.add_child(token)
	# 6. 提交 Occupancy；失败逆序回滚（出树销毁 → 注销 Registry）。
	if not _occupancy.register_cells(occupancy_id, candidate.footprint_cells):
		push_error("DefinitionSpawnService: 占用登记失败，逆序回滚：%s at %s" % [stable_id, anchor_cell])
		_rollback_spawned_node(token, stable_id)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_REGISTRY_REJECTED, "占用登记失败。")
	# 7. 确认预留正式消耗数量；失败逆序回滚占用与注册。
	if not _inventory.commit_reserved_spawn(content_type_id):
		push_error("DefinitionSpawnService: 库存确认失败，逆序回滚：%s" % [stable_id])
		_occupancy.unregister(occupancy_id)
		_rollback_spawned_node(token, stable_id)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_INVENTORY_EXHAUSTED, "库存确认失败。")
	# 8. 成功：登记实例配置记录（Instance Override 层事实）。
	_configurations_by_stable_id[stable_id] = default_configuration
	return ServiceResult.new(Status.SUCCESS, stable_id)


## §15.4 Recover：Occupancy 注销 → Registry 注销 → 正式实例结束 → Stable ID 生命周期结束 → 数量 +1；
## [br]失败则什么都不改变（两阶段回还预留保证不出现“实例已删但库存未还”）。
## [br]Registry 注销失败仅剩不变量破坏一途（快照已确认登记），按 PlacementController 先例：尽力恢复占用并
## [br]大声报告，不得静默吞掉；回还确认失败按构造不可达（预留刚锁定、单线程无交错），防御路径大声报告。
func recover_instance(stable_id: String) -> ServiceResult:
	var snapshot := _object_registry.get_object_snapshot(stable_id)
	if snapshot.is_empty():
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_INVALID_TARGET, "实例未登记。")
	if snapshot[_FormalObjectRegistry._K_ORIGIN] != _FormalObjectRegistry.ORIGIN_SPAWNED:
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_INVALID_TARGET, "非玩家 Spawn 实例不可回收。")
	var content_type_id: StringName = snapshot[_FormalObjectRegistry._K_TYPE_ID]
	var occupancy_id := StringName(stable_id)
	# 快照注销前的完整占用集（回滚恢复用；多格足迹不退化为 anchor 单格）。
	var source_cells := _occupancy.get_cells_of(occupancy_id)
	# 1. 不可逆销毁前预留回还容量。
	if not _inventory.try_reserve_return(content_type_id):
		return ServiceResult.new(Status.FAILED, stable_id, REASON_INVENTORY_EXHAUSTED, "库存回还预留失败。")
	# 2. 注销占用；失败取消预留，全部保持。
	if not _occupancy.unregister(occupancy_id):
		_inventory.cancel_reserved_return(content_type_id)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_REGISTRY_REJECTED, "占用注销失败。")
	# 3. 注销 Registry；失败恢复原占用并取消预留，事务一致可重试。
	if not _object_registry.unregister(stable_id):
		push_error("DefinitionSpawnService: Registry 注销失败（不变量破坏），尽力恢复占用：%s" % [stable_id])
		if not _occupancy.register_cells(occupancy_id, source_cells):
			push_error("DefinitionSpawnService: 回滚恢复占用失败（不变量破坏）：%s at %s" % [stable_id, source_cells])
		_inventory.cancel_reserved_return(content_type_id)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_REGISTRY_REJECTED, "Registry 注销失败。")
	# 4. 提交回还（预留已锁定容量，此步按构造必成功；防御失败大声报告，不伪造恢复）。
	if not _inventory.commit_reserved_return(content_type_id):
		push_error("DefinitionSpawnService: 回还确认意外失败（不可达防御路径）：%s" % [stable_id])
		_inventory.cancel_reserved_return(content_type_id)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_INVENTORY_EXHAUSTED, "回还确认失败。")
	# 5. 正式实例结束：销毁节点、结束配置记录。
	_destroy_token(snapshot[_FormalObjectRegistry._K_INSTANCE])
	_configurations_by_stable_id.erase(stable_id)
	return ServiceResult.new(Status.SUCCESS, stable_id)


## 既有实例 Generic Move（§14 同一事务覆盖 Existing instance move）：候选 → 共享查询（忽略自身占用）→
## [br]占用原子迁移 → Registry 移动保 ID → 节点对齐；任一失败节点停留原格、占用/注册/库存不变。
func move_instance(stable_id: String, to_anchor_cell: Vector2i) -> ServiceResult:
	var snapshot := _object_registry.get_object_snapshot(stable_id)
	if snapshot.is_empty():
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_INVALID_TARGET, "实例未登记。")
	var content_type_id: StringName = snapshot[_FormalObjectRegistry._K_TYPE_ID]
	var current_anchor: Vector2i = snapshot[_FormalObjectRegistry._K_CELL]
	if current_anchor == to_anchor_cell:
		return ServiceResult.new(Status.NO_CHANGE, stable_id)
	var definition := _eligible_definition_or_null(content_type_id)
	if definition == null:
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_TYPE_UNKNOWN, "类型未知。")
	var configuration: _MechanismConfiguration = _configurations_by_stable_id.get(stable_id, null)
	var candidate: _PlacementCandidate = _PlacementCandidate.new(stable_id, content_type_id, to_anchor_cell, definition, configuration)
	# 候选查询忽略自身既有占用（占用键 = 稳定 ID）。
	var query_result: _SharedPlacementQuery.PlacementQueryResult = _shared_query.evaluate(candidate.footprint_cells, StringName(stable_id))
	if not query_result.is_allowed():
		return ServiceResult.new(
			Status.REJECTED, stable_id, REASON_PLACEMENT_ILLEGAL,
			"目标格非法：%s" % [",".join(query_result.issues)]
		)
	var occupancy_id := StringName(stable_id)
	var source_cells := _occupancy.get_cells_of(occupancy_id)
	if not _occupancy.move_cells(occupancy_id, source_cells, candidate.footprint_cells):
		return ServiceResult.new(Status.FAILED, stable_id, REASON_REGISTRY_REJECTED, "占用原子迁移失败。")
	if not _object_registry.move_object(stable_id, to_anchor_cell):
		push_error("DefinitionSpawnService: Registry 移动失败，回滚占用迁移：%s" % [stable_id])
		_occupancy.move_cells(occupancy_id, candidate.footprint_cells, source_cells)
		return ServiceResult.new(Status.FAILED, stable_id, REASON_REGISTRY_REJECTED, "Registry 移动失败。")
	var token: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
	if is_instance_valid(token):
		token.set_cell(to_anchor_cell)
	return ServiceResult.new(Status.SUCCESS, stable_id)


## 读取实例配置记录（detached 副本；供 Typed 玩家动作提案基底）。
func get_instance_configuration(stable_id: String) -> _MechanismConfiguration:
	var configuration: _MechanismConfiguration = _configurations_by_stable_id.get(stable_id, null)
	return configuration.duplicate_configuration() if configuration != null else null


## §12 原子提交候选配置：Schema 全字段校验 → 足迹影响判定（变化才经共享查询）→ 节点 Typed 应用 → 记录换绑。
## [br]候选非法或节点应用失败时实例配置 / 占用 / Registry / 视觉全部不变（验证先于一切写入，Guide 14）。
func commit_configuration(stable_id: String, candidate: _MechanismConfiguration) -> ServiceResult:
	var snapshot := _object_registry.get_object_snapshot(stable_id)
	if snapshot.is_empty():
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_INVALID_TARGET, "实例未登记。")
	var content_type_id: StringName = snapshot[_FormalObjectRegistry._K_TYPE_ID]
	var definition := _eligible_definition_or_null(content_type_id)
	if definition == null:
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_TYPE_UNKNOWN, "类型未知。")
	var current: _MechanismConfiguration = _configurations_by_stable_id.get(stable_id, null)
	if current == null or not _is_valid_against_schema(candidate, definition):
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_CONFIG_INVALID, "候选配置与 Schema 不符。")
	# 足迹影响：偏移集变化才需要 Placement 校验（Guide 12：若 footprint 变化）。
	if not _is_same_offsets(definition, current, candidate):
		var anchor_cell: Vector2i = snapshot[_FormalObjectRegistry._K_CELL]
		var cells: Array[Vector2i] = _FootprintContract.footprint_cells(definition, candidate, anchor_cell)
		var query_result: _SharedPlacementQuery.PlacementQueryResult = _shared_query.evaluate(cells, StringName(stable_id))
		if not query_result.is_allowed():
			return ServiceResult.new(
				Status.REJECTED, stable_id, REASON_PLACEMENT_ILLEGAL,
				"候选足迹非法：%s" % [",".join(query_result.issues)]
			)
	var token: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
	if is_instance_valid(token) and not _apply_configuration_to_token(token, candidate):
		return ServiceResult.new(Status.REJECTED, stable_id, REASON_NODE_APPLY_FAILED, "节点应用配置失败。")
	_configurations_by_stable_id[stable_id] = candidate.duplicate_configuration()
	return ServiceResult.new(Status.SUCCESS, stable_id)


## Reset restore（Guide §15.5 / §7 R 语义）：逐个 Recover 全部玩家 Spawn 实例后恢复库存初始数量。
## [br]返回未能回收的稳定 ID 列表（正常为空；非空时由调用方一致性断言暴露）。
func reset_restore() -> Array[String]:
	var unresolved: Array[String] = []
	for stable_id: String in _object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_SPAWNED):
		if not recover_instance(stable_id).is_success():
			unresolved.append(stable_id)
	_inventory.reset_to_initial()
	return unresolved


## 实例是否存在（含配置记录已在的判断，供权限层 target_valid）。
func has_instance(stable_id: String) -> bool:
	return _object_registry.has_object(stable_id) and _configurations_by_stable_id.has(stable_id)


## 实例的内容类型（Registry 快照；未登记返回空 token，供动作服务解析 Definition）。
func get_content_type_of(stable_id: String) -> StringName:
	var snapshot := _object_registry.get_object_snapshot(stable_id)
	if snapshot.is_empty():
		return &""
	return snapshot[_FormalObjectRegistry._K_TYPE_ID]


## 全部玩家 Spawn 实例稳定 ID 副本（登记序）。
func get_spawned_stable_ids() -> Array[String]:
	return _object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_SPAWNED)


## 取有库存资格的类型定义；未知/非本域/无资格返回 null。
func _eligible_definition_or_null(content_type_id: StringName) -> _MechanismDefinition:
	var definition: _MechanismDefinition = _content_registry.get_definition(content_type_id) as _MechanismDefinition
	if definition == null or not definition.inventory_eligible:
		return null
	return definition


## 经正式 Typed 契约把配置应用到节点（PlaceableToken.apply_configuration）；失败返回 false。
func _apply_configuration_to_token(token: Variant, configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	return token.apply_configuration(configuration)


## Spawn 回滚：出树销毁节点并注销 Registry 注册（占用由调用方先行处理）。
func _rollback_spawned_node(token: Variant, stable_id: String) -> void:
	_destroy_token(token)
	_object_registry.unregister(stable_id)


## 候选配置与 Definition Schema 全量一致校验：字段集相同且逐字段类型/枚举界合法。
func _is_valid_against_schema(candidate: _MechanismConfiguration, definition: _MechanismDefinition) -> bool:
	if candidate == null:
		return false
	var declared_ids := {}
	var by_field_id := {}
	for field: Variant in definition.configuration_fields:
		var field_definition = field as _MechanismFieldDef
		if field_definition == null:
			return false
		declared_ids[field_definition.field_id] = true
		by_field_id[field_definition.field_id] = field_definition
	var candidate_ids := candidate.get_field_ids()
	if candidate_ids.size() != declared_ids.size():
		return false
	for field_id: StringName in candidate_ids:
		if not declared_ids.has(field_id):
			return false
		var field_definition: _MechanismFieldDef = by_field_id[field_id]
		if not field_definition.is_valid_value(candidate.get_value(field_id)):
			return false
	return true


## 两份配置的足迹偏移集是否一致（纯比较）。
func _is_same_offsets(definition: _MechanismDefinition, a: _MechanismConfiguration, b: _MechanismConfiguration) -> bool:
	return _FootprintContract.footprint_offsets(definition, a) == _FootprintContract.footprint_offsets(definition, b)


## 安全销毁节点；只对有效 Node 调 queue_free（--script 无帧循环时由调用方泵帧落地/树退出统一释放）。
func _destroy_token(token: Variant) -> void:
	if is_instance_valid(token) and token is Node:
		(token as Node).queue_free()


## 字段声明类型引用（_is_valid_against_schema 内部使用）。
const _MechanismFieldDef: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
