@tool
extends VBoxContainer

# 正式对象面板（Guide §7/§9）：Content Palette 放置 + 所选对象操作（方向旋转 / Stable ID 修复 / 撤销）。
# 放置与修复业务在 PaletteService / StableIdService；本面板只做列表与事务接线。


const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _EditorTransaction: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_transaction.gd"
)

const PANEL_KEY: String = "content_palette"

var _ctx: Object = null
var _list: ItemList
var _type_ids: Array[StringName] = []
var _rotate_button: Button
var _color_button: Button


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "正式内容 Palette 与所选对象"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 110)
	add_child(_list)
	var palette_row := HBoxContainer.new()
	palette_row.add_child(_button("刷新", _on_refresh_palette))
	palette_row.add_child(_button("放置到关卡", _on_place_selected))
	palette_row.add_child(_button("撤销一步", _on_undo))
	add_child(palette_row)
	var select_row := HBoxContainer.new()
	_rotate_button = _button("旋转方向（R 同款字段）", _on_rotate_selected)
	_rotate_button.disabled = true
	select_row.add_child(_rotate_button)
	_color_button = _button("切换颜色（光颜色水晶）", _on_cycle_color_selected)
	_color_button.disabled = true
	select_row.add_child(_color_button)
	select_row.add_child(_button("修复 Stable ID", _on_repair_stable_ids))
	add_child(select_row)


func refresh() -> void:
	_on_refresh_palette()


# 选择变化：驱动旋转 / 颜色入口可用性（未拾取态时由 Dock 广播）。
func on_selection_changed(formal_nodes: Array[Node]) -> void:
	_rotate_button.disabled = formal_nodes.is_empty()
	_color_button.disabled = formal_nodes.is_empty() or not formal_nodes[0].has_method("cycle_color")


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _on_refresh_palette() -> void:
	_list.clear()
	_type_ids = []
	var registry = _ctx.get_registry()
	if registry == null:
		_ctx.log_message("正式内容声明发现失败（见 Output 错误），Palette 不可用。")
		return
	for entry: Dictionary in _PaletteService.build_palette_entries(registry):
		_type_ids.append(entry.type_id)
		_list.add_item("%s（%s）" % [entry.display_name, entry.category])


func _on_place_selected() -> void:
	var selected_indices := _list.get_selected_items()
	if selected_indices.is_empty():
		_ctx.log_message("请先在 Palette 中选择一个正式类型。")
		return
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("放置失败：当前场景不是关卡（缺少关卡根）。")
		return
	var type_id: StringName = _type_ids[selected_indices[0]]
	var palette := _PaletteService.new()
	var result: Dictionary = palette.place(_ctx.get_registry(), type_id, root, false)
	if not result.ok:
		_ctx.log_message("放置失败：%s" % result.reason)
		return
	var placed: Node = result.node
	var container: Node = result.container
	# add/remove_child 作用于容器；owner 只登记 do 侧且作用于 placed 本体。AF-09 P0：placed 入树前登记
	# undo owner 属性会触发真实 EditorUndoRedoManager 的 node.cpp common_parent is null——undo 段仅
	# remove_child，redo 重放 add_child + owner 恢复同一节点与归属（undo 后节点保持存活）。
	var operations: Array = [
		{
			"target": container,
			"do": ["add_child", [placed]],
			"undo": ["remove_child", [placed]],
		},
		{
			"target": placed,
			"do_properties": [["owner", root]],
		},
	]
	if not _EditorTransaction.commit(_ctx._get_undo_redo(), "Palette 放置 %s" % type_id, operations, root):
		placed.free()
		_ctx.log_message("放置失败：编辑事务未提交（见 Output 错误），节点未入树。")
		return
	_ctx.refresh_all()
	_ctx.log_message("已放置 %s 于 %s（稳定 ID %s）。" % [type_id, result.cell, result.stable_instance_id])


func _on_undo() -> void:
	_ctx._on_undo_pressed()


func _on_rotate_selected() -> void:
	var selected: Array[Node] = _ctx._last_selected_formal()
	if selected.is_empty():
		return
	var node: Node = selected[0]
	var method := ""
	var field := ""
	if node.has_method("cycle_direction"):
		method = "cycle_direction"
		field = "direction"
	elif node.has_method("toggle_orientation"):
		method = "toggle_orientation"
		field = "orientation"
	else:
		_ctx.log_message("所选对象不支持方向旋转（单方向 / 无方向机制自动禁用）。")
		return
	var old_value: Variant = node.get(field)
	var operations: Array = [{
		"target": node,
		"do": [method, []],
		"undo": ["set", [field, old_value]],
	}]
	_EditorTransaction.commit(_ctx._get_undo_redo(), "旋转方向", operations)


# 切换所选光颜色水晶颜色（红→绿→蓝循环；默认红，放置后作者入口，与 Inspector 枚举同字段同事实）。
func _on_cycle_color_selected() -> void:
	var selected: Array[Node] = _ctx._last_selected_formal()
	if selected.is_empty():
		return
	var node: Node = selected[0]
	if not node.has_method("cycle_color"):
		_ctx.log_message("所选对象不支持颜色切换（仅光颜色水晶）。")
		return
	var old_color: Variant = node.get("crystal_color")
	var operations: Array = [{
		"target": node,
		"do": ["cycle_color", []],
		"undo": ["set", ["crystal_color", old_color]],
	}]
	_EditorTransaction.commit(_ctx._get_undo_redo(), "切换颜色", operations)


func _on_repair_stable_ids() -> void:
	var root: Node2D = _ctx.edited_root()
	if root == null:
		_ctx.log_message("请先打开一个关卡场景。")
		return
	var audit: Dictionary = _StableIdService.audit(root)
	var assigned: int = _StableIdService.assign_missing(root)
	var message := "Stable ID：共 %d 正式对象，补发 %d，重复 %d。" % [audit.total, assigned, audit.duplicates.size()]
	if not (audit.duplicates as Array).is_empty():
		message += "（重复 ID 需人工确认保留者：%s）" % ", ".join(audit.duplicates)
	_ctx.log_message(message)
	_ctx.refresh_all()
