@tool
extends RefCounted

# AF-09 Objective 业务数据服务（Guide §13 / §15 / §16）：目标条件与跨目标组的读 / 校验。
# 数据形状：objective_conditions = {target_stable_id: String → [{condition_type_id: String,
# allowed_forms: Array[int]} 或 {condition_type_id: String, target_color: int}（color_condition，
# ColorValue 红/绿/蓝，机关规则 光颜色水晶 v0.1）]}；objective_groups = [{group_type: int,
# member_ids: Array[String], required: bool, window_seconds: float}]。
# 只提供已声明条件（ObjectiveConditionDefinition 注册表枚举，不硬编码名单）；校验与运行时
# ObjectiveConditionConfiguration / ObjectiveGroup 工厂语义同构（含错误清单而非 push_error）。


const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _ObjectiveConditionDefinition: GDScript = preload(
	"res://gameplay/objectives/objective_condition_definition.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)

# meta 键（与 BusinessDataService.apply_id_remap 消费口径一致）。
const META_CONDITIONS: String = "objective_conditions"
const META_GROUPS: String = "objective_groups"

# 组类型显示名（GroupType 枚举：SIMULTANEOUS=0 / SEQUENCE=1）。
const GROUP_TYPE_NAMES: Array[String] = ["同时（Simultaneous）", "顺序（Sequence）"]

# color_condition 目标颜色显示名（顺序对齐 ObjectiveConditionDefinition.get_valid_target_colors = RED/GREEN/BLUE）。
const TARGET_COLOR_NAMES: Array[String] = ["红", "绿", "蓝"]


# 读条件映射（detached；键 = 目标 stable_id）。
static func read_conditions(root: Node) -> Dictionary:
	return _BusinessData.read_meta(root, META_CONDITIONS, {}) as Dictionary


# 读组列表（detached）。
static func read_groups(root: Node) -> Array:
	return _BusinessData.read_meta(root, META_GROUPS, []) as Array


# 已声明条件类型选项（[{condition_type_id, display_name}]；Editor 下拉唯一入口）。
static func get_condition_type_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for definition: Variant in _ObjectiveConditionDefinition.get_all_declared():
		options.append({
			"condition_type_id": String(definition.get_condition_type_id()),
			"display_name": definition.get_display_name(),
		})
	return options


# color_condition 的目标颜色选项（[{value, name}]；value = ColorValue 红/绿/蓝，Panel 下拉唯一入口）。
static func get_target_color_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	var colors: Array[int] = _ObjectiveConditionDefinition.get_valid_target_colors()
	for index: int in colors.size():
		options.append({"value": colors[index], "name": TARGET_COLOR_NAMES[index]})
	return options


# 校验条件映射（目标存在且属 objective_target 域；条件类型已声明且同目标不重复；参数域合法）。
# [br]object_index 由 BusinessDataService.build_object_index 提供（Panel 复用）。
static func validate_conditions(conditions: Dictionary, object_index: Array[Dictionary]) -> PackedStringArray:
	var problems := PackedStringArray()
	var target_domains := _target_domain_index(object_index)
	for target_variant: Variant in conditions.keys():
		var target_id := str(target_variant)
		if not target_domains.has(target_id):
			problems.append("条件目标 %s 不是场景内 objective_target 域正式对象。" % target_id)
			continue
		if target_domains[target_id] != &"objective_target":
			problems.append("条件目标 %s 不接受目标条件（非 objective_target 域）。" % target_id)
			continue
		var seen: Array[String] = []
		for entry_variant: Variant in (conditions[target_variant] as Array):
			var entry: Dictionary = entry_variant
			var type_id := str(entry.get("condition_type_id", ""))
			if _ObjectiveConditionDefinition.get_by_type_id(StringName(type_id)) == null:
				problems.append("目标 %s 的条件类型 %s 未正式声明。" % [target_id, type_id])
				continue
			if seen.has(type_id):
				problems.append("目标 %s 的条件类型 %s 重复（同类型单目标最多一次）。" % [target_id, type_id])
			seen.append(type_id)
			problems.append_array(_validate_condition_params(target_id, type_id, entry.get("allowed_forms", []), entry.get("target_color", -1)))
	return problems


# 单条件参数域（v1：form_condition → allowed_forms 非空、值域合法、去重有序；
# color_condition → target_color ∈ ColorValue 红/绿/蓝，WHITE/NONE 越界拒绝）。
static func _validate_condition_params(target_id: String, type_id: String, allowed_forms: Array, target_color: Variant) -> PackedStringArray:
	var problems := PackedStringArray()
	if type_id == String(_ObjectiveConditionDefinition.TYPE_COLOR_CONDITION):
		if not int(target_color) in _ObjectiveConditionDefinition.get_valid_target_colors():
			problems.append("目标 %s 的 color_condition：目标颜色 %s 越界（仅红/绿/蓝）。" % [target_id, str(target_color)])
		return problems
	if type_id != String(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION):
		return problems
	if (allowed_forms as Array).is_empty():
		problems.append("目标 %s 的 form_condition：allowed_forms 不得为空。" % target_id)
	for form_variant: Variant in allowed_forms:
		if not int(form_variant) in _ObjectiveConditionDefinition.get_valid_light_forms():
			problems.append("目标 %s 的 form_condition：光形态值 %s 越界。" % [target_id, str(form_variant)])
	return problems


# 校验组列表（类型域、≥2 成员、成员不重复且都是 objective_target 目标、Window > 0）。
static func validate_groups(groups: Array, object_index: Array[Dictionary]) -> PackedStringArray:
	var problems := PackedStringArray()
	var target_domains := _target_domain_index(object_index)
	for index: int in groups.size():
		var group: Dictionary = groups[index]
		var group_type := int(group.get("group_type", -1))
		if group_type != 0 and group_type != 1:
			problems.append("组 %d：非法组类型 %d（仅 Simultaneous/Sequence）。" % [index, group_type])
		var members: Array = group.get("member_ids", [])
		if members.size() < 2:
			problems.append("组 %d：Composite Group 至少 2 成员。" % index)
		var seen: Array[String] = []
		for member_variant: Variant in members:
			var member_id := str(member_variant)
			if seen.has(member_id):
				problems.append("组 %d：成员 %s 重复。" % [index, member_id])
			seen.append(member_id)
			if not target_domains.has(member_id):
				problems.append("组 %d：成员 %s 不是场景内正式对象。" % [index, member_id])
			elif target_domains[member_id] != &"objective_target":
				problems.append("组 %d：成员 %s 不是 objective_target 目标。" % [index, member_id])
		if float(group.get("window_seconds", 0.0)) <= 0.0:
			problems.append("组 %d：完成 Window 必须 > 0。" % index)
	return problems


# 目标域索引：stable_id → content_domain（仅含已知类型对象）。
static func _target_domain_index(object_index: Array[Dictionary]) -> Dictionary:
	var domains := {}
	for entry: Dictionary in object_index:
		if entry.type_id != &"":
			domains[entry.stable_id] = entry.domain
	return domains
