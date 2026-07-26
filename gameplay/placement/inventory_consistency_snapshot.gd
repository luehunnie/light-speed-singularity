class_name InventoryConsistencySnapshot
extends RefCounted

## 库存一致性只读快照（Diagnostics 批次 4B-G2）。
##
## 职责：
## 在不持有任何 Node、Node2D、PlaceableToken、OccupancyRegistry、core_loop、Callable、
## Dictionary、Variant 或场景树对象的前提下，把核心闭环原型 _assert_inventory_consistency()
## 所需的全部“纯数据事实”冻结为一份构造后只读的强类型快照，供 InventoryConsistencyRules
## 做纯规则校验。本类只承载数据与对齐契约自检，不执行任何玩法判断，不访问场景树，
## 不调用 Node 生命周期，不读写文件，不使用时间或随机数，不负责日志、断言或自动修复。
##
## 在当前系统中的位置：
## gameplay/placement 下玩法层共享数据契约；由调用方（未来批次接线）从真实
## placed_tokens_by_id 与 OccupancyRegistry 采集等价事实后构造，再交给
## InventoryConsistencyRules.collect_failures 校验。本类不持有真实玩法对象的引用，
## 因此即使原节点被 queue_free 或占用表被清空，快照内容仍保持稳定，便于离线诊断。
##
## 主要依赖：
## 仅依赖 Godot 内建值类型 int、bool、StringName、Vector2i、Array[T]、PackedInt32Array。
## 不依赖 core_loop_prototype、PlaceableToken、OccupancyRegistry、Diagnostics、场景树或文件系统。
##
## 明确不负责：
## 不检查 is_instance_valid、is_queued_for_deletion 等 Node 生命周期事实（仍由 core_loop 负责）；
## 不检查 OccupancyRegistry 反向多余条目；不检查静态机关；不检查重复 Dictionary key；
## 不新增总库存非负、零总库存等业务规则；不做自动修复；不写日志或文件。
## 这些职责仍由 core_loop_prototype 与后续 Check 模块承担。
##
## 关键边界：
## - 构造时对全部 Array 与 PackedInt32Array 执行 duplicate()，不保存调用方容器引用。
## - 保留顺序、保留重复项，不排序、不去重、不修改输入。
## - 允许全部条目数组为空（零条目启动快照结构合法）。
## - 不因数据错误 assert、push_error 或修复；数据对齐契约由 validate() 在读取前自检。
## - 当 occupancy_cell_count 为 0 时，occupancy_first_cell 可存放 Vector2i.ZERO 占位值；
##   规则只在 count == 1 时比较 first_cell，占位值不作为真实登记格参与比较。


# 三组私有标量事实：库存总数、库存剩余、占用表本体一致性标志。
# 这些字段构造后不再被任何公开接口修改，仅通过只读 getter 暴露。
var _total_count: int = 0
var _remaining_count: int = 0
var _occupancy_consistent: bool = false

# 六组对齐的条目级事实（按下标一一对应）。
# dictionary_ids：placed_tokens_by_id 的登记键（字典登记 ID）。
# token_ids：对应 PlaceableToken.mechanism_id 的快照值。
# token_cells：对应 PlaceableToken.cell 的快照值。
# occupancy_ids_at_token_cells：OccupancyRegistry.get_mechanism_at(token.cell) 的快照值。
# occupancy_cell_counts：OccupancyRegistry.get_cells_of(dictionary_id).size() 的快照值。
# occupancy_first_cells：OccupancyRegistry.get_cells_of(dictionary_id) 首格快照值；
#   当 cell_counts 为 0 时存放 Vector2i.ZERO 占位值，规则不在此情况下比较该格。
var _dictionary_ids: Array[StringName] = []
var _token_ids: Array[StringName] = []
var _token_cells: Array[Vector2i] = []
var _occupancy_ids_at_token_cells: Array[StringName] = []
var _occupancy_cell_counts: PackedInt32Array = PackedInt32Array()
var _occupancy_first_cells: Array[Vector2i] = []


