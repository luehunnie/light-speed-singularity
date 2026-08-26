extends SceneTree

# AF-09 业务编辑器面板集成测试（headless）：Dock 装配八面板、Inventory 添加/应用/撤销、
# Objective 条件与组、Control 连接（2D Pick 经 notify_selection_changed 回填）、Rules、
# Presentation、meta 事务撤销恢复、PackedScene 序列化 round-trip（pack + user:// 落盘重载）。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。


const _Dock: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/level_authoring_dock.gd"
)
const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _ObjectiveData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/objective_data_service.gd"
)
const _ControlData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/control_data_service.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _root: Node2D
var _dock: CanvasItem
var _undo: UndoRedo


class StubBridge extends RefCounted:
	var current_root: Node2D = null

	func open_scene(_path: String) -> void:
		pass

	func get_current_scene_path() -> String:
		return "res://levels/campaign/ray_chapter/level_ray_001.tscn" if current_root != null else ""

	func get_edited_level_root() -> Node2D:
		return current_root

	func play_current_level() -> void:
		pass


func _initialize() -> void:
	_root = _LevelRay001.instantiate()
	_StableIdService.assign_missing(_root)
	_dock = _Dock.new()
	var bridge := StubBridge.new()
	bridge.current_root = _root
	_dock.set_editor_bridge(bridge)
	_undo = UndoRedo.new()
	_dock.set_undo_redo(_undo)
	_dock._ready()

	_test_01_panels_built()
	_test_02_inventory_flow()
	_test_03_objective_flow()
	_test_04_control_pick_flow()
	_test_05_rules_flow()
	_test_06_presentation_flow()
	_test_07_undo_roundtrip()
	_test_08_serialization_roundtrip()
	_test_09_gui_gate_fixes()

	_dock.free()
	_root.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])


func _panel(key: String) -> Control:
	return _dock.get_panel(key)


func _test_01_panels_built() -> void:
	const NAME: String = "01_面板装配"
	for key: String in ["level_tools", "map_assist", "content_palette", "inventory",
			"objective", "control", "rules", "presentation"]:
		_check(NAME, _panel(key) != null, "面板 %s 应装配。" % key)
	_check(NAME, (_panel("content_palette") as Object).get("_list").item_count >= 5,
		"Palette 面板应列 ≥5 正式类型。")


func _test_02_inventory_flow() -> void:
	const NAME: String = "02_Inventory流"
	var inventory: Object = _panel("inventory")
	inventory.call("refresh")
	_check(NAME, int(inventory.get("_type_options").item_count) >= 3, "类型下拉应列 ≥3 可入库类型。")
	inventory.get("_type_options").select(0)
	inventory.get("_quantity_spin").value = 3
	inventory.call("_on_add_entry")
	inventory.call("_on_apply")
	var stored: Array = _BusinessData.read_inventory(_root)
	_check(NAME, stored.size() == 1 and int(stored[0]["initial_quantity"]) == 3,
		"应用后 meta 应存 1 条 ×3（order 由列表序派生为 0）。")
	inventory.get("_list").select(0)
	inventory.call("_on_increment_quantity")
	inventory.call("_on_apply")
	stored = _BusinessData.read_inventory(_root)
	_check(NAME, int(stored[0]["initial_quantity"]) == 4, "数量 +1 流应生效。")


func _test_03_objective_flow() -> void:
	const NAME: String = "03_Objective流"
	var objective: Object = _panel("objective")
	objective.call("refresh")
	var crystal_id := ""
	for entry: Dictionary in _dock.get_object_index():
		if entry.domain == &"objective_target":
			crystal_id = entry.stable_id
			break
	_check(NAME, not crystal_id.is_empty(), "应找到水晶目标。")
	_check(NAME, int(objective.get("_target_options").item_count) == 1, "目标下拉应只列水晶。")
	_check(NAME, int(objective.get("_condition_type_options").item_count) >= 1, "条件下拉应列已声明类型。")
	var checks: Array = objective.get("_form_checks")
	for check: CheckBox in checks:
		check.button_pressed = check.text.begins_with("光线")
	objective.call("_on_add_condition")
	# 单目标关无法建组合法组：验证拒绝路径。
	objective.call("_on_add_group")
	var bucket: Array = (_ObjectiveData.read_conditions(_root).get(crystal_id, []) as Array)
	_check(NAME, _ObjectiveData.read_conditions(_root).is_empty(),
		"未应用前 meta 不落（条件先进工作副本）。")
	objective.call("_on_apply")
	bucket = _ObjectiveData.read_conditions(_root).get(crystal_id, [])
	_check(NAME, bucket.size() == 1 and str(bucket[0]["condition_type_id"]) == "form_condition",
		"应用后条件应落 meta。")
	_check(NAME, (bucket[0]["allowed_forms"] as Array).size() == 1 and int(bucket[0]["allowed_forms"][0]) == 0,
		"allowed_forms 应为勾选的 RAY。")
	_check(NAME, (_ObjectiveData.read_groups(_root)).is_empty(), "单成员组拒绝后不应落组 meta。")


