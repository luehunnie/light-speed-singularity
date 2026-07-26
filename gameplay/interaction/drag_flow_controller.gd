extends RefCounted

## 拖拽业务流程控制器（D3-A）：完整拥有一次拖拽的业务生命周期。
## 库存/场上机关拿取 → 预览创建与更新 → 合法/非法反馈 → 正式节点隐藏与恢复 →
## 新放置/移动/回收提交或取消 → 预览与 DragContext 清理 → 请求 UI 刷新与一致性断言。
## 所有权：持有 DragContext、预览节点句柄、被拖正式节点句柄；不持有库存数量、placed_tokens_by_id、占用表、
## RunState 或 runtime_moves_used——后者经只读 Callable 查询、经扣除 Callable 提交，事务仍由 PlacementController/InventoryController 原子负责。
## 节点恢复顺序：恢复/确认正式节点终态 → 清预览 → 清句柄 → DragContext.clear() → 刷新 UI → 一致性断言；cancel_current_drag 可被 R、COMPLETED、非法提交、事务失败安全调用。

const _DragContext: GDScript = preload("res://gameplay/interaction/drag_context.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _RuntimeMoveRules: GDScript = preload("res://gameplay/placement/rules/runtime_move_rules.gd")
const _PlacementController: GDScript = preload("res://gameplay/placement/placement_controller.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _SingleCellMirror: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")

## 库存拖拽的机关类型 ID；与核心 MIRROR_TOKEN_TYPE_ID 一致，不复制拖拽事实（事实由 DragContext 持有）。
const MIRROR_TOKEN_TYPE_ID: StringName = &"basic_single_cell_mirror"

## 一次拖拽的临时事实唯一所有者；本控制器是唯一修改者，核心不再持有副本。
var _drag_context: _DragContext = _DragContext.new()
## 拖拽预览节点句柄；仅作生命周期管理，不作为机关事实来源。
var _drag_preview_token: Variant = null
## 被拖正式机关节点句柄；正式机关事实仍由 PlacementController 持有，本字段仅用于隐藏/恢复视觉。
var _dragged_placed_token: Variant = null

var _placement_controller: _PlacementController
var _inventory_controller: _InventoryController
var _level_world_query: _LevelWorldQuery
## 场景适配：把指针位置解析为机关栏/原型槽位命中与世界格。
var _resolve_pointer: Callable
## 场景适配：创建拖拽预览节点（实例化与挂载由核心负责）。
var _create_preview_token: Callable
## 只读权限快照：当前运行状态与剩余运行期移动次数；不保存或修改 RunState。
var _query_permission: Callable
## 扣除一次运行期移动次数；runtime_moves_used 由 LevelRuntimeController 唯一持有，本控制器仅经只读查询与扣次请求边界使用运行期移动规则，不保存计数事实。
var _consume_runtime_move: Callable
## 刷新机关栏与运行期移动 UI（纯显示，不修改事实）。
var _refresh_ui: Callable
## 执行库存一致性断言（Debug 构建）。
var _assert_consistency: Callable


## 指针命中场景信息：是否位于机关栏、是否位于原型槽位、世界格坐标。
class PointerScene:
	var over_inventory_bar: bool
	var over_prototype_slot: bool
	var world_cell: Vector2i
	func _init(
			p_over_inventory_bar: bool = false,
			p_over_prototype_slot: bool = false,
			p_world_cell: Vector2i = Vector2i.ZERO
	) -> void:
		over_inventory_bar = p_over_inventory_bar
		over_prototype_slot = p_over_prototype_slot
		world_cell = p_world_cell


## 拖拽权限只读快照：当前运行状态与剩余运行期移动次数。
class DragPermission:
	var run_state: _RuntimeInteractionTypes.RunState = _RuntimeInteractionTypes.RunState.SETUP
	var moves_remaining: int = 0
	func _init(
			p_run_state: _RuntimeInteractionTypes.RunState = _RuntimeInteractionTypes.RunState.SETUP,
			p_moves_remaining: int = 0
	) -> void:
		run_state = p_run_state
		moves_remaining = p_moves_remaining


## 构造拖拽流程控制器；placement/inventory/level_world_query 与场景适配 Callable 由核心注入。
func _init(
		placement_controller: _PlacementController,
		inventory_controller: _InventoryController,
		level_world_query: _LevelWorldQuery,
		resolve_pointer: Callable,
		create_preview_token: Callable,
		query_permission: Callable,
		consume_runtime_move: Callable,
		refresh_ui: Callable,
		assert_consistency: Callable
) -> void:
	_placement_controller = placement_controller
	_inventory_controller = inventory_controller
	_level_world_query = level_world_query
	_resolve_pointer = resolve_pointer
	_create_preview_token = create_preview_token
	_query_permission = query_permission
	_consume_runtime_move = consume_runtime_move
	_refresh_ui = refresh_ui
	_assert_consistency = assert_consistency


## 尝试根据指针位置开始一次拖拽；库存拿取在所有非 COMPLETED 状态允许，已放置机关拖起由状态规则限制。
## 失败时不创建预览、不隐藏正式机关、不改占用与库存。返回是否成功开始。
func try_begin_drag(pointer_position: Vector2) -> bool:
	if is_dragging():
		return false
	var permission: DragPermission = _query_permission.call()
	# COMPLETED 冻结一切新拖拽；can_take/can_begin 规则对 COMPLETED 亦返回 false，等价于 can_edit_layout 门。
	if permission.run_state == _RuntimeInteractionTypes.RunState.COMPLETED:
		return false
	var scene: PointerScene = _resolve_pointer.call(pointer_position)
	if scene.over_prototype_slot:
		# 库存拿取：库存大于 0 且状态允许；数量为 0 或状态锁定时不创建预览。
		if _inventory_controller.can_consume_one() and _RuntimeMoveRules.can_take_from_inventory_for_state(permission.run_state):
			_begin_inventory_drag(scene.world_cell)
			update_preview(pointer_position)
			return true
		return false
	if scene.over_inventory_bar:
		# 命中机关栏空白区域：不换算世界格、不启动拖拽。
		return false
	var mechanism_id: StringName = _level_world_query.get_mechanism_id_at(scene.world_cell)
	if mechanism_id == &"":
		return false
	if not _placement_controller.has_placed(mechanism_id):
		return false
	# 已放置机关拖起在所有非 COMPLETED 状态允许（与剩余次数分离）；剩余 0 仍可拖起以便回收/取消，跨格提交二次校验。
	if not _RuntimeMoveRules.can_begin_placed_drag(permission.run_state):
		return false
	if _begin_placed_drag(mechanism_id, scene.world_cell):
		update_preview(pointer_position)
		return true
	return false


## 从机关栏开始一次库存拖拽：创建默认 SLASH 预览，来源设为 INVENTORY；不扣库存，非法/松回不变化。
func _begin_inventory_drag(start_cell: Vector2i) -> void:
	_drag_context.begin_inventory(MIRROR_TOKEN_TYPE_ID, start_cell, _SingleCellMirror.MirrorOrientation.SLASH)
	_dragged_placed_token = null
	_drag_preview_token = _create_preview_token.call(StringName("preview_%s" % MIRROR_TOKEN_TYPE_ID), start_cell)


## 从已放置机关开始拖拽移动：一致性校验通过后隐藏正式视觉、创建预览、复制朝向、记录原格。
## 写入拖拽字段前完成全部一致性检查；任一失败 push_error 并返回 false，未创建预览、未隐藏节点。
func _begin_placed_drag(mechanism_id: StringName, original_cell: Vector2i) -> bool:
	if not _placement_controller.has_placed(mechanism_id):
		push_error("DragFlowController: 拖起失败，玩家机关映射缺少机关 %s。" % [mechanism_id])
		return false
	var token: Variant = _placement_controller.get_placed_node(mechanism_id)
	if not is_instance_valid(token):
		push_error("DragFlowController: 拖起失败，机关 %s 节点已失效。" % [mechanism_id])
		return false
	if token.mechanism_id != mechanism_id:
		push_error("DragFlowController: 拖起失败，机关 ID 失配：参数=%s，节点=%s。" % [mechanism_id, token.mechanism_id])
		return false
	if token.cell != original_cell:
		push_error("DragFlowController: 拖起失败，机关 %s cell 失配：参数=%s，节点=%s。" % [mechanism_id, original_cell, token.cell])
		return false
	# 起始朝向快照取自正式节点；已放置拖拽保留当前朝向，库存拖拽另由 _begin_inventory_drag 设为 SLASH。
	var orientation: _SingleCellMirror.MirrorOrientation = _SingleCellMirror.MirrorOrientation.SLASH
	if token is _SingleCellMirror:
		orientation = (token as _SingleCellMirror).orientation
	_drag_context.begin_placed(mechanism_id, original_cell, original_cell, orientation)
	_dragged_placed_token = token
	# 拖拽期间保留旧逻辑占用，只隐藏正式视觉，松手后再原子更新；预览复制当前朝向。
	token.set_placed_visible(false)
	_drag_preview_token = _create_preview_token.call(mechanism_id, original_cell)
	_copy_mirror_orientation_if_possible(_dragged_placed_token, _drag_preview_token)
	return true


## 根据指针位置更新拖拽预览：位于机关栏时只隐藏世界预览（不把 UI 坐标转成虚假格子），离开后吸附格中心并按空间合法性与松手提交权限刷新合法/非法反馈。
## 隐藏预览不等于取消拖拽；预览颜色只是视觉反馈，不替代正式提交的二次校验。
func update_preview(pointer_position: Vector2) -> void:
	if not _drag_context.is_active() or _drag_preview_token == null:
		return
	var scene: PointerScene = _resolve_pointer.call(pointer_position)
	if scene.over_inventory_bar:
		_drag_preview_token.set_drag_preview_visible(false)
		return
	_drag_preview_token.set_drag_preview_visible(true)
	_drag_context.update_preview_cell(scene.world_cell)
	var permission: DragPermission = _query_permission.call()
	var spatially_valid: bool = _is_valid_placement_cell(_drag_context.preview_cell, _drag_context.mechanism_id)
	var is_valid: bool = _RuntimeMoveRules.is_world_drop_preview_valid(
		_drag_context.source,
		permission.run_state,
		permission.moves_remaining,
		_drag_context.original_cell,
		_drag_context.preview_cell,
		spatially_valid
	)
	_drag_preview_token.set_cell(_drag_context.preview_cell)
	_drag_preview_token.set_world_position(_GridCoordinateRules.cell_to_world(_drag_context.preview_cell))
	_drag_preview_token.set_drag_preview(true, is_valid)


## 在松开位置完成当前拖拽：按来源与松手区域执行库存放置、已放置机关移动、拖回机关栏回收或取消。
## 库存释放回机关栏只取消；只有 PLACED 拖拽可回收，回收在所有非 COMPLETED 状态允许，COMPLETED 释放到机关栏改为安全取消。
func finish_drag(pointer_position: Vector2) -> void:
	var scene: PointerScene = _resolve_pointer.call(pointer_position)
	var is_released_over_inventory: bool = scene.over_inventory_bar
	if _drag_context.is_inventory_source():
		if is_released_over_inventory:
			cancel_current_drag()
			return
		_commit_inventory_drag_or_cancel()
		return
	if _drag_context.is_placed_source():
		if is_released_over_inventory:
			# 回收在所有非 COMPLETED 状态允许；COMPLETED 释放到机关栏改为安全取消，保留原占用与原位置，不增库存、不扣次数。
			if _RuntimeMoveRules.can_recycle_placed_token_for_state(_query_permission.call().run_state):
				_recycle_dragged_placed_token()
			else:
				cancel_current_drag()
			return
		_commit_placed_drag_or_cancel()


## 提交库存拖拽：放置事务由 PlacementController 原子负责（格校验/库存/节点/占用/映射/扣库存与回滚）。
## 非法/事务失败取消拖拽，不扣库存、不创建正式机关；运行期首次放置不消耗 runtime_moves_used。
func _commit_inventory_drag_or_cancel() -> void:
	if not _RuntimeMoveRules.can_take_from_inventory_for_state(_query_permission.call().run_state):
		cancel_current_drag()
		return
	var result := _placement_controller.place_from_inventory(
		_drag_context.token_type_id,
		_drag_context.preview_cell,
		_drag_context.original_orientation,
	)
	if not result.is_success():
		cancel_current_drag()
		return
	# 成功：库存已扣、占用与映射已成立；清理预览与上下文后再刷新 UI 与断言。
	_clear_drag_preview_only()
	_reset_drag_state()
	_refresh_ui.call()
	_assert_consistency.call()


## 提交已放置机关移动：移动事务由 PlacementController 原子负责（旧占用注销/新占用登记/节点 cell 更新与回滚）。
## 提交前二次校验节点/状态/剩余次数；原格/非法/失败取消，不扣次数；仅跨格成功后请求扣除一次（SETUP 不计次）。
func _commit_placed_drag_or_cancel() -> void:
	var token: Variant = _dragged_placed_token
	var mechanism_id: StringName = _drag_context.mechanism_id
	var from_cell: Vector2i = _drag_context.original_cell
	var to_cell: Vector2i = _drag_context.preview_cell
	# 提交前校验：节点有效、拖拽状态一致；失败安全取消，保留原占用，不扣次数。
	if not is_instance_valid(token):
		push_error("DragFlowController: 提交移动前拖拽节点已失效，取消拖拽。")
		cancel_current_drag()
		return
	if token.mechanism_id != mechanism_id or token.cell != from_cell:
		push_error("DragFlowController: 提交移动前拖拽节点状态不一致，取消拖拽。")
		cancel_current_drag()
		return
	var permission: DragPermission = _query_permission.call()
	if not _RuntimeMoveRules.can_commit_placed_move(permission.run_state, permission.moves_remaining, from_cell, to_cell):
		cancel_current_drag()
		return
	var result := _placement_controller.move_placed(mechanism_id, to_cell)
	if not result.is_success():
		# NO_CHANGE/INVALID/FAILED：节点仍在原格，恢复可见性并取消，不扣次数。
		cancel_current_drag()
		return
	# 成功：确认正式节点终态（世界位置与可见性）→ 清预览/上下文 → 扣次 → 刷新 UI → 断言；orientation 不变。
	token.set_world_position(_GridCoordinateRules.cell_to_world(to_cell))
	token.set_placed_visible(true)
	_clear_drag_preview_only()
	_reset_drag_state()
	if _RuntimeMoveRules.should_count_runtime_move(permission.run_state, from_cell, to_cell):
		_consume_runtime_move.call()
	_refresh_ui.call()
	_assert_consistency.call()


## 回收当前已放置机关拖拽：回收事务由 PlacementController 原子负责（注销占用/删映射/销毁节点/库存归还）。
## 防御性状态检查：COMPLETED/未知状态安全取消并恢复原机关，不增库存。回收不消耗 runtime_moves_used；失败恢复正式节点。
func _recycle_dragged_placed_token() -> void:
	if not _drag_context.is_placed_source() or _dragged_placed_token == null:
		cancel_current_drag()
		return
	if not _RuntimeMoveRules.can_recycle_placed_token_for_state(_query_permission.call().run_state):
		cancel_current_drag()
		return
	var result := _placement_controller.recycle_placed(_drag_context.mechanism_id)
	if not result.is_success():
		push_error("DragFlowController: 回收事务失败，恢复原机关：%s（%s）。" % [_drag_context.mechanism_id, result.error_message])
		cancel_current_drag()
		return
	_clear_drag_preview_only()
	_reset_drag_state()
	_refresh_ui.call()
	_assert_consistency.call()


## 取消当前拖拽并恢复拖拽前状态：删除预览；已放置机关且节点有效则恢复原格/位置/可见性；随后清空拖拽状态。
## should_assert_consistency：普通取消默认 true；R 完整重置传 false，把断言延后到玩家机关统一清理之后。
## 库存取消不改变库存；已放置机关取消不改变占用表（旧占用从未清除）。失效节点不再解引用，只清理并报告一致性异常。
func cancel_current_drag(should_assert_consistency: bool = true) -> void:
	if _drag_context.is_placed_source() and _dragged_placed_token != null:
		if is_instance_valid(_dragged_placed_token):
			# 拖拽期间保留旧逻辑占用，取消时只恢复正式视觉。
			_dragged_placed_token.set_cell(_drag_context.original_cell)
			_dragged_placed_token.set_world_position(_GridCoordinateRules.cell_to_world(_drag_context.original_cell))
			_dragged_placed_token.set_placed_visible(true)
		elif OS.is_debug_build():
			# 失效节点不得再次解引用；仅报告一致性异常，不静默重建占用或映射。
			push_error("DragFlowController: 取消拖拽时已放置机关节点已失效，未恢复视觉，请检查映射与占用一致性。")
	_clear_drag_preview_only()
	_reset_drag_state()
	if should_assert_consistency:
		_assert_consistency.call()


## 是否存在进行中的拖拽（DragContext.is_active）；预览节点可能因异常被释放，仍只以 DragContext 来源作为状态事实。
func is_dragging() -> bool:
	return _drag_context.is_active()


## 删除当前拖拽预览节点；预览为空时安全返回，不修改正式机关、库存或占用表。
func _clear_drag_preview_only() -> void:
	if _drag_preview_token != null:
		_drag_preview_token.queue_free()
		_drag_preview_token = null


## 清空节点句柄与 DragContext 临时事实；只在预览删除与正式节点状态已处理后调用，避免丢失恢复所需的原始格子信息。
func _reset_drag_state() -> void:
	_drag_preview_token = null
	_dragged_placed_token = null
	_drag_context.clear()


## 目标格是否为合法放置格（INVALID_CELL 永远非法，其余边界/静态/占用判定由 LevelWorldQuery 组合）。
func _is_valid_placement_cell(cell: Vector2i, ignored_mechanism_id: StringName) -> bool:
	if cell == _DragContext.INVALID_CELL:
		return false
	return _level_world_query.is_valid_placement_cell(cell, ignored_mechanism_id)


## 在两个镜面节点间复制朝向（拖动已有镜面时让预览保留当前“/”或“\”）；任一非镜面安全忽略，避免未来未知机关拖拽崩溃。
func _copy_mirror_orientation_if_possible(source_token: Variant, target_token: Variant) -> void:
	if not is_instance_valid(source_token) or not is_instance_valid(target_token):
		return
	if source_token is not _SingleCellMirror or target_token is not _SingleCellMirror:
		return
	var source_mirror: _SingleCellMirror = source_token as _SingleCellMirror
	var target_mirror: _SingleCellMirror = target_token as _SingleCellMirror
	target_mirror.set_orientation(source_mirror.orientation)
