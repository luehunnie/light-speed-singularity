extends SceneTree

## ParticleRuntimeState 定向测试（D7-4 B1 / B1.1）。
## 覆盖：emitted 初始 STANDARD；next_move_tick 正确（正交 / 斜向）；runtime_id/generation/cell/direction 保存；
##   不依赖 Node（RefCounted）；active 初始 true；非法构造按冻结边界拒绝；terminate 单向不得复活；
##   apply_move 正式状态推进：合法全字段原子更新、正交→斜向改向、STANDARD→FAST/SLOW 档位变更、
##   非法 direction / speed_tier / next_move_tick<=current_tick / current_tick<0 / terminate 后均零变化且不复活。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _ParticleRuntimeState: GDScript = preload(
	"res://gameplay/particle/particle_runtime_state.gd"
)
const _ParticleMotionRules: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)

const _GROUP_COUNT: int = 17

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 9 组后统一报告并退出。
func _initialize() -> void:
	_test_01_emitted_standard_speed()
	_test_02_next_move_tick()
	_test_03_fields_preserved()
	_test_04_not_node()
	_test_05_active_initial_true()
	_test_06_invalid_direction_rejected()
	_test_07_invalid_runtime_id_rejected()
	_test_08_invalid_current_tick_rejected()
	_test_09_terminate_one_way()
	_test_10_apply_move_legal()
	_test_11_orthogonal_to_diagonal()
	_test_12_speed_tier_changes()
	_test_13_invalid_direction_zero_change()
	_test_14_invalid_speed_tier_zero_change()
	_test_15_next_move_tick_not_after_current()
	_test_16_current_tick_negative()
	_test_17_apply_move_after_terminate()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. emitted 入口初始速度固定 STANDARD。
func _test_01_emitted_standard_speed() -> void:
	const G: String = "01_emitted标准速度"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	_check(G, s != null, "合法构造不应返回 null。")
	_check(G, s.get_speed_tier() == _ParticleMotionRules.SpeedTier.STANDARD,
		"emitted 初始速度期望 STANDARD，实际 %d。" % s.get_speed_tier())


## 2. next_move_tick 正确：正交 STANDARD=4，斜向 STANDARD=6；step_started_tick=current_tick。
func _test_02_next_move_tick() -> void:
	const G: String = "02_next_move_tick"
	var ortho: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 10)
	_check(G, ortho.get_step_started_tick() == 10, "正交 step_started_tick 期望 10。")
	_check(G, ortho.get_next_move_tick() == 14, "正交 next_move_tick 期望 10+4=14，实际 %d。" % ortho.get_next_move_tick())
	var diag: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		2, 0, Vector2i(0, 0), Vector2i(1, 1), 10)
	_check(G, diag.get_step_started_tick() == 10, "斜向 step_started_tick 期望 10。")
	_check(G, diag.get_next_move_tick() == 16, "斜向 next_move_tick 期望 10+6=16，实际 %d。" % diag.get_next_move_tick())
	var tick0: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		3, 0, Vector2i(0, 0), Vector2i(0, -1), 0)
	_check(G, tick0.get_next_move_tick() == 4, "current_tick=0 正交 next_move_tick 期望 4，实际 %d。" % tick0.get_next_move_tick())


## 3. runtime_id / generation / cell / direction 正确保存（含负坐标 cell）。
func _test_03_fields_preserved() -> void:
	const G: String = "03_字段保存"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		7, 3, Vector2i(5, -2), Vector2i(-1, 1), 100)
	_check(G, s.get_runtime_id() == 7, "runtime_id 期望 7，实际 %d。" % s.get_runtime_id())
	_check(G, s.get_generation() == 3, "generation 期望 3，实际 %d。" % s.get_generation())
	_check(G, s.get_cell() == Vector2i(5, -2), "cell 期望 (5,-2)，实际 (%d,%d)。" % [s.get_cell().x, s.get_cell().y])
	_check(G, s.get_direction() == Vector2i(-1, 1), "direction 期望 (-1,1)，实际 (%d,%d)。" % [s.get_direction().x, s.get_direction().y])


