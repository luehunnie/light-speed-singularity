class_name OccupancyRegistry
extends RefCounted

## 核心闭环原型轻量占用表。
## 职责：登记、查询和清除当前关卡中的机关占用格（单格与最小多格契约均支持，D7-R4）。
## 位置：由核心闭环原型关卡控制器持有，为后续镜面、拖拽合法性和运行期移动
## 提供统一的“格子—机关”事实来源。
## 依赖：Vector2i 格子坐标与 StringName 机关唯一 ID。
## 多格边界（D7-R4 最小通用契约）：只按“机关 ID + 绝对格列表”登记事实，不解释
## anchor/方向/footprint 语义（由调用方经对象自身 get_occupied_cells(anchor, orientation)
## 展开）；register_cells/move_cells 为原子多格提交，任一冲突整体拒绝、不写任何数据。
## 不负责：拖拽输入、光传播反射、通关判断、视觉动画、地图边界校验
## （边界由关卡控制器在登记前把关）、Tick 批次提交。


## 格子坐标 → 占用该格的机关 ID；未登记的格子不存在于表中。
## 与 occupied_cells_by_id 互为反向索引，两者必须始终同步。
var mechanism_at: Dictionary[Vector2i, StringName] = {}

## 机关 ID → 该机关占用的格子列表（单格机关长度 1，多格机关长度 ≥ 1）。
## 与 mechanism_at 互为反向索引；任一方变更都必须同步另一方。
## 注：Godot 4.6 不支持嵌套类型集合，故值类型用 Array，实际只存 Array[Vector2i]。
var occupied_cells_by_id: Dictionary[StringName, Array] = {}


## 登记一个单格机关占用。
## [br]mechanism_id 是关卡内唯一机关 ID，cell 是要占用的格子坐标。
## [br]返回 true 表示登记成功；返回 false 表示目标格已被占用，或该 ID 已占用其他格。
## [br]失败时不写入任何数据，保证两个表都不会出现半写入状态。
## [br]成功时同时更新 mechanism_at 和 occupied_cells_by_id，保持双向一致。
func register_single_cell(mechanism_id: StringName, cell: Vector2i) -> bool:
	# 先做全部合法性检查，确认无冲突后才动数据，避免半写入。
	if mechanism_id == &"":
		push_error("OccupancyRegistry: 机关 ID 不能为空。")
		return false
	# 同一格已被其他机关占用 → 拒绝，不覆盖既有占用。
	if mechanism_at.has(cell):
		return false
	# 同一机关未清理旧占用就登记到新位置 → 拒绝，保护原占用不被破坏。
	if occupied_cells_by_id.has(mechanism_id):
		return false

	# 检查全部通过，开始原子更新：先写格子→ID，再写 ID→格子列表。
	mechanism_at[cell] = mechanism_id
	# 用类型化 Array[Vector2i] 存入，值槽虽声明为 Array，实际内容严格为 Vector2i。
	var cells: Array[Vector2i] = [cell]
	occupied_cells_by_id[mechanism_id] = cells
	return true


## 解除指定机关的全部占用。
## [br]mechanism_id 是要解除的机关 ID。
## [br]返回 true 表示该机关存在并已清除；返回 false 表示该 ID 不存在（不报错）。
## [br]清除时同步从 mechanism_at 删除其所有占用格，保证两个表同步。
func unregister(mechanism_id: StringName) -> bool:
	if not occupied_cells_by_id.has(mechanism_id):
		# 不存在的机关直接返回 false，不产生错误也不残留半清理状态。
		return false
	# 反向同步：先按 ID 取出占用格，再逐格从 mechanism_at 清除。
	var cells: Array[Vector2i] = occupied_cells_by_id[mechanism_id]
	for cell: Vector2i in cells:
		mechanism_at.erase(cell)
	occupied_cells_by_id.erase(mechanism_id)
	return true


## 单格机关占用原子迁移：全部校验通过后一次性更新正反向索引，失败不修改任何事实，无需“先注销再恢复”。
## [br]仅负责占用事实的原子更新；地图边界/墙体/水晶/放置权限仍由 PlacementController 与 LevelWorldQuery 把关。
## [br]返回 true 表示迁移成功；任一校验失败返回 false 且内部事实完全不变。
func move_single_cell(mechanism_id: StringName, source_cell: Vector2i, target_cell: Vector2i) -> bool:
	# 校验阶段：全部通过前不触碰任何数据，杜绝半写入或“先注销后恢复”中间态。
	if mechanism_id == &"":
		push_error("OccupancyRegistry: 原子移动机关 ID 不能为空。")
		return false
	if not occupied_cells_by_id.has(mechanism_id):
		push_error("OccupancyRegistry: 原子移动源机关未登记：%s" % [mechanism_id])
		return false
	var cells: Array[Vector2i] = occupied_cells_by_id[mechanism_id]
	if cells.size() != 1:
		push_error("OccupancyRegistry: 原子移动仅支持单格机关，%s 占用 %d 格。" % [mechanism_id, cells.size()])
		return false
	if cells[0] != source_cell:
		push_error("OccupancyRegistry: 源格不属于该机关：%s != %s。" % [source_cell, mechanism_id])
		return false
	if mechanism_at.get(source_cell, &"") != mechanism_id:
		push_error("OccupancyRegistry: 源格正向索引与机关不一致：%s。" % [mechanism_id])
		return false
	if target_cell == source_cell:
		push_error("OccupancyRegistry: 原子移动目标格与源格相同。")
		return false
	if mechanism_at.has(target_cell):
		push_error("OccupancyRegistry: 目标格已被占用：%s。" % [target_cell])
		return false
	# 全部校验通过，一次性原子更新正反向索引。
	mechanism_at.erase(source_cell)
	mechanism_at[target_cell] = mechanism_id
	cells[0] = target_cell
	return true


