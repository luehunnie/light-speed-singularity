extends SceneTree

## S3-05 Objective 运行期接线集成测试（真实场景 Layer A + 驱动器 Layer B + BatchEvent 兼容）。
## Layer A（真实 core_loop_prototype.tscn，入树前注入 objective meta / Emitter 配置，经公开 start_run/fire_light/reset_runtime）：
##   01 Ray 命中条件通过 → 点亮 + 完成标签 + COMPLETED；02 条件不符不点亮 → MOVE_WINDOW；
##   03 无 meta 原型回退（不绑模型，原型全点亮完成）；04 非法 meta 安全回退（reader 拒绝，push_error 属预期输出）；
##   05 Particle 命中条件通过 → 点亮 + COMPLETED；06 Reset 归零（模型/水晶/标签/状态）后可再次完整运行。
## Layer B（真实 RayEmissionDriver._apply_ray_execution_result 正式命中点 + Reader 构造 Sequence 组模型 + 可点亮水晶）：
##   08 顺序组乱序命中（条件过→点亮但组不完成）、按序推进、组完成后统一完成判定。
## 07 BatchEvent emission_id 增量兼容：真实 ParticleScheduler + fake world query；emit_particle 传入的 emission_id
##   同时出现在 MOVE 与 TERMINATE 事件；未显式构造时默认 0（旧构造点兼容）。
## 镜像剥离沿用 core_loop_real_light_path_test 的活体 fixture 约定（保持光路基线不随场景内容漂移）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
# 略大于生产脉冲视觉持续时间 1.0s，确保异步结束协程在释放前于活动控制器上恢复。
const _PULSE_SETTLE_MS: int = 1150
# 等待异步状态翻转（Particle 光粒传播 / 脉冲结束）的墙钟上限。
const _STATE_TIMEOUT_MS: int = 20000
const _GROUP_COUNT: int = 8

const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _MirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _ObjectiveMetaReader: GDScript = preload("res://gameplay/objectives/objective_meta_reader.gd")
const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _RayEmissionDriver: GDScript = preload("res://gameplay/runtime/ray_emission_driver.gd")
const _RayExecutionResult: GDScript = preload("res://gameplay/light/ray_execution_result.gd")
const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _FakeWorldQuery: GDScript = preload("res://tests/unit/particle/fixtures/fake_particle_world_query.gd")
const _VisualViewScene: PackedScene = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn")
const _CrystalProfile: Resource = preload("res://assets/visual_profiles/basic_crystal_visuals.tres")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## Layer B 创建的可点亮水晶实例，统一释放避免泄漏。
var _layer_b_crystals: Array[BasicCrystal] = []


func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_ray_hit_condition_pass(scene)
	await _test_02_condition_mismatch_no_light(scene)
	await _test_03_no_meta_prototype_fallback(scene)
	await _test_04_illegal_meta_safe_fallback(scene)
	await _test_05_particle_hit_condition_pass(scene)
	await _test_06_reset_zeroes_model(scene)
	_test_07_batch_event_emission_id_compat()
	await _test_08_driver_sequence_group_wiring()
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	_cleanup_layer_b()
	quit(0 if _failures.is_empty() else 1)


# ===== Layer A 辅助 =====

