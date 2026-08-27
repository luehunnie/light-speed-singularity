extends SceneTree

## VisualTargetResult D4.5-A2 只读结果对象测试。
## 覆盖：默认空结果、SINGLE/MULTIPLE 契约、primary_target 边界、数组构造复制与 getter 副本、reason_code 稳定、不修改节点。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ResultScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_result.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)

# 测试替身：避免依赖 ObjectVisualView 场景子节点。
class _StubVisual extends ObjectVisualView:
	func refresh_visual() -> void:
		pass

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_default_empty()
	_test_02_single_target_contract()
	_test_03_multiple_targets_contract()
	_test_04_primary_target_boundaries()
	_test_05_targets_construct_copy()
	_test_06_get_targets_returns_copy()
	_test_07_ignored_nodes_returns_copy()
	_test_08_reason_code_stable()
	_test_09_does_not_mutate_nodes()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 默认/空结果：new() 应给出 NO_TARGET + no_selection，无伪造目标。
func _test_01_default_empty() -> void:
	const NAME: String = "01_默认空结果"
	var r: RefCounted = _ResultScript.new()
	_check(NAME, r.get_status() == _ResultScript.Status.NO_TARGET, "默认状态应为 NO_TARGET。")
	_check(NAME, r.get_reason_code() == "no_selection", "默认原因码应为 no_selection。")
	_check(NAME, r.get_targets().is_empty(), "默认目标集合应为空。")
	_check(NAME, r.get_ignored_nodes().is_empty(), "默认忽略集合应为空。")
	_check(NAME, r.get_primary_target() == null, "默认主目标应为 null。")
	_check(NAME, r.get_selected_node() == null, "默认选中节点应为 null。")
	_check(NAME, r.get_component_root() == null, "默认组件根应为 null。")


## 2. SINGLE_TARGET 契约：直接视觉结果状态、主目标、集合、组件根、原因码。
func _test_02_single_target_contract() -> void:
	const NAME: String = "02_单目标契约"
	var selected := Node2D.new()
	var root := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	var r: RefCounted = _ResultScript.for_direct_visual(selected, visual, root)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "状态应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == visual, "主目标应为传入视觉。")
	_check(NAME, r.get_targets().size() == 1, "目标集合应仅含一个。")
	_check(NAME, r.get_targets()[0] == visual, "目标集合应为传入视觉。")
	_check(NAME, r.get_component_root() == root, "组件根应为传入根。")
	_check(NAME, r.get_selected_node() == selected, "选中节点应为传入节点。")
	_check(NAME, r.get_reason_code() == "direct_visual", "原因码应为 direct_visual。")
	selected.free()
	root.free()
	visual.free()


## 3. MULTIPLE_TARGETS 契约：组件多视觉结果状态、主目标为 null、集合完整、原因码。
func _test_03_multiple_targets_contract() -> void:
	const NAME: String = "03_多目标契约"
	var selected := Node2D.new()
	var root := Node2D.new()
	var v1: _StubVisual = _StubVisual.new()
	var v2: _StubVisual = _StubVisual.new()
	var v3: _StubVisual = _StubVisual.new()
	var r: RefCounted = _ResultScript.for_component(selected, root, [v1, v2, v3], [])
	_check(NAME, r.get_status() == _ResultScript.Status.MULTIPLE_TARGETS, "状态应为 MULTIPLE_TARGETS。")
	_check(NAME, r.get_primary_target() == null, "多目标主目标应为 null。")
	_check(NAME, r.get_targets().size() == 3, "目标集合应含三个。")
	_check(NAME, r.get_targets()[0] == v1, "目标顺序应保持传入顺序[0]。")
	_check(NAME, r.get_targets()[1] == v2, "目标顺序应保持传入顺序[1]。")
	_check(NAME, r.get_targets()[2] == v3, "目标顺序应保持传入顺序[2]。")
	_check(NAME, r.get_reason_code() == "component_multiple_visuals", "原因码应为 component_multiple_visuals。")
	selected.free()
	root.free()
	v1.free()
	v2.free()
	v3.free()


