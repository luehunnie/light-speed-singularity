extends SceneTree

## S3-04 UI Test Matrix 测试（GUI 冻结总结 v1.0 §86）。
## 覆盖：冻结四组合、干净 fixture 零 issue、五类机械检查各自检出、只输出事实、
##       Node2D 载体三路（CanvasLayer 子树真实检查/Control 根兼容/无 Control root_missing）、
##       原型误报回归（统一 canvas 坐标/绘制叶重叠/Slot 缺失归 Slot Guard）。
## 由 Godot --headless --script 运行；任一失败 quit(1)。fixture 全内存构造并入树。

const _Matrix: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_test_matrix_runner.gd"
)
const _SlotContract: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_binding_slot_contract.gd"
)
const _PreviewData: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_preview_data_service.gd"
)
const _ViewportPresets: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_viewport_presets.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _matrix
var _previews
var _viewports


func _initialize() -> void:
	_matrix = _Matrix.new()
	_previews = _PreviewData.new()
	_viewports = _ViewportPresets.new()
	_test_frozen_combos()
	_test_clean_fixture()
	_test_bounds()
	_test_text_clipping()
	_test_overlap()
	_test_required_not_visible()
	_test_container_overflow()
	_test_node2d_carrier()
	_test_prototype_regressions()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 收集一次运行中出现的 check 种类。
func _check_kinds(issues: Array) -> Dictionary:
	var kinds: Dictionary = {}
	for issue: Dictionary in issues:
		kinds[String(issue["check"])] = true
	return kinds


## 干净 UI fixture：1024x576 根（=最小正式视口，四组合全容纳）+ 两个不重叠 Slot。
func _make_clean_ui() -> Control:
	var ui_root: Control = Control.new()
	ui_root.size = Vector2(1024, 576)
	var panel_a: HBoxContainer = HBoxContainer.new()
	panel_a.position = Vector2(0, 0)
	panel_a.size = Vector2(400, 80)
	panel_a.custom_minimum_size = Vector2(400, 80)
	panel_a.set_meta("ui_binding_slot_id", "inventory_host")
	ui_root.add_child(panel_a)
	var panel_b: HBoxContainer = HBoxContainer.new()
	panel_b.position = Vector2(0, 500)
	panel_b.size = Vector2(300, 60)
	panel_b.custom_minimum_size = Vector2(300, 60)
	panel_b.set_meta("ui_binding_slot_id", "fire_reset_host")
	ui_root.add_child(panel_b)
	return ui_root


## G1 冻结组合：四组代表组合与 §86 示例一致；run_matrix 结构齐全。
func _test_frozen_combos() -> void:
	const NAME: String = "G1_冻结组合"
	_check(NAME, _matrix.MATRIX_COMBOS.size() == 4, "应冻结 4 组代表组合，实际 %d。" % _matrix.MATRIX_COMBOS.size())
	var pairs: PackedStringArray = PackedStringArray()
	for combo: Dictionary in _matrix.MATRIX_COMBOS:
		pairs.append("%s×%s" % [combo["preview"], combo["viewport"]])
	_check(NAME, ",".join(pairs) == "typical×standard_16_9,long_content×small_16_9,stress_test×minimum_supported,minimal×large_16_9", "组合应与 §86 示例一致，实际 %s。" % ",".join(pairs))
	var ui_root: Control = _make_clean_ui()
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_matrix(ui_root, ["inventory_host", "fire_reset_host"])
	_check(NAME, (result["combos"] as Array).size() == 4 and result.has("total_issues"), "run_matrix 应返回 4 组结果与总计。")
	ui_root.free()


## G2 干净 fixture：合格 UI 在四组合下 0 issue。
func _test_clean_fixture() -> void:
	const NAME: String = "G2_干净零issue"
	var ui_root: Control = _make_clean_ui()
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_matrix(ui_root, ["inventory_host", "fire_reset_host"])
	_check(NAME, int(result["total_issues"]) == 0, "干净 UI 四组合应 0 issue，实际：%s。" % str(result["combos"]))
	ui_root.free()


## G3 越界：子 Control 超出视口右缘应检出 control_out_of_bounds。
func _test_bounds() -> void:
	const NAME: String = "G3_越界检出"
	var ui_root: Control = _make_clean_ui()
	var runaway: Control = Control.new()
	runaway.position = Vector2(1900, 0)
	runaway.size = Vector2(200, 50)
	ui_root.add_child(runaway)
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_combo(ui_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, _check_kinds(result["issues"]).has("control_out_of_bounds"), "越界 Control 应检出。")
	ui_root.free()


