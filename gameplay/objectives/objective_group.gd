class_name ObjectiveGroup
extends RefCounted

## 跨目标组运行时（冻结 Guide A §15 Sequence / §16 Simultaneous，AF-04 / P0-6）。
## 只实现冻结语义：Independent 不是组（目标不入组即独立）；组不嵌套（成员只能是目标 ID）；
##   Composite Group 至少 2 成员；Required/Optional 属于组整体，不属于成员。
## Sequence（§15）：顺序 = 成员 ID 列表顺序（不使用人工 sequence number）。
##   - 当前期望成员被"条件错误 Hit"：只算 Invalid Attempt，不回滚，计时继续；
##   - 已完成旧成员被重 Hit：Sequence Progress 忽略（目标自身仍可展示反馈）；
##   - 错误触发未来成员（未来成员命中通过其自身条件）或当前步超时：回滚一个成功步骤，
##     期望目标退回上一步并重新开始完整 Window；
##   - 第一个目标没有等待计时；每成功一步为下一步重新开始完整 Window；
##   - 一旦完成锁定 COMPLETE 直到 Reset。
## Simultaneous（§16）：滑动完成窗口。每成员记录最近一次正确完成时间；旧成员超时只让该成员失效，
##   其它成员有效记录保留；全部成员最近完成时间落在同一 Window 内即完成；
##   正确重复触发刷新该成员时间；条件错误 Hit 不清已有记录、不缩短剩余状态。
## 时间模型：时间戳一律由调用方注入（时间 seam），本类不读引擎时钟、不用计时器节点；
##   超时判定在读取（is_complete / get_expected_member_id）时惰性求值，等价于超时事件回滚。
## 纯数据模型：不持 Node / 目标对象引用（只持成员 ID），不负责点亮视觉、不完成关卡。


## 组类型（冻结：仅 Simultaneous / Sequence 两种；Independent 无组）。
enum GroupType {
	SIMULTANEOUS = 0,
	SEQUENCE = 1,
}

## 成员命中处理结果（供调试 / GUI 反馈消费）。
enum HitOutcome {
	## 顺序组：期望成员命中通过，推进一步。
	ADVANCED = 0,
	## 顺序组：错误触发未来成员或超时回滚后的再次处理；本次触发回滚一个成功步骤。
	ROLLED_BACK = 1,
	## 顺序组：期望成员"条件错误 Hit"，只算 Invalid Attempt，状态与计时不变。
	INVALID_ATTEMPT = 2,
	## 进度无关命中（旧成员重 Hit / 失败命中落非期望成员 / Simultaneous 失败命中），不改变组状态语义。
	IGNORED = 3,
	## Simultaneous：成员正确命中，刷新该成员最近完成时间。
	RECORDED = 4,
}


## 组类型。
var _group_type: int
## 成员目标稳定 ID（有序；Sequence 顺序即此列表顺序）。
var _member_ids: Array[StringName]
## 组整体是否 Required（Required/Optional 属于组，不属于成员）。
var _required: bool
## 完成窗口秒数（Sequence：相邻步完成 Window；Simultaneous：滑动完成窗口）。
var _window_seconds: float
## Sequence：已完成步数（期望成员 = member_ids[_completed_steps]）。
var _completed_steps: int
## Sequence：当前期望步的 Window 起始时间（首步 NO_WINDOW 表示无等待计时）。
var _window_started_at: float
## Sequence：完成锁定（直到 Reset）。
var _locked_complete: bool
## Simultaneous：成员 ID → 最近一次正确完成时间（无记录不入字典）。
var _last_success_by_member: Dictionary
## 成员索引（ID → 列表位置，加速归属判定）。
var _member_index: Dictionary


## 首步无等待计时哨兵。
const NO_WINDOW: float = -1.0


## 构造组；成员 <2、重复成员、非法窗口返回 null 并 push_error（Editor Error / Validator Blocking 的运行时同构）。
static func create(group_type: int, member_ids: Array, required: bool, window_seconds: float) -> ObjectiveGroup:
	if group_type != GroupType.SIMULTANEOUS and group_type != GroupType.SEQUENCE:
		push_error("ObjectiveGroup：非法组类型 %d，拒绝构造。" % [group_type])
		return null
	if member_ids.size() < 2:
		push_error("ObjectiveGroup：Composite Group 至少 2 个成员，拒绝构造。" % [])
		return null
	var ordered: Array[StringName] = []
	var index: Dictionary = {}
	for member_variant: Variant in member_ids:
		var member_id: StringName = member_variant as StringName
		if member_id == null or member_id == &"":
			push_error("ObjectiveGroup：成员 ID 非法，拒绝构造。" % [])
			return null
		if index.has(member_id):
			push_error("ObjectiveGroup：成员 %s 重复，拒绝构造。" % [member_id])
			return null
		index[member_id] = ordered.size()
		ordered.append(member_id)
	if window_seconds <= 0.0:
		push_error("ObjectiveGroup：完成 Window 必须 > 0，拒绝构造。" % [])
		return null
	var group: ObjectiveGroup = ObjectiveGroup.new()
	group._group_type = group_type
	group._member_ids = ordered
	group._member_index = index
	group._required = required
	group._window_seconds = window_seconds
	group._completed_steps = 0
	group._window_started_at = NO_WINDOW
	group._locked_complete = false
	group._last_success_by_member = {}
	return group


## 组类型（只读）。
func get_group_type() -> int:
	return _group_type


