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
## 玩家机关类型索引（AF-10 第三批）：mechanism_id → 放置时的 token_type_id，随 place/recycle 同步维护；
## 多类型库存（MultiTypeInventory）回收归还需按类型路由，本映射是事务内类型的唯一事实（不解析 ID 字符串）。
var _placed_token_types: Dictionary = {}
var _factory: Callable
## 玩家已放置机关 ID → 正式节点；本控制器是唯一修改者，光线层经 get_placed_node 只读 Callable 解析，不再共享可写映射。
var _placed_tokens_by_id: Dictionary[StringName, Variant] = {}
var _next_serial: int = 1


## 构造事务控制器；occupancy、inventory、factory 必须非空。LevelWorldQuery 依赖本控制器 get_placed_node，构造后由 set_level_world_query 注入。
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
	# 2. 确认库存可用（拿起预览时不扣，此处仍未扣）；多类型库存按放置类型路由（AF-10 第三批）。
	if not _can_consume_for_type(token_type_id):
		return PlacementTransactionResult.new(Status.FAILED, &"", Vector2i.ZERO, target_cell, false, "库存不足")
	# 3. 生成唯一 mechanism_id（序号递增，失败也不复用）。
	var mechanism_id: StringName = _make_next_mechanism_id(token_type_id)
	# 4-5. 创建正式节点并确认有效；失败时无占用/映射/库存残留。
	var token: Variant = _factory.call(mechanism_id, target_cell, orientation)
	if not is_instance_valid(token):
		push_error("PlacementController: 创建正式机关节点失败，回滚（无占用/映射/库存变更）：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "节点创建失败")
	# 6. 登记占用（C-08 多格最小接线：按实例 footprint 展开绝对占格，单格机关仍登记 1 格）；失败则销毁已创建节点，不留有节点无占用。
	var occupied_cells: Array[Vector2i] = _get_occupied_cells(token, target_cell)
	if not _level_world_query.is_valid_placement_cell_set(occupied_cells, &""):
		push_error("PlacementController: 多格 footprint 含非法格，销毁已创建节点：%s at %s" % [mechanism_id, occupied_cells])
		_destroy_token(token)
		return PlacementTransactionResult.new(Status.INVALID, mechanism_id, Vector2i.ZERO, target_cell, false, "footprint 含非法格")
	if not _occupancy.register_cells(mechanism_id, occupied_cells):
		push_error("PlacementController: 占用登记失败，销毁已创建节点：%s at %s" % [mechanism_id, target_cell])
		_destroy_token(token)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "占用登记失败")
	# 7. 写入映射（Dictionary 赋值不会失败）。
	_placed_tokens_by_id[mechanism_id] = token
	# 8. 扣除库存；防御性回滚（can_consume 已通过，理论不会失败，仍逆序恢复以防竞态）；按放置类型路由。
	if not _try_consume_for_type(token_type_id):
		push_error("PlacementController: 库存扣除意外失败，逆序回滚映射/占用/节点：%s" % [mechanism_id])
		_placed_tokens_by_id.erase(mechanism_id)
		_occupancy.unregister(mechanism_id)
		_destroy_token(token)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, target_cell, false, "库存扣除失败")
	# 9. 成功；记录机关类型（回收归还需按类型路由）；新机关放置不消耗运行期移动次数。
	_placed_token_types[mechanism_id] = token_type_id
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, Vector2i.ZERO, target_cell, false)


## 已有机关移动原子事务。
## [br]原格返回 NO_CHANGE；非法格返回 INVALID；占用迁移委托 OccupancyRegistry.move_single_cell 原子完成，失败则节点/占用/映射/库存全部保持原状。
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
	# C-08 多格最小接线：源/目标 footprint 均按实例展开（orientation 不变故两套 offsets 同构）。
	var source_cells: Array[Vector2i] = _get_occupied_cells(token, source_cell)
	var target_cells: Array[Vector2i] = _get_occupied_cells(token, target_cell)
	# 非法格：INVALID（多格机关要求全部占格合法，ignored_id 忽略自身既有占用）。
	if not is_valid_placement_cells(target_cells, mechanism_id):
		return PlacementTransactionResult.new(Status.INVALID, mechanism_id, source_cell, target_cell, false, "目标格非法")
	# 原子占用迁移：校验全部通过后一次性更新正反向索引，失败则节点保持原格、占用/映射/库存不变。
	if not _occupancy.move_cells(mechanism_id, source_cells, target_cells):
		push_error("PlacementController: 原子占用迁移失败，节点保持原格：%s %s -> %s" % [mechanism_id, source_cell, target_cell])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, target_cell, false, "原子占用迁移失败")
	# 占用原子迁移成功；move_placed 经 token.set_cell() 把 position 对齐目标格中心、更新节点世界位置；可见性仍由核心恢复，orientation 不变。
	token.set_cell(target_cell)
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, source_cell, target_cell, true)


