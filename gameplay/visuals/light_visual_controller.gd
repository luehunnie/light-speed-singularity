class_name LightVisualController
extends RefCounted

## 普通光线路径视觉控制器（Day 3 D3-B；M4-E2 改 per-emission ownership）。
## 完整拥有普通光路视觉节点集合：按 emission_id 分桶逐格创建光线片段、cell→世界位置应用、入射方向到四类视觉形态的接线、
##   per-emission 清理（某 Ray 结束只清自身视觉）与全清（R/reset 才全清），重复清理安全。
## M4-E2 前：_segments[] 单全局 Ray path + clear_path()——新 Ray 清旧 Ray，单发射 completion 清全部。
## M4-E2 起：emission_id → segments[] 视觉 ownership——新 Ray 不清旧 Ray；某 Ray finish 只清自身（clear_emission(id)）；R/reset 才全清（clear_all）；
##   stale generation completion 由 LRC 上游 generation 守卫拦截（emission_id 全局唯一、跨 R 不复用，故 clear_emission(old_id) 在新 epoch 天然 no-op）。
## 不执行光线传播、不激活水晶、不判断完成、不修改运行状态、不创建计时器、不访问库存/拖拽/放置；show_step 只创建和记录视觉。
## 依赖：LightSegmentView 场景与脚本、LightSegmentVisualProfile 资源、GridCoordinateRules 纯换算；不依赖核心或场景树其他节点。
## generation 在本层只是 visual ownership/version metadata（emission 的 epoch 快照），不是 gameplay generation 真值（真值 LRC._runtime_generation）。


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
# emission_id -> 该 emission 的光路片段节点 Array（M4-E2 per-emission ownership；事实来源）。
# clear_emission(id) 只 free 本桶；clear_all 全 free。某 emission 无片段时不占键（show_step 首次时建桶）。
var _emission_segments: Dictionary = {}
# emission_id -> generation metadata（M4-E2；visual ownership/version metadata，非 gameplay 真值）。仅供诊断，不参与清理判定。
var _emission_generation: Dictionary = {}
# 当前所有 emission 的片段总数缓存（get_segment_count 只读诊断；show_step +1、clear_* 归零维护，避免每次遍历求和）。
var _total_segment_count: int = 0
# 当前视觉 Profile（可为空 → 静默回退占位块）。
var _profile: _LightSegmentVisualProfile = null
# 片段统一颜色，同时调制正式纹理 self_modulate 与占位块 color。
var _light_color: Color = LIGHT_PATH_COLOR


## 构造控制器：注入视觉父节点（场景中的 LightPathLayer）。视觉资源与颜色由控制器自持，核心不持有第二套。
## M4-E2：构造签名不变（runtime_validation_gate 等直接 new(parent)）；per-emission 分桶为内部实现，构造后空 ownership。
func _init(visual_parent: Node) -> void:
	_visual_parent = visual_parent
	_profile = _DefaultLightSegmentProfile as _LightSegmentVisualProfile
	_light_color = LIGHT_PATH_COLOR


## 为指定 emission 的某格子创建并记录一段光路视觉（M4-E2 per-emission ownership）。
## [br]emission_id 为本次 Ray 发射的身份（LRC allocate 返回值；新 Ray 不清旧 Ray，各 emission 分桶独立）。
## [br]generation 为本次发射所属 epoch token（仅作 visual version metadata 原样存储，不校验 / 不参与清理判定；真值 LRC._runtime_generation）。
## [br]cell 为光进入的格子（Vector2i 逻辑格）；incoming_direction 为进入该格时的方向，仅用于选择水平/垂直/slash/backslash 纹理。
## [br]返回 true 表示已创建并记录一段视觉；实例化失败时 push_error 并返回 false。
## [br]边界：同一格允许多个片段共存，不做去重或对象池；非法方向或对应纹理为空时静默回退到占位块（与旧 add_light_visual 一致），不输出 warning。
##   不清旧 emission 视觉（新 Ray 不清旧 Ray）；不清同 emission 旧片段（逐 step 累积）。
func show_step(emission_id: int, generation: int, cell: Vector2i, incoming_direction: Vector2i) -> bool:
	var view: _LightSegmentViewScript = _LightSegmentViewScene.instantiate()
	if not is_instance_valid(view):
		push_error("LightVisualController: 光线路段实例化失败 @ emission=%d %s" % [emission_id, cell])
		return false
	# 冻结算子顺序：实例化 → profile → 方向 → 颜色 → 定位 → add_child；set_* 在 add_child 前调用，
	# 此时 @onready 子节点未就绪，refresh_visual() 安全返回；字段已写入，add_child 触发 _ready() 时由 refresh_visual() 统一应用。
	view.set_profile(_profile)
	view.set_direction(incoming_direction)
	view.set_light_color(_light_color)
	# 根节点局部原点表示光路格中心，由 LightSegmentView 内部 offset 居中。
	view.position = _GridCoordinateRules.cell_to_world(cell)
	_visual_parent.add_child(view)
	if not _emission_segments.has(emission_id):
		_emission_segments[emission_id] = []
		_emission_generation[emission_id] = generation
	_emission_segments[emission_id].append(view)
	_total_segment_count += 1
	return true


