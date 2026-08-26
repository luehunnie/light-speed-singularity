@tool
extends VBoxContainer

## TileSet 图集整套替换面板（TileSet 美术工作流 v1 的唯一 UI 入口）。
## 职责：接收 Dock 转发的当前选中节点；多图集源时让用户明确选择（默认不静默选第一项）；
##       「分析」展示共享 .tres 路径与引用扫描出的全部受影响场景；用户勾选知情确认后「替换」
##       才把一次性 token 交回服务执行；只做展示与编排，全部业务规则在 TilesetAtlasReplaceService。
## 输入输出：show_selection_node(node) 由 Dock 调用；set_editor_undo_redo(ur) 由 Dock 注入；
##       用户交互产出分析/替换结果文本；无返回值。
## 副作用：仅本面板控件；替换与写盘全部经服务走 UndoRedo 与 ResourceSaver。
## 边界：不解析规则（服务负责）、不直接改 TileSet/纹理、不写文件、不查找编辑器单例；
##       无 UndoRedo 管理器时明确报失败；token 一次性，替换后即失效。

const _ReplaceServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/tileset/tileset_atlas_replace_service.gd"
)

var _service: RefCounted = _ReplaceServiceScript.new()
var _layer: TileMapLayer = null
# 多图集源候选 [{source_id, atlas}]；空表示尚未解析或当前选择不可用。
var _atlas_entries: Array = []
var _token: int = -1
var _editor_undo_redo = null

var _status_label: Label = null
var _path_edit: LineEdit = null
var _source_selector: OptionButton = null
var _result_label: Label = null
var _confirm_box: CheckBox = null
var _apply_button: Button = null


## 初始化面板控件；重复调用安全。无参数无返回。
func _ready() -> void:
	_ensure_ui()
	_reset_for_layer(null)


## 注入编辑器 UndoRedo 管理器（EditorUndoRedoManager 或测试用 UndoRedo）；无返回值。
func set_editor_undo_redo(undo_redo) -> void:
	_editor_undo_redo = undo_redo


## Dock 转发的当前单选节点；非 TileMapLayer 时清空面板状态。无返回值。
func show_selection_node(node: Node) -> void:
	_ensure_ui()
	if node != null and is_instance_valid(node) and node is TileMapLayer:
		_reset_for_layer(node as TileMapLayer)
	else:
		_reset_for_layer(null)


## 重置面板到指定层（null 表示无可用目标）：解析图集源候选并按需显示选择器。无返回值。
func _reset_for_layer(layer: TileMapLayer) -> void:
	_layer = layer
	_token = -1
	_atlas_entries = []
	if _source_selector != null:
		_source_selector.clear()
		_source_selector.visible = false
	if _confirm_box != null:
		_confirm_box.button_pressed = false
		_confirm_box.disabled = true
	if _apply_button != null:
		_apply_button.disabled = true
	if _result_label != null:
		_result_label.text = ""
	if layer == null:
		_status_label.text = "选择一个 TileMapLayer 节点（如 WallLayer）后，在此整套替换其图集纹理。"
		return
	# 写盘成功后刷新当前层预览；层为 Node，Callable 持有引用安全。
	_service.set_refresh_callable(Callable(layer, "queue_redraw"))
	var resolved: Dictionary = _service.resolve_target(layer)
	if not resolved.ok:
		_status_label.text = String(resolved.reason)
		_layer = null
		return
	_atlas_entries = resolved.atlas_sources
	if _atlas_entries.size() > 1:
		for entry in _atlas_entries:
			_source_selector.add_item("图集源 source_id=%d" % int(entry.source_id))
			_source_selector.set_item_metadata(_source_selector.item_count - 1, int(entry.source_id))
		# 默认不选第一项，等待用户明确选择；与 Dock 多目标选择器约定一致。
		_source_selector.select(-1)
		_source_selector.visible = true
		_status_label.text = "该 TileSet 含 %d 个图集源，请先明确选择一个，再输入新纹理路径并分析。" % _atlas_entries.size()
	else:
		_status_label.text = "已选择 TileMapLayer「%s」。输入新纹理 res:// 路径后点「分析」。" % layer.name


