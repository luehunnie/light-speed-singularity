extends Node2D

## 第一阶段关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入、发起普通主发射源的最小脉冲光线、
## 用 Vector2i 立即计算直线路径、查询墙体与边界、通知普通独立水晶点亮、
## 判断并保持关卡完成结果、在脉冲结束时只清理光路视觉、在 R 重置时恢复运行状态；
## 持有轻量占用表 OccupancyRegistry，提供“格子—机关”统一查询入口。
## 依赖：OccupancyRegistry（gameplay/phase_1/occupancy_registry.gd）、BasicCrystal 的 activate() / reset_runtime()。
## 不负责：镜面反射、分光、颜色、成就、存档、正式关卡加载、拖拽放置、运行期移动、完整状态机、同时组、顺序组或通用水晶条件系统。
## 光路判定完全基于 Vector2i 格子坐标，不使用 Area2D 碰撞、Tween 或物理射线检测作为核心逻辑。


## 基本参数
const CELL_SIZE: int = 64
const MAX_PROPAGATION_STEPS: int = 128
const PULSE_VISUAL_DURATION_SECONDS: float = 1.0

@export var emitter_cell: Vector2i = Vector2i(1, 3)
@export var emitter_direction: Vector2i = Vector2i.RIGHT
@export var map_bounds: Rect2i = Rect2i(0, 0, 16, 16)
@export var wall_cells: Array[Vector2i] = [Vector2i(5, 3)]

# terrain_layer 保留以满足 plan §3.1 / step 5 的节点树与成员约定；
# 第一阶段不使用 TileSet，cell_to_world 用 CELL_SIZE 常量实现，不依赖 map_to_local。
@onready var terrain_layer: TileMapLayer = $TerrainLayer
@onready var light_path_layer: Node2D = $LightPathLayer
@onready var complete_label: Label = $CanvasLayer/CompleteLabel
@onready var crystals: Array[BasicCrystal] = [$RuntimeObjects/Crystal]

## 轻量机关占用表：格子坐标 ↔ 机关 ID 的双向索引。
## 本阶段只做基础读写与查询入口，传播循环暂不据其改变光路。
# 用 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析。
const _OccupancyRegistry: GDScript = preload("res://gameplay/phase_1/occupancy_registry.gd")
var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()

## 当前是否存在仍在显示窗口内的普通脉冲。
## 用于拒绝重叠 Space 请求，避免同一时间存在多条普通脉冲或多个有效清理流程。
var is_pulse_active: bool = false

## 当前运行是否已经完成关卡。
## 与光路视觉生命周期分离；普通独立水晶和完成结果都保持到 R 重置。
var is_level_completed: bool = false

## 当前脉冲版本号。
## 每次开始脉冲或 R 重置都会递增，用于让旧的异步等待回调失效，避免误清理新脉冲。
var pulse_generation: int = 0


## 初始化第一阶段原型关卡。
## [br]本函数无参数、无返回值。
## [br]副作用：仅在调试构建中执行 OccupancyRegistry 启动期自检；自检结束后会清空占用表，
## 保证运行期仍从空占用表开始，不改变 Space 发射、墙体、水晶、脉冲生命周期或 R 重置逻辑。
## [br]边界条件：发布构建不执行自检，避免把调试断言作为运行期必需流程。
func _ready() -> void:
	if OS.is_debug_build():
		_run_occupancy_registry_self_check()


