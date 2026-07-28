extends SceneTree

## D4.5-C1-Hotfix Plugin→Dock→Panel UndoRedo 注入边界测试（裁剪版）。
## 只保留注入链路与真实 EditorUndoRedoManager do-path：
##   W1 plugin/Dock/Panel 提供 set_editor_undo_redo 注入接口；
##   W2 Dock 接收 manager 后转交 ActionPanel（_editor_undo_redo 一致）；
##   W3 ActionPanel 没有 manager 时明确写“应用失败”而非静默无效；
##   W4 按钮 pressed 触发一次替换，且服务收到的是注入的 manager（非 EditorInterface 查找）；
##   W9/W10 通过面板按钮 + 注入 manager 完成 Undo/Redo（注入链端到端）；
##   W_REAL（仅编辑器模式）：真实 EditorUndoRedoManager 走面板 do-path，验证 add_do_method 2 参形式不再 Invalid call。
## 不重复 Dock 普通 UI 测试（按钮启用条件、状态列表、保存入口由 dock 边界测试覆盖）。
## 由 Godot --script 运行（游戏模式用 UndoRedo.new()）；--editor --script 运行时额外覆盖真实管理器 do-path。
## 任一失败 quit(1)。

const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
const _ArtAssetEntry: GDScript = preload(
	"res://addons/light_speed_art_profile/browser/art_asset_entry.gd"
)
const _NORMAL_PNG: String = "res://assets/art/crystals/crystal_normal_unlit.png"
const _BLUE_PNG: String = "res://assets/art/crystals/crystal_blue_unlit.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 当前测试向面板提供的素材 Entry；由 _provide_entry 回调返回。
var _entry = null

# 测试替身：计数 replace_with_undo_redo 并捕获传入的 undo_redo，证明面板用的是注入的 manager。
class _SpyEdit extends RefCounted:
	var replace_count: int = 0
	var captured_ur = null
	var return_result: Dictionary = {ok = true, reason = "已替换。", skipped = false}
	func find_state(profile, state_id) -> VisualStateTexture:
		return null
	func can_replace(view, state_id, texture, resource_path) -> Dictionary:
		return {ok = true, reason = "", skipped = false}
	func replace_with_undo_redo(undo_redo, view, state_id, new_texture, action_name) -> Dictionary:
		replace_count += 1
		captured_ur = undo_redo
		return return_result


func _initialize() -> void:
	_test_w01_injection_interface_exists()
	_test_w02_dock_forwards_to_panel()
	_test_w03_panel_without_manager_fails()
	_test_w04_button_press_uses_injected_manager()
	_test_w09_undo_restores_old()
	_test_w10_redo_restores_new()
	if Engine.is_editor_hint():
		_test_w_real_editor_undo_redo_manager()
	_report()
	quit(0 if _failures.is_empty() else 1)


## W1. plugin/Dock/Panel 均提供 set_editor_undo_redo 注入接口。
func _test_w01_injection_interface_exists() -> void:
	const NAME: String = "W1_注入接口存在"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	_check(NAME, dock.has_method("set_editor_undo_redo"), "Dock 应提供 set_editor_undo_redo。")
	_check(NAME, dock._action_panel.has_method("set_editor_undo_redo"), "Panel 应提供 set_editor_undo_redo。")
	dock.free()


## W2. Dock 接收 manager 后转交 ActionPanel。
func _test_w02_dock_forwards_to_panel() -> void:
	const NAME: String = "W2_Dock转交Panel"
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	_check(NAME, dock._action_panel._editor_undo_redo == ur, "Panel._editor_undo_redo 应为 Dock 注入的 manager。")
	# 清空引用。
	dock.set_editor_undo_redo(null)
	_check(NAME, dock._action_panel._editor_undo_redo == null, "传入 null 后 Panel._editor_undo_redo 应为 null。")
	dock.free()


## W3. ActionPanel 没有 manager 时明确写“应用失败”。
func _test_w03_panel_without_manager_fails() -> void:
	const NAME: String = "W3_无manager明确失败"
	var dock = _make_dock_with_unlit(_normal_tex())
	dock.set_editor_undo_redo(null)
	_select_unlit_and_blue_entry(dock)
	_check(NAME, dock._action_panel._apply_button.disabled == false, "状态+素材齐备时按钮应启用。")
	dock._action_panel._apply_button.pressed.emit()
	_check(NAME, dock._action_panel._operation_status.text.contains("应用失败"), "无 manager 应写“应用失败”。")
	dock.free()


## W4. 按钮 pressed 触发一次替换，且服务收到的是注入的 manager。
func _test_w04_button_press_uses_injected_manager() -> void:
	const NAME: String = "W4_按钮触发一次替换"
	var dock = _make_dock_with_unlit(_normal_tex())
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	var spy := _SpyEdit.new()
	dock._action_panel._edit_service = spy
	_select_unlit_and_blue_entry(dock)
	dock._action_panel._apply_button.pressed.emit()
	_check(NAME, spy.replace_count == 1, "按下应用按钮应触发一次替换。")
	_check(NAME, spy.captured_ur == ur, "服务应收到注入的 manager，而非 EditorInterface 查找结果。")
	dock.free()


