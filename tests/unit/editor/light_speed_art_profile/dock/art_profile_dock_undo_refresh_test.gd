extends SceneTree

## ArtProfileDock Undo/Redo 刷新钩子与拆分边界测试（AF-Artwork 定点修正）。
## 覆盖：库存图标 apply/clear 后 Ctrl+Z/Ctrl+Y 立即刷新图标诊断与预览（经 version_changed 统一钩子）、
##   创建绑定 Undo/Redo 立即刷新绑定状态与创建区诊断、EURM 事务真值同步恢复、
##   拆分后图标/创建绑定控件归属与注入转发、无需重新选择节点。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
)
const _BindServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_profile_bind_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
# 真实素材路径（与既有 dock 测试同源）。
const _REAL_ART_PATH: String = "res://assets/art/crystal/crystal_normal_unlit.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 当前注入 dock 的编辑场景根提供器返回值（bind 流程需要 owner/scene_file_path 语义）。
var _scene_root_ref: Node = null
# 捕获 BindService 写盘请求，避免真实磁盘写入。
var _backend: RefCounted = _CapturingBackend.new()


class _StubVisual extends ObjectVisualView:
	pass


class _CapturingBackend extends RefCounted:
	var captured_path: String = ""
	func save(profile: Resource, path: String) -> int:
		captured_path = path
		return OK


func _initialize() -> void:
	_test_u01_icon_apply_undo_redo_refresh()
	_test_u02_icon_clear_undo_restores()
	_test_u03_create_bind_undo_redo_refresh()
	_test_u04_split_boundary_and_forwarding()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== U1. 库存图标 apply → Ctrl+Z / Ctrl+Y 立即刷新诊断与预览 =====

func _test_u01_icon_apply_undo_redo_refresh() -> void:
	const NAME: String = "U1_图标apply撤销重做刷新"
	var dock = _make_dock()
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	var view = _StubVisual.new()
	view.visual_profile = profile
	dock.show_selection([view])
	_select_real_art(dock)
	var icon = _icon_panel(dock)
	icon._on_apply_icon_pressed()
	var tex: Texture2D = profile.inventory_icon
	_check(NAME, tex != null and tex.resource_path == _REAL_ART_PATH, "前置：apply 后图标应已替换。")
	_check(NAME, icon._icon_info.text == _REAL_ART_PATH, "apply 后诊断应显示素材路径。")
	_check(NAME, icon._clear_icon_button.disabled == false, "apply 后清除按钮应启用。")
	# Ctrl+Z：version_changed 统一钩子应立即刷新，无需重新选择节点。
	ur.undo()
	_check(NAME, profile.inventory_icon == null, "undo 后 EURM 真值应恢复为空。")
	_check(NAME, icon._icon_info.text == "未设置（道具栏显示占位符）。", "undo 后诊断应立即回到未设置。")
	_check(NAME, icon._icon_preview.texture == null, "undo 后预览应立即清空。")
	_check(NAME, icon._clear_icon_button.disabled == true, "undo 后清除按钮应立即禁用。")
	_check(NAME, dock._action_panel._active_visual == view, "undo 刷新不应改变 active visual（无需重选节点）。")
	# Ctrl+Y：重做后立即恢复路径诊断与预览。
	ur.redo()
	_check(NAME, profile.inventory_icon == tex, "redo 后 EURM 真值应恢复素材。")
	_check(NAME, icon._icon_info.text == _REAL_ART_PATH, "redo 后诊断应立即恢复路径。")
	_check(NAME, icon._icon_preview.texture == tex, "redo 后预览应立即恢复素材。")
	_check(NAME, icon._clear_icon_button.disabled == false, "redo 后清除按钮应立即启用。")
	dock.free()
	view.free()


# ===== U2. 库存图标 clear → Ctrl+Z 立即恢复 =====