## 执行 OccupancyRegistry 启动期轻量自检。
## [br]本函数无参数、无返回值，仅由 _ready() 在调试构建中调用。
## [br]副作用：临时写入并清除 debug_probe 占用，用 assert 验证登记、查询、冲突拒绝、解除、清空和一致性；
## 自检结束后强制 clear()，确保占用表无残留。
## [br]边界条件：自检格子刻意远离当前第 3 行光路；任一断言失败表示占用表接入或双向索引已损坏。
func _run_occupancy_registry_self_check() -> void:
	occupancy.clear()
	var debug_id: StringName = &"debug_probe"
	var debug_cell: Vector2i = Vector2i(10, 10)
	# 首次登记应成功，且双向索引同步写入。
	assert(occupancy.register_single_cell(debug_id, debug_cell), "占用表自检：首次登记应成功")
	assert(occupancy.get_mechanism_at(debug_cell) == debug_id, "占用表自检：按格查询应返回已登记 ID")
	assert(occupancy.has_mechanism_at(debug_cell), "占用表自检：has_mechanism_at 应为 true")
	assert(occupancy.get_cells_of(debug_id) == [debug_cell], "占用表自检：按 ID 查询应返回其占用格")
	# 同一格被另一机关重复占用 → 必须拒绝，不覆盖既有占用。
	assert(not occupancy.register_single_cell(&"other_probe", debug_cell), "占用表自检：重复占用同一格应被拒绝")
	# 同一机关未清理就登记到新位置 → 必须拒绝，原占用保持不变。
	assert(not occupancy.register_single_cell(debug_id, Vector2i(11, 11)), "占用表自检：同一 ID 重复登记应被拒绝")
	assert(occupancy.get_mechanism_at(debug_cell) == debug_id, "占用表自检：拒绝后原占用应保持不变")
	# 解除后双向索引同步清理，重复解除不报错。
	assert(occupancy.unregister(debug_id), "占用表自检：解除已登记机关应成功")
	assert(not occupancy.has_mechanism_at(debug_cell), "占用表自检：解除后该格应无占用")
	assert(not occupancy.unregister(debug_id), "占用表自检：重复解除不存在的机关应安全返回 false")
	assert(occupancy.is_consistent(), "占用表自检：两个反向索引应一致")
	# 自检完成，清空占用表，保证运行期从空表开始且无残留。
	occupancy.clear()
	assert(occupancy.mechanism_at.is_empty(), "占用表自检：清空后 mechanism_at 应为空")
	assert(occupancy.is_consistent(), "占用表自检：清空后仍应一致")


## 处理关卡输入动作。
## [br]event 是 Godot 传入的输入事件。
## [br]无返回值；副作用是 fire_light 动作在空闲且未完成时触发一次脉冲，reset_level 动作执行完整运行重置。
## [br]边界条件：脉冲活动中和关卡完成后的 Space 会在 fire_light() 中被忽略；其他按键不触发发射或重置。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fire_light"):
		fire_light()
	elif event.is_action_pressed("reset_level"):
		reset_runtime()


## 发射一次第一阶段最小脉冲光线。
## [br]本函数无参数、无返回值。
## [br]副作用：空闲且关卡未完成时，清理上一轮光路视觉，立即按当前布局计算完整直线路径，
## 立即生成光路视觉、点亮普通独立水晶并判断完成，然后启动约 1 秒的光路视觉保持流程。
## [br]状态变化：开始时设置 is_pulse_active 为 true 并递增 pulse_generation；若全部必需水晶被本次脉冲满足，设置 is_level_completed 为 true。
## [br]失败条件：方向非法时报告错误并不创建脉冲；脉冲活动中或关卡已完成时忽略请求。
## [br]边界条件：遇到地图边界、墙体或 MAX_PROPAGATION_STEPS 上限时停止传播；路径、命中和通关判断均在发射当下完成，不等待 1 秒；普通独立水晶点亮后保持到 R。
func fire_light() -> void:
	if is_level_completed:
		return
	if is_pulse_active:
		return

	var direction: Vector2i = emitter_direction
	if not is_valid_direction(direction):
		push_error("Invalid emitter direction: %s" % [direction])
		return

	_prepare_for_new_pulse()

	# 脉冲开始：只允许一个有效脉冲进入约 1 秒显示窗口。
	is_pulse_active = true
	pulse_generation += 1
	var current_pulse_generation: int = pulse_generation

	# 初始化传播状态。
	var current_cell: Vector2i = emitter_cell
	var steps: int = 0

	# 逐格传播，直到遇到边界、墙体或安全步数上限。
	while steps < MAX_PROPAGATION_STEPS:
		var next_cell: Vector2i = current_cell + direction

		# 边界停止。
		if not map_bounds.has_point(next_cell):
			break

		# 墙体停止。
		if is_cell_blocking_light(next_cell):
			break

		# 机关查询入口（占位）：当前阶段只查询占用表，不据其改变光路。
		# 后续接入镜面时，在此调用 get_mechanism_at(next_cell) 决定反射或交互，
		# 不另写硬编码机关列表，保证占用事实来源唯一。
		# var mechanism_id := get_mechanism_at(next_cell)  # TODO: 镜面任务启用

		# 显示光路并立即点亮普通独立水晶；通关判断不依赖 1 秒等待。
		add_light_visual(next_cell)
		try_activate_crystal_at(next_cell)

		# 更新当前位置。
		current_cell = next_cell
		steps += 1

	# 达到传播步数上限时停止，避免非法方向或未来反射逻辑造成无限循环。
	if steps >= MAX_PROPAGATION_STEPS:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")

	# 通关判断立即完成；完成结果与约 1 秒光路视觉生命周期分离保存。
	update_completion_state()

	_finish_pulse_after_delay(current_pulse_generation)


