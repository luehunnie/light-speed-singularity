extends SceneTree

## AF-03 Definition-driven Inventory / Spawn 验收合同测试（Guide §15/§16 + AF-03 Acceptance）。
## 核心证明：两种已有玩家机关（SingleCellMirror / ParticleAccelerator）走同一 Inventory / Spawn 路径。
## 覆盖：§16 拖拽预留（Drag Start 预留、Preview 无 Stable ID / 无 Registry / 无 Occupancy、取消释放）、
## 合法提交链（Registry 注册 / Occupancy / 库存消耗 / Stable ID / 节点事实）、
## 非法候选零脏 Occupancy / Registry / 库存（AF-03 Acceptance：回滚无脏 Occupancy）、
## Recover 语义（数量归还 / Stable ID 失效 / 再 Spawn 新 ID）、Generic Move、Reset restore。
## 真实场景节点挂 root，结束统一 queue_free + 泵帧；全部通过 quit(0)，任一失败 quit(1)。


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
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)
const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)
const _LevelObjectRegistry: GDScript = preload(
	"res://gameplay/level/level_object_registry.gd"
)

const _MIRROR: StringName = &"basic_single_cell_mirror"
const _ACCELERATOR: StringName = &"particle_accelerator"
const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 12, 12)
const _WALL_CELL: Vector2i = Vector2i(0, 5)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 共享环境（两机关同一路径的关键证明：同一 registry / occupancy / inventory / service 实例）。
var _content_registry: _FormalContentRegistry = null
var _object_registry: _FormalObjectRegistry = null
var _occupancy: _OccupancyRegistry = null
var _inventory: _LevelInventoryRuntime = null
var _service: _DefinitionSpawnService = null


func _initialize() -> void:
	await process_frame
	_setup_environment()
	_test_01_two_mechanisms_same_spawn_path()
	await _test_02_reservation_preview_and_cancel()
	await _test_03_illegal_candidate_zero_dirty_state()
	await _test_04_recover_and_respawn_new_stable_id()
	await _test_05_generic_move_both_types()
	await _test_06_reset_restore()
	_test_07_no_reservation_commit_rejected()
	await _cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构建共享环境：两类型真实 Definition 进同一 Content Registry；单一多类型库存（镜 2 / 加速器 2）。
func _setup_environment() -> void:
	var mirror_definition := _make_mirror_definition()
	var accelerator_definition := _make_accelerator_definition()
	var registry_build: _FormalContentRegistry = _FormalContentRegistry.build([mirror_definition, accelerator_definition])
	_check("环境", registry_build != null, "Content Registry 构建应成功。")
	_content_registry = registry_build
	_object_registry = _FormalObjectRegistry.new(_content_registry)
	_occupancy = _OccupancyRegistry.new()
	_inventory = _LevelInventoryRuntime.new()
	_inventory.setup([
		_LevelInventoryEntry.new(_MIRROR, 2, 0),
		_LevelInventoryEntry.new(_ACCELERATOR, 2, 1),
	])
	var world_query: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS,
		[_WALL_CELL] as Array[Vector2i],
		Vector2i(11, 11),
		_LevelObjectRegistry.new(),
		_occupancy,
		Callable()
	)
	_service = _DefinitionSpawnService.new(
		_content_registry, _object_registry, _occupancy, _inventory,
		_SharedPlacementQuery.new(world_query), root
	)


