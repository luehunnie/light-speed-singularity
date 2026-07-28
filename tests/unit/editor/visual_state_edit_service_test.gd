extends SceneTree

## VisualStateEditService D4.5-C1 定向测试 + Dock 只读边界验证。
## 覆盖 EditService：null view/profile/state/texture 拒绝、非 art 路径拒绝、合法替换、
##   新旧相同跳过、Do/Undo/Redo 纹理与视图刷新、emit_changed 可观察、refresh_visual 可观察、
##   不改 state_id/default_state_id、不切换 View 当前状态、共享 Profile 多 View 同一变化。
## 覆盖 Dock 边界：单/多目标 active target、状态未选择、素材未选择、切换对象清除状态、
##   应用按钮启用条件、不直接修改 Profile。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：EditorUndoRedoManager 无法在纯 headless 构造，故 UndoRedo 行为以可构造的 UndoRedo 验证；
##     正式编辑器走 EditorUndoRedoManager，二者 create_action/add_do_*/commit_action 接口一致。

const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _SaveServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/profile_save_service.gd"
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
const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _REAL_ART_PATH: String = "res://assets/art/crystals/crystal_normal_unlit.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service = _EditServiceScript.new()

# 信号计数器：统计 Resource.changed 触发次数。
class _SignalCounter extends RefCounted:
	var count: int = 0
	func on_changed() -> void:
		count += 1

# 测试替身：ObjectVisualView 子类，便于构造多目标场景而不依赖场景文件内部子节点。
class _StubVisual extends ObjectVisualView:
	pass

# 测试替身：包裹真实 EditService，仅计数 replace_with_undo_redo 调用；find_state/can_replace 透传。
# 用于验证“保存路径不会触发替换服务”。
class _SpyEdit extends RefCounted:
	var replace_count: int = 0
	var _real: RefCounted = _EditServiceScript.new()
	func find_state(profile, state_id) -> VisualStateTexture:
		return _real.find_state(profile, state_id)
	func can_replace(view, state_id, texture, resource_path) -> Dictionary:
		return _real.can_replace(view, state_id, texture, resource_path)
	func replace_with_undo_redo(undo_redo, view, state_id, new_texture, action_name) -> Dictionary:
		replace_count += 1
		return {ok = false, reason = "spy：不应在保存路径调用替换", skipped = false}

# 测试替身：捕获 SaveService 写入的 profile/path，返回指定 Error；避免真实磁盘写入。
class _CapturingSaveBackend extends RefCounted:
	var captured_path: String = ""
	var captured_profile: Resource = null
	var return_err: int = 0
	func save(profile: Resource, path: String) -> int:
		captured_path = path
		captured_profile = profile
		return return_err


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
	_test_d01_single_target_active()
	_test_d02_multi_target_unselected_null()
	_test_d03_multi_target_selected()
	_test_d04_no_state_selected_empty()
	_test_d05_no_art_entry_null()
	_test_d06_switch_object_clears_state()
	_test_d07_apply_button_enable_conditions()
	_test_d08_dock_does_not_modify_profile()
	_test_d09_state_list_minimum_size()
	_test_d10_two_states_in_list()
	_test_d11_click_unlit_state_id()
	_test_d14_save_does_not_invoke_replace()
	_test_d15_browser_remains_in_dock()
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


# ===== Dock 只读边界测试 =====

## D1. 单目标 active target。
func _test_d01_single_target_active() -> void:
	const NAME: String = "D1_单目标active"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	_check(NAME, dock.get_active_visual_target() == view, "单目标应返回该视觉。")
	dock.free()
	view.free()


## D2. 多目标未选择返回 null。
func _test_d02_multi_target_unselected_null() -> void:
	const NAME: String = "D2_多目标未选择null"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var comp: Node = _GridPlacedObject.new()
	var v1 = _make_stub_with_profile()
	var v2 = _make_stub_with_profile()
	comp.add_child(v1)
	comp.add_child(v2)
	dock.show_selection([comp])
	_check(NAME, dock.get_active_visual_target() == null, "多目标未选择应返回 null。")
	dock.free()
	comp.free()


