extends RefCounted

## 玩家机关放置/移动/回收原子事务控制器（D2-B）。
## 唯一持有 placed_tokens_by_id 映射与机关序号，负责新机关放置、已有机关移动、回收与 R 清理的原子提交与失败回滚。
## 依赖：OccupancyRegistry（占用事实）、LevelWorldQuery（格合法性）、InventoryController（库存扣还）、创建正式节点的 Callable。
## 不持有 RunState、runtime_moves_used、拖拽字段、预览节点或 UI；移动扣次由核心按事务结果决定。
## 原子性：任一步骤失败均逆序回滚占用、映射、节点与库存，禁止留下半提交（有占用无节点/有映射无占用/库存已扣机关未成立）。

const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _PlayerMechanismResetRules: GDScript = preload("res://gameplay/placement/rules/player_mechanism_reset_rules.gd")


## 事务状态。SUCCESS 成功；NO_CHANGE 原格无变化；INVALID 非法输入（格不合法）；FAILED 事务失败（已回滚）。
enum Status {
	SUCCESS,
	NO_CHANGE,
	INVALID,
	FAILED,
}


## 放置/移动/回收事务结果：状态、机关 ID、源/目标格、是否消耗运行期移动次数、错误说明。
## 不含 UI 节点、拖拽预览、RunState、光线数据、水晶或 Diagnostics 记录对象。
class PlacementTransactionResult:
	var status: Status = Status.FAILED
	var mechanism_id: StringName = &""
	var source_cell: Vector2i = Vector2i.ZERO
	var target_cell: Vector2i = Vector2i.ZERO
	var consumes_runtime_move: bool = false
	var error_message: String = ""

	func _init(
			p_status: Status = Status.FAILED,
			p_mechanism_id: StringName = &"",
			p_source_cell: Vector2i = Vector2i.ZERO,
			p_target_cell: Vector2i = Vector2i.ZERO,
			p_consumes_runtime_move: bool = false,
			p_error_message: String = ""
	) -> void:
		status = p_status
		mechanism_id = p_mechanism_id
		source_cell = p_source_cell
		target_cell = p_target_cell
		consumes_runtime_move = p_consumes_runtime_move
		error_message = p_error_message

	## 是否成功提交。
	func is_success() -> bool:
		return status == Status.SUCCESS


## R 清理结果：已清理数、未清理数、未清理机关 ID 列表。
class ClearPlacedResult:
	var removed_count: int = 0
	var unresolved_count: int = 0
	var unresolved_ids: Array[StringName] = []

	func _init(
			p_removed_count: int = 0,
			p_unresolved_count: int = 0,
			p_unresolved_ids: Array[StringName] = []
	) -> void:
		removed_count = p_removed_count
		unresolved_count = p_unresolved_count
		unresolved_ids = p_unresolved_ids


var _occupancy: _OccupancyRegistry
var _level_world_query: _LevelWorldQuery = null
var _inventory: _InventoryController
var _factory: Callable
## 玩家已放置机关 ID → 正式节点；本控制器是唯一修改者，LevelWorldQuery 持有同一引用用于光线层 cell→节点解析。
var _placed_tokens_by_id: Dictionary[StringName, Variant] = {}
var _next_serial: int = 1


## 构造事务控制器；occupancy、inventory、factory 必须非空。LevelWorldQuery 依赖本控制器映射，构造后由 set_level_world_query 注入。
func _init(
		occupancy: _OccupancyRegistry,
		inventory: _InventoryController,
		factory: Callable
) -> void:
	_occupancy = occupancy
	_inventory = inventory
	_factory = factory


## 注入只读世界查询门面；必须在任何事务前调用，提供放置/移动格合法性校验。
func set_level_world_query(level_world_query: _LevelWorldQuery) -> void:
	_level_world_query = level_world_query


## 返回内部映射引用；仅供核心构造 LevelWorldQuery 时传入，本控制器是唯一修改者，不得由调用方写入。
func get_placed_tokens_by_id_reference() -> Dictionary[StringName, Variant]:
	return _placed_tokens_by_id