## 1. 验收核心：两种已有玩家机关经同一 Inventory/Spawn 路径成功放置（同 service、同链路、真实场景节点）。
func _test_01_two_mechanisms_same_spawn_path() -> void:
	const NAME: String = "01_两机关同一路径"
	for spawn_case: Dictionary in [
		{"type": _MIRROR, "cell": Vector2i(2, 2)},
		{"type": _ACCELERATOR, "cell": Vector2i(5, 5)},
	]:
		var content_type_id: StringName = spawn_case["type"]
		var cell: Vector2i = spawn_case["cell"]
		_check(NAME, _service.begin_drag_reservation(content_type_id), "%s 拿取预留应成功。" % [content_type_id])
		var result := _service.commit_spawn(content_type_id, cell)
		_check(NAME, result.is_success(), "%s 提交应成功，实际 %s（%s）。" % [content_type_id, result.reason, result.message])
		_check(NAME, not result.stable_id.is_empty(), "%s 应取得稳定 ID。" % [content_type_id])
		_check(NAME, _object_registry.has_object(result.stable_id), "%s 应注册 Formal Object Registry。" % [content_type_id])
		_check(NAME, _occupancy.has_mechanism_at(cell), "%s 占用应登记。" % [content_type_id])
		_check(NAME, _inventory.get_remaining(content_type_id) == 1, "%s 库存应扣至 1。" % [content_type_id])
		var snapshot: Dictionary = _object_registry.get_object_snapshot(result.stable_id)
		_check(NAME, snapshot[_FormalObjectRegistry._K_TYPE_ID] == content_type_id, "%s Registry 类型应一致。" % [content_type_id])
		_check(NAME, snapshot[_FormalObjectRegistry._K_ORIGIN] == _FormalObjectRegistry.ORIGIN_SPAWNED, "%s 来源应为 spawned。" % [content_type_id])
		var token: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
		_check(NAME, is_instance_valid(token) and token.mechanism_id == StringName(result.stable_id), "%s 节点应持稳定 ID 事实。" % [content_type_id])
		_check(NAME, token.cell == cell, "%s 节点 cell 应为目标格。" % [content_type_id])


## 2. §16 预留与 Preview：候选无 Stable ID / 不入 Registry / 不入 Occupancy；取消释放预留不产生实例。
func _test_02_reservation_preview_and_cancel() -> void:
	const NAME: String = "02_预留与候选"
	_check(NAME, _service.begin_drag_reservation(_MIRROR), "拿取预留应成功。")
	_check(NAME, _inventory.get_reserved_spawn(_MIRROR) == 1 and _inventory.get_remaining(_MIRROR) == 1, "预留锁容量不动 remaining。")
	var candidate := _service.build_spawn_candidate(_MIRROR, Vector2i(7, 7))
	_check(NAME, candidate != null and candidate.stable_instance_id.is_empty(), "Preview 候选不应携带 Stable ID。")
	_check(NAME, candidate.footprint_cells == [Vector2i(7, 7)], "单格候选足迹正确。")
	var preview_query := _service.evaluate_candidate(candidate)
	_check(NAME, preview_query.is_allowed(), "空格候选应合法。")
	_check(NAME, _object_registry.get_count() == 2, "Preview 不入 Registry。")
	_check(NAME, not _occupancy.has_mechanism_at(Vector2i(7, 7)), "Preview 不入 Occupancy。")
	_check(NAME, _service.cancel_drag_reservation(_MIRROR), "取消预留应成功。")
	_check(NAME, _inventory.get_reserved_spawn(_MIRROR) == 0 and _inventory.get_remaining(_MIRROR) == 1, "取消后容量释放、数量不变。")
	_check(NAME, _object_registry.get_count() == 2, "取消不产生正式实例。")