## 实例化场景并剥离 RuntimeObjects 内 authored 镜面（活体 fixture 约定，保持光路基线稳定）；返回未入树节点，配置后交 _activate。
func _make_node(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	for child: Node in node.get_node("RuntimeObjects").get_children():
		if child.get_script() == _MirrorScript:
			child.free()
	return node


## 入树并泵一帧触发真实 _ready。
func _activate(node: Node2D) -> void:
	root.add_child(node)
	await process_frame


## 释放前等待脉冲视觉持续时间过后异步结束协程在活动控制器上恢复，避免游离实例访问。
func _settle_and_free(node: Node2D) -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame
	if is_instance_valid(node):
		node.free()
	await process_frame


## 当前运行状态（RunState 枚举值）。
func _run_state(node: Node2D) -> int:
	var controller: Variant = node.get("_run_state_controller")
	return int(controller.get_current_state())


## 轮询等待运行状态到达期望值（墙钟上限内每帧查询）。
func _await_state(node: Node2D, expected: int, timeout_ms: int) -> bool:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		if _run_state(node) == expected:
			return true
		await process_frame
	return _run_state(node) == expected


## 场景固定水晶（公开场景角色路径）。
func _crystal(node: Node2D) -> BasicCrystal:
	return node.get_node_or_null("RuntimeObjects/Crystal") as BasicCrystal


## 完成标签是否可见（公开场景角色路径）。
func _label_visible(node: Node2D) -> bool:
	var label: Label = node.get_node_or_null("CanvasLayer/CompleteLabel") as Label
	return label != null and label.visible


## 入树前注入 RAY 形态条件 meta（crystal_001 仅 RAY 合法命中）。
func _set_ray_only_condition(node: Node2D) -> void:
	node.set_meta("objective_conditions", {"crystal_001": [
		{"condition_type_id": "form_condition", "allowed_forms": [0]},
	]})


# ===== Layer A 用例 =====

## 1. Ray 命中条件通过：Emitter UP_RIGHT，路径 (2,2)(3,1) 命中 crystal_001 → 条件通过点亮 + 完成标签 + COMPLETED。
func _test_01_ray_hit_condition_pass(scene: PackedScene) -> void:
	const NAME: String = "01_Ray命中条件通过"
	var node: Node2D = _make_node(scene)
	_set_ray_only_condition(node)
	(node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode).ray_default_direction = _EmitterConfigNode.RayDirection.UP_RIGHT
	await _activate(node)
	var controller: Variant = node.get("_objective_controller")
	_check(NAME, controller != null and controller.has_objective_model(), "合法 meta 应绑定目标模型。")
	node.start_run()
	node.fire_light()
	var crystal: BasicCrystal = _crystal(node)
	_check(NAME, crystal != null and crystal.is_activated, "条件通过的 Ray 命中应点亮水晶。")
	_check(NAME, _label_visible(node), "全部目标完成后完成标签应立即可见（on_steps_applied 同步刷新）。")
	_check(NAME, _run_state(node) == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "发射后应处于 PULSE_ACTIVE。")
	var completed: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, completed, "脉冲结束后应进入 COMPLETED。")
	_check(NAME, crystal != null and crystal.is_activated, "COMPLETED 后水晶应保持点亮。")
	_check(NAME, _label_visible(node), "COMPLETED 后完成标签应保持可见。")
	await _settle_and_free(node)


## 2. 条件不符不点亮：条件仅 PARTICLE 但发射 RAY → 水晶不亮、无完成标签、结束进 MOVE_WINDOW（非 COMPLETED）。
func _test_02_condition_mismatch_no_light(scene: PackedScene) -> void:
	const NAME: String = "02_条件不符不点亮"
	var node: Node2D = _make_node(scene)
	node.set_meta("objective_conditions", {"crystal_001": [
		{"condition_type_id": "form_condition", "allowed_forms": [1]},
	]})
	(node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode).ray_default_direction = _EmitterConfigNode.RayDirection.UP_RIGHT
	await _activate(node)
	node.start_run()
	node.fire_light()
	var crystal: BasicCrystal = _crystal(node)
	_check(NAME, crystal != null and not crystal.is_activated, "条件不符的命中不得点亮水晶。")
	_check(NAME, not _label_visible(node), "目标未完成不应出现完成标签。")
	var moved: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.MOVE_WINDOW, _STATE_TIMEOUT_MS)
	_check(NAME, moved, "脉冲结束且未完成应进入 MOVE_WINDOW。")
	_check(NAME, _run_state(node) != _RuntimeInteractionTypes.RunState.COMPLETED, "不应误入 COMPLETED。")
	await _settle_and_free(node)


