extends SceneTree

## VisualTargetResolver D4.5-A2 通用解析测试。
## 覆盖：null、直接视觉、组件边界、深层收集、嵌套隔离、多目标、EmissionPreview、复制组件、只读不变性、名称无关、无类型分支。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_art_profile/target/visual_target_resolver.gd"
)
const _ResultScript: GDScript = preload(
	"res://addons/light_speed_art_profile/target/visual_target_result.gd"
)
const _PluginScript: GDScript = preload(
	"res://addons/light_speed_art_profile/plugin.gd"
)
const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
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
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)

# 测试替身：避免依赖 ObjectVisualView 场景子节点。
class _StubVisual extends ObjectVisualView:
	func refresh_visual() -> void:
		pass

# 测试替身：用于构造正式预览节点。
class _StubPreview extends EmissionPreview:
	pass

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _resolver = _ResolverScript.new()


func _initialize() -> void:
	_test_01_plugin_and_dock_parse()
	_test_02_null_no_selection()
	_test_03_direct_visual_no_component()
	_test_04_direct_visual_inside_component()
	_test_05_component_root_deep_single()
	_test_06_inner_node_finds_component()
	_test_07_multiple_visuals()
	_test_08_nested_component_excluded()
	_test_09_nested_component_inner_resolves_self()
	_test_10_no_component_unsupported()
	_test_11_component_no_visual_no_target()
	_test_12_emission_preview_never_target()
	_test_13_select_preview_locates_component()
	_test_14_duplicate_components_independent()
	_test_15_multiple_order_stable()
	_test_16_resolve_does_not_mutate()
	_test_17_name_independent()
	_test_18_no_type_branches()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 插件入口与 Dock 场景可解析。
func _test_01_plugin_and_dock_parse() -> void:
	const NAME: String = "01_插件与Dock可解析"
	var dock = _DockScene.instantiate()
	_check(NAME, _PluginScript.source_code.contains("extends EditorPlugin"), "plugin.gd 应继承 EditorPlugin。")
	_check(NAME, dock is VBoxContainer, "Dock 场景根节点应为 VBoxContainer。")
	dock.free()


## 2. null 输入返回 NO_TARGET + no_selection。
func _test_02_null_no_selection() -> void:
	const NAME: String = "02_null无选择"
	var r: RefCounted = _resolver.resolve(null)
	_check(NAME, r.get_status() == _ResultScript.Status.NO_TARGET, "null 应为 NO_TARGET。")
	_check(NAME, r.get_reason_code() == "no_selection", "null 原因码应为 no_selection。")
	_check(NAME, r.get_primary_target() == null, "null 主目标应为 null。")


## 3. 直接选无组件祖先的 ObjectVisualView：SINGLE_TARGET + direct_visual，组件根为自身。
func _test_03_direct_visual_no_component() -> void:
	const NAME: String = "03_直接视觉无组件"
	var visual: _StubVisual = _StubVisual.new()
	var r: RefCounted = _resolver.resolve(visual)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == visual, "主目标应为自身。")
	_check(NAME, r.get_targets().size() == 1, "目标集合仅含自身。")
	_check(NAME, r.get_component_root() == visual, "无组件祖先时组件根可为自身。")
	_check(NAME, r.get_reason_code() == "direct_visual", "原因码应为 direct_visual。")
	visual.free()


## 4. 直接选组件内 ObjectVisualView：只返回该节点，不扩大到同组件其他视觉。
func _test_04_direct_visual_inside_component() -> void:
	const NAME: String = "04_直接视觉组件内"
	var comp: Node = _GridPlacedObject.new()
	var v1: _StubVisual = _StubVisual.new()
	var v2: _StubVisual = _StubVisual.new()
	comp.add_child(v1)
	comp.add_child(v2)
	var r: RefCounted = _resolver.resolve(v2)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "应为 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == v2, "主目标应为被选视觉。")
	_check(NAME, r.get_targets().size() == 1, "不应扩大到同组件其他视觉。")
	_check(NAME, r.get_targets()[0] == v2, "目标集合应仅含被选视觉。")
	_check(NAME, r.get_component_root() == comp, "组件根应为最近 GridPlacedObject。")
	comp.free()


