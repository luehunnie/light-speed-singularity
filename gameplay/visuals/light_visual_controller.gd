class_name LightVisualController
extends RefCounted

## 普通光线路径视觉控制器（Day 3 D3-B）。
## 完整拥有普通光路视觉节点集合：逐格创建光线片段、cell→世界位置应用、入射方向到四类视觉形态的接线、当前路径清理与重复清理安全。
## 不执行光线传播、不激活水晶、不判断完成、不修改运行状态、不创建计时器、不访问库存/拖拽/放置；show_step 只创建和记录视觉。
## 依赖：LightSegmentView 场景与脚本、LightSegmentVisualProfile 资源、GridCoordinateRules 纯换算；不依赖核心或场景树其他节点。


# 光线路段视觉场景与脚本（preload 引用避开 MCP run_project 不重建全局 class_name 缓存的问题）。
const _LightSegmentViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _LightSegmentViewScene: PackedScene = preload("res://gameplay/visuals/light_segments/light_segment_view.tscn")
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
# cell→世界纯换算共享模块（不加 class_name，preload 引用）。
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
# 默认光线路段视觉资源（四字段全空 → LightSegmentView 静默回退到黄色占位块）。
const _DefaultLightSegmentProfile: Resource = preload("res://assets/visual_profiles/basic_light_segment_visuals.tres")
# 原型光路视觉黄色显示色；调制正式纹理与占位块，不参与 RGB 玩法。
const LIGHT_PATH_COLOR: Color = Color(1.0, 0.95, 0.2, 0.75)


# 视觉父节点：所有片段 add_child 到此。控制器是唯一向该父节点添加光路视觉的所有者，不持有核心引用。
var _visual_parent: Node = null
# 当前已记录的光路片段节点集合（事实来源；清理时先 queue_free 再清空，重复清理安全）。
var _segments: Array[Node] = []
# 当前视觉 Profile（可为空 → 静默回退占位块）。
var _profile: _LightSegmentVisualProfile = null
# 片段统一颜色，同时调制正式纹理 self_modulate 与占位块 color。
var _light_color: Color = LIGHT_PATH_COLOR


## 构造控制器：注入视觉父节点（场景中的 LightPathLayer）。视觉资源与颜色由控制器自持，核心不持有第二套。
func _init(visual_parent: Node) -> void:
	_visual_parent = visual_parent
	_profile = _DefaultLightSegmentProfile as _LightSegmentVisualProfile
	_light_color = LIGHT_PATH_COLOR


## 为指定格子创建并记录一段光路视觉；incoming_direction 仅选择四方向纹理，不参与传播、不激活水晶。
## [br]cell 为光进入的格子（Vector2i 逻辑格）；incoming_direction 为进入该格时的方向，仅用于选择水平/垂直/slash/backslash 纹理。
## [br]返回 true 表示已创建并记录一段视觉；实例化失败时 push_error 并返回 false。
## [br]边界：同一格允许多个片段共存，不做去重或对象池；非法方向或对应纹理为空时静默回退到占位块（与旧 add_light_visual 一致），不输出 warning。
func show_step(cell: Vector2i, incoming_direction: Vector2i) -> bool:
	var view: _LightSegmentViewScript = _LightSegmentViewScene.instantiate()
	if not is_instance_valid(view):
		push_error("LightVisualController: 光线路段实例化失败 @ %s" % [cell])
		return false
	# 冻结算子顺序：实例化 → profile → 方向 → 颜色 → 定位 → add_child；set_* 在 add_child 前调用，
	# 此时 @onready 子节点未就绪，refresh_visual() 安全返回；字段已写入，add_child 触发 _ready() 时由 refresh_visual() 统一应用。
	view.set_profile(_profile)
	view.set_direction(incoming_direction)
	view.set_light_color(_light_color)
	# 根节点局部原点表示光路格中心，由 LightSegmentView 内部 offset 居中。
	view.position = _GridCoordinateRules.cell_to_world(cell)
	_visual_parent.add_child(view)
	_segments.append(view)
	return true


## 清除当前全部光路视觉节点；重复调用安全（_segments 已空时只空遍历）。不修改水晶/完成状态/库存/占用/运行状态。
func clear_path() -> void:
	for segment: Node in _segments:
		if is_instance_valid(segment):
			segment.queue_free()
	_segments.clear()


## 当前已记录的光路片段数（只读快照，供测试与诊断断言）。
func get_segment_count() -> int:
	return _segments.size()


## 取得指定下标的片段节点（只读快照，供测试检视方向/纹理；越界返回 null）。不暴露可写数组。
func get_segment_at(index: int) -> Node:
	if index < 0 or index >= _segments.size():
		return null
	return _segments[index]
