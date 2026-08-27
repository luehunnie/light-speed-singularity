extends SceneTree

## S3-05 ObjectiveMetaReader 定向单元测试。
## 覆盖：无 meta / 缺 Registry 原型回退；正例（条件 + 组 → ObjectiveModel 结构与 Registry cell 解析）；
## 空 meta 全 Base Success 独立 Required；非法形状安全失败（meta 类型 / 条目类型 / 未声明类型 / 参数越界 /
## 未知 target_id / 组形状 / 未知成员 / 组域校验 / 一目标多组 / 无效水晶实例）；未引用水晶默认入模（Base Success）。
## Reader 只构造模型不激活水晶，水晶无需 _ready（区别 objective_controller_model_test 的可激活水晶约定）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。


const _ObjectiveMetaReader: GDScript = preload("res://gameplay/objectives/objective_meta_reader.gd")
const _ObjectiveGroup: GDScript = preload("res://gameplay/objectives/objective_group.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _RAY: int = _LightEmissionTypes.LightForm.RAY
const _PARTICLE: int = _LightEmissionTypes.LightForm.PARTICLE


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _crystals: Array[BasicCrystal] = []


func _initialize() -> void:
	_test_01_no_meta_fallback()
	_test_02_valid_conditions_and_group()
	_test_03_empty_meta_all_base_success()
	_test_04_unreferenced_crystal_defaults()
	_test_05_illegal_conditions_shapes()
	_test_06_illegal_group_shapes()
	_test_07_identity_only_via_registry()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


# ===== 夹具 =====

## 构造无需 _ready 的水晶（Reader 只读 crystal_id 与派生 cell，不激活）。
func _make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.crystal_id = crystal_id
	crystal.cell = cell
	_crystals.append(crystal)
	return crystal


## 三水晶 Registry（c1@(1,1) / c2@(2,2) / c3@(3,3)，登记顺序即目标顺序）。
func _make_registry() -> _LevelObjectRegistry:
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	registry.register_crystal(&"c1", Vector2i(1, 1), _make_crystal(&"c1", Vector2i(1, 1)))
	registry.register_crystal(&"c2", Vector2i(2, 2), _make_crystal(&"c2", Vector2i(2, 2)))
	registry.register_crystal(&"c3", Vector2i(3, 3), _make_crystal(&"c3", Vector2i(3, 3)))
	return registry


## 承载 meta 的关卡根替身。
func _make_root() -> Node2D:
	return Node2D.new()


## 单条件条目（form_condition + allowed_forms）。
func _condition_entry(type_id: String, allowed_forms: Array) -> Dictionary:
	return {"condition_type_id": type_id, "allowed_forms": allowed_forms}


## 组条目（Authoring 冻结 schema；members 留 Variant 以便注入非法形状用例）。
func _group_entry(group_type: int, members: Variant, required: bool, window_seconds: float) -> Dictionary:
	return {"group_type": group_type, "member_ids": members, "required": required, "window_seconds": window_seconds}


# ===== 测试 =====

## 1. 无 meta 原型回退：无任一 objective meta 键返回 null（静默）；null root 同理；null Registry 显式拒绝。
func _test_01_no_meta_fallback() -> void:
	const NAME: String = "01_无meta原型回退"
	var registry: _LevelObjectRegistry = _make_registry()
	var plain_root: Node2D = _make_root()
	_check(NAME, _ObjectiveMetaReader.build_model(plain_root, registry) == null, "无 meta 应返回 null（原型回退）。")
	plain_root.free()
	_check(NAME, _ObjectiveMetaReader.build_model(null, registry) == null, "null root 应返回 null。")
	var null_registry_root: Node2D = _make_root()
	_check(NAME, _ObjectiveMetaReader.build_model(null_registry_root, null) == null, "null Registry 应返回 null（安全失败）。")
	null_registry_root.free()


## 2. 正例：条件 + 组 → 模型结构、Registry cell 解析、独立/入组 required 语义。
func _test_02_valid_conditions_and_group() -> void:
	const NAME: String = "02_正例条件与组"
	var registry: _LevelObjectRegistry = _make_registry()
	var root: Node2D = _make_root()
	root.set_meta("objective_conditions", {"c1": [_condition_entry("form_condition", [_RAY])]})
	root.set_meta("objective_groups", [_group_entry(1, ["c2", "c3"], true, 5.0)])
	var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
	root.free()
	if not _check(NAME, model != null, "合法 meta 应构造模型。"):
		return
	_check(NAME, model.get_target_count() == 3, "目标数期望 3（Registry 全量水晶口径），实际 %d。" % [model.get_target_count()])
	_check(NAME, model.get_group_count() == 1, "组数期望 1。")
	var c1: Variant = model.get_target_by_id(&"c1")
	_check(NAME, c1 != null and c1.get_cell() == Vector2i(1, 1), "c1 cell 应经 Registry 解析为 (1,1)。")
	_check(NAME, c1 != null and c1.get_condition_count() == 1, "c1 应挂 1 条 form_condition。")
	_check(NAME, c1 != null and c1.is_required(), "独立目标 c1 应 Required。")
	_check(NAME, model.get_target_at_cell(Vector2i(2, 2)) != null, "c2 应按 Registry cell (2,2) 路由。")
	_check(NAME, model.get_target_at_cell(Vector2i(3, 3)) != null, "c3 应按 Registry cell (3,3) 路由。")
	_check(NAME, model.get_group_of_target(&"c2") != null, "c2 应属序列组。")
	_check(NAME, model.get_group_of_target(&"c3") == model.get_group_of_target(&"c2"), "c3 与 c2 同组。")
	var c2_target: Variant = model.get_target_by_id(&"c2")
	_check(NAME, c2_target != null and c2_target.get_condition_count() == 0, "未挂条件成员 c2 应 Base Success（0 条件）。")


## 3. 空 meta（两键均在但为空）→ 全部水晶 Base Success 独立 Required，初始未完成。
func _test_03_empty_meta_all_base_success() -> void:
	const NAME: String = "03_空meta全BaseSuccess"
	var registry: _LevelObjectRegistry = _make_registry()
	var root: Node2D = _make_root()
	root.set_meta("objective_conditions", {})
	root.set_meta("objective_groups", [])
	var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
	root.free()
	if not _check(NAME, model != null, "空 meta（键存在）应构造模型而非回退。"):
		return
	_check(NAME, model.get_target_count() == 3, "目标数期望 3。")
	_check(NAME, model.get_group_count() == 0, "组数期望 0。")
	var snapshot: Dictionary = model.get_progress_snapshot(0.0)
	var all_required: bool = true
	for entry_variant: Variant in snapshot["targets"]:
		all_required = all_required and bool(entry_variant["required"])
	_check(NAME, all_required, "全部目标应 Required（镜像原型全部点亮完成语义）。")
	_check(NAME, not model.is_complete(0.0), "初始不应完成。")


## 4. 未引用水晶默认入模：meta 只引用 c1 时 c2/c3 仍是 Base Success 独立 Required 目标（完成仍需全部命中）。
func _test_04_unreferenced_crystal_defaults() -> void:
	const NAME: String = "04_未引用水晶默认入模"
	var registry: _LevelObjectRegistry = _make_registry()
	var root: Node2D = _make_root()
	root.set_meta("objective_conditions", {"c1": [_condition_entry("form_condition", [_RAY, _PARTICLE])]})
	var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
	root.free()
	if not _check(NAME, model != null, "单目标 meta 应构造模型。"):
		return
	_check(NAME, model.get_target_count() == 3, "未引用水晶也应入模（3 目标）。")
	var c3_target: Variant = model.get_target_by_id(&"c3")
	_check(NAME, c3_target != null and c3_target.get_condition_count() == 0 and c3_target.is_required(),
		"未引用 c3 应为 Base Success Required 目标。")
	_check(NAME, not model.is_complete(0.0), "初始不应完成。")


## 5. 非法 conditions 形状安全失败（全部返回 null，整体原子拒绝）。
func _test_05_illegal_conditions_shapes() -> void:
	const NAME: String = "05_非法conditions形状"
	var cases: Array = [
		["meta 非 Dictionary", {"conditions_value": "not_a_dict"}],
		["目标值非数组", {"conditions_value": {"c1": "not_array"}}],
		["条件条目非 Dictionary", {"conditions_value": {"c1": ["not_dict"]}}],
		["未声明条件类型", {"conditions_value": {"c1": [_condition_entry("unknown_type", [_RAY])]}}],
		["allowed_forms 为空", {"conditions_value": {"c1": [_condition_entry("form_condition", [])]}}],
		["allowed_forms 越界", {"conditions_value": {"c1": [_condition_entry("form_condition", [9])]}}],
		["未知 target_id", {"conditions_value": {"ghost": [_condition_entry("form_condition", [_RAY])]}}],
		["同目标重复条件类型", {"conditions_value": {"c1": [
			_condition_entry("form_condition", [_RAY]),
			_condition_entry("form_condition", [_PARTICLE]),
		]}}],
	]
	for case: Array in cases:
		var label: String = case[0]
		var registry: _LevelObjectRegistry = _make_registry()
		var root: Node2D = _make_root()
		root.set_meta("objective_conditions", case[1]["conditions_value"])
		var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
		root.free()
		_check(NAME, model == null, "[%s] 应安全失败返回 null。" % [label])


## 6. 非法 groups 形状安全失败（组域校验交 ObjectiveGroup.create，形状守卫在 reader）。
func _test_06_illegal_group_shapes() -> void:
	const NAME: String = "06_非法groups形状"
	var cases: Array = [
		["meta 非数组", {"groups_value": "not_array"}],
		["组条目非 Dictionary", {"groups_value": ["not_dict"]}],
		["member_ids 非数组", {"groups_value": [_group_entry(1, "not_array", true, 5.0)]}],
		["未知成员", {"groups_value": [_group_entry(1, ["c2", "ghost"], true, 5.0)]}],
		["非法组类型", {"groups_value": [_group_entry(7, ["c2", "c3"], true, 5.0)]}],
		["成员不足 2", {"groups_value": [_group_entry(0, ["c2"], true, 5.0)]}],
		["成员重复", {"groups_value": [_group_entry(0, ["c2", "c2"], true, 5.0)]}],
		["Window <= 0", {"groups_value": [_group_entry(1, ["c2", "c3"], true, 0.0)]}],
		["一目标属两组", {"groups_value": [
			_group_entry(0, ["c1", "c2"], true, 5.0),
			_group_entry(1, ["c1", "c3"], true, 5.0),
		]}],
	]
	for case: Array in cases:
		var label: String = case[0]
		var registry: _LevelObjectRegistry = _make_registry()
		var root: Node2D = _make_root()
		root.set_meta("objective_groups", case[1]["groups_value"])
		var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
		root.free()
		_check(NAME, model == null, "[%s] 应安全失败返回 null。" % [label])


## 7. 身份只经 Registry：条件键与组成员在 Registry 无此 crystal_id 时拒绝（不从节点名/坐标推测）；
##    已释放水晶实例同样拒绝。
func _test_07_identity_only_via_registry() -> void:
	const NAME: String = "07_身份只经Registry"
	var registry: _LevelObjectRegistry = _make_registry()
	# 条件键为坐标串/节点名形态且未登记 → 拒绝。
	var root: Node2D = _make_root()
	root.set_meta("objective_conditions", {"(1,1)": [_condition_entry("form_condition", [_RAY])]})
	var model: Variant = _ObjectiveMetaReader.build_model(root, registry)
	root.free()
	_check(NAME, model == null, "未登记 ID（坐标串形态）应拒绝，不从坐标推测身份。")
	# 已释放水晶实例：Registry 仍登记但实例无效 → 拒绝。
	var stale_root: Node2D = _make_root()
	var stale_crystal: BasicCrystal = _make_crystal(&"c_dead", Vector2i(9, 9))
	registry.register_crystal(&"c_dead", Vector2i(9, 9), stale_crystal)
	stale_crystal.free()
	var stale_model: Variant = _ObjectiveMetaReader.build_model(stale_root, registry)
	stale_root.free()
	_check(NAME, stale_model == null, "已释放水晶实例应拒绝构造。")


# ===== 汇总 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _cleanup() -> void:
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			crystal.free()
	_crystals.clear()


func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("objective_meta_reader_test： %d/%d 组通过，%d/%d 断言通过。" % [group_count - _failures.size(), group_count, passed_checks, _checks])
	if not _failures.is_empty():
		for failure: String in _failures:
			print("  失败：%s" % [failure])
