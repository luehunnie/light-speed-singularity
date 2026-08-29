extends SceneTree

# 阶段B 第三次 GUI Gate 后补的真实 UI 级契约测试：此前声明层测试（服务字段断言）全绿，
# 但 Human 截图缺"光颜色水晶/滤光片"——缺口在"真实面板可见行"未被任何测试钉住。
# 本测试实例化真实 Dock + 真实面板（content_palette / inventory），断言 Human 眼中可见的
# ItemList 行文本与 OptionButton 条目，并驱动真实"放置到关卡 / 切换颜色"按钮路径。
# 第三次 Gate 审查结论：工作树内真实 UI 数据流正确（7 项 Palette / 5 项下拉）；
# 截图 5+3 的根因是编辑器实例开在主检出（无本批未提交文件），见审查报告。本测试防止
# 面板装配/条目构建接线回归，不再只信服务层。由 Godot --script 运行；失败 quit(1)。


const _Dock: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/level_authoring_dock.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)
const _RayColor: GDScript = preload(
	"res://gameplay/light/ray_color.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


# 编辑器桥替身（与 level_authoring_dock_test 同款口径）：提供内存关卡根。
class StubBridge extends RefCounted:
	var current_root: Node2D = null

	func get_current_scene_path() -> String:
		return "res://levels/campaign/ray_chapter/level_ray_001.tscn" if current_root != null else ""

	func get_edited_level_root() -> Node2D:
		return current_root


func _initialize() -> void:
	var root := _LevelRay001.instantiate() as Node2D
	get_root().add_child(root)
	var dock: CanvasItem = _Dock.new()
	var bridge := StubBridge.new()
	bridge.current_root = root
	dock.set_editor_bridge(bridge)
	dock.set_undo_redo(UndoRedo.new())
	dock._ready()

	_test_01_palette_visible_rows(dock)
	_test_02_inventory_visible_options(dock)
	_test_03_place_and_cycle_color_via_panel(dock, root)
	dock.free()
	root.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _palette(dock: CanvasItem) -> Object:
	return dock.get_panel("content_palette")


func _test_01_palette_visible_rows(dock: CanvasItem) -> void:
	const NAME: String = "01_Palette可见行"
	var list: ItemList = _palette(dock).get("_list")
	var rows: PackedStringArray = PackedStringArray()
	for i: int in list.item_count:
		rows.append(list.get_item_text(i))
	# 光颜色水晶为单一正式项，行文本带 category 后缀（Human 截图口径）。
	var color_rows: PackedStringArray = PackedStringArray()
	for row: String in rows:
		if row.begins_with("光颜色水晶"):
			color_rows.append(row)
	_check(NAME, color_rows.size() == 1 and color_rows[0] == "光颜色水晶（objectives）",
		"Palette 应恰好一行 光颜色水晶（objectives），实际 %s。" % str(rows))
	_check(NAME, rows.has("滤光片（optics）"),
		"Palette 应含 滤光片（optics）行，实际 %s。" % str(rows))
	for legacy: String in ["红水晶", "绿水晶", "蓝水晶"]:
		var found := false
		for row: String in rows:
			if row.begins_with(legacy):
				found = true
		_check(NAME, not found, "旧三色独立项 %s 不应再出现（单一项取代）。" % legacy)


func _test_02_inventory_visible_options(dock: CanvasItem) -> void:
	const NAME: String = "02_Inventory可见下拉"
	var options: OptionButton = dock.get_panel("inventory").get("_type_options")
	var by_metadata: Dictionary = {}
	for i: int in options.item_count:
		by_metadata[options.get_item_metadata(i)] = options.get_item_text(i)
	_check(NAME, by_metadata.has("color_crystal") and by_metadata["color_crystal"] == "光颜色水晶",
		"类型下拉应含 光颜色水晶（color_crystal），实际 %s。" % str(by_metadata))
	_check(NAME, by_metadata.has("light_filter") and by_metadata["light_filter"] == "滤光片",
		"类型下拉应含 滤光片（light_filter），实际 %s。" % str(by_metadata))
	for not_eligible: String in ["basic_crystal", "main_emitter"]:
		_check(NAME, not by_metadata.has(not_eligible),
			"%s 未声明入库资格，不应出现在下拉。" % not_eligible)


func _test_03_place_and_cycle_color_via_panel(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "03_面板放置与颜色入口"
	var palette: Object = _palette(dock)
	var list: ItemList = palette.get("_list")
	var color_row_index := -1
	for i: int in list.item_count:
		if list.get_item_text(i).begins_with("光颜色水晶"):
			color_row_index = i
			break
	if not _check(NAME, color_row_index >= 0, "Palette 应存在光颜色水晶行（前置）。"):
		return
	list.select(color_row_index)
	var runtime_objects: Node = root.get_node("RuntimeObjects")
	var objects_before: int = runtime_objects.get_child_count()
	palette.call("_on_place_selected")
	_check(NAME, runtime_objects.get_child_count() == objects_before + 1,
		"经真实放置按钮后 RuntimeObjects 应 +1 节点。")
	if runtime_objects.get_child_count() != objects_before + 1:
		return
	var placed: Node = runtime_objects.get_child(runtime_objects.get_child_count() - 1)
	_check(NAME, placed.owner == root, "放置节点 owner 应为关卡根（保存链事实）。")
	_check(NAME, placed.get("crystal_color") == _RayColor.ColorValue.RED,
		"放置后默认颜色应为红（RED），实际 %s。" % str(placed.get("crystal_color")))
	# 颜色入口按钮接线：选中后启用，点击循环到绿，可撤销回红。
	dock.notify_selection_changed([root, placed])
	_check(NAME, not palette.get("_color_button").disabled,
		"选中光颜色水晶后颜色入口应启用。")
	palette.call("_on_cycle_color_selected")
	_check(NAME, placed.get("crystal_color") == _RayColor.ColorValue.GREEN,
		"面板切换颜色后应为绿（GREEN），实际 %s。" % str(placed.get("crystal_color")))
	dock._on_undo_pressed()
	_check(NAME, placed.get("crystal_color") == _RayColor.ColorValue.RED,
		"撤销颜色切换应恢复红。")
	# 非颜色对象选择时入口禁用（按钮门控回归）。
	dock.notify_selection_changed([root])
	_check(NAME, palette.get("_color_button").disabled,
		"取消选择后颜色入口应禁用。")


func _check(group: String, condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])
	return condition


func _report() -> void:
	print("real_ui_entries_test: %d checks, %d failures" % [_checks, _failures.size()])
