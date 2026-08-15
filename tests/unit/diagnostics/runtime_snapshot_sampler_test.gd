extends SceneTree

## RuntimeSnapshotSampler 只读采样集成测试（D7-R1）。
## 覆盖：真实 Runtime 链路（LRC 只读诊断出口 → Sampler → RuntimeSnapshotData → RuntimeSnapshot.serialize）——
##   schema 字段真实值；连续两次采样不改变玩法状态（含 PULSE_ACTIVE 不推进 Tick / 不结束 emission）；
##   并发多 emission（PARTICLE+PARTICLE 与 RAY+PARTICLE 混合）正确采样；单 emission 结束只减少自己；
##   Q 只影响后续发射（旧 emission form 不变）；R 后旧 generation/emission/Particle 无残留；
##   身份禁令（不使用 Node.name / instance_id）；序列化成功；性能字段非玩法。
## 经 tests/unit/runtime/fixtures/runtime_controller_fixture.gd 装配真实控制器；headless 由 Godot --script 运行。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")
const _Sampler: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_sampler.gd")
const _Snapshot: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot.gd")

const _GROUP_COUNT: int = 8

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture: _Fixture = null


func _initialize() -> void:
	await process_frame
	_fixture = _Fixture.new(self)
	await _run_all_tests()
	_report()
	await _fixture.wait_settled(4)
	await _fixture.await_settle_pumps()
	_fixture.cleanup()
	quit(0 if _failures.is_empty() else 1)


## 运行本片全部测试组。
func _run_all_tests() -> void:
	await _test_01_real_runtime_schema_fields()
	await _test_02_two_samples_do_not_change_gameplay()
	await _test_03_concurrent_particle_emissions()
	await _test_04_q_leaves_old_emission_form()
	await _test_05_ending_one_emission_removes_only_itself()
	await _test_06_reset_invalidates_old_generation_emission_particles()
	await _test_07_identity_prohibition()
	await _test_08_perf_and_ray_segments()


## 为 env 构造采样器（与 core_loop 同一接线方式）。
func _make_sampler(env: _Fixture._Env) -> _Sampler:
	return _Sampler.new(
		Callable(env.controller, "get_runtime_diagnostics_snapshot"),
		env.rsc,
		env.fixed_emitter,
		env.objective_controller,
		env.registry,
		env.inventory_controller,
		env.placement_controller
	)


## 1. 真实 Runtime 字段：READY_TO_FIRE、generation=1、移动次数、发射器事实、水晶、库存摘要、validate+serialize。
func _test_01_real_runtime_schema_fields() -> void:
	const NAME: String = "01_真实Runtime字段"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(6, 3))
	env.rsc.begin_runtime()
	var data: Variant = _make_sampler(env).sample()
	_check(NAME, data.validate().is_empty(), "真实采样应通过 validate：%s" % ["；".join(data.validate())])
	_check(NAME, data.run_state == &"READY_TO_FIRE", "run_state 期望 READY_TO_FIRE，实际 %s。" % String(data.run_state))
	_check(NAME, data.runtime_generation == 1, "begin_runtime 后 generation 期望 1，实际 %d。" % data.runtime_generation)
	_check(NAME, data.runtime_move_count == 0 and data.runtime_moves_remaining == 1 and data.runtime_move_limit == 1, "移动次数 0/1/1 期望一致。")
	_check(NAME, data.emitter_cell == Vector2i(1, 3) and data.emitter_direction == Vector2i.RIGHT, "发射器 cell/direction 应为配置值。")
	_check(NAME, data.emitter_form == _LightEmissionTypes.LightForm.RAY and data.allow_form_switch == false, "默认 RAY + allow_form_switch=false。")
	_check(NAME, data.crystal_states.size() == 1 and data.crystal_states[0].crystal_id == &"c001" and data.crystal_states[0].is_activated == false, "水晶摘要应含显式 crystal_id c001 且未点亮。")
	_check(NAME, data.inventory_total == 3 and data.inventory_remaining == 3 and data.placed_mechanism_count == 0, "库存摘要应为只读事实。")
	_check(NAME, _Snapshot.serialize(data).is_success(), "真实采样应序列化成功。")