## 回收原子事务（预留两阶段归还，commit 成功前不动不可逆事实）。
## [br]顺序：确认存在 → 预留归还容量 → 暂时注销占用 → 提交归还 → 成功后才删映射/销毁节点。
## [br]预留失败：不注销占用、不删映射、不销毁节点，返回 FAILED，全部保持。
## [br]注销占用失败：取消预留，节点/映射/库存保持，返回 FAILED。
## [br]提交归还失败：用正式注册接口恢复原占用、取消预留，节点/映射/库存保持，返回 FAILED（事务一致，可重试）。
## [br]正常路径最终不出现“机关已删除但库存未归还”；不调用普通 try_return_one。
func recycle_placed(mechanism_id: StringName) -> PlacementTransactionResult:
	if not _placed_tokens_by_id.has(mechanism_id):
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, Vector2i.ZERO, Vector2i.ZERO, false, "机关不存在")
	var token: Variant = _placed_tokens_by_id[mechanism_id]
	var source_cell: Vector2i = Vector2i.ZERO
	if is_instance_valid(token):
		source_cell = token.cell
	# 回收归还需按放置类型路由（AF-10 第三批）：类型索引缺失时传空类型（旧单类型库存按旧名接口工作）。
	var token_type_id: StringName = _placed_token_types.get(mechanism_id, &"")
	# 1. 不可逆销毁前先预留库存归还容量；失败则节点/映射/占用/库存全部保持。
	if not _try_reserve_return_for_type(token_type_id):
		push_error("PlacementController: 回收库存归还预留失败，保留节点/映射/占用：%s" % [mechanism_id])
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, Vector2i.ZERO, false, "库存归还预留失败")
	# 2. 暂时注销占用；失败则取消预留，节点/映射/库存保持。
	if not _occupancy.unregister(mechanism_id):
		push_error("PlacementController: 回收注销占用失败，取消预留并保留节点/映射/库存：%s" % [mechanism_id])
		_cancel_reserved_return_for_type(token_type_id)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, Vector2i.ZERO, false, "注销占用失败")
	# 3. 提交归还；失败则用正式注册接口恢复原占用、取消预留，节点/映射/库存保持，事务一致可重试。
	# 回滚恢复占用的事务假设：刚注销的是同一 mechanism_id 与 source_cell，且库存 commit 不修改占用，
	# 故 register_single_cell 原则上必成功；返回 false 即不变量破坏，必须 push_error 报告，不得静默吞掉。
	# 无论恢复成功与否，预留都只在此清理一次；Token/映射保留、不 queue_free、不进入成功路径、不改内部 Dictionary。
	if not _commit_reserved_return_for_type(token_type_id):
		push_error("PlacementController: 回收提交归还失败，恢复占用并取消预留，保留节点/映射/库存：%s" % [mechanism_id])
		if not _occupancy.register_cells(mechanism_id, _get_occupied_cells(token, source_cell)):
			push_error("PlacementController: 回收回滚恢复占用失败（不变量破坏）：%s at %s" % [mechanism_id, source_cell])
		_cancel_reserved_return_for_type(token_type_id)
		return PlacementTransactionResult.new(Status.FAILED, mechanism_id, source_cell, Vector2i.ZERO, false, "库存归还提交失败")
	# 4. 归还已提交成功：删映射与类型索引 → 销毁节点（queue_free 不必等待真正释放）。
	_placed_tokens_by_id.erase(mechanism_id)
	_placed_token_types.erase(mechanism_id)
	_destroy_token(token)
	return PlacementTransactionResult.new(Status.SUCCESS, mechanism_id, source_cell, Vector2i.ZERO, false)


## 库存类型路由辅助（AF-10 第三批）：注入 MultiTypeInventory 时走显式按类型事务；
## 旧 InventoryController（单类型）保持原接口调用，既有测试与原型路径行为不变。
## 类型为空时对多类型库存返回 false（无选中类型不可消费/归还），对旧单类型库存退回旧名接口。

## 指定类型是否可扣除一个。
func _can_consume_for_type(type_id: StringName) -> bool:
	var inventory: Variant = _inventory
	if inventory.has_method("can_consume_one_for"):
		return inventory.can_consume_one_for(type_id)
	return _inventory.can_consume_one()


