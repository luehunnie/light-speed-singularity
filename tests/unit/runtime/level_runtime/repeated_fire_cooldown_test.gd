extends SceneTree

## M4-E3 正式 repeated fire + 0.5 秒 cooldown transaction 测试。
## 全部经真实玩家入口 LevelRuntimeController.request_fire() 驱动（白盒反射仅用于 transaction 分支的直接证明：_finish_emission 乱序结算 /
##   _dispatch_emission 制造 joined failure / _abort_pulse_if_no_active_emission 分支 / _begin_particle_emission bind 防御 / deadline 只读诊断）。
## 覆盖 spec §13 cooldown 自动验收（0.499 拒 / 0.500 允 / 仅成功刷新 deadline / 状态/拖拽/非法配置/dispatch failure 不消费 /
##   not-ready 重试不延长 / RAY-PARTICLE 共用 deadline / reset ready）+ E3 测试重点（Ray→Ray、Particle→Particle、首发未结束 0.5s 后第二发成功、
##   两发独立正序/乱序结束、joined failure 不影响旧 emission、多 emission reset、stale callback 不影响新 epoch）+
##   bind_particle_runtime false 防御与 joined-failure 分支直接测试。
## cooldown 时钟：fixture 可控假时钟（env.fire_cooldown_clock.advance_seconds 确定性推进，不真实等待）。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)；失败路径用例的 push_error 输出不计入失败。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _ActiveEmissionRegistry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _GROUP_COUNT: int = 16

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
	await _test_01_player_ray_ray_repeated_fire_first_alive_ordered_finish()
	await _test_02_player_particle_particle_repeated_fire_out_of_order_finish()
	_test_03_cooldown_0499_blocked_no_extend()
	_test_04_cooldown_0500_allowed_refreshes_deadline()
	_test_05_state_rejections_do_not_consume_cooldown()
	_test_06_drag_rejection_does_not_consume_or_extend()
	_test_07_invalid_config_rejections_do_not_consume()
	_test_08_dispatch_failure_does_not_consume_cooldown()
	_test_09_ray_particle_share_deadline()
	_test_10_reset_makes_cooldown_ready_and_refire()
	_test_11_joined_failure_keeps_old_emission_and_cooldown()
	_test_12_joined_failure_branch_direct_test()
	_test_13_bind_particle_runtime_false_defense()
	_test_14_multi_emission_reset()
	_test_15_stale_callback_no_new_epoch_impact()
	_test_16_no_illegal_begin_pulse_self_loop_in_repeated_fire()


# ===== 玩家路径 repeated fire =====

