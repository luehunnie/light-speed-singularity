class_name RuntimeSnapshotData
extends RefCounted

## 运行期快照数据公共数据契约。
##
## 职责：
## 保存某一运行时刻的只读事实摘要（时间戳、运行状态、是否完成、发射器、地图边界、墙体格、
## 光路数、库存、已放置机构数、运行期移动次数、水晶状态列表、占用一致性自检结果），
## 并提供只读校验与独立深复制；供后续 RuntimeSnapshot 序列化为 JSON 快照使用。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照数据层（批次 3A 只实现快照数据契约与校验）。
## 本批不实现 runtime_snapshot.gd、JSON.stringify、FileAccess、user://diagnostics/snapshots/ 写入、
## 轮转限制、RuntimeLogger 接线、SelfCheckRunner、DiagnosticsController，也不接入核心循环。
##
## 主要依赖：
## 依赖 CrystalSnapshotState（同批次水晶状态契约）与 SelfCheckResult（批次 1B 自检结果契约），
## 以及 Godot 内建类型（int、StringName、bool、Vector2i、Rect2i、Array[Vector2i]、PackedStringArray）。
## 不依赖场景树、节点、核心循环私有变量、玩法对象或文件系统。
##
## 明确不负责：
## 采集数据（数据由调用方主动提供）、序列化为 JSON、写入文件、轮转、判断关卡是否完成、
## 修复水晶/库存/占用/移动次数、聚合日志。这些属于后续批次或调用方的职责。
##
## 关键边界：
## - 本类只保存调用方主动提供的只读摘要：不接收 Node/Object 后反射字段、不遍历场景树、
##   不直接读取核心循环私有变量、不使用 Dictionary 代替强类型契约、不使用 Variant 逃避已知类型。
## - 构造时必须复制 wall_cells、深复制 crystal_states、复制 occupancy_consistency，
##   不保存调用方的可变引用，避免后续修改原数组/原对象污染快照。
## - validate() 一次返回全部中文错误，不提前返回、不修改数据、不 push_error、不抛异常、
##   不修复状态、不访问文件系统。
## - occupancy_consistency 复用现有 SelfCheckResult，但构造时复制其字段与 details，避免共享可变引用。
## - 本数据契约不在内部判断关卡是否完成；is_completed 仅如实记录调用方提供的事实。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 快照产生时刻的 Unix 毫秒时间戳。
## 由上层调用方传入（通常来自 Time.get_ticks_msec 或系统时间），必须非负。
var timestamp_unix_msec: int

## 快照对应运行状态，使用稳定 StringName，例如 &"EDITING" 或 &"RUNNING"。
## 不得为空；用于在快照中标识采集时的运行状态。
var run_state: StringName

## 快照采集时关卡是否已完成。
## 如实记录调用方提供的事实；本契约不在内部据此判断关卡完成，仅保存布尔值。
var is_completed: bool

## 发射器所在逻辑格坐标。
## 允许任意 Vector2i；仅记录发射器位置事实。
var emitter_cell: Vector2i

## 发射器朝向，使用 Vector2i 表示方向向量。
## 不得为零向量；x/y 分量绝对值均不得超过 1（合法方向为四向或对角八向的单位向量）。
var emitter_direction: Vector2i

## 关卡地图边界，使用逻辑格坐标的整数矩形。
## size.x 与 size.y 均必须大于 0；仅记录边界事实。
var map_bounds: Rect2i

## 墙体所在逻辑格列表。
## 构造时被复制，调用方之后修改原数组不影响本快照；元素为 Vector2i 值语义，无需逐项深复制。
var wall_cells: Array[Vector2i]

## 快照采集时光路数量，必须非负。
## 仅记录事实，不参与光传播判定。
var light_path_count: int

## 快照采集时剩余库存数量，必须非负。
## 仅记录事实，不修改库存。
var inventory_remaining: int

## 快照采集时已放置机构数量，必须非负。
## 仅记录事实，不修改放置状态。
var placed_mechanism_count: int

## 快照采集时运行期移动次数，必须非负。
## 仅记录事实，不扣除或重置移动次数。
var runtime_move_count: int

## 水晶状态列表，元素类型为 CrystalSnapshotState。
## 构造时逐项深复制，调用方之后修改原数组或原水晶对象不影响本快照。
var crystal_states: Array[CrystalSnapshotState]

## 占用一致性自检结果，类型为 SelfCheckResult。
## 构造时复制其字段与 details，不保存调用方的可变引用；不得为 null。
var occupancy_consistency: SelfCheckResult