## 4. primary_target 边界：SINGLE 有值；MULTIPLE/NO_TARGET/UNSUPPORTED 均为 null。
func _test_04_primary_target_boundaries() -> void:
	const NAME: String = "04_主目标边界"
	var visual: _StubVisual = _StubVisual.new()
	var extra: _StubVisual = _StubVisual.new()

	var single_sel := Node2D.new()
	var single_root := Node2D.new()
	var single: RefCounted = _ResultScript.for_direct_visual(single_sel, visual, single_root)
	_check(NAME, single.get_primary_target() == visual, "SINGLE 主目标应为唯一目标。")

	var multi_sel := Node2D.new()
	var multi_root := Node2D.new()
	var multiple: RefCounted = _ResultScript.for_component(multi_sel, multi_root, [visual, extra], [])
	_check(NAME, multiple.get_primary_target() == null, "MULTIPLE 主目标应为 null。")

	var none_sel := Node2D.new()
	var none_root := Node2D.new()
	var none: RefCounted = _ResultScript.for_component(none_sel, none_root, [], [])
	_check(NAME, none.get_primary_target() == null, "NO_TARGET 主目标应为 null。")
	_check(NAME, none.get_status() == _ResultScript.Status.NO_TARGET, "零目标应派生 NO_TARGET。")
	_check(NAME, none.get_reason_code() == "component_has_no_visual", "零目标原因码应为 component_has_no_visual。")

	var unsup_sel := Node2D.new()
	var unsupported: RefCounted = _ResultScript.for_unsupported(unsup_sel, "no_component_boundary")
	_check(NAME, unsupported.get_primary_target() == null, "UNSUPPORTED 主目标应为 null。")
	_check(NAME, unsupported.get_targets().is_empty(), "UNSUPPORTED 不得伪造目标。")

	single_sel.free()
	single_root.free()
	multi_sel.free()
	multi_root.free()
	none_sel.free()
	none_root.free()
	unsup_sel.free()
	visual.free()
	extra.free()


## 5. targets 构造复制：构造后修改原数组不影响内部。
func _test_05_targets_construct_copy() -> void:
	const NAME: String = "05_构造复制目标"
	var v1: _StubVisual = _StubVisual.new()
	var v2: _StubVisual = _StubVisual.new()
	var appended: _StubVisual = _StubVisual.new()
	var original: Array = [v1, v2]
	var r: RefCounted = _ResultScript.for_component(Node2D.new(), Node2D.new(), original, [])
	original.append(appended)
	_check(NAME, r.get_targets().size() == 2, "构造后修改原数组不应影响内部目标集合。")
	_check(NAME, r.get_targets()[0] == v1 and r.get_targets()[1] == v2, "内部目标应保持构造时顺序。")
	r.get_selected_node().free()
	r.get_component_root().free()
	v1.free()
	v2.free()
	appended.free()


## 6. get_targets 返回副本：修改返回数组不影响内部。
func _test_06_get_targets_returns_copy() -> void:
	const NAME: String = "06_目标getter副本"
	var v1: _StubVisual = _StubVisual.new()
	var v2: _StubVisual = _StubVisual.new()
	var appended: _StubVisual = _StubVisual.new()
	var r: RefCounted = _ResultScript.for_component(Node2D.new(), Node2D.new(), [v1, v2], [])
	var snapshot: Array = r.get_targets()
	snapshot.clear()
	snapshot.append(appended)
	_check(NAME, r.get_targets().size() == 2, "修改 getter 返回数组不应影响内部。")
	_check(NAME, r.get_targets()[0] == v1 and r.get_targets()[1] == v2, "内部目标应保持不变。")
	r.get_selected_node().free()
	r.get_component_root().free()
	v1.free()
	v2.free()
	appended.free()


## 7. get_ignored_nodes 返回副本：修改返回数组不影响内部。
func _test_07_ignored_nodes_returns_copy() -> void:
	const NAME: String = "07_忽略getter副本"
	var ignored_a := Node2D.new()
	var ignored_b := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	var r: RefCounted = _ResultScript.for_component(Node2D.new(), Node2D.new(), [visual], [ignored_a, ignored_b])
	var snapshot: Array = r.get_ignored_nodes()
	_check(NAME, snapshot.size() == 2, "忽略集合应含两个。")
	snapshot.clear()
	_check(NAME, r.get_ignored_nodes().size() == 2, "修改 getter 返回数组不应影响内部忽略集合。")
	r.get_selected_node().free()
	r.get_component_root().free()
	visual.free()
	ignored_a.free()
	ignored_b.free()


