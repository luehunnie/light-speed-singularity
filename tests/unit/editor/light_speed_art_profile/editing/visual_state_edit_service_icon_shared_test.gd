extends SceneTree

## VisualStateEditService 库存图标事务 + 同 Profile 多实例刷新测试（AF-Artwork P0-1/P0-4）。
## 覆盖：can_set_inventory_icon 校验域、图标替换 Do/Undo/Redo、相同图标跳过、显式清除与恢复、
##   无图标清除跳过、world_texture 替换经 scene_root 刷新同 Profile 双实例、scene_root 缺省仅刷当前、
##   图标变更对共享实例无破坏。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_state_edit_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
# 真实素材路径（资源路径合法域内）。
const _REAL_ART_PATH: String = "res://assets/art/crystal/crystal_normal_unlit.png"
const _REAL_ART_PATH_2: String = "res://assets/art/crystal/blue_crystal_unactivate.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service: RefCounted = _EditServiceScript.new()


func _initialize() -> void:
	_test_01_can_set_validation()
	_test_02_icon_replace_transaction()
	_test_03_icon_undo_redo()
	_test_04_same_icon_skips()
	_test_05_clear_then_undo_restores()
	_test_06_clear_without_icon_skips()
	_test_07_world_texture_shared_dual_view_refresh()
	_test_08_no_scene_root_only_active_refresh()
	_test_09_icon_change_safe_for_sharing_views()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 库存图标事务 =====

## 1. can_set_inventory_icon 校验域。
func _test_01_can_set_validation() -> void:
	const NAME: String = "01_校验域"
	var view: ObjectVisualView = _make_real_view()
	view.set_profile(_make_profile_with_icon(_make_texture()))
	_check(NAME, _service.can_set_inventory_icon(null, null).ok == false, "null view 应拒绝。")
	var bare: ObjectVisualView = _make_real_view()
	bare.set_profile(null)
	_check(NAME, _service.can_set_inventory_icon(bare, null).ok == false, "无 profile 应拒绝。")
	bare.free()
	_check(NAME, _service.can_set_inventory_icon(view, null).ok == true, "null 新纹理（显式清除）应允许。")
	_check(NAME, _service.can_set_inventory_icon(view, _make_texture()).ok == false, "内存纹理（无资源路径）应拒绝。")
	var real_tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	_check(NAME, _service.can_set_inventory_icon(view, real_tex).ok == true, "art 根下真实纹理应允许。")
	view.free()


## 2. 图标替换事务：Do 更新 inventory_icon。
func _test_02_icon_replace_transaction() -> void:
	const NAME: String = "02_图标替换"
	var view: ObjectVisualView = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_with_icon(_make_texture())
	view.set_profile(profile)
	var new_tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.replace_inventory_icon_with_undo_redo(
		UndoRedo.new(), view, new_tex, "替换库存图标", null)
	_check(NAME, r.ok == true, "合法替换应返回 ok。")
	_check(NAME, profile.inventory_icon == new_tex, "Do 后 inventory_icon 应为新纹理。")
	view.free()


## 3. 图标 Undo / Redo。
func _test_03_icon_undo_redo() -> void:
	const NAME: String = "03_图标UndoRedo"
	var view: ObjectVisualView = _make_real_view()
	var old_tex: Texture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile_with_icon(old_tex)
	view.set_profile(profile)
	var new_tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var ur := UndoRedo.new()
	_service.replace_inventory_icon_with_undo_redo(ur, view, new_tex, "替换库存图标", null)
	ur.undo()
	_check(NAME, profile.inventory_icon == old_tex, "Undo 后应恢复旧图标。")
	ur.redo()
	_check(NAME, profile.inventory_icon == new_tex, "Redo 后应恢复新图标。")
	view.free()


## 4. 相同图标跳过。
func _test_04_same_icon_skips() -> void:
	const NAME: String = "04_相同图标跳过"
	var view: ObjectVisualView = _make_real_view()
	var same_tex: Texture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile_with_icon(same_tex)
	view.set_profile(profile)
	var r: Dictionary = _service.replace_inventory_icon_with_undo_redo(
		UndoRedo.new(), view, same_tex, "替换库存图标", null)
	_check(NAME, r.ok == true and r.get("skipped", false) == true, "相同图标应 skipped=true。")
	_check(NAME, profile.inventory_icon == same_tex, "跳过后图标应不变。")
	view.free()


## 5. 显式清除与 Undo 恢复。
func _test_05_clear_then_undo_restores() -> void:
	const NAME: String = "05_清除与恢复"
	var view: ObjectVisualView = _make_real_view()
	var old_tex: Texture2D = _make_texture()
	var profile: _ObjectVisualProfile = _make_profile_with_icon(old_tex)
	view.set_profile(profile)
	var ur := UndoRedo.new()
	var r: Dictionary = _service.replace_inventory_icon_with_undo_redo(
		ur, view, null, "清除库存图标", null)
	_check(NAME, r.ok == true and not r.get("skipped", false), "清除已有图标应成功且非跳过。")
	_check(NAME, profile.inventory_icon == null, "清除后 inventory_icon 应为 null。")
	ur.undo()
	_check(NAME, profile.inventory_icon == old_tex, "Undo 清除应恢复旧图标。")
	view.free()


