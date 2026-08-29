class_name ObjectiveMetaReader
extends RefCounted

## Objective 关卡 meta 只读解析器（S3-05 运行期接线）。
## 职责（唯一）：读关卡根 metadata 的 objective_conditions / objective_groups（严格镜像
##   addons/light_speed_level_authoring/authoring/business_data/objective_data_service.gd 的冻结 schema
##   与 BusinessDataService.read_meta 的 detached 深拷贝读法；addons 只读不引），
##   以 target_id（= BasicCrystal.crystal_id，Authoring 侧 stable_instance_id 同源）经正式 LevelObjectRegistry
##   解析 cell，构造 ObjectiveTarget / ObjectiveGroup / ObjectiveModel 交 ObjectiveController 绑定。
## Schema（Authoring 冻结）：objective_conditions = {target_stable_id: String → [{condition_type_id: String,
##   allowed_forms: Array[int]} 或 {condition_type_id: String, target_color: int}（color_condition，ColorValue 红/绿/蓝）]}；
##   objective_groups = [{group_type: int(0=Simultaneous/1=Sequence),
##   member_ids: Array[String], required: bool, window_seconds: float}]。
## 身份边界：target_id 一律经 Registry（crystal_id ↔ cell 双向索引）解析，不从 Node 标识、节点路径、
##   坐标推测或场景结构猜测；meta 引用 Registry 未登记 ID = 非法形状安全失败。
## 目标集合口径：全部 Registry 已登记水晶均为 Target Carrier（BasicCrystal 即 conditions=[] 的 Carrier，冻结语义）；
##   meta conditions 只补条件语义，未引用水晶 = Base Success 独立 Required 目标（与原型"全部点亮完成"语义一致）；
##   Authoring meta 无独立目标 Required 标志，独立目标镜像为 Required（Required/Optional 属组整体）。
## 安全失败：无任一 meta 键 → 返回 null（调用方保持水晶原型回退）；meta 存在但形状非法 / 条件参数越界 /
##   引用未登记 ID / 组构造被拒 → push_error 明确原因并返回 null（整体原子拒绝，不绑定半套模型）。
## 纯只读：不写 meta、不修改 Registry、不进场景树、不触发光晶激活/完成判定（构造后交调用方）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ObjectiveTarget: GDScript = preload("res://gameplay/objectives/objective_target.gd")
const _ObjectiveGroup: GDScript = preload("res://gameplay/objectives/objective_group.gd")
const _ObjectiveModel: GDScript = preload("res://gameplay/objectives/objective_model.gd")
const _ObjectiveConditionConfiguration: GDScript = preload(
	"res://gameplay/objectives/objective_condition_configuration.gd"
)
const _ObjectiveConditionDefinition: GDScript = preload(
	"res://gameplay/objectives/objective_condition_definition.gd"
)

## meta 键（与 addons ObjectiveDataService.META_CONDITIONS / META_GROUPS 一致，不 preload addons）。
const META_CONDITIONS: String = "objective_conditions"
const META_GROUPS: String = "objective_groups"


## 读关卡根并构造统一目标模型（S3-05 唯一入口）。
## [br]返回：构造成功的 ObjectiveModel；无任一 objective meta 键返回 null（原型回退，静默）；
## [br]  meta 存在但非法时 push_error 并返回 null（安全失败回退，不绑定半套模型）。
## [br]registry 为正式 LevelObjectRegistry（水晶身份唯一事实）；root 为承载 objective meta 的关卡根节点。
static func build_model(root: Node, registry: Variant) -> _ObjectiveModel:
	if registry == null:
		push_error("ObjectiveMetaReader：缺少 LevelObjectRegistry，拒绝构造目标模型。")
		return null
	if root == null or (not root.has_meta(META_CONDITIONS) and not root.has_meta(META_GROUPS)):
		return null
	var conditions_variant: Variant = _read_conditions_meta(root)
	if conditions_variant == null:
		return null
	var conditions: Dictionary = conditions_variant
	var group_result: Array = _build_groups(root, registry)
	if group_result.is_empty():
		return null
	var targets: Array = _build_targets(registry, conditions, group_result[1])
	if targets.is_empty() and registry.get_crystal_count() > 0:
		return null
	var model: _ObjectiveModel = _ObjectiveModel.create(targets, group_result[0])
	return model


## 读 objective_conditions meta（detached 深拷贝，镜像 BusinessDataService.read_meta）。
## [br]键存在但非 Dictionary → push_error 返回 null（非法形状安全失败）。
static func _read_conditions_meta(root: Node) -> Variant:
	if not root.has_meta(META_CONDITIONS):
		return {}
	var raw: Variant = root.get_meta(META_CONDITIONS).duplicate(true)
	if not (raw is Dictionary):
		push_error("ObjectiveMetaReader：objective_conditions 必须是 Dictionary（target_id → 条件数组），实际 %s。" % [typeof(raw)])
		return null
	return raw


