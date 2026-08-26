@tool
extends RefCounted

# AF-09 关卡业务数据共享服务（Guide §15/§78/§80/§87/§88）：非空间业务数据的 meta 读写底层 +
# Inventory / Presentation / Tutorial Trigger / Move Limit / Main Emitter Level Rules 五个轻域。
# 持久化载体 = 关卡根 meta（与 level_id/display_name 同一冻结口径：无脚本关卡，meta 是唯一
# 不破坏“无脚本”冻结的持久化载体，随场景保存落盘）。数据形状 = 纯 Dictionary/Array + 基础类型，
# 字典键一律 String（序列化中立）；StringName 域（content_type_id 等）在运行期接线边界再转换
# （FROZEN_DEFERRED）。Objective/Control 重域见 objective_data_service / control_data_service。
# 校验只返回问题清单（编辑器口径），不 push_error；运行时 RefCounted 工厂语义同构。


const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _ObjectiveConditionDefinition: GDScript = preload(
	"res://gameplay/objectives/objective_condition_definition.gd"
)
const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)

# meta 键（冻结：改名 / 换载体属 breaking）。
const META_INVENTORY: String = "inventory_entries"
const META_PRESENTATION: String = "presentation_text"
const META_TUTORIALS: String = "tutorial_triggers"
const META_MOVE_LIMIT: String = "move_limit"
const META_EMITTER_RULES: String = "emitter_rules"

# 正式声明的 Presentation Trigger（Guide §80；新增触发类型 = 程序员改本表，编辑器不提供自由表达式）。
const TUTORIAL_TRIGGER_IDS: Array[String] = [
	"level_start", "first_fire", "first_move", "first_recover", "objective_completed",
]

# 脚本资源路径 → content_type_id 缓存（对象→类型解析；编辑器进程内静态，不落盘）。
static var _script_type_cache: Dictionary = {}


# ===== meta 读写底层（全部 detached，读侧复制、写侧深拷贝存入）=====

# 读一个 meta 键的 detached 深拷贝（无值返回 absent_default）。
static func read_meta(root: Node, key: String, absent_default: Variant) -> Variant:
	if root == null or not root.has_meta(key):
		return absent_default
	return root.get_meta(key).duplicate(true)


# 校验通过后写入 detached 深拷贝；调用方先经 validate_* 确认（本函数不做域校验）。
static func write_meta(root: Node, key: String, value: Variant) -> void:
	root.set_meta(key, value.duplicate(true))


# ===== 对象索引与类型解析（Objective/Control/Inventory 共用）=====

# 全部正式对象索引：[{stable_id, type_id, display_name, domain, node}]（按场景子树序）。
static func build_object_index(root: Node, registry) -> Array[Dictionary]:
	var index: Array[Dictionary] = []
	if root == null:
		return index
	for node: Node in _StableIdService.find_formal_objects(root):
		var raw_id: Variant = node.get("stable_instance_id")
		var type_id: StringName = resolve_content_type_id(node, registry)
		var display_name: String = ""
		var domain: StringName = &""
		if registry != null and type_id != &"":
			var definition: Variant = registry.get_definition(type_id)
			if definition != null:
				display_name = definition.display_name
				domain = definition.get_content_domain()
		index.append({
			"stable_id": str(raw_id) if raw_id != null else "",
			"type_id": type_id,
			"display_name": display_name,
			"domain": domain,
			"node": node,
		})
	return index


# 解析节点的正式 content_type_id（经定义场景根脚本比对；未声明返回 &""）。
static func resolve_content_type_id(node: Node, registry) -> StringName:
	if registry == null:
		return &""
	var script: Variant = node.get_script()
	if script == null:
		return &""
	var path: String = script.resource_path
	if path.is_empty():
		return &""
	if _script_type_cache.has(path):
		return _script_type_cache[path]
	for type_id: StringName in registry.get_type_ids():
		var definition: Variant = registry.get_definition(type_id)
		if definition == null or definition.scene == null:
			continue
		var instance: Node = definition.scene.instantiate()
		var instance_script: Variant = instance.get_script()
		instance.free()
		if instance_script != null and instance_script.resource_path == path:
			_script_type_cache[path] = type_id
			return type_id
	_script_type_cache[path] = &""
	return &""


# Inventory 可选类型：Registry 中 inventory_eligible 的机制域定义（有序 [{type_id, display_name}]）。
static func get_inventory_eligible_types(registry) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if registry == null:
		return options
	for type_id: StringName in registry.get_type_ids():
		var definition: Variant = registry.get_definition(type_id)
		if definition != null and definition.get("inventory_eligible") == true:
			options.append({"type_id": type_id, "display_name": definition.display_name})
	return options


# ===== Inventory（Guide §15.1）=====

# 读库存条目（[{content_type_id: String, initial_quantity: int, order: int}]）。
static func read_inventory(root: Node) -> Array:
	return read_meta(root, META_INVENTORY, []) as Array


