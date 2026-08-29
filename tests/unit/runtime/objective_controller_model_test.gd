extends SceneTree

## AF-04 / P0-6 定向测试 3/3：ObjectiveModel + ObjectiveController 统一完成状态。
## 覆盖：模型构造校验（重复 ID / 重复格 / 未知成员 / 一目标多组）、按格命中路由、
## 条件失败命中在顺序组中只算 Invalid Attempt、统一完成判定（全部 Required 完成，Optional 不阻挡）、
## 进度快照 detached、控制器绑定模型后 is_completed / apply_hit / reset_runtime 双路径、
## 未绑定模型时 apply_hit 水晶原型回退（Ray/Particle 命中事实均走通）。
## 可激活水晶需 _ready 解析 @onready _visual；--script 模式手动调用 _ready（同 objective_controller_test 约定）。


const _ObjectiveController: GDScript = preload("res://gameplay/objectives/objective_controller.gd")
const _ObjectiveModel: GDScript = preload("res://gameplay/objectives/objective_model.gd")
const _ObjectiveTarget: GDScript = preload("res://gameplay/objectives/objective_target.gd")
const _ObjectiveGroup: GDScript = preload("res://gameplay/objectives/objective_group.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")
const _ObjectiveConditionConfiguration: GDScript = preload("res://gameplay/objectives/objective_condition_configuration.gd")
const _ObjectiveConditionDefinition: GDScript = preload("res://gameplay/objectives/objective_condition_definition.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _VisualViewScene: PackedScene = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn")
const _CrystalProfile: Resource = preload("res://assets/visual_profiles/basic_crystal_visuals.tres")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 本轮创建的水晶实例，统一释放避免 --script 模式泄漏。
var _crystals: Array[BasicCrystal] = []
## 可控时间源（时间 seam，测试直接赋值推进）。
var _now: float = 0.0


func _initialize() -> void:
	_test_01_model_validation()
	_test_02_apply_hit_routing()
	_test_03_invalid_attempt_in_sequence()
	_test_04_unified_completion_required_only()
	_test_05_progress_snapshot_detached()
	_test_06_controller_fallback_crystal()
	_test_07_controller_model_overrides()
	_test_08_controller_time_seam_sequence()
	_test_09_controller_reset_both()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 构造 Base Success 目标（无条件）。
func _base_target(target_id: StringName, cell: Vector2i, required: bool) -> _ObjectiveTarget:
	var target: _ObjectiveTarget = _ObjectiveTarget.create(target_id, cell, required, [])
	return target


## 构造 RAY 形态条件目标。
func _ray_only_target(target_id: StringName, cell: Vector2i, required: bool) -> _ObjectiveTarget:
	var forms: Array = [_LightEmissionTypes.LightForm.RAY]
	var configuration: _ObjectiveConditionConfiguration = _ObjectiveConditionConfiguration.create(_ObjectiveConditionDefinition.TYPE_FORM_CONDITION, forms)
	var conditions: Array = [configuration]
	var target: _ObjectiveTarget = _ObjectiveTarget.create(target_id, cell, required, conditions)
	return target


## 构造 Ray 命中事实。
func _ray_hit(cell: Vector2i) -> _ObjectiveHitContext:
	var hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_ray(cell, Vector2i(1, 0), 7, 3, 0)
	return hit


## 构造 Particle 命中事实。
func _particle_hit(cell: Vector2i) -> _ObjectiveHitContext:
	var hit: _ObjectiveHitContext = _ObjectiveHitContext.create_for_particle(cell, Vector2i(0, 1), 9, 4, 1)
	return hit


