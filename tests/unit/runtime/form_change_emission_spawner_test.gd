extends SceneTree

## 光形式转换 emission 生成器（FormChangeEmissionSpawner）定向测试（阶段C-01）。
## 覆盖：RAY 路径生成（载荷→dispatch 透传）；generation 过期 / 脉冲非活动 no-op；dispatch 失败不消耗链深度；
##   链深度上限（16 次后拒绝，17 次不再 dispatch）；generation 变更自动归零 + per-fire reset_chain；
##   PARTICLE 路径事务体：解绑→先 spawn 后 finish 顺序、多粒 emission 未结算、普通终止（载荷 -1）直接结算、
##   stale generation 零副作用（不解绑）。registry 使用正式 ActiveEmissionRegistry，LRC 侧依赖以 Recorder Callable 注入。
## headless extends SceneTree，由 Godot --script 运行；全部失败项收集后统一退出（任一失败 quit(1)）。

const _Spawner: GDScript = preload("res://gameplay/runtime/form_change_emission_spawner.gd")
const _Registry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_ray_path_dispatches_payload()
	_test_02_stale_generation_noop()
	_test_03_pulse_inactive_noop()
	_test_04_dispatch_failure_does_not_consume_depth()
	_test_05_chain_depth_cap_and_reset()
	_test_06_particle_path_spawn_before_finish()
	_test_07_particle_path_plain_terminate_and_stale()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## LRC 侧依赖记录器：dispatch/get_generation/is_pulse_active/finish_emission 全部以 Callable 注入 spawner。
class _Recorder:
	extends RefCounted

	var generation: int = 1
	var pulse_active: bool = true
	var fail_dispatch: bool = false
	var next_emission_id: int = 100
	## 事件顺序日志："dispatch:<form>" / "finish:<eid>"，用于断言 spawn 先于 finish。
	var log: Array = []
	var dispatched: Array = []

	func dispatch(generation: int, form: int, cell: Vector2i, direction: Vector2i) -> int:
		log.append("dispatch:%d" % form)
		dispatched.append([generation, form, cell, direction])
		if fail_dispatch:
			return -1
		next_emission_id += 1
		return next_emission_id

	func get_generation() -> int:
		return generation

	func is_pulse_active() -> bool:
		return pulse_active

	func finish_emission(expected_generation: int, emission_id: int) -> void:
		log.append("finish:%d" % emission_id)


## 构造 (spawner, recorder, registry) 三件套；registry 为正式类。
func _make_harness() -> Array:
	var recorder: _Recorder = _Recorder.new()
	var registry: _Registry = _Registry.new()
	var spawner: Variant = _Spawner.new(
		registry,
		Callable(recorder, "dispatch"),
		Callable(recorder, "get_generation"),
		Callable(recorder, "is_pulse_active"),
		Callable(recorder, "finish_emission"))
	return [spawner, recorder, registry]


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== FormChangeEmissionSpawner 定向测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)


# ===== 测试 =====

## 01. RAY 路径：载荷透传 dispatch（generation/form/cell/direction 逐字段一致）。
func _test_01_ray_path_dispatches_payload() -> void:
	const G: String = "01_RAY路径透传"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	_check(G, recorder.dispatched.size() == 1, "应恰好 dispatch 一次。")
	if _check(G, recorder.dispatched.size() == 1, "无 dispatch 则后续断言跳过。"):
		var call_args: Array = recorder.dispatched[0]
		_check(G, call_args[0] == 1, "generation 应透传 1。")
		_check(G, call_args[1] == _LightEmissionTypes.LightForm.PARTICLE, "form 应透传 PARTICLE。")
		_check(G, call_args[2] == Vector2i(2, 0), "转换器格应透传 (2,0)。")
		_check(G, call_args[3] == Vector2i(0, 1), "出射方向应透传 (0,1)。")

## 02. RAY 路径 generation 过期：载荷被忽略，零 dispatch。
func _test_02_stale_generation_noop() -> void:
	const G: String = "02_过期generation忽略"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	spawner.handle_ray_form_change(0, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	_check(G, recorder.dispatched.is_empty(), "过期 generation 应零 dispatch。")

## 03. RAY 路径脉冲非活动：载荷被忽略，零 dispatch。
func _test_03_pulse_inactive_noop() -> void:
	const G: String = "03_脉冲非活动忽略"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	recorder.pulse_active = false
	spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.RAY, Vector2i(2, 0), Vector2i(1, 0))
	_check(G, recorder.dispatched.is_empty(), "脉冲非活动应零 dispatch。")

## 04. dispatch 失败（-1）不消耗链深度：连续 16 次失败后第 17 次成功仍可 spawn。
func _test_04_dispatch_failure_does_not_consume_depth() -> void:
	const G: String = "04_dispatch失败不耗深度"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	recorder.fail_dispatch = true
	for i: int in range(_Spawner.MAX_FORM_CHANGE_CHAIN):
		spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	var failures_count: int = recorder.dispatched.size()
	_check(G, failures_count == _Spawner.MAX_FORM_CHANGE_CHAIN, "16 次失败均应尝试 dispatch（实际 %d）。" % failures_count)
	recorder.fail_dispatch = false
	recorder.dispatched.clear()
	spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	_check(G, recorder.dispatched.size() == 1, "失败不耗深度：成功仍应 spawn。")