## 3. 无 meta 原型回退：不绑定模型，原型语义（命中即点亮，全点亮完成）。
func _test_03_no_meta_prototype_fallback(scene: PackedScene) -> void:
	const NAME: String = "03_无meta原型回退"
	var node: Node2D = _make_node(scene)
	(node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode).ray_default_direction = _EmitterConfigNode.RayDirection.UP_RIGHT
	await _activate(node)
	var controller: Variant = node.get("_objective_controller")
	_check(NAME, controller != null and not controller.has_objective_model(), "无 meta 不应绑定目标模型。")
	node.start_run()
	node.fire_light()
	var crystal: BasicCrystal = _crystal(node)
	_check(NAME, crystal != null and crystal.is_activated, "原型回退下命中应点亮水晶。")
	_check(NAME, _label_visible(node), "原型回退下全点亮应显示完成标签。")
	var completed: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, completed, "原型回退下应照常 COMPLETED。")
	await _settle_and_free(node)


## 4. 非法 meta 安全回退：条件引用未登记 ghost ID → reader 整体拒绝（push_error 属预期），保持原型语义可完整运行。
func _test_04_illegal_meta_safe_fallback(scene: PackedScene) -> void:
	const NAME: String = "04_非法meta安全回退"
	var node: Node2D = _make_node(scene)
	node.set_meta("objective_conditions", {"ghost": [
		{"condition_type_id": "form_condition", "allowed_forms": [0]},
	]})
	(node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode).ray_default_direction = _EmitterConfigNode.RayDirection.UP_RIGHT
	await _activate(node)
	var controller: Variant = node.get("_objective_controller")
	_check(NAME, controller != null and not controller.has_objective_model(), "非法 meta 应安全回退不绑定模型。")
	node.start_run()
	node.fire_light()
	var crystal: BasicCrystal = _crystal(node)
	_check(NAME, crystal != null and crystal.is_activated, "回退后原型命中应点亮水晶。")
	var completed: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, completed, "回退后应照常 COMPLETED。")
	await _settle_and_free(node)


## 5. Particle 命中条件通过：Emitter PARTICLE UP_RIGHT，光粒经 (2,2) 至 (3,1) 踩中水晶 → 点亮 + 完成标签 + COMPLETED。
func _test_05_particle_hit_condition_pass(scene: PackedScene) -> void:
	const NAME: String = "05_Particle命中条件通过"
	var node: Node2D = _make_node(scene)
	node.set_meta("objective_conditions", {"crystal_001": [
		{"condition_type_id": "form_condition", "allowed_forms": [1]},
	]})
	var emitter: _EmitterConfigNode = node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	emitter.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP_RIGHT
	await _activate(node)
	node.start_run()
	node.fire_light()
	var crystal: BasicCrystal = _crystal(node)
	var lit: bool = false
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _STATE_TIMEOUT_MS:
		if crystal != null and crystal.is_activated:
			lit = true
			break
		await process_frame
	_check(NAME, lit, "光粒踩中水晶且条件通过应点亮（入射向 from_cell→entered_cell 由事件换算）。")
	var completed: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, completed, "光粒终止且全部目标完成后应进入 COMPLETED。")
	_check(NAME, _label_visible(node), "COMPLETED 后完成标签应可见。")
	await _settle_and_free(node)


