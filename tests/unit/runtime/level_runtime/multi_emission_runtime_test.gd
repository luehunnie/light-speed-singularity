extends SceneTree

## LevelRuntimeController 多发射 Runtime 基础测试（M4-E1）。
## 覆盖 LRC 接线：成功 fire allocate emission（active_count 0→1）；settle mark_finished（active_count→0）；reset clear（active_count→0）；
##   emission_id 单调（registry 单元测试已直证单调性，本片证 LRC 在成功 fire 时确实 allocate）；
##   0.5s cooldown 接线（成功 fire 后 is_ready==false、reset 后 true；RAY/PARTICLE 共用同一 cooldown）；
##   active emission 与 cooldown 完全独立（settle 使 active→0 而 cooldown 仍 not ready，证明互不驱动）。
## 经 fixtures/runtime_controller_fixture.gd 装配真实控制器；cooldown 用生产单调时钟，仅在“刚 fire（<0.5s）”与“reset 后”两稳态断言，不测 0.5s 精确边界（边界由 cooldown 单元测试覆盖）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")

const _GROUP_COUNT: int = 6

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
	await _test_01_ray_fire_allocates_emission()
	await _test_02_settle_marks_finished()
	await _test_03_reset_clears_registry_and_cooldown()
	await _test_04_particle_fire_allocates_emission_shared_cooldown()
	await _test_05_cooldown_not_ready_after_fire_ready_after_reset()
	await _test_06_active_emission_and_cooldown_independent()


# ===== 测试 =====

## 1. RAY 成功 fire allocate emission：begin → fire 前 active_count==0，fire 后 active_count==1（LRC 在成功 fire 时确实 allocate）。
func _test_01_ray_fire_allocates_emission() -> void:
	const NAME: String = "01_RAY_fire分配emission"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.get_active_emission_count() == 0, "fire 前 active_count 期望 0。")
	_check(NAME, env.controller.request_fire(), "RAY request_fire 应返回 true。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "成功 fire 后 active_count 期望 1（LRC allocate emission），实际 %d。" % [env.controller.get_active_emission_count()])


## 2. settle mark_finished：fire 进 PULSE_ACTIVE → 等 Ray 异步结束（0.0s timer）→ MOVE_WINDOW 后 active_count 回 0（_finish_current_pulse mark_finished）。
func _test_02_settle_marks_finished() -> void:
	const NAME: String = "02_settle标记emission结束"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_active_emission_count() == 1, "fire 后 active_count 期望 1。")
	await _fixture.wait_settled()  # 让 Ray 异步 _finish_pulse_after_delay 触发 _finish_current_pulse → mark_finished
	_check(NAME, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW, "settle 后应 MOVE_WINDOW，实际 %s。" % [_state_label(env.rsc.get_current_state())])
	_check(NAME, env.controller.get_active_emission_count() == 0, "settle 后 active_count 期望 0（_finish_current_pulse mark_finished），实际 %d。" % [env.controller.get_active_emission_count()])


## 3. reset 清 registry + cooldown：fire → PULSE_ACTIVE → reset 后 active_count==0、is_fire_cooldown_ready==true。
func _test_03_reset_clears_registry_and_cooldown() -> void:
	const NAME: String = "03_reset清registry和cooldown"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_active_emission_count() == 1, "fire 后 active_count 期望 1。")
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "fire 后 cooldown 应 not ready。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.get_active_emission_count() == 0, "reset 后 active_count 期望 0（registry.clear），实际 %d。" % [env.controller.get_active_emission_count()])
	_check(NAME, env.controller.is_fire_cooldown_ready(), "reset 后 cooldown 应 ready（cooldown.reset）。")


## 4. PARTICLE 成功 fire 也 allocate emission（RAY/PARTICLE 共用同一 registry / cooldown）：PARTICLE env fire 后 active_count==1、cooldown not ready。
func _test_04_particle_fire_allocates_emission_shared_cooldown() -> void:
	const NAME: String = "04_PARTICLE_fire分配emission共用cooldown"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null, 1, false, _LightEmissionTypes.LightForm.PARTICLE)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.request_fire(), "PARTICLE request_fire 应返回 true。")
	_check(NAME, env.controller.get_active_emission_count() == 1, "PARTICLE fire 后 active_count 期望 1（与 RAY 共用同一 registry），实际 %d。" % [env.controller.get_active_emission_count()])
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "PARTICLE fire 后 cooldown not ready（与 RAY 共用同一 cooldown 实例）。")


## 5. cooldown 接线稳态：成功 fire 后 is_ready==false（<0.5s）；settle 到 MOVE_WINDOW 后仍 false（0.5s 未满）；reset 后 is_ready==true。
func _test_05_cooldown_not_ready_after_fire_ready_after_reset() -> void:
	const NAME: String = "05_cooldown接线稳态"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	_check(NAME, env.controller.is_fire_cooldown_ready(), "begin_runtime（epoch-start reset）后 cooldown 应 ready。")
	env.controller.request_fire()
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "成功 fire 后 cooldown 应 not ready（on_fire_success 已调用）。")
	await _fixture.wait_settled()  # settle 到 MOVE_WINDOW
	_check(NAME, env.controller.is_fire_cooldown_ready() == false, "settle 到 MOVE_WINDOW 后 cooldown 仍 not ready（0.5s 未满，不受 active 影响）。")
	env.controller.reset_runtime()
	_check(NAME, env.controller.is_fire_cooldown_ready(), "reset 后 cooldown 应 ready。")


## 6. active emission 与 cooldown 完全独立（#8）：fire 后 active=1 且 cooldown not ready；settle 后 active→0 而 cooldown 仍 not ready——active 不驱动 cooldown。
func _test_06_active_emission_and_cooldown_independent() -> void:
	const NAME: String = "06_active_emission与cooldown独立"
	var env: _Fixture._Env = _fixture.make_env(Vector2i(1, 3), Vector2i.RIGHT, null)
	env.rsc.begin_runtime()
	env.controller.request_fire()
	_check(NAME, env.controller.get_active_emission_count() == 1, "fire 后 active_count 期望 1。")
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "fire 后 cooldown not ready。")
	await _fixture.wait_settled()  # settle：active 归 0，但 cooldown 不受影响（仍 not ready，0.5s 未满）——证明 active 不驱动 cooldown。
	_check(NAME, env.controller.get_active_emission_count() == 0, "settle 后 active_count 期望 0。")
	_check(NAME, not env.controller.is_fire_cooldown_ready(), "settle 后 cooldown 仍 not ready（与 active 完全独立，不受 active_count 影响）。")


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
	print("==== LevelRuntimeController 多发射 Runtime 基础测试摘要（M4-E1）====")
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
