extends SceneTree

## M4-E4 正式 Q 形态切换 + 混合形态 emission 测试。
## 全部经真实玩家入口 LevelRuntimeController.request_fire() / request_switch_light_form() 驱动
##   （白盒反射仅用于 _finish_emission 乱序/stale 结算与 cooldown deadline 只读诊断，与 E3 既定模式一致）。
## 覆盖 spec §14 自动验收：allow=false 无效、四个非 COMPLETED 状态可切、COMPLETED 禁止、
##   Q 后下一发才用新形态、旧 emission form/视觉/光粒不变、Q 不改 cooldown deadline、不自动发射、
##   Ray→Particle / Particle→Ray 双向、混合乱序完成、四混合 emission 并存、R 恢复初始形态 + stale 安全。
## cooldown 时钟：fixture 可控假时钟（env.fire_cooldown_clock.advance_seconds 确定性推进，不真实等待）。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)；拒绝路径 push_error/print_debug 不计入失败。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _RuntimeStateRules: GDScript = preload("res://gameplay/interaction/runtime_state_rules.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _RAY: int = _LightEmissionTypes.LightForm.RAY
const _PARTICLE: int = _LightEmissionTypes.LightForm.PARTICLE

const _GROUP_COUNT: int = 12

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
	_test_01_allow_false_q_invalid_in_all_states()
	_test_02_allow_true_four_states_switch()
	_test_03_completed_forbids_q()
	_test_04_q_no_autofire_no_emission_touch()
	_test_05_q_keeps_cooldown_deadline()
	await _test_06_next_fire_uses_new_form_ray_to_particle()
	await _test_07_particle_to_ray_mixed()
	await _test_08_mixed_out_of_order_completion()
	await _test_09_four_mixed_emissions_coexist()
	await _test_10_reset_restores_initial_form_and_stale_safe()
	_test_11_rules_pure_function_matrix()
	_test_12_q_keeps_state_and_direction()


# ===== 权限矩阵 =====