## 6. Reset 归零：完成后 reset_runtime → 水晶/标签/模型完成事实全部归零、状态回 SETUP，且可再次完整运行。
func _test_06_reset_zeroes_model(scene: PackedScene) -> void:
	const NAME: String = "06_Reset模型归零"
	var node: Node2D = _make_node(scene)
	_set_ray_only_condition(node)
	(node.get_node("RuntimeObjects/Emitter") as _EmitterConfigNode).ray_default_direction = _EmitterConfigNode.RayDirection.UP_RIGHT
	await _activate(node)
	node.start_run()
	node.fire_light()
	var completed: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, completed, "前置：首次运行应 COMPLETED。")
	node.reset_runtime()
	var crystal: BasicCrystal = _crystal(node)
	var controller: Variant = node.get("_objective_controller")
	_check(NAME, crystal != null and not crystal.is_activated, "Reset 后水晶应熄灭。")
	_check(NAME, not _label_visible(node), "Reset 后完成标签应隐藏。")
	_check(NAME, controller != null and not controller.is_completed(), "Reset 后模型完成事实应归零。")
	_check(NAME, _run_state(node) == _RuntimeInteractionTypes.RunState.SETUP, "Reset 后应回 SETUP。")
	_check(NAME, controller != null and controller.has_objective_model(), "Reset 不解绑模型（结构保持，仅运行事实归零）。")
	node.start_run()
	node.fire_light()
	_check(NAME, crystal != null and crystal.is_activated, "Reset 后再次运行命中应重新点亮。")
	var again: bool = await _await_state(node, _RuntimeInteractionTypes.RunState.COMPLETED, _STATE_TIMEOUT_MS)
	_check(NAME, again, "Reset 后应可再次 COMPLETED。")
	await _settle_and_free(node)


# ===== 07 BatchEvent emission_id 兼容 =====

## 7. 真实 ParticleScheduler：emit_particle 传入 emission_id 同时出现在 MOVE 与 TERMINATE 事件；默认构造保持 0（旧构造点兼容）。
func _test_07_batch_event_emission_id_compat() -> void:
	const NAME: String = "07_BatchEvent增量兼容"
	var query: _FakeWorldQuery = _FakeWorldQuery.new()
	query.set_bounds(Rect2i(0, 0, 4, 4))
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(query)
	scheduler.begin_generation(1)
	scheduler.emit_particle(Vector2i(2, 1), Vector2i.RIGHT, 5)
	var events: Array = []
	while not scheduler.is_drained():
		events.append_array(scheduler.advance_one_tick(1))
	var move_events: Array = events.filter(func(ev: Variant) -> bool:
		return ev.outcome == 0)
	var terminate_events: Array = events.filter(func(ev: Variant) -> bool:
		return ev.outcome == 1)
	_check(NAME, not move_events.is_empty(), "应产出至少一个 MOVE 事件。")
	_check(NAME, not terminate_events.is_empty(), "应产出 TERMINATE 事件。")
	for ev: Variant in move_events:
		_check(NAME, ev.emission_id == 5, "MOVE 事件应携带 emit 传入的 emission_id=5。")
	for ev: Variant in terminate_events:
		_check(NAME, ev.emission_id == 5, "TERMINATE 事件应携带 emit 传入的 emission_id=5。")
	var legacy: Variant = _ParticleScheduler.BatchEvent.new()
	_check(NAME, legacy.emission_id == 0, "未显式构造时 emission_id 默认 0（旧构造点兼容）。")


# ===== Layer B 用例 =====

