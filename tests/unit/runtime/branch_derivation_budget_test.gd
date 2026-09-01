extends SceneTree

## C-08 分光分支派生 + 树级预算（FormChangeEmissionSpawner.handle_ray_branches）定向测试。
## 覆盖：分支→RAY dispatch 透传（source_cell/direction/继承色 5 参）；generation 过期 / 脉冲非活动 no-op；
##   dispatch 失败不消耗预算；树级总预算 128（第 129 支按阻挡处理，不再生成 emission）；
##   reset_chain 同帧归零预算；generation 变更自动归零预算。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题。


const _Spawner: GDScript = preload("res://gameplay/runtime/form_change_emission_spawner.gd")
const _Registry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _Result: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_result.gd"
)
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_branch_dispatch_passthrough()
	_test_02_stale_generation_and_inactive_pulse()
	_test_03_dispatch_failure_does_not_consume_budget()
	_test_04_budget_128_cap()
	_test_05_reset_chain_clears_budget()
	_test_06_generation_advance_clears_budget()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## LRC 侧依赖记录器（dispatch 含 color 第 5 参，与 LRC._dispatch_emission 签名一致）。
class _Recorder:
	extends RefCounted

	var generation: int = 1
	var pulse_active: bool = true
	var fail_dispatch: bool = false
	var next_emission_id: int = 100
	var dispatched: Array = []

	func dispatch(generation: int, form: int, cell: Vector2i, direction: Vector2i, color: int) -> int:
		dispatched.append([generation, form, cell, direction, color])
		if fail_dispatch:
			return -1
		next_emission_id += 1
		return next_emission_id

	func get_generation() -> int:
		return generation

	func is_pulse_active() -> bool:
		return pulse_active

	func finish_emission(_expected_generation: int, _emission_id: int) -> void:
		pass


## 构造 (spawner, recorder) 两件套；registry 为正式 ActiveEmissionRegistry。
func _make_harness() -> Array:
	var recorder: _Recorder = _Recorder.new()
	var registry: _Registry = _Registry.new()
	var spawner: Variant = _Spawner.new(
		registry,
		Callable(recorder, "dispatch"),
		Callable(recorder, "get_generation"),
		Callable(recorder, "is_pulse_active"),
		Callable(recorder, "finish_emission"))
	return [spawner, recorder]


## 构造分支载荷数组（机关侧恒 NONE 色，继承色由执行层盖章后传入）。
func _make_branches(count: int, color: int = -1) -> Array:
	var branches: Array = []
	for i in range(count):
		branches.append(_Result.make_branch_spec(Vector2i(3, 3), Vector2i(1, 0), color))
	return branches


## 1. 分支派生透传：RAY 形态、位置方向原样、继承色经第 5 参透传。
func _test_01_branch_dispatch_passthrough() -> void:
	const G: String = "01_分支派生透传"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	var branches: Array = _make_branches(2, _RayColor.ColorValue.RED)
	spawner.handle_ray_branches(1, 9, branches)
	_check(G, recorder.dispatched.size() == 2, "2 条分支应派生 2 个 emission，实际 %d。" % recorder.dispatched.size())
	if recorder.dispatched.size() == 2:
		var call0: Array = recorder.dispatched[0]
		_check(G, call0[0] == 1, "generation 应透传 1。")
		_check(G, call0[1] == _LightFormRay(), "派生形态应为 RAY。")
		_check(G, call0[2] == Vector2i(3, 3) and call0[3] == Vector2i(1, 0), "位置方向应原样透传。")
		_check(G, call0[4] == _RayColor.ColorValue.RED, "继承色应经 dispatch 第 5 参透传。")


## RAY 形态枚举值（经 LightEmissionTypes 读取）。
func _LightFormRay() -> int:
	return preload("res://gameplay/light/light_emission_types.gd").LightForm.RAY


## 2. generation 过期 / 脉冲非活动 no-op（不派生、不消耗预算）。
func _test_02_stale_generation_and_inactive_pulse() -> void:
	const G: String = "02_守卫no-op"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	spawner.handle_ray_branches(2, 9, _make_branches(1))
	_check(G, recorder.dispatched.is_empty(), "generation 过期分支应 no-op。")
	recorder.pulse_active = false
	spawner.handle_ray_branches(1, 9, _make_branches(1))
	_check(G, recorder.dispatched.is_empty(), "脉冲非活动分支应 no-op。")
	recorder.pulse_active = true
	spawner.handle_ray_branches(1, 9, _make_branches(1))
	_check(G, recorder.dispatched.size() == 1, "守卫恢复后分支应正常派生（前置 no-op 不耗预算）。")


## 3. dispatch 失败：不返回 emission_id、不消耗预算（同 generation 内预算不被空洞占用）。
func _test_03_dispatch_failure_does_not_consume_budget() -> void:
	const G: String = "03_失败不耗预算"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	recorder.fail_dispatch = true
	spawner.handle_ray_branches(1, 9, _make_branches(4))
	_check(G, recorder.dispatched.size() == 4, "失败派生仍应尝试 4 次。")
	recorder.fail_dispatch = false
	spawner.handle_ray_branches(1, 9, _make_branches(1))
	_check(G, recorder.dispatched.size() == 5, "失败不消耗预算：第 5 次应正常派生。")


## 4. 树级总预算 128：同 fire 内第 129 支起按阻挡处理（不再生成 emission）。
func _test_04_budget_128_cap() -> void:
	const G: String = "04_预算128"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	spawner.handle_ray_branches(1, 9, _make_branches(129))
	_check(G, recorder.dispatched.size() == 128, "预算上限 128：第 129 支应被拒绝，实际 %d。" % recorder.dispatched.size())
	spawner.handle_ray_branches(1, 9, _make_branches(1))
	_check(G, recorder.dispatched.size() == 128, "预算耗尽后同 fire 再入分支应继续拒绝。")


## 5. reset_chain 同帧归零预算（per-fire reset 语义，与链深度共用入口）。
func _test_05_reset_chain_clears_budget() -> void:
	const G: String = "05_reset_chain归零"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	spawner.handle_ray_branches(1, 9, _make_branches(128))
	_check(G, recorder.dispatched.size() == 128, "预算应耗尽于 128。")
	spawner.reset_chain()
	spawner.handle_ray_branches(1, 9, _make_branches(1))
	_check(G, recorder.dispatched.size() == 129, "reset_chain 后新 fire 预算应归零（第 129 支可派生）。")


## 6. generation 变更自动归零预算（epoch token 推进即新 fire 树）。
func _test_06_generation_advance_clears_budget() -> void:
	const G: String = "06_代推进归零"
	var harness: Array = _make_harness()
	var spawner: Variant = harness[0]
	var recorder: _Recorder = harness[1]
	spawner.handle_ray_branches(1, 9, _make_branches(128))
	_check(G, recorder.dispatched.size() == 128, "预算应耗尽于 128。")
	recorder.generation = 2
	spawner.handle_ray_branches(2, 9, _make_branches(1))
	_check(G, recorder.dispatched.size() == 129, "generation 推进后预算应自动归零（新分支可派生）。")


func _report() -> void:
	print("C-08 branch budget: %d checks, %d failures" % [_checks, _failures.size()])
	for failure in _failures:
		print("  FAIL %s" % failure)
