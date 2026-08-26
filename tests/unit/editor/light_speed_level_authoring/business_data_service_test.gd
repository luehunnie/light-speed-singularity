extends SceneTree

# AF-09 业务数据服务测试（headless）：Inventory / Presentation / Tutorial / Move Limit /
# Emitter Rules 的缺省读取、校验拒绝域、写入 detached 语义；Objective 条件与组校验；
# Control 连接结构 / 声明 / schema / 去重校验；apply_id_remap 重映射。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _ObjectiveData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/objective_data_service.gd"
)
const _ControlData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/control_data_service.gd"
)
const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _root: Node2D
var _registry


## 测试桩：FormalContentRegistry 鸭子（get_type_ids/get_definition），验证服务不依赖具体 registry 类。
class _DuckRegistry:
	var _type_ids: Array = []
	var _definitions: Dictionary = {}

	func _init(p_type_ids: Array, p_definitions: Dictionary) -> void:
		_type_ids = p_type_ids
		_definitions = p_definitions

	func get_type_ids() -> Array:
		return _type_ids

	func get_definition(type_id: StringName) -> Variant:
		return _definitions.get(type_id, null)


func _initialize() -> void:
	_root = _LevelRay001.instantiate()
	_registry = _PaletteService.build_registry()
	# level_ray_001 两正式对象缺编辑期稳定 ID（AF-07 前事实）：业务引用域先补发（与“修复 Stable ID”按钮同口径）。
	_StableIdService.assign_missing(_root)

	_test_01_defaults()
	_test_02_inventory_domain()
	_test_03_objective_conditions()
	_test_04_objective_groups()
	_test_05_control_connections()
	_test_06_rules_domains()
	_test_07_detached_and_remap()
	_test_08_object_type_resolution()
	_test_09_registry_driven_dynamic_types()

	_root.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])


func _test_01_defaults() -> void:
	const NAME: String = "01_缺省读取"
	_check(NAME, _BusinessData.read_inventory(_root).is_empty(), "无 meta 时库存应为空。")
	_check(NAME, _BusinessData.read_presentation(_root)["title"] == "", "无 meta 时文案应全空。")
	_check(NAME, _BusinessData.read_move_limit(_root)["enabled"] == false, "无 meta 时 Move Limit 应禁用。")
	var rules: Dictionary = _BusinessData.read_emitter_rules(_root)
	_check(NAME, (rules["allowed_forms"] as Array).size() == 2, "无 meta 时形态应为全集合。")
	_check(NAME, (rules["allowed_ray_directions"] as Array).size() == 8, "无 meta 时光线方向应为八方向全集。")
	_check(NAME, _ObjectiveData.read_conditions(_root).is_empty(), "无 meta 时条件应为空。")
	_check(NAME, _ControlData.read_connections(_root).is_empty(), "无 meta 时连接应为空。")


func _test_02_inventory_domain() -> void:
	const NAME: String = "02_Inventory域"
	var entries := [{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 2, "order": 0}]
	_check(NAME, _BusinessData.validate_inventory(entries, _registry).is_empty(), "合法条目应通过。")
	var bad_type := [{"content_type_id": "main_emitter", "initial_quantity": 1, "order": 0}]
	_check(NAME, not _BusinessData.validate_inventory(bad_type, _registry).is_empty(),
		"非 inventory_eligible 类型应被拒绝。")
	var duplicate_type := [entries[0], entries[0].duplicate()]
	_check(NAME, not _BusinessData.validate_inventory(duplicate_type, _registry).is_empty(),
		"重复类型应被拒绝。")
	var negative := [{"content_type_id": "basic_single_cell_mirror", "initial_quantity": -1, "order": 0}]
	_check(NAME, not _BusinessData.validate_inventory(negative, _registry).is_empty(), "负数量应被拒绝。")


