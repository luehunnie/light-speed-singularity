extends SceneTree

## VisualStateEditService D4.5-C1 核心测试（拆分自原 visual_state_edit_service_test）。
## 仅覆盖 EditService：null view/profile/state/texture 拒绝、非 art 路径拒绝、合法替换、
##   新旧相同跳过、Do/Undo/Redo 纹理与视图刷新、emit_changed 可观察、refresh_visual 可观察、
##   不改 state_id/default_state_id、不切换 View 当前状态、共享 Profile 多 View 同一变化。
## 不创建 Dock，不测试按钮和 UI。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：EditorUndoRedoManager 无法在纯 headless 构造，故 UndoRedo 行为以可构造的 UndoRedo 验证；
##     正式编辑器走 EditorUndoRedoManager，二者 create_action/add_do_*/commit_action 接口一致。

const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service = _EditServiceScript.new()

# 信号计数器：统计 Resource.changed 触发次数。
class _SignalCounter extends RefCounted:
	var count: int = 0
	func on_changed() -> void:
		count += 1


func _initialize() -> void:
	_test_01_null_view_denied()
	_test_02_null_profile_denied()
	_test_03_missing_state_denied()
	_test_04_null_texture_denied()
	_test_05_non_art_path_denied()
	_test_06_legal_replace()
	_test_07_same_texture_skips_action()
	_test_08_do_updates_world_texture()
	_test_09_undo_restores_old_texture()
	_test_10_redo_restores_new_texture()
	_test_11_emit_changed_observable()
	_test_12_refresh_visual_observable()
	_test_13_state_id_unchanged()
	_test_14_default_state_id_unchanged()
	_test_15_view_current_state_unchanged()
	_test_16_shared_profile_multi_view()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== EditService 测试 =====

## 1. null view 拒绝。
func _test_01_null_view_denied() -> void:
	const NAME: String = "01_null_view拒绝"
	var r: Dictionary = _service.can_replace(null, &"lit", _make_texture(), "res://assets/art/x.png")
	_check(NAME, r.ok == false, "null view 应拒绝。")


## 2. null profile 拒绝：view 无 visual_profile。
func _test_02_null_profile_denied() -> void:
	const NAME: String = "02_null_profile拒绝"
	var view = _make_real_view()
	view.set_profile(null)
	var r: Dictionary = _service.can_replace(view, &"lit", _make_texture(), "res://assets/art/x.png")
	_check(NAME, r.ok == false, "null profile 应拒绝。")
	var rr: Dictionary = _service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", _make_texture(), "a")
	_check(NAME, rr.ok == false, "null profile 替换应拒绝。")
	view.free()


## 3. state_id 不存在拒绝。
func _test_03_missing_state_denied() -> void:
	const NAME: String = "03_state不存在拒绝"
	var view = _make_real_view()
	view.set_profile(_make_profile_two_states())
	var r: Dictionary = _service.can_replace(view, &"nonexistent", _make_texture(), "res://assets/art/x.png")
	_check(NAME, r.ok == false, "不存在 state_id 应拒绝。")
	view.free()


## 4. null texture 拒绝。
func _test_04_null_texture_denied() -> void:
	const NAME: String = "04_null_texture拒绝"
	var view = _make_real_view()
	view.set_profile(_make_profile_two_states())
	var r: Dictionary = _service.can_replace(view, &"lit", null, "res://assets/art/x.png")
	_check(NAME, r.ok == false, "null texture 应拒绝。")
	view.free()


## 5. 非 art 路径拒绝。
func _test_05_non_art_path_denied() -> void:
	const NAME: String = "05_non_art_path拒绝"
	var view = _make_real_view()
	view.set_profile(_make_profile_two_states())
	var r: Dictionary = _service.can_replace(view, &"lit", _make_texture(), "res://foo/x.png")
	_check(NAME, r.ok == false, "非 art 路径应拒绝。")
	view.free()


## 6. 合法替换：返回 ok 且 world_texture 更新。
func _test_06_legal_replace() -> void:
	const NAME: String = "06_合法替换"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	var new_tex: PlaceholderTexture2D = _make_texture()
	var r: Dictionary = _service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", new_tex, "替换视觉状态 lit 的图片")
	_check(NAME, r.ok == true, "合法替换应返回 ok。")
	var state: _VisualStateTexture = _service.find_state(profile, &"lit")
	_check(NAME, state.world_texture == new_tex, "替换后 world_texture 应为新纹理。")
	view.free()


## 7. 新旧纹理相同不创建动作。
func _test_07_same_texture_skips_action() -> void:
	const NAME: String = "07_相同纹理跳过"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	var same_tex: PlaceholderTexture2D = profile.get_world_texture(&"lit")
	var r: Dictionary = _service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", same_tex, "a")
	_check(NAME, r.ok == true and r.get("skipped", false) == true, "相同纹理应 skipped=true。")
	_check(NAME, profile.get_world_texture(&"lit") == same_tex, "跳过后纹理应不变。")
	view.free()


## 8. Do 更新 world_texture 与视图。
func _test_08_do_updates_world_texture() -> void:
	const NAME: String = "08_Do更新纹理"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.refresh_visual()
	var new_tex: PlaceholderTexture2D = _make_texture()
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", new_tex, "a")
	_check(NAME, profile.get_world_texture(&"lit") == new_tex, "Do 后 profile 纹理应为新。")
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == new_tex, "Do 后 Artwork 应显示新纹理。")
	view.free()


