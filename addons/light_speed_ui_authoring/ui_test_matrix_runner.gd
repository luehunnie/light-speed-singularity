@tool
class_name LightSpeedUIAuthoringTestMatrix
extends RefCounted

## UI Test Matrix 运行器（S3-04；冻结总结 v1.0 §86）。
## 职责：冻结代表组合（Preview Data × Viewport，非笛卡尔积）并对 Control 树跑五类
##       机械检查：Control 越界 / 文本裁切 / 必需模块不可见 / 明显重叠 / Container 溢出。
## 输入输出：run_combo(root, preset, viewport_size, required_slots) → {combo, issues}；
##           run_matrix(...) 逐组合合并；issue={check, node_path, detail}。
## 副作用：无（只读几何事实；不改节点、不 autofix——§86 输出事实，审美仍由人判断）。
## 边界：preset 与 viewport 由注入服务构建（Preview/Viewport 预设为唯一来源）；
##       root 可为 Control 或 Node2D 关卡根（检查域=Slot 合同服务发现的 Control 子树，
##       禁 Node.name/NodePath/场景路径/坐标猜测）；
##       几何统一到同一 canvas 坐标空间（树内 get_global_rect()；脱树按 Control position
##       累积至最近非 Control 祖先、含各子树根自身 position——多 CanvasLayer/Control 子树
##       的局部原点不再互相压扁，跨子树比较有统一参考系；重复根/逻辑对象按实例 ID 去重）；
##       文本裁切/溢出用 get_combined_minimum_size()（含 custom_minimum_size，headless 确定性可用）；
##       overlap 仅比较绘制型/叶级、可见链完整、非零尺寸的 Control（排除 Container/纯宿主、
##       祖先-后代对、隐藏链）；必需 Slot 缺失只由 Slot 合同 Validator 报 missing_required_slot，
##       Matrix 仅在正式 Slot 存在但不可见/出视口时报 required_not_visible（不重复报缺失）。

const PREVIEW_SERVICE: GDScript = preload("./ui_preview_data_service.gd")
const VIEWPORT_SERVICE: GDScript = preload("./ui_viewport_presets.gd")

## 冻结代表组合（§86 示例四组：Typical×Standard / Long×Small / Stress×Min / Minimal×Large）。
const MATRIX_COMBOS: Array = [
	{ preview = "typical", viewport = "standard_16_9" },
	{ preview = "long_content", viewport = "small_16_9" },
	{ preview = "stress_test", viewport = "minimum_supported" },
	{ preview = "minimal", viewport = "large_16_9" },
]

var _previews = PREVIEW_SERVICE.new()
var _viewports = VIEWPORT_SERVICE.new()


## 跑全部冻结组合：返回 {combos: Array[{combo, preview_id, viewport_id, size, issues}], total_issues}。
func run_matrix(root: Node, required_slots: Array) -> Dictionary:
	var results: Array = []
	var total: int = 0
	for combo: Dictionary in MATRIX_COMBOS:
		var preview: Dictionary = _previews.build_preset(String(combo["preview"]))
		var viewport: Dictionary = _viewports.build_preset(String(combo["viewport"]))
		var run_result: Dictionary = run_combo(root, preview, viewport["size"], required_slots)
		results.append({
			preview_id = combo["preview"], viewport_id = combo["viewport"],
			size = viewport["size"], issues = run_result["issues"],
		})
		total += (run_result["issues"] as Array).size()
	return { combos = results, total_issues = total }


## 跑单组合：preset 为 Preview Data 字典，viewport_size 为像素。
## 几何统一到同一 canvas 坐标空间（树内 get_global_rect / 脱树 position 累积，见 _rect_in_canvas）
## ——多 CanvasLayer/Control 子树同参考系，子树根局部原点不互相压扁；收集域按实例 ID 去重。
## 载体兼容：root 可为 Node2D 关卡根，检查域经 Slot 合同服务发现（CanvasLayer/Slot meta）；
##           root 自身为 Control 时保持原语义（域根=自身）；无任何 Control 子树才 root_missing。
func run_combo(root: Node, preset: Dictionary, viewport_size: Vector2i, required_slots: Array) -> Dictionary:
	var issues: Array = []
	var slot_service = preload("./ui_binding_slot_contract.gd").new()
	var domain_roots: Array = slot_service.find_ui_domain_roots(root)
	if domain_roots.is_empty():
		return { issues = [{ check = "root_missing", node_path = "", detail = "UI 根缺失或无任何 Control 子树，无法跑矩阵。" }] }
	var view_rect: Rect2 = Rect2(Vector2.ZERO, Vector2(viewport_size))
	var controls: Array = []
	var seen_ids: Dictionary = {}
	for domain_root: Control in domain_roots:
		for node: Node in _collect_controls(domain_root):
			var instance_id: int = node.get_instance_id()
			if seen_ids.has(instance_id):
				continue
			seen_ids[instance_id] = true
			controls.append(node)
	for node: Node in controls:
		var control: Control = node
		_check_bounds(control, view_rect, issues)
		_check_text_clipping(control, issues)
		_check_container_overflow(control, issues)
	_check_overlap(controls, issues)
	_check_required_visible(root, slot_service, required_slots, view_rect, issues)
	return { issues = issues, preview = preset, viewport_size = viewport_size }