## 创建一次性 UI 结构；仅在控件缺失时创建。无参数无返回。
func _ensure_ui() -> void:
	if _status_label != null and is_instance_valid(_status_label):
		return
	add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = "TileSet 图集整套替换"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)
	_source_selector = OptionButton.new()
	_source_selector.visible = false
	add_child(_source_selector)
	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "新纹理 res:// 路径"
	add_child(_path_edit)
	var analyze_button := Button.new()
	analyze_button.text = "分析影响"
	analyze_button.pressed.connect(Callable(self, "_on_analyze_pressed"))
	add_child(analyze_button)
	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.text = ""
	add_child(_result_label)
	_confirm_box = CheckBox.new()
	_confirm_box.text = "我已知悉将修改共享 TileSet 并影响以上全部场景"
	_confirm_box.disabled = true
	_confirm_box.toggled.connect(Callable(self, "_on_confirm_toggled"))
	add_child(_confirm_box)
	_apply_button = Button.new()
	_apply_button.text = "替换图集纹理（可 Ctrl+Z 撤销）"
	_apply_button.disabled = true
	_apply_button.pressed.connect(Callable(self, "_on_apply_pressed"))
	add_child(_apply_button)


## 「分析影响」：解析图集源选择并调用服务 analyze，展示共享路径 + 受影响场景清单。
## 无参数无返回；不修改任何资源；分析成功才启用知情确认勾选框。
func _on_analyze_pressed() -> void:
	if _layer == null or not is_instance_valid(_layer):
		_status_label.text = "请先选择一个 TileMapLayer 节点。"
		return
	var source_id: int = -1
	if _atlas_entries.size() > 1:
		var picked: int = _source_selector.selected
		if picked < 0:
			_status_label.text = "请先在上方明确选择一个图集源（v1 不做猜测）。"
			return
		source_id = int(_source_selector.get_item_metadata(picked))
	var path: String = _path_edit.text.strip_edges()
	if path == "":
		_status_label.text = "请先输入新纹理 res:// 路径。"
		return
	var plan: Dictionary = _service.analyze(_layer, source_id, path)
	if not plan.ok:
		_status_label.text = String(plan.reason)
		_token = -1
		_confirm_box.button_pressed = false
		_confirm_box.disabled = true
		_apply_button.disabled = true
		_result_label.text = ""
		return
	_token = int(plan.token)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("共享 TileSet：%s" % String(plan.tileset_path))
	lines.append("图块网格 %d×%d，已用范围 %d×%d。" % [
		Vector2i(plan.region).x, Vector2i(plan.region).y,
		Vector2i(plan.required_grid).x, Vector2i(plan.required_grid).y,
	])
	lines.append("当前纹理：%s" % (String(plan.current_texture_path) if String(plan.current_texture_path) != "" else "<内存资源>"))
	lines.append("新纹理：%s（%d×%d）" % [
		String(plan.new_texture_path), Vector2i(plan.new_texture_size).x, Vector2i(plan.new_texture_size).y,
	])
	var affected: PackedStringArray = plan.affected_scenes
	lines.append("该共享资源被 %d 个场景引用，全部将受影响：" % affected.size())
	for scene_path in affected:
		lines.append("· %s" % String(scene_path))
	lines.append("「替换」会直接修改上述共享 .tres（全部替换策略），不改动任何 .tscn。")
	_result_label.text = "\n".join(lines)
	_confirm_box.button_pressed = false
	_confirm_box.disabled = false
	_apply_button.disabled = true
	_status_label.text = "请核对受影响场景后勾选确认，再执行替换。"


## 知情确认勾选变化：只有勾选后才允许替换。pressed 为勾选状态；无返回值。
func _on_confirm_toggled(pressed: bool) -> void:
	_apply_button.disabled = not pressed or _token < 0


## 「替换」：把一次性 token 与注入的 UndoRedo 交给服务执行；结果回显状态。无参数无返回。
func _on_apply_pressed() -> void:
	if _token < 0:
		_status_label.text = "确认已失效，请重新分析。"
		_apply_button.disabled = true
		return
	var result: Dictionary = _service.apply(_token, _editor_undo_redo)
	# token 一次性：无论成败均已消费。
	_token = -1
	_confirm_box.button_pressed = false
	_confirm_box.disabled = true
	_apply_button.disabled = true
	_status_label.text = String(result.reason)
