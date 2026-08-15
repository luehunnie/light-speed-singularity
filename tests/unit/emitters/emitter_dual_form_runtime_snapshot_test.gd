extends SceneTree

## Emitter 双形态 Runtime 快照合同定向测试（D7-4 B3a）。
## 覆盖：公共 LightForm 数值、EmitterConfigNode.LightForm 兼容别名与公共契约对齐（无第二份真值）、
##   旧四光粒方向数值冻结、新增四斜向、八方向经公共 is_valid_direction 合法、ZERO 非法、
##   EmitterConfigNode PARTICLE 快照可读、FixedEmitter RAY/PARTICLE 双形态快照、切换形态无陈旧方向、
##   本批不创建 ParticleRuntimeState / 调度器。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 通过 preload 引用模块避开全局 class_name 缓存问题；非法值用例不计入失败。

const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _FireRequest: GDScript = preload("res://gameplay/light/fire_request.gd")


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0

const _GROUP_COUNT: int = 11


func _initialize() -> void:
	_test_01_public_lightform_values()
	_test_02_config_lightform_aliases_match_public()
	_test_03_old_four_particle_direction_values_frozen()
	_test_04_new_four_diagonal_particle_directions()
	_test_05_all_eight_particle_directions_valid_via_public()
	_test_06_zero_not_valid_active_direction()
	_test_07_fixed_emitter_ray_snapshot_and_fire_request()
	_test_08_fixed_emitter_particle_snapshot_no_fire_request()
	_test_09_form_switch_no_stale_direction()
	_test_10_no_particle_runtime_state_or_scheduler()
	_test_11_config_particle_snapshot_readable()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 公共 LightForm 数值冻结：RAY=0 / PARTICLE=1。
func _test_01_public_lightform_values() -> void:
	const G: String = "01_公共LightForm数值"
	_check(G, _LightEmissionTypes.LightForm.RAY == 0, "公共 RAY 期望 0，实际 %d。" % _LightEmissionTypes.LightForm.RAY)
	_check(G, _LightEmissionTypes.LightForm.PARTICLE == 1, "公共 PARTICLE 期望 1，实际 %d。" % _LightEmissionTypes.LightForm.PARTICLE)


## 2. EmitterConfigNode.LightForm 兼容别名与公共契约数值逐一对齐（无第二份独立真值）。
func _test_02_config_lightform_aliases_match_public() -> void:
	const G: String = "02_LightForm别名对齐公共"
	_check(G, _EmitterConfigNode.LightForm.RAY == _LightEmissionTypes.LightForm.RAY, "EmitterConfigNode.LightForm.RAY 应等于公共 RAY。")
	_check(G, _EmitterConfigNode.LightForm.PARTICLE == _LightEmissionTypes.LightForm.PARTICLE, "EmitterConfigNode.LightForm.PARTICLE 应等于公共 PARTICLE。")
	_check(G, _EmitterConfigNode.LightForm.RAY == 0, "兼容别名 RAY 期望 0（旧场景序列化兼容）。")
	_check(G, _EmitterConfigNode.LightForm.PARTICLE == 1, "兼容别名 PARTICLE 期望 1（旧场景序列化兼容）。")


## 3. 旧四个 ParticleDirection 数值冻结（场景兼容）：RIGHT=0 / DOWN=1 / LEFT=2 / UP=3。
func _test_03_old_four_particle_direction_values_frozen() -> void:
	const G: String = "03_旧四光粒方向数值冻结"
	_check(G, _EmitterConfigNode.ParticleDirection.RIGHT == 0, "RIGHT 期望 0，实际 %d。" % _EmitterConfigNode.ParticleDirection.RIGHT)
	_check(G, _EmitterConfigNode.ParticleDirection.DOWN == 1, "DOWN 期望 1，实际 %d。" % _EmitterConfigNode.ParticleDirection.DOWN)
	_check(G, _EmitterConfigNode.ParticleDirection.LEFT == 2, "LEFT 期望 2，实际 %d。" % _EmitterConfigNode.ParticleDirection.LEFT)
	_check(G, _EmitterConfigNode.ParticleDirection.UP == 3, "UP 期望 3，实际 %d。" % _EmitterConfigNode.ParticleDirection.UP)