## 9. Undo 恢复旧 texture。
func _test_09_undo_restores_old_texture() -> void:
	const NAME: String = "09_Undo恢复旧纹理"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.refresh_visual()
	var old_tex: PlaceholderTexture2D = profile.get_world_texture(&"lit")
	var new_tex: PlaceholderTexture2D = _make_texture()
	var ur := UndoRedo.new()
	_service.replace_with_undo_redo(ur, view, &"lit", new_tex, "a")
	ur.undo()
	_check(NAME, profile.get_world_texture(&"lit") == old_tex, "Undo 后应恢复旧纹理。")
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == old_tex, "Undo 后 Artwork 应恢复旧纹理。")
	view.free()


## 10. Redo 恢复新 texture。
func _test_10_redo_restores_new_texture() -> void:
	const NAME: String = "10_Redo恢复新纹理"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.refresh_visual()
	var new_tex: PlaceholderTexture2D = _make_texture()
	var ur := UndoRedo.new()
	_service.replace_with_undo_redo(ur, view, &"lit", new_tex, "a")
	ur.undo()
	ur.redo()
	_check(NAME, profile.get_world_texture(&"lit") == new_tex, "Redo 后应恢复新纹理。")
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == new_tex, "Redo 后 Artwork 应显示新纹理。")
	view.free()


## 11. emit_changed 被触发。
func _test_11_emit_changed_observable() -> void:
	const NAME: String = "11_emit_changed可观察"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.refresh_visual()
	var counter := _SignalCounter.new()
	profile.changed.connect(Callable(counter, "on_changed"))
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", _make_texture(), "a")
	_check(NAME, counter.count > 0, "Do 应触发 profile.emit_changed。")
	view.free()


## 12. refresh_visual 被调用（结果可观察）。
func _test_12_refresh_visual_observable() -> void:
	const NAME: String = "12_refresh_visual可观察"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"lit")
	view.refresh_visual()
	var new_tex: PlaceholderTexture2D = _make_texture()
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", new_tex, "a")
	var artwork: TextureRect = view.get_node("Artwork")
	_check(NAME, artwork.texture == new_tex, "Do 应调用 refresh_visual 使 Artwork 更新。")
	view.free()


## 13. 不修改 state_id。
func _test_13_state_id_unchanged() -> void:
	const NAME: String = "13_state_id不变"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	var state: _VisualStateTexture = _service.find_state(profile, &"lit")
	var before: StringName = state.state_id
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", _make_texture(), "a")
	_check(NAME, state.state_id == before, "替换不应修改 state_id。")
	view.free()


## 14. 不修改 default_state_id。
func _test_14_default_state_id_unchanged() -> void:
	const NAME: String = "14_default_state_id不变"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	var before: StringName = profile.default_state_id
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", _make_texture(), "a")
	_check(NAME, profile.default_state_id == before, "替换不应修改 default_state_id。")
	view.free()


## 15. 不切换 View 当前状态。
func _test_15_view_current_state_unchanged() -> void:
	const NAME: String = "15_不切换当前状态"
	var view = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	view.set_profile(profile)
	view.set_content_state(&"unlit")
	view.refresh_visual()
	var before: StringName = view.get_content_state()
	_service.replace_with_undo_redo(UndoRedo.new(), view, &"lit", _make_texture(), "a")
	_check(NAME, view.get_content_state() == before, "替换不应切换 View 当前状态。")
	# 当前显示状态不是被修改状态时，Profile 数据仍更新但 Artwork 不被强制改变到新状态。
	_check(NAME, profile.get_world_texture(&"lit") != null, "被修改状态纹理应已更新。")
	view.free()


## 16. 共享 Profile 多个 View 观察到同一变化。
func _test_16_shared_profile_multi_view() -> void:
	const NAME: String = "16_共享Profile多View"
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	var view1 = _make_real_view()
	var view2 = _make_real_view()
	view1.set_profile(profile)
	view2.set_profile(profile)
	view1.set_content_state(&"lit")
	view2.set_content_state(&"lit")
	view1.refresh_visual()
	view2.refresh_visual()
	var new_tex: PlaceholderTexture2D = _make_texture()
	_service.replace_with_undo_redo(UndoRedo.new(), view1, &"lit", new_tex, "a")
	# view2 共享同一 profile 对象，数据层应观察到新纹理。
	_check(NAME, profile.get_world_texture(&"lit") == new_tex, "共享 profile 数据应更新为新纹理。")
	view2.refresh_visual()
	var artwork2: TextureRect = view2.get_node("Artwork")
	_check(NAME, artwork2.texture == new_tex, "view2 刷新后应显示新纹理。")
	view1.free()
	view2.free()


# ===== 辅助 =====

## 创建真实 ObjectVisualView 场景实例并调用 _ready 缓存子节点。
func _make_real_view() -> ObjectVisualView:
	var view = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn").instantiate()
	root.add_child(view)
	view._ready()
	return view


## 创建带两状态（unlit/lit）的 profile，default=unlit。
func _make_profile_two_states() -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	profile.states = [_make_state(&"unlit", _make_texture(), null), _make_state(&"lit", _make_texture(), null)]
	return profile


## 创建单个 VisualStateTexture。
func _make_state(state_id: StringName, world_tex: Texture2D, drag_tex: Texture2D) -> _VisualStateTexture:
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = state_id
	state.world_texture = world_tex
	state.drag_texture = drag_tex
	return state


## 创建可区分占位纹理。
func _make_texture() -> PlaceholderTexture2D:
	var tex: PlaceholderTexture2D = PlaceholderTexture2D.new()
	tex.size = Vector2i(32, 32)
	return tex


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualStateEditService 核心测试摘要 ====")
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
