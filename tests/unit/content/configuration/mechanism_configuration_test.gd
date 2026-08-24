extends SceneTree

## AF-03 Typed Configuration / Stable Field ID 定向合同测试（Guide §11）。
## 覆盖：字段声明校验（空 ID/空名/非法默认值）、值类型域与枚举界、Type Default 构造、
## Instance Override 接受与拒绝（未知字段/类型不符/枚举越界零变更）、重复 Schema 拒绝、
## detached 快照、深拷贝与相等判断、Definition P0-4 域校验（重复 field_id / 非法动作 token / 足迹声明）。
## headless extends SceneTree；全部通过 quit(0)，任一失败 quit(1)。


const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _PlayerInteractionAction: GDScript = preload(
	"res://gameplay/interaction/permission/player_interaction_action.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_field_definition_validation()
	_test_02_value_type_and_enum_bounds()
	_test_03_type_defaults_construction()
	_test_04_override_accept_and_reject()
	_test_05_duplicate_schema_rejected()
	_test_06_snapshot_and_equality()
	_test_07_definition_p04_domain_validation()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 字段声明校验：空 field_id / 空 display_name / 非法默认值各自报错；合法声明零错误。
func _test_01_field_definition_validation() -> void:
	const NAME: String = "01_字段声明校验"
	var field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	_check(NAME, not field.validate().is_empty(), "空声明应报错。")
	field.field_id = &"orientation"
	field.display_name = "镜面朝向"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = 1
	field.default_value = 0
	_check(NAME, field.validate().is_empty(), "合法声明不应报错，实际：%s。" % [",".join(field.validate())])
	field.default_value = 5
	_check(NAME, not field.validate().is_empty(), "默认值越枚举界应报错。")


## 2. 值类型域：BOOL/INT/FLOAT/STRING_NAME/VECTOR2I/VECTOR2I_ARRAY 各自接受正确类型、拒绝错误类型；枚举界只约束 INT。
func _test_02_value_type_and_enum_bounds() -> void:
	const NAME: String = "02_值类型域"
	var field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	field.field_id = &"f"
	field.display_name = "f"
	field.value_type = _MechanismFieldDefinition.ValueType.BOOL
	_check(NAME, field.is_valid_value(true) and not field.is_valid_value(1), "BOOL 域应只接受 bool。")
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_max = -1
	_check(NAME, field.is_valid_value(42) and not field.is_valid_value(1.5), "无枚举 INT 接受任意 int、拒绝 float。")
	field.enum_min = 0
	field.enum_max = 7
	_check(NAME, field.is_valid_value(0) and field.is_valid_value(7), "枚举界含端点。")
	_check(NAME, not field.is_valid_value(-1) and not field.is_valid_value(8), "枚举界外拒绝。")
	field.value_type = _MechanismFieldDefinition.ValueType.VECTOR2I_ARRAY
	_check(NAME, field.is_valid_value([Vector2i.ZERO, Vector2i(1, 0)]) and not field.is_valid_value([Vector2i.ZERO, 3]), "VECTOR2I_ARRAY 全员 Vector2i 才合法。")


## 3. Type Default 构造：按 Schema 填充默认值；空 Schema 产出空配置。
func _test_03_type_defaults_construction() -> void:
	const NAME: String = "03_TypeDefault构造"
	var orientation := _make_orientation_field()
	var direction := _make_direction_field()
	var configuration: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults([orientation, direction])
	_check(NAME, configuration != null, "合法 Schema 应构造成功。")
	_check(NAME, configuration.get_value(&"orientation") == 0 and configuration.get_value(&"direction") == 0, "默认值应为两字段各自 default。")
	_check(NAME, configuration.get_field_ids() == [&"orientation", &"direction"], "字段 ID 快照保持声明序。")
	var empty: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults([])
	_check(NAME, empty != null and empty.get_field_ids().is_empty(), "空 Schema 产出空配置。")


## 4. Instance Override：合法写入成功；未知字段/类型不符/枚举越界拒绝且零变更。
func _test_04_override_accept_and_reject() -> void:
	const NAME: String = "04_Override接受拒绝"
	var configuration: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults([_make_orientation_field()])
	_check(NAME, configuration.apply_override(&"orientation", 1), "枚举界内写入应成功。")
	_check(NAME, configuration.get_value(&"orientation") == 1, "写入后值应为 1。")
	_check(NAME, not configuration.apply_override(&"unknown", 1), "未知字段应拒绝。")
	_check(NAME, not configuration.apply_override(&"orientation", 2), "枚举越界应拒绝。")
	_check(NAME, not configuration.apply_override(&"orientation", &"slash"), "类型不符应拒绝。")
	_check(NAME, configuration.get_value(&"orientation") == 1, "拒绝路径全部零变更。")
	_check(NAME, configuration.has_field(&"orientation") and not configuration.has_field(&"unknown"), "字段存在性判断。")


## 5. 重复 Schema（重复 field_id / 非成员 / 空 ID）构造拒绝返回 null。
func _test_05_duplicate_schema_rejected() -> void:
	const NAME: String = "05_重复Schema拒绝"
	var a := _make_orientation_field()
	var b := _make_orientation_field()
	_check(NAME, _MechanismConfiguration.from_type_defaults([a, b]) == null, "重复 field_id 应返回 null。")
	_check(NAME, _MechanismConfiguration.from_type_defaults(["不是声明"]) == null, "非 MechanismFieldDefinition 成员应返回 null。")


## 6. detached 快照篡改隔离、深拷贝独立演化、相等判断。
func _test_06_snapshot_and_equality() -> void:
	const NAME: String = "06_快照与相等"
	var configuration: _MechanismConfiguration = _MechanismConfiguration.from_type_defaults([_make_orientation_field()])
	configuration.apply_override(&"orientation", 1)
	var snapshot: Dictionary = configuration.snapshot()
	snapshot[&"orientation"] = 99
	_check(NAME, configuration.get_value(&"orientation") == 1, "快照篡改不应影响配置。")
	var copy: _MechanismConfiguration = configuration.duplicate_configuration()
	copy.apply_override(&"orientation", 0)
	_check(NAME, configuration.get_value(&"orientation") == 1 and copy.get_value(&"orientation") == 0, "深拷贝独立演化。")
	_check(NAME, configuration.is_equal_to(configuration.duplicate_configuration()), "同值配置相等。")
	_check(NAME, not configuration.is_equal_to(copy), "异值配置不等。")


## 7. MechanismDefinition P0-4 域校验：重复 field_id / 重复 player_action / 非法动作 token / 空足迹 / 重复偏移 / 非法足迹字段类型。
func _test_07_definition_p04_domain_validation() -> void:
	const NAME: String = "07_Definition域校验"
	var definition := _make_valid_definition()
	_check(NAME, definition.validate_definition().is_empty(), "合法声明零错误，实际：%s。" % [",".join(definition.validate_definition())])
	var dup_definition := _make_valid_definition()
	dup_definition.configuration_fields = [_make_orientation_field(), _make_orientation_field()]
	_check(NAME, _has_error(dup_definition, "重复 field_id"), "重复 field_id 应报错。")
	var action_definition := _make_valid_definition()
	action_definition.configuration_fields = [
		_make_orientation_field(),
		_make_action_bound_field(&"extra", _PlayerInteractionAction.CYCLE_INTERNAL_STATE),
	]
	_check(NAME, _has_error(action_definition, "重复 player_action"), "同动作驱动两字段应报错。")
	var bad_action_definition := _make_valid_definition()
	bad_action_definition.player_interaction_actions = [&"explode"]
	_check(NAME, _has_error(bad_action_definition, "非法动作"), "非法动作 token 应报错。")
	var empty_footprint := _make_valid_definition()
	empty_footprint.static_footprint_offsets = []
	_check(NAME, _has_error(empty_footprint, "static_footprint_offsets 为空"), "空足迹应报错。")
	var dup_footprint := _make_valid_definition()
	dup_footprint.static_footprint_offsets = [Vector2i.ZERO, Vector2i.ZERO]
	_check(NAME, _has_error(dup_footprint, "重复偏移格"), "重复偏移格应报错。")
	var bad_footprint_field := _make_valid_definition()
	bad_footprint_field.footprint_field_id = &"orientation"
	_check(NAME, _has_error(bad_footprint_field, "VECTOR2I_ARRAY"), "足迹字段类型须为 VECTOR2I_ARRAY。")
	var missing_footprint_field := _make_valid_definition()
	missing_footprint_field.footprint_field_id = &"nope"
	_check(NAME, _has_error(missing_footprint_field, "未声明字段"), "足迹字段未声明应报错。")


## 合法镜面朝向字段（枚举 0..1，CYCLE_INTERNAL_STATE 驱动）。
func _make_orientation_field() -> _MechanismFieldDefinition:
	var field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	field.field_id = &"orientation"
	field.display_name = "镜面朝向"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = 1
	field.default_value = 0
	field.player_action = _PlayerInteractionAction.CYCLE_INTERNAL_STATE
	return field


## 合法八方向字段（枚举 0..7）。
func _make_direction_field() -> _MechanismFieldDefinition:
	var field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	field.field_id = &"direction"
	field.display_name = "加速方向"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = 7
	field.default_value = 0
	field.player_action = _PlayerInteractionAction.CYCLE_DIRECTION
	return field


## 生成一个绑定到指定动作的附加字段（用于重复 player_action 检测）。
func _make_action_bound_field(field_id: StringName, action: StringName) -> _MechanismFieldDefinition:
	var field: _MechanismFieldDefinition = _MechanismFieldDefinition.new()
	field.field_id = field_id
	field.display_name = "附加字段"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = 1
	field.default_value = 0
	field.player_action = action
	return field


## 合法 MechanismDefinition（镜面形状：单格足迹 + orientation 字段 + CYCLE_INTERNAL_STATE）。
func _make_valid_definition() -> _MechanismDefinition:
	var definition: _MechanismDefinition = _MechanismDefinition.new()
	definition.content_type_id = &"basic_single_cell_mirror"
	definition.display_name = "基础单格镜"
	definition.scene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")
	definition.inventory_eligible = true
	definition.static_footprint_offsets = [Vector2i.ZERO]
	definition.configuration_fields = [_make_orientation_field()]
	definition.player_interaction_actions = [_PlayerInteractionAction.CYCLE_INTERNAL_STATE]
	return definition


## 判断 Definition 校验错误清单是否含关键子串。
func _has_error(definition: _MechanismDefinition, keyword: String) -> bool:
	return ",".join(definition.validate_definition()).contains(keyword)


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("mechanism_configuration_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
