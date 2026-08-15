extends SceneTree

## ArtProfileDock D4.5-C1 只读边界测试（拆分自原 visual_state_edit_service_test）。
## 覆盖 Dock 边界：单/多目标 active target、状态未选择、素材未选择、切换对象清除状态、
##   应用按钮启用条件、不直接修改 Profile、状态列表与点击 state_id、保存入口、Browser 接线。
## 不重复测试 EditService 内部 UndoRedo。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
)
const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _SaveServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/profile_save_service.gd"
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
# 真实素材路径（M4-F1 修正：美术目录重组后 crystals/ → crystal/，见 git a3e99ba/0f27215）
const _REAL_ART_PATH: String = "res://assets/art/crystal/crystal_normal_unlit.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0

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
	_test_d16_subpanel_control_ownership()
	_test_d17_service_forwarding()
	_test_d18_clear_action_clears_subpanels()
	_report()
	quit(0 if _failures.is_empty() else 1)


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
	dock._action_panel._visual_state_panel._state_list.select(0)
	dock._action_panel._visual_state_panel._on_state_selected(0)
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
	_check(NAME, dock._action_panel._visual_state_panel._apply_button.disabled == true, "无状态/素材应禁用。")
	# 选中状态但仍无素材：禁用。
	dock._action_panel._visual_state_panel._state_list.select(0)
	dock._action_panel._visual_state_panel._on_state_selected(0)
	_check(NAME, dock._action_panel._visual_state_panel._apply_button.disabled == true, "有状态无素材应禁用。")
	# 扫描浏览器并选中真实素材：启用。
	dock._browser_view._ready()
	var ok: bool = dock._browser_view.select_entry_by_path(_REAL_ART_PATH)
	_check(NAME, ok, "应能选中真实素材。")
	_check(NAME, dock._action_panel._visual_state_panel._apply_button.disabled == false, "状态+素材齐备应启用。")
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
	dock._action_panel._visual_state_panel._state_list.select(1)
	dock._action_panel._visual_state_panel._on_state_selected(1)
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
	var sl: ItemList = dock._action_panel._visual_state_panel._state_list
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
	var sl: ItemList = dock._action_panel._visual_state_panel._state_list
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
	var sl: ItemList = dock._action_panel._visual_state_panel._state_list
	var idx: int = -1
	for i: int in range(sl.item_count):
		if sl.get_item_metadata(i) == &"unlit":
			idx = i
			break
	_check(NAME, idx >= 0, "应找到 unlit 项。")
	if idx >= 0:
		sl.select(idx)
		dock._action_panel._visual_state_panel._on_state_selected(idx)
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
	dock._action_panel._save_panel._on_save_pressed()
	_check(NAME, dock._action_panel._save_panel._save_confirm.visible == true, "保存应显示确认 UI。")
	dock._action_panel._save_panel._on_confirm_save_pressed()
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

## D16. 拆分后控件归属：状态/应用控件在 VisualStatePanel，保存控件在 ProfileSavePanel，共享状态在 ActionPanel。
func _test_d16_subpanel_control_ownership() -> void:
	const NAME: String = "D16_子面板控件归属"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	var vsp = dock._action_panel._visual_state_panel
	var ssp = dock._action_panel._save_panel
	_check(NAME, vsp != null and is_instance_valid(vsp), "VisualStatePanel 应存在。")
	_check(NAME, ssp != null and is_instance_valid(ssp), "ProfileSavePanel 应存在。")
	_check(NAME, vsp._state_list != null and is_instance_valid(vsp._state_list), "状态列表应归属 VisualStatePanel。")
	_check(NAME, vsp._apply_button != null and is_instance_valid(vsp._apply_button), "应用按钮应归属 VisualStatePanel。")
	_check(NAME, ssp._save_button != null and is_instance_valid(ssp._save_button), "保存按钮应归属 ProfileSavePanel。")
	_check(NAME, ssp._save_confirm != null and is_instance_valid(ssp._save_confirm), "保存确认应归属 ProfileSavePanel。")
	_check(NAME, dock._action_panel._operation_status != null, "共享操作状态 Label 应归属 ActionPanel。")
	dock.free()
	view.free()


## D17. ActionPanel 属性赋值实时转发：EditService / SaveService / UndoRedo 注入子面板。
func _test_d17_service_forwarding() -> void:
	const NAME: String = "D17_服务与UndoRedo转发"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var spy := _SpyEdit.new()
	dock._action_panel._edit_service = spy
	_check(NAME, dock._action_panel._visual_state_panel._edit_service == spy, "EditService 赋值应转发到 VisualStatePanel。")
	var save_service = _SaveServiceScript.new()
	dock._action_panel._save_service = save_service
	_check(NAME, dock._action_panel._save_panel._save_service == save_service, "SaveService 赋值应转发到 ProfileSavePanel。")
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	_check(NAME, dock._action_panel._editor_undo_redo == ur, "ActionPanel 应持有注入的 UndoRedo。")
	_check(NAME, dock._action_panel._visual_state_panel._editor_undo_redo == ur, "UndoRedo 应转发到 VisualStatePanel。")
	dock.free()


## D18. clear_action 同时清空两个子面板：状态列表释放、选择清空、保存确认隐藏、共享状态行清空。
func _test_d18_clear_action_clears_subpanels() -> void:
	const NAME: String = "D18_clear_action清两子面板"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	dock._action_panel._visual_state_panel._state_list.select(0)
	dock._action_panel._visual_state_panel._on_state_selected(0)
	_check(NAME, dock._action_panel._visual_state_panel._state_list != null, "前置：状态列表应已创建。")
	_check(NAME, dock.get_selected_state_id() != &"", "前置：应已选择状态。")
	dock._action_panel.clear_action()
	_check(NAME, dock._action_panel._visual_state_panel._state_list == null, "clear_action 应释放状态列表。")
	_check(NAME, dock._action_panel._visual_state_panel.get_selected_state_id() == &"", "clear_action 应清空状态选择。")
	_check(NAME, dock._action_panel._save_panel._save_confirm.visible == false, "clear_action 应隐藏保存确认。")
	_check(NAME, dock._action_panel._operation_status.text == "", "clear_action 应清空共享状态行。")
	dock.free()
	view.free()


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
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== ArtProfileDock 只读边界测试摘要 ====")
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