## 成员目标稳定 ID（detached 副本，有序，只读）。
func get_member_ids() -> Array[StringName]:
	return _member_ids.duplicate()


## 组是否 Required（只读）。
func is_required() -> bool:
	return _required


## 成员窗口秒数（只读）。
func get_window_seconds() -> float:
	return _window_seconds


## 成员命中处理：passed = 该成员自身条件是否通过（由 ObjectiveModel 先求值）。
## [br]返回 HitOutcome；不读时钟（now 由调用方注入），命中不触发惰性超时回滚（读取时统一判定）。
func on_member_hit(member_id: StringName, passed: bool, now: float) -> int:
	if not _member_index.has(member_id):
		return HitOutcome.IGNORED
	if _group_type == GroupType.SIMULTANEOUS:
		if not passed:
			## 条件错误 Hit：不清已有记录、不缩短剩余状态。
			return HitOutcome.IGNORED
		_last_success_by_member[member_id] = now
		return HitOutcome.RECORDED
	return _on_sequence_member_hit(member_id, passed, now)


## Sequence 命中分支（§15 规则逐条对应，见类头注释）。
func _on_sequence_member_hit(member_id: StringName, passed: bool, now: float) -> int:
	if _locked_complete:
		return HitOutcome.IGNORED
	var member_position: int = int(_member_index[member_id])
	var expected_position: int = _completed_steps
	if not passed:
		if member_position == expected_position:
			## 当前期望目标"条件错误 Hit"：只算 Invalid Attempt，不回滚，当前计时继续。
			return HitOutcome.INVALID_ATTEMPT
		## 非期望成员的失败命中：不构成"触发"，进度忽略。
		return HitOutcome.IGNORED
	if member_position < expected_position:
		## 重新 Hit 已完成的旧目标：Sequence Progress 忽略（目标自身反馈由目标侧负责）。
		return HitOutcome.IGNORED
	if member_position > expected_position:
		## 错误地触发未来成员：回滚一个成功步骤，期望退回并重新开始完整 Window。
		_rollback_one_step(now)
		return HitOutcome.ROLLED_BACK
	## 期望成员正确命中：推进一步；为下一步重新开始完整 Window（末步无下一步）。
	_completed_steps += 1
	if _completed_steps >= _member_ids.size():
		_locked_complete = true
	else:
		_window_started_at = now
	return HitOutcome.ADVANCED


## 回滚一个成功步骤：移除最近一次成功，期望退回该成员并重新开始完整 Window。
## [br]退回首步时无等待计时（第一个目标没有等待计时）；无成功步骤可回滚时无操作（不惩罚，等待继续）。
func _rollback_one_step(now: float) -> void:
	if _completed_steps <= 0:
		return
	_completed_steps -= 1
	_window_started_at = NO_WINDOW if _completed_steps == 0 else now


## 组当前是否完成（惰性超时求值：Sequence 当前步超时先回滚一个成功步骤再判定）。
func is_complete(now: float) -> bool:
	if _group_type == GroupType.SEQUENCE:
		_apply_sequence_timeout_rollback(now)
		return _locked_complete
	## Simultaneous：全部成员最近完成时间均落在以 now 为终点的滑动 Window 内。
	for member_id: StringName in _member_ids:
		if not _last_success_by_member.has(member_id):
			return false
		if now - float(_last_success_by_member[member_id]) > _window_seconds:
			## 旧成员超时：只让该过期成员失效（本次读取判定不通过），其它成员有效记录保留。
			return false
	return true


## Sequence 惰性超时：当前期望步（非首步）窗口耗尽则回滚一个成功步骤；
## [br]每次读取至多回滚一步（对齐冻结语义"每事件回滚一个成功步骤"），回滚后新窗口自本次读取时间重新开始。
func _apply_sequence_timeout_rollback(now: float) -> void:
	if _locked_complete or _completed_steps <= 0:
		return
	if _window_started_at == NO_WINDOW:
		return
	if now - _window_started_at > _window_seconds:
		_rollback_one_step(now)


## Sequence 当前期望成员 ID（惰性超时求值后；已锁定返回最后成员）。
func get_expected_member_id(now: float) -> StringName:
	if _group_type != GroupType.SEQUENCE:
		return &""
	_apply_sequence_timeout_rollback(now)
	if _completed_steps >= _member_ids.size():
		return _member_ids[_member_ids.size() - 1]
	return _member_ids[_completed_steps]


## Sequence 已完成步数（惰性超时求值后，只读）。
func get_completed_steps(now: float) -> int:
	if _group_type != GroupType.SEQUENCE:
		return 0
	_apply_sequence_timeout_rollback(now)
	return _completed_steps


## Simultaneous 成员最近一次正确完成时间（无记录返回 ObjectiveTarget.NO_SUCCESS，只读）。
func get_member_last_success(member_id: StringName) -> float:
	if _group_type != GroupType.SIMULTANEOUS or not _last_success_by_member.has(member_id):
		return -1.0
	return float(_last_success_by_member[member_id])


## Sequence 是否完成锁定（只读）。
func is_locked_complete() -> bool:
	return _locked_complete


## 重置组运行状态：步数 / 窗口 / 成员时间 / 锁定全部归零（身份与成员不变）；重复调用安全。
func reset_runtime() -> void:
	_completed_steps = 0
	_window_started_at = NO_WINDOW
	_locked_complete = false
	_last_success_by_member = {}
