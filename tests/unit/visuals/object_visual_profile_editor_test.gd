extends SceneTree

## ObjectVisualProfile / VisualStateTexture D3C-0.6 编辑器可实例化定向测试。
## 覆盖：两个 Resource 标注 @tool 后可在编辑器中实例化与调用、字段保存、
##   state_id→default_state_id→null 回退、drag 缺失回退同状态 world、空 Profile 安全、
##   @tool Profile 通过 ObjectVisualView 守卫并解析非空纹理、两份现有 .tres 只读加载可调用且内容不变。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：--script 模式下 Engine.is_editor_hint() 为 false，无法真正模拟编辑器帧；
##   此处以“脚本含 @tool + can_instantiate() + 方法可调用”作为编辑器可实例化契约的等价验证，
##   真实编辑器内实例化由 @tool 注解与 headless 编辑器解析共同保证。

const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
const _SCENE: PackedScene = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.tscn"
)
const _BASIC_CRYSTAL_TRES: String = "res://assets/visual_profiles/basic_crystal_visuals.tres"
const _MIRROR_TRES: String = "res://assets/visual_profiles/single_cell_mirror_visuals.tres"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 两份现有 .tres 的磁盘内容基线，用于测试前后内容一致性比对。
var _tres_baseline: Dictionary = {}


func _initialize() -> void:
	_capture_tres_baseline()
	_test_01_profile_tool_instantiable()
	_test_02_state_texture_tool_instantiable()
	_test_03_profile_methods_callable()
	_test_04_state_texture_stores_fields()
	_test_05_profile_returns_correct_state()
	_test_06_fallback_to_default()
	_test_07_drag_falls_back_to_world()
	_test_08_empty_profile_safe()
	_test_09_view_resolves_texture_with_tool_profile()
	_test_10_basic_crystal_tres_loads()
	_test_11_mirror_tres_loads()
	_test_12_tres_unchanged()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. ObjectVisualProfile 标注 @tool、脚本可实例化、.new() 可创建。
func _test_01_profile_tool_instantiable() -> void:
	const NAME: String = "01_Profile_@tool可实例化"
	var src: String = _ObjectVisualProfile.source_code
	_check(NAME, src.contains("@tool"), "ObjectVisualProfile 应标注 @tool。")
	var script: Script = _ObjectVisualProfile
	_check(NAME, script.can_instantiate(), "ObjectVisualProfile 脚本应 can_instantiate。")
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	_check(NAME, profile is _ObjectVisualProfile, ".new() 应返回 ObjectVisualProfile 实例。")
	# Resource 为 RefCounted，由引用计数管理，不手动 free。


## 2. VisualStateTexture 标注 @tool、脚本可实例化、.new() 可创建。
func _test_02_state_texture_tool_instantiable() -> void:
	const NAME: String = "02_StateTexture_@tool可实例化"
	var src: String = _VisualStateTexture.source_code
	_check(NAME, src.contains("@tool"), "VisualStateTexture 应标注 @tool。")
	var script: Script = _VisualStateTexture
	_check(NAME, script.can_instantiate(), "VisualStateTexture 脚本应 can_instantiate。")
	var state: _VisualStateTexture = _VisualStateTexture.new()
	_check(NAME, state is _VisualStateTexture, ".new() 应返回 VisualStateTexture 实例。")
	# Resource 为 RefCounted，由引用计数管理，不手动 free。


## 3. ObjectVisualProfile 的查询/校验方法可调用且语义正确。
func _test_03_profile_methods_callable() -> void:
	const NAME: String = "03_Profile方法可调用"
	var profile: _ObjectVisualProfile = _make_profile(&"default", _make_texture(), null)
	_check(NAME, profile.has_state(&"default") == true, "has_state(default) 应为 true。")
	_check(NAME, profile.get_world_texture(&"default") != null, "get_world_texture(default) 应非空。")
	_check(NAME, profile.get_drag_texture(&"default") != null, "get_drag_texture(default) 应回退 world，非空。")
	_check(NAME, profile.validate_profile().is_empty(), "合法 profile 的 validate_profile 应无问题。")
	# Resource 为 RefCounted，不手动 free。