## G4 文本裁切：Label 先定小尺寸再赋长文本，文本最小需求超过 size 应检出。
func _test_text_clipping() -> void:
	const NAME: String = "G4_文本裁切"
	var ui_root: Control = _make_clean_ui()
	var clipped: Label = Label.new()
	clipped.size = Vector2(80, 20)
	clipped.text = "这是一段非常长的目标文本内容用于触发裁切检测的确定性长文本"
	clipped.position = Vector2(0, 200)
	ui_root.add_child(clipped)
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_combo(ui_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, _check_kinds(result["issues"]).has("text_clipping"), "Label 裁切应检出。")
	ui_root.free()


## G5 明显重叠：同父两绘制叶（ColorRect）交叠超一半应检出；Container/裸 Control 纯宿主不参与。
func _test_overlap() -> void:
	const NAME: String = "G5_明显重叠"
	var ui_root: Control = _make_clean_ui()
	var a: ColorRect = ColorRect.new()
	a.position = Vector2(600, 300)
	a.size = Vector2(100, 50)
	var b: ColorRect = ColorRect.new()
	b.position = Vector2(620, 305)
	b.size = Vector2(100, 50)
	ui_root.add_child(a)
	ui_root.add_child(b)
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_combo(ui_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, _check_kinds(result["issues"]).has("obvious_overlap"), "同父绘制叶明显重叠应检出。")
	_check(NAME, not result["issues"].any(func(i): return String(i["node_path"]) in [String(a.name), String(b.name)] and String(i["check"]) != "obvious_overlap"), "绘制叶除重叠外不应有其他误报。")
	ui_root.free()


## G6 必需模块不可见：Slot 缺失只由 Slot Validator（missing_required_slot）报告，Matrix 不重复；
##       Slot 存在但隐藏（visible=false）仍由 Matrix 报 required_not_visible。
func _test_required_not_visible() -> void:
	const NAME: String = "G6_必需不可见"
	var contract = _SlotContract.new()
	# 缺失：根上无 fire_reset_host → Matrix 零 required_not_visible；Slot Validator 报缺失。
	var missing_root: Control = _make_clean_ui()
	missing_root.get_child(1).remove_meta("ui_binding_slot_id")
	root.add_child(missing_root)
	var missing_result: Dictionary = _matrix.run_combo(missing_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, not _check_kinds(missing_result["issues"]).has("required_not_visible"), "Slot 缺失不应由 Matrix 报 required_not_visible（Slot Guard 职责）。")
	var guard_issues: Array = contract.validate_ui_structure(missing_root, ["inventory_host", "fire_reset_host"])
	_check(NAME, guard_issues.any(func(i): return String(i["check"]) == "missing_required_slot"), "Slot 缺失应由 Slot Validator 报 missing_required_slot。")
	missing_root.free()
	# 隐藏：Slot 存在但 visible=false。
	var hidden_root: Control = _make_clean_ui()
	hidden_root.get_child(1).visible = false
	root.add_child(hidden_root)
	var hidden_result: Dictionary = _matrix.run_combo(hidden_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, _check_kinds(hidden_result["issues"]).has("required_not_visible"), "隐藏必需 Slot 应检出。")
	hidden_root.free()


## G7 容器溢出：子最小需求超过父尺寸应检出 container_overflow。
func _test_container_overflow() -> void:
	const NAME: String = "G7_容器溢出"
	var ui_root: Control = _make_clean_ui()
	var small_parent: Control = Control.new()
	small_parent.position = Vector2(0, 400)
	small_parent.size = Vector2(200, 100)
	var big_child: Control = Control.new()
	big_child.custom_minimum_size = Vector2(800, 40)
	big_child.size = Vector2(800, 40)
	small_parent.add_child(big_child)
	ui_root.add_child(small_parent)
	root.add_child(ui_root)
	var result: Dictionary = _matrix.run_combo(ui_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, _check_kinds(result["issues"]).has("container_overflow"), "容器溢出应检出。")
	ui_root.free()


