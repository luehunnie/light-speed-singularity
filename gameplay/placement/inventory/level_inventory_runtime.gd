class_name LevelInventoryRuntime
extends RefCounted

## Level Inventory Runtime（AF-03 / P0-5，Guide §15.2）：关卡唯一的 type_id → quantity 多类型数量池。
## 冻结边界：不保存 Stable ID 列表、不保存隐藏实例对象池、不持有节点/占用/Registry；
## 数量事务（Spawn 预留两阶段 + 回还预留两阶段）全部按 type 原子化，任一失败零变更。
## 事务语义与既有单类型 InventoryController 对齐（预留锁容量 → 提交才改 remaining），多类型化为按 type 键控。

const _LevelInventoryEntry: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_entry.gd"
)


## type_id → 单类型数量事实（total / remaining / spawn 预留 / 回还预留）。
class _TypePool:
	var total: int = 0
	var remaining: int = 0
	var reserved_spawn: int = 0
	var reserved_return: int = 0

	func _init(p_total: int) -> void:
		total = maxi(p_total, 0)
		remaining = total


var _pools_by_type_id: Dictionary[StringName, _TypePool] = {}
## 作者声明序（order 升序、同序按 setup 传入序）的 type_id 列表。
var _ordered_type_ids: Array[StringName] = []


## 以关卡库存条目初始化数量池（每关一次）；重复 type_id、非法条目或未预置类型拒绝并返回 false（零变更）。
## [br]重复 setup 先清空旧池再重建；返回是否全部条目合法。
func setup(entries: Array) -> bool:
	var next_pools: Dictionary[StringName, _TypePool] = {}
	var next_ordered: Array[StringName] = []
	var sorted_entries: Array = entries.duplicate()
	sorted_entries.sort_custom(_compare_entries)
	for entry_variant: Variant in sorted_entries:
		if not (entry_variant is _LevelInventoryEntry):
			push_error("LevelInventoryRuntime: 条目非 LevelInventoryEntry，拒绝 setup。")
			return false
		var entry: _LevelInventoryEntry = entry_variant as _LevelInventoryEntry
		if not entry.validate().is_empty():
			push_error("LevelInventoryRuntime: 非法库存条目（%s），拒绝 setup。" % [entry.content_type_id])
			return false
		if next_pools.has(entry.content_type_id):
			push_error("LevelInventoryRuntime: 重复 content_type_id：%s。" % [entry.content_type_id])
			return false
		next_pools[entry.content_type_id] = _TypePool.new(entry.initial_quantity)
		next_ordered.append(entry.content_type_id)
	_pools_by_type_id = next_pools
	_ordered_type_ids = next_ordered
	return true


## 类型是否已登记。
func has_type(content_type_id: StringName) -> bool:
	return _pools_by_type_id.has(content_type_id)


## 已登记类型清单（order 声明序）。
func get_type_ids() -> Array[StringName]:
	return _ordered_type_ids.duplicate()


## 当前剩余可放置数量；未登记类型返回 0（与“登记 0 个”同表现，登记性另由 has_type 区分）。
func get_remaining(content_type_id: StringName) -> int:
	var pool := _pool_or_null(content_type_id)
	return pool.remaining if pool != null else 0


## 总量（setup 后不变）；未登记返回 0。
func get_total(content_type_id: StringName) -> int:
	var pool := _pool_or_null(content_type_id)
	return pool.total if pool != null else 0


## 已锁定的 Spawn 预留数（只读观察口）。
func get_reserved_spawn(content_type_id: StringName) -> int:
	var pool := _pool_or_null(content_type_id)
	return pool.reserved_spawn if pool != null else 0


## 已锁定的回还预留数（只读观察口）。
func get_reserved_return(content_type_id: StringName) -> int:
	var pool := _pool_or_null(content_type_id)
	return pool.reserved_return if pool != null else 0


