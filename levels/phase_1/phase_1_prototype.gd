extends Node2D

## 第一阶段关卡控制器（plan §4.2 / §5 / §6）。
## 职责：读取 fire_light / reset_level 输入、发起发射、清理旧光路、
## 用 Vector2i 计算直线路径、查询墙体与边界、通知水晶激活、判断通关、
## 显示/隐藏「关卡完成」、重置运行状态。
## 不负责：镜面反射、分光、颜色、成就、存档、正式关卡加载。
## 光路判定完全基于 Vector2i 格子坐标，不使用 Area2D 碰撞或射线检测。


## 基本参数
const CELL_SIZE: int = 64
const MAX_PROPAGATION_STEPS: int = 128

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


## 输入处理
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fire_light"):
		fire_light()
	elif event.is_action_pressed("reset_level"):
		reset_runtime()


## 清理历史发射
func fire_light() -> void:
	reset_runtime()

## 初始化传播状态
	var current_cell: Vector2i = emitter_cell
	var direction: Vector2i = emitter_direction
	var steps: int = 0

	if not is_valid_direction(direction):
		push_error("Invalid emitter direction: %s" % [direction])
		return

## 逐格传播
	while steps < MAX_PROPAGATION_STEPS:
		var next_cell: Vector2i = current_cell + direction

## 边界停止
		if not map_bounds.has_point(next_cell):
			break

## 墙体停止
		if is_cell_blocking_light(next_cell):
			break

## 显示光路并激活水晶
		add_light_visual(next_cell)
		try_activate_crystal_at(next_cell)

## 更新当前位置
		current_cell = next_cell
		steps += 1

## 再防一次无限传播(被搞怕了)
	if steps >= MAX_PROPAGATION_STEPS:
		push_warning("Light propagation stopped by MAX_PROPAGATION_STEPS")

## 通关判断更新
	update_completion_state()


## 清理残余逻辑
func reset_runtime() -> void:
	clear_light_path()
	for crystal: BasicCrystal in crystals:
		crystal.reset_runtime()
	complete_label.visible = false


func clear_light_path() -> void:
	for child: Node in light_path_layer.get_children():
		child.queue_free()


func is_valid_direction(direction: Vector2i) -> bool:
	return (
		direction != Vector2i.ZERO
		and abs(direction.x) <= 1
		and abs(direction.y) <= 1
	)


func is_cell_blocking_light(cell: Vector2i) -> bool:
	return wall_cells.has(cell)


func try_activate_crystal_at(cell: Vector2i) -> void:
	for crystal: BasicCrystal in crystals:
		if crystal.cell == cell:
			crystal.activate()


## 通关判断
func all_required_crystals_activated() -> bool:
	for crystal: BasicCrystal in crystals:
		if not crystal.is_activated:
			return false
	return true


func update_completion_state() -> void:
	complete_label.visible = all_required_crystals_activated()


## 光路显示
func add_light_visual(cell: Vector2i) -> void:
	var rect := ColorRect.new()
	rect.color = Color(1.0, 0.95, 0.2, 0.75)
	rect.size = Vector2(CELL_SIZE, CELL_SIZE)
	rect.position = cell_to_world(cell) - rect.size * 0.5
	light_path_layer.add_child(rect)


func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(
		cell.x * CELL_SIZE + CELL_SIZE / 2.0,
		cell.y * CELL_SIZE + CELL_SIZE / 2.0
	)
