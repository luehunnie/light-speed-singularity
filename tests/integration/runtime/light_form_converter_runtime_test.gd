extends SceneTree

## 光形式转换器运行期端到端集成测试（阶段C-01；真实 .tscn 实例 + 真实 LRC/Driver/Spawner/Scheduler 链路）。
## 覆盖：真实 light_form_converter.tscn 实例化入树（_ready 视觉刷新不崩）+ 两份 Definition 契约
##   （预置/道具共享同一 scene；inventory_eligible 互异；道具版声明 cycle_direction 动作；direction 字段 enum_max=7）；
##   RAY→PARTICLE：RAY 停于转换器格 → 同步生成 PARTICLE emission（EMITTED 事件 cell=转换器格 direction=朝向）→
##   可控泵推进光粒沿朝向传播；PARTICLE→RAY：光粒 TERMINATE(MECHANISM_BLOCK) 于转换器格 →
##   生成 RAY emission 点亮水晶 → 脉冲聚合 COMPLETED（先 spawn 后 finish 顺序的端到端证明）；
##   背面阻挡：BACK 入射恒 BLOCK，零新 emission、零光粒、不完成关卡。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)；preload 引用避开全局 class_name 缓存问题。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _Fixture: GDScript = preload("res://tests/unit/runtime/fixtures/runtime_controller_fixture.gd")
const _Converter: GDScript = preload("res://gameplay/mechanisms/converter/light_form_converter.gd")
const _ConverterScene: PackedScene = preload("res://gameplay/mechanisms/converter/light_form_converter.tscn")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
const _Motion: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

const _GROUP_COUNT: int = 4
const _CONVERTER_ID: StringName = &"conv1"
const _CONVERTER_CELL: Vector2i = Vector2i(3, 3)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture: _Fixture = null
## 本轮实例化的真实转换器节点（树内；收尾统一 queue_free）。
var _converters: Array[Node] = []


func _initialize() -> void:
	await process_frame
	_fixture = _Fixture.new(self)
	await _test_01_real_scene_and_definitions_contract()
	_test_02_ray_to_particle_conversion()
	await _test_03_particle_to_ray_lights_crystal()
	_test_04_back_face_block_no_conversion()
	await _fixture.wait_settled(4)
	await _fixture.await_settle_pumps()
	for node: Node in _converters:
		node.queue_free()
	await _fixture.wait_settled(2)
	_fixture.cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## 实例化真实转换器场景并入树，登记占用，返回节点（resolver 经此返回给 level_query）。
func _spawn_preplaced_converter(direction_value: int) -> Node:
	var converter: Node = _ConverterScene.instantiate()
	converter.direction = direction_value as _Converter.ConverterDirection
	root.add_child(converter)
	_converters.append(converter)
	return converter


## 构造含预置转换器的 env：occupancy 登记单格占用 + resolver seam 提供节点解析（固定预放置不在放置表）。
func _make_env_with_converter(direction_value: int, light_form: int, crystal_cell: Variant) -> _Fixture._Env:
	var converter: Node = _spawn_preplaced_converter(direction_value)
	var resolver: Callable = func(id: StringName) -> Variant:
		return converter if id == _CONVERTER_ID else null
	var env: _Fixture._Env = _fixture.make_env(
		Vector2i(1, 3), Vector2i.RIGHT, crystal_cell, 1, false, light_form, [], false, resolver)
	_check("00_前置", env.occupancy.register_single_cell(_CONVERTER_ID, _CONVERTER_CELL), "occupancy 单格登记应成功。")
	return env


## 推进可控泵 until_tick 个整数 Tick（逐个 resume，不真实等待 0.1s）。
func _advance_ticks(env: _Fixture._Env, tick_count: int) -> void:
	for i: int in range(tick_count):
		env.particle_tick_pump.resume_one_tick()


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 光形式转换器运行期端到端测试摘要 ====")
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


# ===== 测试 =====

## 01. 真实场景 + Definition 契约：实例化入树 _ready 不崩、cycle 后内容状态同步；两份 Definition 共享同一 scene、
##   inventory_eligible 互异、道具版声明 cycle_direction、direction 字段 enum_max=7、场景内 DebugArrow 后备存在。
func _test_01_real_scene_and_definitions_contract() -> void:
	const G: String = "01_真实场景与Definition契约"
	var converter: Node = _spawn_preplaced_converter(0)
	await process_frame
	_check(G, converter.is_node_ready(), "真实场景实例化入树后应 ready（_ready 视觉刷新不崩）。")
	_check(G, converter.direction == 0, "默认朝向应为 RIGHT。")
	converter.cycle_direction()
	await process_frame
	_check(G, converter.direction == 1, "cycle 后朝向应为 DOWN_RIGHT。")
	var view: Node = converter.get_node("VisualView")
	_check(G, view.get_content_state() == &"down_right", "VisualView 内容状态应同步 down_right（实际 %s）。" % view.get_content_state())
	_check(G, converter.has_method("get_light_interaction_forms") and converter.has_method("interact_ray") and converter.has_method("interact_particle"),
		"真实场景节点应具备正式光交互契约面三件套。")
	var preplaced: Variant = load("res://gameplay/content/definitions/light_form_converter.tres")
	var player: Variant = load("res://gameplay/content/definitions/light_form_converter_player.tres")
	_check(G, preplaced != null and player != null, "两份 Definition 应可加载。")
	_check(G, preplaced.content_type_id == &"light_form_converter" and player.content_type_id == &"light_form_converter_player",
		"content_type_id 应互异。")
	_check(G, preplaced.inventory_eligible == false and player.inventory_eligible == true,
		"预置版不可入库存、道具版可入库存。")
	_check(G, preplaced.scene.resource_path == player.scene.resource_path,
		"两变体必须共享同一转换核心场景（总控裁决）。")
	_check(G, preplaced.light_interaction_forms == [&"RAY", &"PARTICLE"], "Definition 形态声明应为 RAY+PARTICLE。")
	_check(G, player.player_interaction_actions == [&"cycle_direction"], "道具版应声明 cycle_direction 玩家动作。")
	_check(G, preplaced.configuration_fields.size() == 1 and preplaced.configuration_fields[0].field_id == &"direction"
		and preplaced.configuration_fields[0].enum_max == 7, "direction 字段应为八向枚举（enum_max=7）。")

