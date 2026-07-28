extends SceneTree

## FixedEmitter 定向自动测试（Day 2 D2-E）：只通过公开接口观察行为，覆盖格子/方向持有、FireRequest 数据、
## try_set_direction 合法与非法、非法初始方向保留与无法构建请求、无移动入口与 max_steps 边界。
## tests/unit 下 extends SceneTree 的 headless 脚本，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 关键边界：全部失败项收集后统一退出（任一失败 quit(1)）；不读取私有字段，无移动入口用 has_method 判定。


const _FixedEmitter: GDScript = preload("res://gameplay/mechanisms/emitters/fixed_emitter.gd")
const _FireRequest: GDScript = preload("res://gameplay/light/fire_request.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：运行全部测试后统一报告并退出。
func _initialize() -> void:
	_test_01_retains_initial_cell()
	_test_02_retains_valid_direction()
	_test_03_fire_request_start_cell()
	_test_04_fire_request_direction()
	_test_05_fire_request_max_steps()
	_test_06_try_set_direction_valid()
	_test_07_try_set_direction_invalid_keeps_old()
	_test_08_invalid_initial_direction_retained()
	_test_09_invalid_initial_direction_no_request()
	_test_10_no_movement_entry()
	_test_11_max_steps_boundary()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 保存初始 cell：构造后 get_cell() 等于传入初始格。
func _test_01_retains_initial_cell() -> void:
	const NAME: String = "01_保存初始cell"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(1, 3), Vector2i.RIGHT)
	_check(NAME, emitter.get_cell() == Vector2i(1, 3), "get_cell 期望 (1,3)，实际 %s。" % [emitter.get_cell()])


## 2. 保存八方向中的合法方向：构造后 get_direction() 等于传入合法方向（取 UP 代表八方向之一）。
func _test_02_retains_valid_direction() -> void:
	const NAME: String = "02_保存合法方向"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.UP)
	_check(NAME, emitter.get_direction() == Vector2i.UP, "get_direction 期望 UP，实际 %s。" % [emitter.get_direction()])


## 3. build_fire_request 返回正确起点：合法方向下 request.get_start_cell() 等于发射器格。
func _test_03_fire_request_start_cell() -> void:
	const NAME: String = "03_请求起点"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(2, 4), Vector2i.RIGHT)
	var request: _FireRequest = emitter.build_fire_request(128)
	if _check(NAME, request != null, "合法方向下 build_fire_request 不应返回 null。"):
		_check(NAME, request.get_start_cell() == Vector2i(2, 4), "start_cell 期望 (2,4)，实际 %s。" % [request.get_start_cell()])


## 4. build_fire_request 返回正确方向：request.get_direction() 等于当前方向。
func _test_04_fire_request_direction() -> void:
	const NAME: String = "04_请求方向"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.DOWN)
	var request: _FireRequest = emitter.build_fire_request(128)
	if _check(NAME, request != null, "合法方向下 build_fire_request 不应返回 null。"):
		_check(NAME, request.get_direction() == Vector2i.DOWN, "direction 期望 DOWN，实际 %s。" % [request.get_direction()])


## 5. build_fire_request 返回正确 max_steps：request.get_max_steps() 等于传入值。
func _test_05_fire_request_max_steps() -> void:
	const NAME: String = "05_请求max_steps"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT)
	var request: _FireRequest = emitter.build_fire_request(128)
	if _check(NAME, request != null, "合法方向下 build_fire_request 不应返回 null。"):
		_check(NAME, request.get_max_steps() == 128, "max_steps 期望 128，实际 %d。" % [request.get_max_steps()])


## 6. 合法 try_set_direction 成功：设置 UP 返回 true 且 get_direction() 变为 UP。
func _test_06_try_set_direction_valid() -> void:
	const NAME: String = "06_合法设置方向"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT)
	var ok: bool = emitter.try_set_direction(Vector2i.UP)
	_check(NAME, ok == true, "try_set_direction(UP) 期望返回 true。")
	_check(NAME, emitter.get_direction() == Vector2i.UP, "设置后 direction 期望 UP，实际 %s。" % [emitter.get_direction()])