## 1. 模型构造校验：重复 ID / 重复格 / 未知成员 / 一目标多组拒绝。
func _test_01_model_validation() -> void:
	const NAME: String = "01_模型构造校验"
	var a: _ObjectiveTarget = _base_target(&"a", Vector2i(1, 1), true)
	var a_dup: _ObjectiveTarget = _base_target(&"a", Vector2i(2, 2), true)
	var b: _ObjectiveTarget = _base_target(&"b", Vector2i(1, 1), true)
	var dup_id: Array = [a, a_dup]
	_check(NAME, _ObjectiveModel.create(dup_id, []) == null, "重复目标 ID 应拒绝。")
	var dup_cell: Array = [a, b]
	_check(NAME, _ObjectiveModel.create(dup_cell, []) == null, "重复格应拒绝（一格一目标）。")
	var unknown_member: Array = [&"a", &"ghost"]
	var bad_group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, unknown_member, true, 5.0)
	var with_bad_group: Array = [bad_group]
	_check(NAME, _ObjectiveModel.create([a], with_bad_group) == null, "未知组成员应拒绝。")
	var members_ab: Array = [&"a", &"a"]
	var impossible: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, members_ab, true, 5.0)
	_check(NAME, impossible == null, "同目标重复入组在组构造层已拒绝。")
	var group_one: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"a", &"c"], true, 5.0)
	var group_two: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, [&"a", &"c"], true, 5.0)
	var c: _ObjectiveTarget = _base_target(&"c", Vector2i(3, 3), false)
	var two_groups: Array = [group_one, group_two]
	_check(NAME, _ObjectiveModel.create([a, c], two_groups) == null, "一目标属两组应拒绝。")
	var ok_model: _ObjectiveModel = _ObjectiveModel.create([a, c], [group_one])
	_check(NAME, ok_model != null, "合法模型应构造成功。")
	if ok_model != null:
		_check(NAME, ok_model.get_target_count() == 2, "目标数应为 2。")
		_check(NAME, ok_model.get_group_count() == 1, "组数应为 1。")
		_check(NAME, ok_model.get_target_at_cell(Vector2i(1, 1)) == a, "按格应查得目标 a。")
		_check(NAME, ok_model.get_group_of_target(&"a") == group_one, "a 所属组应读回。")
		_check(NAME, ok_model.get_group_of_target(&"c") == group_one, "c 所属组应读回。")
		_check(NAME, ok_model.get_target_by_id(&"ghost") == null, "未知 ID 应返回 null。")


## 2. 命中路由：未知格 / null 命中零副作用；Base Success 与 FormCondition 目标按形态分流。
func _test_02_apply_hit_routing() -> void:
	const NAME: String = "02_命中路由"
	var base: _ObjectiveTarget = _base_target(&"base", Vector2i(1, 1), true)
	var ray_only: _ObjectiveTarget = _ray_only_target(&"rayt", Vector2i(2, 2), true)
	var model: _ObjectiveModel = _ObjectiveModel.create([base, ray_only], [])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	_check(NAME, not model.apply_hit(_ray_hit(Vector2i(9, 9)), 0.0), "未知格应返回 false。")
	_check(NAME, not model.apply_hit(null, 0.0), "null 命中应返回 false。")
	_check(NAME, model.apply_hit(_particle_hit(Vector2i(1, 1)), 1.0), "Base Success 目标应接受 PARTICLE 命中。")
	_check(NAME, base.has_success(), "Base Success 目标应登记成功。")
	_check(NAME, not model.apply_hit(_particle_hit(Vector2i(2, 2)), 2.0), "RAY 形态目标应拒绝 PARTICLE 命中。")
	_check(NAME, not ray_only.has_success(), "拒绝命中不应登记成功。")
	_check(NAME, model.apply_hit(_ray_hit(Vector2i(2, 2)), 3.0), "RAY 形态目标应接受 RAY 命中。")
	_check(NAME, ray_only.get_last_success_at() == 3.0, "成功时间应读回 3.0。")