## 5. 选择 GridPlacedObject 根，找到深层单个 View。
func _test_05_component_root_deep_single() -> void:
	const NAME: String = "05_组件根深层单视觉"
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


## 6. 选择组件内部普通节点，向上找到最近组件根并收集其视觉。
func _test_06_inner_node_finds_component() -> void:
	const NAME: String = "06_内部节点定位组件"
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


## 7. 组件含多个 View，返回 MULTIPLE_TARGETS，主目标为 null。
func _test_07_multiple_visuals() -> void:
	const NAME: String = "07_多视觉多目标"
	var comp: Node = _GridPlacedObject.new()
	var v1: _StubVisual = _StubVisual.new()
	var v2: _StubVisual = _StubVisual.new()
	comp.add_child(v1)
	comp.add_child(v2)
	var r: RefCounted = _resolver.resolve(comp)
	_check(NAME, r.get_status() == _ResultScript.Status.MULTIPLE_TARGETS, "应为 MULTIPLE_TARGETS。")
	_check(NAME, r.get_primary_target() == null, "多目标主目标应为 null。")
	_check(NAME, r.get_targets().size() == 2, "目标集合应含两个。")
	_check(NAME, r.get_reason_code() == "component_multiple_visuals", "原因码应为 component_multiple_visuals。")
	comp.free()


## 8. 嵌套 GridPlacedObject 的 View 不进入外层目标，且记入 ignored。
func _test_08_nested_component_excluded() -> void:
	const NAME: String = "08_嵌套隔离"
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


## 9. 选择嵌套组件内部节点，解析到嵌套组件本身而非外层。
func _test_09_nested_component_inner_resolves_self() -> void:
	const NAME: String = "09_嵌套内层自解析"
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


## 10. 无 GridPlacedObject 的普通节点返回 UNSUPPORTED + no_component_boundary。
func _test_10_no_component_unsupported() -> void:
	const NAME: String = "10_无组件不支持"
	var plain := Node2D.new()
	plain.add_child(Node2D.new())
	var r: RefCounted = _resolver.resolve(plain)
	_check(NAME, r.get_status() == _ResultScript.Status.UNSUPPORTED, "无组件边界应为 UNSUPPORTED。")
	_check(NAME, r.get_reason_code() == "no_component_boundary", "原因码应为 no_component_boundary。")
	_check(NAME, r.get_primary_target() == null, "UNSUPPORTED 主目标应为 null。")
	_check(NAME, r.get_targets().is_empty(), "UNSUPPORTED 不得伪造目标。")
	plain.free()


## 11. GridPlacedObject 没有 View 返回 NO_TARGET + component_has_no_visual。
func _test_11_component_no_visual_no_target() -> void:
	const NAME: String = "11_组件无视觉"
	var comp: Node = _GridPlacedObject.new()
	comp.add_child(Node2D.new())
	var r: RefCounted = _resolver.resolve(comp)
	_check(NAME, r.get_status() == _ResultScript.Status.NO_TARGET, "无视觉组件应为 NO_TARGET。")
	_check(NAME, r.get_reason_code() == "component_has_no_visual", "原因码应为 component_has_no_visual。")
	_check(NAME, r.get_primary_target() == null, "无视觉主目标应为 null。")
	comp.free()


## 12. EmissionPreview 永不进入 targets（选组件根与选 Preview 两种路径）。
func _test_12_emission_preview_never_target() -> void:
	const NAME: String = "12_预览永不入目标"
	var comp: Node = _GridPlacedObject.new()
	var visual: _StubVisual = _StubVisual.new()
	var preview: _StubPreview = _StubPreview.new()
	comp.add_child(visual)
	comp.add_child(preview)
	# 选组件根：targets 含正式视觉，不含 Preview。
	var r_root: RefCounted = _resolver.resolve(comp)
	_check(NAME, r_root.get_targets().has(visual), "组件根解析应含正式视觉。")
	_check(NAME, not r_root.get_targets().has(preview), "EmissionPreview 不得进入 targets（组件根路径）。")
	# 选 Preview：定位组件后 targets 仍不含 Preview。
	var r_preview: RefCounted = _resolver.resolve(preview)
	_check(NAME, not r_preview.get_targets().has(preview), "EmissionPreview 不得进入 targets（Preview 路径）。")
	_check(NAME, r_preview.get_targets().has(visual), "Preview 解析应定位到正式视觉。")
	comp.free()