## 执行下一次脉冲前的光路视觉清理。
## [br]本函数无参数、无返回值。
## [br]副作用：清除旧光路视觉，不改变已经点亮的普通独立水晶。
## [br]状态变化：不改变 is_level_completed、CompleteLabel、pulse_generation、is_pulse_active 或水晶点亮状态。
## [br]边界条件：只作为 Space 发射前的轻量清理，不承担 R 的完整运行重置职责。
func _prepare_for_new_pulse() -> void:
	clear_light_path()


## 等待当前脉冲的视觉保持时间并尝试结束脉冲。
## [br]expected_generation 是发起等待时记录的脉冲版本号。
## [br]无返回值；副作用是在等待约 PULSE_VISUAL_DURATION_SECONDS 后，若版本仍有效则结束当前脉冲。
## [br]失败条件：若 R 重置或新脉冲已递增 pulse_generation，本回调视为过期并直接返回。
## [br]边界条件：该等待只控制光路视觉，不参与路径、墙体、水晶命中、普通独立水晶保持或通关结果计算。
func _finish_pulse_after_delay(expected_generation: int) -> void:
	await get_tree().create_timer(PULSE_VISUAL_DURATION_SECONDS).timeout
	# 过期回调保护：旧脉冲等待结束后不得清理 R 后新发射的脉冲。
	if expected_generation != pulse_generation:
		return
	if not is_pulse_active:
		return
	_finish_current_pulse(expected_generation)


## 结束当前仍有效的普通脉冲。
## [br]expected_generation 是调用方确认的脉冲版本号。
## [br]无返回值；副作用：清除当前光路视觉，并将 is_pulse_active 设为 false。
## [br]状态变化：不清除普通独立水晶，不清除 is_level_completed；水晶点亮状态和 CompleteLabel 都保持到 R 重置。
## [br]失败条件：版本不匹配或当前无活动脉冲时直接返回，避免重复结束或旧回调误清理。
## [br]边界条件：不修改 OccupancyRegistry，不处理同时组、顺序组、移动窗口或完整状态机。
func _finish_current_pulse(expected_generation: int) -> void:
	# 过期回调保护：结束清理前再次确认这是当前有效脉冲。
	if expected_generation != pulse_generation:
		return
	if not is_pulse_active:
		return

	# 脉冲结束：普通光路视觉消失，普通独立水晶继续保持点亮。
	clear_light_path()
	is_pulse_active = false

	# 完成结果保留：路径消失后，已经成立的关卡完成标签继续显示。
	if is_level_completed:
		complete_label.visible = true


## 重置本次原型运行状态。
## [br]本函数无参数、无返回值。
## [br]副作用：取消当前脉冲、使旧等待回调失效、清除当前光路视觉、重置全部普通独立水晶点亮状态，并隐藏完成标签。
## [br]状态变化：将 is_pulse_active 设为 false，is_level_completed 设为 false，并递增 pulse_generation。
## [br]边界条件：不清空玩家布局和占用表；当前阶段没有移动次数、同时组、顺序组或完整 RunStateController 需要恢复。
func reset_runtime() -> void:
	# R取消当前脉冲：递增版本号，使已经挂起的旧等待回调全部失效。
	pulse_generation += 1
	is_pulse_active = false
	is_level_completed = false
	clear_light_path()
	_reset_independent_crystals()
	complete_label.visible = false


## 重置普通独立水晶为未点亮状态。
## [br]本函数无参数、无返回值。
## [br]副作用：对当前 crystals 中的每个 BasicCrystal 调用 reset_runtime()，恢复其半透明未点亮视觉。
## [br]状态变化：只在 R 完整重置中清除普通独立水晶状态；不由普通脉冲结束调用。
## [br]边界条件：当前 BasicCrystal 只作为普通独立水晶使用；本函数不实现同时组、顺序组或通用水晶条件系统。
func _reset_independent_crystals() -> void:
	# R完整重置：普通独立水晶保持到玩家重置时才恢复未点亮。
	for crystal: BasicCrystal in crystals:
		crystal.reset_runtime()


## 清除当前光路视觉节点。
## [br]本函数无参数、无返回值。
## [br]副作用：对 LightPathLayer 下的所有子节点调用 queue_free()，实际释放由 Godot 帧流程完成。
## [br]边界条件：子节点为空时安全无效果；只清理视觉层，不修改水晶、完成状态、墙体或占用表。
func clear_light_path() -> void:
	for child: Node in light_path_layer.get_children():
		child.queue_free()


