class_name FormalObjectRegistry
extends RefCounted

## 正式世界对象索引（AF-01 / P0-2，Guide 8.1）："世界里有哪些正式对象、它们是谁、属于什么类型、在哪里"。
## 统一收纳预置对象与玩家 Spawn 对象，二者对发现层无来源特权（Guide 8.3）。
## 边界（Guide 8.2）：本类是身份/类型/位置索引，不是 Placement/Occupancy 合法性事务；多格足迹属 P0-4 后续 additive。
## 身份（Guide 6/7）：stable_instance_id 是唯一实例身份；节点名、节点路径、网格坐标均不是身份。
## 移动/旋转保 ID；复制/Spawn 新 ID；Recover 原条目失效；Reset 预置回初始格并保 ID、动态实例清除。
## 光域身份不进入本索引；光传播统一消费接线按后续阶段，本批不接既有 Runtime。


## 实例来源域。
const ORIGIN_PREPLACED: StringName = &"preplaced"
const ORIGIN_SPAWNED: StringName = &"spawned"

## 条目快照键（detached 字典，不暴露内部条目引用）。
const _K_STABLE_ID: String = "stable_instance_id"
const _K_TYPE_ID: String = "content_type_id"
const _K_ORIGIN: String = "origin"
const _K_CELL: String = "cell"
const _K_INITIAL_CELL: String = "initial_cell"
const _K_INSTANCE: String = "instance"

## stable_id → 条目字典。
var _entries_by_stable_id: Dictionary[String, Dictionary] = {}
## cell → stable_id（单格索引；多格足迹属 P0-4）。
var _stable_id_by_cell: Dictionary[Vector2i, String] = {}
## 稳定 ID 分配器：仅本类发号，保证会话内唯一。
var _allocator := StableInstanceIdAllocator.new()
## 可选类型索引；提供时注册前校验类型已声明。
var _content_registry: FormalContentRegistry = null


## 构造；可注入 FormalContentRegistry 以启用类型已知性校验。
func _init(content_registry: FormalContentRegistry = null) -> void:
	_content_registry = content_registry


## 注册一个预置对象：显式关卡初始 stable_id（关卡数据持真值）；为空时由分配器补发。
## [br]成功返回 stable_instance_id，失败返回空串且零索引污染。
func register_preplaced(
		content_type_id: StringName,
		cell: Vector2i,
		instance: Variant = null,
		stable_instance_id: String = ""
) -> String:
	var final_id := stable_instance_id
	if final_id.is_empty():
		final_id = _allocator.allocate()
	if not _validate_registration(content_type_id, final_id, cell):
		return ""
	var entry := {
		_K_STABLE_ID: final_id,
		_K_TYPE_ID: content_type_id,
		_K_ORIGIN: ORIGIN_PREPLACED,
		_K_CELL: cell,
		_K_INITIAL_CELL: cell,
		_K_INSTANCE: instance,
	}
	_commit_entry(entry)
	return final_id


## 注册一个玩家 Spawn 对象：总是分配新稳定 ID（复制 / 新 Spawn 均走此语义）。
## [br]成功返回新 stable_instance_id，失败返回空串且零索引污染。
func register_spawn(content_type_id: StringName, cell: Vector2i, instance: Variant = null) -> String:
	var stable_id := _allocator.allocate()
	if not _validate_registration(content_type_id, stable_id, cell):
		return ""
	var entry := {
		_K_STABLE_ID: stable_id,
		_K_TYPE_ID: content_type_id,
		_K_ORIGIN: ORIGIN_SPAWNED,
		_K_CELL: cell,
		_K_INITIAL_CELL: cell,
		_K_INSTANCE: instance,
	}
	_commit_entry(entry)
	return stable_id


## 注销一个实例（Recover 语义）：原条目生命周期结束、原 ID 失效、格子释放。
func unregister(stable_id: String) -> bool:
	if not _entries_by_stable_id.has(stable_id):
		push_error("FormalObjectRegistry: 注销未登记实例：%s" % stable_id)
		return false
	var entry: Dictionary = _entries_by_stable_id[stable_id]
	_stable_id_by_cell.erase(entry[_K_CELL])
	_entries_by_stable_id.erase(stable_id)
	return true


## 移动实例到新格（移动保 ID 语义）；目标格被占或身份未知则拒绝。
func move_object(stable_id: String, new_cell: Vector2i) -> bool:
	if not _entries_by_stable_id.has(stable_id):
		push_error("FormalObjectRegistry: 移动未登记实例：%s" % stable_id)
		return false
	var entry: Dictionary = _entries_by_stable_id[stable_id]
	var old_cell: Vector2i = entry[_K_CELL]
	if old_cell == new_cell:
		return true
	if _stable_id_by_cell.has(new_cell):
		push_error("FormalObjectRegistry: 拒绝移动到已占格 %s（stable_id=%s）。" % [new_cell, stable_id])
		return false
	_stable_id_by_cell.erase(old_cell)
	entry[_K_CELL] = new_cell
	_stable_id_by_cell[new_cell] = stable_id
	return true