## 4. 不依赖 Node：是 RefCounted，不是 Node；create_emitted 无需场景树。
## 注：GDScript 解析器已知 ParticleRuntimeState 静态类型为 RefCounted，故直接写 "s is Node" 会触发 Parse Error，
## 这本身即是“不是 Node”的静态保证；此处通过 Object 上转做运行期判定以产出显式断言。
func _test_04_not_node() -> void:
	const G: String = "04_不依赖Node"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	_check(G, s is RefCounted, "ParticleRuntimeState 应为 RefCounted。")
	var as_object: Object = s
	_check(G, as_object is RefCounted, "上转 Object 后仍应为 RefCounted。")
	_check(G, not (as_object is Node), "ParticleRuntimeState 不应是 Node。")
	_check(G, s.get_runtime_id() == 1, "无场景树构造后字段仍可用。")


## 5. active 初始 true。
func _test_05_active_initial_true() -> void:
	const G: String = "05_active初始true"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	_check(G, s.is_active() == true, "emitted 初始 active 期望 true。")


## 6. 非法方向：ZERO 与超范围方向拒绝（返回 null）。
func _test_06_invalid_direction_rejected() -> void:
	const G: String = "06_非法方向拒绝"
	_check(G, _ParticleRuntimeState.create_emitted(1, 0, Vector2i.ZERO, Vector2i.ZERO, 0) == null,
		"ZERO 方向应拒绝构造（返回 null）。")
	_check(G, _ParticleRuntimeState.create_emitted(1, 0, Vector2i.ZERO, Vector2i(2, 0), 0) == null,
		"(2,0) 方向应拒绝构造（返回 null）。")
	_check(G, _ParticleRuntimeState.create_emitted(1, 0, Vector2i.ZERO, Vector2i(1, 2), 0) == null,
		"(1,2) 方向应拒绝构造（返回 null）。")


## 7. 非法 runtime_id：<0 拒绝（返回 null）。
func _test_07_invalid_runtime_id_rejected() -> void:
	const G: String = "07_非runtimid拒绝"
	_check(G, _ParticleRuntimeState.create_emitted(-1, 0, Vector2i.ZERO, Vector2i(1, 0), 0) == null,
		"runtime_id=-1 应拒绝构造（返回 null）。")


## 8. 非法 current_tick：<0 拒绝（返回 null）。
func _test_08_invalid_current_tick_rejected() -> void:
	const G: String = "08_非curtick拒绝"
	_check(G, _ParticleRuntimeState.create_emitted(1, 0, Vector2i.ZERO, Vector2i(1, 0), -1) == null,
		"current_tick=-1 应拒绝构造（返回 null）。")


## 9. terminate 单向：终止后 active=false，幂等，且无置真入口（不得复活）。
func _test_09_terminate_one_way() -> void:
	const G: String = "09_terminate单向"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	s.terminate()
	_check(G, s.is_active() == false, "terminate 后 active 期望 false。")
	# 幂等：再次 terminate 仍为 false。
	s.terminate()
	_check(G, s.is_active() == false, "重复 terminate 后 active 仍期望 false。")
	# 结构保证：不存在置真入口。
	_check(G, not s.has_method("set_active"), "不应暴露 set_active 入口（否则可复活）。")
	_check(G, not s.has_method("revive"), "不应暴露 revive 入口（否则可复活）。")


## 10. 合法 apply_move：五可变字段全部原子更新；runtime_id / generation 不变；active 仍 true。
func _test_10_apply_move_legal() -> void:
	const G: String = "10_apply_move合法"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var ok: bool = s.apply_move(
		Vector2i(1, 0), Vector2i(0, 1), _ParticleMotionRules.SpeedTier.FAST, 10, 12)
	_check(G, ok == true, "合法 apply_move 期望返回 true。")
	var expected: Dictionary = {
		"runtime_id": 1,
		"generation": 0,
		"cell": Vector2i(1, 0),
		"direction": Vector2i(0, 1),
		"speed_tier": _ParticleMotionRules.SpeedTier.FAST,
		"step_started_tick": 10,
		"next_move_tick": 12,
		"active": true,
	}
	_check_snapshot_equals(G, expected, _snapshot(s), "合法 apply_move 后整体状态")


