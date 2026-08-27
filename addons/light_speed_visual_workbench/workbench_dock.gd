@tool
class_name LightSpeedVisualWorkbenchDock
extends VBoxContainer

## P1 Visual Asset Workbench 唯一业务入口 Dock（S3-03；GUI 冻结总结 v1.0 §2.2/§35-§38/§55-§57）。
## 职责：按业务概念入口浏览正式视觉对象、执行冻结九步导入、维护单对象 Change Set、
##       展示 Usage Impact 与 Preflight，并在 Apply 前强制 Preflight 可见且通过。
## 输入输出：全部业务写操作经 LightSpeedVisualWorkbenchChangeSet 与 backend 后端服务；
##           本 Dock 只做编排与展示，不直接改资源字段。
## 副作用：导入经 ImportService 复制文件；Apply 经 UndoRedo 单动作改写 Profile 字段。
## 边界：首批只开通 Mechanisms 业务入口（其余 §35 入口列出但标注未开通）；
##       Human 残留 Profile 一律只读保护，禁止暂存/Apply（is_profile_protected）；
##       不访问 EditorSelection、不猜 Node.name / NodePath / 场景坐标；
##       编辑器专用能力（资源扫描）经 Engine.is_editor_hint + 单例鸭子调用，保证 headless 可构造。

## §35 业务概念入口（首批仅 mechanisms 可用，其余降级标注）。
const BUSINESS_ENTRIES: Array = [
	{ id = "mechanisms", label = "机关视觉", available = true },
	{ id = "map_themes", label = "地图主题", available = false },
	{ id = "ray", label = "光线视觉", available = false },
	{ id = "particle", label = "光粒视觉", available = false },
	{ id = "formal_colors", label = "正式色彩", available = false },
	{ id = "public_feedback", label = "公共反馈视觉", available = false },
	{ id = "ui_theme", label = "UI 主题", available = false },
]
## Human 残留保护清单（S3-03 硬约束：不得触碰/提交）。
const PROTECTED_PROFILE_PATHS: Array = ["res://assets/visual_profiles/emitter_visuals.tres"]
const PROFILES_ROOT: String = "res://assets/visual_profiles/"
## 首批机关视觉导入的正式目录（§38 槽位稳定路径映射随各业务域开通细化）。
const DEFAULT_FORMAL_DIR: String = "res://assets/art/workbench_imports/"
## 首批尺寸合同：Free（§39 各槽位声明 Strict/Recommended 随域开通接入）。
const DEFAULT_SIZE_CONTRACT: Dictionary = { mode = "free", expected_size = Vector2i.ZERO }

const _EditServiceScript: GDScript = preload("res://addons/light_speed_visual_workbench/backend/editing/visual_state_edit_service.gd")
const _CatalogScript: GDScript = preload("res://addons/light_speed_visual_workbench/backend/browser/art_asset_catalog.gd")
const _NamingScript: GDScript = preload("./visual_asset_naming.gd")
const _ImportServiceScript: GDScript = preload("./formal_asset_import_service.gd")
const _ChangeSetScript: GDScript = preload("./visual_change_set.gd")
const _ImpactServiceScript: GDScript = preload("./visual_usage_impact_service.gd")
const _PreflightScript: GDScript = preload("./change_set_preflight.gd")

var _undo_redo = null
var _edit_service = _EditServiceScript.new()
var _import_service = null
var _impact_service = _ImpactServiceScript.new()
var _preflight_service = _PreflightScript.new()
var _change_set = null
var _last_preflight: Dictionary = {}
var _profile_paths: PackedStringArray = PackedStringArray()

var _entry_list: ItemList
var _profile_list: ItemList
var _state_list: ItemList
var _existing_picker: OptionButton
var _stage_existing_btn: Button
var _import_btn: Button
var _file_dialog: FileDialog
var _preview: TextureRect
var _cs_list: ItemList
var _impact_label: Label
var _preflight_label: Label
var _apply_btn: Button
var _clear_btn: Button
var _status_label: Label


## 构建全部 UI 并加载首批数据；headless 可安全调用（无编辑器单例访问）。
func _ready() -> void:
	_import_service = _ImportServiceScript.new()
	_build_ui()
	_reload_profiles()


## 注入编辑器 UndoRedo 管理器（插件生命周期调用；null 表示脱离编辑器）。
func set_editor_undo_redo(undo_redo) -> void:
	_undo_redo = undo_redo
	_refresh_apply_availability()


