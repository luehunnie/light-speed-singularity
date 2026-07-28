extends SceneTree

## VisualTargetResolver D4.5-A2 组件边界测试（拆分自原 visual_target_resolver_test）。
## 覆盖：深层视觉收集、最近 GridPlacedObject 定位、嵌套组件隔离、复制组件独立解析、
##   稳定遍历顺序、解析不修改节点树。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_art_profile/target/visual_target_resolver.gd"
)
const _ResultScript: GDScript = preload(
	"res://addons/light_speed_art_profile/target/visual_target_result.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
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
var _resolver = _ResolverScript.new()


func _initialize() -> void:
	_test_01_component_root_deep_single()
	_test_02_inner_node_finds_component()
	_test_03_nested_component_excluded()
	_test_04_nested_component_inner_resolves_self()
	_test_05_duplicate_components_independent()
	_test_06_multiple_order_stable()
	_test_07_resolve_does_not_mutate()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 选择 GridPlacedObject 根，找到深层单个 View。
func _test_01_component_root_deep_single() -> void:
	const NAME: String = "01_组件根深层单视觉"
	var comp: Node = _GridPlacedObject.new()
	var middle := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	comp.add_child(middle)
	middle.add_child(visual)
	var r: RefCounted = _resolver.resolve(comp)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == visual, "应找到深层视觉。")
	_check(NAME, r.get_component_root() == comp, "组件根应为选中根。")
	_check(NAME, r.get_reason_code() == "component_single_visual", "原因码应为 component_single_visual。")
	comp.free()


## 2. 选择组件内部普通节点，向上找到最近组件根并收集其视觉。
func _test_02_inner_node_finds_component() -> void:
	const NAME: String = "02_内部节点定位组件"
	var comp: Node = _GridPlacedObject.new()
	var middle := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	comp.add_child(middle)
	middle.add_child(visual)
	var r: RefCounted = _resolver.resolve(middle)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == visual, "应定位到组件视觉。")
	_check(NAME, r.get_component_root() == comp, "组件根应为最近 GridPlacedObject 祖先。")
	comp.free()


## 3. 嵌套 GridPlacedObject 的 View 不进入外层目标，且记入 ignored。
func _test_03_nested_component_excluded() -> void:
	const NAME: String = "03_嵌套隔离"
	var outer: Node = _GridPlacedObject.new()
	var outer_visual: _StubVisual = _StubVisual.new()
	var inner: Node = _GridPlacedObject.new()
	var inner_visual: _StubVisual = _StubVisual.new()
	outer.add_child(outer_visual)
	outer.add_child(inner)
	inner.add_child(inner_visual)
	var r: RefCounted = _resolver.resolve(outer)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "外层应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == outer_visual, "外层主目标应为外层视觉。")
	_check(NAME, not r.get_targets().has(inner_visual), "嵌套组件视觉不应进入外层目标。")
	_check(NAME, r.get_targets().size() == 1, "外层目标集合仅含外层视觉。")
	_check(NAME, r.get_ignored_nodes().has(inner), "嵌套组件根应记入 ignored。")
	outer.free()


## 4. 选择嵌套组件内部节点，解析到嵌套组件本身而非外层。
func _test_04_nested_component_inner_resolves_self() -> void:
	const NAME: String = "04_嵌套内层自解析"
	var outer: Node = _GridPlacedObject.new()
	var inner: Node = _GridPlacedObject.new()
	var inner_visual: _StubVisual = _StubVisual.new()
	outer.add_child(inner)
	inner.add_child(inner_visual)
	# 选择内层视觉：直接视觉，组件根为内层。
	var r_direct: RefCounted = _resolver.resolve(inner_visual)
	_check(NAME, r_direct.get_component_root() == inner, "内层视觉组件根应为内层组件。")
	_check(NAME, r_direct.get_primary_target() == inner_visual, "内层视觉主目标应为自身。")
	# 选择内层普通节点：向上定位到内层组件。
	var middle := Node2D.new()
	inner.add_child(middle)
	var r_inner: RefCounted = _resolver.resolve(middle)
	_check(NAME, r_inner.get_component_root() == inner, "内层普通节点应定位到内层组件。")
	_check(NAME, r_inner.get_primary_target() == inner_visual, "内层组件应收集到内层视觉。")
	_check(NAME, not r_inner.get_targets().has(outer), "外层组件不应混入内层目标。")
	outer.free()


