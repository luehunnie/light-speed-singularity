@tool
extends VBoxContainer

# Inventory Editor 面板（Guide §15.1，AF-09）：关卡库存条目的无代码配置。
# 条目只编辑 content_type_id / initial_quantity / order 三项（显示名/图标/描述来自 Definition）；
# 类型下拉只列 Registry 中 inventory_eligible 的正式类型（不硬编码名单）；应用 = 整域校验 +
# 一次 meta 事务（可撤销）。Typed 输入：类型 OptionButton、数量/顺序 SpinBox，无自由文本域。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)

const PANEL_KEY: String = "inventory"

var _ctx: Object = null
var _entries: Array = []
var _list: ItemList
var _type_options: OptionButton
var _quantity_spin: SpinBox
var _order_spin: SpinBox


func setup(context: Object) -> void:
	_ctx = context
	var header := Label.new()
	header.text = "Inventory（关卡库存：每类型数量与顺序在此设置）"
	header.modulate = Color(0.8, 0.85, 1.0)
	add_child(header)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 84)
	add_child(_list)
	var add_row := HBoxContainer.new()
	_type_options = OptionButton.new()
	add_row.add_child(_type_options)
	_quantity_spin = _spin("数量", 0, 999, 1)
	add_row.add_child(_quantity_spin)
	_order_spin = _spin("顺序", 0, 999, 0)
	add_row.add_child(_order_spin)
	add_row.add_child(_button("添加条目", _on_add_entry))
	add_child(add_row)
	var edit_row := HBoxContainer.new()
	edit_row.add_child(_button("数量+1", _on_increment_quantity))
	edit_row.add_child(_button("上移", _on_move_up))
	edit_row.add_child(_button("下移", _on_move_down))
	edit_row.add_child(_button("移除所选", _on_remove_entry))
	edit_row.add_child(_button("应用", _on_apply))
	add_child(edit_row)


func refresh() -> void:
	var root: Node2D = _ctx.edited_root()
	_entries = _BusinessData.read_inventory(root) if root != null else []
	# 列表顺序即作者顺序：读取时按 order 稳定排序。
	_entries.sort_custom(func(a, b): return int(a.get("order", 0)) < int(b.get("order", 0)))
	_type_options.clear()
	for option: Dictionary in _BusinessData.get_inventory_eligible_types(_ctx.get_registry()):
		_type_options.add_item("%s" % option.display_name)
		_type_options.set_item_metadata(-1, String(option.type_id))
	if _type_options.item_count > 0 and _type_options.selected < 0:
		_type_options.select(0)
	_rebuild_list()


func _rebuild_list() -> void:
	_list.clear()
	for entry: Variant in _entries:
		_list.add_item("%s ×%d（顺序 %d）" % [
			_display_name_for(str(entry.get("content_type_id", ""))),
			entry.get("initial_quantity", 0), entry.get("order", 0)])


func _spin(title: String, min_value: float, max_value: float, value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.value = value
	spin.suffix = title
	spin.custom_minimum_size = Vector2(96, 0)
	return spin


func _button(title: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(handler)
	return button


func _selected_entry_index() -> int:
	var selected := _list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _on_add_entry() -> void:
	if _type_options.item_count == 0:
		_ctx.log_message("Registry 中没有可入库类型（inventory_eligible）。")
		return
	var type_id: String = _type_options.get_item_metadata(_type_options.selected)
	var display := _display_name_for(type_id)
	var existing := _find_entry_by_type(type_id)
	if not existing.is_empty():
		existing["initial_quantity"] = int(existing["initial_quantity"]) + 1
		_ctx.log_message("Inventory：%s 已有条目，数量 +1 → ×%d（每类型一条）。" % [
			display, int(existing["initial_quantity"])])
	else:
		_entries.append({
			"content_type_id": type_id,
			"initial_quantity": int(_quantity_spin.value),
			"order": int(_order_spin.value),
		})
		_ctx.log_message("Inventory：已添加 %s ×%d（顺序 %d）；点「应用」写入关卡（Ctrl+S 保存生效）。" % [
			display, int(_quantity_spin.value), int(_order_spin.value)])
	_rebuild_list()


# 类型显示名（与列表行同源；Registry 缺定义时退回 type_id）。
func _display_name_for(type_id: String) -> String:
	var definition: Variant = _ctx.get_registry().get_definition(StringName(type_id))
	return definition.display_name if definition != null else type_id


func _find_entry_by_type(type_id: String) -> Dictionary:
	for entry: Variant in _entries:
		if str(entry.get("content_type_id", "")) == type_id:
			return entry
	return {}


func _on_increment_quantity() -> void:
	var index := _selected_entry_index()
	if index < 0:
		_ctx.log_message("请先在库存列表选择一个条目。")
		return
	_entries[index]["initial_quantity"] = int(_entries[index]["initial_quantity"]) + 1
	_rebuild_list()


func _on_move_up() -> void:
	_swap_entry(-1)


func _on_move_down() -> void:
	_swap_entry(1)


func _swap_entry(direction: int) -> void:
	var index := _selected_entry_index()
	var other := index + direction
	if index < 0 or other < 0 or other >= _entries.size():
		return
	var temp: Variant = _entries[index]
	_entries[index] = _entries[other]
	_entries[other] = temp
	_rebuild_list()
	_list.select(other)


func _on_remove_entry() -> void:
	var index := _selected_entry_index()
	if index < 0:
		_ctx.log_message("请先在库存列表选择一个条目。")
		return
	_entries.remove_at(index)
	_rebuild_list()


func _on_apply() -> void:
	# 列表顺序即作者顺序（order 由列表序派生，不维护第二套事实）。
	for index: int in _entries.size():
		_entries[index]["order"] = index
	var problems: PackedStringArray = _BusinessData.validate_inventory(_entries, _ctx.get_registry())
	if not problems.is_empty():
		_ctx.log_message("Inventory 校验未通过：%s" % "；".join(problems))
		return
	if _ctx.commit_meta(_BusinessData.META_INVENTORY, _entries, "配置 Inventory"):
		var summary: PackedStringArray = PackedStringArray()
		for entry: Variant in _entries:
			summary.append("%s ×%d" % [_display_name_for(str(entry.get("content_type_id", ""))),
				int(entry.get("initial_quantity", 0))])
		_ctx.log_message("Inventory 已应用：%s（共 %d 条目，Ctrl+S 保存关卡生效）。" % [
			"、".join(summary) if not summary.is_empty() else "空库存", _entries.size()])
