extends SceneTree

## core_loop Q 形态切换正式链路集成测试（M4-E4）。
##
## 实例化真实 core_loop_prototype.tscn，挂入 SceneTree 触发真实 _ready（构造 FormSwitchToastView 与运行期编排），
## 经真实 _input(Q 键事件) → PlayerInteractionController(SWITCH_FORM) → _switch_light_form →
## LevelRuntimeController.request_switch_light_form → FormSwitchToastView 全链驱动，
## 观察公开节点路径 CanvasLayer/FormSwitchToastLabel 与 LightPathLayer，禁止白盒私有状态。
##
## 覆盖：真实人工验收场景序列化 allow_form_switch=true（零内存改写，Human Gate 所用配置直证）且 Q 显示提示；
##   allow=false（内存显式关闭，模拟禁用关卡）时 Q 无效且不显示提示；allow=true 时 SETUP Q 提示“粒子模式”上方居中 1 秒消失；
##   玩家 Ray→Q→Particle 混合并存（真实 0.5s cooldown）；R 恢复初始形态（toast 文案区分）+ 全清；
##   COMPLETED 后 Q 禁止且无提示。
## 真实 cooldown（正式 LRC 读单调时钟）：混合发射用例等待约 0.6 秒真实时间；Ray 视觉 1.0s。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
## 略大于正式 0.5s cooldown，确保第二次 Space 可发射。
const _COOLDOWN_SETTLE_MS: int = 650
## 略大于提示 1 秒生命周期，验证自动消失。
const _TOAST_SETTLE_MS: int = 1250

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_real_scene_serialized_allow_true(scene)
	_test_02_allow_false_q_rejected_no_toast(scene)
	await _test_03_allow_true_setup_q_toast(scene)
	await _test_04_player_q_mixed_fire_and_reset(scene)
	await _test_05_completed_forbids_q_no_toast(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 构造 Q 按下的真实键盘事件（switch_light_form 以 physical_keycode=81 绑定，与 PlayerInteractionController 测试一致）。
func _make_q_press() -> InputEventKey:
	var e: InputEventKey = InputEventKey.new()
	e.physical_keycode = 81  # KEY_Q
	e.pressed = true
	e.echo = false
	return e


## 实例化场景（挂树前把发射器配置 allow_form_switch 显式写入内存值，不写资源）：场景序列化值已为 true，
## 本入口用于 allow=false 拒绝用例（模拟禁用关卡）与 allow=true 显式用例；泵一帧触发真实 _ready（构造 FormSwitchToastView）。
func _ready_instance(scene: PackedScene, allow_form_switch: bool) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	var emitter: Node = node.get_node_or_null("RuntimeObjects/Emitter")
	if emitter != null:
		emitter.set("allow_form_switch", allow_form_switch)
	root.add_child(node)
	await process_frame
	return node


## 取形态提示标签（公开场景角色路径 CanvasLayer/FormSwitchToastLabel）。
func _toast_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/FormSwitchToastLabel") as Label


## 取 LightPathLayer（公开场景角色路径）。
func _lpl(node: Node2D) -> Node2D:
	return node.get_node_or_null("LightPathLayer") as Node2D


## 等待指定真实毫秒（正式 cooldown/提示 Timer 读真实时间）。
func _wait_ms(ms: int) -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < ms:
		await process_frame


## 释放实例前等待脉冲/泵协程在活动控制器上恢复（含 Particle 0.1s 泵与 Ray 1.0s 视觉延迟）。
func _settle_and_free(node: Node2D) -> void:
	await _wait_ms(1250)
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. 真实人工验收场景序列化证明（Human Gate Fix）：零内存改写直接实例化 core_loop_prototype.tscn，
##    挂树前读发射器序列化 allow_form_switch 必须为 true（真实 GUI 验收所用配置），SETUP 下真实 Q 键事件显示「粒子模式」。
func _test_01_real_scene_serialized_allow_true(scene: PackedScene) -> void:
	const NAME: String = "01_真实场景序列化allow为true_Q提示"
	var node: Node2D = scene.instantiate() as Node2D
	var emitter: Node = node.get_node_or_null("RuntimeObjects/Emitter")
	var serialized_allow: bool = emitter != null and bool(emitter.get("allow_form_switch"))
	_check(NAME, emitter != null, "RuntimeObjects/Emitter 应存在。")
	_check(NAME, serialized_allow, "core_loop_prototype.tscn 发射器序列化 allow_form_switch 应为 true（人工验收 Q 可达前提），实际 false。")
	root.add_child(node)
	await process_frame
	var toast: Label = _toast_label(node)
	node._input(_make_q_press())
	_check(NAME, toast != null and toast.visible and toast.text == "粒子模式",
			"零改写真实场景 SETUP Q 应成功切换并显示「粒子模式」，实际 visible=%s text=%s。" % [toast.visible if toast != null else false, toast.text if toast != null else "<null>"])
	await _settle_and_free(node)


## 2. allow=false（内存显式关闭，模拟禁用关卡）Q 无效：SETUP 下真实 Q 键事件 → 形态保持初始 RAY（Start Run+fire 仍产生 Ray 光段）、不显示任何提示。
func _test_02_allow_false_q_rejected_no_toast(scene: PackedScene) -> void:
	const NAME: String = "02_allow为false_Q无效无提示"
	var node: Node2D = await _ready_instance(scene, false)
	var toast: Label = _toast_label(node)
	_check(NAME, toast != null, "FormSwitchToastLabel 应已由 FormSwitchToastView 创建。")
	node._input(_make_q_press())
	_check(NAME, toast != null and not toast.visible, "被禁止的 Q 不应显示提示。")
	# Q 无效的公开可观测证明：形态未变——Start Run 后 fire 仍为 RAY 光段（若 Q 生效则发射光粒、光路层为 ParticleView）。
	var lpl: Node2D = _lpl(node)
	node.start_run()
	node.fire_light()
	await process_frame
	_check(NAME, lpl != null and lpl.get_child_count() > 0, "初始 RAY 未被无效 Q 改变，fire 应产生 Ray 视觉，实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_and_free(node)


## 3. allow=true SETUP Q：真实 Q 键事件 → 提示“粒子模式”出现且上方居中；1 秒后自动消失。
func _test_03_allow_true_setup_q_toast(scene: PackedScene) -> void:
	const NAME: String = "03_allow为true_SETUP_Q提示"
	var node: Node2D = await _ready_instance(scene, true)
	var toast: Label = _toast_label(node)
	node._input(_make_q_press())
	_check(NAME, toast != null, "FormSwitchToastLabel 应存在。")
	if toast == null:
		await _settle_and_free(node)
		return
	_check(NAME, toast.visible, "成功切换（RAY→PARTICLE）后提示应可见。")
	_check(NAME, toast.text == "粒子模式", "切到 PARTICLE 文案应为「粒子模式」，实际：%s。" % [toast.text])
	_check(NAME, is_equal_approx(toast.anchor_left, 0.5) and is_equal_approx(toast.anchor_right, 0.5), "提示应水平居中（锚点 0.5），实际 L=%s R=%s。" % [toast.anchor_left, toast.anchor_right])
	_check(NAME, is_equal_approx(toast.anchor_top, 0.0) and toast.offset_top > 0.0 and toast.offset_top < 60.0, "提示应在屏幕上方（顶锚 0 + 小偏移），实际 top=%s offset=%s。" % [toast.anchor_top, toast.offset_top])
	await _wait_ms(_TOAST_SETTLE_MS)
	_check(NAME, not toast.visible, "提示应在 1 秒后自动消失。")
	await _settle_and_free(node)


## 4. 玩家混合路径 + R：Start Run → fire(Ray) → Q → 0.5s 后 fire(Particle) 同层并存 → R 全清且恢复初始 RAY
##    （R 后再 Q 提示「粒子模式」证明 R 已把形态恢复回 RAY；若未恢复则 Q 会切到 RAY 显示「射线模式」）。
func _test_04_player_q_mixed_fire_and_reset(scene: PackedScene) -> void:
	const NAME: String = "04_玩家混合发射与R恢复"
	var node: Node2D = await _ready_instance(scene, true)
	var toast: Label = _toast_label(node)
	var lpl: Node2D = _lpl(node)
	node.start_run()
	node.fire_light()
	await process_frame
	var ray_children: int = lpl.get_child_count()
	_check(NAME, ray_children > 0, "前置 fire(RAY) 应产生 Ray 视觉，实际 %d。" % [ray_children])
	# PULSE_ACTIVE 中 Q（Ray 尚存活，视觉 1.0s）→ 提示“粒子模式”。
	node._input(_make_q_press())
	_check(NAME, toast != null and toast.visible and toast.text == "粒子模式", "PULSE_ACTIVE Q 应显示「粒子模式」。")
	# 真实 0.5s cooldown 到期后第二发以 PARTICLE 形态发射——与仍存活的 Ray 同层并存。
	await _wait_ms(_COOLDOWN_SETTLE_MS)
	node.fire_light()
	await process_frame
	var mixed_children: int = lpl.get_child_count()
	_check(NAME, mixed_children > ray_children, "Q 后第二发应为 PARTICLE 视觉并与旧 Ray 并存（children %d → %d）。" % [ray_children, mixed_children])
	# R：全清 + 恢复关卡初始形态 RAY。
	node.reset_runtime()
	await process_frame
	_check(NAME, lpl.get_child_count() == 0, "R 后光路层应全清，实际 %d。" % [lpl.get_child_count()])
	node._input(_make_q_press())
	_check(NAME, toast != null and toast.visible and toast.text == "粒子模式", "R 恢复初始 RAY 后再 Q 应显示「粒子模式」（证明 R 已恢复初始形态）。")
	await _settle_and_free(node)


## 5. COMPLETED 禁止 Q：水晶移入光路使 fire 后完成 → COMPLETED 下真实 Q 键事件被拒、不显示提示。
func _test_05_completed_forbids_q_no_toast(scene: PackedScene) -> void:
	const NAME: String = "05_COMPLETED禁止Q无提示"
	var node: Node2D = scene.instantiate() as Node2D
	var emitter: Node = node.get_node_or_null("RuntimeObjects/Emitter")
	if emitter != null:
		emitter.set("allow_form_switch", true)
	# 水晶移到光路行 (3,3)：默认发射器 (1,3) RIGHT，光路命中 (3,3) → 激活 → 完成。
	var crystal: Node2D = node.get_node_or_null("RuntimeObjects/Crystal") as Node2D
	if crystal != null:
		crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 3))
	root.add_child(node)
	await process_frame
	var toast: Label = _toast_label(node)
	node.start_run()
	node.fire_light()
	await _wait_ms(1250)
	node._input(_make_q_press())
	_check(NAME, toast != null and not toast.visible, "COMPLETED 下 Q 应被禁止且不显示提示。")
	await _settle_and_free(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== core_loop Q 形态切换正式链路集成测试摘要（M4-E4）====")
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