## 13. 选择 EmissionPreview 自动定位所属组件正式视觉，Preview 不在目标列表。
func _test_13_select_preview_locates_component() -> void:
	const NAME: String = "13_选预览定位组件"
	var comp: Node = _GridPlacedObject.new()
	var visual: _StubVisual = _StubVisual.new()
	var preview: _StubPreview = _StubPreview.new()
	comp.add_child(visual)
	comp.add_child(preview)
	var r: RefCounted = _resolver.resolve(preview)
	_check(NAME, r.get_status() == _ResultScript.Status.SINGLE_TARGET, "选 Preview 应定位到 SINGLE_TARGET。")
	_check(NAME, r.get_primary_target() == visual, "主目标应为所属组件正式视觉。")
	_check(NAME, r.get_selected_node() == preview, "选中节点应保留为 Preview。")
	_check(NAME, r.get_component_root() == comp, "组件根应为 Preview 所属组件。")
	_check(NAME, not r.get_targets().has(preview), "Preview 不得出现在目标列表。")
	comp.free()


## 14. 两个复制组件分别解析到自身，不依赖 Node.name 作为身份。
func _test_14_duplicate_components_independent() -> void:
	const NAME: String = "14_复制组件独立"
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


## 15. 多目标顺序稳定，遵循场景树深度优先，不按 Node.name 排序。
func _test_15_multiple_order_stable() -> void:
	const NAME: String = "15_多目标顺序稳定"
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


## 16. 解析过程不修改节点树、位置、Profile。
func _test_16_resolve_does_not_mutate() -> void:
	const NAME: String = "16_解析只读"
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


## 17. 不依赖节点名称：重命名后解析结果不变。
func _test_17_name_independent() -> void:
	const NAME: String = "17_名称无关"
	var comp: Node = _GridPlacedObject.new()
	var visual: _StubVisual = _StubVisual.new()
	comp.add_child(visual)
	var r_before: RefCounted = _resolver.resolve(comp)
	# 重命名组件与视觉后再次解析，目标身份不变。
	comp.name = "RenamedComponent"
	visual.name = "RenamedVisual"
	var r_after: RefCounted = _resolver.resolve(comp)
	_check(NAME, r_after.get_primary_target() == visual, "重命名后应仍解析到同一视觉。")
	_check(NAME, r_after.get_primary_target() == r_before.get_primary_target(), "名称变化不应改变目标身份。")
	comp.free()


## 18. 不存在 EmitterConfigNode / Mirror / Crystal 等逐类型分支（静态源码搜索，剥离注释）。
func _test_18_no_type_branches() -> void:
	const NAME: String = "18_无类型分支"
	# 只检查实际代码：剥离全行注释，避免文档说明被误判为类型分支。
	var code: String = ""
	for line: String in _ResolverScript.source_code.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("#"):
			continue
		code += line + "\n"
	_check(NAME, not code.contains("is EmitterConfigNode"), "不得出现 EmitterConfigNode 类型分支。")
	_check(NAME, not code.contains("is EmitterVisual"), "不得出现 EmitterVisual 类型分支。")
	_check(NAME, not code.contains("is Mirror"), "不得出现 Mirror 类型分支。")
	_check(NAME, not code.contains("is Crystal"), "不得出现 Crystal 类型分支。")
	_check(NAME, not code.contains("is FixedEmitter"), "不得出现 FixedEmitter 类型分支。")
	_check(NAME, not code.contains("is BasicCrystal"), "不得出现 BasicCrystal 类型分支。")
	_check(NAME, not code.contains(".name ==") and not code.contains(".name !="), "不得用 Node.name 判断身份。")
	_check(NAME, not code.contains("get_name()"), "不得用 get_name() 判断身份。")
	_check(NAME, code.contains("is GridPlacedObject"), "应以 GridPlacedObject 作为通用组件边界。")
	_check(NAME, code.contains("is ObjectVisualView"), "应以 ObjectVisualView 作为正式视觉身份。")


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
	var group_count: int = 18
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualTargetResolver 测试摘要 ====")
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