## 3. 顺序组条件错误命中：期望成员条件错误只算 Invalid Attempt，不回滚、不推进（经模型链路验证）。
func _test_03_invalid_attempt_in_sequence() -> void:
	const NAME: String = "03_顺序组InvalidAttempt"
	var ray_only: _ObjectiveTarget = _ray_only_target(&"seq1", Vector2i(1, 1), true)
	var ray_second: _ObjectiveTarget = _ray_only_target(&"seq2", Vector2i(2, 2), true)
	var group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"seq1", &"seq2"], true, 10.0)
	var model: _ObjectiveModel = _ObjectiveModel.create([ray_only, ray_second], [group])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	_check(NAME, model.apply_hit(_ray_hit(Vector2i(1, 1)), 0.0), "seq1 的 RAY 命中应通过。")
	_check(NAME, group.get_expected_member_id(0.5) == &"seq2", "期望应推进到 seq2。")
	_check(NAME, not model.apply_hit(_particle_hit(Vector2i(2, 2)), 1.0), "seq2 的 PARTICLE 命中应不通过 RAY 条件。")
	_check(NAME, group.get_expected_member_id(1.5) == &"seq2", "期望成员条件错误 Hit 不应改变期望。")
	_check(NAME, group.get_completed_steps(1.5) == 1, "期望成员条件错误 Hit 不应回滚。")
	_check(NAME, not model.is_complete(1.5), "Invalid Attempt 后不应完成。")
	_check(NAME, model.apply_hit(_ray_hit(Vector2i(2, 2)), 2.0), "seq2 的 RAY 命中应通过。")
	_check(NAME, model.is_complete(2.0), "序列完成后模型应完成。")


## 4. 统一完成判定：全部 Required 完成才完成；Optional 不阻挡；无 Required 不误判完成。
func _test_04_unified_completion_required_only() -> void:
	const NAME: String = "04_统一完成判定"
	var required_independent: _ObjectiveTarget = _base_target(&"req_i", Vector2i(1, 1), true)
	var optional_independent: _ObjectiveTarget = _base_target(&"opt_i", Vector2i(2, 2), false)
	var member_a: _ObjectiveTarget = _base_target(&"ga", Vector2i(3, 3), true)
	var member_b: _ObjectiveTarget = _base_target(&"gb", Vector2i(4, 4), true)
	var required_group: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"ga", &"gb"], true, 10.0)
	var model: _ObjectiveModel = _ObjectiveModel.create([required_independent, optional_independent, member_a, member_b], [required_group])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	_check(NAME, not model.is_complete(0.0), "初始不应完成。")
	model.apply_hit(_particle_hit(Vector2i(2, 2)), 1.0)
	_check(NAME, not model.is_complete(1.0), "仅 Optional 完成不应完成关卡。")
	model.apply_hit(_particle_hit(Vector2i(1, 1)), 2.0)
	_check(NAME, not model.is_complete(2.0), "Required 独立完成但组未完成不应完成。")
	model.apply_hit(_particle_hit(Vector2i(3, 3)), 3.0)
	_check(NAME, not model.is_complete(3.0), "序列组半程不应完成。")
	model.apply_hit(_particle_hit(Vector2i(4, 4)), 4.0)
	_check(NAME, model.is_complete(4.0), "全部 Required 完成应完成。")
	# 无任何 Required 的模型不应误判完成（空 has_required）。
	var all_optional: _ObjectiveModel = _ObjectiveModel.create([optional_independent], [])
	_check(NAME, all_optional != null, "全 Optional 模型应构造成功。")
	if all_optional != null:
		_check(NAME, not all_optional.is_complete(0.0), "无 Required 不应误判完成。")
	# 空模型不误判完成。
	var empty_model: _ObjectiveModel = _ObjectiveModel.create([], [])
	_check(NAME, empty_model != null, "空模型应构造成功。")
	if empty_model != null:
		_check(NAME, not empty_model.is_complete(0.0), "空模型不应误判完成。")


