extends SceneTree

## 滤光片（LightFilter）合同定向测试（机关规则 滤光片 v0.1）。
## 覆盖：四朝向撞棱角（每朝向恰 2 平行方向 → BLOCK，不分颜色，白光/红光均撞棱角停止）；
##   滤色映射（白光→单色 COLOR_CHANGE / 同色保持 CONTINUE / 异色吸收 BLOCK，3 滤色 × 4 入射色全表）；
##   PARTICLE 恒 BLOCK；形态声明 RAY+PARTICLE；运行期零写入（R 不变量：orientation/color 恒为 authored 值）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存；
##   机关为 Node fixture（不进场景树，_ready 不触发，_refresh_visual 经 is_node_ready 安全跳过），用后 free。
##   全部失败项收集后统一退出（任一失败 quit(1)）。

const _Filter: GDScript = preload("res://gameplay/mechanisms/filters/light_filter.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _Contract: GDScript = preload("res://gameplay/light/interaction/light_interaction_contract.gd")
const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _RayContext: GDScript = preload("res://gameplay/light/interaction/ray_interaction_context.gd")
const _ParticleContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)
const _Motion: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")

const _GROUP_COUNT: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_edge_collision_all_colors()
	_test_02_filter_color_mapping()
	_test_03_particle_always_block()
	_test_04_forms_declaration()
	_test_05_runtime_zero_write()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 构造带当前颜色的 RAY Context。
func _ray_ctx(incoming: Vector2i, current_color: int) -> Variant:
	return _RayContext.create(Vector2i(2, 0), incoming, 1, 0, current_color)


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 滤光片合同测试摘要 ====")
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


## 01. 四朝向撞棱角：每朝向恰 2 平行方向 → BLOCK（不分颜色，白光/红光均撞棱角停止）。
func _test_01_edge_collision_all_colors() -> void:
	const G: String = "01_撞棱角"
	var filter: Variant = _Filter.new()
	var orientations: Array = [
		_Filter.FilterOrientation.VERTICAL, _Filter.FilterOrientation.HORIZONTAL,
		_Filter.FilterOrientation.SLASH, _Filter.FilterOrientation.BACKSLASH,
	]
	var tangents: Array[Vector2i] = [
		Vector2i(0, -1), Vector2i(1, 0), Vector2i(1, -1), Vector2i(1, 1),
	]
	for i: int in range(4):
		filter.set_orientation(orientations[i])
		var tangent: Vector2i = tangents[i]
		var on_axis_count: int = 0
		for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
			var incoming: Vector2i = _DirectionDomain.to_vector(token)
			var collision: bool = filter.is_edge_collision(incoming)
			_check(G, collision == _DirectionDomain.same_axis(incoming, tangent),
				"朝向 %d 入射 %s 撞棱角判定应等于 same_axis 事实。" % [i, token])
			if collision:
				on_axis_count += 1
				var r_white: Variant = _Contract.dispatch_ray(filter, _ray_ctx(incoming, _RayColor.ColorValue.WHITE))
				_check(G, r_white.decision == _Result.Decision.BLOCK,
					"朝向 %d 白光入射 %s 撞棱角期望 BLOCK。" % [i, token])
				var r_red: Variant = _Contract.dispatch_ray(filter, _ray_ctx(incoming, _RayColor.ColorValue.RED))
				_check(G, r_red.decision == _Result.Decision.BLOCK,
					"朝向 %d 红光入射 %s 撞棱角期望 BLOCK（不分颜色）。" % [i, token])
		_check(G, on_axis_count == 2, "朝向 %d 平行方向数期望 2，实际 %d。" % [i, on_axis_count])
	filter.free()