## 4. 新增四个斜向 ParticleDirection 存在、映射正确，且数值追加在旧四正方向之后（不重排旧值）。
func _test_04_new_four_diagonal_particle_directions() -> void:
	const G: String = "04_新增四斜向"
	var cases: Array = [
		[_EmitterConfigNode.ParticleDirection.DOWN_RIGHT, Vector2i(1, 1)],
		[_EmitterConfigNode.ParticleDirection.DOWN_LEFT, Vector2i(-1, 1)],
		[_EmitterConfigNode.ParticleDirection.UP_LEFT, Vector2i(-1, -1)],
		[_EmitterConfigNode.ParticleDirection.UP_RIGHT, Vector2i(1, -1)],
	]
	for case: Array in cases:
		var d: int = case[0]
		var expected: Vector2i = case[1]
		var got: Vector2i = _EmitterConfigNode.particle_direction_to_vector(d)
		_check(G, got == expected, "斜向 ParticleDirection %d 应映射到 %s，实际 %s。" % [d, expected, got])
	_check(G, _EmitterConfigNode.ParticleDirection.DOWN_RIGHT > _EmitterConfigNode.ParticleDirection.UP, "斜向数值应追加在旧四正方向之后，不应重排旧值。")


## 5. 八个 ParticleDirection 映射向量全部经公共 is_valid_direction 判为合法。
func _test_05_all_eight_particle_directions_valid_via_public() -> void:
	const G: String = "05_八光粒方向经公共合法"
	for d: int in _EmitterConfigNode.ParticleDirection.values():
		var v: Vector2i = _EmitterConfigNode.particle_direction_to_vector(d)
		_check(G, _LightEmissionTypes.is_valid_direction(v), "ParticleDirection %d 向量 %s 应经公共 is_valid_direction 合法。" % [d, v])


## 6. Vector2i.ZERO 不成为合法 active direction（公共边界拒绝，FixedEmitter 同步拒绝）。
func _test_06_zero_not_valid_active_direction() -> void:
	const G: String = "06_ZERO非法"
	_check(G, _LightEmissionTypes.is_valid_direction(Vector2i.ZERO) == false, "ZERO 应被公共 is_valid_direction 拒绝。")
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT)
	_check(G, emitter.try_set_direction(Vector2i.ZERO) == false, "FixedEmitter.try_set_direction(ZERO) 应返回 false。")
	_check(G, emitter.get_direction() == Vector2i.RIGHT, "ZERO 拒绝后方向应保持 RIGHT。")


## 7. FixedEmitter RAY：form=RAY、cell/direction 正确、build_fire_request 仍工作、max_steps 不变。
func _test_07_fixed_emitter_ray_snapshot_and_fire_request() -> void:
	const G: String = "07_FixedEmitter_RAY快照与请求"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(2, 4), Vector2i.RIGHT)
	_check(G, emitter.get_light_form() == _LightEmissionTypes.LightForm.RAY, "默认 form 应为 RAY，实际 %d。" % [emitter.get_light_form()])
	_check(G, emitter.get_cell() == Vector2i(2, 4), "cell 期望 (2,4)，实际 %s。" % [emitter.get_cell()])
	_check(G, emitter.get_direction() == Vector2i.RIGHT, "direction 期望 RIGHT，实际 %s。" % [emitter.get_direction()])
	var request: _FireRequest = emitter.build_fire_request(128)
	if _check(G, request != null, "RAY 合法方向 build_fire_request 不应返回 null。"):
		_check(G, request.get_start_cell() == Vector2i(2, 4), "start_cell 期望 (2,4)，实际 %s。" % [request.get_start_cell()])
		_check(G, request.get_direction() == Vector2i.RIGHT, "request direction 期望 RIGHT，实际 %s。" % [request.get_direction()])
		_check(G, request.get_max_steps() == 128, "max_steps 期望 128，实际 %d。" % [request.get_max_steps()])
	# max_steps 边界与旧行为一致。
	var req_zero: _FireRequest = emitter.build_fire_request(0)
	if _check(G, req_zero != null, "max_steps=0 不应返回 null。"):
		_check(G, req_zero.get_max_steps() == 0, "max_steps=0 应原样保存，实际 %d。" % [req_zero.get_max_steps()])


## 8. FixedEmitter PARTICLE：form=PARTICLE、cell 正确、方向为合法八方向、不需要 FireRequest。
func _test_08_fixed_emitter_particle_snapshot_no_fire_request() -> void:
	const G: String = "08_FixedEmitter_PARTICLE快照"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(3, 5), Vector2i(1, 1), _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, emitter.get_light_form() == _LightEmissionTypes.LightForm.PARTICLE, "form 期望 PARTICLE，实际 %d。" % [emitter.get_light_form()])
	_check(G, emitter.get_cell() == Vector2i(3, 5), "cell 期望 (3,5)，实际 %s。" % [emitter.get_cell()])
	_check(G, emitter.get_direction() == Vector2i(1, 1), "direction 期望 (1,1)，实际 %s。" % [emitter.get_direction()])
	_check(G, _LightEmissionTypes.is_valid_direction(emitter.get_direction()), "PARTICLE active direction 应为合法八方向。")
	# FireRequest 为 Ray-only：PARTICLE 形态不构建 Ray 请求。
	var request: Variant = emitter.build_fire_request(128)
	_check(G, request == null, "PARTICLE 形态 build_fire_request 应返回 null（FireRequest Ray-only），实际非 null。")