# 校验库存条目（类型已声明且 inventory_eligible、数量非负、类型不重复；order 作者自由）。
static func validate_inventory(entries: Array, registry) -> PackedStringArray:
	var problems := PackedStringArray()
	var seen: Array[String] = []
	for entry_variant: Variant in entries:
		var entry: Dictionary = entry_variant
		var type_id := str(entry.get("content_type_id", ""))
		var definition: Variant = registry.get_definition(StringName(type_id)) if registry != null else null
		if definition == null:
			problems.append("库存条目类型 %s 未在 Registry 声明。" % type_id)
		elif definition.get("inventory_eligible") != true:
			problems.append("库存条目类型 %s 不可入库（inventory_eligible=false）。" % type_id)
		if seen.has(type_id):
			problems.append("库存条目类型 %s 重复（每类型一条，数量并到同条目）。" % type_id)
		seen.append(type_id)
		if int(entry.get("initial_quantity", 0)) < 0:
			problems.append("库存条目 %s 数量为负。" % type_id)
	return problems


# ===== Presentation / Text（Guide §78）=====

# 读玩家文案（{title, intro, objective, hint, completion}，缺省全空串）。
static func read_presentation(root: Node) -> Dictionary:
	var value: Dictionary = read_meta(root, META_PRESENTATION, {}) as Dictionary
	return {
		"title": str(value.get("title", "")),
		"intro": str(value.get("intro", "")),
		"objective": str(value.get("objective", "")),
		"hint": str(value.get("hint", "")),
		"completion": str(value.get("completion", "")),
	}