## 8. reason_code 保持：各工厂原因码稳定；UNSUPPORTED 自定义原因码保留。
func _test_08_reason_code_stable() -> void:
	const NAME: String = "08_原因码稳定"
	_check(NAME, _ResultScript.for_no_selection().get_reason_code() == "no_selection", "no_selection 原因码。")
	_check(NAME, _ResultScript.for_unsupported(null, "no_component_boundary").get_reason_code() == "no_component_boundary", "UNSUPPORTED 应保留自定义原因码。")
	var single_sel := Node2D.new()
	var single_root := Node2D.new()
	var single_visual: _StubVisual = _StubVisual.new()
	var single: RefCounted = _ResultScript.for_direct_visual(single_sel, single_visual, single_root)
	_check(NAME, single.get_reason_code() == "direct_visual", "direct_visual 原因码。")
	var one_sel := Node2D.new()
	var one_root := Node2D.new()
	var one_visual: _StubVisual = _StubVisual.new()
	var one: RefCounted = _ResultScript.for_component(one_sel, one_root, [one_visual], [])
	_check(NAME, one.get_reason_code() == "component_single_visual", "component_single_visual 原因码。")
	_check(NAME, one.get_status() == _ResultScript.Status.SINGLE_TARGET, "单目标组件应派生 SINGLE_TARGET。")
	single_sel.free()
	single_root.free()
	single_visual.free()
	one_sel.free()
	one_root.free()
	one_visual.free()


## 9. 不修改节点：构造结果并调用全部 getter 后，节点位置、子节点数、Profile 不变。
func _test_09_does_not_mutate_nodes() -> void:
	const NAME: String = "09_结果不修改节点"
	var root := Node2D.new()
	root.position = Vector2(12, 34)
	var visual: _StubVisual = _StubVisual.new()
	visual.position = Vector2(5, 6)
	var profile: _ObjectVisualProfile = _make_profile()
	visual.visual_profile = profile
	var root_children_before: int = root.get_child_count()
	var visual_children_before: int = visual.get_child_count()
	var root_pos_before: Vector2 = root.position
	var visual_pos_before: Vector2 = visual.position
	var default_before: StringName = profile.default_state_id
	var state_id_before: StringName = profile.states[0].state_id
	var texture_before: Texture2D = profile.states[0].world_texture
	var ignored_node := Node2D.new()

	var r: RefCounted = _ResultScript.for_component(root, root, [visual], [ignored_node])
	# 调用全部 getter，确认无副作用。
	r.get_status()
	r.get_selected_node()
	r.get_component_root()
	r.get_targets()
	r.get_primary_target()
	r.get_ignored_nodes()
	r.get_reason_code()

	_check(NAME, root.get_child_count() == root_children_before, "不应增删组件根子节点。")
	_check(NAME, visual.get_child_count() == visual_children_before, "不应增删视觉子节点。")
	_check(NAME, root.position == root_pos_before, "不应修改组件根位置。")
	_check(NAME, visual.position == visual_pos_before, "不应修改视觉节点位置。")
	_check(NAME, visual.visual_profile == profile, "不应替换 visual_profile。")
	_check(NAME, profile.default_state_id == default_before, "不应修改 default_state_id。")
	_check(NAME, profile.states[0].state_id == state_id_before, "不应修改 state_id。")
	_check(NAME, profile.states[0].world_texture == texture_before, "不应修改 world_texture。")
	ignored_node.free()
	root.free()
	visual.free()


## 创建最小 Profile，供只读不变性测试使用。
func _make_profile() -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"default"
	state.world_texture = PlaceholderTexture2D.new()
	profile.default_state_id = &"default"
	profile.states = [state]
	return profile


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualTargetResult 测试摘要 ====")
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
