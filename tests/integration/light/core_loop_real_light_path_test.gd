extends SceneTree

## 真实光路端到端集成回归测试（阶段 1 D3C-3）。
## 实例化真实 core_loop_prototype.tscn，挂入 SceneTree 触发真实 _ready，经公开入口 fire_light()/reset_runtime()
## 触发发射与重置，观察 LightPathLayer 下光路段投影。权威传播算法（逐格推进/边界/墙体/镜面）由
## RayExecutionModule 单测负责，本测试只验证场景配置→FixedEmitter 启动快照→运行编排→视觉投影的端到端接线，
## 不重复算法单测。光路段为 LightPathLayer 直接子节点且 position=cell_to_world(step.cell)，
## 路径格由 global_position 反查、首段方向由首格-发射器格推断，均走公开节点路径。
## 异步边界：脉冲视觉持续生产常量 1.0s，发射后立即断言；释放前等待 >1.0s 让脉冲结束协程在活动控制器上恢复。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
# 略大于生产脉冲视觉持续时间 1.0s，确保异步结束协程在释放前于活动控制器上恢复。
const _PULSE_SETTLE_MS: int = 1150

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _EmissionPreview: GDScript = preload("res://gameplay/mechanisms/emitters/emission_preview.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


## SceneTree 初始化入口：逐用例独立实例化场景，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_default_path(scene)
	await _test_02_moved_emitter(scene)
	await _test_03_eight_directions(scene)
	await _test_04_visual_rotation_isolation(scene)
	await _test_05_preview_isolation(scene)
	await _test_06_reset_clears_path(scene)
	await _test_07_particle_rejection(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _ready。
func _ready_instance(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	root.add_child(node)
	await process_frame
	return node


## 取 LightPathLayer（公开场景角色路径）。
func _lpl(node: Node2D) -> Node2D:
	return node.get_node_or_null("LightPathLayer") as Node2D


## 取 RuntimeObjects/Emitter（公开场景角色路径）。
func _emitter(node: Node2D) -> _EmitterConfigNode:
	return node.get_node_or_null("RuntimeObjects/Emitter") as _EmitterConfigNode


## 由 LightPathLayer 子节点 global_position 反查路径格序列（真实运行结果的视觉投影，非权威传播事实）。
func _path_cells(node: Node2D) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var lpl: Node2D = _lpl(node)
	if lpl == null:
		return cells
	for child: Node in lpl.get_children():
		cells.append(_GridCoordinateRules.world_to_cell((child as Node2D).global_position))
	return cells


## 首段方向 = 首格 - 发射器格（公开几何推断，不读 LightSegmentView._direction 私有字段）。
func _first_direction(node: Node2D, cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var emitter: _EmitterConfigNode = _emitter(node)
	if emitter == null:
		return Vector2i.ZERO
	return cells[0] - emitter.get_cell()


## 释放前等待脉冲视觉持续时间过后异步结束协程在活动控制器上恢复，避免游离实例访问；fired=false 无脉冲直接释放。
func _settle_and_free(node: Node2D, fired: bool) -> void:
	if fired:
		var start_ms: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
			await process_frame
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. 默认真实路径：Emitter(1,3) RIGHT，墙(5,3) 阻挡 → 正式路径 (2,3)(3,3)(4,3)，墙格不进入正式光段。
func _test_01_default_path(scene: PackedScene) -> void:
	const NAME: String = "01_默认真实路径"
	var node: Node2D = await _ready_instance(scene)
	node.fire_light()
	var lpl: Node2D = _lpl(node)
	var cells: Array[Vector2i] = _path_cells(node)
	_check(NAME, lpl != null and lpl.get_child_count() == 3, "正式路径段数期望 3，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	_check(NAME, cells.size() == 3, "路径格数期望 3，实际 %d。" % [cells.size()])
	if _check(NAME, cells.size() == 3, "路径格数不足，无法校验顺序。"):
		_check(NAME, cells[0] == Vector2i(2, 3), "首格期望 (2,3)，实际 %s。" % [cells[0]])
		_check(NAME, cells[1] == Vector2i(3, 3), "次格期望 (3,3)，实际 %s。" % [cells[1]])
		_check(NAME, cells[2] == Vector2i(4, 3), "末格期望 (4,3)，实际 %s。" % [cells[2]])
	_check(NAME, _first_direction(node, cells) == Vector2i.RIGHT, "首段方向期望 RIGHT，实际 %s。" % [_first_direction(node, cells)])
	_check(NAME, not cells.has(Vector2i(5, 3)), "墙格 (5,3) 不应生成正式光段。")
	await _settle_and_free(node, true)


## 2. 入树前移动 Emitter.position：FixedEmitter 启动快照与视觉路径起点一致，旧起点不再使用。
func _test_02_moved_emitter(scene: PackedScene) -> void:
	const NAME: String = "02_移动发射器改变起点"
	const MOVED: Vector2i = Vector2i(1, 6)
	var node: Node2D = scene.instantiate() as Node2D
	var emitter: _EmitterConfigNode = _emitter(node)
	_check(NAME, emitter != null, "入树前 Emitter 缺失。")
	if emitter == null:
		node.free()
		return
	emitter.position = _GridCoordinateRules.cell_to_world(MOVED)
	root.add_child(node)
	await process_frame
	emitter = _emitter(node)
	_check(NAME, emitter != null and emitter.get_cell() == MOVED, "EmitterConfigNode 格期望 %s，实际 %s。" % [MOVED, emitter.get_cell() if emitter != null else Vector2i(-1, -1)])
	# FixedEmitter 启动快照：沿用既有 core_loop_emitter_scene_test 同一私有字段契约判空/校验，未新增公开 API。
	var fe: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fe != null, "_fixed_emitter 应已构造。")
	if fe != null:
		_check(NAME, fe.get_cell() == MOVED, "FixedEmitter 快照格期望 %s，实际 %s。" % [MOVED, fe.get_cell()])
		_check(NAME, fe.get_direction() == Vector2i.RIGHT, "FixedEmitter 快照方向期望 RIGHT，实际 %s。" % [fe.get_direction()])
	node.fire_light()
	var cells: Array[Vector2i] = _path_cells(node)
	if _check(NAME, cells.size() > 0, "移动后应生成路径。"):
		_check(NAME, cells[0] == MOVED + Vector2i.RIGHT, "首格期望 %s，实际 %s。" % [MOVED + Vector2i.RIGHT, cells[0]])
		_check(NAME, cells[0] != Vector2i(2, 3), "不应再使用旧起点 (1,3) 的首格 (2,3)。")
	await _settle_and_free(node, true)


## 3. 八方向配置改变首段：每方向新建实例，Emitter 置安全中心格(8,8)，断言首格=格+方向、首段方向=配置方向。
func _test_03_eight_directions(scene: PackedScene) -> void:
	const NAME: String = "03_八方向首段"
	const SAFE_CELL: Vector2i = Vector2i(8, 8)
	var dirs: Array[int] = [
		_EmitterConfigNode.RayDirection.RIGHT,
		_EmitterConfigNode.RayDirection.DOWN_RIGHT,
		_EmitterConfigNode.RayDirection.DOWN,
		_EmitterConfigNode.RayDirection.DOWN_LEFT,
		_EmitterConfigNode.RayDirection.LEFT,
		_EmitterConfigNode.RayDirection.UP_LEFT,
		_EmitterConfigNode.RayDirection.UP,
		_EmitterConfigNode.RayDirection.UP_RIGHT,
	]
	for dir: int in dirs:
		var node: Node2D = scene.instantiate() as Node2D
		var emitter: _EmitterConfigNode = _emitter(node)
		if emitter == null:
			_check(NAME, false, "方向 %d：Emitter 缺失。" % [dir])
			node.free()
			continue
		emitter.position = _GridCoordinateRules.cell_to_world(SAFE_CELL)
		emitter.ray_default_direction = dir
		root.add_child(node)
		await process_frame
		var vec: Vector2i = _EmitterConfigNode.ray_direction_to_vector(dir)
		node.fire_light()
		var cells: Array[Vector2i] = _path_cells(node)
		var label: String = "方向%d(%s)" % [dir, vec]
		if _check(NAME, cells.size() > 0, "[%s] 应生成首段。" % [label]):
			_check(NAME, cells[0] == SAFE_CELL + vec, "[%s] 首格期望 %s，实际 %s。" % [label, SAFE_CELL + vec, cells[0]])
			_check(NAME, _first_direction(node, cells) == vec, "[%s] 首段方向期望 %s，实际 %s。" % [label, vec, _first_direction(node, cells)])
		await _settle_and_free(node, true)


## 4. 视觉旋转不影响逻辑：RIGHT 配置下人为改 EmitterVisual.rotation，正式首段仍按 RIGHT，逻辑方向只来自配置。
func _test_04_visual_rotation_isolation(scene: PackedScene) -> void:
	const NAME: String = "04_视觉旋转不影响逻辑"
	var node: Node2D = await _ready_instance(scene)
	var visual: Node2D = node.get_node_or_null("RuntimeObjects/Emitter/EmitterVisual") as Node2D
	_check(NAME, visual != null, "EmitterVisual 节点缺失。")
	if visual == null:
		await _settle_and_free(node, false)
		return
	# _ready 已按 RIGHT 把 rotation 置 0；人为改成与 RIGHT 不一致的角度。
	visual.rotation = PI / 2.0
	node.fire_light()
	var cells: Array[Vector2i] = _path_cells(node)
	_check(NAME, _first_direction(node, cells) == Vector2i.RIGHT, "视觉旋转后首段方向仍应 RIGHT，实际 %s。" % [_first_direction(node, cells)])
	if _check(NAME, cells.size() > 0, "应生成路径。"):
		_check(NAME, cells[0] == Vector2i(1, 3) + Vector2i.RIGHT, "首格期望 (2,3)，实际 %s。" % [cells[0]])
	_check(NAME, is_instance_valid(visual) and is_zero_approx(visual.rotation - PI / 2.0), "EmitterVisual.rotation 应保持人为值，未被逻辑回写。")
	await _settle_and_free(node, true)


## 5. EmissionPreview 与正式路径隔离：始终为 Emitter 子节点，不在 LightPathLayer 下，不计入正式路径段。
func _test_05_preview_isolation(scene: PackedScene) -> void:
	const NAME: String = "05_Preview与正式路径隔离"
	var node: Node2D = await _ready_instance(scene)
	var emitter: _EmitterConfigNode = _emitter(node)
	var lpl: Node2D = _lpl(node)
	_check(NAME, emitter != null, "Emitter 缺失。")
	_check(NAME, lpl != null, "LightPathLayer 缺失。")
	if emitter == null or lpl == null:
		await _settle_and_free(node, false)
		return
	var preview: _EmissionPreview = emitter.get_node_or_null("EmissionPreview") as _EmissionPreview
	_check(NAME, preview != null, "EmissionPreview 缺失。")
	if preview == null:
		await _settle_and_free(node, false)
		return
	# 发射前：Preview 为 Emitter 子节点，LightPathLayer 无正式段，Preview 非其子节点。
	_check(NAME, preview.get_parent() == emitter, "EmissionPreview 应为 Emitter 直属子节点。")
	_check(NAME, not lpl.is_ancestor_of(preview), "EmissionPreview 不应在 LightPathLayer 下。")
	_check(NAME, lpl.get_child_count() == 0, "发射前 LightPathLayer 应无正式段，实际 %d。" % [lpl.get_child_count()])
	node.fire_light()
	# 发射后：正式段已生成，Preview 仍非 LightPathLayer 子节点，不计入段数。
	_check(NAME, preview.get_parent() == emitter, "发射后 EmissionPreview 仍应为 Emitter 子节点。")
	_check(NAME, not lpl.is_ancestor_of(preview), "发射后 EmissionPreview 仍不应在 LightPathLayer 下。")
	var preview_under_lpl: bool = false
	for child: Node in lpl.get_children():
		if child == preview:
			preview_under_lpl = true
	_check(NAME, not preview_under_lpl, "EmissionPreview 不应成为 LightPathLayer 子节点。")
	_check(NAME, lpl.get_child_count() == 3, "发射后正式段数期望 3（Preview 不计入），实际 %d。" % [lpl.get_child_count()])
	await _settle_and_free(node, true)


## 6. R 重置清理正式光路：发射后 reset_runtime() 清空 LightPathLayer，发射器配置不破坏，Preview 不受路径清理管理。
func _test_06_reset_clears_path(scene: PackedScene) -> void:
	const NAME: String = "06_R重置清理正式光路"
	var node: Node2D = await _ready_instance(scene)
	var emitter: _EmitterConfigNode = _emitter(node)
	var lpl: Node2D = _lpl(node)
	node.fire_light()
	_check(NAME, lpl != null and lpl.get_child_count() == 3, "发射后正式段数期望 3，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	node.reset_runtime()
	# reset_runtime 同步 queue_free 段并清空记录；泵帧让 queue_free 落地。
	await process_frame
	_check(NAME, lpl != null and lpl.get_child_count() == 0, "R 后 LightPathLayer 正式段应清空，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	if emitter != null:
		_check(NAME, emitter.get_cell() == Vector2i(1, 3), "R 后 Emitter 格应保持 (1,3)，实际 %s。" % [emitter.get_cell()])
		_check(NAME, emitter.get_ray_direction_vector() == Vector2i.RIGHT, "R 后 Emitter 方向应保持 RIGHT。")
		var preview: _EmissionPreview = emitter.get_node_or_null("EmissionPreview") as _EmissionPreview
		_check(NAME, preview != null and preview.get_parent() == emitter, "R 后 EmissionPreview 应仍为 Emitter 子节点，不受路径清理管理。")
	await _settle_and_free(node, true)


## 7. PARTICLE 拒绝保持：default_light_form=PARTICLE 入树初始化，不构造 FixedEmitter/运行期编排，不生成正式路径段，不静默按 RAY 发射。
func _test_07_particle_rejection(scene: PackedScene) -> void:
	const NAME: String = "07_PARTICLE拒绝保持"
	var node: Node2D = scene.instantiate() as Node2D
	var emitter: _EmitterConfigNode = _emitter(node)
	_check(NAME, emitter != null, "入树前 Emitter 缺失。")
	if emitter == null:
		node.free()
		return
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	root.add_child(node)
	await process_frame
	# 沿用既有 core_loop_emitter_scene_test 私有字段判空契约，确认未静默构造 RAY 运行时。
	_check(NAME, node.get("_fixed_emitter") == null, "PARTICLE 不应构造 FixedEmitter。")
	_check(NAME, node.get("_level_runtime_controller") == null, "PARTICLE 不应构造运行期编排控制器。")
	_check(NAME, is_instance_valid(node), "PARTICLE 安全停止后节点应仍有效。")
	var lpl: Node2D = _lpl(node)
	_check(NAME, lpl != null and lpl.get_child_count() == 0, "PARTICLE 不应生成正式路径段，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_and_free(node, false)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表；返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== 核心闭环真实光路端到端集成回归测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