## 新机关放置原子事务。
## [br]顺序：再次校验目标格 → 确认库存 → 生成 ID → 创建节点 → 登记占用 → 写映射 → 扣库存。
## [br]非法格返回 INVALID；节点创建/占用登记/库存扣除失败返回 FAILED 并逆序回滚。
## [br]拿起预览不扣库存；只有合法放置成功才扣库存；序号允许跳号，ID 永不复用。
func place_from_inventory(
		token_type_id: StringName,
		target_cell: Vector2i,
		orientation: Variant
) -> PlacementTransactionResult:
	# 1. 再次校验目标格（边界/静态/占用）。
	if not _is_valid_placement_cell(target_cell, &""):
		return PlacementTransactionResult.new(Status.INVALID, &"", Vector2i.ZERO, target_cell, false, "目标格非法")
	# 2. 确认库存可用（拿起预览时不扣，此处仍未扣）。
	if not _inventory.can_consume_one():
		return PlacementTransactionResult.new(Status.FAILED, &"", Vector2i.ZERO, target_cell, false, "库存不足")
	# 3. 生成唯一 mechanism_id（序号递增，失败也不复用）。
	var mechanism_id: StringName = _make_next_mechanism_id(token_type_id)
	# 4-5. 创建正式节点并确认有效；失败时无占用/映射/库存残留。
	var token: Variant = _factory.call(mechanism_id, target_cell, orientation)
	if not is_instance_valid(token):
		push_error("PlacementController: 创建正式机关节点失败，回滚（无占用/映射/库存变更）：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "节点创建失败")
	# 6. 登记占用；失败则销毁已创建节点，不留有节点无占用。
	if not _occupancy.register_single_cell(mechanism_id, target_cell):
		push_error("PlacementController: 占用登记失败，销毁已创建节点：%s at %s" % [mechanism_id, target_cell])
		_destroy_token(token)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "占用登记失败")
	# 7. 写入映射（Dictionary 赋值不会失败）。
	_placed_tokens_by_id[mechanism_id] = token
	# 8. 扣除库存；防御性回滚（can_consume_one 已通过，理论不会失败，仍逆序恢复以防竞态）。
	if not _inventory.try_consume_one():
		push_error("PlacementController: 库存扣除意外失败，逆序回滚映射/占用/节点：%s" % [mechanism_id])
		_placed_tokens_by_id.erase(mechanism_id)
		_occupancy.unregister(mechanism_id)
		_destroy_token(token)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "库存扣除失败")
	# 9. 成功；新机关放置不消耗运行期移动次数。
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, Vector2i.ZERO, target_cell, false)


## 已有机关移动原子事务。
## [br]原格返回 NO_CHANGE；非法格返回 INVALID；注销旧占用与登记新占用原子，新占用失败恢复旧占用与节点格。
## [br]不修改 orientation、不扣库存、不直接扣 runtime_moves_used；成功跨格返回 consumes_runtime_move=true，由核心按规则扣次。
func move_placed(
		mechanism_id: StringName,
		target_cell: Vector2i
) -> PlacementTransactionResult:
	# 确认机关存在且节点有效。
	if not _placed_tokens_by_id.has(mechanism_id):
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "机关不存在")
	var token: Variant = _placed_tokens_by_id[mechanism_id]
	if not is_instance_valid(token):
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "机关节点失效")
	var source_cell: Vector2i = token.cell
	# 原格：NO_CHANGE，不扣次。
	if target_cell == source_cell:
		return PlacementTransactionResult.new(Status.NO_CHANGE, mechanism_id, source_cell, target_cell, false)
	# 非法格：INVALID。
	if not _is_valid_placement_cell(target_cell, mechanism_id):
		return PlacementTransactionResult.new(Status.INVALID, mechanism_id, source_cell, target_cell, false, "目标格非法")
	# 原子更新：先注销旧占用再登记新占用；失败必须恢复旧占用，避免新旧同时丢失。
	if not _occupancy.unregister(mechanism_id):
		push_error("PlacementController: 移动前旧占用不存在，回滚：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, target_cell, false, "旧占用缺失")
	if not _occupancy.register_single_cell(mechanism_id, target_cell):
		push_error("PlacementController: 新占用登记失败，恢复旧占用：%s -> %s" % [source_cell, target_cell])
		# 恢复旧占用；若连恢复也失败则占用处于丢失状态，保留节点原格供一致性断言暴露。
		if not _occupancy.register_single_cell(mechanism_id, source_cell):
			push_error("PlacementController: 恢复旧占用失败，占用丢失，保留节点原格供断言暴露：%s" % [mechanism_id])
			return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, target_cell, false, "恢复旧占用失败")
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, target_cell, false, "新占用登记失败")
	# 占用原子更新成功；更新节点逻辑格（世界位置与可见性由核心处理），orientation 不变。
	token.set_cell(target_cell)
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, source_cell, target_cell, true)