## 8. 顺序组驱动接线：Reader 构造 [ca, cb] Sequence 组模型 → 真实 RayEmissionDriver 命中点应用。
## [br]乱序先命中 cb：条件通过点亮（视觉联动不因组序失败抑制），但组不完成；按序命中 ca 推进；再命中 cb 组锁定完成。
func _test_08_driver_sequence_group_wiring() -> void:
	const NAME: String = "08_顺序组驱动接线"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var crystal_a: BasicCrystal = _make_lit_capable_crystal(&"ca", Vector2i(2, 1))
	var crystal_b: BasicCrystal = _make_lit_capable_crystal(&"cb", Vector2i(2, 3))
	registry.register_crystal(&"ca", Vector2i(2, 1), crystal_a)
	registry.register_crystal(&"cb", Vector2i(2, 3), crystal_b)
	var root: Node2D = Node2D.new()
	root.set_meta("objective_groups", [
		{"group_type": 1, "member_ids": ["ca", "cb"], "required": true, "window_seconds": 10.0},
	])
	var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
	root.free()
	if not _check(NAME, model != null, "Reader 应从 groups meta 构造 Sequence 组模型。"):
		return
	var controller: _ObjectiveController = _ObjectiveController.new(registry)
	controller.set_objective_model(model)
	var driver: _RayEmissionDriver = _RayEmissionDriver.new(
		_FakeVisualRecorder.new(), controller, null, 100, 0.0, Callable(), Callable())
	# 第一发（向下）：先命中 cb（顺序组期望 ca）→ cb 条件通过点亮，组回滚不完成。
	driver.call("_apply_ray_execution_result", _build_down_result(), 1, 1)
	_check(NAME, crystal_b.is_activated, "乱序命中 cb 条件通过应点亮（目标条件与组序判定分离）。")
	_check(NAME, not crystal_a.is_activated, "未命中 ca 不应点亮。")
	_check(NAME, not controller.is_completed(), "乱序命中后顺序组不应完成。")
	# 第二发（向上）：命中 ca（期望成员）→ 推进至期望 cb。
	driver.call("_apply_ray_execution_result", _build_up_result(), 2, 1)
	_check(NAME, crystal_a.is_activated, "按序命中 ca 应点亮。")
	_check(NAME, not controller.is_completed(), "顺序组半程不应完成。")
	# 第三发（再向下）：再命中 cb → 组锁定完成。
	driver.call("_apply_ray_execution_result", _build_down_result(), 3, 1)
	_check(NAME, controller.is_completed(), "按序完成全部成员后顺序组应完成（统一完成判定）。")


## 构造向下传播结果：(2,2) 空格 → (2,3) 命中 cb。
func _build_down_result() -> _RayExecutionResult:
	var result: _RayExecutionResult = _RayExecutionResult.new()
	result.add_step(Vector2i(2, 2), Vector2i.DOWN, false)
	result.add_step(Vector2i(2, 3), Vector2i.DOWN, true)
	return result


## 构造向上传播结果：(2,2) 空格 → (2,1) 命中 ca。
func _build_up_result() -> _RayExecutionResult:
	var result: _RayExecutionResult = _RayExecutionResult.new()
	result.add_step(Vector2i(2, 2), Vector2i.UP, false)
	result.add_step(Vector2i(2, 1), Vector2i.UP, true)
	return result


## 构造可真实点亮的水晶（VisualView 子节点 + 手动 _ready；--script 模式不入树约定同 objective_controller_model_test）。
func _make_lit_capable_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.crystal_id = crystal_id
	crystal.cell = cell
	var view: ObjectVisualView = _VisualViewScene.instantiate()
	view.name = "VisualView"
	view.visual_profile = _CrystalProfile
	view.initial_state_id = &"unlit"
	crystal.add_child(view)
	view._ready()
	crystal._ready()
	_layer_b_crystals.append(crystal)
	return crystal


## 光路视觉替身（只计数，不建真实节点；driver 命中点前照常收到 show_step 调用）。
class _FakeVisualRecorder:
	extends RefCounted

	var show_step_calls: int = 0
	var show_reflection_calls: int = 0

	func show_step(_emission_id: int, _generation: int, _cell: Vector2i, _direction: Vector2i) -> void:
		show_step_calls += 1

	func show_reflection_step(
			_emission_id: int, _generation: int, _cell: Vector2i,
			_incoming: Vector2i, _outgoing: Vector2i) -> void:
		show_reflection_calls += 1


# ===== 汇总 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 释放 Layer B 创建的水晶实例（连带 VisualView 子节点）。
func _cleanup_layer_b() -> void:
	for i: int in range(_layer_b_crystals.size()):
		var crystal: BasicCrystal = _layer_b_crystals[i]
		if is_instance_valid(crystal):
			crystal.free()
	_layer_b_crystals.clear()


func _report() -> void:
	var passed_groups: int = maxi(0, _GROUP_COUNT - _failures.size())
	var passed_checks: int = _checks - _failures.size()
	print("objective_runtime_wiring_test： %d/%d 组通过，%d/%d 断言通过。" % [passed_groups, _GROUP_COUNT, passed_checks, _checks])
	if not _failures.is_empty():
		for failure: String in _failures:
			print("  失败：%s" % [failure])