## 指定类型扣除一个。
func _try_consume_for_type(type_id: StringName) -> bool:
	var inventory: Variant = _inventory
	if inventory.has_method("try_consume_one_for"):
		return inventory.try_consume_one_for(type_id)
	return _inventory.try_consume_one()


## 指定类型归还预留两阶段第一阶段。
func _try_reserve_return_for_type(type_id: StringName) -> bool:
	var inventory: Variant = _inventory
	if inventory.has_method("try_reserve_return_one_for"):
		return inventory.try_reserve_return_one_for(type_id)
	return _inventory.try_reserve_return_one()


## 指定类型归还预留两阶段第二阶段。
func _commit_reserved_return_for_type(type_id: StringName) -> bool:
	var inventory: Variant = _inventory
	if inventory.has_method("commit_reserved_return_for"):
		return inventory.commit_reserved_return_for(type_id)
	return _inventory.commit_reserved_return()


## 取消指定类型归还预留（失败结果忽略：调用点语义为尽力清理，残留由一致性断言暴露）。
func _cancel_reserved_return_for_type(type_id: StringName) -> void:
	var inventory: Variant = _inventory
	if inventory.has_method("cancel_reserved_return_for"):
		inventory.cancel_reserved_return_for(type_id)
		return
	_inventory.cancel_reserved_return()


## R 清理：复用 recycle_placed 单一回收事务逐个清理玩家机关，不维护第二套回收路径。
## [br]成功项：预留→注销→删映射→销毁→提交归还，库存随每次成功回收原子加一。
## [br]失败项（预留失败或注销失败）保留节点/映射/占用并取消预留，不残留归还预留。
## [br]正常全部清理后库存恢复满，部分失败时 remaining + unresolved_count == total；不修改 LevelRuntimeController 的 R 顺序。
func clear_all_placed() -> ClearPlacedResult:
	# 必须先快照 ID，遍历中 erase 会改变迭代集合。
	var mechanism_ids: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(_placed_tokens_by_id)
	var removed_count: int = 0
	var unresolved_ids: Array[StringName] = []

	for mechanism_id: StringName in mechanism_ids:
		var r: PlacementTransactionResult = recycle_placed(mechanism_id)
		if r.is_success():
			removed_count += 1
			continue
		# 失败项保留节点/映射/占用，由一致性断言暴露；recycle_placed 内部已取消任何未提交预留。
		unresolved_ids.append(mechanism_id)
		push_error("PlacementController: R 清理无法回收玩家机关，保留节点/映射/占用：%s（%s）" % [mechanism_id, r.error_message])

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


## 读取机关实例 footprint 展开的绝对占格（C-08 多格最小接线，冻结裁决 2）。
## 实例提供 get_occupied_offsets（D7-R4 契约，PlaceableToken/GridPlacedObject 同名）时经锚格展开；
## 否则退回单格 [anchor_cell]。offsets 与朝向无关（双格镜/分光器均为线形），朝向事实由实例自持，
## 事务层不透传 orientation。不写占用表，只读实例。
func _get_occupied_cells(token: Variant, anchor_cell: Vector2i) -> Array[Vector2i]:
	if is_instance_valid(token) and token.has_method("get_occupied_offsets"):
		var cells: Array[Vector2i] = []
		for offset: Variant in token.get_occupied_offsets():
			cells.append(anchor_cell + (offset as Vector2i))
		return cells
	return [anchor_cell]


## 多格放置合法性格点（D7-R4 多格最小路径）：非空、格间无重复、每格均满足单格合法性判定；
## 委托 LevelWorldQuery.is_valid_placement_cell_set，ignored_id 允许移动/旋转中的多格机关忽略自身既有占用。
## [br]只做合法性判断：不登记占用、不创建节点、不扣库存；未来多格机关流程在合法性通过后
## 经 OccupancyRegistry.register_cells / move_cells 原子提交占用事实。LevelWorldQuery 未注入时返回 false。
func is_valid_placement_cells(cells: Array[Vector2i], ignored_id: StringName = &"") -> bool:
	if _level_world_query == null:
		push_error("PlacementController: LevelWorldQuery 未注入，无法校验多格放置合法性。")
		return false
	return _level_world_query.is_valid_placement_cell_set(cells, ignored_id)


## 安全销毁节点；只对有效 Node 调 queue_free，非节点或已失效安全忽略。
func _destroy_token(token: Variant) -> void:
	if is_instance_valid(token) and token is Node:
		(token as Node).queue_free()