func _test_u02_icon_clear_undo_restores() -> void:
	const NAME: String = "U2_图标clear撤销恢复"
	var dock = _make_dock()
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	var profile: _ObjectVisualProfile = _make_profile_two_states()
	var placeholder: PlaceholderTexture2D = PlaceholderTexture2D.new()
	placeholder.size = Vector2i(24, 24)
	profile.inventory_icon = placeholder
	var view = _StubVisual.new()
	view.visual_profile = profile
	dock.show_selection([view])
	var icon = _icon_panel(dock)
	_check(NAME, icon._icon_info.text == "<内存资源>", "前置：内存资源图标应显示占位文案。")
	icon._on_clear_icon_pressed()
	_check(NAME, profile.inventory_icon == null, "前置：clear 后图标应已置空。")
	_check(NAME, icon._icon_info.text == "未设置（道具栏显示占位符）。", "clear 后诊断应立即更新。")
	ur.undo()
	_check(NAME, profile.inventory_icon == placeholder, "undo 后 EURM 真值应恢复原图标。")
	_check(NAME, icon._icon_info.text == "<内存资源>", "undo 后诊断应立即恢复内存资源文案。")
	_check(NAME, icon._icon_preview.texture == placeholder, "undo 后预览应立即恢复原图标。")
	_check(NAME, icon._clear_icon_button.disabled == false, "undo 后清除按钮应立即启用。")
	dock.free()
	view.free()


# ===== U3. 创建绑定 → Ctrl+Z 解绑刷新创建区 / Ctrl+Y 重绑刷新状态列表 =====

func _test_u03_create_bind_undo_redo_refresh() -> void:
	const NAME: String = "U3_创建绑定撤销重做刷新"
	var dock = _make_dock()
	var ur := UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	# 注入带捕获后端的 BindService，避免真实写盘。
	var bind_service = _BindServiceScript.new()
	bind_service.set_save_backend(Callable(_backend, "save"))
	dock._action_panel._bind_service = bind_service
	# 合成"未绑定已保存场景"夹具：holder 持伪 scene_file_path（派生路径磁盘必然不存在）、
	# view 的 owner 指向 holder；存量视觉接入第一批后真实机关场景均已自带 profile 且磁盘已有同名
	# visuals 文件，不再具备"缺 profile 且可创建"语义，故以合成场景保持本组测试意图。
	var holder: Node2D = Node2D.new()
	holder.name = "UnboundStubScene"
	holder.scene_file_path = "res://gameplay/mechanisms/speed/unbound_stub_scene.tscn"
	root.add_child(holder)
	var view: ObjectVisualView = _StubVisual.new()
	view.name = "VisualView"
	holder.add_child(view)
	view.owner = holder
	_scene_root_ref = holder
	dock.set_scene_root_provider(Callable(self, "_provide_scene_root"))
	view._ready()
	dock.show_selection([view])
	_select_real_art(dock)
	var bind = _bind_panel(dock)
	var vsp = dock._action_panel._visual_state_panel
	_check(NAME, bind._create_bind_button.visible == true, "前置：缺 profile 时创建区应可见。")
	_check(NAME, bind._create_bind_button.disabled == false, "前置：条件齐备创建按钮应启用。")
	bind._on_create_bind_pressed()
	_check(NAME, view.visual_profile != null, "前置：创建后应已绑定。")
	_check(NAME, vsp._state_list != null and vsp._state_list.item_count == 1, "前置：创建后状态列表应含 default。")
	_check(NAME, bind._create_bind_button.visible == false, "前置：创建后创建区应隐藏。")
	# Ctrl+Z：解绑后立即回到创建区并刷新诊断（不要求重新选择节点）。
	ur.undo()
	_check(NAME, view.visual_profile == null, "undo 后 EURM 真值应解绑。")
	_check(NAME, vsp._state_list == null, "undo 后状态列表应立即清空。")
	_check(NAME, bind._create_bind_button.visible == true, "undo 后创建区应立即可见。")
	_check(NAME, bind._bind_hint.visible == true, "undo 后创建区提示应立即可见。")
	_check(NAME, bind._create_bind_button.disabled == false, "undo 后创建按钮诊断应立即重算（素材仍选中）。")
	_check(NAME, dock._action_panel._active_visual == view, "undo 刷新不应改变 active visual。")
	# Ctrl+Y：重绑后立即回到状态列表与图标区。
	ur.redo()
	_check(NAME, view.visual_profile != null, "redo 后 EURM 真值应重绑。")
	_check(NAME, vsp._state_list != null and vsp._state_list.item_count == 1, "redo 后状态列表应立即恢复。")
	_check(NAME, bind._create_bind_button.visible == false, "redo 后创建区应立即隐藏。")
	_check(NAME, _icon_panel(dock)._icon_title.visible == true, "redo 后图标区应立即可见。")
	_scene_root_ref = null
	dock.free()
	holder.free()


# ===== U4. 拆分边界：控件归属、注入转发、布局顺序、区块可见性 =====