## 3. 非法候选回滚：墙格 / 占用格 / 出界提交全部 REJECTED，占用/注册/库存零脏变更（验收条款）。
func _test_03_illegal_candidate_zero_dirty_state() -> void:
	const NAME: String = "03_非法候选零脏"
	var before_count: int = _object_registry.get_count()
	for illegal_case: Dictionary in [
		{"type": _MIRROR, "cell": _WALL_CELL, "label": "墙格"},
		{"type": _MIRROR, "cell": Vector2i(2, 2), "label": "已占格"},
		{"type": _ACCELERATOR, "cell": Vector2i(99, 99), "label": "出界"},
	]:
		_service.begin_drag_reservation(illegal_case["type"])
		var result := _service.commit_spawn(illegal_case["type"], illegal_case["cell"])
		_check(NAME, result.status == _DefinitionSpawnService.Status.REJECTED and not result.is_success(), "%s 提交应 REJECTED（%s）。" % [illegal_case["label"], result.message])
		_check(NAME, _service.cancel_drag_reservation(illegal_case["type"]), "%s 拒绝后释放预留。" % [illegal_case["label"]])
	_check(NAME, _object_registry.get_count() == before_count, "非法提交不增 Registry。")
	_check(NAME, _occupancy.get_mechanism_at(_WALL_CELL) == &"", "墙格不应被登记占用。")
	_check(NAME, _inventory.get_remaining(_MIRROR) == 1 and _inventory.get_remaining(_ACCELERATOR) == 1, "非法提交零库存变更。")
	_check(NAME, _occupancy.is_consistent(), "占用双向索引一致。")


## 4. Recover 语义：两类型各自回收数量归还、Stable ID 失效、再 Spawn 取新 ID（旧 ID 不复用）。
func _test_04_recover_and_respawn_new_stable_id() -> void:
	const NAME: String = "04_Recover与再Spawn"
	var mirror_snapshot: Dictionary = _object_registry.get_object_snapshot(_object_registry.get_stable_ids_of_type(_MIRROR)[0])
	var old_mirror_id: String = mirror_snapshot[_FormalObjectRegistry._K_STABLE_ID]
	_check(NAME, _inventory.get_remaining(_MIRROR) == 1, "回收前镜剩余 1。")
	var recover_result := _service.recover_instance(old_mirror_id)
	_check(NAME, recover_result.is_success(), "镜回收应成功。")
	_check(NAME, not _object_registry.has_object(old_mirror_id), "旧 Stable ID 应失效。")
	_check(NAME, not _occupancy.has_mechanism_at(Vector2i(2, 2)), "占用应注销。")
	_check(NAME, _inventory.get_remaining(_MIRROR) == 2, "数量应归还至 2。")
	# 再 Spawn：新 ID 不复用。
	_check(NAME, _service.begin_drag_reservation(_MIRROR), "再拿取应成功。")
	var respawn := _service.commit_spawn(_MIRROR, Vector2i(3, 3))
	_check(NAME, respawn.is_success(), "再 Spawn 应成功。")
	_check(NAME, respawn.stable_id != old_mirror_id, "再 Spawn 必须取得新 Stable ID。")
	# 回收未知/预置实例防御。
	_check(NAME, _service.recover_instance("fci_9999999").status == _DefinitionSpawnService.Status.REJECTED, "未知实例回收应 REJECTED。")


## 5. Generic Move：两类型既有实例同一路径移动（保 Stable ID、占用迁移、节点对齐）；非法目标拒绝保原状。
func _test_05_generic_move_both_types() -> void:
	const NAME: String = "05_通用移动"
	for move_case: Dictionary in [
		{"type": _MIRROR, "to": Vector2i(8, 8)},
		{"type": _ACCELERATOR, "to": Vector2i(9, 9)},
	]:
		var stable_ids: Array[String] = _object_registry.get_stable_ids_of_type(move_case["type"])
		var stable_id: String = stable_ids[0]
		var old_cell: Vector2i = _object_registry.get_object_snapshot(stable_id)[_FormalObjectRegistry._K_CELL]
		var move_result := _service.move_instance(stable_id, move_case["to"])
		_check(NAME, move_result.is_success(), "%s 移动应成功（%s）。" % [move_case["type"], move_result.message])
		_check(NAME, _object_registry.has_object(stable_id), "移动保 Stable ID。")
		_check(NAME, not _occupancy.has_mechanism_at(old_cell) and _occupancy.has_mechanism_at(move_case["to"]), "占用迁移。")
		_check(NAME, _object_registry.get_object_snapshot(stable_id)[_FormalObjectRegistry._K_CELL] == move_case["to"], "Registry 格更新。")
		# 非法目标：墙格拒绝、原状保持。
		var blocked := _service.move_instance(stable_id, _WALL_CELL)
		_check(NAME, blocked.status == _DefinitionSpawnService.Status.REJECTED, "移动到墙格应 REJECTED。")
		_check(NAME, _object_registry.get_object_snapshot(stable_id)[_FormalObjectRegistry._K_CELL] == move_case["to"], "拒绝后原状保持。")
		var same_cell := _service.move_instance(stable_id, move_case["to"])
		_check(NAME, same_cell.status == _DefinitionSpawnService.Status.NO_CHANGE, "原格移动应 NO_CHANGE。")