## 统一 canvas 坐标空间矩形：树内节点用 get_global_rect()（多 CanvasLayer/Control 子树
## 统一进同一 canvas 空间，子树根局部原点不互相压扁）；脱树节点退化按 Control position
## 自身起逐级累积至最近非 Control 祖先（含各子树根自身 position），保持 headless 确定性。
func _rect_in_canvas(control: Control) -> Rect2:
	if control.is_inside_tree():
		return control.get_global_rect()
	var accumulated: Vector2 = Vector2.ZERO
	var node: Node = control
	while node is Control:
		accumulated += (node as Control).position
		node = node.get_parent()
	return Rect2(accumulated, control.size)


## 自 control 向上走 Control 链的 visible（子树根自身也计入；不依赖入树）。
func _visible_through(control: Control) -> bool:
	var node: Node = control
	while node is CanvasItem:
		if not (node as CanvasItem).visible:
			return false
		node = node.get_parent()
	return true


## 逐项：越界（统一 canvas 矩形不包含于视口矩形）。
func _check_bounds(control: Control, view_rect: Rect2, issues: Array) -> void:
	var rect: Rect2 = _rect_in_canvas(control)
	if not view_rect.encloses(rect):
		issues.append({ check = "control_out_of_bounds", node_path = control.name,
			detail = "越界：rect %s 不在视口 %s 内。" % [rect, view_rect] })


## 逐项：文本裁切（Label 文本自然最小需求 get_minimum_size() 超过自身 size；
## fixture 须先定 size 再赋长文本——size 赋值会向 combined min 收紧，反序造不出裁切）。
func _check_text_clipping(control: Control, issues: Array) -> void:
	if not (control is Label):
		return
	var label: Label = control
	var needed: Vector2 = label.get_minimum_size()
	if label.text != "" and (needed.x > label.size.x or needed.y > label.size.y):
		issues.append({ check = "text_clipping", node_path = control.name,
			detail = "文本裁切：最小需求 %s 超过尺寸 %s。" % [needed, label.size] })


## 逐项：Container/父级溢出（子 Control 最小需求超过父 Control 尺寸）。
func _check_container_overflow(control: Control, issues: Array) -> void:
	var parent: Node = control.get_parent()
	if not (parent is Control):
		return
	var parent_control: Control = parent
	var needed: Vector2 = control.get_combined_minimum_size()
	if needed.x > parent_control.size.x or needed.y > parent_control.size.y:
		issues.append({ check = "container_overflow", node_path = control.name,
			detail = "容器溢出：子最小需求 %s 超过父尺寸 %s。" % [needed, parent_control.size] })


## 成对：明显重叠（候选绘制叶在统一 canvas 空间两两比较——不限同父，跨 CanvasLayer/
## Control 子树同参考系；交叠超过较小者一半面积）。祖先-后代对跳过（包含属正常排版）。
func _check_overlap(controls: Array, issues: Array) -> void:
	var candidates: Array = []
	for node: Node in controls:
		var control: Control = node
		if _is_overlap_candidate(control):
			candidates.append(control)
	for i: int in range(candidates.size()):
		var a: Control = candidates[i]
		for j: int in range(i + 1, candidates.size()):
			var b: Control = candidates[j]
			if a.is_ancestor_of(b) or b.is_ancestor_of(a):
				continue
			var rect_a: Rect2 = _rect_in_canvas(a)
			var rect_b: Rect2 = _rect_in_canvas(b)
			var intersection: Rect2 = rect_a.intersection(rect_b)
			if intersection.has_area():
				var smaller: float = min(rect_a.get_area(), rect_b.get_area())
				if smaller > 0.0 and intersection.get_area() / smaller >= 0.5:
					issues.append({ check = "obvious_overlap", node_path = a.name,
						detail = "明显重叠：与 %s 交叠 %.0f%%。" % [b.name, intersection.get_area() / smaller * 100] })


## overlap 候选判定（类型判定，不猜 Node.name/NodePath/坐标）：实际绘制、可见链完整、
## 非零尺寸——Container（纯排版宿主）与无脚本裸 Control（纯宿主，可能只是布局锚点）排除；
## 带脚本 Control 保留（可能自定义绘制）。
func _is_overlap_candidate(control: Control) -> bool:
	if control is Container:
		return false
	if control.get_script() == null and control.get_class() == "Control":
		return false
	if control.size.x <= 0.0 or control.size.y <= 0.0:
		return false
	return _visible_through(control)


## 必需模块不可见：仅当正式 Slot 存在但隐藏（visible 链）/ 不在视口内时报告；
## Slot 缺失只由 Slot 合同 Validator 报 missing_required_slot（Slot Guard 职责），Matrix 不重复。
## scene_root 为编辑场景根（可为 Node2D），Slot 发现已覆盖全场景（含 CanvasLayer 分支）。
func _check_required_visible(scene_root: Node, slot_service, required_slots: Array, view_rect: Rect2, issues: Array) -> void:
	var slots: Dictionary = slot_service.find_slots(scene_root)
	for slot_id: String in required_slots:
		if not slots.has(slot_id):
			continue
		for node: Node in slots[slot_id]:
			if not (node is Control):
				continue
			var control: Control = node
			if not _visible_through(control):
				issues.append({ check = "required_not_visible", node_path = control.name, detail = "必需 Slot %s 不可见。" % slot_id })
			elif not view_rect.encloses(_rect_in_canvas(control)):
				issues.append({ check = "required_not_visible", node_path = control.name, detail = "必需 Slot %s 在视口外。" % slot_id })


## 收集树内全部 Control（含根）。
func _collect_controls(node: Node) -> Array:
	var found: Array = []
	if node is Control:
		found.append(node)
	for child: Node in node.get_children():
		found.append_array(_collect_controls(child))
	return found