## 构造一份运行期快照数据。
## [br]p_timestamp_unix_msec 为 Unix 毫秒时间戳，必须非负。
## [br]p_run_state 为运行状态，不得为空。
## [br]p_is_completed 表示关卡是否完成，如实记录。
## [br]p_emitter_cell 为发射器逻辑格坐标。
## [br]p_emitter_direction 为发射器朝向，不得为零且分量绝对值不超过 1。
## [br]p_map_bounds 为地图边界，size 各分量必须大于 0。
## [br]p_wall_cells 为墙体格列表，传入后会被复制。
## [br]p_light_path_count 为光路数，必须非负。
## [br]p_inventory_remaining 为剩余库存，必须非负。
## [br]p_placed_mechanism_count 为已放置机构数，必须非负。
## [br]p_runtime_move_count 为运行期移动次数，必须非负。
## [br]p_crystal_states 为水晶状态列表，传入后逐项深复制。
## [br]p_occupancy_consistency 为占用一致性自检结果，传入后复制其字段与 details；允许 null（validate 会报告）。
## [br]本函数仅赋值字段并完成必要复制，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值或 null 也不抛异常，留给 validate() 一次报告全部问题。
## [br]副作用：复制 wall_cells、深复制 crystal_states、复制 occupancy_consistency，调用方之后修改原数据不影响本快照。
func _init(
		p_timestamp_unix_msec: int,
		p_run_state: StringName,
		p_is_completed: bool,
		p_emitter_cell: Vector2i,
		p_emitter_direction: Vector2i,
		p_map_bounds: Rect2i,
		p_wall_cells: Array[Vector2i],
		p_light_path_count: int,
		p_inventory_remaining: int,
		p_placed_mechanism_count: int,
		p_runtime_move_count: int,
		p_crystal_states: Array[CrystalSnapshotState],
		p_occupancy_consistency: SelfCheckResult
) -> void:
	timestamp_unix_msec = p_timestamp_unix_msec
	run_state = p_run_state
	is_completed = p_is_completed
	emitter_cell = p_emitter_cell
	emitter_direction = p_emitter_direction
	map_bounds = p_map_bounds
	# 复制墙体格数组：Vector2i 为值语义，assign 即独立复制，避免共享调用方可变引用。
	wall_cells.assign(p_wall_cells)
	light_path_count = p_light_path_count
	inventory_remaining = p_inventory_remaining
	placed_mechanism_count = p_placed_mechanism_count
	runtime_move_count = p_runtime_move_count
	# 深复制水晶状态列表：逐项调用 duplicate_state，避免共享调用方原数组与原水晶对象。
	crystal_states = _copy_crystal_states(p_crystal_states)
	# 复制占用一致性自检结果：构造新 SelfCheckResult 并复制其字段与 details，避免共享可变引用。
	occupancy_consistency = _copy_occupancy(p_occupancy_consistency)


## 复制水晶状态列表的私有辅助函数。
## [br]p_source 为源水晶状态列表。
## [br]返回新的 Array[CrystalSnapshotState]：逐项调用 duplicate_state 生成独立副本；
## [br]遇到 null 元素时原样保留 null（不抛异常），交由 validate() 报告，以避免在构造期中断。
## [br]副作用：无；不修改源数组，不访问节点或文件系统。
## [br]失败条件：源元素为 null 时不复制而保留 null，由 validate() 报告。
func _copy_crystal_states(p_source: Array[CrystalSnapshotState]) -> Array[CrystalSnapshotState]:
	var copy: Array[CrystalSnapshotState] = []
	for index: int in range(p_source.size()):
		var source_state: CrystalSnapshotState = p_source[index]
		# null 元素无法复制：原样保留，由 validate() 报告，避免构造期抛异常。
		if source_state == null:
			copy.append(null)
		else:
			copy.append(source_state.duplicate_state())
	return copy


## 复制占用一致性自检结果的私有辅助函数。
## [br]p_source 为源 SelfCheckResult，允许为 null。
## [br]返回新的 SelfCheckResult，其字段与 details 与源相等但独立；
## [br]源为 null 时返回 null（交由 validate() 报告），以避免在构造期中断。
## [br]副作用：无；不修改源对象，不访问节点或文件系统。
## [br]边界条件：SelfCheckResult._init 内部会复制传入的 PackedStringArray details，因此副本与源不共享明细引用。
func _copy_occupancy(p_source: SelfCheckResult) -> SelfCheckResult:
	# 源为 null 时无法复制：返回 null，由 validate() 报告，避免构造期抛异常。
	if p_source == null:
		return null
	return SelfCheckResult.new(
		p_source.check_id,
		p_source.passed,
		p_source.summary,
		p_source.details,
		p_source.duration_usec
	)


