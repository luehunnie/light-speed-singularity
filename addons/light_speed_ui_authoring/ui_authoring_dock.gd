@tool
class_name LightSpeedUIAuthoringDock
extends VBoxContainer

## 界面编辑辅助 Dock（S3-04；冻结总结 v1.0 §2.4/§82-§86）。
## 职责：唯一 UI 入口——Slot 结构守卫报告、Preview 预设/Ad-hoc（会话临时）、
##       Viewport 预设选择、一键运行 UI Test Matrix；全部结果只呈现事实。
## 输入输出：只读编辑器当前场景根（EditorInterface 鸭子调用，编辑器外安全降级）；
##           结果写入结果列表与状态标签；Ad-hoc 数据仅存本 Dock 成员（不落盘）。
## 副作用：不修改任何节点/场景/文件（§86 审美仍由人判断，无 autofix）。
## 边界（红线）：不做拖拽式 UI Layout Workbench；布局正式入口=Godot 原生 Control 编辑。

const _PreviewData: GDScript = preload("./ui_preview_data_service.gd")
const _ViewportPresets: GDScript = preload("./ui_viewport_presets.gd")
const _SlotContract: GDScript = preload("./ui_binding_slot_contract.gd")
const _TestMatrix: GDScript = preload("./ui_test_matrix_runner.gd")

var _preview_service = _PreviewData.new()
var _viewport_service = _ViewportPresets.new()
var _contract = _SlotContract.new()
var _matrix = _TestMatrix.new()

## Ad-hoc 会话临时数据（仅内存成员；重开 Dock/编辑器即失效，§84）。
var _adhoc_preview: Dictionary = {}
var _selected_viewport: Dictionary = {}

var _preview_list: OptionButton
var _viewport_list: OptionButton
var _adhoc_count: SpinBox
var _guard_btn: Button
var _matrix_btn: Button
var _result_list: ItemList
var _status_label: Label


func _ready() -> void:
	_build_ui()
	_reload_presets()


## 程序化构建最小 UI（无场景文件；中文文案）。
func _build_ui() -> void:
	var title: Label = Label.new()
	title.text = "界面编辑辅助"
	add_child(title)
	var note: Label = Label.new()
	note.text = "布局正式入口＝Godot 原生 Control 编辑；本面板只做守卫/预览/矩阵。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(note)

	_preview_list = OptionButton.new()
	add_child(_preview_list)
	_preview_list.item_selected.connect(_on_preview_selected)
	_viewport_list = OptionButton.new()
	add_child(_viewport_list)
	_viewport_list.item_selected.connect(_on_viewport_selected)

	var adhoc_row: HBoxContainer = HBoxContainer.new()
	var adhoc_label: Label = Label.new()
	adhoc_label.text = "Ad-hoc 库存数（会话临时）："
	adhoc_row.add_child(adhoc_label)
	_adhoc_count = SpinBox.new()
	_adhoc_count.min_value = 0
	_adhoc_count.max_value = 99
	adhoc_row.add_child(_adhoc_count)
	var adhoc_btn: Button = Button.new()
	adhoc_btn.text = "应用临时数据"
	adhoc_btn.pressed.connect(_on_adhoc_pressed)
	adhoc_row.add_child(adhoc_btn)
	add_child(adhoc_row)

	_guard_btn = Button.new()
	_guard_btn.text = "运行 Slot 结构守卫"
	_guard_btn.pressed.connect(_on_guard_pressed)
	add_child(_guard_btn)
	_matrix_btn = Button.new()
	_matrix_btn.text = "运行 UI Test Matrix"
	_matrix_btn.pressed.connect(_on_matrix_pressed)
	add_child(_matrix_btn)

	_result_list = ItemList.new()
	_result_list.custom_minimum_size = Vector2(0, 180)
	add_child(_result_list)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "就绪。"
	add_child(_status_label)