func _test_04_control_pick_flow() -> void:
	const NAME: String = "04_Control拾取流"
	var control: Object = _panel("control")
	control.call("refresh")
	var mirror := preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn").instantiate()
	var accelerator := preload("res://gameplay/mechanisms/speed/particle_accelerator.tscn").instantiate()
	mirror.set("stable_instance_id", "mirror_pick")
	accelerator.set("stable_instance_id", "accel_pick")
	_root.get_node("RuntimeObjects").add_child(mirror)
	_root.get_node("RuntimeObjects").add_child(accelerator)
	_dock.refresh_all()
	# 2D Pick：面板进入待拾取态 → EditorSelection 转发 → 回填 source。
	_dock.arm_pick("source", control)
	_dock.notify_selection_changed([mirror])
	_check(NAME, str(control.get("_source_entry").get("stable_id", "")) == "mirror_pick",
		"拾取 Source 应回填镜稳定 ID。")
	_check(NAME, int(control.get("_event_options").item_count) == 1
			and str(control.get("_event_options").get_item_metadata(0)) == "beam_redirected",
		"Source 事件下拉应只列镜声明事件。")
	_dock.arm_pick("target", control)
	_dock.notify_selection_changed([accelerator])
	_check(NAME, str(control.get("_target_entry").get("stable_id", "")) == "accel_pick",
		"拾取 Target 应回填加速器稳定 ID。")
	_check(NAME, int(control.get("_action_options").item_count) == 1,
		"Target 动作下拉应只列加速器声明动作。")
	control.get("_event_options").select(0)
	control.get("_action_options").select(0)
	control.call("_on_add_connection")
	control.call("_on_apply")
	var connections: Array = _ControlData.read_connections(_root)
	_check(NAME, connections.size() == 1 and str(connections[0]["event_id"]) == "beam_redirected"
			and str(connections[0]["action_id"]) == "toggle_enabled",
		"应用后连接应落 meta（声明匹配）。")
	mirror.free()
	accelerator.free()


func _test_05_rules_flow() -> void:
	const NAME: String = "05_Rules流"
	var rules: Object = _panel("rules")
	rules.call("refresh")
	rules.get("_move_enabled_check").button_pressed = true
	rules.get("_move_limit_spin").value = 12
	rules.get("_form_checks")[1].button_pressed = false
	rules.call("_on_apply")
	var move_limit: Dictionary = _BusinessData.read_move_limit(_root)
	_check(NAME, bool(move_limit["enabled"]) and int(move_limit["max_count"]) == 12,
		"Move Limit 应落 meta（启用 / 12）。")
	var emitter_rules: Dictionary = _BusinessData.read_emitter_rules(_root)
	_check(NAME, (emitter_rules["allowed_forms"] as Array).size() == 1,
		"Allowed Forms 应只剩勾选项。")
	var emitter: Node = _dock._find_emitter_node()
	var form_before: int = int(emitter.get("default_light_form"))
	rules.get("_initial_form_options").select(0)
	rules.get("_initial_ray_options").select(1)
	rules.call("_on_apply_emitter")
	_check(NAME, int(emitter.get("ray_default_direction")) == 1,
		"应用 Initial 应写发射器节点字段。")
	_undo.undo()
	_check(NAME, int(emitter.get("ray_default_direction")) == form_before
			and int(emitter.get("ray_default_direction")) == 0,
		"Initial 配置应可撤销恢复。")


func _test_06_presentation_flow() -> void:
	const NAME: String = "06_Presentation流"
	var presentation: Object = _panel("presentation")
	presentation.call("refresh")
	presentation.get("_text_inputs")["title"].text = "第一关"
	presentation.get("_trigger_text").text = "按空格发射"
	presentation.call("_on_add_trigger")
	presentation.call("_on_apply")
	var text: Dictionary = _BusinessData.read_presentation(_root)
	_check(NAME, str(text["title"]) == "第一关", "标题应落 meta。")
	var triggers: Array = _BusinessData.read_tutorials(_root)
	_check(NAME, triggers.size() == 1 and str(triggers[0]["trigger_id"]) == "level_start",
		"教学触发应落 meta 且缺省选中 level_start。")


func _test_07_undo_roundtrip() -> void:
	const NAME: String = "07_撤销恢复"
	var before: Array = _BusinessData.read_inventory(_root)
	var inventory: Object = _panel("inventory")
	inventory.call("_on_remove_entry")
	inventory.get("_list").select(0)
	inventory.call("_on_remove_entry")
	inventory.call("_on_apply")
	_check(NAME, _BusinessData.read_inventory(_root).is_empty(), "移除并应用后库存应为空。")
	_undo.undo()
	var after: Array = _BusinessData.read_inventory(_root)
	_check(NAME, after.size() == before.size()
			and int(after[0]["initial_quantity"]) == int(before[0]["initial_quantity"]),
		"撤销应恢复库存 meta。")


