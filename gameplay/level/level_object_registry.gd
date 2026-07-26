class_name LevelObjectRegistry
extends RefCounted

## 关卡稳定对象索引所有者（D3-C）：本批只实现水晶范围，按显式 crystal_id 与 cell 双向索引。
## 关卡作者在 BasicCrystal.crystal_id 显式配置稳定 ID；本类不从 Node.name 推导、不随机生成、不为空静默填充，cell 变化时 crystal_id 保持不变。
## 所有权：内部 Dictionary 仅由本类修改，不暴露可写引用；返回 ID 或对象集合时一律返回副本。
## 不负责：删除/移动水晶、RuntimeSnapshot、自动保存、机关注册、Objective 逻辑。


# crystal_id → BasicCrystal（登记顺序保留）。
var _crystals_by_id: Dictionary[StringName, BasicCrystal] = {}
# cell → crystal_id，用于按格反查与拒绝重复 cell。
var _crystal_id_by_cell: Dictionary[Vector2i, StringName] = {}


## 注册一颗水晶；拒绝空 ID、无效实例、重复 ID、重复 cell、同一实例重复登记。失败 push_error 并返回 false，不污染任何索引。
## [br]crystal 取 Variant 而非 BasicCrystal：需在调用边界接纳已释放实例并经 is_instance_valid 拒绝，强类型参数会在进入函数体前即报类型错误。
func register_crystal(
		crystal_id: StringName,
		cell: Vector2i,
		crystal: Variant
) -> bool:
	if crystal_id == &"":
		push_error("LevelObjectRegistry: 拒绝空 crystal_id。")
		return false
	if not is_instance_valid(crystal) or not (crystal is BasicCrystal):
		push_error("LevelObjectRegistry: 拒绝无效水晶实例：%s" % [crystal_id])
		return false
	if _crystals_by_id.has(crystal_id):
		push_error("LevelObjectRegistry: 拒绝重复 crystal_id：%s" % [crystal_id])
		return false
	if _crystal_id_by_cell.has(cell):
		push_error("LevelObjectRegistry: 拒绝重复 cell %s（crystal_id=%s）。" % [cell, crystal_id])
		return false
	var crystal_node: BasicCrystal = crystal as BasicCrystal
	for existing: BasicCrystal in _crystals_by_id.values():
		if existing == crystal_node:
			push_error("LevelObjectRegistry: 拒绝同一水晶实例重复登记：%s" % [crystal_id])
			return false
	_crystals_by_id[crystal_id] = crystal_node
	_crystal_id_by_cell[cell] = crystal_id
	return true


## 按 crystal_id 取水晶；未登记返回 null。
func get_crystal(crystal_id: StringName) -> BasicCrystal:
	if not _crystals_by_id.has(crystal_id):
		return null
	return _crystals_by_id[crystal_id]


## 按 cell 取水晶；未登记返回 null。
func get_crystal_at(cell: Vector2i) -> BasicCrystal:
	if not _crystal_id_by_cell.has(cell):
		return null
	return _crystals_by_id[_crystal_id_by_cell[cell]]


## 是否存在指定 crystal_id。
func has_crystal(crystal_id: StringName) -> bool:
	return _crystals_by_id.has(crystal_id)


## 指定 cell 是否有水晶登记。
func has_crystal_at(cell: Vector2i) -> bool:
	return _crystal_id_by_cell.has(cell)


## 全部 crystal_id 副本（按登记顺序）。
func get_crystal_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for key: Variant in _crystals_by_id.keys():
		ids.append(StringName(key))
	return ids


## 全部水晶副本（按登记顺序）。
func get_all_crystals() -> Array[BasicCrystal]:
	var all: Array[BasicCrystal] = []
	for crystal: BasicCrystal in _crystals_by_id.values():
		all.append(crystal)
	return all


## 已登记水晶数量。
func get_crystal_count() -> int:
	return _crystals_by_id.size()
