extends SceneTree

## core_loop 正式 Start Run UI 集成测试（D7-3 Start Run 正式入口与生命周期集成）。
##
## 实例化真实 core_loop_prototype.tscn，挂入 SceneTree 触发真实 _ready（构造 RunStartView），
## 经公开入口 start_run() / fire_light() / reset_runtime() 驱动，观察 CanvasLayer 下
## StartRunButton / HintLabel / StartRunFeedbackLabel / LightPathLayer 公开节点路径。
##
## 覆盖协作文档 §10「自动测试最低合同 · UI」10 项（11–20）：
##   11 SETUP：Start Run 可见/可用；12 SETUP：提示不再宣称 Space 当前可发射；
##   13 Start Run valid → READY；14 READY：Start Run 不可用、Space 提示可用；
##   15 PULSE：Start Run 不可用、Space 不表现为可重复发射；16 MOVE：Space 提示恢复；
##   17 COMPLETED：Start Run/Space 均不表现为可用；18 invalid：反馈出现且仍 SETUP；
##   19 valid 后旧失败反馈清除；20 R → SETUP → Start Run 重新可用（且 direct fire 被拒绝、重启再 fire 成功）。
##
## 禁止白盒访问私有 _run_state_controller / _run_start_view；UI 状态全部经公开场景节点路径只读观测。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
# 略大于生产脉冲视觉持续时间 1.0s，确保异步结束协程在释放前于活动控制器上恢复。
const _PULSE_SETTLE_MS: int = 1150

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _MirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")