## 05. 链深度上限：同 generation 16 次成功后拒绝；generation 变更自动归零；reset_chain 同代重置（per-fire）。
func _test_05_chain_depth_cap_and_reset() -> void:
	const G: String = "05_链深度上限与重置"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	for i: int in range(_Spawner.MAX_FORM_CHANGE_CHAIN):
		spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	_check(G, recorder.dispatched.size() == _Spawner.MAX_FORM_CHANGE_CHAIN, "前 16 次应全部 spawn。")
	spawner.handle_ray_form_change(1, 99, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(2, 0), Vector2i(0, 1))
	_check(G, recorder.dispatched.size() == _Spawner.MAX_FORM_CHANGE_CHAIN, "第 17 次应达上限拒绝（不再 dispatch）。")
	# generation 变更自动归零：新 epoch 可再次 spawn。
	recorder.generation = 2
	recorder.dispatched.clear()
	spawner.handle_ray_form_change(2, 99, _LightEmissionTypes.LightForm.RAY, Vector2i(3, 0), Vector2i(1, 0))
	_check(G, recorder.dispatched.size() == 1, "generation 变更后链深度应自动归零并 spawn。")
	# 同代 reset_chain（per-fire 预算重置）：LRC 在每次 request_fire 前调用。
	recorder.generation = 3
	recorder.dispatched.clear()
	for i: int in range(_Spawner.MAX_FORM_CHANGE_CHAIN):
		spawner.handle_ray_form_change(3, 99, _LightEmissionTypes.LightForm.RAY, Vector2i(3, 0), Vector2i(1, 0))
	_check(G, recorder.dispatched.size() == _Spawner.MAX_FORM_CHANGE_CHAIN, "generation 3 重新计满 16。")
	spawner.reset_chain()
	recorder.dispatched.clear()
	spawner.handle_ray_form_change(3, 99, _LightEmissionTypes.LightForm.RAY, Vector2i(3, 0), Vector2i(1, 0))
	_check(G, recorder.dispatched.size() == 1, "reset_chain 后同代应可再次 spawn。")

## 06. PARTICLE 路径事务体：解绑→先 spawn 后 finish；多粒 emission 不 finish；转换载荷透传。
func _test_06_particle_path_spawn_before_finish() -> void:
	const G: String = "06_先spawn后finish"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	var registry: _Registry = h[2]
	var emission_id: int = registry.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, registry.bind_particle_runtime(emission_id, 5), "前置 bind runtime 5 应成功。")
	spawner.handle_particle_terminated(1, 5, _LightEmissionTypes.LightForm.RAY, Vector2i(1, 0), Vector2i(3, 0))
	_check(G, recorder.dispatched.size() == 1, "转换 emission 应生成一次。")
	if _check(G, recorder.dispatched.size() == 1, "无 dispatch 则载荷断言跳过。"):
		var call_args: Array = recorder.dispatched[0]
		_check(G, call_args[1] == _LightEmissionTypes.LightForm.RAY and call_args[2] == Vector2i(3, 0) and call_args[3] == Vector2i(1, 0),
			"转换载荷（RAY / 转换器格 / 出射方向）应逐字段透传。")
	_check(G, recorder.log.size() == 2 and recorder.log[0] == "dispatch:%d" % _LightEmissionTypes.LightForm.RAY and String(recorder.log[1]).begins_with("finish:"),
		"顺序冻结：spawn 必须先于 finish（实际 %s）。" % [recorder.log])
	_check(G, registry.get_emission_runtime_count(emission_id) == 0, "源 emission runtime 应已解绑。")
	# 多粒 emission：最后一粒解绑才 finish。
	var emission_id2: int = registry.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	registry.bind_particle_runtime(emission_id2, 6)
	registry.bind_particle_runtime(emission_id2, 7)
	recorder.log.clear()
	recorder.dispatched.clear()
	spawner.handle_particle_terminated(1, 6, -1, Vector2i.ZERO, Vector2i.ZERO)
	_check(G, recorder.dispatched.is_empty(), "普通终止（载荷 -1）不应 dispatch。")
	_check(G, recorder.log.is_empty(), "emission 仍有 runtime 时不应 finish。")
	spawner.handle_particle_terminated(1, 7, -1, Vector2i.ZERO, Vector2i.ZERO)
	_check(G, recorder.log.size() == 1 and String(recorder.log[0]).begins_with("finish:"), "最后一粒解绑后应 finish 源 emission。")

## 07. PARTICLE 路径 stale generation / 非活动脉冲：零副作用（不解绑、不 spawn、不 finish）。
func _test_07_particle_path_plain_terminate_and_stale() -> void:
	const G: String = "07_stale零副作用"
	var h: Array = _make_harness()
	var spawner: Variant = h[0]
	var recorder: _Recorder = h[1]
	var registry: _Registry = h[2]
	var emission_id: int = registry.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	registry.bind_particle_runtime(emission_id, 5)
	spawner.handle_particle_terminated(0, 5, _LightEmissionTypes.LightForm.RAY, Vector2i(1, 0), Vector2i(3, 0))
	_check(G, registry.get_emission_runtime_count(emission_id) == 1, "stale generation 不应解绑 runtime。")
	_check(G, recorder.dispatched.is_empty() and recorder.log.is_empty(), "stale generation 应零 dispatch / 零 finish。")
	recorder.pulse_active = false
	spawner.handle_particle_terminated(1, 5, _LightEmissionTypes.LightForm.RAY, Vector2i(1, 0), Vector2i(3, 0))
	_check(G, registry.get_emission_runtime_count(emission_id) == 1, "脉冲非活动不应解绑 runtime。")
	_check(G, recorder.dispatched.is_empty() and recorder.log.is_empty(), "脉冲非活动应零 dispatch / 零 finish。")