## 判断 Profile 正式路径是否属于 Human 残留保护（保护 = 只读展示，禁止暂存/Apply）。
func is_profile_protected(profile_path: String) -> bool:
	return profile_path in PROTECTED_PROFILE_PATHS


## 当前选中 Profile 的正式路径（未选返回 ""）。
func get_selected_profile_path() -> String:
	var indices: PackedInt32Array = _profile_list.get_selected_items()
	if indices.is_empty():
		return ""
	return _profile_paths[indices[0]]


## 当前绑定的 Change Set（未选 Profile 时为 null；供测试与外部只读观察）。
func get_change_set():
	return _change_set


## 程序化构建 Dock UI（业务入口 → 对象 → 状态/槽位 → 导入 → Change Set 面板）。
func _build_ui() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	var body: VBoxContainer = VBoxContainer.new()
	margin.add_child(body)
	add_child(margin)
	var title: Label = Label.new()
	title.text = "Visual Asset Workbench"
	body.add_child(title)
	_entry_list = ItemList.new()
	_entry_list.custom_minimum_size = Vector2(0, 96)
	for entry: Dictionary in BUSINESS_ENTRIES:
		var label: String = String(entry["label"]) + ("" if bool(entry["available"]) else "（未开通）")
		_entry_list.add_item(label)
		_entry_list.set_item_disabled(_entry_list.item_count - 1, not bool(entry["available"]))
	body.add_child(_entry_list)
	_profile_list = ItemList.new()
	_profile_list.custom_minimum_size = Vector2(0, 96)
	_profile_list.item_selected.connect(_on_profile_selected)
	body.add_child(_profile_list)
	_state_list = ItemList.new()
	_state_list.custom_minimum_size = Vector2(0, 80)
	_state_list.item_selected.connect(_on_state_selected)
	body.add_child(_state_list)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(64, 64)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	body.add_child(_preview)
	_import_btn = Button.new()
	_import_btn.text = "Import / Replace Image"
	_import_btn.pressed.connect(_on_import_pressed)
	body.add_child(_import_btn)
	_existing_picker = OptionButton.new()
	_existing_picker.custom_minimum_size = Vector2(0, 0)
	body.add_child(_existing_picker)
	_stage_existing_btn = Button.new()
	_stage_existing_btn.text = "Choose Existing：暂存到所选状态"
	_stage_existing_btn.pressed.connect(_on_stage_existing)
	body.add_child(_stage_existing_btn)
	_cs_list = ItemList.new()
	_cs_list.custom_minimum_size = Vector2(0, 72)
	body.add_child(_cs_list)
	_impact_label = Label.new()
	_impact_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_impact_label.custom_minimum_size = Vector2(0, 60)
	body.add_child(_impact_label)
	_preflight_label = Label.new()
	_preflight_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preflight_label.custom_minimum_size = Vector2(0, 60)
	body.add_child(_preflight_label)
	var actions: HBoxContainer = HBoxContainer.new()
	_apply_btn = Button.new()
	_apply_btn.text = "Apply All"
	_apply_btn.disabled = true
	_apply_btn.pressed.connect(_on_apply_pressed)
	actions.add_child(_apply_btn)
	_clear_btn = Button.new()
	_clear_btn.text = "清空批次"
	_clear_btn.disabled = true
	_clear_btn.pressed.connect(_on_clear_pressed)
	actions.add_child(_clear_btn)
	body.add_child(actions)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status_label)
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.png ; PNG", "*.jpg, *.jpeg ; JPEG", "*.webp ; WebP"])
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)


## 扫描正式 Profile 目录并填充对象列表（保护项带后缀但仍可选，动作层拦截）。
func _reload_profiles() -> void:
	_profile_list.clear()
	_profile_paths = PackedStringArray()
	var dir: DirAccess = DirAccess.open(PROFILES_ROOT)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not name.begins_with(".") and name.get_extension() == "tres":
			var path: String = PROFILES_ROOT + name
			_profile_paths.append(path)
			_profile_list.add_item(name + ("（保护）" if is_profile_protected(path) else ""))
		name = dir.get_next()
	dir.list_dir_end()
	_reload_existing_picker()