## 构造库存一致性只读快照。
## [br]职责：把调用方采集到的标量事实与六组条目级事实冻结为本实例的私有副本。
## [br]输入：total_count 为库存总数量；remaining_count 为库存剩余数量；
## occupancy_consistent 为 OccupancyRegistry.is_consistent() 的本体一致性标志；
## dictionary_ids/token_ids/token_cells 为每个已放置机关的字典登记 ID、自身 mechanism_id、自身 cell 快照；
## occupancy_ids_at_token_cells 为 token.cell 处查询到的占用表 mechanism_id 快照；
## occupancy_cell_counts 为该登记 ID 在占用表中登记的格子数量快照；
## occupancy_first_cells 为该登记 ID 登记格列表的首格快照（数量为 0 时传 Vector2i.ZERO 占位）。
## [br]返回：无；构造完成后实例字段即为只读副本。
## [br]副作用：对全部 Array 与 PackedInt32Array 执行 duplicate()，生成与调用方容器完全独立的副本；
## 不保存调用方容器引用；不修改任何输入容器；不访问场景树、Node、OccupancyRegistry 或文件。
## [br]失败：本构造函数不判定数据错误，不 assert、不 push_error、不修复；对齐契约由 validate() 读取前自检。
## [br]边界：保留输入顺序与重复项，不排序、不去重；允许全部条目数组为空（零条目结构合法）；
## 调用方在构造后修改原数组或 PackedInt32Array 不会影响本快照内容。
func _init(
		total_count: int,
		remaining_count: int,
		occupancy_consistent: bool,
		dictionary_ids: Array[StringName],
		token_ids: Array[StringName],
		token_cells: Array[Vector2i],
		occupancy_ids_at_token_cells: Array[StringName],
		occupancy_cell_counts: PackedInt32Array,
		occupancy_first_cells: Array[Vector2i]
		) -> void:
	# 标量直接赋值，值类型天然独立于调用方。
	_total_count = total_count
	_remaining_count = remaining_count
	_occupancy_consistent = occupancy_consistent
	# 容器一律 duplicate()，断开与调用方容器的引用关系，保留顺序与重复项。
	_dictionary_ids = dictionary_ids.duplicate()
	_token_ids = token_ids.duplicate()
	_token_cells = token_cells.duplicate()
	_occupancy_ids_at_token_cells = occupancy_ids_at_token_cells.duplicate()
	_occupancy_cell_counts = occupancy_cell_counts.duplicate()
	_occupancy_first_cells = occupancy_first_cells.duplicate()


## 自检六组对齐条目容器的长度是否完全一致。
## [br]职责：在规则读取条目前确认六组容器可按下标一一对应，避免越界。
## [br]输入：无；只读取本实例私有字段。
## [br]返回：PackedStringArray，长度为 0 表示契约有效；非空时每项为一条稳定中文错误详情。
## [br]副作用：无；不修改快照，不访问场景树或外部对象。
## [br]失败：本函数不抛异常；发现长度不一致时如实记录到返回值，不做修复。
## [br]边界：六组容器全为空（零条目）视为契约有效；不检查库存业务结果，只检查结构对齐。
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	# 以 _dictionary_ids 长度为基准，逐个比较其余五组容器长度。
	var reference_length: int = _dictionary_ids.size()
	if _token_ids.size() != reference_length:
		errors.append(
				"快照契约无效：token_ids 长度 %d 与 dictionary_ids 长度 %d 不一致。"
				% [_token_ids.size(), reference_length]
				)
	if _token_cells.size() != reference_length:
		errors.append(
				"快照契约无效：token_cells 长度 %d 与 dictionary_ids 长度 %d 不一致。"
				% [_token_cells.size(), reference_length]
				)
	if _occupancy_ids_at_token_cells.size() != reference_length:
		errors.append(
				"快照契约无效：occupancy_ids_at_token_cells 长度 %d 与 dictionary_ids 长度 %d 不一致。"
				% [_occupancy_ids_at_token_cells.size(), reference_length]
				)
	if _occupancy_cell_counts.size() != reference_length:
		errors.append(
				"快照契约无效：occupancy_cell_counts 长度 %d 与 dictionary_ids 长度 %d 不一致。"
				% [_occupancy_cell_counts.size(), reference_length]
				)
	if _occupancy_first_cells.size() != reference_length:
		errors.append(
				"快照契约无效：occupancy_first_cells 长度 %d 与 dictionary_ids 长度 %d 不一致。"
				% [_occupancy_first_cells.size(), reference_length]
				)
	return errors