## 填充 Preview 与 Viewport 预设选项（正式预设，中文标签）。
func _reload_presets() -> void:
	_preview_list.clear()
	for preset: Dictionary in _preview_service.build_all_presets():
		_preview_list.add_item("Preview：%s" % str(preset["label"]))
	_preview_list.select(1)
	_viewport_list.clear()
	for viewport: Dictionary in _viewport_service.get_presets():
		_viewport_list.add_item("视口：%s（%s）" % [str(viewport["label"]), str(viewport["size"])])
	_viewport_list.select(0)
	_on_viewport_selected(0)


## 选择 Preview 预设（Ad-hoc 生效前以标准预设为矩阵输入）。
func _on_preview_selected(_index: int) -> void:
	_adhoc_preview = {}


## 选择 Viewport 预设：记录选择并提示切换仅编辑器预览（§85）。
func _on_viewport_selected(index: int) -> void:
	var presets: Array = _viewport_service.get_presets()
	if index >= 0 and index < presets.size():
		_selected_viewport = presets[index]
		_status_label.text = "视口预设：%s（切换仅编辑器预览，不改项目设置）。" % str(_selected_viewport["label"])


## 应用 Ad-hoc 临时数据：基于当前选中预设覆盖库存数，仅存会话成员（§84 不落盘）。
func _on_adhoc_pressed() -> void:
	var presets: Array = _preview_service.build_all_presets()
	var base: Dictionary = presets[maxi(0, _preview_list.selected)] if not presets.is_empty() else {}
	var merged: Dictionary = _preview_service.build_adhoc(base, { inventory_count = int(_adhoc_count.value) })
	if merged.has("error"):
		_status_label.text = str(merged["error"])
		return
	_adhoc_preview = merged
	_status_label.text = "Ad-hoc 已生效（仅本会话，不落盘/不写关卡）。"


## Slot 结构守卫：对当前编辑场景根跑独立 Validator，结果只呈现事实。
func _on_guard_pressed() -> void:
	var root: Node = _get_edited_scene_root()
	if root == null:
		_status_label.text = "仅编辑器内可用（当前无编辑场景根）。"
		return
	_show_issues(_contract.validate_ui_structure(root, _contract.REQUIRED_DEFAULT), "Slot 守卫")


## 一键 UI Test Matrix：冻结四组合 × 五类机械检查（§86）。
func _on_matrix_pressed() -> void:
	var root: Node = _get_edited_scene_root()
	if root == null:
		_status_label.text = "仅编辑器内可用（当前无编辑场景根）。"
		return
	var preview: Dictionary = _adhoc_preview if not _adhoc_preview.is_empty() else _selected_preview()
	var viewport_size: Vector2i = _selected_viewport.get("size", Vector2i(1920, 1080))
	var result: Dictionary = _matrix.run_combo(root, preview, viewport_size, _contract.REQUIRED_DEFAULT)
	_show_issues(result["issues"], "Test Matrix（%s × %s）" % [str(preview.get("label", "?")), str(viewport_size)])


## 当前选中的标准 Preview 预设。
func _selected_preview() -> Dictionary:
	var presets: Array = _preview_service.build_all_presets()
	if presets.is_empty():
		return {}
	return presets[maxi(0, _preview_list.selected)]


## 只读获取编辑器当前场景根（EditorInterface 鸭子调用；headless/运行态安全返回 null）。
func _get_edited_scene_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	var editor_interface: Object = Engine.get_singleton("EditorInterface")
	if editor_interface == null or not editor_interface.has_method("get_edited_scene_root"):
		return null
	var root: Node = editor_interface.call("get_edited_scene_root")
	return root if root is Control or root is Node else null


## 结果呈现：issue 列表 + 状态摘要（无 issue=通过；不做任何修复）。
func _show_issues(issues: Array, source: String) -> void:
	_result_list.clear()
	if issues.is_empty():
		_status_label.text = "%s：通过（0 项机械问题）。" % source
		return
	for issue: Dictionary in issues:
		_result_list.add_item("[%s] %s" % [str(issue["check"]), str(issue["detail"])])
	_status_label.text = "%s：%d 项机械问题（事实呈现，审美由人判断）。" % [source, issues.size()]