## 1. 玩家路径 Ray→Ray：fire1 成功（PULSE_ACTIVE、active 1、14 段）→ 0.5s 后 fire2 成功且 emission1 仍存活（28 段、active 2、仍 PULSE_ACTIVE）；
##    两发独立正序结束：finish emission1 不清 emission2，最后一个才 MOVE_WINDOW。
func _test_01_player_ray_ray_repeated_fire_first_alive_ordered_finish() -> void:
	const NAME: String = "01_玩家Ray-Ray连发首发存活正序结束"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 RAY 应成功。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "fire1 后应 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "fire1 后 active 期望 1。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "0.500 后 fire2 RAY 应成功（repeated fire）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "fire2 后 active 期望 2（首发存活，两 emission 并存）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "两 Ray 各 14 段总期望 28。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "两发射后仍应 PULSE_ACTIVE。")
	# 正序独立结束：先 finish emission1——只清 emission1，emission2 不受影响，保持 PULSE_ACTIVE。
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 0, "emission1 结束只清自身视觉。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 14, "emission2 视觉不受 emission1 结束影响（仍 14）。")
	_check(NAME, env.controller.get_active_emission_count() == 1 and env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission1 结束后 active 1 + PULSE_ACTIVE。")
	env.controller.call("_finish_emission", 1, 2)
	_check(NAME, env.controller.get_active_emission_count() == 0, "最后 emission2 结束后 active 期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 emission 才 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


## 2. 玩家路径 Particle→Particle：fire1 成功（光粒 1）→ 0.5s 后 fire2 成功且 emission1 仍存活（光粒 2、active 2）；乱序结束：先 finish emission2，emission1 存活保持 PULSE_ACTIVE，最后 emission1 才 MOVE_WINDOW。
func _test_02_player_particle_particle_repeated_fire_out_of_order_finish() -> void:
	const NAME: String = "02_玩家Particle-Particle连发乱序结束"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 PARTICLE 应成功。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "fire1 后光粒期望 1。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "0.500 后 fire2 PARTICLE 应成功（repeated fire）。")
	_check(NAME, env.controller.get_particle_active_count() == 2, "fire2 后光粒期望 2（首发存活）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "fire2 后 active 期望 2。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "两发射后仍应 PULSE_ACTIVE。")
	# 乱序独立结束：先 finish emission2（后发先结束），emission1 不受影响。
	env.controller.call("_finish_emission", 1, 2)
	_check(NAME, env.controller.get_active_emission_count() == 1, "乱序 finish emission2 后 active 期望 1。")
	_check(NAME, env.controller.get_particle_state_snapshot(0) != null, "emission1 的光粒 rid0 不因 emission2 结束被移除。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission1 存活保持 PULSE_ACTIVE。")
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.controller.get_active_emission_count() == 0, "最后 emission1 结束后 active 期望 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 emission 才 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])


# ===== cooldown 边界 =====

## 3. 0.499 不可再次发射且不延长 deadline：fire1(t=0) → advance 0.499 → request_fire false、active 不变、ready_at 仍 0.5（not-ready 重试不消费/不延长）。
func _test_03_cooldown_0499_blocked_no_extend() -> void:
	const NAME: String = "03_0.499拒绝且不延长deadline"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, _ready_at(env) == 0.5, "fire1(t=0) 后 deadline 期望 0.5。")
	env.fire_cooldown_clock.advance_seconds(0.499)
	_check(NAME, not env.controller.request_fire(), "0.499 时 request_fire 应返回 false。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "被拒重试不得创建第二 emission。")
	_check(NAME, _ready_at(env) == 0.5, "not-ready 被拒重试后 deadline 仍 0.5（不延长、不消费）。")
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "0.499 时 cooldown 应 not ready。")


## 4. 0.500 可再次发射且仅成功刷新 deadline：advance 到恰好 0.500 → request_fire true → deadline 刷新为 1.0。
func _test_04_cooldown_0500_allowed_refreshes_deadline() -> void:
	const NAME: String = "04_0.500允许并刷新deadline"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.is_fire_cooldown_ready(), "0.500 时 cooldown 应 ready。")
	_check(NAME, env.controller.request_fire(), "0.500 时 request_fire 应成功。")
	_check(NAME, _ready_at(env) == 1.0, "成功发射后 deadline 刷新为 1.0（仅成功刷新）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "两 emission 并存期望 2。")


# ===== 拒绝路径不消费 cooldown =====

## 5. 状态拒绝不消费：SETUP（未 begin_runtime）与 COMPLETED 下的 request_fire 均不消费、不刷新 deadline。
func _test_05_state_rejections_do_not_consume_cooldown() -> void:
	const NAME: String = "05_状态拒绝不消费cooldown"
	# SETUP：从未发射，request_fire 拒绝后 cooldown 仍 ready（deadline 0.0）。
	var env_setup: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	_check(NAME, not env_setup.controller.request_fire(), "SETUP request_fire 应拒绝。")
	_check(NAME, _ready_at(env_setup) == 0.0 and env_setup.controller.is_fire_cooldown_ready(), "SETUP 拒绝不消费 cooldown（仍 ready）。")
	# COMPLETED：fire1 后 finish_pulse(true) 进 COMPLETED，重试拒绝且 deadline 不变。
	var env_done: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env_done.rsc.begin_runtime()
	env_done.controller.request_fire()
	env_done.rsc.finish_pulse(true)
	_check(NAME, env_done.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	_check(NAME, not env_done.controller.request_fire(), "COMPLETED request_fire 应拒绝。")
	_check(NAME, _ready_at(env_done) == 0.5, "COMPLETED 拒绝后 deadline 仍 0.5（不消费、不延长）。")


## 6. 拖拽拒绝不消费不延长：cooldown 已 ready（advance 0.6 > 0.5）但拖拽中 → 拒绝且 deadline 不变。
func _test_06_drag_rejection_does_not_consume_or_extend() -> void:
	const NAME: String = "06_拖拽拒绝不消费不延长"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.6)
	env.drag._stub_dragging = true
	_check(NAME, not env.controller.request_fire(), "拖拽中 request_fire 应拒绝。")
	_check(NAME, _ready_at(env) == 0.5, "拖拽拒绝后 deadline 仍 0.5（cooldown 已 ready 也不刷新）。")
	env.drag._stub_dragging = false
	_check(NAME, env.controller.request_fire(), "取消拖拽后同刻度可成功发射。")


## 7. 非法配置拒绝不消费：非法方向与未知 form 均在 preflight 零副作用拒绝，deadline 保持 0.0（未消费）。
func _test_07_invalid_config_rejections_do_not_consume() -> void:
	const NAME: String = "07_非法配置拒绝不消费"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.ZERO, null)
	env.rsc.begin_runtime()
	_check(NAME, not env.controller.request_fire(), "非法方向 request_fire 应拒绝。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "非法方向不创建视觉。")
	_check(NAME, _ready_at(env) == 0.0, "非法方向拒绝不消费 cooldown。")
	env.fixed_emitter.try_set_direction(Vector2i.RIGHT)
	env.fixed_emitter.set("_form", 99)
	_check(NAME, not env.controller.request_fire(), "未知 form request_fire 应拒绝（preflight 零副作用）。")
	_check(NAME, _ready_at(env) == 0.0, "未知 form 拒绝不消费 cooldown。")


## 8. dispatch 失败不消费：fire1 成功后白盒 dispatch 失败（ZERO direction）→ deadline 不变（joined 场景在 11 组另证）。
func _test_08_dispatch_failure_does_not_consume_cooldown() -> void:
	const NAME: String = "08_dispatch失败不消费cooldown"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	var eid_fail: int = int(env.controller.call("_dispatch_emission", 1, _LightEmissionTypes.LightForm.RAY, Vector2i(1, 3), Vector2i.ZERO))
	_check(NAME, eid_fail == -1, "白盒 dispatch 失败应返回 -1。")
	_check(NAME, _ready_at(env) == 0.5, "dispatch 失败后 deadline 仍 0.5（不消费、不刷新）。")


# ===== 形态共用与 reset =====

## 9. RAY/PARTICLE 共用同一 deadline：RAY fire1(t=0) 后切换 form（白盒，Q 未实现）→ 0.499 PARTICLE 拒（同一 deadline）→ 0.500 PARTICLE 成功且 deadline 刷新为 1.0。
func _test_09_ray_particle_share_deadline() -> void:
	const NAME: String = "09_RAY-PARTICLE共用deadline"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "RAY fire1 应成功。")
	env.fixed_emitter.set("_form", _LightEmissionTypes.LightForm.PARTICLE)
	env.fire_cooldown_clock.advance_seconds(0.499)
	_check(NAME, not env.controller.request_fire(), "RAY 消费的同一 deadline 在 0.499 应拒绝 PARTICLE。")
	env.fire_cooldown_clock.advance_seconds(0.001)
	_check(NAME, env.controller.request_fire(), "0.500 时 PARTICLE 应按同一 cooldown ready 发射。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "PARTICLE fire2 应创建 1 颗光粒。")
	_check(NAME, _ready_at(env) == 1.0, "共用 deadline 刷新为 1.0。")


## 10. reset ready：双发射后 R → cooldown ready、active 清零；新 epoch 再次发射成功。
func _test_10_reset_makes_cooldown_ready_and_refire() -> void:
	const NAME: String = "10_reset后cooldown_ready可再发射"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	env.controller.request_fire()
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "双发射后 cooldown 应 not ready。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.is_fire_cooldown_ready(), "R 后 cooldown 应 ready。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "R 后 active 期望 0。")
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "新 epoch 再次发射应成功。")