## 11. 支持正交→斜向改向（direction (1,0) → (1,1)）；cell 同步推进到斜向邻格。
func _test_11_orthogonal_to_diagonal() -> void:
	const G: String = "11_正交转斜向"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		2, 1, Vector2i(3, 3), Vector2i(1, 0), 5)
	var ok: bool = s.apply_move(
		Vector2i(4, 4), Vector2i(1, 1), _ParticleMotionRules.SpeedTier.STANDARD, 20, 26)
	_check(G, ok == true, "正交→斜向 apply_move 期望返回 true。")
	var expected: Dictionary = {
		"runtime_id": 2,
		"generation": 1,
		"cell": Vector2i(4, 4),
		"direction": Vector2i(1, 1),
		"speed_tier": _ParticleMotionRules.SpeedTier.STANDARD,
		"step_started_tick": 20,
		"next_move_tick": 26,
		"active": true,
	}
	_check_snapshot_equals(G, expected, _snapshot(s), "正交→斜向后整体状态")


## 12. 合法 tier 更新：STANDARD→FAST 与 STANDARD→SLOW 均接受且档位落地。
func _test_12_speed_tier_changes() -> void:
	const G: String = "12_档位变更"
	var fast: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var ok_f: bool = fast.apply_move(
		Vector2i(1, 0), Vector2i(1, 0), _ParticleMotionRules.SpeedTier.FAST, 4, 6)
	_check(G, ok_f == true, "STANDARD→FAST apply_move 期望返回 true。")
	_check(G, fast.get_speed_tier() == _ParticleMotionRules.SpeedTier.FAST,
		"STANDARD→FAST 后 speed_tier 期望 FAST(2)，实际 %s。" % fast.get_speed_tier())
	var slow: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		2, 0, Vector2i(0, 0), Vector2i(0, 1), 0)
	var ok_s: bool = slow.apply_move(
		Vector2i(0, 1), Vector2i(0, 1), _ParticleMotionRules.SpeedTier.SLOW, 4, 12)
	_check(G, ok_s == true, "STANDARD→SLOW apply_move 期望返回 true。")
	_check(G, slow.get_speed_tier() == _ParticleMotionRules.SpeedTier.SLOW,
		"STANDARD→SLOW 后 speed_tier 期望 SLOW(0)，实际 %s。" % slow.get_speed_tier())