## 是否可再预留一个 Spawn（Guide §16 Drag Start 预留判据）：remaining - 已锁预留 > 0。
func can_reserve_spawn(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null:
		return false
	return pool.remaining - pool.reserved_spawn > 0


## Spawn 预留第一阶段（Guide §16 “Reserve 1 unit”）：锁定一单位不立即扣 remaining。
## [br]失败（未登记 / 无可预留容量）返回 false 且零变更。
func try_reserve_spawn(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null or not can_reserve_spawn(content_type_id):
		return false
	pool.reserved_spawn += 1
	return true


## Spawn 预留确认（合法 Placement Commit 末步）：把一单位预留转为正式消耗（remaining -= 1）。
## [br]无预留时 push_error 返回 false（remaining 不变）。
func commit_reserved_spawn(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null or pool.reserved_spawn <= 0:
		push_error("LevelInventoryRuntime: 确认 Spawn 预留时不存在预留（%s）。" % [content_type_id])
		return false
	pool.reserved_spawn -= 1
	pool.remaining -= 1
	return true


## 取消 Spawn 预留（Guide §16 取消/非法路径）：释放锁定的单位，remaining 不变。
func cancel_reserved_spawn(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null or pool.reserved_spawn <= 0:
		return false
	pool.reserved_spawn -= 1
	return true


## 回还预留第一阶段（Recover 在不可逆销毁前锁定归还容量）：仅当 remaining + 两类预留 < total 时成功。
func try_reserve_return(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null:
		return false
	if pool.remaining + pool.reserved_spawn + pool.reserved_return >= pool.total:
		return false
	pool.reserved_return += 1
	return true


## 回还预留确认：把锁定容量真正归还 remaining（不超过 total）。
func commit_reserved_return(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null or pool.reserved_return <= 0:
		push_error("LevelInventoryRuntime: 确认回还预留时不存在预留（%s）。" % [content_type_id])
		return false
	pool.reserved_return -= 1
	pool.remaining = mini(pool.remaining + 1, pool.total)
	return true


## 取消回还预留：释放锁定容量，remaining 不变。
func cancel_reserved_return(content_type_id: StringName) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null or pool.reserved_return <= 0:
		return false
	pool.reserved_return -= 1
	return true


## Reset restore（Guide §15.5 / §7 R 语义）：全部类型恢复初始数量并清除所有预留。
func reset_to_initial() -> void:
	for content_type_id: StringName in _pools_by_type_id:
		var pool: _TypePool = _pools_by_type_id[content_type_id]
		pool.remaining = pool.total
		pool.reserved_spawn = 0
		pool.reserved_return = 0


## 一致性标量判断：remaining + spawned_count == total（spawned_count 为该类型场上实例数）。
func is_consistent_with_spawned_count(content_type_id: StringName, spawned_count: int) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null:
		return false
	return pool.remaining + spawned_count == pool.total


## 按残留实例数量校准剩余（部分清理失败后的 R 收尾）；同时清除该类型全部预留。
## [br]返回 spawned_count 是否处于合法范围 [0, total]；越界仍按公式钳制但返回 false 暴露异常。
func reconcile_with_spawned_count(content_type_id: StringName, spawned_count: int) -> bool:
	var pool := _pool_or_null(content_type_id)
	if pool == null:
		return false
	var legal: bool = spawned_count >= 0 and spawned_count <= pool.total
	pool.remaining = clampi(pool.total - maxi(spawned_count, 0), 0, pool.total)
	pool.reserved_spawn = 0
	pool.reserved_return = 0
	return legal


## 全池 detached 只读快照（type_id → {total, remaining, reserved_spawn, reserved_return}）。
func snapshot() -> Dictionary:
	var snapshot_by_type: Dictionary = {}
	for content_type_id: StringName in _pools_by_type_id:
		var pool: _TypePool = _pools_by_type_id[content_type_id]
		snapshot_by_type[content_type_id] = {
			"total": pool.total,
			"remaining": pool.remaining,
			"reserved_spawn": pool.reserved_spawn,
			"reserved_return": pool.reserved_return,
		}
	return snapshot_by_type


## order 升序稳定排序（同序保持传入顺序；Array.sort_custom 为稳定排序）。
static func _compare_entries(a: Variant, b: Variant) -> bool:
	var entry_a: _LevelInventoryEntry = a as _LevelInventoryEntry
	var entry_b: _LevelInventoryEntry = b as _LevelInventoryEntry
	if entry_a == null or entry_b == null:
		return false
	return entry_a.order < entry_b.order


## 取单类型数量池；未登记返回 null。
func _pool_or_null(content_type_id: StringName) -> _TypePool:
	if not _pools_by_type_id.has(content_type_id):
		return null
	return _pools_by_type_id[content_type_id]