## 6. 无图标时清除跳过。
func _test_06_clear_without_icon_skips() -> void:
	const NAME: String = "06_空清除跳过"
	var view: ObjectVisualView = _make_real_view()
	var profile: _ObjectVisualProfile = _make_profile_with_icon(null)
	view.set_profile(profile)
	var r: Dictionary = _service.replace_inventory_icon_with_undo_redo(
		UndoRedo.new(), view, null, "清除库存图标", null)
	_check(NAME, r.ok == true and r.get("skipped", false) == true, "无图标清除应 skipped=true。")
	view.free()


# ===== 同 Profile 多实例刷新 =====

## 7. world_texture 替换 + scene_root：同 Profile 双实例同步刷新（P0-4 核心）。
func _test_07_world_texture_shared_dual_view_refresh() -> void:
	const NAME: String = "07_双实例同步刷新"
	var scene_root: Node = Node2D.new()
	scene_root.name = "EditedScene"
	root.add_child(scene_root)
	var profile: _ObjectVisualProfile = _make_profile_with_icon(null)
	var view1: ObjectVisualView = _make_real_view(scene_root)
	var view2: ObjectVisualView = _make_real_view(scene_root)
	view1.set_profile(profile)
	view2.set_profile(profile)
	view1.set_content_state(&"lit")
	view2.set_content_state(&"lit")
	view1.refresh_visual()
	view2.refresh_visual()
	var new_tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.replace_with_undo_redo(
		UndoRedo.new(), view1, &"lit", new_tex, "替换", scene_root)
	_check(NAME, r.ok == true, "替换应成功。")
	var artwork1: TextureRect = view1.get_node("Artwork")
	var artwork2: TextureRect = view2.get_node("Artwork")
	_check(NAME, artwork1.texture == new_tex, "主动实例应显示新纹理。")
	_check(NAME, artwork2.texture == new_tex, "同 Profile 另一实例应被事务自动刷新（无需手动 refresh）。")
	scene_root.free()


## 8. scene_root 缺省：仅刷新主动实例（旧行为保持）。
func _test_08_no_scene_root_only_active_refresh() -> void:
	const NAME: String = "08_缺省仅刷当前"
	var profile: _ObjectVisualProfile = _make_profile_with_icon(null)
	var view1: ObjectVisualView = _make_real_view()
	var view2: ObjectVisualView = _make_real_view()
	view1.set_profile(profile)
	view2.set_profile(profile)
	view1.set_content_state(&"lit")
	view2.set_content_state(&"lit")
	view1.refresh_visual()
	view2.refresh_visual()
	var new_tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	_service.replace_with_undo_redo(UndoRedo.new(), view1, &"lit", new_tex, "替换", null)
	var artwork1: TextureRect = view1.get_node("Artwork")
	var artwork2: TextureRect = view2.get_node("Artwork")
	_check(NAME, artwork1.texture == new_tex, "主动实例应刷新。")
	_check(NAME, artwork2.texture != new_tex, "无 scene_root 时另一实例不应被自动刷新。")
	view1.free()
	view2.free()


## 9. 图标变更对共享实例无破坏（刷新无害）。
func _test_09_icon_change_safe_for_sharing_views() -> void:
	const NAME: String = "09_图标变更共享安全"
	var scene_root: Node = Node2D.new()
	scene_root.name = "EditedScene2"
	root.add_child(scene_root)
	var profile: _ObjectVisualProfile = _make_profile_with_icon(_make_texture())
	var view1: ObjectVisualView = _make_real_view(scene_root)
	var view2: ObjectVisualView = _make_real_view(scene_root)
	view1.set_profile(profile)
	view2.set_profile(profile)
	view1.set_content_state(&"lit")
	view2.set_content_state(&"lit")
	view1.refresh_visual()
	view2.refresh_visual()
	var world_tex: Texture2D = profile.get_world_texture(&"lit")
	var new_icon: Texture2D = ResourceLoader.load(_REAL_ART_PATH_2)
	var r: Dictionary = _service.replace_inventory_icon_with_undo_redo(
		UndoRedo.new(), view1, new_icon, "替换库存图标", scene_root)
	_check(NAME, r.ok == true, "图标替换应成功。")
	_check(NAME, profile.inventory_icon == new_icon, "图标应已更新。")
	var artwork2: TextureRect = view2.get_node("Artwork")
	_check(NAME, artwork2.texture == world_tex, "共享实例世界纹理应保持不受图标变更影响。")
	scene_root.free()


# ===== 辅助 =====

## 创建真实 ObjectVisualView 场景实例并调用 _ready 缓存子节点。
## parent 为空时挂到测试根；传入 scene_root 时直接挂其下（勿先挂 root 再改挂，add_child 不重父）。
func _make_real_view(parent: Node = null) -> ObjectVisualView:
	var view: ObjectVisualView = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn").instantiate()
	if parent != null:
		parent.add_child(view)
	else:
		root.add_child(view)
	view._ready()
	return view


## 创建带 unlit/lit 两状态与指定库存图标的 profile。
func _make_profile_with_icon(icon: Texture2D) -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	profile.inventory_icon = icon
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
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualStateEditService 图标与共享刷新测试摘要 ====")
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