## 13. 非法 direction（ZERO / 超范围）：返回 false，整体状态零变化。
func _test_13_invalid_direction_zero_change() -> void:
	const G: String = "13_非法direction零变化"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(2, -1), Vector2i(1, 0), 8)
	var before: Dictionary = _snapshot(s)
	_check(G, s.apply_move(Vector2i(3, -1), Vector2i.ZERO, _ParticleMotionRules.SpeedTier.STANDARD, 10, 14) == false,
		"非法 direction (ZERO) apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "非法 direction (ZERO) 后状态应零变化")
	_check(G, s.apply_move(Vector2i(3, -1), Vector2i(2, 0), _ParticleMotionRules.SpeedTier.STANDARD, 10, 14) == false,
		"非法 direction (2,0) apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "非法 direction (2,0) 后状态应零变化")


## 14. 非法 speed tier（99 / -1）：返回 false，整体状态零变化。
func _test_14_invalid_speed_tier_zero_change() -> void:
	const G: String = "14_非speedtier零变化"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var before: Dictionary = _snapshot(s)
	_check(G, s.apply_move(Vector2i(1, 0), Vector2i(1, 0), 99, 10, 14) == false,
		"非法 speed_tier 99 apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "非法 speed_tier 99 后状态应零变化")
	_check(G, s.apply_move(Vector2i(1, 0), Vector2i(1, 0), -1, 10, 14) == false,
		"非法 speed_tier -1 apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "非法 speed_tier -1 后状态应零变化")


## 15. next_move_tick <= current_tick（相等 / 更早）：返回 false，整体状态零变化。
func _test_15_next_move_tick_not_after_current() -> void:
	const G: String = "15_nexttick不晚于当前"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var before: Dictionary = _snapshot(s)
	_check(G, s.apply_move(Vector2i(1, 0), Vector2i(1, 0), _ParticleMotionRules.SpeedTier.STANDARD, 10, 10) == false,
		"next_move_tick == current_tick apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "next==current 后状态应零变化")
	_check(G, s.apply_move(Vector2i(1, 0), Vector2i(1, 0), _ParticleMotionRules.SpeedTier.STANDARD, 10, 9) == false,
		"next_move_tick < current_tick apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "next<current 后状态应零变化")


## 16. current_tick < 0：返回 false，整体状态零变化。
func _test_16_current_tick_negative() -> void:
	const G: String = "16_curtick为负零变化"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var before: Dictionary = _snapshot(s)
	_check(G, s.apply_move(Vector2i(1, 0), Vector2i(1, 0), _ParticleMotionRules.SpeedTier.STANDARD, -1, 4) == false,
		"current_tick=-1 apply_move 期望返回 false。")
	_check_snapshot_equals(G, before, _snapshot(s), "current_tick<0 后状态应零变化")


## 17. terminate 后 apply_move：返回 false，不复活（active 仍 false），整体状态零变化。
func _test_17_apply_move_after_terminate() -> void:
	const G: String = "17_终止后不可推进"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		5, 2, Vector2i(1, 1), Vector2i(1, 0), 7)
	s.terminate()
	var before: Dictionary = _snapshot(s)
	var ok: bool = s.apply_move(
		Vector2i(2, 1), Vector2i(1, 0), _ParticleMotionRules.SpeedTier.FAST, 10, 12)
	_check(G, ok == false, "terminate 后 apply_move 期望返回 false。")
	_check(G, s.is_active() == false, "terminate 后 apply_move 不应复活（active 仍 false）。")
	_check_snapshot_equals(G, before, _snapshot(s), "terminate 后 apply_move 状态应零变化")


## 拍摄全部逻辑事实快照（含不可变身份 runtime_id / generation），用于 apply_move 前后整体比对。
func _snapshot(s: _ParticleRuntimeState) -> Dictionary:
	return {
		"runtime_id": s.get_runtime_id(),
		"generation": s.get_generation(),
		"cell": s.get_cell(),
		"direction": s.get_direction(),
		"speed_tier": s.get_speed_tier(),
		"step_started_tick": s.get_step_started_tick(),
		"next_move_tick": s.get_next_move_tick(),
		"active": s.is_active(),
	}


## 逐字段比对两份快照是否完全一致；任一字段差异即追加一条失败，便于定位是哪个字段被动了。
func _check_snapshot_equals(group: String, expected: Dictionary, actual: Dictionary, label: String) -> void:
	_check(group, expected["runtime_id"] == actual["runtime_id"],
		"%s：runtime_id 期望 %s，实际 %s。" % [label, expected["runtime_id"], actual["runtime_id"]])
	_check(group, expected["generation"] == actual["generation"],
		"%s：generation 期望 %s，实际 %s。" % [label, expected["generation"], actual["generation"]])
	_check(group, expected["cell"] == actual["cell"],
		"%s：cell 期望 %s，实际 %s。" % [label, expected["cell"], actual["cell"]])
	_check(group, expected["direction"] == actual["direction"],
		"%s：direction 期望 %s，实际 %s。" % [label, expected["direction"], actual["direction"]])
	_check(group, expected["speed_tier"] == actual["speed_tier"],
		"%s：speed_tier 期望 %s，实际 %s。" % [label, expected["speed_tier"], actual["speed_tier"]])
	_check(group, expected["step_started_tick"] == actual["step_started_tick"],
		"%s：step_started_tick 期望 %s，实际 %s。" % [label, expected["step_started_tick"], actual["step_started_tick"]])
	_check(group, expected["next_move_tick"] == actual["next_move_tick"],
		"%s：next_move_tick 期望 %s，实际 %s。" % [label, expected["next_move_tick"], actual["next_move_tick"]])
	_check(group, expected["active"] == actual["active"],
		"%s：active 期望 %s，实际 %s。" % [label, expected["active"], actual["active"]])


## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleRuntimeState 测试摘要（D7-4 B1）====")
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