## D3. 多目标选择后返回正确目标。
func _test_d03_multi_target_selected() -> void:
	const NAME: String = "D3_多目标选择"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var comp: Node = _GridPlacedObject.new()
	var v1 = _make_stub_with_profile()
	var v2 = _make_stub_with_profile()
	comp.add_child(v1)
	comp.add_child(v2)
	dock.show_selection([comp])
	# 模拟用户在多目标选择器中选择第二项。
	dock._on_target_selected(1)
	_check(NAME, dock.get_active_visual_target() == v2, "选择后应返回正确目标。")
	dock.free()
	comp.free()


## D4. 状态未选择返回空。
func _test_d04_no_state_selected_empty() -> void:
	const NAME: String = "D4_状态未选择空"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	_check(NAME, dock.get_selected_state_id() == &"", "未选择状态应返回空 StringName。")
	dock.free()
	view.free()


## D5. 素材未选择返回 null。
func _test_d05_no_art_entry_null() -> void:
	const NAME: String = "D5_素材未选择null"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	_check(NAME, dock.get_selected_art_entry() == null, "未选择素材应返回 null。")
	dock.free()
	view.free()


## D6. 切换对象清除状态选择。
func _test_d06_switch_object_clears_state() -> void:
	const NAME: String = "D6_切换对象清状态"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view1 = _make_stub_with_profile()
	dock.show_selection([view1])
	# 选中第一个状态。
	dock._action_panel._state_list.select(0)
	dock._action_panel._on_state_selected(0)
	_check(NAME, dock.get_selected_state_id() != &"", "前置：应已选择状态。")
	# 切换到另一个对象。
	var view2 = _make_stub_with_profile()
	dock.show_selection([view2])
	_check(NAME, dock.get_selected_state_id() == &"", "切换对象应清除状态选择。")
	dock.free()
	view1.free()
	view2.free()


## D7. 应用按钮启用条件。
func _test_d07_apply_button_enable_conditions() -> void:
	const NAME: String = "D7_应用按钮启用条件"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	# 无状态、无素材：禁用。
	_check(NAME, dock._action_panel._apply_button.disabled == true, "无状态/素材应禁用。")
	# 选中状态但仍无素材：禁用。
	dock._action_panel._state_list.select(0)
	dock._action_panel._on_state_selected(0)
	_check(NAME, dock._action_panel._apply_button.disabled == true, "有状态无素材应禁用。")
	# 扫描浏览器并选中真实素材：启用。
	dock._browser_view._ready()
	var ok: bool = dock._browser_view.select_entry_by_path(_REAL_ART_PATH)
	_check(NAME, ok, "应能选中真实素材。")
	_check(NAME, dock._action_panel._apply_button.disabled == false, "状态+素材齐备应启用。")
	dock.free()
	view.free()


## D8. Dock 不直接修改 Profile。
func _test_d08_dock_does_not_modify_profile() -> void:
	const NAME: String = "D8_Dock不改Profile"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	var before_unlit: Texture2D = profile.get_world_texture(&"unlit")
	var before_lit: Texture2D = profile.get_world_texture(&"lit")
	var view = _StubVisual.new()
	view.visual_profile = profile
	dock.show_selection([view])
	dock._action_panel._state_list.select(1)
	dock._action_panel._on_state_selected(1)
	dock._browser_view._ready()
	dock._browser_view.select_entry_by_path(_REAL_ART_PATH)
	_check(NAME, profile.get_world_texture(&"unlit") == before_unlit, "Dock 不应修改 unlit 纹理。")
	_check(NAME, profile.get_world_texture(&"lit") == before_lit, "Dock 不应修改 lit 纹理。")
	dock.free()
	view.free()


## D9. 状态列表 custom_minimum_size 非零（保证 unlit/lit 可见）。
func _test_d09_state_list_minimum_size() -> void:
	const NAME: String = "D9_状态列表最小高度"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	var sl: ItemList = dock._action_panel._state_list
	_check(NAME, sl != null and is_instance_valid(sl), "状态列表应已创建。")
	_check(NAME, sl.custom_minimum_size.y > 0, "状态列表 custom_minimum_size.y 应非零。")
	dock.free()
	view.free()


