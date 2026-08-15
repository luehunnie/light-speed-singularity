extends SceneTree

## M4-E3 Gate 2 修复直测：post-emit bind_particle_runtime false 分支即时撤销刚发射光粒。
## 缺陷背景：_begin_particle_emission 在 scheduler.emit_particle 成功后调 bind；bind false（防御路径，正常不可达）旧实现
##   只 return false，已 emit 光粒 zombie 惰性存活至 epoch 重置，违反冻结 transaction"失败仅回滚本次 emission / 不留 zombie"。
## 修复：bind 拒绝时先 scheduler._rollback_emitted_particle（下划线私有约定内部协作方法，仅 LRC 防御事务调用）撤销刚发射光粒再返回 false。
## 强制手段（真实分支直证，非仅 Registry 级 cross-bind 单测）：白盒反射把 scheduler 下一个 runtime_id 预绑到既有 emission，
##   制造 cross-emission rebind 防御态——再经 request_fire 真实玩家路径触发 emit → bind false，走 LRC 真实修复分支。
## 覆盖：①玩家路径直证（无 zombie/旧光粒完好/PULSE_ACTIVE 保持/cooldown 不变/无视觉/无泵残留）
##   ②joined 失败（旧 Ray emission/视觉/状态全保持）③失败后系统恢复（runtime_id 单调空洞、后续发射正常）。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)；失败路径 push_error 输出不计入失败。

const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _GROUP_COUNT: int = 3

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


func _run_all_tests() -> void:
	_test_01_post_emit_bind_false_rolls_back_only_new_runtime()
	_test_02_joined_bind_failure_keeps_old_ray_emission()
	_test_03_subsequent_fire_recovers_after_rollback()


# ===== ① 玩家路径直证：post-emit bind false → 仅撤销新光粒，零残留 =====

## 1. PARTICLE 首发成功后，把 scheduler 下一个 runtime_id 预绑到 emission1（cross-emission rebind 防御态）；
##    0.5s cooldown 到期后真实 request_fire → emit 返回该预绑 id → bind(新 emission, 已绑 runtime) 必 false → 修复分支。
##    证明：scheduler 活动数不变（刚发射 runtime 已撤销、旧光粒完好 active）、registry 无 zombie（失败 emission 已回滚、
##    emission1 仍活动）、PULSE_ACTIVE 保持、cooldown 不消费（仍 ready）、无 EMITTED 视觉事件、无第二条泵链。
func _test_01_post_emit_bind_false_rolls_back_only_new_runtime() -> void:
	const NAME: String = "01_emit后bind_false仅撤销新光粒"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "首发 PARTICLE request_fire 应成功。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "首发后光粒 active 1。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "首发后 emission active 1。")
	# 白盒构造防御态：把 scheduler 下一个 runtime_id 预绑到 emission1（届时 bind(emission2, 该 id) 因 cross-emission rebind 被拒）。
	var scheduler: Object = env.controller.get("_particle_scheduler")
	var registry: Object = env.controller.get("_active_emission_registry")
	var poisoned_rid: int = scheduler.get_next_runtime_id()
	_check(NAME, registry.bind_particle_runtime(1, poisoned_rid), "预绑下一个 runtime_id=%d 到 emission1 应成功（防御态构造）。" % poisoned_rid)
	# 0.5s 到期后真实玩家路径 repeated fire：emit 返回 poisoned_rid → bind false → 修复分支即时撤销。
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.is_fire_cooldown_ready(), "0.5s 后 cooldown ready。")
	_check(NAME, not env.controller.request_fire(), "bind false 防御触发时 request_fire 应返回 false。")
	# 无 zombie：调度器活动数不变，刚发射 runtime 已撤销，旧 emission 光粒完好。
	_check(NAME, env.controller.get_particle_active_count() == 1, "失败后 scheduler 活动光粒数不变（仍 1，无 zombie），实际 %d。" % [env.controller.get_particle_active_count()])
	_check(NAME, env.controller.get_particle_state_snapshot(poisoned_rid) == null, "刚发射的 runtime %d 应已被立即撤销（snapshot null）。" % poisoned_rid)
	var old_snapshot: Dictionary = env.controller.get_particle_state_snapshot(poisoned_rid - 1)
	_check(NAME, old_snapshot != null and old_snapshot["active"], "旧 emission 光粒（runtime %d）完好且 active。" % (poisoned_rid - 1))
	# registry 无 zombie：失败 emission 已回滚，emission1 仍活动。
	_check(NAME, env.controller.get_active_emission_count() == 1, "失败后 registry active 仍 1（失败 emission 已回滚）。")
	_check(NAME, not registry.is_active(2), "emission2 不在活动表（无 registry zombie）。")
	# PULSE_ACTIVE 保持（joined failure 不退脉冲）。
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "旧 emission 仍活动，保持 PULSE_ACTIVE。")
	# cooldown 不变（失败路径不消费）。
	_check(NAME, env.controller.is_fire_cooldown_ready(), "失败路径不消费 cooldown（仍 ready）。")
	# 无视觉残留：EMITTED 事件仍只有首发的 1 条（bind 失败先于事件发布返回）。
	_check(NAME, env.particle_visual_sink.events_of_type("EMITTED").size() == 1, "失败 emission 不发布 EMITTED（仍 1 条），实际 %d。" % [env.particle_visual_sink.events_of_type("EMITTED").size()])
	# 无泵残留：泵链总数仍为首发 1 条（bind 失败先于 start_pump_if_idle 返回）。
	_check(NAME, env.particle_tick_pump.get("_chains").size() == 1, "失败不启第二条泵链（仍 1 条），实际 %d。" % [env.particle_tick_pump.get("_chains").size()])