## 用 backend 后端 Catalog 填充既有正式素材选择器（复用而非复制，§2.2）。
func _reload_existing_picker() -> void:
	_existing_picker.clear()
	var catalog = _CatalogScript.new()
	catalog.scan()
	for entry in catalog.get_entries():
		if entry.extension in ["png", "jpg", "jpeg", "webp"]:
			_existing_picker.add_item("%s / %s" % [entry.relative_directory, entry.file_name])
			_existing_picker.set_item_metadata(_existing_picker.item_count - 1, entry.resource_path)


## 选中 Profile：加载状态列表、重建该对象的 Change Set、刷新面板。
func _on_profile_selected(index: int) -> void:
	var profile_path: String = _profile_paths[index]
	var profile: ObjectVisualProfile = load(profile_path) as ObjectVisualProfile
	if profile == null:
		_status_label.text = "Profile 加载失败：%s。" % profile_path
		return
	_change_set = _ChangeSetScript.new(profile, profile_path)
	_state_list.clear()
	for state: VisualStateTexture in profile.states:
		if state == null:
			continue
		_state_list.add_item("%s%s" % [state.state_id, "（缺纹理）" if state.world_texture == null else ""])
		_state_list.set_item_metadata(_state_list.item_count - 1, state.state_id)
	_refresh_preview_from_profile()
	_refresh_change_set_panel()


## 选中状态：预览该状态当前纹理。
func _on_state_selected(index: int) -> void:
	if _change_set == null:
		return
	var state_id: StringName = _state_list.get_item_metadata(index)
	var staged: Texture2D = _change_set.get_staged_new_texture(state_id)
	_preview.texture = staged if staged != null else _change_set.get_profile().get_world_texture(state_id)


## Import / Replace Image：弹出项目外图片选择，走冻结九步导入。
func _on_import_pressed() -> void:
	if _require_selected_profile() == "":
		return
	if _state_list.get_selected_items().is_empty():
		_status_label.text = "请先在状态列表选择目标槽位。"
		return
	_file_dialog.popup_centered(Vector2i(720, 480))


## 选定外部图片后执行九步导入（钩子：编辑器扫描/槽位绑定/预览刷新）。
func _on_file_selected(source_path: String) -> void:
	var profile_path: String = _require_selected_profile()
	if profile_path == "":
		return
	var state_id: StringName = _state_list.get_item_metadata(_state_list.get_selected_items()[0])
	var identity: String = profile_path.get_file().get_basename().trim_suffix("_visuals")
	var request: Dictionary = {
		source_path = source_path,
		formal_dir = DEFAULT_FORMAL_DIR,
		identity = identity,
		slot = "state",
		state = String(state_id),
		direction = "",
		usage = "world",
		size_mode = String(DEFAULT_SIZE_CONTRACT["mode"]),
		expected_size = DEFAULT_SIZE_CONTRACT["expected_size"],
		overwrite = true,
		hooks = {
			import_trigger = Callable(self, "_trigger_editor_import"),
			slot_binder = Callable(self, "_bind_imported_slot"),
			preview_refresher = Callable(self, "_refresh_preview_from_profile"),
		},
	}
	var result: Dictionary = _import_service.run_import(request)
	_status_label.text = "导入%s：%s。" % ["成功" if bool(result["ok"]) else "失败", result["canonical_name"]]
	_refresh_change_set_panel()