func _test_03_objective_conditions() -> void:
	const NAME: String = "03_条件域"
	var index: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var crystal_id := ""
	for entry: Dictionary in index:
		if entry.domain == &"objective_target":
			crystal_id = entry.stable_id
			break
	_check(NAME, not crystal_id.is_empty(), "level_ray_001 应有 objective_target 目标。")
	var conditions := {crystal_id: [{"condition_type_id": "form_condition", "allowed_forms": [0, 1]}]}
	_check(NAME, _ObjectiveData.validate_conditions(conditions, index).is_empty(), "合法条件应通过。")
	var unknown_target := {"ghost_id": [{"condition_type_id": "form_condition", "allowed_forms": [0]}]}
	_check(NAME, not _ObjectiveData.validate_conditions(unknown_target, index).is_empty(),
		"不存在的目标应被拒绝。")
	var empty_forms := {crystal_id: [{"condition_type_id": "form_condition", "allowed_forms": []}]}
	_check(NAME, not _ObjectiveData.validate_conditions(empty_forms, index).is_empty(),
		"空 allowed_forms 应被拒绝。")
	var dup_type := {crystal_id: [
		{"condition_type_id": "form_condition", "allowed_forms": [0]},
		{"condition_type_id": "form_condition", "allowed_forms": [1]}]}
	_check(NAME, not _ObjectiveData.validate_conditions(dup_type, index).is_empty(),
		"同目标重复条件类型应被拒绝。")


func _test_04_objective_groups() -> void:
	const NAME: String = "04_组域"
	var index: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var crystal_id := ""
	for entry: Dictionary in index:
		if entry.domain == &"objective_target":
			crystal_id = entry.stable_id
			break
	var groups := [{"group_type": 0, "member_ids": [crystal_id, "other"], "required": true, "window_seconds": 5.0}]
	_check(NAME, not _ObjectiveData.validate_groups(groups, index).is_empty(),
		"非目标成员应被拒绝（单水晶关不具备两目标，构造拒绝用例）。")
	var single_member := [{"group_type": 1, "member_ids": [crystal_id], "required": false, "window_seconds": 5.0}]
	_check(NAME, not _ObjectiveData.validate_groups(single_member, index).is_empty(),
		"单成员组应被拒绝（至少 2 成员）。")
	var bad_window := [{"group_type": 0, "member_ids": [crystal_id, crystal_id], "required": false, "window_seconds": 0.0}]
	_check(NAME, not _ObjectiveData.validate_groups(bad_window, index).is_empty(),
		"窗口 ≤0 与重复成员应被拒绝。")


func _test_05_control_connections() -> void:
	const NAME: String = "05_连接域"
	var index: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var emitter_id := ""
	var crystal_id := ""
	for entry: Dictionary in index:
		if str(entry.type_id) == "main_emitter":
			emitter_id = entry.stable_id
		if entry.domain == &"objective_target":
			crystal_id = entry.stable_id
	var connections := [{
		"source_stable_id": emitter_id, "event_id": "beam_redirected",
		"target_stable_id": crystal_id, "action_id": "toggle_enabled", "params": {},
	}]
	_check(NAME, not _ControlData.validate_connections(connections, index, _registry).is_empty(),
		"Source 未声明该事件应被拒绝（声明域以对端定义为准）。")
	var empty_segment := [{
		"source_stable_id": "", "event_id": "e", "target_stable_id": crystal_id,
		"action_id": "a", "params": {}}]
	_check(NAME, not _ControlData.validate_connections(empty_segment, index, _registry).is_empty(),
		"空 source 应被拒绝。")
	var bad_params := [{
		"source_stable_id": emitter_id, "event_id": "beam_redirected",
		"target_stable_id": crystal_id, "action_id": "toggle_enabled",
		"params": {"k": "string_value"}}]
	_check(NAME, not _ControlData.validate_connections(bad_params, index, _registry).is_empty(),
		"params 字符串值应被拒绝（仅 bool/int）。")
	# 声明枚举：镜已声明 beam_redirected；加速器已声明 toggle_enabled。
	var mirror_events: Array = _ControlData.get_event_options(&"basic_single_cell_mirror", _registry)
	_check(NAME, mirror_events.size() == 1 and str(mirror_events[0]["event_id"]) == "beam_redirected",
		"镜定义应枚举出已声明事件 beam_redirected。")
	var accelerator_actions: Array = _ControlData.get_action_options(&"particle_accelerator", _registry)
	_check(NAME, accelerator_actions.size() == 1 and str(accelerator_actions[0]["action_id"]) == "toggle_enabled",
		"加速器定义应枚举出已声明动作 toggle_enabled。")
	# 真实合法连接：source=镜（声明事件），target=加速器（声明动作）——构造一个镜像占位节点入树。
	var mirror := preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn").instantiate()
	mirror.set("stable_instance_id", "mirror_x")
	_root.get_node("RuntimeObjects").add_child(mirror)
	var index2: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var accelerator := preload("res://gameplay/mechanisms/speed/particle_accelerator.tscn").instantiate()
	accelerator.set("stable_instance_id", "accel_x")
	_root.get_node("RuntimeObjects").add_child(accelerator)
	var index3: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var valid := [{
		"source_stable_id": "mirror_x", "event_id": "beam_redirected",
		"target_stable_id": "accel_x", "action_id": "toggle_enabled", "params": {}}]
	_check(NAME, _ControlData.validate_connections(valid, index3, _registry).is_empty(),
		"声明匹配的连接应通过（source=镜事件，target=加速器动作）。")
	var duplicate := valid.duplicate(true)
	duplicate.append(valid[0].duplicate(true))
	_check(NAME, not _ControlData.validate_connections(duplicate, index3, _registry).is_empty(),
		"五元组重复连接应被拒绝。")
	mirror.free()
	accelerator.free()


