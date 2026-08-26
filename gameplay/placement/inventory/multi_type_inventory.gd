extends "res://gameplay/placement/inventory_controller.gd"

## 多类型玩家库存门面（AF-10 第三批）：metadata inventory_entries 驱动的每类型独立库存事实所有者。
## 组合复用 InventoryController 冻结标量事务（每类型一个内部栈实例），不复制第二套扣/还/预留算法；
## 以子类身份满足 PlacementController / DragFlowController / LevelRuntimeController 既有单类型注入位
## （类型标注为 inventory_controller.gd 的字段可直接接收本类），旧单类型路径行为不变。
## 消费路由：显式 `*_for(type_id)`（PlacementController 事务用）；旧名 can_consume_one/try_consume_one
## 按 selected_type_id 路由（DragFlow 拿取检查用，选中事实由道具卡 Presenter 在拿取前写入）。
## 归还路由：recycle 两阶段预留经 `*_for(type_id)` 显式带类型；旧名预留路由到 selected_type_id 仅作防御。
## 聚合口径：get_total/get_remaining 返回全类型求和，维持 InventoryConsistencyRules A 规则
## remaining + placed == total 在 Σ 维度成立（每类型亦各自成立）。
## 不负责：metadata 解析（MetadataInventoryReader）、UI 呈现（InventoryCardBar）、类型合法性（Registry）。


## 内部栈脚本（本类基类脚本；构造期经 get_base_script 取得，避免自引用 preload 环）。
var _stack_script: GDScript = null
var _stacks: Dictionary = {}
var _ordered_type_ids: Array[StringName] = []
## 当前选中类型（道具卡 Presenter 写入）；空且无类型时旧名消费接口恒返回 false。
var selected_type_id: StringName = &""
## 已锁定的归还预留所属类型（两阶段事务路由上下文）。
var _pending_return_type: StringName = &""


## 构造多类型库存；entries 为 MetadataInventoryReader.read_ordered_entries 输出形状
## （{content_type_id, initial_quantity, order}），按传入顺序即展示顺序；数量钳非负；重复类型首个为准。
func _init(entries: Array) -> void:
	super(0)
	if _stack_script == null:
		_stack_script = get_script().get_base_script()
	for entry_variant: Variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var type_id: StringName = StringName(str(entry.get("content_type_id", "")))
		if type_id == &"" or _stacks.has(type_id):
			continue
		var quantity: int = maxi(0, int(entry.get("initial_quantity", 0)))
		_stacks[type_id] = _stack_script.new(quantity)
		_ordered_type_ids.append(type_id)
	if not _ordered_type_ids.is_empty():
		selected_type_id = _ordered_type_ids[0]


## 全部类型 ID（展示顺序快照；返回后内部顺序变化不影响快照）。
func get_type_ids() -> Array[StringName]:
	return _ordered_type_ids.duplicate()


## 是否存在指定类型栈。
func has_type(type_id: StringName) -> bool:
	return _stacks.has(type_id)


## 指定类型总量；未知类型返回 0。
func get_total_for(type_id: StringName) -> int:
	var stack: Variant = _stacks.get(type_id, null)
	return stack.get_total() if stack != null else 0


## 指定类型当前剩余；未知类型返回 0。
func get_remaining_for(type_id: StringName) -> int:
	var stack: Variant = _stacks.get(type_id, null)
	return stack.get_remaining() if stack != null else 0


## ===== 显式按类型事务（PlacementController 经 has_method 特征检测使用） =====

## 指定类型是否可再扣除一个。
func can_consume_one_for(type_id: StringName) -> bool:
	var stack: Variant = _stacks.get(type_id, null)
	return stack != null and stack.can_consume_one()


## 指定类型成功放置后扣除一个；未知类型/剩余 0 返回 false 且不变更。
func try_consume_one_for(type_id: StringName) -> bool:
	var stack: Variant = _stacks.get(type_id, null)
	return stack != null and stack.try_consume_one()


## 指定类型回收归还两阶段第一阶段：锁定归还容量；成功时记录预留所属类型。
func try_reserve_return_one_for(type_id: StringName) -> bool:
	var stack: Variant = _stacks.get(type_id, null)
	if stack == null or not stack.try_reserve_return_one():
		return false
	_pending_return_type = type_id
	return true