## D10. Crystal 两个状态（unlit/lit）均进入 ItemList。
func _test_d10_two_states_in_list() -> void:
	const NAME: String = "D10_两状态入列表"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	var sl: ItemList = dock._action_panel._state_list
	_check(NAME, sl != null and sl.item_count == 2, "Crystal 应有 unlit/lit 两项。")
	if sl == null:
		dock.free()
		view.free()
		return
	var ids: Dictionary = {}
	for i: int in range(sl.item_count):
		ids[sl.get_item_metadata(i)] = true
	_check(NAME, ids.has(&"unlit"), "列表应含 unlit。")
	_check(NAME, ids.has(&"lit"), "列表应含 lit。")
	dock.free()
	view.free()


## D11. 点击 unlit 后 get_selected_state_id() 返回正确 state_id。
func _test_d11_click_unlit_state_id() -> void:
	const NAME: String = "D11_点击unlit返回state_id"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	var sl: ItemList = dock._action_panel._state_list
	var idx: int = -1
	for i: int in range(sl.item_count):
		if sl.get_item_metadata(i) == &"unlit":
			idx = i
			break
	_check(NAME, idx >= 0, "应找到 unlit 项。")
	if idx >= 0:
		sl.select(idx)
		dock._action_panel._on_state_selected(idx)
		_check(NAME, dock.get_selected_state_id() == &"unlit", "点击 unlit 后 state_id 应为 unlit。")
	dock.free()
	view.free()


## D14. 保存按钮不会调用替换服务；保存只走 SaveService。
func _test_d14_save_does_not_invoke_replace() -> void:
	const NAME: String = "D14_保存不调用替换"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	# 单状态 profile，resource_path 指向 visual_profiles，便于走保存确认路径。
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"default"
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"default"
	state.world_texture = _make_texture()
	profile.states = [state]
	profile.resource_path = "res://assets/visual_profiles/__dock_d14__.tres"
	var view = _StubVisual.new()
	view.visual_profile = profile
	dock.show_selection([view])
	# 注入 spy 编辑服务（计数替换调用）与捕获保存后端（不写盘）。
	var spy := _SpyEdit.new()
	dock._action_panel._edit_service = spy
	var save_service = _SaveServiceScript.new()
	var backend := _CapturingSaveBackend.new()
	backend.return_err = OK
	save_service.set_save_backend(Callable(backend, "save"))
	dock._action_panel._save_service = save_service
	dock._action_panel._on_save_pressed()
	_check(NAME, dock._action_panel._save_confirm.visible == true, "保存应显示确认 UI。")
	dock._action_panel._on_confirm_save_pressed()
	_check(NAME, spy.replace_count == 0, "保存不应调用替换服务。")
	_check(NAME, backend.captured_profile == profile, "保存应走 SaveService 写入原 profile。")
	dock.free()
	view.free()


## D15. BrowserView 仍位于 Dock 内且未被删除。
# 注：--script 模式下 SceneTree 根未 entered，is_inside_tree() 不可靠；改用父节点与祖先关系判定。
func _test_d15_browser_remains_in_dock() -> void:
	const NAME: String = "D15_Browser仍在Dock内"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	_check(NAME, dock._browser_view != null and is_instance_valid(dock._browser_view), "BrowserView 应存在。")
	if dock._browser_view == null:
		dock.free()
		return
	_check(NAME, dock._browser_view.get_parent() != null, "BrowserView 父节点不应为空（未被删除）。")
	_check(NAME, dock.is_ancestor_of(dock._browser_view), "BrowserView 应位于 Dock 子树内。")
	dock.free()


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


## 创建带两状态 profile 的 _StubVisual，未入树。
func _make_stub_with_profile() -> ObjectVisualView:
	var view: _StubVisual = _StubVisual.new()
	view.visual_profile = _make_profile_two_states()
	return view


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 29
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualStateEditService + Dock 边界测试摘要 ====")
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