func _test_08_serialization_roundtrip() -> void:
	const NAME: String = "08_序列化roundtrip"
	var packed := PackedScene.new()
	_check(NAME, packed.pack(_root) == OK, "带业务 meta 的关卡应可打包。")
	var reloaded: Node2D = packed.instantiate() as Node2D
	_check(NAME, _BusinessData.read_presentation(reloaded)["title"] == "第一关",
		"pack→instantiate 后文案 meta 应保留。")
	_check(NAME, (_ObjectiveData.read_conditions(reloaded).size()) == 1,
		"pack→instantiate 后条件 meta 应保留。")
	_check(NAME, _ControlData.read_connections(reloaded).size() == 1,
		"pack→instantiate 后连接 meta 应保留。")
	reloaded.free()
	var path := "user://af09_roundtrip_test.tscn"
	var save_error := ResourceSaver.save(packed, path)
	_check(NAME, save_error == OK, "应可保存到 user://。")
	var from_disk := load(path) as PackedScene
	var disk_root: Node2D = from_disk.instantiate() as Node2D
	_check(NAME, _BusinessData.read_inventory(disk_root).size() == 1
			and int(_BusinessData.read_inventory(disk_root)[0]["initial_quantity"]) == 4,
		"落盘重载后库存 meta 应一致。")
	_check(NAME, bool(_BusinessData.read_move_limit(disk_root)["enabled"]),
		"落盘重载后 Move Limit meta 应一致。")
	var tutorials: Array = _BusinessData.read_tutorials(disk_root)
	_check(NAME, tutorials.size() == 1 and str(tutorials[0]["text"]) == "按空格发射",
		"落盘重载后教学触发 meta 应一致。")
	disk_root.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# AF-09 GUI Human Gate 失败项回归：滚动布局（全部面板经 ScrollContainer 可达、刷新行与日志常驻）、
# Inventory 添加/应用日志反馈（类型显示名 + 数量）、Create/Map 节点行为短说明。
func _test_09_gui_gate_fixes() -> void:
	const NAME: String = "09_GUI修复回归"
	var scroll: ScrollContainer = _dock.get_node_or_null("PanelScroll") as ScrollContainer
	_check(NAME, scroll != null, "Dock 应有 PanelScroll 滚动容器（否则下半部面板不可达）。")
	if scroll == null:
		return
	_check(NAME, scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED,
		"纵向滚动应启用（鼠标滚轮 / 滚动条可达全部面板）。")
	_check(NAME, scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"横向滚动应禁用（面板纵向布局）。")
	var log_inside_scroll := false
	var node: Node = _dock.get("_log_output")
	while node != null:
		if node == scroll:
			log_inside_scroll = true
		node = node.get_parent()
	_check(NAME, not log_inside_scroll, "日志应固定在滚动区外（反馈常驻可见）。")
	for key: String in ["level_tools", "map_assist", "content_palette", "inventory",
			"objective", "control", "rules", "presentation"]:
		var panel_node: Node = _panel(key)
		var inside := false
		node = panel_node
		while node != null:
			if node == scroll:
				inside = true
			node = node.get_parent()
		_check(NAME, inside, "面板 %s 应在滚动区内。" % key)
	_check(NAME, _hint_text(_panel("level_tools")).contains("无需手动创建节点"),
		"关卡工具面板应有 Create 自动建树短说明。")
	_check(NAME, _hint_text(_panel("map_assist")).contains("不创建场景树节点"),
		"地图辅助面板应有不创建节点短说明。")
	# Inventory 反馈：添加与应用日志含类型显示名 + 数量；列表行同样显示。
	var inventory: Object = _panel("inventory")
	inventory.call("refresh")
	# 选第二个类型：前组已为第一个类型建条目（同类型 +1 不新增列表行，走不了“新条目”路径）。
	inventory.get("_type_options").select(1)
	inventory.get("_quantity_spin").value = 5
	var list_before: int = int(inventory.get("_list").item_count)
	inventory.call("_on_add_entry")
	var added_text: String = inventory.get("_list").get_item_text(
		int(inventory.get("_list").item_count) - 1)
	var add_logged: bool = str(_dock.get_log_text()).contains("×5")
	_check(NAME, int(inventory.get("_list").item_count) == list_before + 1
		and added_text.contains("×5"), "添加后列表应显示 类型 ×数量。")
	_check(NAME, add_logged, "添加后日志应含数量反馈（×5）。")
	inventory.call("_on_apply")
	var applied_log: String = str(_dock.get_log_text())
	_check(NAME, applied_log.contains("Inventory 已应用")
		and applied_log.contains("×5"),
		"应用后日志应列出每类型数量。")


# 面板内全部 Label 拼接文本（短说明存在性静态检查用）。
func _hint_text(panel: Node) -> String:
	var texts: PackedStringArray = PackedStringArray()
	for child: Node in panel.get_children():
		if child is Label:
			texts.append((child as Label).text)
	return " ".join(texts)


func _report() -> void:
	print("business_editor_panels_test：")
	for failure: String in _failures:
		print("  FAIL %s" % failure)
	print("  %d checks, %d failures" % [_checks, _failures.size()])