## 6. Reset restore：全部 Spawn 实例清除、库存恢复初始、Registry 只剩空（本测试无预置）。
func _test_06_reset_restore() -> void:
	const NAME: String = "06_ResetRestore"
	var unresolved: Array[String] = _service.reset_restore()
	_check(NAME, unresolved.is_empty(), "Reset 应全部回收，未解决：%s。" % [",".join(unresolved)])
	_check(NAME, _object_registry.get_count() == 0, "Registry 应清空。")
	_check(NAME, _inventory.get_remaining(_MIRROR) == 2 and _inventory.get_remaining(_ACCELERATOR) == 2, "两类型库存恢复初始。")
	_check(NAME, _occupancy.is_consistent() and not _occupancy.has_mechanism_at(Vector2i(8, 8)), "占用零残留。")


## 7. 无预留提交防御：未 begin_drag_reservation 直接 commit 应 REJECTED 且零变更。
func _test_07_no_reservation_commit_rejected() -> void:
	const NAME: String = "07_无预留提交"
	var result := _service.commit_spawn(_MIRROR, Vector2i(6, 6))
	_check(NAME, result.status == _DefinitionSpawnService.Status.REJECTED and result.reason == _DefinitionSpawnService.REASON_NO_RESERVATION, "无预留提交应 REJECTED(NO_RESERVATION)。")
	_check(NAME, _object_registry.get_count() == 0, "防御路径零注册。")


## 真实镜面 Definition（orientation 枚举 0..1，CYCLE_INTERNAL_STATE）。
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


## 真实加速器 Definition（direction 枚举 0..7，CYCLE_DIRECTION）。
func _make_accelerator_definition() -> _MechanismDefinition:
	var direction_field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	direction_field.field_id = &"direction"
	direction_field.display_name = "加速方向"
	direction_field.value_type = _MechanismFieldDefinition.ValueType.INT
	direction_field.enum_min = 0
	direction_field.enum_max = 7
	direction_field.default_value = 0
	direction_field.player_action = _PlayerInteractionAction.CYCLE_DIRECTION
	var definition: _MechanismDefinition = _MechanismDefinition.new()
	definition.content_type_id = _ACCELERATOR
	definition.display_name = "光粒加速器"
	definition.scene = preload("res://gameplay/mechanisms/speed/particle_accelerator.tscn")
	definition.inventory_eligible = true
	definition.static_footprint_offsets = [Vector2i.ZERO]
	definition.configuration_fields = [direction_field]
	definition.player_interaction_actions = [_PlayerInteractionAction.CYCLE_DIRECTION]
	return definition


## 清理：回收流程已 queue_free 全部实例节点，泵帧落地后确认 root 无残留（本测试 fixture 挂载节点）。
func _cleanup() -> void:
	for stable_id: String in _object_registry.get_stable_ids_by_origin(_FormalObjectRegistry.ORIGIN_SPAWNED):
		var snapshot: Dictionary = _object_registry.get_object_snapshot(stable_id)
		var token: Variant = snapshot[_FormalObjectRegistry._K_INSTANCE]
		if is_instance_valid(token) and token is Node:
			(token as Node).queue_free()
	await process_frame
	_check("清理", root.get_child_count() == 0, "测试结束 root 不应有残留子节点，实际 %d。" % [root.get_child_count()])


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("definition_spawn_service_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