# 校验玩家文案（五个键全为 String；无其它硬约束——玩法冲突由后续 Validator 警告域扩展）。
static func validate_presentation(value: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key: String in ["title", "intro", "objective", "hint", "completion"]:
		if not (value.get(key, "") is String):
			problems.append("Presentation 字段 %s 必须是文本。" % key)
	return problems


# ===== Tutorial / Hint Trigger（Guide §80）=====

# 读教学触发列表（[{text, trigger_id, display_style, duration_seconds}]）。
static func read_tutorials(root: Node) -> Array:
	return read_meta(root, META_TUTORIALS, []) as Array


# 校验教学触发（trigger 已正式声明、文本非空、时长 > 0、样式非空）。
static func validate_tutorials(triggers: Array) -> PackedStringArray:
	var problems := PackedStringArray()
	for index: int in triggers.size():
		var entry: Dictionary = triggers[index]
		var trigger_id := str(entry.get("trigger_id", ""))
		if not TUTORIAL_TRIGGER_IDS.has(trigger_id):
			problems.append("教学触发 %d：触发器 %s 未正式声明。" % [index, trigger_id])
		if str(entry.get("text", "")).is_empty():
			problems.append("教学触发 %d：文本为空。" % index)
		if str(entry.get("display_style", "")).is_empty():
			problems.append("教学触发 %d：显示样式为空。" % index)
		if float(entry.get("duration_seconds", 0.0)) <= 0.0:
			problems.append("教学触发 %d：纯视觉持续时间必须 > 0。" % index)
	return problems


# ===== General Rules / Move Limit（Guide §87.1）=====

# 读 Move Limit（缺省关闭；不用 -1 Sentinel，禁用时 Count 只读不落语义）。
static func read_move_limit(root: Node) -> Dictionary:
	var value: Dictionary = read_meta(root, META_MOVE_LIMIT, {}) as Dictionary
	return {
		"enabled": bool(value.get("enabled", false)),
		"max_count": int(value.get("max_count", 1)),
	}


# 校验 Move Limit（启用时 Maximum Count ≥ 1）。
static func validate_move_limit(value: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	if bool(value.get("enabled", false)) and int(value.get("max_count", 0)) < 1:
		problems.append("Move Limit 启用时 Maximum Count 必须 ≥ 1（不使用 -1 Sentinel）。")
	return problems


# ===== Main Emitter Level Rules（Guide §88）=====

# 读发射器关卡规则（缺省 = 全集合：不限制）。initial form/direction 真值在 Emitter 节点字段。
static func read_emitter_rules(root: Node) -> Dictionary:
	var value: Dictionary = read_meta(root, META_EMITTER_RULES, {}) as Dictionary
	var forms: Array[int] = []
	for form_variant: Variant in value.get("allowed_forms", all_light_forms()):
		forms.append(int(form_variant))
	var ray: Array[int] = []
	for dir_variant: Variant in value.get("allowed_ray_directions", _all_directions()):
		ray.append(int(dir_variant))
	var particle: Array[int] = []
	for dir_variant: Variant in value.get("allowed_particle_directions", _all_directions()):
		particle.append(int(dir_variant))
	return {
		"allowed_forms": forms,
		"allowed_ray_directions": ray,
		"allowed_particle_directions": particle,
	}


# 校验发射器规则（三集合非空且都在枚举域内）+ 与场景发射器初始配置一致性（§88.1/88.2：initial ∈ allowed）。
static func validate_emitter_rules(root: Node, value: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var forms: Array = value.get("allowed_forms", [])
	if forms.is_empty():
		problems.append("Allowed Forms 必须非空（集合即玩家可选范围）。")
	for form_variant: Variant in forms:
		if not int(form_variant) in _LightEmissionTypes.LightForm.values():
			problems.append("Allowed Forms 含越界形态值 %s。" % str(form_variant))
	for direction_key: String in ["allowed_ray_directions", "allowed_particle_directions"]:
		var directions: Array = value.get(direction_key, [])
		if directions.is_empty():
			problems.append("%s 必须非空子集。" % direction_key)
		for dir_variant: Variant in directions:
			if not int(dir_variant) in _EmitterConfigNode.RayDirection.values():
				problems.append("%s 含越界方向值 %s。" % [direction_key, str(dir_variant)])
	problems.append_array(_check_emitter_initial_consistency(root, value))
	return problems


# 场景一致性：发射器节点存在时，initial form / direction 必须属于 allowed 集合（§88 冻结）。
static func _check_emitter_initial_consistency(root: Node, value: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var emitter := find_emitter(root)
	if emitter == null:
		return problems
	var initial_form: int = int(emitter.get("default_light_form"))
	if not initial_form in (value.get("allowed_forms", []) as Array):
		problems.append("发射器 Initial Form（%d）不在 Allowed Forms 内。" % initial_form)
	var ray_direction: int = int(emitter.get("ray_default_direction"))
	if not ray_direction in (value.get("allowed_ray_directions", []) as Array):
		problems.append("发射器 Initial 光线方向（%d）不在 Allowed Directions 内。" % ray_direction)
	var particle_direction: int = int(emitter.get("particle_default_direction"))
	if not particle_direction in (value.get("allowed_particle_directions", []) as Array):
		problems.append("发射器 Initial 光粒方向（%d）不在 Allowed Directions 内。" % particle_direction)
	return problems


# 找场景内第一个 EmitterConfigNode（v0 恰好一个 Main Emitter；面板 Initial 配置入口）。
static func find_emitter(root: Node) -> Node:
	for node: Node in _StableIdService.find_formal_objects(root):
		if node is _EmitterConfigNode:
			return node
	return null


# ===== Stable ID 引用重映射（Duplicate as New Level 消费 AF-08 重映射表）=====

# 将全部业务 meta 中的旧 stable_id 引用替换为新 ID（Objective 条件目标键 / 组成员 / Control 四段中
# source 与 target；remap 覆盖不到的引用原样保留，由校验域暴露）。
static func apply_id_remap(root: Node, remap: Dictionary) -> void:
	_remap_dict_keys(root, "objective_conditions", remap)
	_remap_group_members(root, "objective_groups", remap)
	_remap_array_fields(root, "control_connections", ["source_stable_id", "target_stable_id"], remap)


# 重映射一个 Dictionary 键域 meta（键 = 目标 stable_id）。
static func _remap_dict_keys(root: Node, key: String, remap: Dictionary) -> void:
	if not root.has_meta(key):
		return
	var value: Dictionary = root.get_meta(key)
	var remapped: Dictionary = {}
	for old_id: Variant in value.keys():
		var new_id: String = str(remap.get(old_id, old_id))
		remapped[new_id] = value[old_id]
	root.set_meta(key, remapped)


# 重映射组 meta 的成员 ID 列表（member_ids 是 ID 列表，不是单值字段）。
static func _remap_group_members(root: Node, key: String, remap: Dictionary) -> void:
	if not root.has_meta(key):
		return
	var value: Array = root.get_meta(key)
	for entry: Variant in value:
		var members: Array = (entry as Dictionary).get("member_ids", [])
		for index: int in members.size():
			var old_id := str(members[index])
			if remap.has(old_id):
				members[index] = str(remap[old_id])


# 重映射一个 Array 域 meta 中若干单值字符串字段。
static func _remap_array_fields(root: Node, key: String, fields: Array, remap: Dictionary) -> void:
	if not root.has_meta(key):
		return
	var value: Array = root.get_meta(key)
	for entry: Variant in value:
		var dictionary := entry as Dictionary
		for field: Variant in fields:
			var old_id := str(dictionary.get(field, ""))
			if remap.has(old_id):
				dictionary[field] = str(remap[old_id])


# 全形态集合（缺省不限制口径）。
static func all_light_forms() -> Array[int]:
	return [
		_LightEmissionTypes.LightForm.RAY,
		_LightEmissionTypes.LightForm.PARTICLE,
	]


# 八方向全集（两枚举值域同为 0..7，追加序冻结）。
static func _all_directions() -> Array[int]:
	return [0, 1, 2, 3, 4, 5, 6, 7]
