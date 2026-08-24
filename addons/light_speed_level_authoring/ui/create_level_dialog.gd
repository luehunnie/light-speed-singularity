@tool
extends AcceptDialog

# AF-08 Create / Duplicate Level 向导对话框（Guide §5）：内容人员只输入面向人的显示名称与章节，
# 技术文件名 / 保存路径 / 稳定 level_id 全部由 LevelFileService 系统管理，本对话框不暴露任何技术身份字段。


signal confirmed_level(display_name: String, chapter: String)

## 关卡保存根目录（与 LevelFileService.CAMPAIGN_ROOT 一致；注入以便测试隔离）。
@export var campaign_root: String = "res://levels/campaign"

var _display_name_edit: LineEdit
var _chapter_option: OptionButton


func _ready() -> void:
	title = "新建关卡"
	about_to_popup.connect(_refresh)
	confirmed.connect(_on_confirmed)
	_build_ui()


## 构建最小输入面：显示名称 + 章节下拉（campaign 子目录即章节 token）。
func _build_ui() -> void:
	var column := VBoxContainer.new()
	column.add_child(_label("显示名称（玩家可见，可随时修改；不影响关卡 ID）"))
	_display_name_edit = LineEdit.new()
	_display_name_edit.placeholder_text = "例如：第一道光"
	column.add_child(_display_name_edit)
	column.add_child(_label("章节（决定保存目录与技术文件名前缀）"))
	_chapter_option = OptionButton.new()
	column.add_child(_chapter_option)
	add_child(column)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# 每次打开刷新章节列表（保持与目录现状一致；无子目录时回退 ray_chapter）。
func _refresh() -> void:
	_chapter_option.clear()
	for chapter: String in _collect_chapters():
		_chapter_option.add_item(chapter)
	if _chapter_option.item_count == 0:
		_chapter_option.add_item("ray_chapter")
	_chapter_option.select(0)
	_display_name_edit.grab_focus()


func _collect_chapters() -> Array[String]:
	var chapters: Array[String] = []
	var dir := DirAccess.open(campaign_root)
	if dir == null:
		return chapters
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not entry.begins_with(".") and dir.current_is_dir():
			chapters.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	chapters.sort()
	return chapters


func _on_confirmed() -> void:
	confirmed_level.emit(_display_name_edit.text.strip_edges(), _chapter_option.get_item_text(_chapter_option.selected))