## Reset 语义（Guide 7）：清除全部动态实例，预置实例保 ID 并回关卡初始格。
## [br]返回被清除的动态实例数。
func reset_level() -> int:
	var removed_ids: Array[String] = []
	for stable_id: String in _entries_by_stable_id.keys():
		if _entries_by_stable_id[stable_id][_K_ORIGIN] == ORIGIN_SPAWNED:
			removed_ids.append(stable_id)
	for stable_id: String in removed_ids:
		var spawned_entry: Dictionary = _entries_by_stable_id[stable_id]
		_stable_id_by_cell.erase(spawned_entry[_K_CELL])
		_entries_by_stable_id.erase(stable_id)
	for stable_id: String in _entries_by_stable_id.keys():
		var entry: Dictionary = _entries_by_stable_id[stable_id]
		var initial_cell: Vector2i = entry[_K_INITIAL_CELL]
		var current_cell: Vector2i = entry[_K_CELL]
		if current_cell != initial_cell:
			_stable_id_by_cell.erase(current_cell)
			entry[_K_CELL] = initial_cell
			_stable_id_by_cell[initial_cell] = stable_id
	return removed_ids.size()


## 按稳定 ID 取条目快照（detached 字典副本）；未登记返回 null。
func get_object_snapshot(stable_id: String) -> Dictionary:
	if not _entries_by_stable_id.has(stable_id):
		return {}
	var entry: Dictionary = _entries_by_stable_id[stable_id]
	return {
		_K_STABLE_ID: entry[_K_STABLE_ID],
		_K_TYPE_ID: entry[_K_TYPE_ID],
		_K_ORIGIN: entry[_K_ORIGIN],
		_K_CELL: entry[_K_CELL],
		_K_INITIAL_CELL: entry[_K_INITIAL_CELL],
		_K_INSTANCE: entry[_K_INSTANCE],
	}


## 是否存在指定稳定 ID。
func has_object(stable_id: String) -> bool:
	return _entries_by_stable_id.has(stable_id)


## 指定格上实例的稳定 ID；空格返回空串。
func get_stable_id_at(cell: Vector2i) -> String:
	return _stable_id_by_cell.get(cell, "")


## 指定格是否有实例登记。
func has_object_at(cell: Vector2i) -> bool:
	return _stable_id_by_cell.has(cell)


## 指定类型的全部稳定 ID 副本（登记序）。
func get_stable_ids_of_type(content_type_id: StringName) -> Array[String]:
	return _collect_ids_by_predicate(
		func(entry: Dictionary) -> bool:
			return entry[_K_TYPE_ID] == content_type_id
	)


## 按来源域取全部稳定 ID 副本（preplaced / spawned）。
func get_stable_ids_by_origin(origin: StringName) -> Array[String]:
	return _collect_ids_by_predicate(
		func(entry: Dictionary) -> bool:
			return entry[_K_ORIGIN] == origin
	)


## 已登记实例总数。
func get_count() -> int:
	return _entries_by_stable_id.size()


## 注册前统一校验：类型非空（提供索引时须已知）、ID 非空且唯一、格子未占。
func _validate_registration(content_type_id: StringName, stable_id: String, cell: Vector2i) -> bool:
	if content_type_id == &"":
		push_error("FormalObjectRegistry: 拒绝空 content_type_id。")
		return false
	if _content_registry != null and not _content_registry.has_type(content_type_id):
		push_error("FormalObjectRegistry: 拒绝未声明类型：%s" % content_type_id)
		return false
	if stable_id.is_empty():
		push_error("FormalObjectRegistry: 拒绝空 stable_instance_id。")
		return false
	if _entries_by_stable_id.has(stable_id):
		push_error("FormalObjectRegistry: 拒绝重复 stable_instance_id：%s" % stable_id)
		return false
	if _stable_id_by_cell.has(cell):
		push_error("FormalObjectRegistry: 拒绝已占格 %s（stable_id=%s）。" % [cell, _stable_id_by_cell[cell]])
		return false
	return true


## 通过登记校验后落双索引。
func _commit_entry(entry: Dictionary) -> void:
	var stable_id: String = entry[_K_STABLE_ID]
	_entries_by_stable_id[stable_id] = entry
	_stable_id_by_cell[entry[_K_CELL]] = stable_id


## 按谓词收集稳定 ID 副本（登记序）。
func _collect_ids_by_predicate(predicate: Callable) -> Array[String]:
	var ids: Array[String] = []
	for stable_id: String in _entries_by_stable_id.keys():
		if predicate.call(_entries_by_stable_id[stable_id]):
			ids.append(stable_id)
	return ids
