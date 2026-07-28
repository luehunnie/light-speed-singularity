@tool
class_name EmissionPreview
extends Node2D

## 发射器编辑器预览节点（阶段 1 D3B-2）。
## 仅在 Godot 编辑器中显示发射起点、当前方向、光线/光粒路径示意。
## direction 是外部已转换完成的 Vector2i 显示输入，本类不判定其合法性。
## 预览仅为编辑器辅助视觉，不参与玩法判定、不复制传播算法、运行时隐藏。

const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

# ===== 即时显示状态（非关卡配置来源） =====
var _direction: Vector2i = Vector2i.RIGHT
var _particle_style: bool = false
var _preview_enabled: bool = true

# ===== 纯视觉常量（不承担格坐标换算） =====
const _LINE_WIDTH: float = 2.0
const _POINT_RADIUS: float = 5.0
const _ARROW_SIZE: float = 9.0
const _RAY_PREVIEW_CELLS: int = 3
const _PARTICLE_POINT_COUNT: int = 3
const _RAY_COLOR: Color = Color(1.0, 0.92, 0.4, 0.6)
const _PARTICLE_COLOR: Color = Color(0.4, 0.9, 1.0, 0.7)
const _ORIGIN_COLOR: Color = Color(1.0, 1.0, 1.0, 0.85)
const _ARROW_COLOR: Color = Color(1.0, 1.0, 1.0, 0.7)


func _ready() -> void:
	# 入树时同步一次可见性并请求重绘，确保编辑器初始预览正确。
	_sync_editor_visibility()
	queue_redraw()


## 统一入口：写入方向、样式、可见三项显示状态；完全相同则跳过重绘。
func set_preview_state(
		direction: Vector2i,
		particle_style: bool,
		enabled: bool
) -> void:
	if direction == _direction and particle_style == _particle_style and enabled == _preview_enabled:
		return
	_direction = direction
	_particle_style = particle_style
	_preview_enabled = enabled
	_sync_editor_visibility()
	queue_redraw()


func get_preview_direction() -> Vector2i:
	return _direction


func is_particle_style() -> bool:
	return _particle_style


func is_preview_enabled() -> bool:
	return _preview_enabled


## 仅编辑器且开启预览时可见；运行时隐藏，不依赖父节点主动隐藏。
func _sync_editor_visibility() -> void:
	visible = Engine.is_editor_hint() and _preview_enabled


## 相邻格中心之间的局部位移；预览节点位于发射器格中心，绘制起点为本地原点。
func _get_cell_step(dir: Vector2i) -> Vector2:
	return _GridCoordinateRules.cell_to_world(dir) - _GridCoordinateRules.cell_to_world(Vector2i.ZERO)


## 光线样式终点：沿方向三格处。
func _get_ray_end(dir: Vector2i) -> Vector2:
	return _get_cell_step(dir) * float(_RAY_PREVIEW_CELLS)


## 光粒样式三个离散示意点位置（不含起点）。
func _get_particle_points(dir: Vector2i) -> PackedVector2Array:
	var step: Vector2 = _get_cell_step(dir)
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(1, _PARTICLE_POINT_COUNT + 1):
		points.append(step * float(i))
	return points


func _draw() -> void:
	if not visible:
		return
	_draw_origin_marker()
	# ZERO 方向不绘制方向路径，仅保留起点标记。
	if _direction == Vector2i.ZERO:
		return
	_draw_arrow(_get_ray_end(_direction))
	if _particle_style:
		_draw_particle_preview()
	else:
		_draw_ray_preview()


func _draw_origin_marker() -> void:
	draw_circle(Vector2.ZERO, _POINT_RADIUS, _ORIGIN_COLOR)


func _draw_ray_preview() -> void:
	draw_line(Vector2.ZERO, _get_ray_end(_direction), _RAY_COLOR, _LINE_WIDTH)


func _draw_particle_preview() -> void:
	for point: Vector2 in _get_particle_points(_direction):
		draw_circle(point, _POINT_RADIUS, _PARTICLE_COLOR)


func _draw_arrow(end: Vector2) -> void:
	if end.length() == 0.0:
		return
	var forward: Vector2 = end.normalized()
	var base: Vector2 = end - forward * _ARROW_SIZE
	var perp: Vector2 = Vector2(-forward.y, forward.x) * (_ARROW_SIZE * 0.5)
	draw_colored_polygon(
		PackedVector2Array([end, base + perp, base - perp]),
		_ARROW_COLOR
	)