## 4. 内存创建的 VisualStateTexture 能保存 state_id、world_texture、drag_texture。
func _test_04_state_texture_stores_fields() -> void:
	const NAME: String = "04_StateTexture保存字段"
	var wt: PlaceholderTexture2D = _make_texture()
	var dt: PlaceholderTexture2D = _make_texture()
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"lit"
	state.world_texture = wt
	state.drag_texture = dt
	_check(NAME, state.state_id == &"lit", "state_id 应为 lit。")
	_check(NAME, state.world_texture == wt, "world_texture 应为 wt。")
	_check(NAME, state.drag_texture == dt, "drag_texture 应为 dt。")
	_check(NAME, state.validate_state().is_empty(), "合法 state 的 validate_state 应无问题。")
	# Resource 为 RefCounted，不手动 free。


## 5. Profile 能按 state_id 返回对应状态纹理。
func _test_05_profile_returns_correct_state() -> void:
	const NAME: String = "05_Profile按state_id返回状态"
	var tex_a: PlaceholderTexture2D = _make_texture()
	var tex_b: PlaceholderTexture2D = _make_texture()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"a"
	profile.states = [_make_state(&"a", tex_a, null), _make_state(&"b", tex_b, null)]
	_check(NAME, profile.get_world_texture(&"a") == tex_a, "a 应返回 tex_a。")
	_check(NAME, profile.get_world_texture(&"b") == tex_b, "b 应返回 tex_b。")
	_check(NAME, profile.has_state(&"c") == false, "c 不存在应为 false。")
	# Resource 为 RefCounted，不手动 free。


## 6. 未命中 state_id 时回退 default_state_id。
func _test_06_fallback_to_default() -> void:
	const NAME: String = "06_未命中回退default"
	var tex_default: PlaceholderTexture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile(&"default", tex_default, null)
	_check(NAME, profile.get_world_texture(&"nonexistent") == tex_default, "未知 id 应回退 default 纹理。")
	_check(NAME, profile.get_world_texture(&"") == tex_default, "空 id 应回退 default 纹理。")
	# Resource 为 RefCounted，不手动 free。


## 7. drag_texture 缺失时回退同一状态的 world_texture。
func _test_07_drag_falls_back_to_world() -> void:
	const NAME: String = "07_drag缺失回退world"
	var world_tex: PlaceholderTexture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile(&"default", world_tex, null)
	_check(NAME, profile.get_drag_texture(&"default") == world_tex, "drag 缺失应回退同状态 world 纹理。")
	# Resource 为 RefCounted，不手动 free。


## 8. 空 Profile（states 为空）安全：查询返回 null、校验报告问题、不崩溃。
func _test_08_empty_profile_safe() -> void:
	const NAME: String = "08_空Profile安全"
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"default"
	profile.states = []
	_check(NAME, profile.get_world_texture(&"default") == null, "空 states 查询应返回 null。")
	_check(NAME, profile.get_world_texture(&"") == null, "空 id 空 states 应返回 null。")
	_check(NAME, profile.has_state(&"default") == false, "空 states 的 has_state 应为 false。")
	var problems: PackedStringArray = profile.validate_profile()
	_check(NAME, not problems.is_empty(), "空 states 的 validate_profile 应报告问题。")
	# Resource 为 RefCounted，不手动 free。