## 多格机关占用原子登记（D7-R4 最小通用契约）：只按“机关 ID + 绝对格列表”登记事实，不解释 anchor/方向/footprint
## （由调用方经对象自身 get_occupied_cells(anchor, orientation) 展开为绝对格列表后传入）。
## [br]cells 必须非空且内部无重复格；单格机关可继续使用 register_single_cell，列表长度 1 的 register_cells 与其等价。
## [br]空 ID / 空列表 / 列表内重复格属非法输入，push_error 并返回 false；
## 任一格已被其他机关占用、或该 ID 已登记（单格或多格）返回 false 且不写任何数据（整体原子拒绝，无半写入）。
## [br]成功时同时更新 mechanism_at 与 occupied_cells_by_id，保持双向一致。
func register_cells(mechanism_id: StringName, cells: Array[Vector2i]) -> bool:
	# 先做全部合法性检查，确认无冲突后才动数据，避免半写入。
	if mechanism_id == &"":
		push_error("OccupancyRegistry: 多格登记机关 ID 不能为空。")
		return false
	if cells.is_empty():
		push_error("OccupancyRegistry: 多格登记格列表不能为空。")
		return false
	if _has_duplicate_cells(cells):
		push_error("OccupancyRegistry: 多格登记格列表存在重复格。")
		return false
	# 同一机关未清理旧占用就再次登记 → 拒绝，保护原占用不被破坏。
	if occupied_cells_by_id.has(mechanism_id):
		return false
	# 任一格已被其他机关占用 → 拒绝，不覆盖既有占用。
	for cell: Vector2i in cells:
		if mechanism_at.has(cell):
			return false

	# 检查全部通过，开始原子更新：先逐格写格子→ID，再写 ID→格子列表。
	for cell: Vector2i in cells:
		mechanism_at[cell] = mechanism_id
	# 存入副本，避免调用方后续修改原数组影响内部事实。
	occupied_cells_by_id[mechanism_id] = cells.duplicate()
	return true


## 多格机关占用原子迁移（D7-R4 最小通用契约）：支持平移与旋转，源/目标允许部分重叠
## （旋转保持锚点时锚点格同属源与目标，视为自身占用不构成冲突）。
## [br]source_cells 必须与该机关当前占用集合完全一致（顺序无关）；target_cells 必须非空、无重复，
## 且不得与 source_cells 为同一集合（无变化迁移拒绝，与 move_single_cell 同格拒绝语义一致）；
## 任一 target 格被其他机关占用即拒绝。
## [br]任一校验失败返回 false 且内部事实完全不变（整体原子拒绝）；全部通过后一次性更新正反向索引。
func move_cells(
		mechanism_id: StringName,
		source_cells: Array[Vector2i],
		target_cells: Array[Vector2i]
) -> bool:
	# 校验阶段：全部通过前不触碰任何数据，杜绝半写入。
	if mechanism_id == &"":
		push_error("OccupancyRegistry: 多格原子移动机关 ID 不能为空。")
		return false
	if not occupied_cells_by_id.has(mechanism_id):
		push_error("OccupancyRegistry: 多格原子移动源机关未登记：%s" % [mechanism_id])
		return false
	if source_cells.is_empty() or target_cells.is_empty():
		push_error("OccupancyRegistry: 多格原子移动源/目标格列表不能为空。")
		return false
	if _has_duplicate_cells(source_cells) or _has_duplicate_cells(target_cells):
		push_error("OccupancyRegistry: 多格原子移动源/目标格列表存在重复格。")
		return false
	var current_cells: Array[Vector2i] = occupied_cells_by_id[mechanism_id]
	if not _is_same_cell_set(current_cells, source_cells):
		push_error("OccupancyRegistry: 源格列表与机关 %s 当前占用不一致。" % [mechanism_id])
		return false
	for cell: Vector2i in source_cells:
		if mechanism_at.get(cell, &"") != mechanism_id:
			push_error("OccupancyRegistry: 源格正向索引与机关不一致：%s。" % [mechanism_id])
			return false
	if _is_same_cell_set(source_cells, target_cells):
		push_error("OccupancyRegistry: 多格原子移动目标格集合与源格集合相同。")
		return false
	# 目标格占用检查：占用者为其他机关 → 冲突拒绝；占用者为本机关则必属 source（集合一致性已保证），
	# 先整体注销再整体写入即可天然兼容旋转重叠格，无需特判。
	for cell: Vector2i in target_cells:
		var owner_id: StringName = mechanism_at.get(cell, &"")
		if owner_id != &"" and owner_id != mechanism_id:
			push_error("OccupancyRegistry: 目标格已被机关 %s 占用。" % [owner_id])
			return false

	# 全部校验通过，一次性原子更新正反向索引。
	for cell: Vector2i in source_cells:
		mechanism_at.erase(cell)
	for cell: Vector2i in target_cells:
		mechanism_at[cell] = mechanism_id
	occupied_cells_by_id[mechanism_id] = target_cells.duplicate()
	return true