## 为指定 emission 的反射格创建两段半光束视觉（D7-R5 反射格视觉修复）。
## [br]镜面格（本格进入方向与离开方向不同）不再画贯穿整格的入射段——那会使光束视觉上穿过镜面格远端，
##   且与下一格全段之间留半格断口；改为两段半光束在同一格中心拼出拐角：
##   入射半段（指向 -incoming_direction，覆盖入射边→格中心）+ 出射半段（指向 outgoing_direction，覆盖格中心→出射边）。
## [br]emission_id / generation 语义与 show_step 相同（per-emission ownership；generation 仅作 version metadata 原样存储）。
## [br]cell 为反射格；incoming_direction 为进入该格方向；outgoing_direction 为离开该格方向（均八方向）。
## [br]返回 true 表示两段均已创建并记录；任一实例化失败 push_error 并返回 false（已创建的一段仍归属本 emission，由 clear_* 统一清理）。
## [br]边界：本函数只创建视觉，不判断 cell 是否真有镜面（改向判定由调用方据传播结果做出）；不做去重；不清其它 emission 视觉。
func show_reflection_step(
		emission_id: int,
		generation: int,
		cell: Vector2i,
		incoming_direction: Vector2i,
		outgoing_direction: Vector2i
) -> bool:
	var created: bool = true
	# 入射半段：指向 -incoming（半段几何从格中心画到入射边），与出射半段在格中心相接。
	created = _append_half_segment(
		emission_id, generation, cell, Vector2i(
			-incoming_direction.x, -incoming_direction.y)) and created
	# 出射半段：指向 outgoing（从格中心画到出射边），与下一格全段在共享边中点相接。
	created = _append_half_segment(
		emission_id, generation, cell, outgoing_direction) and created
	return created


## 实例化一段半光束并登记到指定 emission 桶（show_reflection_step 内部共享实现）。
## [br]half_direction 为半段指向（见 LightSegmentView.set_direction_half）；返回是否创建成功。
func _append_half_segment(
		emission_id: int,
		generation: int,
		cell: Vector2i,
		half_direction: Vector2i
) -> bool:
	var view: _LightSegmentViewScript = _LightSegmentViewScene.instantiate()
	if not is_instance_valid(view):
		push_error("LightVisualController: 反射格半段实例化失败 @ emission=%d %s" % [emission_id, cell])
		return false
	# 冻结算子顺序（与 show_step 一致）：实例化 → profile → 半段方向 → 颜色 → 定位 → add_child。
	view.set_profile(_profile)
	view.set_direction_half(half_direction)
	view.set_light_color(_light_color)
	view.position = _GridCoordinateRules.cell_to_world(cell)
	_visual_parent.add_child(view)
	if not _emission_segments.has(emission_id):
		_emission_segments[emission_id] = []
		_emission_generation[emission_id] = generation
	_emission_segments[emission_id].append(view)
	_total_segment_count += 1
	return true


## 清除指定 emission 的全部光路视觉节点（M4-E2 per-emission ownership）；某 Ray finish 只清自身，不影响其它 active emission。
## [br]emission_id 为 allocate 返回值；未登记 / 已清的 emission 安全 no-op（emission_id 全局唯一跨 R 不复用，故 clear_emission(old_id) 在新 epoch 天然 no-op）。
## [br]副作用：free 该 emission 全部片段、erase 本桶与 generation metadata、total_segment_count 扣减。
## [br]边界：不修改水晶/完成状态/库存/占用/运行状态；不清其它 emission 的视觉；幂等。
func clear_emission(emission_id: int) -> void:
	if not _emission_segments.has(emission_id):
		return
	var segments: Array = _emission_segments[emission_id]
	for segment: Node in segments:
		if is_instance_valid(segment):
			segment.queue_free()
	_total_segment_count -= segments.size()
	_emission_segments.erase(emission_id)
	_emission_generation.erase(emission_id)


## 清除全部 emission 的全部光路视觉节点（M4-E2；R/reset 才全清）；重复调用安全（空 ownership 时只空遍历）。
## [br]副作用：free 全部片段、清空 _emission_segments / _emission_generation、total_segment_count 归零。
## [br]边界：不修改水晶/完成状态/库存/占用/运行状态。
func clear_all() -> void:
	for emission_id: Variant in _emission_segments:
		for segment: Node in _emission_segments[emission_id]:
			if is_instance_valid(segment):
				segment.queue_free()
	_emission_segments.clear()
	_emission_generation.clear()
	_total_segment_count = 0


## 当前所有 emission 的光路片段总数（只读快照，供测试与诊断断言；M4-E2：跨全部 emission 求和，单发射下与旧 _segments.size() 等价）。
func get_segment_count() -> int:
	return _total_segment_count


## 指定 emission 的光路片段数（只读诊断 / 测试；未登记返回 0）。
func get_emission_segment_count(emission_id: int) -> int:
	if not _emission_segments.has(emission_id):
		return 0
	return _emission_segments[emission_id].size()


## 取指定 emission 的片段节点数组的只读副本（供测试检视方向/纹理；未登记返回空数组）。不暴露内部可写数组。
func get_segments_for_emission(emission_id: int) -> Array:
	if not _emission_segments.has(emission_id):
		return []
	return _emission_segments[emission_id].duplicate()


## 指定 emission 登记 show_step 时记录的 generation metadata（只读诊断 / 测试；未登记返回 -1）。
## [br]注意：本值为 visual version metadata，非 gameplay generation 真值；真值唯一来源 LRC._runtime_generation。
func get_emission_generation(emission_id: int) -> int:
	if not _emission_generation.has(emission_id):
		return -1
	return int(_emission_generation[emission_id])


## 当前持有片段的 emission 数量（只读诊断 / 测试；每个 emission 至少一段，0 表无 active Ray 视觉）。
func get_emission_count() -> int:
	return _emission_segments.size()