## G8 载体兼容：Node2D 关卡根经 CanvasLayer 发现 Control 子树跑真实机械检查；
## 世界空间 Control（无 CanvasLayer/无 Slot）不入域；Control 根保持兼容；无 Control 才 root_missing。
func _test_node2d_carrier() -> void:
	const NAME: String = "G8_Node2D载体兼容"
	# Node2D → CanvasLayer → Control（含裁切 Label）→ 真实检出，非 root_missing。
	var level: Node2D = Node2D.new()
	var canvas: CanvasLayer = CanvasLayer.new()
	level.add_child(canvas)
	var ui: Control = Control.new()
	ui.size = Vector2(1024, 576)
	var clipped: Label = Label.new()
	clipped.size = Vector2(80, 20)
	clipped.text = "这是一段非常长的目标文本内容用于触发裁切检测的确定性长文本"
	ui.add_child(clipped)
	canvas.add_child(ui)
	var walls: Node2D = Node2D.new()
	var wall_rect: ColorRect = ColorRect.new()
	wall_rect.size = Vector2(4000, 3000)
	walls.add_child(wall_rect)
	level.add_child(walls)
	root.add_child(level)
	var result: Dictionary = _matrix.run_combo(level, _previews.build_preset("typical"), Vector2i(1920, 1080), [])
	var kinds: Dictionary = _check_kinds(result["issues"])
	_check(NAME, not kinds.has("root_missing"), "Node2D+CanvasLayer 载体不应 root_missing，实际：%s。" % str(result["issues"]))
	_check(NAME, kinds.has("text_clipping"), "CanvasLayer 下 Control 子树应输出真实机械检查。")
	_check(NAME, not result["issues"].any(func(i): return String(i["node_path"]) == String(wall_rect.name)), "世界空间 Control 不应入 UI 检查域。")
	level.free()
	# Control 根保持兼容：干净 UI 仍 0 issue。
	var ui_root: Control = _make_clean_ui()
	root.add_child(ui_root)
	var compat: Dictionary = _matrix.run_combo(ui_root, _previews.build_preset("typical"), Vector2i(1920, 1080), ["inventory_host", "fire_reset_host"])
	_check(NAME, not _check_kinds(compat["issues"]).has("root_missing") and (compat["issues"] as Array).is_empty(), "Control 根应保持原语义（0 issue）。")
	ui_root.free()
	# 无任何 Control 子树 → root_missing。
	var empty_level: Node2D = Node2D.new()
	empty_level.add_child(Node2D.new())
	root.add_child(empty_level)
	var missing: Dictionary = _matrix.run_combo(empty_level, _previews.build_preset("typical"), Vector2i(1920, 1080), [])
	_check(NAME, _check_kinds(missing["issues"]).has("root_missing"), "无任何 Control 子树才应 root_missing。")
	empty_level.free()


## G9 原型误报回归（CoreLoopPrototype 形状）：Node2D→CanvasLayer→顶部 Labels + 底部
## PanelContainer(含叶 Label)——统一 canvas 坐标空间后不误报 obvious_overlap；缺失 Slot 不由
## Matrix 报 required_not_visible；跨子树真实重叠绘制叶仍能检出（修复前局部原点压扁致 100% 误报）。
func _test_prototype_regressions() -> void:
	const NAME: String = "G9_原型误报回归"
	# 原型形状：顶部提示/步数 Label + 底部库存 PanelContainer（各自 CanvasLayer 直接子树根）。
	var level: Node2D = Node2D.new()
	var canvas: CanvasLayer = CanvasLayer.new()
	level.add_child(canvas)
	var hint: Label = Label.new()
	hint.position = Vector2(16, 16)
	hint.size = Vector2(404, 32)
	hint.text = "提示文本"
	canvas.add_child(hint)
	var moves: Label = Label.new()
	moves.position = Vector2(16, 88)
	moves.size = Vector2(304, 32)
	moves.text = "步数文本"
	canvas.add_child(moves)
	var bar: PanelContainer = PanelContainer.new()
	bar.position = Vector2(16, 472)
	bar.size = Vector2(992, 88)
	var bar_label: Label = Label.new()
	bar_label.position = Vector2(8, 8)
	bar_label.size = Vector2(200, 40)
	bar_label.text = "库存槽位"
	bar.add_child(bar_label)
	canvas.add_child(bar)
	root.add_child(level)
	var result: Dictionary = _matrix.run_matrix(level, ["inventory_host"])
	var overlap_issues: Array = []
	for combo: Dictionary in result["combos"]:
		for issue: Dictionary in combo["issues"]:
			if String(issue["check"]) == "obvious_overlap":
				overlap_issues.append(issue)
	_check(NAME, overlap_issues.is_empty(), "顶部 Label 与底部库存条不重叠，不应报 obvious_overlap，实际：%s。" % str(overlap_issues))
	_check(NAME, not _check_kinds(_all_issues(result)).has("required_not_visible"), "缺失 Slot（inventory_host）不应由 Matrix 报 required_not_visible。")
	# 跨子树真实重叠：另一子树根的绘制叶与 hint ≥50% 交叠 → 统一坐标下仍应检出。
	var overlay: ColorRect = ColorRect.new()
	overlay.position = Vector2(20, 18)
	overlay.size = Vector2(200, 28)
	canvas.add_child(overlay)
	var overlap_result: Dictionary = _matrix.run_combo(level, _previews.build_preset("typical"), Vector2i(1024, 576), [])
	_check(NAME, _check_kinds(overlap_result["issues"]).has("obvious_overlap"), "跨子树真实重叠绘制叶应检出。")
	level.free()


## 汇总一次 run_matrix 全部组合的 issues。
func _all_issues(result: Dictionary) -> Array:
	var all: Array = []
	for combo: Dictionary in result["combos"]:
		all.append_array(combo["issues"])
	return all


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== UI Test Matrix 测试摘要 ====")
	print("测试组数：9")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
