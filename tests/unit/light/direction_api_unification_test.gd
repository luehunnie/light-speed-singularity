extends SceneTree

## S3-01 统一八方向 API 核验测试（DirectionDomain 唯一事实收敛）。
## 覆盖：加速器/减速器 direction_to_vector 与 DirectionDomain.CLOCKWISE_ORDER 逐值一致；
##   speed_direction_rules.cycle_clockwise 轮转顺序与 DirectionDomain 唯一顺序事实一致（含越界不猜测）；
##   真实节点 set_direction → cycle_direction → matches_direction 全链路经委派实现；
##   发射器 RayDirection（顺时针同序）与 ParticleDirection（冻结旧数值 + 斜向追加）换算经 DirectionDomain 一致。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题；
##   机关为 Node2D fixture，用后 free（不进树，_ready 不触发，@onready 不解引用）。
## 全部失败项收集后统一退出（任一失败 quit(1)）。

const _Domain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _Rules: GDScript = preload("res://gameplay/mechanisms/speed/speed_direction_rules.gd")
const _Accelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_accelerator.gd")
const _Decelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_decelerator.gd")
const _EmitterConfig: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")

const _GROUP_COUNT: int = 4

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_mechanism_vectors_match_domain()
	_test_02_cycle_order_follows_domain()
	_test_03_node_cycle_chain()
	_test_04_emitter_frozen_mapping()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 统一八方向 API 核验测试摘要（S3-01）====")
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

## 01. 加速器/减速器 direction_to_vector 逐值 == DirectionDomain.CLOCKWISE_ORDER 向量（不自建第二份向量表）。
func _test_01_mechanism_vectors_match_domain() -> void:
	const G: String = "01_机关向量与Domain一致"
	for i: int in range(8):
		var expected: Vector2i = _Domain.to_vector(_Domain.CLOCKWISE_ORDER[i])
		var accel_vector: Vector2i = _Accelerator.direction_to_vector(i)
		var decel_vector: Vector2i = _Decelerator.direction_to_vector(i)
		_check(G, accel_vector == expected,
			"加速器枚举 %d 向量期望 %s，实际 %s。" % [i, expected, accel_vector])
		_check(G, decel_vector == expected,
			"减速器枚举 %d 向量期望 %s，实际 %s。" % [i, expected, decel_vector])
		_check(G, _Domain.is_valid(accel_vector) and _Domain.is_valid(decel_vector),
			"枚举 %d 换算向量须经 Domain 判定为合法八方向。" % [i])
	_check(G, _Accelerator.validate_direction_vectors() and _Decelerator.validate_direction_vectors(),
		"两机关启动自检 validate_direction_vectors 应全部通过。")


## 02. rules 轮转顺序 == DirectionDomain 唯一顺时针事实；越界不猜测（ZERO / 原值返回）。
func _test_02_cycle_order_follows_domain() -> void:
	const G: String = "02_轮转顺序与Domain一致"
	for i: int in range(8):
		var next_value: int = _Rules.cycle_clockwise(i)
		var expected_token: StringName = _Domain.CLOCKWISE_ORDER[(i + 1) % 8]
		_check(G, _Domain.from_vector(_Rules.direction_to_vector(next_value)) == expected_token,
			"枚举 %d 顺时针轮转后应指向 Domain token %s，实际 %s。"
				% [i, expected_token, _Domain.from_vector(_Rules.direction_to_vector(next_value))])
	var looped: int = 0
	for step: int in range(8):
		looped = _Rules.cycle_clockwise(looped)
	_check(G, looped == 0, "连续轮转 8 步应回到起点枚举 0，实际 %d。" % [looped])
	_check(G, _Rules.cycle_clockwise(-1) == -1, "越界枚举 -1 轮转应原样返回不猜测。")
	_check(G, _Rules.direction_to_vector(-1) == Vector2i.ZERO, "越界枚举 -1 向量应为 ZERO 哨兵。")
	_check(G, _Rules.direction_to_vector(8) == Vector2i.ZERO, "越界枚举 8 向量应为 ZERO 哨兵。")


## 03. 真实节点全链路：set_direction(RIGHT) → cycle_direction() → direction 枚举与 matches_direction 均经委派实现。
func _test_03_node_cycle_chain() -> void:
	const G: String = "03_节点轮转全链路"
	var accel: Variant = _Accelerator.new()
	_check(G, _is_editor_property(accel, &"direction"), "加速器 direction 应导出到 Inspector。")
	accel.set_direction(_Accelerator.AcceleratorDirection.RIGHT)
	accel.cycle_direction()
	_check(G, accel.direction == _Accelerator.AcceleratorDirection.DOWN_RIGHT,
		"加速器 RIGHT 右键轮转后应为 DOWN_RIGHT，实际 %s。" % [accel.direction])
	_check(G, accel.matches_direction(Vector2i(1, 1)) == true,
		"加速器轮转后 matches_direction(1,1) 应为 true。")
	accel.free()
	var decel: Variant = _Decelerator.new()
	_check(G, _is_editor_property(decel, &"direction"), "减速器 direction 应导出到 Inspector。")
	decel.set_direction(_Decelerator.DeceleratorDirection.RIGHT)
	decel.cycle_direction()
	_check(G, decel.direction == _Decelerator.DeceleratorDirection.DOWN_RIGHT,
		"减速器 RIGHT 右键轮转后应为 DOWN_RIGHT，实际 %s。" % [decel.direction])
	_check(G, decel.matches_direction(Vector2i(1, 1)) == true,
		"减速器轮转后 matches_direction(1,1) 应为 true。")
	decel.free()


func _is_editor_property(object: Object, property_name: StringName) -> bool:
	for property: Dictionary in object.get_property_list():
		if property.name == property_name:
			return (property.usage as int) & PROPERTY_USAGE_EDITOR != 0
	return false


## 04. 发射器冻结映射：RayDirection 同序对齐 CLOCKWISE_ORDER；ParticleDirection 冻结数值桥接后向量一致。
func _test_04_emitter_frozen_mapping() -> void:
	const G: String = "04_发射器冻结映射"
	for i: int in range(8):
		var expected: Vector2i = _Domain.to_vector(_Domain.CLOCKWISE_ORDER[i])
		var ray_vector: Vector2i = _EmitterConfig.ray_direction_to_vector(i)
		_check(G, ray_vector == expected,
			"RayDirection 枚举 %d 向量期望 %s，实际 %s。" % [i, expected, ray_vector])
	# ParticleDirection 冻结数值契约：RIGHT=0/DOWN=1/LEFT=2/UP=3 + DOWN_RIGHT=4/DOWN_LEFT=5/UP_LEFT=6/UP_RIGHT=7。
	var particle_tokens: Array[StringName] = [
		&"RIGHT", &"DOWN", &"LEFT", &"UP",
		&"DOWN_RIGHT", &"DOWN_LEFT", &"UP_LEFT", &"UP_RIGHT",
	]
	for value: int in range(8):
		var expected_vector: Vector2i = _Domain.to_vector(particle_tokens[value])
		var actual_vector: Vector2i = _EmitterConfig.particle_direction_to_vector(value)
		_check(G, actual_vector == expected_vector,
			"ParticleDirection 枚举 %d 向量期望 %s（token %s），实际 %s。"
				% [value, expected_vector, particle_tokens[value], actual_vector])
