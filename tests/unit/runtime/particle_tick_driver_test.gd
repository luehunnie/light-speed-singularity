extends SceneTree

## ParticleTickDriver 单元测试（M4-E2 settle contract 拆分 + pump 重入安全）。
## 覆盖 spec 十三.27~29：
##   - 同 generation 第二 Particle 不启动第二 pump（pump 单链；start_pump_if_idle 在 _pump_active 已真时复用）。
##   - drain 后 pump 正确停止（is_drained → on_drained 回调 + 返回 false 停链）。
##   - 【重入安全】drained callback 期间同步发射新 Particle 时，新 Particle 必须获得有效 pump（杜绝“有粒无泵”）。
##     证明 driver 在 drained_now 时**先**清 _pump_active 再回调上层——上层 callback 内 start_pump_if_idle 看到 flag=false 启动新泵。
## 直接构造 ParticleTickDriver + 真实 ParticleScheduler + 可控泵 + stub world_query / objective；不经 LRC，聚焦 driver 合同。
## 由 Godot --script 运行，全部 quit(0)，任一失败 quit(1)；通过 preload 引用避开全局 class_name 缓存问题。

const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _ParticleTickDriver: GDScript = preload("res://gameplay/runtime/particle_tick_driver.gd")
const _ControllablePump: GDScript = preload("res://tests/unit/runtime/fixtures/controllable_particle_tick_pump.gd")

const _GROUP_COUNT: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


# ===== stub =====