## 02. RAY→PARTICLE：RAY 停于转换器格 → 同步生成 PARTICLE emission（标准速度初速 + EMITTED 事件 cell=转换器格、
##   direction=转换器朝向）→ 可控泵推进光粒沿朝向继续传播。
func _test_02_ray_to_particle_conversion() -> void:
	const G: String = "02_RAY转PARTICLE"
	# 转换器朝向 DOWN：RAY 向右射入 (3,3)，出射向下。
	var env: _Fixture._Env = _make_env_with_converter(2, _LightEmissionTypes.LightForm.RAY, null)
	env.rsc.begin_runtime()
	var fired: bool = env.controller.request_fire()
	_check(G, fired, "READY RAY 发射应成功。")
	# 转换在 Ray driver dispatch 内同步发生：此刻即应存在 1 颗光粒（新 PARTICLE emission）。
	_check(G, env.controller.get_particle_active_count() == 1, "RAY 停于转换器格后应同步生成 1 颗光粒。")
	var emitted: Array = env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_EMITTED)
	if _check(G, emitted.size() == 1, "应恰好 1 条 EMITTED 事件（实际 %d）。" % emitted.size()):
		_check(G, emitted[0]["cell"] == _CONVERTER_CELL, "EMITTED cell 应为转换器格 (3,3)（实际 %s）。" % emitted[0]["cell"])
		_check(G, emitted[0]["direction"] == Vector2i(0, 1), "EMITTED direction 应为转换器朝向 (0,1)。")
		_check(G, emitted[0]["speed_tier"] == _Motion.SpeedTier.STANDARD, "RAY→PARTICLE 出射应为标准速度。")
	# 可控泵推进：STANDARD 直向首步 4 Tick → 光粒到达 (3,4)。
	_advance_ticks(env, 4)
	var snapshot: Variant = env.controller.get_particle_state_snapshot(0)
	if _check(G, snapshot != null, "推进后应存在 rid 0 光粒。"):
		_check(G, snapshot["cell"] == Vector2i(3, 4), "4 Tick 后光粒应沿朝向到达 (3,4)（实际 %s）。" % snapshot["cell"])

## 03. PARTICLE→RAY：光粒 TERMINATE(MECHANISM_BLOCK) 于转换器格 → 生成 RAY emission 点亮水晶 → 脉冲聚合 COMPLETED。
func _test_03_particle_to_ray_lights_crystal() -> void:
	const G: String = "03_PARTICLE转RAY点亮水晶"
	# 转换器朝向 RIGHT：光粒向右进入 (3,3) 转换为 RAY 继续向右，(6,3) 水晶被点亮。
	var env: _Fixture._Env = _make_env_with_converter(0, _LightEmissionTypes.LightForm.PARTICLE, Vector2i(6, 3))
	env.rsc.begin_runtime()
	_check(G, env.controller.request_fire(), "READY PARTICLE 发射应成功。")
	_check(G, env.controller.get_particle_active_count() == 1, "发射后应有 1 颗光粒。")
	# Tick 4：(2,3)；Tick 8：进入转换器格 (3,3) → TERMINATE + 转换。
	_advance_ticks(env, 8)
	_check(G, env.controller.get_particle_active_count() == 0, "转换后原光粒应终止。")
	# RAY 同步执行（转换发生在 TERMINATE 上报内）：水晶点亮；源 emission 已 finish，RAY timer 待到期 → PULSE_ACTIVE。
	_check(G, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE,
		"转换 RAY 未结束前脉冲应保持 PULSE_ACTIVE（先 spawn 后 finish）。")
	# 等 RAY visual delay（fixture 0.0s）到期回调 finish → 聚合结算 → COMPLETED。
	await _fixture.wait_settled(4)
	_check(G, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.COMPLETED,
		"水晶点亮且全部 emission 结束后应 COMPLETED（实际 %s）。"
		% env.rsc.get_current_state())

## 04. 背面阻挡：入射方向 == 朝向反向 → 恒 BLOCK，零新 emission、零光粒、关卡不完成。
func _test_04_back_face_block_no_conversion() -> void:
	const G: String = "04_背面阻挡零转换"
	# 转换器朝向 LEFT：向右射入的 RAY 打在背面 → BLOCK。
	var env: _Fixture._Env = _make_env_with_converter(4, _LightEmissionTypes.LightForm.RAY, null)
	env.rsc.begin_runtime()
	_check(G, env.controller.request_fire(), "READY RAY 发射应成功。")
	_check(G, env.controller.get_particle_active_count() == 0, "背面阻挡不得生成光粒。")
	_check(G, env.particle_visual_sink.events_of_type(_ParticleVisualEvent.TYPE_EMITTED).is_empty(), "背面阻挡不得产生 EMITTED 事件。")
	await _fixture.wait_settled(4)
	_check(G, env.controller.get_active_emission_count() == 0, "背面阻挡后不应有活动 emission。")
	_check(G, env.rsc.get_current_state() == _RuntimeInteractionTypes.RunState.MOVE_WINDOW,
		"普通 RAY 结束后应回 MOVE_WINDOW（实际 %s）。" % env.rsc.get_current_state())