## 触发编辑器资源扫描（等待/触发 Godot Import；非编辑器环境降级跳过）。
func _trigger_editor_import(_formal_path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return { status = "skipped", detail = "非编辑器环境，跳过 Import 触发。" }
	var editor_interface = Engine.get_singleton("EditorInterface")
	if editor_interface == null or not editor_interface.has_method("get_resource_filesystem"):
		return { status = "skipped", detail = "编辑器接口不可用。" }
	editor_interface.get_resource_filesystem().scan()
	return { status = "pass", detail = "已触发编辑器资源扫描。" }


## 九步之八：把导入产物绑定到正式视觉槽（暂存进 Change Set，Apply 时落盘）。
func _bind_imported_slot(formal_path: String) -> Dictionary:
	var indices: PackedInt32Array = _state_list.get_selected_items()
	if indices.is_empty():
		return { ok = false, detail = "未选择目标槽位。" }
	var state_id: StringName = _state_list.get_item_metadata(indices[0])
	var texture: Texture2D = load(formal_path) as Texture2D
	if texture == null:
		return { ok = false, detail = "导入产物尚不可加载（等待 Godot Import 完成后重试绑定）。" }
	var staged: Dictionary = _change_set.stage_state_texture(state_id, texture)
	return { ok = bool(staged["ok"]), detail = String(staged["reason"]) }


## Choose Existing：把既有正式素材暂存到所选状态槽（§36 保留路径）。
func _on_stage_existing() -> void:
	if _require_selected_profile() == "":
		return
	var indices: PackedInt32Array = _state_list.get_selected_items()
	if indices.is_empty():
		_status_label.text = "请先选择目标状态。"
		return
	if _existing_picker.selected < 0:
		_status_label.text = "请先选择既有素材。"
		return
	var texture_path: String = _existing_picker.get_item_metadata(_existing_picker.selected)
	var state_id: StringName = _state_list.get_item_metadata(indices[0])
	var staged: Dictionary = _change_set.stage_state_texture(state_id, load(texture_path) as Texture2D)
	_status_label.text = String(staged["reason"])
	_refresh_change_set_panel()


## 刷新 Change Set 面板：条目 Before/After、Usage Impact、Preflight（§55/§56/§57）。
func _refresh_change_set_panel() -> void:
	_cs_list.clear()
	_impact_label.text = ""
	_preflight_label.text = ""
	_last_preflight = {}
	if _change_set == null:
		_refresh_apply_availability()
		return
	for entry: Dictionary in _change_set.get_entries():
		var slot_name: String = String(entry["state_id"]) if String(entry["kind"]) == "state" else "inventory_icon"
		_cs_list.add_item("%s：%s → %s" % [slot_name, entry["old_path"], entry["new_path"]])
	var report: Dictionary = _impact_service.build_report(
		_change_set.get_profile_path(), _change_set.get_old_texture_paths(), _change_set.get_profile())
	_impact_label.text = "Usage Impact：受影响关卡 %d；Validator 问题 %d。%s" % [
		report["affected_level_count"], report["validator_issues"].size(),
		"；".join(PackedStringArray(report["levels_using"].map(func(path): return String(path))))]
	_last_preflight = _preflight_service.run(_change_set, DEFAULT_SIZE_CONTRACT)
	var lines: PackedStringArray = PackedStringArray()
	for check: Dictionary in _last_preflight["checks"]:
		lines.append("%s：%s（%s）" % [check["id"], check["status"], check["detail"]])
	_preflight_label.text = "\n".join(lines)
	_refresh_apply_availability()


## Apply All：Preflight 通过且批次非空才可点；保护 Profile 一律拒绝。
func _on_apply_pressed() -> void:
	var profile_path: String = get_selected_profile_path()
	if is_profile_protected(profile_path):
		_status_label.text = "该 Profile 属 Human 残留保护，禁止 Apply（%s）。" % profile_path
		return
	if _undo_redo == null:
		_status_label.text = "未注入 UndoRedo，应用失败。"
		return
	var result: Dictionary = _change_set.apply_all(_undo_redo, _edit_service, _last_preflight, "Workbench Apply Change Set")
	_status_label.text = String(result["reason"])
	_refresh_preview_from_profile()
	_refresh_change_set_panel()


## 清空当前批次（不影响已 Apply 的历史）。
func _on_clear_pressed() -> void:
	if _change_set != null:
		_change_set.clear()
		_refresh_change_set_panel()


## 校验已选中非保护 Profile，未选中/受保护时写状态并返回 ""。
func _require_selected_profile() -> String:
	var profile_path: String = get_selected_profile_path()
	if profile_path == "":
		_status_label.text = "请先选择正式视觉对象。"
		return ""
	if is_profile_protected(profile_path):
		_status_label.text = "该 Profile 属 Human 残留保护，只读展示（%s）。" % profile_path
		return ""
	return profile_path


## Apply 可用性 = 已注入 UndoRedo + Preflight 通过 + 批次非空。
func _refresh_apply_availability() -> void:
	var batch_ready: bool = _change_set != null and not _change_set.is_empty()
	_apply_btn.disabled = not (_undo_redo != null and batch_ready and bool(_last_preflight.get("passed", false)))
	_clear_btn.disabled = not batch_ready


## 预览默认状态当前纹理（Apply/导入后刷新 Effective Preview）。
## 形参为导入钩子协议保留（Callable 统一收 formal_path），本实现不使用。
func _refresh_preview_from_profile(_formal_path: String = "") -> void:
	if _change_set == null:
		_preview.texture = null
		return
	_preview.texture = _change_set.get_profile().get_world_texture(_change_set.get_profile().default_state_id)