## 判断传播方向是否合法。
## [br]direction 是要检查的格子方向向量。
## [br]返回 true 表示方向非零且每个分量都在 -1 到 1 之间；返回 false 表示不能用于逐格传播。
## [br]本函数无副作用；边界条件是 Vector2i.ZERO、超过一格的方向和非法斜率都会被拒绝。
func is_valid_direction(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


## 判断指定格子是否阻挡光线。
## [br]cell 是要检查的格子坐标。
## [br]返回 true 表示该格在 wall_cells 中，应停止传播；返回 false 表示当前原型允许通过。
## [br]本函数无副作用；边界条件：只检查静态 wall_cells，不处理可消除墙、机关占用或电控门。
func is_cell_blocking_light(cell: Vector2i) -> bool:
	return wall_cells.has(cell)


## 查询指定格子被哪个机关占用（占用表对外查询入口）。
## [br]cell 是要查询的格子坐标。
## [br]返回占用该格的机关 ID；未被占用时返回空 StringName（&""），不报错。
## [br]本函数无副作用；当前阶段传播循环不据此改变光路，仅提供统一入口供后续镜面等机关使用。
func get_mechanism_at(cell: Vector2i) -> StringName:
	return occupancy.get_mechanism_at(cell)


## 判断指定格子是否被任意机关占用（占用表对外查询入口）。
## [br]cell 是要查询的格子坐标。
## [br]返回 true 表示该格已被机关占用；返回 false 表示未占用。
## [br]本函数无副作用；边界条件：空占用表时始终返回 false。
func has_mechanism_at(cell: Vector2i) -> bool:
	return occupancy.has_mechanism_at(cell)


## 尝试点亮指定格子上的普通独立水晶。
## [br]cell 是当前光线进入的格子坐标。
## [br]无返回值；副作用是在存在坐标匹配的 BasicCrystal 时调用 activate() 改变其点亮状态和视觉。
## [br]边界条件：没有匹配水晶时安全无效果；当前阶段不处理颜色、形式、同时组或顺序组，普通独立水晶保持到 R 重置。
func try_activate_crystal_at(cell: Vector2i) -> void:
	for crystal: BasicCrystal in crystals:
		if crystal.cell == cell:
			crystal.activate()


## 判断所有必需普通独立水晶是否已点亮。
## [br]本函数无参数。
## [br]返回 true 表示 crystals 中全部水晶的 is_activated 都为 true；任一未激活则返回 false。
## [br]本函数无副作用；边界条件：crystals 为空表示关卡未配置必需水晶，会输出明确错误并返回 false，防止误判通关。
func all_required_crystals_activated() -> bool:
	if crystals.is_empty():
		push_error("Phase1Prototype: 当前关卡未配置任何必需水晶，不能判定为完成。")
		return false

	for crystal: BasicCrystal in crystals:
		if not crystal.is_activated:
			return false
	return true


## 根据当前水晶状态更新关卡完成状态和完成标签。
## [br]本函数无参数、无返回值。
## [br]副作用：当全部必需水晶在当前脉冲中已激活时显示 CompleteLabel。
## [br]状态变化：首次满足条件时将 is_level_completed 设为 true；此后不因光路视觉消失而清除完成结果。
## [br]边界条件：普通独立水晶和通关结果都保持到 R；只有 R 重置会清除完成状态和隐藏标签。
func update_completion_state() -> void:
	if is_level_completed:
		complete_label.visible = true
		return

	if all_required_crystals_activated():
		is_level_completed = true
		complete_label.visible = true
	else:
		complete_label.visible = false


## 为指定格子添加一段原型光路视觉。
## [br]cell 是要显示光路的格子坐标。
## [br]无返回值；副作用是创建 ColorRect 并加入 LightPathLayer。
## [br]边界条件：只负责当前原型的静态黄色方块显示；约 1 秒后的清理由脉冲结束流程统一执行。
func add_light_visual(cell: Vector2i) -> void:
	var rect := ColorRect.new()
	rect.color = Color(1.0, 0.95, 0.2, 0.75)
	rect.size = Vector2(CELL_SIZE, CELL_SIZE)
	rect.position = cell_to_world(cell) - rect.size * 0.5
	light_path_layer.add_child(rect)


## 将格子坐标转换为当前原型使用的世界坐标中心点。
## [br]cell 是要转换的格子坐标。
## [br]返回该格中心点的世界坐标；本函数无副作用。
## [br]边界条件：当前阶段使用 CELL_SIZE 常量直接计算，不依赖 TileMapLayer.map_to_local()，因此必须与场景中 64 像素格子对齐。
func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(
		cell.x * CELL_SIZE + CELL_SIZE / 2.0,
		cell.y * CELL_SIZE + CELL_SIZE / 2.0
	)
