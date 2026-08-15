extends SceneTree

## LevelRuntimeController.request_begin_runtime 正式 Start Run 入口单元测试（D7-3 Start Run 正式入口与生命周期集成）。
##
## 覆盖协作文档 §10「自动测试最低合同 · Runtime Start Run」10 项：
##   01 valid + SETUP → READY_TO_FIRE；
##   02 结构化 Validation Result 可获得（LevelValidationResult 实例 + 公开 API）；
##   03 valid 不自动 fire（仍 READY_TO_FIRE，未进 PULSE_ACTIVE）；
##   04 generation 不变（pulse_generation == 0）；
##   05 Ray 不执行/无正式光段（spy 查询计数 == 0 + 光段数 == 0）；
##   06 Crystal/Objective 不变化（is_completed false / activated 0）；
##   07 invalid → SETUP（空白模板 terrain_empty ERROR）；
##   08 invalid 无玩法副作用（generation/光段/库存/占用/水晶/状态全不变）；
##   09 WARNING-only → READY（清空 LegalArea → legal_area_empty WARNING、0 ERROR、is_valid true）；
##   10 非 SETUP Start Run 拒绝（表驱动：READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 四态分别 request_begin_runtime 返回 null、状态不变、无额外 state_changed、不 fire）。
##
## 真实控制器经 fixtures/runtime_controller_fixture.gd 装配；level_root 用真实场景
##   （编辑示例 = valid 正例、空白模板 = invalid 负例），不白盒访问私有 _run_state_controller。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；preload 引用避开全局 class_name 缓存坑。

const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")

const _EDITING_EXAMPLE_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
const _BLANK_TEMPLATE_PATH: String = "res://levels/templates/level_template.tscn"

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 装配夹具（持有 env RefCounted，避免 Callable 单引用回收致 null::method）。
var _fixture: _Fixture = null


## SceneTree 初始化入口：等待一帧后运行全部测试，统一报告、清理并退出。
func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready/get_tree 可用。
	await process_frame
	_fixture = _Fixture.new(self)
	_run_all_tests()
	_report()
	# 清理前推进若干帧，让挂起的异步脉冲结束协程恢复完成，避免 free controller 后协程再访问 null 实例。
	await _fixture.wait_settled(4)
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	_test_01_valid_setup_to_ready()
	_test_02_structured_result_obtainable()
	_test_03_valid_no_auto_fire()
	_test_04_generation_unchanged()
	_test_05_ray_not_executed()
	_test_06_crystal_objective_unchanged()
	_test_07_invalid_keeps_setup()
	_test_08_invalid_no_side_effects()
	_test_09_warning_only_to_ready()
	_test_10_non_setup_repeat_rejected()


# ===== 测试用例 =====

## 1. valid + SETUP → READY_TO_FIRE：编辑示例经 Gate valid，request_begin_runtime 后状态切换到 READY_TO_FIRE。
func _test_01_valid_setup_to_ready() -> void:
	const NAME: String = "01_valid+SETUP→READY"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	var result: _LevelValidationResult = env.controller.request_begin_runtime(root)
	_check(NAME, result != null, "SETUP 下应返回结构化结果，不应返回 null。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE,
		"valid 后应进 READY_TO_FIRE，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	root.free()


## 2. 结构化 Result 可获得：返回值为 LevelValidationResult 实例，可读 is_valid/get_error_count/get_issues。
func _test_02_structured_result_obtainable() -> void:
	const NAME: String = "02_结构化Result可获得"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	var result: _LevelValidationResult = env.controller.request_begin_runtime(root)
	if _check(NAME, result != null, "应返回非 null 结果。"):
		_check(NAME, is_instance_of(result, _LevelValidationResult), "应返回 LevelValidationResult 实例。")
		_check(NAME, result.is_valid() == true, "编辑示例期望 is_valid=true。")
		_check(NAME, result.get_error_count() == 0, "编辑示例期望 0 ERROR，实际 %d。" % [result.get_error_count()])
		_check(NAME, result.get_issues() != null, "get_issues 应返回数组（可为空）。")
	root.free()


## 3. valid 不自动 fire：valid 后仅 READY_TO_FIRE，未进 PULSE_ACTIVE（按钮本身不发射）。
func _test_03_valid_no_auto_fire() -> void:
	const NAME: String = "03_valid不自动fire"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	env.controller.request_begin_runtime(root)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE,
		"valid 后应停留在 READY_TO_FIRE，未自动进入 PULSE_ACTIVE，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, not env.rsc.is_current_pulse_active(), "不应进入脉冲活动。")
	root.free()


## 4. M4-E1 generation 新语义：valid Start Run（SETUP→READY）进入新 Runtime epoch，推进 generation 0→1；同 epoch 后续 fire 不再递增。
func _test_04_generation_unchanged() -> void:
	const NAME: String = "04_generation_新语义"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	_check(NAME, env.controller.get_runtime_generation() == 0, "前置 generation 期望 0。")
	env.controller.request_begin_runtime(root)
	_check(NAME, env.controller.get_runtime_generation() == 1, "M4-E1：valid Start Run 进入新 epoch 推进 generation 到 1，实际 %d。" % [env.controller.get_runtime_generation()])
	root.free()


## 5. Ray 不执行/无正式光段：observe_ray_queries=true 注入 spy，valid Start Run 后查询计数 == 0 + 光段数 == 0。
func _test_05_ray_not_executed() -> void:
	const NAME: String = "05_Ray不执行"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3), 1, true)
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	env.controller.request_begin_runtime(root)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0,
		"valid Start Run 后正式光段数期望 0，实际 %d。" % [env.light_visual_controller.get_segment_count()])
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.total_query_calls() == 0,
			"Ray 执行查询次数期望 0（Start Run 不触发 Ray），实际 %d。" % [env.light_world_query_spy.total_query_calls()])
	root.free()


