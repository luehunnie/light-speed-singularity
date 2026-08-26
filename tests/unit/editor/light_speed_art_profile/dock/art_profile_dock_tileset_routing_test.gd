extends SceneTree

## ArtProfileDock TileMapLayer 真实选择路由测试（TileSet 美术工作流 v1 路由修复）。
## 覆盖：
##   R01 单选真实 TileMapLayer：优先于 ObjectVisual Resolver 的 UNSUPPORTED 路径；
##       TileSet 面板立即可分析（目标已解析、按钮态正确），ObjectVisual 专属区整体隐藏。
##   R02 继承判定：继承 TileMapLayer 的脚本子类经 is 判定同样路由（非 get_class 字符串比较）。
##   R03 切回 ObjectVisual：TileSet 面板反向隐藏，目标与一次性确认 token 一并作废。
##   R04 空选 / 多选：两区安全清空，不残留上一次选择的目标或提示。
##   R05 父 Node2D 不猜子节点：选 Walls 类父节点不进入 TileMap 模式，走 UNSUPPORTED 提示。
##   R06 模拟 EditorSelection 连续通知顺序：空→TileMapLayer→ObjectVisual→TileMapLayer→空。
## 由 Godot --headless --script 运行（用户纹理/TileSet 均为 user:// fixture，不触真实资源）。
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

const _TEST_DIR: String = "user://tileset_routing_test"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# fixture 命名串号：避免与历史运行残留文件及同进程资源缓存路径冲突。
var _serial: String = ""
var _fixture_tileset: TileSet = null
var _fixture_layer: TileMapLayer = null
# 泄漏防护：游离 fixture 节点统一登记，收尾释放。
var _leak_guard: Array = []

# 测试替身：ObjectVisualView 子类，带两状态 profile（unlit/lit），不依赖场景文件。
class _StubVisual extends ObjectVisualView:
	pass

# 继承 TileMapLayer 的脚本子类：验证 Godot 4.6 is 继承判定覆盖脚本子类路由。
class _SubTileMapLayer extends TileMapLayer:
	pass


func _initialize() -> void:
	_serial = str(Time.get_ticks_msec())
	_prepare_fixtures()
	_test_r01_tilemap_routes_first()
	_test_r02_subclass_is_routing()
	_test_r03_switch_to_objectvisual()
	_test_r04_empty_and_multi_clear()
	_test_r05_parent_node2d_not_guessed()
	_test_r06_selection_notification_sequence()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 建立 Dock + 真实外部 TileSet fixture（region 64×16、单图集源、tiles (0,0)(1,0)）。