## 指定类型回收归还两阶段第二阶段：提交预留；类型与锁定时不一致按防御失败处理（不改数量）。
func commit_reserved_return_for(type_id: StringName) -> bool:
	if type_id == &"" or _pending_return_type != type_id:
		push_error("MultiTypeInventory: 提交归还预留的类型与锁定时不一致（%s vs %s）。" % [
			type_id, _pending_return_type])
		return false
	var stack: Variant = _stacks.get(type_id, null)
	if stack == null or not stack.commit_reserved_return():
		return false
	_pending_return_type = &""
	return true


## 取消指定类型的归还预留；类型与锁定时不一致仍取消实际锁定类型并大声报告。
func cancel_reserved_return_for(type_id: StringName) -> bool:
	var locked: StringName = _pending_return_type
	if locked != &"" and locked != type_id:
		push_error("MultiTypeInventory: 取消归还预留的类型与锁定时不一致（%s vs %s），改为取消锁定类型。" % [
			type_id, locked])
		type_id = locked
	var stack: Variant = _stacks.get(type_id, null)
	if stack == null or not stack.cancel_reserved_return():
		return false
	if type_id == _pending_return_type:
		_pending_return_type = &""
	return true


## ===== 旧名单类型注入位兼容（selected 路由 / Σ 聚合） =====

## 旧名消费检查：按 selected_type_id 路由（DragFlow 拿取前置检查；Presenter 拿取前已写入选中）。
func can_consume_one() -> bool:
	return can_consume_one_for(selected_type_id)


## 旧名消费：按 selected_type_id 路由。
func try_consume_one() -> bool:
	return try_consume_one_for(selected_type_id)


## 旧名归还预留（防御路由）：按 selected_type_id 锁定；正式回收路径应使用 try_reserve_return_one_for。
func try_reserve_return_one() -> bool:
	return try_reserve_return_one_for(selected_type_id)


## 旧名归还提交（防御路由）：按 selected_type_id 提交。
func commit_reserved_return() -> bool:
	return commit_reserved_return_for(selected_type_id)


## 旧名归还取消（防御路由）。
func cancel_reserved_return() -> bool:
	return cancel_reserved_return_for(selected_type_id)


## 聚合总量：全部类型栈求和（InventoryConsistencyRules A 规则 Σ 口径）。
func get_total() -> int:
	var total: int = 0
	for type_id: StringName in _ordered_type_ids:
		total += get_total_for(type_id)
	return total


## 聚合剩余：全部类型栈求和。
func get_remaining() -> int:
	var remaining: int = 0
	for type_id: StringName in _ordered_type_ids:
		remaining += get_remaining_for(type_id)
	return remaining


## R 完整重置：全部类型栈恢复满、清除遗留归还预留；selected_type_id 保持不变（选中是 UI 事实）。
func reset_to_total() -> void:
	for type_id: StringName in _ordered_type_ids:
		var stack: Variant = _stacks[type_id]
		stack.reset_to_total()
	_pending_return_type = &""


## 按残留机关数量重置各类型剩余（R 部分清理失败路径）：目标 Σremaining = clamp(Σtotal - placed, 0, Σtotal)；
## 差额按展示顺序从首个栈起贪心扣减/补足（确定性）；每栈经其 reconcile_with_placed_count 写入，
## 同时继承基类语义清除各栈遗留归还预留。
## [br]返回 placed_count 是否处于合法范围 [0, Σtotal]；越界仍按公式钳制但返回 false 暴露异常。
func reconcile_with_placed_count(placed_count: int) -> bool:
	var total_sum: int = get_total()
	var legal: bool = placed_count >= 0 and placed_count <= total_sum
	var target_remaining: int = clampi(total_sum - maxi(placed_count, 0), 0, total_sum)
	var deficit: int = get_remaining() - target_remaining
	for type_id: StringName in _ordered_type_ids:
		if deficit == 0:
			break
		var stack: Variant = _stacks[type_id]
		var current: int = stack.get_remaining()
		var next_remaining: int = current
		if deficit > 0:
			next_remaining = current - mini(deficit, current)
			deficit -= current - next_remaining
		else:
			var headroom: int = maxi(0, stack.get_total() - current)
			var give: int = mini(-deficit, headroom)
			next_remaining = current + give
			deficit += give
		stack.reconcile_with_placed_count(stack.get_total() - next_remaining)
	_pending_return_type = &""
	return legal


## 聚合一致性：Σremaining + placed == Σtotal。
func is_consistent_with_placed_count(placed_count: int) -> bool:
	return get_remaining() + placed_count == get_total()