## 6. Crystal/Objective 不变化：valid Start Run 后 ObjectiveController 仍 is_completed=false、activated=0。
func _test_06_crystal_objective_unchanged() -> void:
	const NAME: String = "06_Crystal/Objective不变"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	env.controller.request_begin_runtime(root)
	if _check(NAME, env.objective_controller.get_required_count() == 1, "前置应有 1 颗水晶登记。"):
		_check(NAME, env.objective_controller.get_activated_count() == 0, "Start Run 后已激活水晶期望 0。")
		_check(NAME, env.objective_controller.is_completed() == false, "Start Run 后完成事实期望 false。")
	root.free()


## 7. invalid → SETUP：空白模板 terrain_empty ERROR，request_begin_runtime 后仍 SETUP 且结果 is_valid=false。
func _test_07_invalid_keeps_setup() -> void:
	const NAME: String = "07_invalid→SETUP"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_BLANK_TEMPLATE_PATH, NAME)
	if root == null:
		return
	var result: _LevelValidationResult = env.controller.request_begin_runtime(root)
	_check(NAME, result != null, "SETUP 下 invalid 也应返回结构化结果供 UI 反馈。")
	if result != null:
		_check(NAME, result.has_errors() == true, "空白模板期望 has_errors=true。")
		_check(NAME, result.is_valid() == false, "空白模板期望 is_valid=false。")
		_check(NAME, result.get_error_count() >= 1, "空白模板期望至少 1 个 ERROR，实际 %d。" % [result.get_error_count()])
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP,
		"invalid 后应保持 SETUP，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	root.free()


