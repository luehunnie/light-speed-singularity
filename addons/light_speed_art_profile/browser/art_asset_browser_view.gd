@tool
class_name LightSpeedArtProfileArtAssetBrowserView
extends Control

## 美术资产浏览器视图（D4.5-B2A）。
## 职责：刷新美术库、动态目录树、文件名/路径搜索、文字结果列表、大图预览。
## 输入输出：只消费 ArtAssetCatalog 与 ArtAssetBrowserModel；不接收外部节点，不返回值。
## 副作用：仅调用 Catalog.scan()（只读文件系统）与更新自身控件；不修改 Profile、art 或场景树。
## 边界：不重载 Texture2D（直接用 Entry.texture）；不做缩略图网格/分页（留待 B2B）；
##       不监听 EditorFileSystem 自动变更（留待 D4.5-E）；选择素材不影响 Profile 状态。

const _CatalogScript: GDScript = preload(
	"res://addons/light_speed_art_profile/browser/art_asset_catalog.gd"
)
const _ModelScript: GDScript = preload(
	"res://addons/light_speed_art_profile/browser/art_asset_browser_model.gd"
)

var _catalog: RefCounted = _CatalogScript.new()
var _model: RefCounted = _ModelScript.new()

var _tree: Tree = null
var _search: LineEdit = null
var _result_list: ItemList = null
var _result_hint: Label = null
var _preview_rect: TextureRect = null
var _preview_filename: Label = null
var _preview_path: Label = null
var _preview_dir: Label = null
var _preview_ext: Label = null
var _preview_size: Label = null
var _preview_status: Label = null
var _status_label: Label = null
var _refresh_button: Button = null
var _root_tree_item: TreeItem = null
var _ui_ready: bool = false


## 初始化浏览器 UI 并执行首次只读扫描。
## 无参数无返回；副作用为构建控件树、连接信号、触发一次 Catalog.scan()。
func _ready() -> void:
	_ensure_ui()


## 创建一次性 UI 结构；重复调用安全。
## 无参数无返回；仅在控件缺失时构建，并完成首次刷新。
func _ensure_ui() -> void:
	if _ui_ready:
		return
	_ui_ready = true
	custom_minimum_size = Vector2(340, 320)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	var title := Label.new()
	title.text = "美术资产浏览器"
	vbox.add_child(title)

	# 顶栏：刷新按钮 + 搜索框
	var topbar := HBoxContainer.new()
	_refresh_button = Button.new()
	_refresh_button.text = "刷新美术库"
	_refresh_button.pressed.connect(_on_refresh_pressed)
	topbar.add_child(_refresh_button)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索文件名/路径..."
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	topbar.add_child(_search)
	vbox.add_child(topbar)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	# 主区：左侧目录树+结果列表，右侧大图预览
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)
	var dir_label := Label.new()
	dir_label.text = "目录"
	left.add_child(dir_label)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_tree_selected)
	left.add_child(_tree)

	var result_label := Label.new()
	result_label.text = "结果"
	left.add_child(result_label)
	_result_hint = Label.new()
	_result_hint.text = "此分类暂无可用图片"
	_result_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_result_hint.visible = false
	left.add_child(_result_hint)
	_result_list = ItemList.new()
	_result_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_result_list.item_selected.connect(_on_result_selected)
	left.add_child(_result_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var prev_title := Label.new()
	prev_title.text = "预览"
	right.add_child(prev_title)
	_preview_rect = TextureRect.new()
	_preview_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	right.add_child(_preview_rect)
	_preview_filename = _add_preview_field(right, "文件名")
	_preview_path = _add_preview_field(right, "res:// 路径")
	_preview_dir = _add_preview_field(right, "相对目录")
	_preview_ext = _add_preview_field(right, "扩展名")
	_preview_size = _add_preview_field(right, "像素尺寸")
	_preview_status = Label.new()
	_preview_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_preview_status)

	_refresh_from_catalog()


## 新增一组预览字段标签；title 为字段名，返回可后续写入的值 Label。
func _add_preview_field(parent: Control, title: String) -> Label:
	var name_label := Label.new()
	name_label.text = title
	name_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	parent.add_child(name_label)
	var value_label := Label.new()
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.text = "-"
	parent.add_child(value_label)
	return value_label


## 刷新按钮回调：重新扫描并重建目录树与结果列表。
## 无参数无返回；保留仍存在的选择，清空失效选择与预览。
func _on_refresh_pressed() -> void:
	_refresh_from_catalog()


## 搜索框回调：即时更新过滤结果，不重新扫描。
## new_text 为当前搜索文本；无返回。
func _on_search_changed(new_text: String) -> void:
	_model.set_query(new_text)
	_refresh_result_list()


## 目录树选择回调：切换当前目录并刷新结果列表。
## 无参数无返回；不修改选择与预览状态。
func _on_tree_selected() -> void:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return
	var dir: String = item.get_metadata(0)
	_model.set_directory(dir)
	_refresh_result_list()


## 结果列表选择回调：保存选中 resource_path 并更新右侧预览。
## index 为选中项索引；无返回；不修改任何 Profile。
func _on_result_selected(index: int) -> void:
	var path = _result_list.get_item_metadata(index)
	if path == null:
		return
	_model.select_entry(path)
	_update_preview()