## 5. 进度快照 detached：修改快照不影响模型真值；Sequence/Simultaneous 专属字段齐备。
func _test_05_progress_snapshot_detached() -> void:
	const NAME: String = "05_进度快照detached"
	var member_a: _ObjectiveTarget = _base_target(&"sa", Vector2i(1, 1), true)
	var member_b: _ObjectiveTarget = _base_target(&"sb", Vector2i(2, 2), true)
	var sequence: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"sa", &"sb"], true, 10.0)
	var sim_x: _ObjectiveTarget = _base_target(&"sx", Vector2i(3, 3), true)
	var sim_y: _ObjectiveTarget = _base_target(&"sy", Vector2i(4, 4), true)
	var simultaneous: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SIMULTANEOUS, [&"sx", &"sy"], true, 10.0)
	var model: _ObjectiveModel = _ObjectiveModel.create([member_a, member_b, sim_x, sim_y], [sequence, simultaneous])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	model.apply_hit(_particle_hit(Vector2i(1, 1)), 1.0)
	model.apply_hit(_particle_hit(Vector2i(3, 3)), 1.5)
	model.apply_hit(_particle_hit(Vector2i(4, 4)), 2.0)
	var snapshot: Dictionary = model.get_progress_snapshot(2.5)
	var targets: Array = snapshot["targets"]
	var groups: Array = snapshot["groups"]
	_check(NAME, targets.size() == 4, "快照目标数应为 4。")
	_check(NAME, groups.size() == 2, "快照组数应为 2。")
	# detached：篡改快照不改真值。
	var first: Dictionary = targets[0]
	first["has_success"] = false
	var again: Dictionary = model.get_progress_snapshot(2.5)
	_check(NAME, (again["targets"] as Array)[0]["has_success"] == true, "修改快照不应影响模型真值。")
	for group_variant: Variant in groups:
		var entry: Dictionary = group_variant
		if entry["type"] == _ObjectiveGroup.GroupType.SEQUENCE:
			_check(NAME, entry["expected_member_id"] == &"sb", "序列快照期望成员应为 sb。")
			_check(NAME, entry["completed_steps"] == 1, "序列快照已完成步数应为 1。")
			_check(NAME, not entry["locked"], "序列快照不应锁定。")
		else:
			_check(NAME, entry["complete"], "同时组快照应完成。")
			var last_success: Dictionary = entry["member_last_success"]
			_check(NAME, last_success[&"sx"] == 1.5, "同时组快照 sx 时间应为 1.5。")
			_check(NAME, last_success[&"sy"] == 2.0, "同时组快照 sy 时间应为 2.0。")


## 6. 未绑定模型回退：apply_hit 走水晶原型路径（Ray/Particle 命中事实均可点亮）。
func _test_06_controller_fallback_crystal() -> void:
	const NAME: String = "06_未绑定模型水晶回退"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var crystal: BasicCrystal = _make_crystal(&"c_fallback", Vector2i(3, 1))
	registry.register_crystal(&"c_fallback", Vector2i(3, 1), crystal)
	var controller: _ObjectiveController = _ObjectiveController.new(registry)
	_check(NAME, not controller.has_objective_model(), "初始应未绑定模型。")
	_check(NAME, controller.apply_hit(_ray_hit(Vector2i(3, 1))), "RAY 命中事实回退应激活水晶。")
	_check(NAME, crystal.is_activated, "RAY 命中后水晶应点亮。")
	_check(NAME, controller.is_completed(), "单水晶激活后原型路径应完成。")
	crystal.reset_runtime()
	_check(NAME, controller.apply_hit(_particle_hit(Vector2i(3, 1))), "PARTICLE 命中事实回退应激活水晶。")
	_check(NAME, crystal.is_activated, "PARTICLE 命中后水晶应点亮。")
	_check(NAME, not controller.apply_hit(_ray_hit(Vector2i(9, 9))), "未知格回退应返回 false。")


## 7. 绑定模型后覆盖：is_completed 走统一判定（水晶全亮但模型 Required 未满足仍不完成）。
func _test_07_controller_model_overrides() -> void:
	const NAME: String = "07_绑定模型统一判定"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var crystal: BasicCrystal = _make_crystal(&"c_over", Vector2i(3, 1))
	registry.register_crystal(&"c_over", Vector2i(3, 1), crystal)
	var controller: _ObjectiveController = _ObjectiveController.new(registry)
	var required_target: _ObjectiveTarget = _base_target(&"req", Vector2i(5, 5), true)
	var model: _ObjectiveModel = _ObjectiveModel.create([required_target], [])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	controller.set_objective_model(model)
	_check(NAME, controller.has_objective_model(), "绑定后应报告已绑定。")
	crystal.activate()
	_check(NAME, crystal.is_activated, "水晶应已点亮。")
	_check(NAME, not controller.is_completed(), "模型 Required 未满足时水晶全亮也不应完成。")
	_check(NAME, controller.apply_hit(_ray_hit(Vector2i(5, 5))), "模型目标命中应通过。")
	_check(NAME, controller.is_completed(), "Required 完成后应完成。")