## 2. 连续两次采样不改变玩法：PULSE_ACTIVE PARTICLE 期间采样两次，Tick / active 数 / RunState / cooldown / 移动次数全不变。
func _test_02_two_samples_do_not_change_gameplay() -> void:
	const NAME: String = "02_两次采样零玩法副作用"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "PARTICLE fire 应成功。")
	var before: Dictionary = env.controller.get_runtime_diagnostics_snapshot()
	var sampler: _Sampler = _make_sampler(env)
	var first: Variant = sampler.sample()
	var second: Variant = sampler.sample()
	var after: Dictionary = env.controller.get_runtime_diagnostics_snapshot()
	_check(NAME, first.validate().is_empty() and second.validate().is_empty(), "两次采样均应通过 validate。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "采样不得改变 RunState（应保持 PULSE_ACTIVE）。")
	_check(NAME, before["particle_tick"] == after["particle_tick"], "采样不得推进 Particle Tick：%d vs %d" % [before["particle_tick"], after["particle_tick"]])
	_check(NAME, before["active_emission_count"] == 1 and after["active_emission_count"] == 1, "采样不得结束 emission（active 仍 1）。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "采样不得移除光粒（仍 1 颗）。")
	_check(NAME, before["fire_cooldown_ready"] == false and after["fire_cooldown_ready"] == false, "采样不得重置 cooldown（仍 not ready）。")
	_check(NAME, env.controller.get_runtime_moves_used() == 0, "采样不得改变移动次数。")


## 3. 并发多 emission（PARTICLE+PARTICLE）：两 emission 两光粒，id 单调且一一关联。
func _test_03_concurrent_particle_emissions() -> void:
	const NAME: String = "03_并发PARTICLE多emission"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "第一发应成功。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "0.5s 后第二发应成功（repeated fire）。")
	var data: Variant = _make_sampler(env).sample()
	_check(NAME, data.validate().is_empty(), "并发快照应通过 validate。")
	_check(NAME, data.active_emission_count == 2 and data.emission_states.size() == 2, "应采样到 2 条活动 emission。")
	_check(NAME, data.emission_states[0].emission_id == 1 and data.emission_states[1].emission_id == 2, "emission_id 应为 1、2（单调）。")
	_check(NAME, data.emission_states[0].form == _LightEmissionTypes.LightForm.PARTICLE and data.emission_states[1].form == _LightEmissionTypes.LightForm.PARTICLE, "两条 emission 均为 PARTICLE。")
	_check(NAME, data.emission_states[0].runtime_ids == [0] and data.emission_states[1].runtime_ids == [1], "每条 emission 各绑定一颗 runtime（0 与 1）。")
	_check(NAME, data.particle_states.size() == 2 and data.particle_states[0].emission_id == 1 and data.particle_states[1].emission_id == 2, "光粒应正确关联所属 emission。")
	_check(NAME, data.particle_active_count == 2 and data.fire_cooldown_ready == false, "性能摘要字段应为当前事实。")
	var json: Variant = _Snapshot.serialize(data)
	_check(NAME, json.is_success() and (JSON.parse_string(json.json_text) as Dictionary)["emissions"].size() == 2, "并发快照应可序列化且 emissions=2。")


## 4. Q 只影响后续发射：旧 RAY emission form 不变，新 emission 为 PARTICLE，emitter_form 已切换。
func _test_04_q_leaves_old_emission_form() -> void:
	const NAME: String = "04_Q旧emission形态不变"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.RAY, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "RAY 首发应成功。")
	_check(NAME, env.controller.request_switch_light_form() == _LightEmissionTypes.LightForm.PARTICLE, "Q 切换应返回 PARTICLE。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "Q 后第二发应成功。")
	var data: Variant = _make_sampler(env).sample()
	_check(NAME, data.emission_states[0].emission_id == 1 and data.emission_states[0].form == _LightEmissionTypes.LightForm.RAY, "旧 emission(1) form 应保持 RAY。")
	_check(NAME, data.emission_states[1].emission_id == 2 and data.emission_states[1].form == _LightEmissionTypes.LightForm.PARTICLE, "新 emission(2) form 应为 PARTICLE。")
	_check(NAME, data.emitter_form == _LightEmissionTypes.LightForm.PARTICLE and data.allow_form_switch, "发射器当前形态应为切换后 PARTICLE 且 allow_form_switch=true。")


## 5. 单 emission 结束只减少自己：RAY settle 后仅剩 PARTICLE emission，Ray 段清零，PULSE_ACTIVE 保持。
func _test_05_ending_one_emission_removes_only_itself() -> void:
	const NAME: String = "05_单emission结束只减自己"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.RAY)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "RAY 首发应成功。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	var sampler: _Sampler = _make_sampler(env)
	# 第二发用反射调度 PARTICLE emission（_dispatch_emission 白盒 seam；不消费 cooldown，构造确定性混合场景）。
	var emission_id: int = env.controller.call("_dispatch_emission", env.controller.get_runtime_generation(), _LightEmissionTypes.LightForm.PARTICLE, Vector2i(1, 3), Vector2i.RIGHT)
	_check(NAME, emission_id > 0, "白盒 PARTICLE dispatch 应成功（emission %d）。" % emission_id)
	var during: Variant = sampler.sample()
	_check(NAME, during.active_emission_count == 2 and during.ray_segment_count > 0, "结束前应采样到 2 条 emission 且 Ray 段 > 0。")
	await _fixture.wait_settled(8)  # RAY 异步结束（fixture 0.0s timer）；PARTICLE 泵 idle 不推进。
	var after: Variant = sampler.sample()
	_check(NAME, after.active_emission_count == 1, "RAY 结束后应只剩 1 条 emission，实际 %d。" % after.active_emission_count)
	_check(NAME, after.emission_states[0].emission_id == 2 and after.emission_states[0].form == _LightEmissionTypes.LightForm.PARTICLE, "保留的应为 PARTICLE emission(2)。")
	_check(NAME, after.ray_segment_count == 0, "RAY 结束后 Ray 段应清零。")
	_check(NAME, after.particle_active_count == 1, "PARTICLE 光粒应保留。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "joined emission 期间应保持 PULSE_ACTIVE。")


## 6. R 后旧 generation/emission/Particle 无残留：active 归零、generation+1、旧 id 不再出现。
func _test_06_reset_invalidates_old_generation_emission_particles() -> void:
	const NAME: String = "06_R后无旧状态残留"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	env.controller.request_fire()
	var sampler: _Sampler = _make_sampler(env)
	var before: Variant = sampler.sample()
	_check(NAME, before.runtime_generation == 1 and before.active_emission_count == 2 and before.particle_states.size() == 2, "R 前应有 generation=1 / 2 emission / 2 光粒。")
	env.controller.reset_runtime()
	var after: Variant = sampler.sample()
	_check(NAME, after.runtime_generation == 2, "R 后 generation 应为 2，实际 %d。" % after.runtime_generation)
	_check(NAME, after.active_emission_count == 0 and after.emission_states.is_empty(), "R 后旧 emission 不残留。")
	_check(NAME, after.particle_active_count == 0 and after.particle_states.is_empty(), "R 后旧 Particle 不残留。")
	_check(NAME, after.particle_tick == 0, "R 后 Particle tick 重置为 0。")
	_check(NAME, after.run_state == &"SETUP" and after.fire_cooldown_ready, "R 后回 SETUP 且 cooldown ready。")
	for emission: Variant in after.emission_states:
		_check(NAME, emission.emission_id != 1 and emission.emission_id != 2, "旧 emission_id 不得出现在 R 后快照。")


## 7. 身份禁令：emission/runtime/crystal 身份均为业务 ID，序列化产物不含 instance_id / Node.name。
func _test_07_identity_prohibition() -> void:
	const NAME: String = "07_身份禁令"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(6, 3))
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var data: Variant = _make_sampler(env).sample()
	var json: Variant = _Snapshot.serialize(data)
	_check(NAME, json.is_success(), "快照应序列化成功。")
	var text: String = json.json_text
	_check(NAME, text.contains("\"emission_id\":1"), "JSON 应含业务 emission_id。")
	_check(NAME, not text.contains("instance_id"), "JSON 不得含 instance_id（禁止作为持久业务 ID）。")
	_check(NAME, not text.contains("\"node_name\"") and not text.contains("\"name\""), "JSON 不得含 Node.name 冒充身份。")
	_check(NAME, text.contains("\"crystal_id\":\"c001\""), "crystal_id 应为显式配置稳定 ID c001。")


## 8. 性能字段非玩法：采样耗时记录且非负；Ray 段计数随 emission 出现；NOT IMPLEMENTED 指标不进玩法。
func _test_08_perf_and_ray_segments() -> void:
	const NAME: String = "08_性能与Ray段"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, Vector2i(6, 3))
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var before: Dictionary = env.controller.get_runtime_diagnostics_snapshot()
	var data: Variant = _make_sampler(env).sample()
	_check(NAME, data.snapshot_duration_usec >= 0, "采样耗时应非负。")
	_check(NAME, data.ray_segment_count > 0, "RAY 活动期间 Ray 段数应 > 0。")
	_check(NAME, data.ray_segment_count == before["ray_segment_count"], "Ray 段数应与 Runtime 只读出口一致。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "性能采样不得改变 RunState。")
	await _fixture.wait_settled(4)


# ===== 断言与报告 =====

## 单项断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== RuntimeSnapshotSampler 只读采样集成测试摘要（D7-R1）====")
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