## 执行一次只读扫描，更新 Model、目录树、结果列表与状态。
## 无参数无返回；扫描错误数量写入状态标签。
func _refresh_from_catalog() -> void:
	_catalog.scan()
	var entries: Array = _catalog.get_entries()
	var dirs: Array = _catalog.get_directories()
	var errors: Array = _catalog.get_errors()
	_model.set_catalog_data(entries, dirs, errors)
	_rebuild_tree()
	_refresh_result_list()
	if errors.is_empty():
		_status_label.text = "已刷新美术库（%d 项）。" % entries.size()
	else:
		_status_label.text = "已刷新（%d 项，扫描错误 %d 条）。" % [entries.size(), errors.size()]


## 按 Model 当前目录重建目录树；根显示为 assets/art，子目录按真实层级嵌套。
## 无参数无返回；不硬编码分类名；刷新后失效目录回根由 Model 处理，此处同步选中。
func _rebuild_tree() -> void:
	_tree.clear()
	_root_tree_item = _tree.create_item()
	_root_tree_item.set_text(0, "assets/art")
	_root_tree_item.set_metadata(0, "") # 根 = 全部资源
	for dir: String in _model.get_directories():
		_ensure_tree_path(dir)
	_select_tree_for_directory(_model.get_current_directory())


## 沿相对目录路径创建嵌套 TreeItem；每个节点 metadata 为其完整相对目录。
## rel_dir 为相对 ART_ROOT 的目录字符串；无返回。
func _ensure_tree_path(rel_dir: String) -> void:
	var parts := rel_dir.split("/")
	var parent: TreeItem = _root_tree_item
	var acc := ""
	for part: String in parts:
		acc = acc.path_join(part)
		var child: TreeItem = _find_tree_child(parent, part)
		if child == null:
			child = _tree.create_item(parent)
			child.set_text(0, part)
			child.set_metadata(0, acc)
		parent = child


## 在父节点直接子级中按显示文本查找 TreeItem；返回匹配项或 null。
func _find_tree_child(parent: TreeItem, text: String) -> TreeItem:
	var child: TreeItem = parent.get_first_child()
	while child != null:
		if child.get_text(0) == text:
			return child
		child = child.get_next()
	return null


## 选中与指定目录对应的 TreeItem；dir 为 "" 时选中根。阻塞信号避免回调回流。
func _select_tree_for_directory(dir: String) -> void:
	_tree.set_block_signals(true)
	if dir == "":
		_root_tree_item.select(0)
	else:
		var item: TreeItem = _find_tree_item_by_metadata(_root_tree_item, dir)
		if item != null:
			item.select(0)
		else:
			_root_tree_item.select(0)
	_tree.set_block_signals(false)


## 递归查找 metadata 等于 dir 的 TreeItem；返回匹配项或 null。
func _find_tree_item_by_metadata(root: TreeItem, dir: String) -> TreeItem:
	var item: TreeItem = root
	while item != null:
		if String(item.get_metadata(0)) == dir:
			return item
		var child: TreeItem = item.get_first_child()
		while child != null:
			var found: TreeItem = _find_tree_item_by_metadata(child, dir)
			if found != null:
				return found
			child = child.get_next()
		return null
	return null


## 按 Model 当前过滤结果重建文字列表；每项显示 file_name、relative_directory、texture_size。
## 无参数无返回；保留当前选中项的高亮；空结果显示提示标签。
func _refresh_result_list() -> void:
	_result_list.clear()
	var entries: Array = _model.get_filtered_entries()
	if entries.is_empty():
		_result_hint.visible = true
		_update_preview()
		return
	_result_hint.visible = false
	var selected_path: String = _model.get_selected_resource_path()
	var select_index := -1
	for i: int in range(entries.size()):
		var entry = entries[i]
		var dir_text: String = entry.relative_directory if entry.relative_directory != "" else "/"
		var text := "%s  [%s]  %dx%d" % [entry.file_name, dir_text, entry.texture_size.x, entry.texture_size.y]
		var idx: int = _result_list.add_item(text)
		_result_list.set_item_metadata(idx, entry.resource_path)
		if entry.resource_path == selected_path:
			select_index = idx
	if select_index >= 0:
		_result_list.select(select_index)
	_update_preview()


## 按 Model 当前选中条目更新右侧大图预览。
## 无参数无返回；无选择时清空旧预览；资源失效时显示明确错误；不重新 ResourceLoader.load。
func _update_preview() -> void:
	var entry = _model.get_selected_entry()
	if entry == null:
		_preview_rect.texture = null
		_preview_filename.text = "-"
		_preview_path.text = "-"
		_preview_dir.text = "-"
		_preview_ext.text = "-"
		_preview_size.text = "-"
		_preview_status.text = "未选择素材。"
		return
	# 路径信息无论纹理是否可用都展示，便于定位失效资源
	_preview_filename.text = entry.file_name
	_preview_path.text = entry.resource_path
	_preview_dir.text = entry.relative_directory if entry.relative_directory != "" else "(根目录)"
	_preview_ext.text = entry.extension
	_preview_size.text = "%d × %d" % [entry.texture_size.x, entry.texture_size.y]
	if entry.texture == null or not is_instance_valid(entry.texture):
		_preview_rect.texture = null
		_preview_status.text = "资源失效：纹理不可用。"
		return
	_preview_rect.texture = entry.texture
	_preview_status.text = "已选择素材。"