# ===== joined failure 与直接分支测试 =====

## 11. joined failure 不影响旧 emission 且不消费 cooldown：fire1 存活时白盒 dispatch 失败 → 旧 emission/视觉/光粒保持、PULSE_ACTIVE 保持、deadline 不变。
func _test_11_joined_failure_keeps_old_emission_and_cooldown() -> void:
	const NAME: String = "11_joined失败不影响旧emission不消费cooldown"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "旧 Ray emission1 应成功。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "旧 Ray 视觉 14 段。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	var eid_fail: int = int(env.controller.call("_dispatch_emission", 1, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(1, 3), Vector2i.ZERO))
	_check(NAME, eid_fail == -1, "joined PARTICLE ZERO direction dispatch 应失败 -1。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "joined 失败后旧 emission 仍活动。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "joined 失败不清旧 Ray 视觉。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "joined 失败保持 PULSE_ACTIVE。")
	_check(NAME, _ready_at(env) == 0.5, "joined 失败不消费 cooldown（deadline 仍 0.5，advance 0.5 已 ready）。")


## 12. joined-failure 分支直接测试：registry 仍有活动 emission 时调 _abort_pulse_if_no_active_emission → 保持 PULSE_ACTIVE、只刷新 UI、不 finish pulse。
func _test_12_joined_failure_branch_direct_test() -> void:
	const NAME: String = "12_joined-failure分支直接测试"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	var refresh_before: int = env.sink.refresh_calls
	env.controller.call("_abort_pulse_if_no_active_emission")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "has_active 分支应保持 PULSE_ACTIVE。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "has_active 分支不影响旧 emission。")
	_check(NAME, env.sink.refresh_calls == refresh_before + 1, "has_active 分支应刷新一次 UI（实际 +%d）。" % [env.sink.refresh_calls - refresh_before])


## 13. bind_particle_runtime false 防御直接测试：(a) Registry 级 cross-emission rebind 拒绝且两侧映射不变；(b) LRC _begin_particle_emission 对不活动 emission 先于 emit 拒绝（零光粒残留、零 zombie）。
func _test_13_bind_particle_runtime_false_defense() -> void:
	const NAME: String = "13_bindfalse防御直接测试"
	# (a) Registry 级：e1 绑 rid100 后 e2 再绑 rid100 → false（cross-emission rebind），两侧映射完全不变。
	# Variant 鸭子调用（与 world_query 同模式）：ActiveEmissionRegistry 为 preload 脚本类型，不经全局 class 缓存。
	var registry: Variant = _ActiveEmissionRegistry.new()
	var e1: int = registry.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	var e2: int = registry.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	_check(NAME, registry.bind_particle_runtime(e1, 100) == true, "首次 bind e1-rid100 应 true。")
	_check(NAME, registry.bind_particle_runtime(e2, 100) == false, "cross-emission rebind 应返回 false。")
	_check(NAME, registry.find_emission_for_runtime(100) == e1, "拒绝后 rid100 仍属 e1（reverse 不被覆盖）。")
	_check(NAME, registry.get_emission_runtime_count(e2) == 0, "拒绝后 e2 不残留 runtime。")
	_check(NAME, registry.get_emission_runtime_count(e1) == 1, "拒绝后 e1 runtime 数不变。")
	# (b) LRC 级：不活动 emission（未 allocate 的 eid）先于 emit 拒绝——不创建光粒、不留 zombie。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	var started: bool = bool(env.controller.call("_begin_particle_emission", 1, 999, Vector2i(1, 3), Vector2i.RIGHT))
	_check(NAME, not started, "不活动 emission 的 Particle 启动应返回 false（bind 前置防御）。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "防御拒绝零光粒残留（emit 前拒绝）。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "防御拒绝零 Registry zombie。")


# ===== reset / stale =====

## 14. 多 emission reset：玩家两连发（RAY+RAY）active 2 → R 全清（active 0、视觉 0、SETUP、cooldown ready）。
func _test_14_multi_emission_reset() -> void:
	const NAME: String = "14_多emission_reset全清"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	env.controller.request_fire()
	_check(NAME, env.controller.get_active_emission_count() == 2, "前置两 emission active 期望 2。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "前置 28 段。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_active_emission_count() == 0, "R 后 active 期望 0。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "R 后视觉全清。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应 SETUP。")
	_check(NAME, env.controller.is_fire_cooldown_ready(), "R 后 cooldown 应 ready。")


## 15. stale callback 不影响新 epoch：gen1 发射 → R → 新 epoch 再发射 → 旧 generation _finish_emission 回调 no-op（不清新视觉、不改状态、不误 finish）。
func _test_15_stale_callback_no_new_epoch_impact() -> void:
	const NAME: String = "15_stale回调不影响新epoch"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()  # gen=1, emission1。
	env.controller.reset_runtime()  # gen=2, SETUP。
	env.rsc.begin_runtime()  # gen=3。
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "新 epoch fire 应成功（cooldown 已 reset）。")
	_check(NAME, env.controller.get_runtime_generation() == 3, "新 epoch generation 期望 3。")
	var seg_before: int = env.light_visual_controller.get_segment_count()
	env.controller.call("_finish_emission", 1, 1)  # 模拟旧 gen1 回调恢复。
	_check(NAME, env.light_visual_controller.get_segment_count() == seg_before, "旧回调不清新 epoch 视觉（仍 %d）。" % [env.light_visual_controller.get_segment_count()])
	_check(NAME, env.controller.get_active_emission_count() == 1, "旧回调不误 finish 新 emission。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "旧回调不改新 epoch 状态。")


## 16. repeated fire 不请求非法 begin_pulse 自环：PULSE_ACTIVE 中成功 repeated fire 后状态仍 PULSE_ACTIVE 且无非法转换错误（RunStateController.begin_pulse 拒绝 PULSE_ACTIVE 来源；若 LRC 误调将产生 push_error 且状态不变——本组以状态保持 + emission 正常创建证明未走自环路径）。
func _test_16_no_illegal_begin_pulse_self_loop_in_repeated_fire() -> void:
	const NAME: String = "16_repeated不请求begin_pulse自环"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "repeated fire 应成功。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "repeated fire 后状态应保持 PULSE_ACTIVE（无自环转换尝试）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "repeated fire 创建第二个 emission。")
	# 直接证明 begin_pulse 在 PULSE_ACTIVE 被拒（非法自环）：LRC 若误请求将被此守卫拒绝。
	_check(NAME, not env.rsc.begin_pulse(), "RunStateController 应拒绝 PULSE_ACTIVE→PULSE_ACTIVE 非法自环。")


# ===== 辅助 =====

## 读 LRC 内 cooldown 的 ready_at deadline（只读诊断 get_ready_at；白盒读取，测试专用）。
func _ready_at(env: _Fixture._Env) -> float:
	var cooldown: Variant = env.controller.get("_emitter_fire_cooldown")
	return float(cooldown.get_ready_at())


## RunState 值映射为人类可读名称（仅用于失败明细）。
func _state_label(state: int) -> String:
	match state:
		_RuntimeInteractionTypes.RunState.SETUP:
			return "SETUP"
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE:
			return "READY_TO_FIRE"
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE:
			return "PULSE_ACTIVE"
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW:
			return "MOVE_WINDOW"
		_RuntimeInteractionTypes.RunState.COMPLETED:
			return "COMPLETED"
		_:
			return "未知(%d)" % [state]


# ===== 断言与报告 =====

## 单项断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== M4-E3 正式 repeated fire + 0.5s cooldown transaction 测试摘要 ====")
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