## 9. ObjectVisualView 设置正常 @tool Profile 后能解析非空纹理，且守卫契约 _is_profile_callable 为 true。
func _test_09_view_resolves_texture_with_tool_profile() -> void:
	const NAME: String = "09_视图设置@tool_Profile解析非空纹理"
	var world_tex: PlaceholderTexture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile(&"default", world_tex, null)
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(profile)
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == world_tex, "ready 后 set_profile 应解析出 world 纹理。")
	# 守卫契约：@tool Profile 可调用，_is_profile_callable 为 true，编辑器守卫不会吞掉纹理。
	_check(NAME, view._is_profile_callable() == true, "@tool Profile 应通过 _is_profile_callable 守卫。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 10. basic_crystal_visuals.tres 可只读加载并调用 Profile 方法。
func _test_10_basic_crystal_tres_loads() -> void:
	const NAME: String = "10_basic_crystal_tres只读加载"
	var profile: _ObjectVisualProfile = load(_BASIC_CRYSTAL_TRES) as _ObjectVisualProfile
	_check(NAME, profile != null, "basic_crystal_visuals.tres 应加载为 ObjectVisualProfile。")
	if profile == null:
		return
	_check(NAME, profile.has_state(&"unlit") == true, "应含 unlit 状态。")
	_check(NAME, profile.has_state(&"lit") == true, "应含 lit 状态。")
	_check(NAME, profile.get_world_texture(&"unlit") != null, "unlit 的 world_texture 应非空。")
	_check(NAME, profile.get_world_texture(&"lit") != null, "lit 的 world_texture 应非空。")
	_check(NAME, profile.get_world_texture(&"unknown") == profile.get_world_texture(&"unlit"), "未知 id 应回退 default(unlit)。")
	_check(NAME, profile.validate_profile().is_empty(), "该 .tres 的 validate_profile 应无问题。")
	# 加载得到的共享资源不 free，交由资源系统管理。


## 11. single_cell_mirror_visuals.tres 可只读加载并调用 Profile 方法。
func _test_11_mirror_tres_loads() -> void:
	const NAME: String = "11_mirror_tres只读加载"
	var profile: _ObjectVisualProfile = load(_MIRROR_TRES) as _ObjectVisualProfile
	_check(NAME, profile != null, "single_cell_mirror_visuals.tres 应加载为 ObjectVisualProfile。")
	if profile == null:
		return
	_check(NAME, profile.has_state(&"slash") == true, "应含 slash 状态。")
	_check(NAME, profile.has_state(&"backslash") == true, "应含 backslash 状态。")
	_check(NAME, profile.get_world_texture(&"slash") != null, "slash 的 world_texture 应非空。")
	_check(NAME, profile.get_world_texture(&"backslash") != null, "backslash 的 world_texture 应非空。")
	_check(NAME, profile.get_world_texture(&"unknown") == profile.get_world_texture(&"slash"), "未知 id 应回退 default(slash)。")
	_check(NAME, profile.validate_profile().is_empty(), "该 .tres 的 validate_profile 应无问题。")


## 12. 两份现有 .tres 在测试运行前后磁盘内容未发生变化。
func _test_12_tres_unchanged() -> void:
	const NAME: String = "12_两份tres内容未变"
	for path: String in _tres_baseline.keys():
		var now: String = FileAccess.get_file_as_string(path)
		_check(NAME, now == _tres_baseline[path], "%s 在测试前后内容应一致。" % path)


# ===== 辅助 =====

## 创建带单个状态的 profile；drag_tex 为 null 表示该状态无拖拽纹理。
func _make_profile(state_id: StringName, world_tex: Texture2D, drag_tex: Texture2D) -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = state_id
	profile.states = [_make_state(state_id, world_tex, drag_tex)]
	return profile


## 创建单个 VisualStateTexture。
func _make_state(state_id: StringName, world_tex: Texture2D, drag_tex: Texture2D) -> _VisualStateTexture:
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = state_id
	state.world_texture = world_tex
	state.drag_texture = drag_tex
	return state


## 创建可区分的占位纹理。
func _make_texture() -> PlaceholderTexture2D:
	var tex: PlaceholderTexture2D = PlaceholderTexture2D.new()
	tex.size = Vector2i(32, 32)
	return tex


## 记录两份现有 .tres 的磁盘内容基线，供测试结束后比对。
func _capture_tres_baseline() -> void:
	_tres_baseline[_BASIC_CRYSTAL_TRES] = FileAccess.get_file_as_string(_BASIC_CRYSTAL_TRES)
	_tres_baseline[_MIRROR_TRES] = FileAccess.get_file_as_string(_MIRROR_TRES)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 12
	var passed_checks: int = _checks - _failures.size()
	print("==== ObjectVisualProfile 编辑器可实例化测试摘要 ====")
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