## 判断格列表内是否存在重复格（私有纯判断，不修改输入）。
func _has_duplicate_cells(cells: Array[Vector2i]) -> bool:
	var seen: Dictionary = {}
	for cell: Vector2i in cells:
		if seen.has(cell):
			return true
		seen[cell] = true
	return false


## 判断两个格列表是否为同一集合（顺序无关、大小相等、元素互相包含；私有纯判断，不修改输入）。
func _is_same_cell_set(a: Array[Vector2i], b: Array[Vector2i]) -> bool:
	if a.size() != b.size():
		return false
	for cell: Vector2i in a:
		if not b.has(cell):
			return false
	return true


## 清空全部机关占用。
## [br]同时重置 mechanism_at 和 occupied_cells_by_id，回到初始空状态。
## [br]重复调用安全，不会报错。
func clear() -> void:
	mechanism_at.clear()
	occupied_cells_by_id.clear()


## 查询指定格子被哪个机关占用。
## [br]cell 是要查询的格子坐标。
## [br]返回占用该格的机关 ID；格子未被占用时返回空 StringName（&""）。
## [br]查询不存在的格子不会报错。
func get_mechanism_at(cell: Vector2i) -> StringName:
	if not mechanism_at.has(cell):
		return &""
	return mechanism_at[cell]


## 判断指定格子是否被任意机关占用。
## [br]cell 是要查询的格子坐标。返回 true 表示已占用。
func has_mechanism_at(cell: Vector2i) -> bool:
	return mechanism_at.has(cell)


## 判断指定机关 ID 是否已登记。
## [br]mechanism_id 是要查询的机关 ID。返回 true 表示已登记。
func has_mechanism(mechanism_id: StringName) -> bool:
	return occupied_cells_by_id.has(mechanism_id)


## 查询指定机关占用的全部格子。
## [br]mechanism_id 是要查询的机关 ID。
## [br]返回该机关占用格的副本数组；ID 不存在时返回空数组，不报错。
## [br]返回副本而非内部引用，避免调用方直接改坏内部表。
func get_cells_of(mechanism_id: StringName) -> Array[Vector2i]:
	if not occupied_cells_by_id.has(mechanism_id):
		return []
	return occupied_cells_by_id[mechanism_id].duplicate()


## 自检两个反向索引是否一致。
## [br]用于关卡控制器初始化时确认占用表没有重复登记或残留。
## [br]返回 true 表示 mechanism_at 与 occupied_cells_by_id 完全一致。
## [br]不一致时通过 push_error 报告具体冲突，便于定位。
func is_consistent() -> bool:
	# 正向校验：每个 ID 登记的格子，其反向索引必须指向同一个 ID。
	for mechanism_id: StringName in occupied_cells_by_id:
		var cells: Array[Vector2i] = occupied_cells_by_id[mechanism_id]
		if cells.is_empty():
			push_error("OccupancyRegistry: 机关 %s 没有占用任何格子。" % mechanism_id)
			return false
		for cell: Vector2i in cells:
			if mechanism_at.get(cell, &"") != mechanism_id:
				push_error("OccupancyRegistry: 格子 %s 的反向索引与机关 %s 不一致。" % [cell, mechanism_id])
				return false
	# 反向校验：每个被占用的格子，其机关 ID 必须存在且包含该格。
	for cell: Vector2i in mechanism_at:
		var mechanism_id: StringName = mechanism_at[cell]
		if not occupied_cells_by_id.has(mechanism_id):
			push_error("OccupancyRegistry: 格子 %s 指向不存在的机关 %s。" % [cell, mechanism_id])
			return false
		if not occupied_cells_by_id[mechanism_id].has(cell):
			push_error("OccupancyRegistry: 机关 %s 的占用列表缺少格子 %s。" % [mechanism_id, cell])
			return false
	return true