## W9. Undo 通过注入 manager 恢复旧纹理（注入链端到端）。
func _test_w09_undo_restores_old() -> void:
	const NAME: String = "W9_Undo恢复旧纹理"
	var normal := _normal_tex()
	var dock = _make_dock_with_unlit(normal)
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	_select_unlit_and_blue_entry(dock)
	dock._action_panel._apply_button.pressed.emit()
	ur.undo()
	var state: _VisualStateTexture = dock._action_panel._edit_service.find_state(dock._action_panel.get_active_visual_target().visual_profile, &"unlit")
	_check(NAME, state.world_texture == normal, "Undo 后 world_texture 应恢复为 normal。")
	dock.free()


## W10. Redo 通过注入 manager 恢复新纹理。
func _test_w10_redo_restores_new() -> void:
	const NAME: String = "W10_Redo恢复新纹理"
	var dock = _make_dock_with_unlit(_normal_tex())
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	_select_unlit_and_blue_entry(dock)
	dock._action_panel._apply_button.pressed.emit()
	ur.undo()
	ur.redo()
	var state: _VisualStateTexture = dock._action_panel._edit_service.find_state(dock._action_panel.get_active_visual_target().visual_profile, &"unlit")
	_check(NAME, state.world_texture == _blue_tex(), "Redo 后 world_texture 应恢复为 blue。")
	dock.free()


## W_REAL（仅编辑器模式）：真实 EditorUndoRedoManager 走面板 do-path，验证 add_do_method 2 参形式不再 Invalid call。
func _test_w_real_editor_undo_redo_manager() -> void:
	const NAME: String = "W_REAL_真实管理器do-path"
	var EI = Engine.get_singleton("EditorInterface")
	if EI == null or not EI.has_method("get_editor_undo_redo"):
		_check(NAME, false, "编辑器模式下应可取得 EditorUndoRedoManager。")
		return
	var real_ur = EI.get_editor_undo_redo()
	_check(NAME, real_ur != null, "EditorInterface.get_editor_undo_redo() 应返回非空管理器。")
	var dock = _make_dock_with_unlit(_normal_tex())
	dock.set_editor_undo_redo(real_ur)
	_select_unlit_and_blue_entry(dock)
	dock._action_panel._apply_button.pressed.emit()
	var state: _VisualStateTexture = dock._action_panel._edit_service.find_state(dock._action_panel.get_active_visual_target().visual_profile, &"unlit")
	_check(NAME, state.world_texture == _blue_tex(), "真实管理器 do-path 应完成替换（无 Invalid call）。")
	dock.free()


# ===== 辅助 =====

## 取得本测试使用的 UndoRedo 管理器：编辑器模式用真实 EditorUndoRedoManager，否则 UndoRedo.new()。
func _make_dock_with_unlit(unlit_tex: Texture2D) -> Node:
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"unlit"
	state.world_texture = unlit_tex
	profile.states = [state]
	var view = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn").instantiate()
	view.visual_profile = profile
	dock.show_selection([view])
	return dock


## 选中 unlit 状态并把浏览器素材提供器设为 blue entry。
func _select_unlit_and_blue_entry(dock: Node) -> void:
	_entry = _make_entry(_BLUE_PNG, _blue_tex())
	dock._action_panel.set_browser_entry_provider(Callable(self, "_provide_entry"))
	_select_unlit_state(dock)


## 在面板状态列表中选中 unlit。
func _select_unlit_state(dock: Node) -> void:
	var sl: ItemList = dock._action_panel._state_list
	var idx: int = -1
	for i: int in range(sl.item_count):
		if sl.get_item_metadata(i) == &"unlit":
			idx = i
			break
	sl.select(idx)
	dock._action_panel._on_state_selected(idx)


## 浏览器素材提供器回调：返回当前测试设置的 Entry。
func _provide_entry():
	return _entry


## 构造一个 ArtAssetEntry。
func _make_entry(path: String, texture: Texture2D) -> RefCounted:
	var entry = _ArtAssetEntry.new()
	entry.resource_path = path
	entry.file_name = path.get_file()
	entry.texture = texture
	return entry


## 加载（并缓存）normal_unlit 真实纹理。
var _normal_cache: Texture2D = null
func _normal_tex() -> Texture2D:
	if _normal_cache == null:
		_normal_cache = load(_NORMAL_PNG) as Texture2D
	return _normal_cache


## 加载（并缓存）blue_unlit 真实纹理。
var _blue_cache: Texture2D = null
func _blue_tex() -> Texture2D:
	if _blue_cache == null:
		_blue_cache = load(_BLUE_PNG) as Texture2D
	return _blue_cache


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== 美术 Profile 注入边界测试摘要 ====")
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