## 只读世界查询 stub（16x16 边界，无墙/水晶/机关）：供 scheduler executor 求值；particle @ (14,3) RIGHT tick8 越界 terminate。
class _StubWorldQuery extends RefCounted:
	func is_in_bounds(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.x < 16 and cell.y >= 0 and cell.y < 16
	func is_wall_cell(_cell: Vector2i) -> bool:
		return false
	func has_crystal_at(_cell: Vector2i) -> bool:
		return false
	func get_light_mechanism_at(_cell: Vector2i) -> Variant:
		return null


## 无副作用 Objective stub（driver BatchEvent MOVE.has_crystal → try_activate_crystal_at；本测试无水晶，仅满足签名）。
class _StubObjective extends RefCounted:
	var activate_calls: int = 0
	func try_activate_crystal_at(_cell: Vector2i) -> void:
		activate_calls += 1


## 重入 sink：on_drained 回调内同步 emit 新 Particle + start_pump_if_idle（模拟上层在 drained callback 中产生新粒）。
## 持有 scheduler/driver 引用（driver 在构造后回填，避开构造期循环依赖）；记录重入行为供断言。
## emitted flag 保证只重入 emit 一次——避免新粒再次 drain 触发无限级联（本测试聚焦首次重入的 pump 一致性，非级联行为）。
## emit_on_terminate（M4-E2.1 stale drained 测试）：on_particle_terminated 内同步 emit 新粒 + start_pump（spec 警告的 TERMINATE-callback 重入场景）。
class _ReentrantSink extends RefCounted:
	var scheduler: Variant = null
	var driver: Variant = null
	var tree: SceneTree = null
	var on_drained_calls: int = 0
	var on_terminated_calls: int = 0
	var last_terminated_runtime: int = -1
	var emitted: bool = false
	var emit_on_terminate: bool = false
	## on_particle_terminated：记录；emit_on_terminate 时同步 emit 新 Particle @ (1,1) RIGHT + start_pump（spec 重入场景；emitted flag 保证只重入一次）。
	func on_particle_terminated(_expected_generation: int, runtime_id: int) -> void:
		on_terminated_calls += 1
		last_terminated_runtime = runtime_id
		if emit_on_terminate and not emitted and scheduler != null and driver != null:
			emitted = true
			scheduler.emit_particle(Vector2i(1, 1), Vector2i.RIGHT)
			driver.start_pump_if_idle(tree, 1)
	## on_drained：同步 emit 新 Particle @ (14,3) RIGHT + start_pump_if_idle（这正是 spec 警告的重入场景）。emitted flag 保证只重入一次。
	func on_drained(_expected_generation: int) -> void:
		on_drained_calls += 1
		if not emitted and scheduler != null and driver != null:
			emitted = true
			scheduler.emit_particle(Vector2i(14, 3), Vector2i.RIGHT)
			driver.start_pump_if_idle(tree, 1)


func _initialize() -> void:
	await process_frame
	_test_01_second_particle_same_generation_no_second_pump()
	_test_02_drain_stops_pump_and_calls_on_drained()
	_test_03_terminated_event_reports_runtime_id()
	_test_04_drained_callback_new_particle_gets_pump()
	_test_05_terminated_callback_new_particle_no_stale_drained()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试 =====

## 27.（spec 十三.27）同 generation 第二 Particle 不启动第二 pump：start_pump_if_idle 在 _pump_active 已真时复用，active_chain_count 仍 1。
func _test_01_second_particle_same_generation_no_second_pump() -> void:
	const NAME: String = "01_同generation第二Particle不启第二pump"
	var world: _StubWorldQuery = _StubWorldQuery.new()
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(world)
	var pump: _ControllablePump = _ControllablePump.new()
	var objective: _StubObjective = _StubObjective.new()
	var driver: _ParticleTickDriver = _ParticleTickDriver.new(
		scheduler, pump, objective, Callable(self, "_noop_publish"), Callable(self, "_const_gen_1"), Callable(self, "_always_true"),
		Callable(), Callable())
	scheduler.begin_generation(1)
	scheduler.emit_particle(Vector2i(1, 3), Vector2i.RIGHT)
	driver.start_pump_if_idle(self, 1)
	_check(NAME, pump.active_chain_count() == 1, "首颗后 pump 链期望 1。")
	# 同 generation 第二颗 emit + 再 start_pump_if_idle：_pump_active 已真 → 复用，不启动第二链。
	scheduler.emit_particle(Vector2i(1, 5), Vector2i.RIGHT)
	driver.start_pump_if_idle(self, 1)
	_check(NAME, pump.active_chain_count() == 1, "同 generation 第二 Particle 不应启动第二 pump，链仍期望 1，实际 %d。" % [pump.active_chain_count()])
	_check(NAME, scheduler.get_active_count() == 2, "两颗粒子并存期望 2。")


## 28.（spec 十三.28）drain 后 pump 正确停止：单粒越界 terminate → is_drained → on_drained 回调 + 返回 false 停链；额外 resume 不再推进。
func _test_02_drain_stops_pump_and_calls_on_drained() -> void:
	const NAME: String = "02_drain后pump停止并回调on_drained"
	var world: _StubWorldQuery = _StubWorldQuery.new()
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(world)
	var pump: _ControllablePump = _ControllablePump.new()
	var objective: _StubObjective = _StubObjective.new()
	var sink: _ReentrantSink = _ReentrantSink.new()
	sink.scheduler = null  # 本测试 on_drained 不重入（不 emit 新粒）。
	var driver: _ParticleTickDriver = _ParticleTickDriver.new(
		scheduler, pump, objective, Callable(self, "_noop_publish"), Callable(self, "_const_gen_1"), Callable(self, "_always_true"),
		Callable(sink, "on_particle_terminated"), Callable(sink, "on_drained"))
	sink.driver = driver
	sink.tree = self
	scheduler.begin_generation(1)
	scheduler.emit_particle(Vector2i(14, 3), Vector2i.RIGHT)  # tick8 越界 terminate。
	driver.start_pump_if_idle(self, 1)
	# 推进到 drain：resume 返回 false 后链停（sink.on_drained 不 emit 新粒，故真 drain）。
	var any: bool = true
	var guard: int = 0
	while any and guard < 20:
		any = pump.resume_one_tick()
		guard += 1
	_check(NAME, scheduler.get_active_count() == 0, "drain 后光粒期望 0。")
	_check(NAME, pump.active_chain_count() == 0, "drain 后 pump 链期望 0。")
	_check(NAME, sink.on_drained_calls == 1, "on_drained 应被调用 1 次，实际 %d。" % [sink.on_drained_calls])
	_check(NAME, sink.on_terminated_calls == 1, "on_particle_terminated 应上报 1 次（runtime0 TERMINATE）。")
	_check(NAME, sink.last_terminated_runtime == 0, "上报的 runtime_id 期望 0。")


## （spec 五）Particle TERMINATE 逐 runtime 上报：on_tick 对每条 TERMINATE BatchEvent 调 on_particle_terminated(expected_generation, runtime_id)。
func _test_03_terminated_event_reports_runtime_id() -> void:
	const NAME: String = "03_TERMINATE逐runtime上报"
	var world: _StubWorldQuery = _StubWorldQuery.new()
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(world)
	var pump: _ControllablePump = _ControllablePump.new()
	var objective: _StubObjective = _StubObjective.new()
	var sink: _ReentrantSink = _ReentrantSink.new()
	sink.scheduler = null
	var driver: _ParticleTickDriver = _ParticleTickDriver.new(
		scheduler, pump, objective, Callable(self, "_noop_publish"), Callable(self, "_const_gen_1"), Callable(self, "_always_true"),
		Callable(sink, "on_particle_terminated"), Callable(sink, "on_drained"))
	sink.driver = driver
	sink.tree = self
	scheduler.begin_generation(1)
	# 两颗粒子：runtime0 @ (14,3) RIGHT tick8 terminate；runtime1 @ (1,1) RIGHT tick8 MOVE 不 terminate。
	scheduler.emit_particle(Vector2i(14, 3), Vector2i.RIGHT)
	scheduler.emit_particle(Vector2i(1, 1), Vector2i.RIGHT)
	driver.start_pump_if_idle(self, 1)
	# 推进 8 Tick：runtime0 越界 terminate（上报 runtime_id 0）；runtime1 MOVE 不上报。
	for i in 8:
		var cont: bool = pump.resume_one_tick()
		if not cont:
			break
	_check(NAME, sink.on_terminated_calls == 1, "tick8 应只上报 runtime0 的 TERMINATE（1 次），实际 %d。" % [sink.on_terminated_calls])
	_check(NAME, sink.last_terminated_runtime == 0, "上报的 runtime_id 期望 0。")
	_check(NAME, scheduler.get_active_count() == 1, "runtime1 仍 active，期望 1。")


## 29.（spec 十三.29 重入安全）drained callback 期间同步 emit 新 Particle：新 Particle 必须获得有效 pump（active_chain_count==1，scheduler 仍有 1 粒），杜绝“有粒无泵”。
##    证明 driver 在 drained_now 时先清 _pump_active 再回调——sink.on_drained 内 start_pump_if_idle 看到 flag=false 启动新泵。若 driver 清 flag 顺序错误（回调后才清），新泵不启动 → active_chain_count==0 → 测试失败。
func _test_04_drained_callback_new_particle_gets_pump() -> void:
	const NAME: String = "04_drained回调新Particle获得pump"
	var world: _StubWorldQuery = _StubWorldQuery.new()
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(world)
	var pump: _ControllablePump = _ControllablePump.new()
	var objective: _StubObjective = _StubObjective.new()
	var sink: _ReentrantSink = _ReentrantSink.new()
	sink.scheduler = scheduler  # on_drained 将 emit 新粒 + start_pump_if_idle（重入）。
	var driver: _ParticleTickDriver = _ParticleTickDriver.new(
		scheduler, pump, objective, Callable(self, "_noop_publish"), Callable(self, "_const_gen_1"), Callable(self, "_always_true"),
		Callable(sink, "on_particle_terminated"), Callable(sink, "on_drained"))
	sink.driver = driver
	sink.tree = self
	scheduler.begin_generation(1)
	scheduler.emit_particle(Vector2i(14, 3), Vector2i.RIGHT)  # tick8 越界 terminate → drained_now → on_drained 重入 emit 新粒。
	driver.start_pump_if_idle(self, 1)  # chain 1。
	# 推进恰好到 tick8（8 次 resume；break-on-false 兼容链停止）：runtime0 terminate → drained_now=true → 清 flag → on_drained（emit runtime1 + start_pump → 新 chain 2）。
	# emitted flag 保证只重入一次，故 on_drained_calls==1（不级联）。
	for i in 8:
		if not pump.resume_one_tick():
			break
	_check(NAME, sink.on_drained_calls == 1, "on_drained 应被调用 1 次，实际 %d。" % [sink.on_drained_calls])
	_check(NAME, sink.last_terminated_runtime == 0, "上报 terminate 的 runtime_id 期望 0。")
	_check(NAME, scheduler.get_active_count() == 1, "重入 emit 的新粒应存在（active 期望 1），实际 %d。" % [scheduler.get_active_count()])
	_check(NAME, pump.active_chain_count() == 1, "新粒必须有有效 pump（active_chain 期望 1，杜绝有粒无泵），实际 %d。" % [pump.active_chain_count()])
	_check(NAME, sink.emitted, "on_drained 应已触发重入 emit。")


## （M4-E2.1 stale drained 修复）TERMINATE callback 同步创建新 Particle：新泵成功启动（active_chain==1）、旧链 return false 停止、on_drained 不报告（杜绝 stale on_drained 与“有粒无泵”）。
##    证明 on_tick 在 drained_provisional 清 flag + 跑完 TERMINATE callback 后**重新校验** is_drained()——callback 已 emit 新粒致不再 drained → 跳过 on_drained。
##    若 driver 未重校验（用 drained_provisional 直接触发 on_drained），on_drained_calls 会 ==1 → 测试失败。
func _test_05_terminated_callback_new_particle_no_stale_drained() -> void:
	const NAME: String = "05_TERMINATE回调新Particle不报告drained"
	var world: _StubWorldQuery = _StubWorldQuery.new()
	var scheduler: _ParticleScheduler = _ParticleScheduler.new(world)
	var pump: _ControllablePump = _ControllablePump.new()
	var objective: _StubObjective = _StubObjective.new()
	var sink: _ReentrantSink = _ReentrantSink.new()
	sink.scheduler = scheduler
	sink.emit_on_terminate = true  # on_particle_terminated 内同步 emit 新粒 @ (1,1) RIGHT + start_pump（重入）。
	var driver: _ParticleTickDriver = _ParticleTickDriver.new(
		scheduler, pump, objective, Callable(self, "_noop_publish"), Callable(self, "_const_gen_1"), Callable(self, "_always_true"),
		Callable(sink, "on_particle_terminated"), Callable(sink, "on_drained"))
	sink.driver = driver
	sink.tree = self
	scheduler.begin_generation(1)
	scheduler.emit_particle(Vector2i(14, 3), Vector2i.RIGHT)  # tick8 越界 terminate → on_particle_terminated 重入 emit 新粒。
	driver.start_pump_if_idle(self, 1)  # chain A。
	# 推进 8 Tick：A 越界 terminate（drained_provisional=true → 清 flag → callback emit B + start_pump → 重校验 is_drained()==false → 不报告 drained → 旧链 return false）。
	for i in 8:
		if not pump.resume_one_tick():
			break
	_check(NAME, sink.on_terminated_calls >= 1, "on_particle_terminated 应至少上报 1 次（runtime0 TERMINATE），实际 %d。" % [sink.on_terminated_calls])
	_check(NAME, sink.on_drained_calls == 0, "stale drained 修复：TERMINATE callback 创建新粒后不应报告 on_drained，实际 %d 次。" % [sink.on_drained_calls])
	_check(NAME, scheduler.get_active_count() == 1, "重入 emit 的新粒应存在（active 期望 1），实际 %d。" % [scheduler.get_active_count()])
	_check(NAME, pump.active_chain_count() == 1, "新泵应成功启动（active_chain 期望 1，杜绝有粒无泵），实际 %d。" % [pump.active_chain_count()])
	_check(NAME, sink.emitted, "on_particle_terminated 应已触发重入 emit。")


# ===== Callable stub =====

func _const_gen_1() -> int:
	return 1


func _always_true() -> bool:
	return true


func _noop_publish(_event: Dictionary) -> void:
	pass


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleTickDriver 测试摘要（M4-E2 settle 拆分 + 重入）====")
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
