extends SceneTree

## ObjectVisualView D3C-0.5 生命周期定向自动测试。
## 覆盖：@tool Node2D、_ready 前各 setter 安全、_ready 后统一应用此前保存状态、
##   空 profile 安全、state_id→default_state_id→null 回退顺序不变、drag 缺纹理回退 world、
##   反馈覆盖语义、重复刷新稳定、无 _process、无禁止依赖、不加载主场景。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 空 profile 与缺纹理用例会产生预期 push_warning，不计入失败。

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

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_is_tool_node2d()
	_test_02_pre_ready_set_profile_safe()
	_test_03_pre_ready_set_content_state_safe()
	_test_04_pre_ready_set_display_mode_safe()
	_test_05_pre_ready_set_feedback_safe()
	_test_06_pre_ready_set_visual_visible_safe()
	_test_07_tree_enter_applies_saved_state()
	_test_08_post_ready_set_profile_refreshes()
	_test_09_empty_profile_safe()
	_test_10_state_fallback_order()
	_test_11_drag_falls_back_to_world()
	_test_12_feedback_semantics()
	_test_13_repeat_refresh_stable()
	_test_14_no_process()
	_test_15_no_forbidden_dependencies()
	_test_16_no_main_scene_loaded()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. ObjectVisualView 为 @tool 的 Node2D。
func _test_01_is_tool_node2d() -> void:
	const NAME: String = "01_@tool_Node2D"
	var src: String = _ObjectVisualView.source_code
	_check(NAME, src.contains("@tool"), "ObjectVisualView 应标注 @tool。")
	var view = _SCENE.instantiate()
	_check(NAME, view is Node2D, "ObjectVisualView 应为 Node2D。")
	view.free()


## 2. _ready 前 set_profile 不报错、不访问子节点、保存 profile。
func _test_02_pre_ready_set_profile_safe() -> void:
	const NAME: String = "02_ready前set_profile安全"
	var view = _SCENE.instantiate()
	var profile: _ObjectVisualProfile = _make_profile(&"default", _make_texture(), null)
	view.set_profile(profile)  # _ready 未调用，子节点未缓存
	_check(NAME, view.visual_profile == profile, "set_profile 应保存 profile。")
	_check(NAME, view.get_child_count() == 4, "不应增删子节点，实际 %d。" % [view.get_child_count()])
	view.free()


## 3. _ready 前 set_content_state 不报错并保存状态。
func _test_03_pre_ready_set_content_state_safe() -> void:
	const NAME: String = "03_ready前set_content_state安全"
	var view = _SCENE.instantiate()
	view.set_content_state(&"lit")
	_check(NAME, view.get_content_state() == &"lit", "set_content_state 应保存 lit。")
	view.free()


## 4. _ready 前 set_display_mode 不报错并保存模式。
func _test_04_pre_ready_set_display_mode_safe() -> void:
	const NAME: String = "04_ready前set_display_mode安全"
	var view = _SCENE.instantiate()
	view.set_display_mode(_ObjectVisualView.DisplayMode.DRAG_PREVIEW)
	_check(NAME, view.get_display_mode() == _ObjectVisualView.DisplayMode.DRAG_PREVIEW, "set_display_mode 应保存 DRAG_PREVIEW。")
	view.free()


## 5. _ready 前 set_feedback 不报错并保存反馈。
func _test_05_pre_ready_set_feedback_safe() -> void:
	const NAME: String = "05_ready前set_feedback安全"
	var view = _SCENE.instantiate()
	view.set_feedback(_ObjectVisualView.FeedbackState.VALID)
	_check(NAME, view.get_feedback() == _ObjectVisualView.FeedbackState.VALID, "set_feedback 应保存 VALID。")
	view.free()


## 6. _ready 前 set_visual_visible 不报错并设置根节点 visible。
func _test_06_pre_ready_set_visual_visible_safe() -> void:
	const NAME: String = "06_ready前set_visual_visible安全"
	var view = _SCENE.instantiate()
	view.set_visual_visible(false)
	_check(NAME, view.visible == false, "set_visual_visible 应将 visible 置为 false。")
	view.free()


