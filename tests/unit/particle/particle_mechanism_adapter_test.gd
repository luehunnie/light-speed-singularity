extends SceneTree

## ParticleMechanismAdapter 定向测试（D7-4 B2）。
## 覆盖：null / 已释放 / 未知机关 / 非 Object 一律 no-op；+1 / -1 modifier；入射方向正确传入机关；不直接改变 state。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _Adapter: GDScript = preload(
	"res://gameplay/particle/particle_mechanism_adapter.gd"
)
const _Fake: GDScript = preload(
	"res://tests/unit/particle/fixtures/fake_particle_world_query.gd"
)
const _ParticleRuntimeState: GDScript = preload(
	"res://gameplay/particle/particle_runtime_state.gd"
)

const _GROUP_COUNT: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_null_freed_unknown_noop()
	_test_02_plus_one_modifier()
	_test_03_minus_one_modifier()
	_test_04_direction_passed_to_mechanism()
	_test_05_no_state_mutation()
	_test_06_mirror_reflect_direction()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. null / 已释放 / 未知机关 / 非 Object：一律 continue_motion=true、outgoing_direction=入射、speed_delta=0。
func _test_01_null_freed_unknown_noop() -> void:
	const G: String = "01_null未知no-op"
	var incoming: Vector2i = Vector2i(1, 0)

	var e_null = _Adapter.adapt(null, incoming)
	_check(G, e_null != null, "null 不应返回 null effect。")
	_check(G, e_null.continue_motion == true, "null continue_motion 期望 true。")
	_check(G, e_null.outgoing_direction == incoming, "null outgoing_direction 期望入射方向 (1,0)。")
	_check(G, e_null.speed_delta == 0, "null speed_delta 期望 0。")

	# 已释放 Node（is_instance_valid → false）。
	var freed_node: Node = Node.new()
	freed_node.free()
	var e_freed = _Adapter.adapt(freed_node, incoming)
	_check(G, e_freed.continue_motion == true, "已释放 continue_motion 期望 true。")
	_check(G, e_freed.outgoing_direction == incoming, "已释放 outgoing_direction 期望入射方向。")
	_check(G, e_freed.speed_delta == 0, "已释放 speed_delta 期望 0。")

	# 未知机关：普通 RefCounted，无 get_speed_modifier。
	var unknown: RefCounted = RefCounted.new()
	var e_unknown = _Adapter.adapt(unknown, incoming)
	_check(G, e_unknown.continue_motion == true, "未知机关 continue_motion 期望 true。")
	_check(G, e_unknown.outgoing_direction == incoming, "未知机关 outgoing_direction 期望入射方向。")
	_check(G, e_unknown.speed_delta == 0, "未知机关 speed_delta 期望 0。")

	# 非 Object（int）：安全降级。
	var e_int = _Adapter.adapt(5, incoming)
	_check(G, e_int.continue_motion == true, "非 Object continue_motion 期望 true。")
	_check(G, e_int.speed_delta == 0, "非 Object speed_delta 期望 0。")


## 2. +1 modifier：速度机关返回 1，effect.speed_delta == 1；不改向。
func _test_02_plus_one_modifier() -> void:
	const G: String = "02_+1modifier"
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	var incoming: Vector2i = Vector2i(0, 1)
	var e = _Adapter.adapt(m, incoming)
	_check(G, e.continue_motion == true, "+1 机关 continue_motion 期望 true。")
	_check(G, e.speed_delta == 1, "+1 机关 speed_delta 期望 1，实际 %d。" % e.speed_delta)
	_check(G, e.outgoing_direction == incoming, "+1 机关不改向，outgoing_direction 期望入射 (0,1)。")
	_check(G, m.call_count == 1, "+1 机关 get_speed_modifier 应被调用 1 次，实际 %d。" % m.call_count)


## 3. -1 modifier：速度机关返回 -1，effect.speed_delta == -1。
func _test_03_minus_one_modifier() -> void:
	const G: String = "03_-1modifier"
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = -1
	var incoming: Vector2i = Vector2i(-1, 1)
	var e = _Adapter.adapt(m, incoming)
	_check(G, e.continue_motion == true, "-1 机关 continue_motion 期望 true。")
	_check(G, e.speed_delta == -1, "-1 机关 speed_delta 期望 -1，实际 %d。" % e.speed_delta)
	_check(G, e.outgoing_direction == incoming, "-1 机关不改向，outgoing_direction 期望入射 (-1,1)。")


## 4. direction 正确传给机关：入射方向原样到达 get_speed_modifier 参数。
func _test_04_direction_passed_to_mechanism() -> void:
	const G: String = "04_direction传入机关"
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	var incoming: Vector2i = Vector2i(1, -1)
	_Adapter.adapt(m, incoming)
	_check(G, m.last_seen_direction == incoming,
		"入射方向应原样传入机关，期望 (1,-1)，实际 (%d,%d)。" % [m.last_seen_direction.x, m.last_seen_direction.y])
	_check(G, m.call_count == 1, "机关应被调用 1 次，实际 %d。" % m.call_count)
	# 不依赖具体类名：FakeSpeedMechanism 非 ParticleAccelerator / ParticleDecelerator 子类。
	_check(G, not (m is Node), "FakeSpeedMechanism 不应是 Node（证明不依赖具体机关类）。")


