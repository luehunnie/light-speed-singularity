extends SceneTree

## VisualTargetResolver D4.5-A 只读解析测试。
## 覆盖：正式 ObjectVisualView 自身、直属唯一视觉、EmitterVisual 与 EmissionPreview 并存、空与歧义边界。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_art_profile/visual_target_resolver.gd"
)
const _PluginScript: GDScript = preload(
	"res://addons/light_speed_art_profile/plugin.gd"
)
const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/art_profile_dock.tscn"
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
const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
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
	_test_02_direct_visual_returns_self()
	_test_03_parent_single_direct_visual()
	_test_04_emitter_ignores_preview()
	_test_05_direct_preview_returns_null()
	_test_06_no_visual_returns_null()
	_test_07_two_direct_visuals_ambiguous()
	_test_08_grandchild_not_scanned()
	_test_09_null_returns_null()
	_test_10_resolve_does_not_mutate()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 插件入口与 Dock 场景可解析。
func _test_01_plugin_and_dock_parse() -> void:
	const NAME: String = "01_插件与Dock可解析"
	var dock = _DockScene.instantiate()
	_check(NAME, _PluginScript.source_code.contains("extends EditorPlugin"), "plugin.gd 应继承 EditorPlugin。")
	_check(NAME, dock is VBoxContainer, "Dock 场景根节点应为 VBoxContainer。")
	dock.free()


## 2. 直接选 ObjectVisualView 返回自身。
func _test_02_direct_visual_returns_self() -> void:
	const NAME: String = "01_直接选择视觉"
	var visual: _StubVisual = _StubVisual.new()
	_check(NAME, _resolver.resolve(visual) == visual, "应返回自身。")
	visual.free()


## 3. 父节点只有一个直属视觉时解析成功。
func _test_03_parent_single_direct_visual() -> void:
	const NAME: String = "02_直属唯一视觉"
	var parent := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	parent.add_child(visual)
	_check(NAME, _resolver.resolve(parent) == visual, "应返回唯一直属 ObjectVisualView。")
	parent.free()


## 4. EmitterVisual 与 EmissionPreview 并存时只返回正式视觉。
func _test_04_emitter_ignores_preview() -> void:
	const NAME: String = "03_发射器排除预览"
	var emitter: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	emitter.add_child(visual)
	emitter.add_child(preview)
	_check(NAME, _resolver.resolve(emitter) == visual, "应返回 EmitterVisual，不返回 EmissionPreview。")
	emitter.free()


## 5. 直接选择 EmissionPreview 返回 null。
func _test_05_direct_preview_returns_null() -> void:
	const NAME: String = "04_直接预览为空"
	var preview: _StubPreview = _StubPreview.new()
	_check(NAME, _resolver.resolve(preview) == null, "EmissionPreview 不是正式视觉。")
	preview.free()


## 6. 无正式视觉节点返回 null。
func _test_06_no_visual_returns_null() -> void:
	const NAME: String = "05_无视觉为空"
	var node := Node2D.new()
	node.add_child(Node2D.new())
	_check(NAME, _resolver.resolve(node) == null, "无直属 ObjectVisualView 应返回 null。")
	node.free()


## 7. 两个直属 ObjectVisualView 歧义返回 null。
func _test_07_two_direct_visuals_ambiguous() -> void:
	const NAME: String = "06_多个直属视觉歧义"
	var parent := Node2D.new()
	parent.add_child(_StubVisual.new())
	parent.add_child(_StubVisual.new())
	_check(NAME, _resolver.resolve(parent) == null, "多个直属视觉不得随意选第一个。")
	parent.free()


## 8. 只有孙级 ObjectVisualView 时不递归解析。
func _test_08_grandchild_not_scanned() -> void:
	const NAME: String = "07_不递归孙级"
	var parent := Node2D.new()
	var child := Node2D.new()
	var visual: _StubVisual = _StubVisual.new()
	child.add_child(visual)
	parent.add_child(child)
	_check(NAME, _resolver.resolve(parent) == null, "孙级视觉不应被解析。")
	parent.free()


## 9. null 输入返回 null。
func _test_09_null_returns_null() -> void:
	const NAME: String = "08_null为空"
	_check(NAME, _resolver.resolve(null) == null, "null 输入应返回 null。")


## 10. 解析过程不修改节点结构、位置或 Profile。
func _test_10_resolve_does_not_mutate() -> void:
	const NAME: String = "09_解析只读"
	var parent := Node2D.new()
	parent.position = Vector2(12, 34)
	var visual: _StubVisual = _StubVisual.new()
	visual.position = Vector2(5, 6)
	var profile: _ObjectVisualProfile = _make_profile()
	visual.visual_profile = profile
	parent.add_child(visual)
	var parent_children_before: int = parent.get_child_count()
	var visual_children_before: int = visual.get_child_count()
	var parent_position_before: Vector2 = parent.position
	var visual_position_before: Vector2 = visual.position
	var state_id_before: StringName = profile.states[0].state_id
	var texture_before: Texture2D = profile.states[0].world_texture
	var resolved: ObjectVisualView = _resolver.resolve(parent)
	_check(NAME, resolved == visual, "前置解析应成功。")
	_check(NAME, parent.get_child_count() == parent_children_before, "不应增删父节点子节点。")
	_check(NAME, visual.get_child_count() == visual_children_before, "不应增删视觉子节点。")
	_check(NAME, parent.position == parent_position_before, "不应修改父节点位置。")
	_check(NAME, visual.position == visual_position_before, "不应修改视觉节点位置。")
	_check(NAME, visual.visual_profile == profile, "不应替换 visual_profile。")
	_check(NAME, profile.default_state_id == &"default", "不应修改 default_state_id。")
	_check(NAME, profile.states[0].state_id == state_id_before, "不应修改 state_id。")
	_check(NAME, profile.states[0].world_texture == texture_before, "不应修改 world_texture。")
	parent.free()


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
	var group_count: int = 10
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