func _test_06_rules_domains() -> void:
	const NAME: String = "06_Rules域"
	_check(NAME, _BusinessData.validate_move_limit({"enabled": false, "max_count": 0}).is_empty(),
		"禁用时 Count 只读，0 合法。")
	_check(NAME, not _BusinessData.validate_move_limit({"enabled": true, "max_count": 0}).is_empty(),
		"启用时 Count <1 应被拒绝。")
	var full := {"allowed_forms": [0, 1], "allowed_ray_directions": [0], "allowed_particle_directions": [0, 7]}
	_check(NAME, _BusinessData.validate_emitter_rules(_root, full).is_empty(),
		"合法发射器规则（initial 与 allowed 一致性按场景发射器核）应通过。")
	var empty_forms := {"allowed_forms": [], "allowed_ray_directions": [0], "allowed_particle_directions": [0]}
	_check(NAME, not _BusinessData.validate_emitter_rules(_root, empty_forms).is_empty(),
		"空 Allowed Forms 应被拒绝。")
	var out_of_range := {"allowed_forms": [5], "allowed_ray_directions": [0], "allowed_particle_directions": [0]}
	_check(NAME, not _BusinessData.validate_emitter_rules(_root, out_of_range).is_empty(),
		"越界形态应被拒绝。")
	var inconsistent := {"allowed_forms": [1], "allowed_ray_directions": [1], "allowed_particle_directions": [0]}
	_check(NAME, not _BusinessData.validate_emitter_rules(_root, inconsistent).is_empty(),
		"发射器 Initial（RAY/右）不在 allowed 内应被拒绝。")
	_check(NAME, _BusinessData.validate_tutorials(
			[{"text": "t", "trigger_id": "level_start", "display_style": "toast",
				"duration_seconds": 2.0}]).is_empty(), "合法教学触发应通过。")
	_check(NAME, not _BusinessData.validate_tutorials(
			[{"text": "t", "trigger_id": "custom_script", "display_style": "toast",
				"duration_seconds": 2.0}]).is_empty(), "未声明触发器应被拒绝（无自由表达式）。")