func _test_u04_split_boundary_and_forwarding() -> void:
	const NAME: String = "U4_拆分边界与转发"
	var dock = _make_dock()
	var vsp = dock._action_panel._visual_state_panel
	var icon = _icon_panel(dock)
	var bind = _bind_panel(dock)
	_check(NAME, icon != null and is_instance_valid(icon), "库存图标子面板应存在。")
	_check(NAME, bind != null and is_instance_valid(bind), "创建绑定子面板应存在。")
	_check(NAME, icon.get_parent() == vsp and bind.get_parent() == vsp, "两个子面板应挂在 VisualStatePanel 下。")
	_check(NAME, icon._apply_icon_button != null and icon._clear_icon_button != null, "图标按钮应归属图标子面板。")
	_check(NAME, bind._create_bind_button != null and bind._bind_hint != null, "创建绑定控件应归属创建绑定子面板。")
	_check(NAME, vsp._state_list != null or vsp._states_box != null, "状态列表仍应归属主面板。")
	_check(NAME, vsp._apply_button != null and is_instance_valid(vsp._apply_button), "应用按钮仍应归属主面板。")
	# 布局顺序保持：状态区 → 图标区 → 创建绑定区。
	_check(NAME, icon.get_index() > vsp._apply_hint.get_index(), "图标区应位于状态区之后。")
	_check(NAME, bind.get_index() > icon.get_index(), "创建绑定区应位于图标区之后。")
	# 服务注入转发：主面板属性赋值应实时到达对应子面板。
	var edit_spy: RefCounted = RefCounted.new()
	dock._action_panel._edit_service = edit_spy
	_check(NAME, vsp._edit_service == edit_spy, "EditService 应保留在主面板字段。")
	_check(NAME, icon._edit_service == edit_spy, "EditService 赋值应转发到图标子面板。")
	var bind_spy: RefCounted = RefCounted.new()
	dock._action_panel._bind_service = bind_spy
	_check(NAME, bind._bind_service == bind_spy, "BindService 赋值应转发到创建绑定子面板。")
	# 区块可见性切换：缺 profile 目标显示创建区、隐藏图标区。
	var view = _StubVisual.new()
	view.visual_profile = null
	dock.show_selection([view])
	_check(NAME, bind._create_bind_button.visible == true, "缺 profile 时创建区应可见。")
	_check(NAME, icon._apply_icon_button.visible == false, "缺 profile 时图标区应隐藏。")
	# clear_action 全清：两子面板区块都应隐藏。
	dock._action_panel.clear_action()
	_check(NAME, bind._create_bind_button.visible == false, "clear_action 后创建区应隐藏。")
	_check(NAME, icon._apply_icon_button.visible == false, "clear_action 后图标区应隐藏。")
	view.free()
	dock.free()


# ===== 辅助 =====

## 实例化 Dock 并完成 _ready（控件树就绪）。
func _make_dock():
	var dock = _DockScene.instantiate()
	root.add_child(dock)
	dock._ready()
	return dock


## 扫描浏览器并选中真实素材（与既有 dock 测试同源做法）。
func _select_real_art(dock) -> void:
	dock._browser_view._ready()
	var ok: bool = dock._browser_view.select_entry_by_path(_REAL_ART_PATH)
	_check("辅助", ok, "应能选中真实素材 %s。" % _REAL_ART_PATH)


## 取库存图标子面板。
func _icon_panel(dock) -> VBoxContainer:
	return dock._action_panel._visual_state_panel._icon_panel


## 取创建绑定子面板。
func _bind_panel(dock) -> VBoxContainer:
	return dock._action_panel._visual_state_panel._bind_panel


## 编辑场景根提供器：返回当前注入引用。
func _provide_scene_root() -> Node:
	return _scene_root_ref


## 创建带两状态（unlit/lit）的 profile，default=unlit。
func _make_profile_two_states() -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var s1: _VisualStateTexture = _VisualStateTexture.new()
	s1.state_id = &"unlit"
	s1.world_texture = _make_texture()
	var s2: _VisualStateTexture = _VisualStateTexture.new()
	s2.state_id = &"lit"
	s2.world_texture = _make_texture()
	profile.states = [s1, s2]
	return profile


## 创建占位纹理。
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
	var group_count: int = 4
	var passed_checks: int = _checks - _failures.size()
	print("==== ArtProfileDock Undo/Redo 刷新与拆分边界测试摘要 ====")
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
