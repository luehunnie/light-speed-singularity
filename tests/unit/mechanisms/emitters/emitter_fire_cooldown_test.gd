extends SceneTree

## EmitterFireCooldown 单元测试（M4-E1）。
## 覆盖（#7 精确 0.5s 边界）：初始 ready；on_fire_success 后 not ready；t=0.499 not ready；t=0.500 ready；
##   再次 on_fire_success 重新开始 cooldown；is_ready 查询不消费 cooldown；reset→ready；FIRE_INTERVAL_SECONDS=0.5；
##   （RAY/PARTICLE 共用）cooldown 形态无关——on_fire_success 不区分形态，形态切换不重置/不消费。
## 经可控 fake clock Callable 驱动时间 seam，不真实 sleep。headless extends SceneTree，由 Godot --script 运行。

const _Cooldown: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_fire_cooldown.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 9

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_initial_ready_and_constant()
	_test_02_after_success_not_ready()
	_test_03_boundary_0_499_not_ready()
	_test_04_boundary_0_500_ready()
	_test_05_second_success_restarts_cooldown()
	_test_06_ready_check_does_not_consume()
	_test_07_reset_ready()
	_test_08_form_switch_does_not_reset()
	_test_09_failed_check_does_not_consume()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 可控时钟 seam =====

## 可控单调时钟：测试经 advance(d) 推进时间，now() 返回当前秒。
class _FakeClock:
	extends RefCounted
	var t: float = 0.0
	func now() -> float:
		return t
	func advance(d: float) -> void:
		t += d


## 构造绑定 fake clock 的 cooldown。
func _new_cooldown(clock: _FakeClock) -> _Cooldown:
	return _Cooldown.new(Callable(clock, "now"))


# ===== 测试 =====

## 1. 初始 ready + FIRE_INTERVAL_SECONDS=0.5 常量。
func _test_01_initial_ready_and_constant() -> void:
	const G: String = "01_初始ready"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	_check(G, c.is_ready(), "初始应 ready。")
	_check(G, _Cooldown.FIRE_INTERVAL_SECONDS == 0.5, "FIRE_INTERVAL_SECONDS 期望 0.5。")
	_check(G, c.get_ready_at() == 0.0, "初始 ready_at 期望 0.0。")


## 2. on_fire_success 后 not ready（t=0）。
func _test_02_after_success_not_ready() -> void:
	const G: String = "02_成功后not_ready"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	_check(G, not c.is_ready(), "t=0 成功发射后应 not ready。")
	_check(G, c.get_ready_at() == 0.5, "ready_at 期望 0.5，实际 %f。" % c.get_ready_at())


## 3. t=0.499 仍 not ready（边界严格 < 0.5）。
func _test_03_boundary_0_499_not_ready() -> void:
	const G: String = "03_0.499边界not_ready"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	clk.advance(0.499)
	_check(G, not c.is_ready(), "t=0.499 应仍 not ready。")


## 4. t=0.500 ready（#7 精确边界：>= 0.5 即 ready）。
func _test_04_boundary_0_500_ready() -> void:
	const G: String = "04_0.500边界ready"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	clk.advance(0.500)
	_check(G, c.is_ready(), "t=0.500 应 ready（>= 0.5）。")


## 5. 再次 on_fire_success 重新开始 cooldown：第一次 ready 后再 success，重新 not ready。
func _test_05_second_success_restarts_cooldown() -> void:
	const G: String = "05_再次success重启cooldown"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	clk.advance(0.500)
	_check(G, c.is_ready(), "0.5s 后应 ready。")
	c.on_fire_success()
	_check(G, not c.is_ready(), "第二次 success 后应重新 not ready。")
	_check(G, c.get_ready_at() == 1.0, "第二次 success 后 ready_at 期望 1.0（0.5+0.5），实际 %f。" % c.get_ready_at())
	clk.advance(0.499)
	_check(G, not c.is_ready(), "再过 0.499 仍 not ready。")
	clk.advance(0.001)
	_check(G, c.is_ready(), "再过 0.001（累计 0.5）应 ready。")


## 6. is_ready 查询不消费 cooldown：连续 is_ready 调用不改 ready_at。
func _test_06_ready_check_does_not_consume() -> void:
	const G: String = "06_ready查询不消费"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	var ra: float = c.get_ready_at()
	for i in 10:
		c.is_ready()
	_check(G, c.get_ready_at() == ra, "10 次 is_ready 查询不应改变 ready_at。")
	_check(G, not c.is_ready(), "查询后仍 not ready（查询不推进时间 / 不消费 cooldown）。")


## 7. reset→ready：成功后 reset 恢复 ready。
func _test_07_reset_ready() -> void:
	const G: String = "07_reset恢复ready"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	c.on_fire_success()
	_check(G, not c.is_ready(), "success 后 not ready。")
	c.reset()
	_check(G, c.is_ready(), "reset 后应 ready。")
	_check(G, c.get_ready_at() == 0.0, "reset 后 ready_at 期望 0.0。")


## 8. 形态切换不重置/不消费 cooldown：cooldown 无形态概念——on_fire_success 不区分 RAY/PARTICLE；无 on_fire_success 则形态切换（外部事件）不改 ready。
## [br]RAY/PARTICLE 共用同一 cooldown 事实：cooldown 组件无 form 字段，on_fire_success 是唯一消费入口，与形态无关。
func _test_08_form_switch_does_not_reset() -> void:
	const G: String = "08_形态切换不重置cooldown"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	# RAY 成功发射 → cooldown 开始。
	c.on_fire_success()
	_check(G, not c.is_ready(), "RAY 成功后 not ready。")
	# 模拟形态切换（外部事件，不调 cooldown 任何方法）——cooldown 状态不变。
	clk.advance(0.250)
	var _form_after_switch: int = _LightEmissionTypes.LightForm.PARTICLE  # 形态切换不触碰 cooldown
	_check(G, not c.is_ready(), "形态切换后 0.25s 仍 not ready（形态切换不重置 cooldown）。")
	clk.advance(0.250)
	_check(G, c.is_ready(), "形态切换后累计 0.5s 应 ready（cooldown 按 0.5s 计，不受形态影响）。")
	# RAY/PARTICLE 共用：PARTILE 成功也走同一 cooldown。
	c.on_fire_success()
	_check(G, not c.is_ready(), "PARTICLE 成功后 not ready（与 RAY 共用同一 cooldown 实例）。")


## 9. 失败检查不消费 cooldown（#8 一侧）：cooldown 未 on_fire_success 时，多次 is_ready 查询（模拟发射失败被拒）后 reset 仍回到初始 ready，ready_at 全程 0。
func _test_09_failed_check_does_not_consume() -> void:
	const G: String = "09_失败检查不消费cooldown"
	var clk: _FakeClock = _FakeClock.new()
	var c: _Cooldown = _new_cooldown(clk)
	# 模拟连续发射失败（被拒）：不调 on_fire_success，只查 is_ready。
	for i in 5:
		c.is_ready()
	_check(G, c.is_ready(), "连续失败检查后仍 ready（失败不消费 cooldown）。")
	_check(G, c.get_ready_at() == 0.0, "失败检查 ready_at 仍 0.0（未消费 cooldown）。")
	# 随后一次成功发射才开始 cooldown。
	c.on_fire_success()
	_check(G, not c.is_ready(), "随后成功发射才开始 cooldown（not ready）。")


# ===== 断言与报告 =====

## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterFireCooldown 测试摘要（M4-E1）====")
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