## 读取库存总数量。
## [br]职责：只读返回构造时冻结的 total_count。
## [br]输入：无。[br]返回：int 总数量。[br]副作用：无。[br]失败：不会失败。[br]边界：不暴露内部容器。
func get_total_count() -> int:
	return _total_count


## 读取库存剩余数量。
## [br]职责：只读返回构造时冻结的 remaining_count。
## [br]输入：无。[br]返回：int 剩余数量。[br]副作用：无。[br]失败：不会失败。[br]边界：不暴露内部容器。
func get_remaining_count() -> int:
	return _remaining_count


## 读取占用表本体一致性标志。
## [br]职责：只读返回构造时冻结的 occupancy_consistent。
## [br]输入：无。[br]返回：bool 一致性标志。[br]副作用：无。[br]失败：不会失败。[br]边界：不暴露内部容器。
func is_occupancy_consistent() -> bool:
	return _occupancy_consistent


## 读取条目数量。
## [br]职责：只读返回 dictionary_ids 长度，即已放置机关条目数。
## [br]输入：无。[br]返回：int 条目数。[br]副作用：无。[br]失败：不会失败。
## [br]边界：返回值为长度，不返回内部容器引用；调用方应在 validate() 通过后再据此遍历索引。
func get_entry_count() -> int:
	return _dictionary_ids.size()


## 读取指定条目的字典登记 ID。
## [br]职责：只读返回 index 处的 dictionary_id 值副本。
## [br]输入：index 为条目下标。[br]返回：StringName 字典登记 ID。[br]副作用：无。
## [br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用。
func get_dictionary_id(index: int) -> StringName:
	return _dictionary_ids[index]


## 读取指定条目的机关自身 mechanism_id 快照。
## [br]职责：只读返回 index 处的 token_id 值副本。
## [br]输入：index 为条目下标。[br]返回：StringName 机关 mechanism_id 快照。[br]副作用：无。
## [br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用。
func get_token_id(index: int) -> StringName:
	return _token_ids[index]


## 读取指定条目的机关自身 cell 快照。
## [br]职责：只读返回 index 处的 token_cell 值副本。
## [br]输入：index 为条目下标。[br]返回：Vector2i 机关 cell 快照。[br]副作用：无。
## [br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用。
func get_token_cell(index: int) -> Vector2i:
	return _token_cells[index]


## 读取指定条目在 token.cell 处查询到的占用表 mechanism_id 快照。
## [br]职责：只读返回 index 处的 occupancy_id_at_token_cell 值副本。
## [br]输入：index 为条目下标。[br]返回：StringName 占用表查询 ID 快照。[br]副作用：无。
## [br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用。
func get_occupancy_id_at_token_cell(index: int) -> StringName:
	return _occupancy_ids_at_token_cells[index]


## 读取指定条目对应登记 ID 在占用表中的格子数量快照。
## [br]职责：只读返回 index 处的 occupancy_cell_count 值。
## [br]输入：index 为条目下标。[br]返回：int 占用格数量快照。[br]副作用：无。
## [br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用。
func get_occupancy_cell_count(index: int) -> int:
	return _occupancy_cell_counts[index]


## 读取指定条目对应登记 ID 登记格列表的首格快照。
## [br]职责：只读返回 index 处的 occupancy_first_cell 值副本。
## [br]输入：index 为条目下标。[br]返回：Vector2i 首格快照；当 count 为 0 时为 Vector2i.ZERO 占位值。
## [br]副作用：无。[br]失败：index 越界时由 Godot 内建越界检查触发错误，本函数不额外 assert 或 push_error。
## [br]边界：仅在 validate() 通过且 0 <= index < get_entry_count() 时调用；
## 规则只在 occupancy_cell_count == 1 时比较本返回值，不得把 count == 0 的占位值当作真实登记格。
func get_occupancy_first_cell(index: int) -> Vector2i:
	return _occupancy_first_cells[index]