# ===== ② joined 失败：旧 Ray emission 不受影响 =====

## 2. 旧 Ray emission1 活动 + 同防御态下白盒 dispatch PARTICLE emission2 → bind false → 撤销；
##    旧 Ray 视觉/活动状态/PULSE_ACTIVE 全保持（失败只回滚本次 emission）。
func _test_02_joined_bind_failure_keeps_old_ray_emission() -> void:
	const NAME: String = "02_joined失败不影响旧Ray"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "旧 Ray emission1 request_fire 应成功。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "旧 Ray 视觉 14 段。")
	var scheduler: Object = env.controller.get("_particle_scheduler")
	var registry: Object = env.controller.get("_active_emission_registry")
	var poisoned_rid: int = scheduler.get_next_runtime_id()
	_check(NAME, registry.bind_particle_runtime(1, poisoned_rid), "预绑下一个 runtime_id=%d 到 emission1 应成功（防御态构造）。" % poisoned_rid)
	# 白盒 dispatch PARTICLE emission2（joined；玩家路径直证见 test_01）：emit 返回 poisoned_rid → bind false → 撤销 + 回滚。
	var eid: int = int(env.controller.call("_dispatch_emission", 1, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(14, 3), Vector2i.RIGHT))
	_check(NAME, eid == -1, "joined bind false dispatch 应返回 -1，实际 %d。" % eid)
	_check(NAME, env.controller.get_particle_active_count() == 0, "joined 失败后无任何光粒（撤销即时，无 zombie），实际 %d。" % [env.controller.get_particle_active_count()])
	_check(NAME, env.controller.get_particle_state_snapshot(poisoned_rid) == null, "刚发射 runtime %d 已撤销。" % poisoned_rid)
	_check(NAME, env.controller.get_active_emission_count() == 1, "旧 Ray emission 仍唯一 active。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "旧 Ray 视觉不受影响（仍 14 段）。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "joined failure 保持 PULSE_ACTIVE。")


# ===== ③ 失败后恢复：runtime_id 单调空洞 + 后续发射正常 =====

## 3. bind false 撤销后系统可继续正常发射：runtime_id 不回拨（撤销形成空洞，与 emission_id 空洞一致），
##    解除防御态后下一次 request_fire 正常成功并绑定新 runtime。
func _test_03_subsequent_fire_recovers_after_rollback() -> void:
	const NAME: String = "03_撤销后恢复正常发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(14, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "首发 PARTICLE request_fire 应成功。")
	var scheduler: Object = env.controller.get("_particle_scheduler")
	var registry: Object = env.controller.get("_active_emission_registry")
	var poisoned_rid: int = scheduler.get_next_runtime_id()
	_check(NAME, registry.bind_particle_runtime(1, poisoned_rid), "预绑防御态构造成功。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, not env.controller.request_fire(), "防御态下第二次 request_fire 应失败（bind false）。")
	# runtime_id 不回拨：撤销的 poisoned_rid 形成空洞，下一个分配 poisoned_rid + 1。
	_check(NAME, scheduler.get_next_runtime_id() == poisoned_rid + 1, "撤销不回拨 runtime_id（下一分配 %d，期望 %d）。" % [scheduler.get_next_runtime_id(), poisoned_rid + 1])
	# 解除防御态（解绑预绑 runtime），再发射应恢复正常。
	_check(NAME, registry.unbind_particle_runtime(poisoned_rid) == 1, "解除防御态（解绑预绑 runtime）应返回原 emission 1。")
	_check(NAME, env.controller.is_fire_cooldown_ready(), "失败未消费 cooldown，第三次发射前仍 ready。")
	_check(NAME, env.controller.request_fire(), "解除防御态后第三次 request_fire 应成功。")
	_check(NAME, env.controller.get_particle_active_count() == 2, "第三次发射后两颗光粒并存（active 2），实际 %d。" % [env.controller.get_particle_active_count()])
	var recovered_snapshot: Dictionary = env.controller.get_particle_state_snapshot(poisoned_rid + 1)
	_check(NAME, recovered_snapshot != null and recovered_snapshot["active"], "新发射 runtime %d 已正常登记且 active。" % (poisoned_rid + 1))
	_check(NAME, env.controller.get_active_emission_count() == 2, "两个活动 emission 并存（active 2）。")


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== M4-E3 Gate2 post-emit bind false 即时撤销测试摘要 ====")
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