## 5. 两个复制组件分别解析到自身，不依赖 Node.name 作为身份。
func _test_05_duplicate_components_independent() -> void:
	const NAME: String = "05_复制组件独立"
	# 两组件同名、同结构，仅靠场景树位置区分身份。
	var comp_a: Node = _GridPlacedObject.new()
	comp_a.name = "Component"
	var visual_a: _StubVisual = _StubVisual.new()
	visual_a.name = "Visual"
	comp_a.add_child(visual_a)
	var comp_b: Node = _GridPlacedObject.new()
	comp_b.name = "Component"
	var visual_b: _StubVisual = _StubVisual.new()
	visual_b.name = "Visual"
	comp_b.add_child(visual_b)
	# 选 B 内部普通节点，应定位到 B 而非 A。
	var middle_b := Node2D.new()
	comp_b.add_child(middle_b)
	var r: RefCounted = _resolver.resolve(middle_b)
	_check(NAME, r.get_component_root() == comp_b, "应定位到复制组件 B。")
	_check(NAME, r.get_primary_target() == visual_b, "应解析到 B 的视觉，而非 A。")
	_check(NAME, r.get_primary_target() != visual_a, "不得错配到 A 的视觉。")
	# 相同 Profile 引用不影响目标身份。
	var shared_profile: _ObjectVisualProfile = _make_profile()
	visual_a.visual_profile = shared_profile
	visual_b.visual_profile = shared_profile
	var r_profile: RefCounted = _resolver.resolve(visual_b)
	_check(NAME, r_profile.get_primary_target() == visual_b, "相同 Profile 引用不应混淆目标身份。")
	comp_a.free()
	comp_b.free()


## 6. 多目标顺序稳定，遵循场景树深度优先，不按 Node.name 排序。
func _test_06_multiple_order_stable() -> void:
	const NAME: String = "06_多目标顺序稳定"
	var comp: Node = _GridPlacedObject.new()
	# 故意用逆序名称，验证不按名称排序。
	var v_z: _StubVisual = _StubVisual.new()
	v_z.name = "Z_visual"
	var v_a: _StubVisual = _StubVisual.new()
	v_a.name = "A_visual"
	var v_m: _StubVisual = _StubVisual.new()
	v_m.name = "M_visual"
	comp.add_child(v_z)
	comp.add_child(v_a)
	comp.add_child(v_m)
	var r1: RefCounted = _resolver.resolve(comp)
	var r2: RefCounted = _resolver.resolve(comp)
	_check(NAME, r1.get_targets().size() == 3, "应有三个目标。")
	_check(NAME, r1.get_targets()[0] == v_z, "顺序应遵循添加顺序[0]，不按名称。")
	_check(NAME, r1.get_targets()[1] == v_a, "顺序应遵循添加顺序[1]。")
	_check(NAME, r1.get_targets()[2] == v_m, "顺序应遵循添加顺序[2]。")
	_check(NAME, r2.get_targets() == r1.get_targets(), "两次解析顺序应一致。")
	comp.free()


## 7. 解析过程不修改节点树、位置、Profile。
func _test_07_resolve_does_not_mutate() -> void:
	const NAME: String = "07_解析只读"
	var comp: Node = _GridPlacedObject.new()
	comp.position = Vector2(12, 34)
	var visual: _StubVisual = _StubVisual.new()
	visual.position = Vector2(5, 6)
	var profile: _ObjectVisualProfile = _make_profile()
	visual.visual_profile = profile
	comp.add_child(visual)
	var comp_children_before: int = comp.get_child_count()
	var visual_children_before: int = visual.get_child_count()
	var comp_pos_before: Vector2 = comp.position
	var visual_pos_before: Vector2 = visual.position
	var state_id_before: StringName = profile.states[0].state_id
	var texture_before: Texture2D = profile.states[0].world_texture
	var r: RefCounted = _resolver.resolve(comp)
	_check(NAME, r.get_primary_target() == visual, "前置解析应成功。")
	_check(NAME, comp.get_child_count() == comp_children_before, "不应增删组件子节点。")
	_check(NAME, visual.get_child_count() == visual_children_before, "不应增删视觉子节点。")
	_check(NAME, comp.position == comp_pos_before, "不应修改组件位置。")
	_check(NAME, visual.position == visual_pos_before, "不应修改视觉位置。")
	_check(NAME, visual.visual_profile == profile, "不应替换 visual_profile。")
	_check(NAME, profile.states[0].state_id == state_id_before, "不应修改 state_id。")
	_check(NAME, profile.states[0].world_texture == texture_before, "不应修改 world_texture。")
	comp.free()


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
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualTargetResolver 组件边界测试摘要 ====")
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