## 1. allow_form_switch=false：五个状态 Q 全部无效（返回 -1、形态保持初始 RAY）。
func _test_01_allow_false_q_invalid_in_all_states() -> void:
	const NAME: String = "01_allow为false时Q全态无效"
	# SETUP：初始状态直接 Q。
	var env_setup: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	_check(NAME, env_setup.controller.request_switch_light_form() == -1, "SETUP + allow=false Q 应返回 -1。")
	_check(NAME, env_setup.fixed_emitter.get_light_form() == _RAY, "allow=false Q 后形态应保持初始 RAY。")
	# READY_TO_FIRE / PULSE_ACTIVE / MOVE_WINDOW / COMPLETED：单 env 顺序走完四态。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_switch_light_form() == -1, "READY_TO_FIRE + allow=false Q 应返回 -1。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "READY_TO_FIRE 拒绝后形态仍 RAY。")
	env.controller.request_fire()
	_check(NAME, env.controller.request_switch_light_form() == -1, "PULSE_ACTIVE + allow=false Q 应返回 -1。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "PULSE_ACTIVE 拒绝后形态仍 RAY。")
	env.controller.call("_finish_emission", env.controller.get_runtime_generation(), 1)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应已 MOVE_WINDOW。")
	_check(NAME, env.controller.request_switch_light_form() == -1, "MOVE_WINDOW + allow=false Q 应返回 -1。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "MOVE_WINDOW 拒绝后形态仍 RAY。")
	# COMPLETED：MOVE_WINDOW 再 fire 进 PULSE_ACTIVE 后以完成事实结算（先过 0.5s cooldown）。
	env.fire_cooldown_clock.advance_seconds(0.5)
	env.controller.request_fire()
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应已 COMPLETED。")
	_check(NAME, env.controller.request_switch_light_form() == -1, "COMPLETED + allow=false Q 应返回 -1。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "COMPLETED 拒绝后形态仍 RAY。")


## 2. allow=true 四个非 COMPLETED 状态均可切：单 env 顺序走 SETUP→READY_TO_FIRE→PULSE_ACTIVE→MOVE_WINDOW，
##    每态 Q 成功且形态交替翻转（RAY→PARTICLE→RAY→PARTICLE→RAY）。
func _test_02_allow_true_four_states_switch() -> void:
	const NAME: String = "02_allow为true四态可切"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	# SETUP。
	_check(NAME, env.controller.request_switch_light_form() == _PARTICLE, "SETUP Q 应切到 PARTICLE。")
	_check(NAME, env.fixed_emitter.get_light_form() == _PARTICLE, "SETUP Q 后形态应为 PARTICLE。")
	# READY_TO_FIRE。
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_switch_light_form() == _RAY, "READY_TO_FIRE Q 应切回 RAY。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "READY_TO_FIRE Q 后形态应为 RAY。")
	# PULSE_ACTIVE。
	env.controller.request_fire()
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	_check(NAME, env.controller.request_switch_light_form() == _PARTICLE, "PULSE_ACTIVE Q 应切到 PARTICLE。")
	_check(NAME, env.fixed_emitter.get_light_form() == _PARTICLE, "PULSE_ACTIVE Q 后形态应为 PARTICLE。")
	# MOVE_WINDOW。
	env.controller.call("_finish_emission", env.controller.get_runtime_generation(), 1)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "前置应 MOVE_WINDOW。")
	_check(NAME, env.controller.request_switch_light_form() == _RAY, "MOVE_WINDOW Q 应切回 RAY。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "MOVE_WINDOW Q 后形态应为 RAY。")


## 3. COMPLETED 禁止（allow=true 也禁止）：Q 返回 -1、形态不变、拒绝零副作用。
func _test_03_completed_forbids_q() -> void:
	const NAME: String = "03_COMPLETED禁止Q"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.rsc.finish_pulse(true)
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED, "前置应 COMPLETED。")
	var active_before: int = env.controller.get_active_emission_count()
	_check(NAME, env.controller.request_switch_light_form() == -1, "COMPLETED Q 应返回 -1。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "COMPLETED Q 后形态应保持 RAY。")
	_check(NAME, env.controller.get_active_emission_count() == active_before, "COMPLETED Q 不触 emission。")


# ===== 冻结语义：不发射/不触旧 emission/不触 cooldown =====

## 4. Q 不自动发射、不触场上 emission：PULSE_ACTIVE 旧 Ray 存活时 Q——active/光粒/旧 Ray 视觉段全部不变。
func _test_04_q_no_autofire_no_emission_touch() -> void:
	const NAME: String = "04_Q不自动发射不触旧emission"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "前置 RAY 发射应成功。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "前置旧 Ray 应 14 段。")
	var gen: int = env.controller.get_runtime_generation()
	_check(NAME, env.controller.request_switch_light_form() == _PARTICLE, "PULSE_ACTIVE Q 应切到 PARTICLE。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "Q 不自动发射（active 仍 1）。")
	_check(NAME, env.controller.get_particle_active_count() == 0, "Q 不创建光粒。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "Q 不清/不改旧 Ray 视觉（仍 14 段）。")
	_check(NAME, env.light_visual_controller.get_emission_segment_count(1) == 14, "旧 emission1 视觉不变。")
	_check(NAME, env.controller.get_runtime_generation() == gen, "Q 不推进 runtime generation（不重建运行期）。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "Q 不切 RunState（仍 PULSE_ACTIVE）。")


## 5. Q 不改变 cooldown deadline：fire 后 not-ready 中 Q → deadline 不变仍 not ready；ready 后 Q → 仍 ready 不刷新。
func _test_05_q_keeps_cooldown_deadline() -> void:
	const NAME: String = "05_Q不改cooldown_deadline"
	# not-ready 中 Q。
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	env.fire_cooldown_clock.advance_seconds(0.2)
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "前置 0.2s 应 not ready。")
	_check(NAME, _ready_at(env) == 0.5, "前置 deadline 期望 0.5。")
	env.controller.request_switch_light_form()
	_check(NAME, _ready_at(env) == 0.5, "Q 后 deadline 仍 0.5（不重置/不消费/不延长）。")
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "Q 后仍 not ready。")
	# ready 后 Q 不刷新。
	env.fire_cooldown_clock.advance_seconds(0.4)
	_check(NAME, env.controller.is_fire_cooldown_ready(), "前置 0.6s 应 ready。")
	env.controller.request_switch_light_form()
	_check(NAME, _ready_at(env) == 0.5, "ready 后 Q 不刷新 deadline（仍 0.5）。")
	_check(NAME, env.controller.is_fire_cooldown_ready(), "ready 后 Q 仍 ready。")


# ===== 真实玩家双向混合路径 =====

## 6. Ray→Particle：fire RAY（14 段）→ Q → 下一发才是 PARTICLE（旧 Ray 视觉/active 不变，两 emission 并存）。
func _test_06_next_fire_uses_new_form_ray_to_particle() -> void:
	const NAME: String = "06_Ray到Particle下一发新形态"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 RAY 应成功。")
	_check(NAME, env.controller.request_switch_light_form() == _PARTICLE, "Q 应切到 PARTICLE。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "Q 后旧 Ray 视觉仍 14 段。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "0.5s 后 fire2 应成功（新形态 PARTICLE）。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "fire2 应以 PARTICLE 形态发射（光粒 1）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "两 emission 并存（RAY+PARTICLE）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "旧 Ray emission 视觉不受新 PARTICLE emission 影响。")


## 7. Particle→Ray：fire PARTICLE → Q → 下一发 RAY（旧光粒存活，两 emission 并存）。
func _test_07_particle_to_ray_mixed() -> void:
	const NAME: String = "07_Particle到Ray混合并存"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _PARTICLE, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 PARTICLE 应成功。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "fire1 后光粒 1。")
	_check(NAME, env.controller.request_switch_light_form() == _RAY, "Q 应切到 RAY。")
	_check(NAME, env.controller.get_particle_state_snapshot(0) != null, "Q 后旧光粒仍存活。")
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "0.5s 后 fire2 应成功（新形态 RAY）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "fire2 应以 RAY 形态发射（14 段）。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "两 emission 并存（PARTICLE+RAY）。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "旧光粒不受新 Ray emission 影响。")


## 8. 混合乱序完成：P(emission1)+R(emission2) 并存 → 先结束 emission2（Ray 清自身视觉、光粒存活、保持 PULSE_ACTIVE）→
##    再结束 emission1 → MOVE_WINDOW；单个结束不影响另一个。
func _test_08_mixed_out_of_order_completion() -> void:
	const NAME: String = "08_混合乱序完成"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _PARTICLE, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 PARTICLE 应成功。")
	env.controller.request_switch_light_form()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "fire2 RAY 应成功。")
	_check(NAME, env.controller.get_active_emission_count() == 2, "前置两 emission 并存。")
	var gen: int = env.controller.get_runtime_generation()
	# 乱序：先结束后发的 Ray emission2。
	env.controller.call("_finish_emission", gen, 2)
	_check(NAME, env.light_visual_controller.get_emission_segment_count(2) == 0, "emission2 结束清自身 Ray 视觉。")
	_check(NAME, env.controller.get_particle_state_snapshot(0) != null, "emission2 结束不影响 emission1 光粒。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "emission2 结束后 active 仍 1。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission1 存活保持 PULSE_ACTIVE。")
	# 最后结束 emission1 → 聚合结算 MOVE_WINDOW。
	env.controller.call("_finish_emission", gen, 1)
	_check(NAME, env.controller.get_active_emission_count() == 0, "最后 emission 结束后 active 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后 emission 才 MOVE_WINDOW。")


## 9. 四混合 emission 并存：P→Q→R→Q→P→Q→R 交替四次 fire——active 4、光粒 2、Ray 28 段同时在场，
##    乱序部分结束后剩余并存、最后才 MOVE_WINDOW。
func _test_09_four_mixed_emissions_coexist() -> void:
	const NAME: String = "09_四混合emission并存"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _PARTICLE, [], true)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "fire1 PARTICLE 应成功。")
	env.controller.request_switch_light_form()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "fire2 RAY 应成功。")
	env.controller.request_switch_light_form()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "fire3 PARTICLE 应成功。")
	env.controller.request_switch_light_form()
	env.fire_cooldown_clock.advance_seconds(0.5)
	_check(NAME, env.controller.request_fire(), "fire4 RAY 应成功。")
	# 四 emission 并存快照：active 4、光粒 2（emission1/3）、Ray 28 段（emission2/4）。
	_check(NAME, env.controller.get_active_emission_count() == 4, "四混合 emission 应并存（active 4）。")
	_check(NAME, env.controller.get_particle_active_count() == 2, "两 PARTICLE emission 光粒并存（2）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 28, "两 RAY emission 视觉并存（28 段）。")
	# 乱序结束：先结束两个 RAY（emission4、emission2），两光粒存活。
	var gen: int = env.controller.get_runtime_generation()
	env.controller.call("_finish_emission", gen, 4)
	env.controller.call("_finish_emission", gen, 2)
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "两 Ray 结束后视觉清零。")
	_check(NAME, env.controller.get_particle_active_count() == 2, "两光粒不受 Ray 结束影响。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "剩余 emission 存活保持 PULSE_ACTIVE。")
	# 结束 emission3（PARTICLE）→ 剩 emission1；最后结束 emission1 → MOVE_WINDOW。
	env.controller.call("_finish_emission", gen, 3)
	_check(NAME, env.controller.get_active_emission_count() == 1 and env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "emission3 结束后剩 emission1 且 PULSE_ACTIVE。")
	env.controller.call("_finish_emission", gen, 1)
	_check(NAME, env.controller.get_active_emission_count() == 0, "最后 emission 结束后 active 0。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "最后才 MOVE_WINDOW。")


## 10. R/reset stale 安全：初始 PARTICLE 关卡——SETUP Q→RAY 发射后 Q→PARTICLE，R 恢复初始 PARTICLE 并全清；
##     新 epoch 发射以初始形态 PARTICLE 走；旧 generation 结束回调对新 epoch 零影响。
func _test_10_reset_restores_initial_form_and_stale_safe() -> void:
	const NAME: String = "10_R恢复初始形态stale安全"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _PARTICLE, [], true)
	# SETUP 切到 RAY 并发射（Ray emission1，gen1）。
	_check(NAME, env.controller.request_switch_light_form() == _RAY, "SETUP Q 应切到 RAY。")
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "RAY fire 应成功。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 14, "前置 Ray 14 段。")
	env.controller.request_switch_light_form()
	# R：全清 + 恢复关卡初始形态 PARTICLE + 回 SETUP。
	env.controller.reset_runtime()
	_check(NAME, env.fixed_emitter.get_light_form() == _PARTICLE, "R 应恢复关卡初始形态 PARTICLE。")
	_check(NAME, env.controller.get_active_emission_count() == 0, "R 后 active 0。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "R 后视觉全清。")
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "R 后应 SETUP。")
	_check(NAME, env.controller.is_fire_cooldown_ready(), "R 后 cooldown ready。")
	# 旧 gen1 回调 stale：不清新 epoch 状态/视觉/不误 finish。
	env.rsc.begin_runtime()
	var gen_new: int = env.controller.get_runtime_generation()
	env.controller.call("_finish_emission", 1, 1)
	_check(NAME, env.controller.get_runtime_generation() == gen_new, "stale 回调不改 generation。")
	# 新 epoch 发射以恢复后的初始形态 PARTICLE 走（光粒而非 Ray）。
	_check(NAME, env.controller.request_fire(), "新 epoch fire 应成功。")
	_check(NAME, env.controller.get_particle_active_count() == 1, "新 epoch 应以初始形态 PARTICLE 发射（光粒 1）。")
	_check(NAME, env.light_visual_controller.get_segment_count() == 0, "新 epoch 不产生 Ray 段。")


# ===== 纯规则与发射器不变量 =====

## 11. RuntimeStateRules.can_switch_light_form 纯函数矩阵：5 状态 × allow 真值全枚举。
func _test_11_rules_pure_function_matrix() -> void:
	const NAME: String = "11_纯规则矩阵"
	var states: Array[int] = [
		_RuntimeInteractionTypes.RunState.SETUP,
		_RuntimeInteractionTypes.RunState.READY_TO_FIRE,
		_RuntimeInteractionTypes.RunState.PULSE_ACTIVE,
		_RuntimeInteractionTypes.RunState.MOVE_WINDOW,
		_RuntimeInteractionTypes.RunState.COMPLETED,
	]
	for state: int in states:
		var allow_result: bool = _RuntimeStateRules.can_switch_light_form(state, true)
		var expected: bool = state != _RuntimeInteractionTypes.RunState.COMPLETED
		_check(NAME, allow_result == expected, "allow=true 时 %s 期望 %s。" % [_state_label(state), str(expected)])
		_check(NAME, not _RuntimeStateRules.can_switch_light_form(state, false), "allow=false 时 %s 期望 false。" % [_state_label(state)])


## 12. Q 不改方向与格：切换前后 get_direction/get_cell 不变（Q 只翻形态，不触方向单字段事实）。
func _test_12_q_keeps_state_and_direction() -> void:
	const NAME: String = "12_Q不改方向与格"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _RAY, [], true)
	env.controller.request_switch_light_form()
	_check(NAME, env.fixed_emitter.get_direction() == Vector2i.RIGHT, "Q 后方向应保持 RIGHT。")
	_check(NAME, env.fixed_emitter.get_cell() == Vector2i(1, 3), "Q 后格应保持 (1,3)。")
	# 双向翻转自反：再切一次回 RAY。
	_check(NAME, env.controller.request_switch_light_form() == _RAY, "再切一次应回 RAY。")
	_check(NAME, env.fixed_emitter.get_light_form() == _RAY, "二次 Q 后形态回 RAY。")


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
	print("==== M4-E4 正式 Q 形态切换 + 混合形态 emission 测试摘要 ====")
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