## 7. 进入 SceneTree 并 _ready 后，一次性应用此前保存的全部状态。
func _test_07_tree_enter_applies_saved_state() -> void:
	const NAME: String = "07_进入树后应用保存状态"
	var world_tex: PlaceholderTexture2D = _make_texture()
	var drag_tex: PlaceholderTexture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile(&"lit", world_tex, drag_tex)
	var view = _SCENE.instantiate()
	# _ready 前连续设置 profile / 内容状态 / 显示模式 / 反馈，全部只保存不访问子节点。
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.set_display_mode(_ObjectVisualView.DisplayMode.DRAG_PREVIEW)
	view.set_feedback(_ObjectVisualView.FeedbackState.VALID)
	root.add_child(view)
	view._ready()  # 缓存子节点并统一刷新
	var artwork: TextureRect = view.get_node("Artwork")
	var overlay: ColorRect = view.get_node("FeedbackOverlay")
	_check(NAME, artwork.texture == drag_tex, "_ready 后应应用 DRAG_PREVIEW 的 drag 纹理。")
	_check(NAME, overlay.visible == true, "_ready 后 VALID 反馈覆盖层应可见。")
	_check(NAME, artwork.self_modulate == Color.WHITE, "VALID 下 Artwork 应保持原色。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 8. _ready 后 set_profile 正常刷新纹理。
func _test_08_post_ready_set_profile_refreshes() -> void:
	const NAME: String = "08_ready后set_profile刷新"
	var tex_a: PlaceholderTexture2D = _make_texture()
	var tex_b: PlaceholderTexture2D = _make_texture()
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(_make_profile(&"default", tex_a, null))
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == tex_a, "ready 后 set_profile 应刷新为 tex_a。")
	view.set_profile(_make_profile(&"default", tex_b, null))
	_check(NAME, artwork.texture == tex_b, "再次 set_profile 应刷新为 tex_b。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 9. 空 profile 安全：Artwork 纹理置 null，重复刷新不崩溃。
func _test_09_empty_profile_safe() -> void:
	const NAME: String = "09_空profile安全"
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(null)
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == null, "空 profile 时 Artwork 纹理应为 null。")
	view.refresh_visual()
	view.set_content_state(&"anything")
	_check(NAME, artwork.texture == null, "空 profile 下重复刷新与改状态仍为 null。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 10. state_id → default_state_id → null 既有回退顺序不变。
func _test_10_state_fallback_order() -> void:
	const NAME: String = "10_状态回退顺序"
	var tex_default: PlaceholderTexture2D = _make_texture()
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(_make_profile(&"default", tex_default, null))
	var artwork: TextureRect = view.get_node("Artwork")
	view.set_content_state(&"nonexistent")
	_check(NAME, artwork.texture == tex_default, "未知 state_id 应回退到 default 纹理。")
	view.set_content_state(&"")
	_check(NAME, artwork.texture == tex_default, "空 state_id 应回退到 default 纹理。")
	# default_state_id 在 states 中不存在 → null。
	var profile_no_match: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile_no_match.default_state_id = &"ghost"
	profile_no_match.states = []
	view.set_profile(profile_no_match)
	_check(NAME, artwork.texture == null, "default 不存在时应回退到 null。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 11. drag 缺纹理仍回退到同一状态的 world 纹理。
func _test_11_drag_falls_back_to_world() -> void:
	const NAME: String = "11_drag缺纹理回退world"
	var world_tex: PlaceholderTexture2D = _make_texture()
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(_make_profile(&"default", world_tex, null))
	view.set_display_mode(_ObjectVisualView.DisplayMode.DRAG_PREVIEW)
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == world_tex, "drag 缺纹理应回退到同一状态 world 纹理。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 12. feedback 覆盖效果保持现有语义。
func _test_12_feedback_semantics() -> void:
	const NAME: String = "12_反馈语义"
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	var artwork: TextureRect = view.get_node("Artwork")
	var overlay: ColorRect = view.get_node("FeedbackOverlay")
	view.set_feedback(_ObjectVisualView.FeedbackState.VALID)
	_check(NAME, overlay.visible == true and artwork.self_modulate == Color.WHITE, "VALID：覆盖层可见且 Artwork 原色。")
	view.set_feedback(_ObjectVisualView.FeedbackState.INVALID)
	_check(NAME, overlay.visible == true and overlay.color.is_equal_approx(Color(1.0, 0.18, 0.18, 0.5)), "INVALID：红色覆盖层可见。")
	view.set_feedback(_ObjectVisualView.FeedbackState.DISABLED)
	_check(NAME, overlay.visible == false and artwork.self_modulate.is_equal_approx(Color(0.45, 0.45, 0.45, 0.6)), "DISABLED：覆盖层隐藏且 Artwork 灰调。")
	view.set_feedback(_ObjectVisualView.FeedbackState.NONE)
	_check(NAME, overlay.visible == false and artwork.self_modulate == Color.WHITE, "NONE：覆盖层隐藏且 Artwork 原色。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 13. 重复刷新稳定，不崩溃、状态一致。
func _test_13_repeat_refresh_stable() -> void:
	const NAME: String = "13_重复刷新稳定"
	var tex: PlaceholderTexture2D = _make_texture()
	var view = _SCENE.instantiate()
	root.add_child(view)
	view._ready()
	view.set_profile(_make_profile(&"default", tex, null))
	var artwork: TextureRect = view.get_node("Artwork")
	for i in range(10):
		view.refresh_visual()
	_check(NAME, artwork.texture == tex, "重复刷新后纹理应稳定为 tex。")
	view.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 14. 不使用 _process。
func _test_14_no_process() -> void:
	const NAME: String = "14_无_process"
	var src: String = _ObjectVisualView.source_code
	_check(NAME, not src.contains("func _process"), "不应定义 _process。")


## 15. 不依赖 EmitterConfigNode / EmissionPreview / CoreLoopPrototype / addons / EditorPlugin。
##    仅检查代码级引用；文档注释中作为未来消费者出现的名称不算依赖。
func _test_15_no_forbidden_dependencies() -> void:
	const NAME: String = "15_无禁止依赖"
	var code: String = _strip_comments(_ObjectVisualView.source_code)
	for token: String in ["EmitterConfigNode", "EmissionPreview", "BasicCrystal", "FixedEmitter", "CoreLoopPrototype", "addons", "EditorPlugin"]:
		_check(NAME, not code.contains(token), "源码不应引用禁止依赖 %s。" % [token])


## 16. 不加载正式主场景：测试结束后 root 无残留。
func _test_16_no_main_scene_loaded() -> void:
	const NAME: String = "16_不加载主场景"
	_check(NAME, root.get_child_count() == 0, "测试结束后 root 应无残留，实际 %d。" % [root.get_child_count()])


# ===== 辅助 =====

## 创建带单个状态的 profile；drag_tex 为 null 表示该状态无拖拽纹理。
func _make_profile(state_id: StringName, world_tex: Texture2D, drag_tex: Texture2D) -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = state_id
	state.world_texture = world_tex
	state.drag_texture = drag_tex
	profile.default_state_id = state_id
	profile.states = [state]
	return profile


## 创建可区分的占位纹理。
func _make_texture() -> PlaceholderTexture2D:
	var tex: PlaceholderTexture2D = PlaceholderTexture2D.new()
	tex.size = Vector2i(32, 32)
	return tex


## 剥离 GDScript 注释（# 至行尾），便于检查代码级依赖而忽略文档注释中的名称。
func _strip_comments(src: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for line: String in src.split("\n", false):
		var hash_pos: int = line.find("#")
		if hash_pos == -1:
			out.append(line)
		else:
			out.append(line.substr(0, hash_pos))
	return "\n".join(out)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== ObjectVisualView 测试摘要 ====")
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