## 只读校验当前快照数据的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改数据、不 push_error、不抛异常、不修复状态、不访问文件系统。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]emitter_cell 等坐标字段不限制正负；emitter_direction 必须非零且分量绝对值不超过 1；
## [br]crystal_states 中 null 元素逐一报告；occupancy_consistency 为 null 时报告且不再汇总其子错误。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# 时间戳为负属于非法输入：Unix 毫秒时间戳必须非负。
	if timestamp_unix_msec < 0:
		problems.append("RuntimeSnapshotData：timestamp_unix_msec 为负，必须为非负 Unix 毫秒时间戳。")
	# run_state 为空会导致快照无法标识采集时的运行状态。
	if run_state == &"":
		problems.append("RuntimeSnapshotData：run_state 为空，必须填写运行状态。")
	# 发射器朝向为零向量属于非法方向。
	if emitter_direction == Vector2i.ZERO:
		problems.append("RuntimeSnapshotData：emitter_direction 为零向量，必须为非零方向。")
	# 方向分量绝对值超过 1 不是合法的单位方向（四向或对角八向）。
	if absi(emitter_direction.x) > 1 or absi(emitter_direction.y) > 1:
		problems.append("RuntimeSnapshotData：emitter_direction 分量绝对值超过 1，必须为单位方向向量。")
	# 地图边界尺寸必须为正：宽或高为零/负属于非法边界。
	if map_bounds.size.x <= 0 or map_bounds.size.y <= 0:
		problems.append("RuntimeSnapshotData：map_bounds 尺寸非正，size.x 与 size.y 均必须大于 0。")
	# 各计数必须非负：负值属于非法输入。
	if light_path_count < 0:
		problems.append("RuntimeSnapshotData：light_path_count 为负，必须非负。")
	if inventory_remaining < 0:
		problems.append("RuntimeSnapshotData：inventory_remaining 为负，必须非负。")
	if placed_mechanism_count < 0:
		problems.append("RuntimeSnapshotData：placed_mechanism_count 为负，必须非负。")
	if runtime_move_count < 0:
		problems.append("RuntimeSnapshotData：runtime_move_count 为负，必须非负。")
	# 逐项校验水晶状态：null 元素逐一报告，非空元素汇总其子错误。
	for index: int in range(crystal_states.size()):
		var state: CrystalSnapshotState = crystal_states[index]
		if state == null:
			problems.append("RuntimeSnapshotData：crystal_states 第 %d 项为 null，元素不得为 null。" % [index + 1])
		else:
			# 汇总该水晶状态的子错误，前缀标注来源索引以便定位。
			for sub_problem: String in state.validate():
				problems.append("RuntimeSnapshotData：crystal_states 第 %d 项：%s" % [index + 1, sub_problem])
	# 占用一致性自检结果不能为 null：为 null 时报告且不汇总子错误（无对象可校验）。
	if occupancy_consistency == null:
		problems.append("RuntimeSnapshotData：occupancy_consistency 为 null，必须提供 SelfCheckResult。")
	else:
		# 汇总占用一致性自检结果的子错误，前缀标注来源。
		for sub_problem: String in occupancy_consistency.validate():
			problems.append("RuntimeSnapshotData：occupancy_consistency：%s" % [sub_problem])
	return problems


## 返回当前快照数据的全新独立深副本。
## [br]本函数无参数。
## [br]返回新的 RuntimeSnapshotData，标量与坐标字段相等，wall_cells、crystal_states、
## [br]occupancy_consistency 均为独立深复制；修改副本不影响本对象。
## [br]本函数无副作用：不修改本对象、不 push_error、不抛异常、不访问节点或文件系统。
## [br]边界条件：通过构造函数完成复制，构造函数内部已复制 wall_cells、深复制 crystal_states、复制 occupancy_consistency。
func duplicate_data() -> RuntimeSnapshotData:
	var copy: RuntimeSnapshotData = RuntimeSnapshotData.new(
		timestamp_unix_msec,
		run_state,
		is_completed,
		emitter_cell,
		emitter_direction,
		map_bounds,
		wall_cells,
		light_path_count,
		inventory_remaining,
		placed_mechanism_count,
		runtime_move_count,
		crystal_states,
		occupancy_consistency
	)
	return copy