## 8. 时间 seam：注入可控时间源驱动序列组超时回滚（经控制器 is_completed 可观测）。
func _test_08_controller_time_seam_sequence() -> void:
	const NAME: String = "08_时间seam超时"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	_now = 0.0
	var controller: _ObjectiveController = _ObjectiveController.new(registry, func() -> float: return _now)
	var member_a: _ObjectiveTarget = _base_target(&"ta", Vector2i(1, 1), true)
	var member_b: _ObjectiveTarget = _base_target(&"tb", Vector2i(2, 2), true)
	var sequence: _ObjectiveGroup = _ObjectiveGroup.create(_ObjectiveGroup.GroupType.SEQUENCE, [&"ta", &"tb"], true, 10.0)
	var model: _ObjectiveModel = _ObjectiveModel.create([member_a, member_b], [sequence])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	controller.set_objective_model(model)
	_now = 0.0
	_check(NAME, controller.apply_hit(_ray_hit(Vector2i(1, 1))), "ta 命中应通过。")
	_now = 1.0
	_check(NAME, not controller.is_completed(), "序列半程不应完成。")
	_now = 11.5
	_check(NAME, not controller.is_completed(), "tb 窗口超时后仍不应完成。")
	_check(NAME, sequence.get_expected_member_id(_now) == &"ta", "超时应回滚一个成功步骤，期望退回 ta。")
	_now = 12.0
	_check(NAME, controller.apply_hit(_ray_hit(Vector2i(1, 1))), "ta 重新命中应通过。")
	_now = 13.0
	_check(NAME, controller.apply_hit(_ray_hit(Vector2i(2, 2))), "tb 命中应通过。")
	_check(NAME, controller.is_completed(), "序列完成后应完成。")


## 9. reset_runtime 双路径：水晶归未点亮且模型状态归零。
func _test_09_controller_reset_both() -> void:
	const NAME: String = "09_重置双路径"
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var crystal: BasicCrystal = _make_crystal(&"c_reset", Vector2i(3, 1))
	registry.register_crystal(&"c_reset", Vector2i(3, 1), crystal)
	var controller: _ObjectiveController = _ObjectiveController.new(registry)
	var required_target: _ObjectiveTarget = _base_target(&"rr", Vector2i(5, 5), true)
	var model: _ObjectiveModel = _ObjectiveModel.create([required_target], [])
	_check(NAME, model != null, "模型应构造成功。")
	if model == null:
		return
	controller.set_objective_model(model)
	controller.try_activate_crystal_at(Vector2i(3, 1))
	controller.apply_hit(_ray_hit(Vector2i(5, 5)))
	_check(NAME, crystal.is_activated, "水晶应已点亮（原型路径激活）。")
	_check(NAME, controller.is_completed(), "重置前应完成。")
	controller.reset_runtime()
	_check(NAME, not crystal.is_activated, "重置后水晶应未点亮。")
	_check(NAME, not required_target.has_success(), "重置后模型目标应无成功记录。")
	_check(NAME, not controller.is_completed(), "重置后不应完成。")


## 构造可激活水晶（手动 _ready，同 objective_controller_test 约定）。
func _make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = cell
	crystal.crystal_id = crystal_id
	var view: ObjectVisualView = _VisualViewScene.instantiate()
	view.name = "VisualView"
	view.visual_profile = _CrystalProfile
	view.initial_state_id = &"unlit"
	crystal.add_child(view)
	view._ready()
	crystal._ready()
	_crystals.append(crystal)
	return crystal


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 释放本轮创建的水晶实例（连带 VisualView 子节点）。
func _cleanup() -> void:
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			for child: Node in crystal.get_children():
				child.free()
			crystal.free()
	_crystals.clear()


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("objective_controller_model_test： %d/%d 组通过，%d/%d 断言通过。" % [group_count - _failures.size(), group_count, passed_checks, _checks])
	if not _failures.is_empty():
		for failure: String in _failures:
			print("  失败：%s" % [failure])
