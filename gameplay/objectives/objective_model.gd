class_name ObjectiveModel
extends RefCounted

## 目标运行时模型（AF-04 / P0-6）：ObjectiveTarget 集合 + ObjectiveGroup 集合的统一持有者。
## 职责：构造校验（ID / 格唯一、组成员存在、每目标最多一个跨目标组）、按格路由命中
##   （求值目标条件 → 登记成功 → 通报所属组）、统一完成判定（全部 Required 完成 → COMPLETED，
##   Optional 不阻挡；冻结 Guide A §14.1"全部 Required 完成后立即 COMPLETED"）、进度快照（GUI P0 运行时数据）。
## 不负责：点亮视觉、水晶 Node 状态、关卡五态、发射/传播、计时器节点；时间戳一律由调用方注入（时间 seam）。
## "每个正式可运行关卡至少一个 Required（0 Required = ERROR）"是 Validator 校验域（AF-06 扩展点），
##   本模型不强制（允许空模型表示无目标场景原型）。


const _ObjectiveTarget: GDScript = preload("res://gameplay/objectives/objective_target.gd")
const _ObjectiveGroup: GDScript = preload("res://gameplay/objectives/objective_group.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")


## 有序目标列表。
var _targets: Array
## 目标 ID → 目标对象索引。
var _target_by_id: Dictionary
## 格 → 目标对象索引（命中路由键；一格一目标）。
var _target_by_cell: Dictionary
## 组列表。
var _groups: Array
## 目标 ID → 所属组索引（每目标最多一个跨目标组，Guide A §14）。
var _group_by_member_id: Dictionary


## 构造模型；目标 / 组非法或冲突（重复 ID、重复格、未知成员、一目标多组）返回 null 并 push_error。
static func create(targets: Array, groups: Array) -> ObjectiveModel:
	var model: ObjectiveModel = ObjectiveModel.new()
	for target_variant: Variant in targets:
		var target: _ObjectiveTarget = target_variant as _ObjectiveTarget
		if target == null:
			push_error("ObjectiveModel：含非法目标对象，拒绝构造。" % [])
			return null
		var target_id: StringName = target.get_target_id()
		if model._target_by_id.has(target_id):
			push_error("ObjectiveModel：目标 ID %s 重复，拒绝构造。" % [target_id])
			return null
		if model._target_by_cell.has(target.get_cell()):
			push_error("ObjectiveModel：格 %s 已有目标（一格一目标），拒绝构造。" % [target.get_cell()])
			return null
		model._target_by_id[target_id] = target
		model._target_by_cell[target.get_cell()] = target
		model._targets.append(target)
	for group_variant: Variant in groups:
		var group: _ObjectiveGroup = group_variant as _ObjectiveGroup
		if group == null:
			push_error("ObjectiveModel：含非法组对象，拒绝构造。" % [])
			return null
		for member_id: StringName in group.get_member_ids():
			if not model._target_by_id.has(member_id):
				push_error("ObjectiveModel：组成员 %s 不存在，拒绝构造。" % [member_id])
				return null
			if model._group_by_member_id.has(member_id):
				push_error("ObjectiveModel：目标 %s 已属一个跨目标组（最多一个），拒绝构造。" % [member_id])
				return null
			model._group_by_member_id[member_id] = group
		model._groups.append(group)
	return model


## 目标数（只读）。
func get_target_count() -> int:
	return _targets.size()


## 组数（只读）。
func get_group_count() -> int:
	return _groups.size()


## 按格取目标（无则 null，只读）。
func get_target_at_cell(cell: Vector2i) -> _ObjectiveTarget:
	return _target_by_cell.get(cell)


## 按稳定 ID 取目标（无则 null，只读）。
func get_target_by_id(target_id: StringName) -> _ObjectiveTarget:
	return _target_by_id.get(target_id)


## 目标所属组（独立目标返回 null，只读）。
func get_group_of_target(target_id: StringName) -> _ObjectiveGroup:
	return _group_by_member_id.get(target_id)


## 应用一次命中事实：按格路由 → 求值目标条件 → 通过则登记成功并通报所属组，失败则只通报所属组
##   （顺序组期望成员"条件错误 Hit"只算 Invalid Attempt）。
## [br]返回命中是否通过目标条件；未知格返回 false 且零副作用。
func apply_hit(hit: Variant, now: float) -> bool:
	var hit_context: _ObjectiveHitContext = hit as _ObjectiveHitContext
	if hit_context == null:
		return false
	var target: _ObjectiveTarget = _target_by_cell.get(hit_context.get_cell())
	if target == null:
		return false
	var passed: bool = target.evaluate_hit(hit_context)
	var group: _ObjectiveGroup = _group_by_member_id.get(target.get_target_id())
	if group != null:
		group.on_member_hit(target.get_target_id(), passed, now)
	if passed:
		target.register_success(now)
	return passed


## 统一完成判定：全部 Required（独立目标 + 组）完成 → true；Optional 不阻挡；空模型返回 false（不误判完成）。
func is_complete(now: float) -> bool:
	var has_required: bool = false
	for target_variant: Variant in _targets:
		var target: _ObjectiveTarget = target_variant as _ObjectiveTarget
		if _group_by_member_id.has(target.get_target_id()):
			continue
		if not target.is_required():
			continue
		has_required = true
		if not target.has_success():
			return false
	for group_variant: Variant in _groups:
		var group: _ObjectiveGroup = group_variant as _ObjectiveGroup
		if not group.is_required():
			continue
		has_required = true
		if not group.is_complete(now):
			return false
	return has_required


## 进度快照（GUI P0 运行时数据；detached 深拷贝，调用方修改不影响模型真值）。
## [br]targets: [{id, cell, required, in_group, has_success, last_success_at}]；
## [br]groups: [{type, required, member_ids, complete, locked/expected/completed_steps（Sequence）、
## [br]  member_last_success（Simultaneous）、window_seconds}]。
func get_progress_snapshot(now: float) -> Dictionary:
	var targets: Array = []
	for target_variant: Variant in _targets:
		var target: _ObjectiveTarget = target_variant as _ObjectiveTarget
		targets.append({
			"id": target.get_target_id(),
			"cell": target.get_cell(),
			"required": target.is_required(),
			"in_group": _group_by_member_id.has(target.get_target_id()),
			"has_success": target.has_success(),
			"last_success_at": target.get_last_success_at(),
		})
	var groups: Array = []
	for group_variant: Variant in _groups:
		var group: _ObjectiveGroup = group_variant as _ObjectiveGroup
		var entry: Dictionary = {
			"type": group.get_group_type(),
			"required": group.is_required(),
			"member_ids": group.get_member_ids(),
			"complete": group.is_complete(now),
			"window_seconds": group.get_window_seconds(),
		}
		if group.get_group_type() == _ObjectiveGroup.GroupType.SEQUENCE:
			entry["locked"] = group.is_locked_complete()
			entry["expected_member_id"] = group.get_expected_member_id(now)
			entry["completed_steps"] = group.get_completed_steps(now)
		else:
			var member_last_success: Dictionary = {}
			for member_id: StringName in group.get_member_ids():
				member_last_success[member_id] = group.get_member_last_success(member_id)
			entry["member_last_success"] = member_last_success
		groups.append(entry)
	return {"targets": targets, "groups": groups}


## 重置运行状态：全部目标与组归零（身份与结构不变）；重复调用安全。
func reset_runtime() -> void:
	for target_variant: Variant in _targets:
		(target_variant as _ObjectiveTarget).reset_runtime()
	for group_variant: Variant in _groups:
		(group_variant as _ObjectiveGroup).reset_runtime()