func _prepare_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(_TEST_DIR)
	var png: Dictionary = _make_png("atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var tileset: TileSet = TileSet.new()
	tileset.tile_size = Vector2i(64, 16)
	var atlas: TileSetAtlasSource = TileSetAtlasSource.new()
	atlas.texture = png.tex
	atlas.texture_region_size = Vector2i(64, 16)
	tileset.add_source(atlas, 0)
	atlas.create_tile(Vector2i(0, 0))
	atlas.create_tile(Vector2i(1, 0))
	var path: String = "%s/fixture_%s.tres" % [_TEST_DIR, _serial]
	tileset.resource_path = path
	ResourceSaver.save(tileset, path)
	_fixture_tileset = tileset
	_fixture_layer = TileMapLayer.new()
	_fixture_layer.tile_set = tileset
	_leak_guard.append(_fixture_layer)


## R01 单选真实 TileMapLayer：TileSet 模式立即生效且可分析，ObjectVisual 区隐藏。
func _test_r01_tilemap_routes_first() -> void:
	const NAME: String = "R01_单选TileMapLayer路由优先"
	var dock = _make_dock()
	dock.show_selection([_fixture_layer])
	_check(NAME, dock._tileset_panel.visible, "单选 TileMapLayer 应显示 TileSet 面板。")
	_check(NAME, dock._tileset_panel._layer == _fixture_layer, "面板应立即绑定该层目标。")
	_check(NAME, not dock._action_panel.visible, "ObjectVisual 操作区应隐藏。")
	_check(NAME, not dock._visual_value.visible and not dock._component_value.visible, "ObjectVisual 专属字段应隐藏。")
	var hidden_count: int = 0
	for control in dock._objectvisual_field_controls:
		if is_instance_valid(control) and not control.visible:
			hidden_count += 1
	_check(NAME, hidden_count == dock._objectvisual_field_controls.size(), "ObjectVisual 字段对应全部隐藏。")
	_check(NAME, not dock._status_label.text.contains("不属于可编辑"), "不得落入 Resolver UNSUPPORTED 提示。")
	_check(NAME, dock._status_label.text.contains("TileMapLayer"), "状态应说明已进入 TileSet 替换模式。")
	_check(NAME, dock._selected_value.text == _fixture_layer.name, "当前对象字段应显示层名。")
	# 立即可分析：单图集源不出选择器；确认/替换保持禁用等待输入。
	_check(NAME, not dock._tileset_panel._source_selector.visible, "单图集源不应显示图集源选择器。")
	_check(NAME, dock._tileset_panel._status_label.text.contains("分析"), "面板应提示输入路径后分析。")
	_check(NAME, dock._tileset_panel._confirm_box.disabled and dock._tileset_panel._apply_button.disabled, "未分析前确认/替换应禁用。")
	dock.free()


## R02 继承 TileMapLayer 的脚本子类经 is 判定同样路由。
func _test_r02_subclass_is_routing() -> void:
	const NAME: String = "R02_子类is判定路由"
	var dock = _make_dock()
	var sub: TileMapLayer = _SubTileMapLayer.new()
	sub.tile_set = _fixture_tileset
	_leak_guard.append(sub)
	dock.show_selection([sub])
	_check(NAME, dock._tileset_panel.visible, "脚本子类选中应显示 TileSet 面板。")
	_check(NAME, dock._tileset_panel._layer == sub, "is 判定应覆盖继承 TileMapLayer 的子类。")
	_check(NAME, not dock._action_panel.visible, "子类路由同样隐藏 ObjectVisual 区。")
	dock.free()


## R03 切回 ObjectVisual：TileSet 面板反向隐藏；已签发的一次性确认 token 作废。
func _test_r03_switch_to_objectvisual() -> void:
	const NAME: String = "R03_切回ObjectVisual反向隐藏"
	var dock = _make_dock()
	# 先进入 TileMap 模式并完成一次分析，取得有效 token。
	dock.show_selection([_fixture_layer])
	var panel = dock._tileset_panel
	panel._service.set_scene_scan_roots(PackedStringArray([_TEST_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	panel._path_edit.text = String(new_png.path)
	panel._on_analyze_pressed()
	_check(NAME, panel._token >= 0, "前置：分析成功应签发 token。")
	panel._on_confirm_toggled(true)
	_check(NAME, not panel._apply_button.disabled, "前置：勾选确认后替换可用。")
	# 切回 ObjectVisual：面板隐藏、目标清空、token 作废。
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	_check(NAME, not panel.visible, "切回 ObjectVisual 应隐藏 TileSet 面板。")
	_check(NAME, panel._layer == null, "面板目标应清空。")
	_check(NAME, panel._token == -1, "切换选择不得保留旧确认 token。")
	_check(NAME, panel._confirm_box.button_pressed == false and panel._apply_button.disabled, "确认与替换应回到禁用。")
	_check(NAME, dock._action_panel.visible, "ObjectVisual 操作区应恢复显示。")
	_check(NAME, dock._visual_value.visible and dock._profile_value.visible, "ObjectVisual 专属字段应恢复显示。")
	_check(NAME, dock.get_active_visual_target() == view, "单目标应返回该视觉。")
	dock.free()
	view.free()


## R04 空选 / 多选：两区安全清空，不残留目标或旧提示。
func _test_r04_empty_and_multi_clear() -> void:
	const NAME: String = "R04_空选多选安全清空"
	var dock = _make_dock()
	var view = _make_stub_with_profile()
	dock.show_selection([view])
	_check(NAME, dock._tileset_panel._layer == null, "前置：ObjectVisual 选择下 TileSet 目标为空。")
	dock.show_selection([])
	_check(NAME, not dock._tileset_panel.visible, "空选应隐藏 TileSet 面板。")
	_check(NAME, dock._tileset_panel._layer == null and dock._tileset_panel._token == -1, "空选应清空面板目标与 token。")
	_check(NAME, dock._action_panel.visible, "空选下 ObjectVisual 区保持显示。")
	_check(NAME, dock._status_label.text.contains("请先在场景树中选择"), "空选应显示选择引导。")
	_check(NAME, dock._selected_value.text == "", "空选应清空当前对象字段。")
	var view2 = _make_stub_with_profile()
	dock.show_selection([view, view2])
	_check(NAME, not dock._tileset_panel.visible, "多选应隐藏 TileSet 面板。")
	_check(NAME, dock._status_label.text.contains("一次只能编辑一个对象"), "多选应显示单选引导。")
	_check(NAME, dock._selected_value.text == "", "多选应清空当前对象字段。")
	dock.free()
	view.free()
	view2.free()


## R05 父 Node2D 不猜子节点：选 Walls 类父节点不进入 TileMap 模式。
func _test_r05_parent_node2d_not_guessed() -> void:
	const NAME: String = "R05_父Node2D不猜子节点"
	var dock = _make_dock()
	var parent: Node2D = Node2D.new()
	parent.name = "Walls"
	var child: TileMapLayer = TileMapLayer.new()
	child.tile_set = _fixture_tileset
	parent.add_child(child)
	_leak_guard.append(parent)
	dock.show_selection([parent])
	_check(NAME, not dock._tileset_panel.visible, "选中父 Node2D 不应显示 TileSet 面板。")
	_check(NAME, dock._tileset_panel._layer == null, "不得猜测父节点下的 TileMapLayer 子节点。")
	_check(NAME, dock._action_panel.visible, "父 Node2D 走 ObjectVisual 展示路径。")
	_check(NAME, dock._status_label.text.contains("不属于可编辑"), "非组件父节点应显示 UNSUPPORTED 提示。")
	dock.free()


## R06 模拟 plugin.gd 转发的 EditorSelection 连续通知顺序。
func _test_r06_selection_notification_sequence() -> void:
	const NAME: String = "R06_通知顺序模拟"
	var dock = _make_dock()
	var view = _make_stub_with_profile()
	# 空选（插件启用首拍）→ TileMapLayer → ObjectVisual → TileMapLayer → 空选。
	dock.show_selection([])
	_check(NAME, not dock._tileset_panel.visible and dock._action_panel.visible, "首拍空选应为 ObjectVisual 空态。")
	dock.show_selection([_fixture_layer])
	_check(NAME, dock._tileset_panel.visible and not dock._action_panel.visible, "第二拍 TileMapLayer 应切换到 TileSet 模式。")
	dock.show_selection([view])
	_check(NAME, not dock._tileset_panel.visible and dock._action_panel.visible, "第三拍 ObjectVisual 应切回并隐藏 TileSet 面板。")
	dock.show_selection([_fixture_layer])
	_check(NAME, dock._tileset_panel.visible and dock._tileset_panel._layer == _fixture_layer, "第四拍重新选中层应恢复绑定。")
	_check(NAME, dock._tileset_panel._status_label.text.contains("分析"), "重选后面板应重新可分析。")
	dock.show_selection([])
	_check(NAME, not dock._tileset_panel.visible and dock._tileset_panel._layer == null, "末拍空选应清空面板。")
	_check(NAME, dock._status_label.text.contains("请先在场景树中选择"), "末拍空选应回到选择引导。")
	dock.free()
	view.free()


# ===== fixture 辅助 =====

## 创建入树的 Dock 实例（与边界测试同构：真实场景实例化 + _ready）。
func _make_dock() -> VBoxContainer:
	var dock: VBoxContainer = _DockScene.instantiate() as VBoxContainer
	root.add_child(dock)
	dock._ready()
	return dock


## 生成带路径的 PNG 纹理 fixture（user:// 经 Image 包装为带 resource_path 的 ImageTexture）。
## 返回 {tex, path}；生成失败时直接记失败断言并由调用方中止该组。
func _make_png(name: String, width: int, height: int, color: Color) -> Dictionary:
	var path: String = "%s/%s_%s.png" % [_TEST_DIR, name, _serial]
	var image: Image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	image.fill(color)
	image.save_png(path)
	var loaded: Image = Image.load_from_file(path)
	var texture: ImageTexture = ImageTexture.create_from_image(loaded)
	texture.take_over_path(path)
	return {tex = texture, path = path}


## 创建带两状态（unlit/lit）profile 的 _StubVisual，未入树。
func _make_stub_with_profile() -> ObjectVisualView:
	var view: _StubVisual = _StubVisual.new()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var unlit: _VisualStateTexture = _VisualStateTexture.new()
	unlit.state_id = &"unlit"
	unlit.world_texture = PlaceholderTexture2D.new()
	var lit: _VisualStateTexture = _VisualStateTexture.new()
	lit.state_id = &"lit"
	lit.world_texture = PlaceholderTexture2D.new()
	profile.states = [unlit, lit]
	view.visual_profile = profile
	return view


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 释放全部游离 fixture 节点，保证退出零泄漏。无返回值。
func _cleanup() -> void:
	for node in _leak_guard:
		if is_instance_valid(node):
			node.free()
	_leak_guard.clear()


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== ArtProfileDock TileSet 路由测试摘要 ====")
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