## 02. 滤色映射：白光→单色（COLOR_CHANGE）/ 同色保持（CONTINUE 无变色）/ 异色吸收（BLOCK），3 滤色 × 4 入射色全表。
func _test_02_filter_color_mapping() -> void:
	const G: String = "02_滤色映射"
	var filter: Variant = _Filter.new()
	filter.set_orientation(_Filter.FilterOrientation.VERTICAL)
	var incoming: Vector2i = Vector2i(1, 0)
	var filters: Array = [
		_Filter.FilterColor.RED, _Filter.FilterColor.GREEN, _Filter.FilterColor.BLUE,
	]
	var filter_values: Array = [
		_RayColor.ColorValue.RED, _RayColor.ColorValue.GREEN, _RayColor.ColorValue.BLUE,
	]
	var names: Array = ["RED", "GREEN", "BLUE"]
	var ray_values: Array = [
		_RayColor.ColorValue.WHITE, _RayColor.ColorValue.RED,
		_RayColor.ColorValue.GREEN, _RayColor.ColorValue.BLUE,
	]
	var ray_names: Array = ["WHITE", "RED", "GREEN", "BLUE"]
	for fi: int in range(3):
		filter.set_color(filters[fi])
		var fv: int = filter_values[fi]
		for ri: int in range(4):
			var ic: int = ray_values[ri]
			var result: Variant = _Contract.dispatch_ray(filter, _ray_ctx(incoming, ic))
			if ic == _RayColor.ColorValue.WHITE:
				_check(G, result.decision == _Result.Decision.CONTINUE
					and result.get_color_change() == fv,
					"%s×白光 期望 CONTINUE + COLOR_CHANGE(%s)。" % [names[fi], names[fi]])
			elif ic == fv:
				_check(G, result.decision == _Result.Decision.CONTINUE
					and result.get_color_change() == _RayColor.ColorValue.NONE,
					"%s×%s 同色 期望 CONTINUE 保持无变色。" % [names[fi], ray_names[ri]])
			else:
				_check(G, result.decision == _Result.Decision.BLOCK,
					"%s×%s 异色 期望 BLOCK 吸收。" % [names[fi], ray_names[ri]])
	filter.free()


## 03. PARTICLE 恒 BLOCK（任意方向）。
func _test_03_particle_always_block() -> void:
	const G: String = "03_光粒阻挡"
	var filter: Variant = _Filter.new()
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		var incoming: Vector2i = _DirectionDomain.to_vector(token)
		var p_ctx: Variant = _ParticleContext.create(Vector2i(2, 0), incoming, 1, 0, _Motion.SpeedTier.STANDARD, 7)
		var result: Variant = _Contract.dispatch_particle(filter, p_ctx)
		_check(G, result.decision == _Result.Decision.BLOCK,
			"光粒入射 %s 期望恒 BLOCK。" % token)
	filter.free()


## 04. 形态声明 RAY+PARTICLE。
func _test_04_forms_declaration() -> void:
	const G: String = "04_形态声明"
	var filter: Variant = _Filter.new()
	_check(G, filter.get_light_interaction_forms() == [&"RAY", &"PARTICLE"],
		"形态声明应为 RAY+PARTICLE。")
	filter.free()


## 05. 运行期零写入：全部交互后 orientation/color 恒为 authored 值。
func _test_05_runtime_zero_write() -> void:
	const G: String = "05_运行期零写入"
	var filter: Variant = _Filter.new()
	filter.set_orientation(_Filter.FilterOrientation.BACKSLASH)
	filter.set_color(_Filter.FilterColor.BLUE)
	_Contract.dispatch_ray(filter, _ray_ctx(Vector2i(1, 0), _RayColor.ColorValue.WHITE))
	_Contract.dispatch_ray(filter, _ray_ctx(Vector2i(1, 1), _RayColor.ColorValue.RED))
	_Contract.dispatch_particle(filter, _ParticleContext.create(Vector2i(2, 0), Vector2i(1, 0), 1, 0, _Motion.SpeedTier.STANDARD, 7))
	_check(G, filter.orientation == _Filter.FilterOrientation.BACKSLASH,
		"交互后 orientation 应保持 authored BACKSLASH。")
	_check(G, filter.color == _Filter.FilterColor.BLUE,
		"交互后 color 应保持 authored BLUE。")
	filter.free()
