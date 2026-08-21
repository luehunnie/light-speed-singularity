extends SceneTree

## DirectionDomain 定向测试（AF-02 / Guide §18 唯一八方向 Domain）。
## 覆盖：token 顺序唯一性、token↔向量双射、is_valid 委托单一真相、旋转/反向/正交/斜向/共轴纯函数、
##   非法输入哨兵（未知 token → ZERO，非法向量 → 空 token / 原样返回）。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。


const _Domain: GDScript = preload("res://gameplay/light/direction_domain.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_order_and_bijection()
	_test_02_validity()
	_test_03_rotation_and_opposite()
	_test_04_orthogonal_diagonal_axis()
	_test_05_invalid_sentinels()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 顺时针顺序与 token↔向量双射：8 token 位置对应 8 向量，与 LightEmissionTypes 合法集合完全一致。
func _test_01_order_and_bijection() -> void:
	const G: String = "01_顺序与双射"
	var order: Array = _Domain.CLOCKWISE_ORDER
	_check(G, order.size() == 8, "顺时针 token 数期望 8，实际 %d。" % order.size())
	# 逐位置双射 + 环绕顺时针：向量 = 右、右下、下、左下、左、左上、上、右上。
	var expect_vectors: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	]
	for i: int in range(8):
		var token: StringName = order[i]
		_check(G, _Domain.to_vector(token) == expect_vectors[i],
			"%s 应映射 %s，实际 %s。" % [token, expect_vectors[i], _Domain.to_vector(token)])
		_check(G, _Domain.from_vector(expect_vectors[i]) == token,
			"%s 应反查 token %s，实际 %s。" % [expect_vectors[i], token, _Domain.from_vector(expect_vectors[i])])
	# 与 LightEmissionTypes 唯一合法集合零分歧（单一真相对齐证明）。
	for direction: Vector2i in expect_vectors:
		_check(G, _LightEmissionTypes.is_valid_direction(direction), "Domain 向量 %s 应在 LightEmissionTypes 合法集合内。" % [direction])
	var typed_array: Array[Vector2i] = []
	for direction: Vector2i in expect_vectors:
		typed_array.append(direction)
	_check(G, typed_array == (_LightEmissionTypes._VALID_DIRECTIONS as Array),
		"Domain 向量序列应与 LightEmissionTypes 合法集合一致（顺序同为顺时针）。")


## 2. 合法性判定：八方向 true；ZERO / 分量超界 / 斜倍向量 false；token 合法性同理。
func _test_02_validity() -> void:
	const G: String = "02_合法性"
	_check(G, _Domain.is_valid(Vector2i(1, 0)), "RIGHT 应合法。")
	_check(G, _Domain.is_valid(Vector2i(-1, 1)), "DOWN_LEFT 应合法。")
	_check(G, not _Domain.is_valid(Vector2i.ZERO), "ZERO 应非法。")
	_check(G, not _Domain.is_valid(Vector2i(2, 0)), "(2,0) 应非法。")
	_check(G, not _Domain.is_valid(Vector2i(2, 2)), "(2,2) 应非法。")
	_check(G, _Domain.is_valid_token(&"RIGHT"), "token RIGHT 应合法。")
	_check(G, not _Domain.is_valid_token(&"E"), "旧发射器 token E 不在唯一 Domain 内（对齐留后续）。")
	_check(G, not _Domain.is_valid_token(&""), "空 token 应非法。")


## 3. 旋转与反向：顺/逆时针逐位推进、多步与环绕、opposite 恒 4 步。
func _test_03_rotation_and_opposite() -> void:
	const G: String = "03_旋转与反向"
	var right: Vector2i = Vector2i(1, 0)
	_check(G, _Domain.rotate_clockwise(right) == Vector2i(1, 1), "RIGHT 顺时针 1 步期望 DOWN_RIGHT(1,1)。")
	_check(G, _Domain.rotate_clockwise(right, 2) == Vector2i(0, 1), "RIGHT 顺时针 2 步期望 DOWN(0,1)。")
	_check(G, _Domain.rotate_clockwise(right, 8) == right, "顺时针 8 步应回到原方向。")
	_check(G, _Domain.rotate_counterclockwise(right) == Vector2i(1, -1), "RIGHT 逆时针 1 步期望 UP_RIGHT(1,-1)。")
	_check(G, _Domain.rotate_counterclockwise(Vector2i(0, 1), 2) == Vector2i(1, 0), "DOWN 逆时针 2 步期望 RIGHT(1,0)。")
	_check(G, _Domain.opposite(Vector2i(1, 1)) == Vector2i(-1, -1), "DOWN_RIGHT 反向期望 UP_LEFT(-1,-1)。")
	_check(G, _Domain.opposite(right) == Vector2i(-1, 0), "RIGHT 反向期望 LEFT(-1,0)。")
	_check(G, _Domain.rotate_clockwise(right, 0) == right, "steps=0 应原样返回。")


## 4. 正交 / 斜向 / 共轴：八方向分类与同轴判定（含反平行）。
func _test_04_orthogonal_diagonal_axis() -> void:
	const G: String = "04_正交斜向共轴"
	_check(G, _Domain.is_orthogonal(Vector2i(1, 0)), "RIGHT 应为正交。")
	_check(G, _Domain.is_orthogonal(Vector2i(0, -1)), "UP 应为正交。")
	_check(G, not _Domain.is_orthogonal(Vector2i(1, 1)), "DOWN_RIGHT 不应为正交。")
	_check(G, _Domain.is_diagonal(Vector2i(-1, 1)), "DOWN_LEFT 应为斜向。")
	_check(G, not _Domain.is_diagonal(Vector2i(-1, 0)), "LEFT 不应为斜向。")
	_check(G, not _Domain.is_orthogonal(Vector2i.ZERO), "ZERO 非法输入 is_orthogonal 应 false。")
	_check(G, _Domain.same_axis(Vector2i(1, 0), Vector2i(-1, 0)), "RIGHT 与 LEFT 应共轴。")
	_check(G, _Domain.same_axis(Vector2i(1, 1), Vector2i(-1, -1)), "DOWN_RIGHT 与 UP_LEFT 应共轴。")
	_check(G, not _Domain.same_axis(Vector2i(1, 0), Vector2i(0, 1)), "RIGHT 与 DOWN 不应共轴。")
	_check(G, not _Domain.same_axis(Vector2i(1, 1), Vector2i(1, -1)), "两斜向对角线不应共轴。")
	_check(G, not _Domain.same_axis(Vector2i(2, 0), Vector2i(1, 0)), "非法输入共轴应 false。")


## 5. 非法哨兵：未知 token → ZERO 向量；非法向量 → 空 token / 原样返回。
func _test_05_invalid_sentinels() -> void:
	const G: String = "05_非法哨兵"
	_check(G, _Domain.to_vector(&"NOPE") == Vector2i.ZERO, "未知 token 应返回 ZERO 哨兵。")
	_check(G, _Domain.to_vector(&"") == Vector2i.ZERO, "空 token 应返回 ZERO 哨兵。")
	_check(G, _Domain.from_vector(Vector2i.ZERO) == &"", "ZERO 向量应返回空 token。")
	_check(G, _Domain.from_vector(Vector2i(2, 0)) == &"", "非法向量应返回空 token。")
	_check(G, _Domain.rotate_clockwise(Vector2i(3, 3)) == Vector2i(3, 3), "非法向量旋转应原样返回。")
	_check(G, _Domain.opposite(Vector2i.ZERO) == Vector2i.ZERO, "ZERO 反向应原样返回。")


## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== DirectionDomain AF-02 测试摘要 ====")
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