## 9. 切换/配置不同 form 后 Runtime 快照不返回另一形态的陈旧方向。
func _test_09_form_switch_no_stale_direction() -> void:
	const G: String = "09_形态切换无陈旧方向"
	# EmitterConfigNode：两形态方向分开保存，active 随形态切换不串扰。
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(G, config.get_active_direction_vector() == Vector2i(0, -1), "PARTICLE active 应取光粒 UP=(0,-1)，实际 %s。" % [config.get_active_direction_vector()])
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(G, config.get_active_direction_vector() == Vector2i(0, 1), "切回 RAY active 应取光线 DOWN=(0,1)，无陈旧光粒方向，实际 %s。" % [config.get_active_direction_vector()])
	config.free()
	# FixedEmitter：单方向字段，RAY 与 PARTICLE 两实例互不串扰。
	var ray_e: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT, _LightEmissionTypes.LightForm.RAY)
	var particle_e: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i(1, -1), _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, ray_e.get_light_form() == _LightEmissionTypes.LightForm.RAY and ray_e.get_direction() == Vector2i.RIGHT, "RAY 实例快照应不串扰。")
	_check(G, particle_e.get_light_form() == _LightEmissionTypes.LightForm.PARTICLE and particle_e.get_direction() == Vector2i(1, -1), "PARTICLE 实例快照应不串扰。")


## 10. 本批不创建 ParticleRuntimeState / 调度器：无 request_fire / tick 入口，PARTICLE 不构建 FireRequest，快照为纯契约类型。
func _test_10_no_particle_runtime_state_or_scheduler() -> void:
	const G: String = "10_不创建Particle运行期对象"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i(1, 1), _LightEmissionTypes.LightForm.PARTICLE)
	# 无调度 / 发射执行入口。
	_check(G, not emitter.has_method("request_fire"), "不应提供 request_fire 入口。")
	_check(G, not emitter.has_method("request_fire_particle"), "不应提供 request_fire_particle 入口。")
	_check(G, not emitter.has_method("tick"), "不应提供 tick 调度入口。")
	# 快照返回纯契约类型（int / Vector2i），非 ParticleRuntimeState。
	_check(G, emitter.get_light_form() == _LightEmissionTypes.LightForm.PARTICLE, "快照 light_form 应为 int 形态值 PARTICLE。")
	_check(G, typeof(emitter.get_cell()) == TYPE_VECTOR2I, "快照 emitter_cell 应为 Vector2i。")
	_check(G, typeof(emitter.get_direction()) == TYPE_VECTOR2I, "快照 active_direction 应为 Vector2i。")
	# PARTICLE 形态不产出 FireRequest（Ray-only），不创建 ParticleRuntimeState / 调度器。
	_check(G, emitter.build_fire_request(128) == null, "PARTICLE 形态不应产出 FireRequest。")


## 11. EmitterConfigNode PARTICLE 形态 Runtime 快照三项只读事实可读取；执行阶段闸门 B3b-1 起对 PARTICLE 返回 true（与真实 Runtime 能力同步）。
func _test_11_config_particle_snapshot_readable() -> void:
	const G: String = "11_EmitterConfigNode_PARTICLE快照可读"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.DOWN_RIGHT
	config.cell = Vector2i(2, 3)
	_check(G, config.get_default_light_form() == _EmitterConfigNode.LightForm.PARTICLE, "快照 light_form 应为 PARTICLE。")
	_check(G, config.get_active_direction_vector() == Vector2i(1, 1), "快照 active_direction 应为光粒 DOWN_RIGHT=(1,1)，实际 %s。" % [config.get_active_direction_vector()])
	_check(G, config.get_cell() == Vector2i(2, 3), "快照 emitter_cell 应为 (2,3)，实际 %s。" % [config.get_cell()])
	# B3b-1：is_runtime_form_supported 对 PARTICLE 返回 true（PARTICLE 已接 Runtime，与真实能力同步）；RAY 同样 true。
	_check(G, config.is_runtime_form_supported() == true, "PARTICLE 执行阶段闸门 B3b-1 起应为 true（与真实 Runtime 能力同步）。")
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(G, config.is_runtime_form_supported() == true, "RAY 执行阶段闸门应保持 true。")
	config.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(group: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== Emitter 双形态 Runtime 快照合同 测试摘要（D7-4 B3a）====")
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