## 构造组列表：逐组校验形状（Dictionary / group_type / member_ids 数组 / required / window），
## [br]成员 ID 须经 Registry 已登记（身份解析唯一来源），再交 ObjectiveGroup.create 做域校验（类型 / ≥2 / 重复 / Window>0）。
## [br]返回 [groups, member_id_set]；任一组非法返回空数组（整体原子拒绝）。
static func _build_groups(root: Node, registry: Variant) -> Array:
	var groups: Array = []
	var member_ids_seen: Dictionary = {}
	if not root.has_meta(META_GROUPS):
		return [groups, member_ids_seen]
	var raw_groups: Variant = root.get_meta(META_GROUPS).duplicate(true)
	if not (raw_groups is Array):
		push_error("ObjectiveMetaReader：objective_groups 必须是数组，实际 %s。" % [typeof(raw_groups)])
		return []
	for index: int in (raw_groups as Array).size():
		var entry: Variant = (raw_groups as Array)[index]
		if not (entry is Dictionary):
			push_error("ObjectiveMetaReader：组 %d 必须是 Dictionary，实际 %s。" % [index, typeof(entry)])
			return []
		var group_entry: Dictionary = entry
		var raw_members: Variant = group_entry.get("member_ids", [])
		if not (raw_members is Array):
			push_error("ObjectiveMetaReader：组 %d 的 member_ids 必须是数组，实际 %s。" % [index, typeof(raw_members)])
			return []
		var members: Array[StringName] = []
		for member_variant: Variant in (raw_members as Array):
			var member_id: StringName = StringName(str(member_variant))
			if member_id == &"" or not registry.has_crystal(member_id):
				push_error("ObjectiveMetaReader：组 %d 成员 %s 不是场景内已登记水晶（crystal_id）。" % [index, str(member_variant)])
				return []
			members.append(member_id)
		var group: _ObjectiveGroup = _ObjectiveGroup.create(
			int(group_entry.get("group_type", -1)),
			members,
			bool(group_entry.get("required", false)),
			float(group_entry.get("window_seconds", 0.0))
		)
		if group == null:
			return []
		for member_id: StringName in members:
			member_ids_seen[member_id] = true
		groups.append(group)
	return [groups, member_ids_seen]


## 构造目标列表：按 Registry 登记顺序枚举全部水晶（Target Carrier 全量口径），
## [br]meta conditions 补条件（键须为已登记 crystal_id，值须为条件 Dictionary 数组），
## [br]未入组独立目标 Required=true（meta 无独立 Required 标志，镜像原型"全部点亮完成"语义）。
## [br]返回目标数组；条件键未登记 / 任一条件/目标构造被拒返回空数组（整体原子拒绝）。
static func _build_targets(registry: Variant, conditions: Dictionary, member_ids_seen: Dictionary) -> Array:
	for key_variant: Variant in conditions.keys():
		var key_id: StringName = StringName(str(key_variant))
		if key_id == &"" or not registry.has_crystal(key_id):
			push_error("ObjectiveMetaReader：条件目标 %s 不是场景内已登记水晶（crystal_id）。" % [str(key_variant)])
			return []
	var targets: Array = []
	for crystal_id: StringName in registry.get_crystal_ids():
		var crystal: Variant = registry.get_crystal(crystal_id)
		if crystal == null or not is_instance_valid(crystal):
			push_error("ObjectiveMetaReader：水晶 %s 实例无效，拒绝构造目标模型。" % [crystal_id])
			return []
		var condition_configs: Array = []
		if conditions.has(String(crystal_id)):
			var bucket: Variant = conditions[String(crystal_id)]
			if not (bucket is Array):
				push_error("ObjectiveMetaReader：目标 %s 的条件必须是数组，实际 %s。" % [crystal_id, typeof(bucket)])
				return []
			for entry_variant: Variant in (bucket as Array):
				if not (entry_variant is Dictionary):
					push_error("ObjectiveMetaReader：目标 %s 的条件条目必须是 Dictionary，实际 %s。" % [crystal_id, typeof(entry_variant)])
					return []
				var entry: Dictionary = entry_variant
				# color_condition 走 target_color 参数（ColorValue 红/绿/蓝）；其余类型沿用 allowed_forms 参数域。
				var condition_type: StringName = StringName(str(entry.get("condition_type_id", "")))
				var configuration: _ObjectiveConditionConfiguration
				if condition_type == _ObjectiveConditionDefinition.TYPE_COLOR_CONDITION:
					configuration = _ObjectiveConditionConfiguration.create_for_color(
						int(entry.get("target_color", -1)))
				else:
					configuration = _ObjectiveConditionConfiguration.create(
						condition_type, entry.get("allowed_forms", []))
				if configuration == null:
					return []
				condition_configs.append(configuration)
		var target: _ObjectiveTarget = _ObjectiveTarget.create(
			crystal_id,
			crystal.get_cell(),
			not member_ids_seen.has(crystal_id),
			condition_configs
		)
		if target == null:
			return []
		targets.append(target)
	return targets