## 7. 非法方向设置失败且旧方向不变：(2,0) 返回 false，方向保持原 RIGHT。
func _test_07_try_set_direction_invalid_keeps_old() -> void:
	const NAME: String = "07_非法方向不变"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT)
	var ok: bool = emitter.try_set_direction(Vector2i(2, 0))
	_check(NAME, ok == false, "try_set_direction((2,0)) 期望返回 false。")
	_check(NAME, emitter.get_direction() == Vector2i.RIGHT, "非法设置后 direction 应保持 RIGHT，实际 %s。" % [emitter.get_direction()])
	# ZERO 同样非法且旧方向不变。
	var ok_zero: bool = emitter.try_set_direction(Vector2i.ZERO)
	_check(NAME, ok_zero == false, "try_set_direction(ZERO) 期望返回 false。")
	_check(NAME, emitter.get_direction() == Vector2i.RIGHT, "ZERO 设置后 direction 应保持 RIGHT，实际 %s。" % [emitter.get_direction()])


## 8. 非法初始方向按旧语义保留：构造传入 ZERO，get_direction() 仍为 ZERO（不自动修正）。
func _test_08_invalid_initial_direction_retained() -> void:
	const NAME: String = "08_非法初始方向保留"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(1, 1), Vector2i.ZERO)
	_check(NAME, emitter.get_direction() == Vector2i.ZERO, "非法初始方向应原样保留 ZERO，实际 %s。" % [emitter.get_direction()])
	# 超过一格的非法初始方向同样保留。
	var emitter_b: _FixedEmitter = _FixedEmitter.new(Vector2i(1, 1), Vector2i(2, 0))
	_check(NAME, emitter_b.get_direction() == Vector2i(2, 0), "非法初始方向 (2,0) 应原样保留，实际 %s。" % [emitter_b.get_direction()])


## 9. 非法初始方向无法构建有效请求：方向为 ZERO 时 build_fire_request 返回 null。
func _test_09_invalid_initial_direction_no_request() -> void:
	const NAME: String = "09_非法方向无法构建请求"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(1, 1), Vector2i.ZERO)
	var request: Variant = emitter.build_fire_request(128)
	_check(NAME, request == null, "非法方向下 build_fire_request 期望返回 null，实际非 null。")


## 10. 无 set_cell 或其他移动入口：公开接口不含 set_cell/set_position/move 等移动方法。
func _test_10_no_movement_entry() -> void:
	const NAME: String = "10_无移动入口"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(1, 1), Vector2i.RIGHT)
	_check(NAME, not emitter.has_method("set_cell"), "不应提供 set_cell 移动入口。")
	_check(NAME, not emitter.has_method("move"), "不应提供 move 移动入口。")
	_check(NAME, not emitter.has_method("set_position"), "不应提供 set_position 移动入口。")


## 11. max_steps 边界与旧行为一致：旧行为不校验 max_steps，原样承载；0 与 128 均按传入值保存。
func _test_11_max_steps_boundary() -> void:
	const NAME: String = "11_max_steps边界"
	var emitter: _FixedEmitter = _FixedEmitter.new(Vector2i(0, 0), Vector2i.RIGHT)
	var request_zero: _FireRequest = emitter.build_fire_request(0)
	if _check(NAME, request_zero != null, "max_steps=0 合法方向下不应返回 null。"):
		_check(NAME, request_zero.get_max_steps() == 0, "max_steps=0 应原样保存，实际 %d。" % [request_zero.get_max_steps()])
	var request_max: _FireRequest = emitter.build_fire_request(128)
	if _check(NAME, request_max != null, "max_steps=128 合法方向下不应返回 null。"):
		_check(NAME, request_max.get_max_steps() == 128, "max_steps=128 应原样保存，实际 %d。" % [request_max.get_max_steps()])


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 本身供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 11
	var passed_checks: int = _checks - _failures.size()
	print("==== FixedEmitter D2-E 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