## 5. 不直接改变 state：adapt 前后 ParticleRuntimeState 快照完全一致（结构上不接收 state）。
func _test_05_no_state_mutation() -> void:
	const G: String = "05_不改state"
	var s: _ParticleRuntimeState = _ParticleRuntimeState.create_emitted(
		1, 0, Vector2i(0, 0), Vector2i(1, 0), 0)
	var before: Dictionary = _snapshot_state(s)
	var m = _Fake.FakeSpeedMechanism.new()
	m.delta = 1
	_Adapter.adapt(m, Vector2i(1, 0))
	_Adapter.adapt(null, Vector2i(1, 0))
	_check_snapshot_equals(G, before, _snapshot_state(s), "adapt 调用后 state 应零变化")
	# 结构保证：Adapter 无可变实例字段、adapt 为 static、不接收 state。
	var adapter_instance = _Adapter.new()
	_check(G, not adapter_instance.has_method("apply_move"), "Adapter 不应暴露 apply_move。")
	_check(G, not adapter_instance.has_method("terminate"), "Adapter 不应暴露 terminate。")


## 6. 镜面反射（D7-R5 GUI 验收修复）：has_method("reflect_direction") 机关按正式规则改向、speed_delta=0；
##    入射方向原样传入机关；反射返回 ZERO（非法入射哨兵）安全降级保持入射方向。
func _test_06_mirror_reflect_direction() -> void:
	const G: String = "06_镜面反射"
	# SLASH "/" 镜：入射 RIGHT(1,0) → 出射 UP(0,-1)。
	var m_slash = _Fake.FakeReflectMechanism.new()
	m_slash.slash = true
	var e_slash = _Adapter.adapt(m_slash, Vector2i(1, 0))
	_check(G, e_slash.continue_motion == true, "镜面 continue_motion 期望 true。")
	_check(G, e_slash.outgoing_direction == Vector2i(0, -1),
		"SLASH 镜入射 RIGHT 出射期望 UP(0,-1)，实际 (%d,%d)。" % [e_slash.outgoing_direction.x, e_slash.outgoing_direction.y])
	_check(G, e_slash.speed_delta == 0, "镜面 speed_delta 期望 0（改向不改速）。")
	_check(G, m_slash.call_count == 1, "reflect_direction 应被调用 1 次，实际 %d。" % m_slash.call_count)
	_check(G, m_slash.last_seen_direction == Vector2i(1, 0), "入射方向应原样传入镜面。")

	# BACKSLASH "\" 镜：入射 RIGHT(1,0) → 出射 DOWN(0,1)。
	var m_back = _Fake.FakeReflectMechanism.new()
	m_back.slash = false
	var e_back = _Adapter.adapt(m_back, Vector2i(1, 0))
	_check(G, e_back.outgoing_direction == Vector2i(0, 1),
		"BACKSLASH 镜入射 RIGHT 出射期望 DOWN(0,1)，实际 (%d,%d)。" % [e_back.outgoing_direction.x, e_back.outgoing_direction.y])

	# 斜向入射：SLASH 镜入射 DOWN_RIGHT(1,1) → 出射 UP_LEFT(-1,-1)。
	var e_diag = _Adapter.adapt(m_slash, Vector2i(1, 1))
	_check(G, e_diag.outgoing_direction == Vector2i(-1, -1),
		"SLASH 镜入射 DOWN_RIGHT 出射期望 UP_LEFT(-1,-1)，实际 (%d,%d)。" % [e_diag.outgoing_direction.x, e_diag.outgoing_direction.y])

	# 非法入射哨兵（ZERO 反射）：安全降级保持入射方向，不猜测光学行为。
	var m_zero = _Fake.FakeReflectMechanism.new()
	m_zero.zero_on_any = true
	var e_zero = _Adapter.adapt(m_zero, Vector2i(1, 0))
	_check(G, e_zero.continue_motion == true, "ZERO 反射 continue_motion 期望 true（安全降级）。")
	_check(G, e_zero.outgoing_direction == Vector2i(1, 0), "ZERO 反射 outgoing_direction 期望保持入射 (1,0)。")
	_check(G, e_zero.speed_delta == 0, "ZERO 反射 speed_delta 期望 0。")

	# 结构证明：FakeReflectMechanism 无 get_speed_modifier，镜面判定不依赖速度机关契约。
	_check(G, not m_slash.has_method("get_speed_modifier"), "FakeReflectMechanism 不应暴露 get_speed_modifier（证明只认反射契约）。")


## 拍摄 state 逻辑事实快照。
func _snapshot_state(s: _ParticleRuntimeState) -> Dictionary:
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


## 逐字段比对两份快照。
func _check_snapshot_equals(group: String, expected: Dictionary, actual: Dictionary, label: String) -> void:
	for key: String in expected.keys():
		_check(group, expected[key] == actual[key],
			"%s：字段 %s 期望 %s，实际 %s。" % [label, key, expected[key], actual[key]])


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleMechanismAdapter 测试摘要（D7-4 B2）====")
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
