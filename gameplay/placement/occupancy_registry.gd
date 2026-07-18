class_name OccupancyRegistry
extends RefCounted

## 核心闭环原型轻量占用表。
## 职责：登记、查询和清除当前关卡中的单格机关占用格。
## 位置：由核心闭环原型关卡控制器持有，为后续镜面、拖拽合法性和运行期移动
## 提供统一的“格子—机关”事实来源；当前核心闭环原型只做单格占用的基础读写。
## 依赖：Vector2i 格子坐标与 StringName 机关唯一 ID。
## 不负责：拖拽输入、光传播反射、通关判断、视觉动画、多格机关、
## 地图边界校验（边界由关卡控制器在登记前把关）、Tick 批次提交。


## 格子坐标 → 占用该格的机关 ID；未登记的格子不存在于表中。
## 与 occupied_cells_by_id 互为反向索引，两者必须始终同步。
var mechanism_at: Dictionary[Vector2i, StringName] = {}

## 机关 ID → 该机关占用的格子列表（单格机关长度恒为 1）。
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