## 入树前固定实例级 fixture（场景是活体作者 fixture，可携带 authored 库存/预置机关）：
## 镜面×3 库存 metadata + 剥离场景 RuntimeObjects 内 authored 镜面，保持本测试运行期 UI 基线不随场景内容漂移。
func _prepare_fixture(node: Node2D) -> void:
	node.set_meta("inventory_entries", [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
	])
	for child: Node in node.get_node("RuntimeObjects").get_children():
		if child.get_script() == _MirrorScript:
			child.free()

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
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
	await _test_01_setup_ui(scene)
	await _test_02_start_run_to_ready_ui(scene)
	await _test_03_pulse_ui(scene)
	await _test_04_move_ui(scene)
	await _test_05_completed_ui(scene)
	await _test_06_invalid_feedback_and_valid_clears(scene)
	await _test_07_reset_restart_and_direct_fire_rejected(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _ready（构造 RunStartView 与运行期编排）。
func _ready_instance(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	_prepare_fixture(node)
	root.add_child(node)
	await process_frame
	return node


## 取「开始运行」按钮（公开场景角色路径 CanvasLayer/StartRunButton）。
func _start_run_button(node: Node2D) -> Button:
	return node.get_node_or_null("CanvasLayer/StartRunButton") as Button


## 取状态提示标签（公开场景角色路径 CanvasLayer/HintLabel）。
func _hint_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/HintLabel") as Label


## 取 invalid 反馈标签（公开场景角色路径 CanvasLayer/StartRunFeedbackLabel）。
func _feedback_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/StartRunFeedbackLabel") as Label


## 取 LightPathLayer（公开场景角色路径）。
func _lpl(node: Node2D) -> Node2D:
	return node.get_node_or_null("LightPathLayer") as Node2D


## 释放前等待脉冲视觉持续时间过后异步结束协程在活动控制器上恢复；fired=false 无脉冲直接释放。
func _settle_and_free(node: Node2D, fired: bool) -> void:
	if fired:
		var start_ms: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
			await process_frame
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. SETUP 初始 UI + direct fire 拒绝（11/12）：Start Run 可见且可用；HintLabel 引导「开始运行」，不再宣称 Space 当前可发射。
##    再调用公开 fire_light() 证明 SETUP direct Space 被正式拒绝：状态仍 SETUP（按钮仍可见可用 + 提示仍引导「开始运行」）、正式路径仍 0 段。
##    拒绝证据全部经公开可观测（RunStartView 只由真实 RunState 驱动，状态被错误切换则按钮隐藏/提示变更）；不访问私有 _run_state_controller。
##    fire_light 返回 void，拒绝由“未发生状态切换 + 空光段”体现，不靠返回值。
func _test_01_setup_ui(scene: PackedScene) -> void:
	const NAME: String = "11/12_SETUP初始UI与directFire拒绝"
	var node: Node2D = await _ready_instance(scene)
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	var feedback: Label = _feedback_label(node)
	_check(NAME, button != null, "StartRunButton 应已由 RunStartView 创建。")
	_check(NAME, hint != null, "HintLabel 应存在。")
	_check(NAME, feedback != null, "StartRunFeedbackLabel 应已由 RunStartView 创建。")
	if button != null:
		_check(NAME, button.visible, "SETUP 下「开始运行」按钮应可见。")
		_check(NAME, not button.disabled, "SETUP 下「开始运行」按钮应可用。")
	if hint != null:
		_check(NAME, hint.text.find("开始运行") != -1, "SETUP 提示应引导点击「开始运行」，实际：%s。" % [hint.text])
		_check(NAME, hint.text.find("Space：发射") == -1, "SETUP 提示不应宣称 Space 当前可发射，实际：%s。" % [hint.text])
	if feedback != null:
		_check(NAME, not feedback.visible, "SETUP 初始不应显示 invalid 反馈。")
	# SETUP direct Space 正式拒绝：调用公开 fire_light()，状态仍 SETUP、正式路径仍空。
	# RunStartView 只由真实 RunState 驱动，故按钮/提示未变即状态未切换；LightPathLayer 仍 0 段即未执行发射。
	var lpl: Node2D = _lpl(node)
	node.fire_light()
	if button != null:
		_check(NAME, button.visible and not button.disabled, "SETUP direct fire 后按钮应仍可见可用（状态仍 SETUP）。")
	if hint != null:
		_check(NAME, hint.text.find("开始运行") != -1, "SETUP direct fire 后提示应仍引导「开始运行」（状态仍 SETUP），实际：%s。" % [hint.text])
		_check(NAME, hint.text.find("Space：发射") == -1, "SETUP direct fire 后提示不应变为 Space 可发射，实际：%s。" % [hint.text])
	_check(NAME, lpl != null and lpl.get_child_count() == 0, "SETUP direct fire 应被拒绝，正式光段应仍为 0，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_and_free(node, false)


## 2. 真实按钮事件路径 → READY（13/14）：从初始 SETUP 直接触发「开始运行」按钮 pressed，经正式回调链
##    _on_start_run_pressed → start_run() → request_begin_runtime → READY_TO_FIRE；按钮隐藏、提示恢复 Space、旧反馈清除。
##    不先手工 node.start_run()、不白盒私有状态；确认按钮事件经正式 Start Run 链进入 READY，且按钮本身不发射（LightPathLayer 仍空）。
func _test_02_start_run_to_ready_ui(scene: PackedScene) -> void:
	const NAME: String = "13/14_按钮pressed→READY"
	var node: Node2D = await _ready_instance(scene)
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	var feedback: Label = _feedback_label(node)
	var lpl: Node2D = _lpl(node)
	if button == null:
		_check(NAME, false, "StartRunButton 应存在以测试真实按钮事件路径。")
		await _settle_and_free(node, false)
		return
	# 前置 SETUP：按钮可见可用。
	_check(NAME, button.visible and not button.disabled, "前置 SETUP 按钮应可见可用。")
	# 真实按钮事件：玩家点击「开始运行」→ pressed 信号 → _on_start_run_pressed → start_run() → request_begin_runtime → READY。
	button.pressed.emit()
	# 正式 Start Run 链进入 READY：按钮隐藏、提示恢复 Space、旧反馈清除。
	_check(NAME, not button.visible, "按钮 pressed 后应进入 READY，按钮应隐藏。")
	if hint != null:
		_check(NAME, hint.text.find("Space：发射") != -1, "READY 提示应恢复 Space 发射，实际：%s。" % [hint.text])
	if feedback != null:
		_check(NAME, not feedback.visible, "READY 下 invalid 反馈应清除。")
	# 按钮本身不发射：按钮 pressed 只经 Start Run 链进 READY，LightPathLayer 仍为空（未 fire）。
	_check(NAME, lpl != null and lpl.get_child_count() == 0, "点击「开始运行」不应自动发射，光段应仍为 0，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_and_free(node, false)


## 3. PULSE UI（15）：READY→fire 进入 PULSE_ACTIVE，按钮隐藏，提示「运行中…」，Space 不表现为可重复发射。
func _test_03_pulse_ui(scene: PackedScene) -> void:
	const NAME: String = "15_PULSE_UI"
	var node: Node2D = await _ready_instance(scene)
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	node.start_run()
	node.fire_light()
	if button != null:
		_check(NAME, not button.visible, "PULSE 下「开始运行」按钮应隐藏。")
	if hint != null:
		_check(NAME, hint.text.find("运行中") != -1, "PULSE 提示应为「运行中…」，实际：%s。" % [hint.text])
		_check(NAME, hint.text.find("Space：发射") == -1, "PULSE 提示不应表现为 Space 可重复发射，实际：%s。" % [hint.text])
	await _settle_and_free(node, true)


## 4. MOVE UI（16）：未完成脉冲结算后进入 MOVE_WINDOW，Space 提示恢复。
func _test_04_move_ui(scene: PackedScene) -> void:
	const NAME: String = "16_MOVE_UI"
	var node: Node2D = await _ready_instance(scene)
	var hint: Label = _hint_label(node)
	node.start_run()
	node.fire_light()
	# 等待脉冲视觉结束 → MOVE_WINDOW（默认水晶不在光路，未完成）。
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame
	if hint != null:
		_check(NAME, hint.text.find("Space：发射") != -1, "MOVE 提示应恢复 Space 发射，实际：%s。" % [hint.text])
	await _settle_and_free(node, false)


## 5. COMPLETED UI（17）：入树前把水晶移到光路格 (3,3)，Start Run→fire→结算完成→COMPLETED，按钮/Space 均不表现为可用。
func _test_05_completed_ui(scene: PackedScene) -> void:
	const NAME: String = "17_COMPLETED_UI"
	var node: Node2D = scene.instantiate() as Node2D
	# 水晶移到光路行 (3,3)：默认发射器 (1,3) RIGHT，光路 (2,3)(3,3)(4,3) 命中 (3,3) → 激活 → 完成。
	var crystal: Node2D = node.get_node_or_null("RuntimeObjects/Crystal") as Node2D
	_check(NAME, crystal != null, "RuntimeObjects/Crystal 应存在。")
	if crystal != null:
		crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 3))
	root.add_child(node)
	await process_frame
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	node.start_run()
	node.fire_light()
	# 等待脉冲结算 → COMPLETED（水晶在光路，完成事实成立）。
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame
	if button != null:
		_check(NAME, not button.visible, "COMPLETED 下「开始运行」按钮应隐藏。")
	if hint != null:
		_check(NAME, hint.text.find("Space：发射") == -1, "COMPLETED 提示不应表现为 Space 可发射，实际：%s。" % [hint.text])
		_check(NAME, hint.text.find("R：重置") != -1, "COMPLETED 提示应保留 R 重置，实际：%s。" % [hint.text])
	await _settle_and_free(node, false)


## 6. invalid 反馈与 valid 清除（同一实例 18/19）：捕获合法 Terrain 单元格 → 清空 TerrainLayer 使 Gate 报 terrain_empty ERROR →
##    Start Run 出现 invalid 反馈、仍 SETUP；同实例恢复 Terrain 单元格 → 再次正式 Start Run → READY → 旧 invalid 反馈清除。
##    不修改 Validator 规则、不写资源；invalid→valid 完全由内存中 Terrain 单元格可逆切换实现（不换场景实例）。
func _test_06_invalid_feedback_and_valid_clears(scene: PackedScene) -> void:
	const NAME: String = "18/19_invalid反馈与valid清除(同实例)"
	var node: Node2D = await _ready_instance(scene)
	var terrain: TileMapLayer = node.get_node_or_null("TerrainLayer") as TileMapLayer
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	var feedback: Label = _feedback_label(node)
	# 捕获合法 Terrain 完整 tile 信息（cell/source_id/atlas/alt），供同实例 invalid→valid 可逆恢复，不写资源、不改 Validator 规则。
	var saved_cells: Array[Vector2i] = []
	var saved_source_ids: Array[int] = []
	var saved_atlas: Array[Vector2i] = []
	var saved_alt: Array[int] = []
	_check(NAME, terrain != null, "TerrainLayer 应存在。")
	if terrain != null:
		for cell: Vector2i in terrain.get_used_cells():
			saved_cells.append(cell)
			saved_source_ids.append(terrain.get_cell_source_id(cell))
			saved_atlas.append(terrain.get_cell_atlas_coords(cell))
			saved_alt.append(terrain.get_cell_alternative_tile(cell))
	# invalid 路径：清空 TerrainLayer → terrain_empty ERROR（不影响已构造运行期快照）。
	if terrain != null:
		terrain.clear()
	var result_invalid: Variant = node.start_run()
	_check(NAME, result_invalid != null, "invalid 也应返回结构化结果。")
	if feedback != null:
		_check(NAME, feedback.visible, "invalid 后 StartRunFeedbackLabel 应可见。")
		_check(NAME, feedback.text.find("无法开始运行") != -1, "invalid 反馈文案应以「无法开始运行」开头，实际：%s。" % [feedback.text])
		_check(NAME, feedback.text.find("错误") != -1, "invalid 反馈文案应包含错误数量，实际：%s。" % [feedback.text])
	if button != null:
		_check(NAME, button.visible and not button.disabled, "invalid 后按钮仍可见且可用（允许重试）。")
	if hint != null:
		_check(NAME, hint.text.find("开始运行") != -1, "invalid 后仍 SETUP，提示应引导「开始运行」，实际：%s。" % [hint.text])
	# 同实例 invalid→valid：恢复 Terrain 单元格 → 再次正式 Start Run → READY → 旧 invalid 反馈由 READY 刷新清除。
	if terrain != null:
		for i: int in range(saved_cells.size()):
			terrain.set_cell(saved_cells[i], saved_source_ids[i], saved_atlas[i], saved_alt[i])
	var result_valid: Variant = node.start_run()
	_check(NAME, result_valid != null, "valid Start Run 也应返回结构化结果。")
	if feedback != null:
		_check(NAME, not feedback.visible, "同实例 valid Start Run 后旧 invalid 反馈应清除（READY 刷新）。")
	if hint != null:
		_check(NAME, hint.text.find("Space：发射") != -1, "同实例 valid 后应进 READY，提示恢复 Space 发射，实际：%s。" % [hint.text])
	if button != null:
		_check(NAME, not button.visible, "同实例 valid 后应进 READY，按钮隐藏。")
	await _settle_and_free(node, false)


## 7. R 重启与 direct fire 拒绝（20）：Start Run→fire→R 回 SETUP；R 后 direct fire 仍拒绝；
##    重新 Start Run→READY→fire 再次成功（必须重新 Start Run 才能发射）。
func _test_07_reset_restart_and_direct_fire_rejected(scene: PackedScene) -> void:
	const NAME: String = "20_R重启与directFire拒绝"
	var node: Node2D = await _ready_instance(scene)
	var button: Button = _start_run_button(node)
	var hint: Label = _hint_label(node)
	var lpl: Node2D = _lpl(node)
	# 进入运行并发射一次。
	node.start_run()
	node.fire_light()
	await _settle_and_free_pulse_wait(node)
	# R 回 SETUP。
	node.reset_runtime()
	await process_frame
	if button != null:
		_check(NAME, button.visible and not button.disabled, "R 后回 SETUP，「开始运行」应重新可见且可用。")
	if hint != null:
		_check(NAME, hint.text.find("开始运行") != -1, "R 后回 SETUP，提示应引导「开始运行」，实际：%s。" % [hint.text])
		_check(NAME, hint.text.find("Space：发射") == -1, "R 后回 SETUP，提示不应宣称 Space 可发射，实际：%s。" % [hint.text])
	# R 后 direct Space 仍拒绝：未重新 Start Run 时 fire 不产生光段。
	node.fire_light()
	_check(NAME, lpl != null and lpl.get_child_count() == 0, "R 后未重新 Start Run，direct fire 应被拒绝（光段 0），实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	# 重新 Start Run → READY → fire 再次成功。
	node.start_run()
	node.fire_light()
	_check(NAME, lpl != null and lpl.get_child_count() == 3, "重新 Start Run 后 fire 应成功（光段 3），实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_and_free(node, true)


## 等待脉冲视觉结束（不复用 _settle_and_free，因本用例后续仍要使用 node）。
func _settle_and_free_pulse_wait(node: Node2D) -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== core_loop 正式 Start Run UI 集成测试摘要（D7-3）====")
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