## 8. invalid 无玩法副作用：generation/光段/库存/占用/水晶/状态在 invalid Start Run 前后全不变。
func _test_08_invalid_no_side_effects() -> void:
	const NAME: String = "08_invalid无玩法副作用"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3), 1, true)
	var root: Node2D = _load_scene(_BLANK_TEMPLATE_PATH, NAME)
	if root == null:
		return
	var inv_before: int = env.inventory_controller.get_remaining()
	var occ_entries_before: int = env.occupancy.mechanism_at.size()
	var occ_consistent_before: bool = env.occupancy.is_consistent()
	env.controller.request_begin_runtime(root)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "状态应保持 SETUP。")
	_check(NAME, env.controller.get_runtime_generation() == 0, "generation 应保持 0。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "正式光段数应保持 0。")
	if env.light_world_query_spy != null:
		_check(NAME, env.light_world_query_spy.total_query_calls() == 0, "Ray 查询次数应保持 0。")
	_check(NAME, env.inventory_controller.get_remaining() == inv_before, "库存 remaining 应不变。")
	_check(NAME, env.occupancy.mechanism_at.size() == occ_entries_before, "占用表条目数应不变。")
	_check(NAME, env.occupancy.is_consistent() == occ_consistent_before, "占用表一致性应不变。")
	_check(NAME, env.objective_controller.is_completed() == false, "Objective 完成事实应保持 false。")
	_check(NAME, env.objective_controller.get_activated_count() == 0, "水晶激活数应保持 0。")
	root.free()


## 9. WARNING-only → READY：清空编辑示例 LegalAreaLayer → legal_area_empty WARNING、0 ERROR、is_valid=true → READY_TO_FIRE。
##    证明 WARNING 数量不阻断（严格遵循既有 LevelValidationResult.is_valid 语义，不建第二套严重度）。
func _test_09_warning_only_to_ready() -> void:
	const NAME: String = "09_WARNING-only→READY"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3))
	var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
	if root == null:
		return
	# 清空 LegalAreaLayer（不写回资源）→ 仅 legal_area_empty WARNING、0 ERROR。
	var legal: Node = root.get_node_or_null(NodePath("LegalAreaLayer"))
	if legal != null and legal is TileMapLayer:
		(legal as TileMapLayer).clear()
	var result: _LevelValidationResult = env.controller.request_begin_runtime(root)
	_check(NAME, result != null and result.get_error_count() == 0, "清空 Legal 后期望 0 ERROR。")
	_check(NAME, result != null and result.get_warning_count() >= 1, "清空 Legal 后期望 WARNING >=1。")
	_check(NAME, result != null and result.is_valid() == true, "仅 WARNING 无 ERROR 时 is_valid 应 true。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.READY_TO_FIRE,
		"WARNING-only 应进入 READY_TO_FIRE，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	root.free()


## 10. 非 SETUP Start Run 拒绝（表驱动，D7-3 精度补齐）：READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED 四态分别经公开
##    request_begin_runtime() 请求，确认请求被拒绝（返回 null）、状态不变、不产生额外 state_changed、不 fire（generation/光段/Ray 查询不变）。
##    各前置状态经公开 RunStateController 入口（begin_runtime/begin_pulse/finish_pulse）准备，不白盒私有字段；每态独立 env 与场景根。
func _test_10_non_setup_repeat_rejected() -> void:
	const NAME: String = "10_非SETUP_StartRun拒绝"
	var labels: PackedStringArray = PackedStringArray(["READY_TO_FIRE", "PULSE_ACTIVE", "MOVE_WINDOW", "COMPLETED"])
	for label: String in labels:
		var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(5, 3), 1, true)
		var root: Node2D = _load_scene(_EDITING_EXAMPLE_PATH, NAME)
		if root == null:
			continue
		var sink: _SignalSink = _SignalSink.new()
		env.rsc.state_changed.connect(Callable(sink, "on_changed"))
		_prepare_non_setup_state(env, label)
		var state_before: int = env.rsc.get_current_state()
		_check(NAME, state_before != _RuntimeInteractionTypes.RunState.SETUP,
			"[%s] 前置应已离开 SETUP，实际 %s。" % [label, _state_label(state_before)])
		var count_before: int = sink.count()
		var gen_before: int = env.controller.get_runtime_generation()
		# 正式 Start Run 入口在非 SETUP 下必须被拒绝。
		var result: _LevelValidationResult = env.controller.request_begin_runtime(root)
		_check(NAME, result == null, "[%s] 非 SETUP request_begin_runtime 应返回 null，实际 %s。" % [label, str(result)])
		_check(NAME, env.rsc.get_current_state() == state_before,
			"[%s] 状态应不变，实际 %s。" % [label, _state_label(env.rsc.get_current_state())])
		_check(NAME, sink.count() == count_before,
			"[%s] 不应产生额外 state_changed，实际 %d。" % [label, sink.count()])
		_check(NAME, env.controller.get_runtime_generation() == gen_before,
			"[%s] 不应 fire（generation 不变），实际 %d。" % [label, env.controller.get_runtime_generation()])
		_check(NAME, env.light_visual_controller.get_segment_count() == 0,
			"[%s] 不应产生光段，实际 %d。" % [label, env.light_visual_controller.get_segment_count()])
		if env.light_world_query_spy != null:
			_check(NAME, env.light_world_query_spy.total_query_calls() == 0,
				"[%s] Ray 执行查询应保持 0，实际 %d。" % [label, env.light_world_query_spy.total_query_calls()])
		root.free()


## 经公开 RunStateController 入口把 env 准备到指定非 SETUP 状态（仅状态机推进，不发 fire、不启动异步脉冲）。
## READY_TO_FIRE=begin_runtime；PULSE_ACTIVE=+begin_pulse；MOVE_WINDOW=+finish_pulse(false)；COMPLETED=+finish_pulse(true)。
func _prepare_non_setup_state(env: _Fixture._Env, label: String) -> void:
	env.rsc.begin_runtime()
	if label == "READY_TO_FIRE":
		return
	env.rsc.begin_pulse()
	if label == "PULSE_ACTIVE":
		return
	env.rsc.finish_pulse(label == "COMPLETED")


# ===== 辅助 =====

## 真实 load + instantiate（不入树，与 Gate 测试同款）；失败累计并返回 null。
func _load_scene(path: String, group: String) -> Node2D:
	var packed: PackedScene = load(path)
	if packed == null:
		_check(group, false, "无法 load 场景：%s。" % path)
		return null
	var node: Node = packed.instantiate()
	if node == null or not (node is Node2D):
		_check(group, false, "场景根非 Node2D：%s。" % path)
		return null
	return node


## RunState 稳定可读名称（仅用于失败明细）。
func _state_label(state: int) -> String:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return "SETUP"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return "COMPLETED"
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			return "READY_TO_FIRE"
		_:
			return "未知(%d)" % [state]


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeController.request_begin_runtime 正式 Start Run 入口测试摘要（D7-3）====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)


# ===== 信号计数桩 =====

## RunStateController.state_changed 计数桩（RefCounted，由 Callable 与本地变量共同持有，避免单引用回收）。
class _SignalSink:
	var _count: int = 0
	## state_changed(previous_state, new_state) 回调：仅累加计数，不读取参数。
	func on_changed(_previous, _new) -> void:
		_count += 1

	## 已记录的信号次数。
	func count() -> int:
		return _count