func _test_07_detached_and_remap() -> void:
	const NAME: String = "07_写入与重映射"
	var entries := [{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 1, "order": 0}]
	_BusinessData.write_meta(_root, _BusinessData.META_INVENTORY, entries)
	entries[0]["initial_quantity"] = 99
	var stored: Array = _BusinessData.read_inventory(_root)
	_check(NAME, int(stored[0]["initial_quantity"]) == 1, "写入后修改源不应影响存值（detached）。")
	var conditions := {"tgt_old": [{"condition_type_id": "form_condition", "allowed_forms": [0]}]}
	_BusinessData.write_meta(_root, _ObjectiveData.META_CONDITIONS, conditions)
	var groups := [{"group_type": 1, "member_ids": ["tgt_old"], "required": false, "window_seconds": 3.0}]
	_BusinessData.write_meta(_root, _ObjectiveData.META_GROUPS, groups)
	var connections := [{"source_stable_id": "src_old", "event_id": "e", "target_stable_id": "tgt_old",
		"action_id": "a", "params": {}}]
	_BusinessData.write_meta(_root, _ControlData.META_CONNECTIONS, connections)
	_BusinessData.apply_id_remap(_root, {"tgt_old": "tgt_new", "src_old": "src_new"})
	var remapped_conditions: Dictionary = _ObjectiveData.read_conditions(_root)
	_check(NAME, remapped_conditions.has("tgt_new") and not remapped_conditions.has("tgt_old"),
		"条件目标键应重映射。")
	var remapped_groups: Array = _ObjectiveData.read_groups(_root)
	_check(NAME, str((remapped_groups[0] as Dictionary)["member_ids"][0]) == "tgt_new",
		"组成员应重映射。")
	var remapped_connections: Array = _ControlData.read_connections(_root)
	var connection: Dictionary = remapped_connections[0]
	_check(NAME, str(connection["source_stable_id"]) == "src_new"
			and str(connection["target_stable_id"]) == "tgt_new", "连接两端应重映射。")


func _test_08_object_type_resolution() -> void:
	const NAME: String = "08_类型解析"
	var index: Array[Dictionary] = _BusinessData.build_object_index(_root, _registry)
	var has_emitter := false
	var has_crystal := false
	for entry: Dictionary in index:
		if str(entry.type_id) == "main_emitter":
			has_emitter = true
		if str(entry.type_id) == "basic_crystal":
			has_crystal = true
	_check(NAME, has_emitter, "发射器应解析出 main_emitter 类型。")
	_check(NAME, has_crystal, "水晶应解析出 basic_crystal 类型。")
	_check(NAME, _BusinessData.get_inventory_eligible_types(_registry).size() >= 3,
		"应枚举 ≥3 个 inventory_eligible 类型。")


## AF-10 第三批：编辑器 Inventory 类型选项 registry 驱动证明——新增正式 definition（inventory_eligible）
## 无需改 UI/服务即自动出现在选项中，非 eligible 类型不出现（无每类型硬编码）。
func _test_09_registry_driven_dynamic_types() -> void:
	const NAME: String = "09_类型选项registry驱动"
	var fake_registry := {
		"type_ids": [&"future_mechanism", &"editor_only_helper"],
		"definitions": {
			&"future_mechanism": {"display_name": "未来机关", "inventory_eligible": true},
			&"editor_only_helper": {"display_name": "编辑器辅助", "inventory_eligible": false},
		},
	}
	# 鸭子 registry：get_type_ids/get_definition 与 FormalContentRegistry 同形。
	var duck := _DuckRegistry.new(fake_registry["type_ids"], fake_registry["definitions"])
	var options: Array[Dictionary] = _BusinessData.get_inventory_eligible_types(duck)
	var type_ids: Array[StringName] = []
	for option: Dictionary in options:
		type_ids.append(StringName(option["type_id"]))
	_check(NAME, type_ids.has(&"future_mechanism"), "registry 新增 eligible 定义应自动出现在类型选项。")
	_check(NAME, not type_ids.has(&"editor_only_helper"), "非 eligible 类型不应出现。")
	var future: Dictionary = {}
	for option: Dictionary in options:
		if StringName(option["type_id"]) == &"future_mechanism":
			future = option
	_check(NAME, str(future.get("display_name", "")) == "未来机关", "选项显示名应来自定义。")
	# 真实 registry 选项形状：全部携带非空 display_name（面板无需第二事实源）。
	var real_options: Array[Dictionary] = _BusinessData.get_inventory_eligible_types(_registry)
	var shape_ok := not real_options.is_empty()
	for option: Dictionary in real_options:
		if str(option.get("display_name", "")).is_empty():
			shape_ok = false
	_check(NAME, shape_ok, "真实 registry 选项应全部携带 display_name。")


func _report() -> void:
	print("business_data_service_test：")
	for failure: String in _failures:
		print("  FAIL %s" % failure)
	print("  %d checks, %d failures" % [_checks, _failures.size()])