## 回收原子事务。
## [br]顺序：确认存在 → 注销占用 → 删映射 → 销毁节点 → 库存归还。
## [br]注销占用失败则不删映射、不销毁节点、不归还库存，返回 FAILED，避免半提交。
func recycle_placed(mechanism_id: StringName) -> PlacementTransactionResult:
	if not _placed_tokens_by_id.has(mechanism_id):
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, Vector2i.ZERO, false, "机关不存在")
	var token: Variant = _placed_tokens_by_id[mechanism_id]
	var source_cell: Vector2i = Vector2i.ZERO
	if is_instance_valid(token):
		source_cell = token.cell
	# 注销占用；失败则保留节点/映射/库存。
	if not _occupancy.unregister(mechanism_id):
		push_error("PlacementController: 回收注销占用失败，保留节点/映射/库存：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, Vector2i.ZERO, false, "注销占用失败")
	# 占用已清理：删映射 → 销毁节点 → 归还库存（queue_free 不必等待真正释放）。
	_placed_tokens_by_id.erase(mechanism_id)
	_destroy_token(token)
	if not _inventory.try_return_one():
		# 归还失败（已达总量，异常）：映射与节点已清理，库存未增，由一致性断言暴露。
		push_error("PlacementController: 回收归还库存失败（已达总量？），映射与节点已清理，库存未增：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, Vector2i.ZERO, false, "库存归还失败")
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, source_cell, Vector2i.ZERO, false)


## R 清理：逐个尝试注销/销毁/移除玩家机关。
## [br]成功项：注销、erase、queue_free；失败项（OccupancyRegistry 残留引用）保留映射与占用，不假装成功。
## [br]清理后按残留数 reconcile 库存，保持 remaining + placed_count == total；不使用 Node.name，不静默归还未清理机关库存。
func clear_all_placed() -> ClearPlacedResult:
	# 必须先快照 ID，遍历中 erase 会改变迭代集合。
	var mechanism_ids: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(_placed_tokens_by_id)
	var removed_count: int = 0
	var unresolved_ids: Array[StringName] = []

	for mechanism_id: StringName in mechanism_ids:
		var token: Variant = _placed_tokens_by_id.get(mechanism_id)
		var was_unregistered: bool = _occupancy.unregister(mechanism_id)
		var has_residual: bool = _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(_occupancy, mechanism_id)

		if has_residual:
			# 残留引用：保留映射/节点/库存，失败关闭，由一致性断言暴露。
			unresolved_ids.append(mechanism_id)
			push_error("PlacementController: R 清理无法注销玩家机关占用，保留映射与节点：%s" % [mechanism_id])
			if not is_instance_valid(token):
				push_error("PlacementController: R 清理时节点已失效且占用残留，保留映射供断言暴露：%s" % [mechanism_id])
			continue

		if not was_unregistered and OS.is_debug_build():
			push_warning("PlacementController: R 清理时占用已提前缺失，继续清理节点：%s" % [mechanism_id])

		_destroy_token(token)
		_placed_tokens_by_id.erase(mechanism_id)
		removed_count += 1

	# 按残留数 reconcile 库存：全部清理恢复满库存，部分失败扣除残留数。
	_inventory.reconcile_with_placed_count(unresolved_ids.size())
	return ClearPlacedResult.new(removed_count, unresolved_ids.size(), unresolved_ids)


## 取得正式机关节点；ID 未登记或节点失效返回 null，调用方需自行 is_instance_valid 校验。
func get_placed_node(mechanism_id: StringName) -> Variant:
	if not _placed_tokens_by_id.has(mechanism_id):
		return null
	return _placed_tokens_by_id[mechanism_id]


## 是否存在指定机关映射。
func has_placed(mechanism_id: StringName) -> bool:
	return _placed_tokens_by_id.has(mechanism_id)


## 当前已放置机关数量。
func get_placed_count() -> int:
	return _placed_tokens_by_id.size()


## 已放置机关 ID 快照（按映射当前迭代顺序）；返回后映射增删不影响快照。
func get_placed_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for key: Variant in _placed_tokens_by_id.keys():
		ids.append(StringName(key))
	return ids


## 生成下一个正式机关唯一 ID；回收后旧 ID 不复用，序号允许跳号但不影响唯一性。
func _make_next_mechanism_id(token_type_id: StringName) -> StringName:
	var mechanism_id: StringName = StringName("%s_%d" % [token_type_id, _next_serial])
	_next_serial += 1
	return mechanism_id


## 校验目标格是否为合法放置格；ignored_id 为移动已放置机关时允许忽略的自身 ID。LevelWorldQuery 未注入时返回 false。
func _is_valid_placement_cell(cell: Vector2i, ignored_id: StringName) -> bool:
	if _level_world_query == null:
		push_error("PlacementController: LevelWorldQuery 未注入，无法校验格合法性。")
		return false
	return _level_world_query.is_valid_placement_cell(cell, ignored_id)


## 安全销毁节点；只对有效 Node 调 queue_free，非节点或已失效安全忽略。
func _destroy_token(token: Variant) -> void:
	if is_instance_valid(token) and token is Node:
		(token as Node).queue_free()
