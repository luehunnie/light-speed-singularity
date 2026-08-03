extends SceneTree

## PlaceableToken 单格位置契约定向测试（OBJ-C1/C2）。
## 覆盖：position 为唯一场景位置事实；cell 由 position 经统一 GridCoordinateRules 派生，不持有可独立漂移的后备字段；
##   set_cell/.cell 写入 position 到格中心；get_cell/set_cell 兼容接口与属性 getter/setter 一致；
##   连续移动 position 不残留旧 cell；负坐标与格边界按 GridPlacedObject 同源规则处理；
##   不硬编码第二套 64×64 换算（与 GridPlacedObject 同 position 派生同 cell）；SingleCellMirror 继承后契约不变。
## 期望值一律由 GridCoordinateRules 派生，不复制 64×64 规则、不写死 world_to_cell(0,0) 结果。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注意：契约测试只驱动 position/cell 属性与 set_cell/get_cell/set_world_position，
##   不调用 configure（其依赖 @onready VisualView 子节点），不进入场景树，避开视觉依赖。

const _PlaceableToken: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _SingleCellMirror: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_default_position_derives_cell()
	_test_02_set_position_derives_cell()
	_test_03_set_cell_aligns_position_to_center()
	_test_04_cell_assign_matches_set_cell()
	_test_05_get_cell_matches_property()
	_test_06_position_moves_no_cell_residue()
	_test_07_negative_and_boundary_roundtrip()
	_test_08_no_independent_cell_backing_field()
	_test_09_same_rules_as_grid_placed_object()
	_test_10_set_world_position_derives_cell()
	_test_11_single_cell_mirror_inherits_contract()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 新对象默认 position=(0,0)：cell 应为 world_to_cell(0,0) 的真实结果，不写死 (0,0)。
func _test_01_default_position_derives_cell() -> void:
	const NAME: String = "01_默认position派生cell"
	var token: _PlaceableToken = _PlaceableToken.new()
	var expected: Vector2i = _GridCoordinateRules.world_to_cell(Vector2.ZERO)
	_check(NAME, token.position == Vector2.ZERO, "新对象 position 应为 (0,0)，实际 %s。" % [token.position])
	_check(NAME, token.cell == expected, "默认 cell 应为 world_to_cell(0,0)=%s，实际 %s。" % [expected, token.cell])
	token.free()


## 2. 设置 position 后 cell 自动变化：position 落在 (3,1) 格中心，cell 应为 (3,1)。
func _test_02_set_position_derives_cell() -> void:
	const NAME: String = "02_设置position后cell自动变化"
	var token: _PlaceableToken = _PlaceableToken.new()
	var pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	token.position = pos
	var expected: Vector2i = _GridCoordinateRules.world_to_cell(pos)
	_check(NAME, token.cell == expected, "设 position 后 cell 期望 %s，实际 %s。" % [expected, token.cell])
	_check(NAME, token.cell == Vector2i(3, 1), "cell 期望 (3,1)，实际 %s。" % [token.cell])
	token.free()


## 3. set_cell((3,1)) 后 position 对齐到格中心 cell_to_world((3,1))。
func _test_03_set_cell_aligns_position_to_center() -> void:
	const NAME: String = "03_set_cell对齐position到格中心"
	var token: _PlaceableToken = _PlaceableToken.new()
	token.set_cell(Vector2i(3, 1))
	var expected_pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	_check(NAME, token.position == expected_pos, "set_cell(3,1) 后 position 期望 %s，实际 %s。" % [expected_pos, token.position])
	_check(NAME, token.cell == Vector2i(3, 1), "set_cell 后 cell 期望 (3,1)，实际 %s。" % [token.cell])
	token.free()


## 4. .cell = ... 与 set_cell() 语义一致：同一格经两种写入路径 position 与 cell 相同。
func _test_04_cell_assign_matches_set_cell() -> void:
	const NAME: String = "04_cell赋值与set_cell一致"
	var token_a: _PlaceableToken = _PlaceableToken.new()
	var token_b: _PlaceableToken = _PlaceableToken.new()
	token_a.set_cell(Vector2i(3, 1))
	token_b.cell = Vector2i(3, 1)
	_check(NAME, token_a.position == token_b.position, "set_cell 与 .cell 写入后 position 应一致，%s vs %s。" % [token_a.position, token_b.position])
	_check(NAME, token_a.cell == token_b.cell, "两种写入后 cell 应一致，%s vs %s。" % [token_a.cell, token_b.cell])
	token_a.free()
	token_b.free()


## 5. get_cell() 与属性 getter 一致：兼容接口存在且与 .cell 同源。
func _test_05_get_cell_matches_property() -> void:
	const NAME: String = "05_get_cell与属性getter一致"
	var token: _PlaceableToken = _PlaceableToken.new()
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(4, 7))
	_check(NAME, token.has_method("get_cell"), "应保留 get_cell() 兼容接口。")
	if token.has_method("get_cell"):
		_check(NAME, token.get_cell() == token.cell, "get_cell 与 .cell 应一致，%s vs %s。" % [token.get_cell(), token.cell])
		_check(NAME, token.get_cell() == Vector2i(4, 7), "get_cell 期望 (4,7)，实际 %s。" % [token.get_cell()])
	token.free()


## 6. 连续移动 position 不保留旧 cell：跨多格移动，cell 始终跟随当前 position 派生。
func _test_06_position_moves_no_cell_residue() -> void:
	const NAME: String = "06_连续移动position不残留旧cell"
	var token: _PlaceableToken = _PlaceableToken.new()
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(2, 2))
	var cell_after_first: Vector2i = token.cell
	_check(NAME, cell_after_first == Vector2i(2, 2), "首次移动后 cell 期望 (2,2)，实际 %s。" % [cell_after_first])
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(5, 5))
	_check(NAME, token.cell == Vector2i(5, 5), "二次移动后 cell 期望 (5,5)，实际 %s。" % [token.cell])
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(2, 2))
	_check(NAME, token.cell == Vector2i(2, 2), "回到原格 cell 期望 (2,2)，实际 %s，不应残留 (5,5)。" % [token.cell])
	token.free()


## 7. 负坐标与格边界：负格往返、临近格边界（63.999→(0,0)，64→(1,1)）按 GridPlacedObject 同源规则。
func _test_07_negative_and_boundary_roundtrip() -> void:
	const NAME: String = "07_负坐标与格边界往返"
	var token: _PlaceableToken = _PlaceableToken.new()
	token.set_cell(Vector2i(-1, -2))
	var expected_neg_pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(-1, -2))
	_check(NAME, token.position == expected_neg_pos, "负格 position 期望 %s，实际 %s。" % [expected_neg_pos, token.position])
	_check(NAME, token.cell == Vector2i(-1, -2), "负格 cell 往返期望 (-1,-2)，实际 %s。" % [token.cell])
	# 格边界：63.999 仍属 (0,0)，64 进入 (1,1)；期望值统一由规则派生。
	token.position = Vector2(63.999, 63.999)
	_check(NAME, token.cell == _GridCoordinateRules.world_to_cell(Vector2(63.999, 63.999)), "63.999 边界 cell 期望 %s，实际 %s。" % [_GridCoordinateRules.world_to_cell(Vector2(63.999, 63.999)), token.cell])
	token.position = Vector2(64.0, 64.0)
	_check(NAME, token.cell == _GridCoordinateRules.world_to_cell(Vector2(64.0, 64.0)), "64 边界 cell 期望 %s，实际 %s。" % [_GridCoordinateRules.world_to_cell(Vector2(64.0, 64.0)), token.cell])
	token.free()


## 8. 无独立 cell 后备字段：先 set_cell(A)，再把 position 移到 B 格中心，cell 必须跟随 B（证明 cell 无可独立漂移的后备）。
func _test_08_no_independent_cell_backing_field() -> void:
	const NAME: String = "08_无独立cell后备字段"
	var token: _PlaceableToken = _PlaceableToken.new()
	token.set_cell(Vector2i(8, 8))
	_check(NAME, token.cell == Vector2i(8, 8), "set_cell(8,8) 后 cell 期望 (8,8)，实际 %s。" % [token.cell])
	# 仅改 position，不调 set_cell；若存在独立后备，cell 会卡在 (8,8)。
	token.position = _GridCoordinateRules.cell_to_world(Vector2i(1, 1))
	_check(NAME, token.cell == Vector2i(1, 1), "改 position 后 cell 应跟随 (1,1)，实际 %s，说明存在独立漂移后备。" % [token.cell])
	token.free()


## 9. 与 GridPlacedObject 同源换算：同一 position 下两者派生出同一 cell，证明不硬编码第二套 64×64 公式。
func _test_09_same_rules_as_grid_placed_object() -> void:
	const NAME: String = "09_与GridPlacedObject同源换算"
	var token: _PlaceableToken = _PlaceableToken.new()
	var gpo: _GridPlacedObject = _GridPlacedObject.new()
	var shared_pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(6, 9))
	token.position = shared_pos
	gpo.position = shared_pos
	_check(NAME, token.cell == gpo.cell, "同 position 下 PlaceableToken.cell(%s) 应与 GridPlacedObject.cell(%s) 一致。" % [token.cell, gpo.cell])
	_check(NAME, token.cell == Vector2i(6, 9), "同源换算 cell 期望 (6,9)，实际 %s。" % [token.cell])
	token.free()
	gpo.free()


## 10. set_world_position(p) 后 cell 由 p 派生：兼容接口写 position，cell 实时跟随。
func _test_10_set_world_position_derives_cell() -> void:
	const NAME: String = "10_set_world_position驱动派生cell"
	var token: _PlaceableToken = _PlaceableToken.new()
	var pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(2, 5))
	token.set_world_position(pos)
	_check(NAME, token.position == pos, "set_world_position 后 position 期望 %s，实际 %s。" % [pos, token.position])
	_check(NAME, token.cell == _GridCoordinateRules.world_to_cell(pos), "set_world_position 后 cell 期望 %s，实际 %s。" % [_GridCoordinateRules.world_to_cell(pos), token.cell])
	token.free()


## 11. SingleCellMirror 继承后契约不变：派生机关复用 PlaceableToken 的 position→cell 派生。
func _test_11_single_cell_mirror_inherits_contract() -> void:
	const NAME: String = "11_SingleCellMirror继承契约不变"
	var mirror: _SingleCellMirror = _SingleCellMirror.new()
	var pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 4))
	mirror.position = pos
	_check(NAME, mirror.cell == Vector2i(3, 4), "Mirror 设 position 后 cell 期望 (3,4)，实际 %s。" % [mirror.cell])
	mirror.set_cell(Vector2i(5, 2))
	_check(NAME, mirror.position == _GridCoordinateRules.cell_to_world(Vector2i(5, 2)), "Mirror set_cell 后 position 应对齐格中心，实际 %s。" % [mirror.position])
	_check(NAME, mirror.has_method("get_cell"), "Mirror 应继承 get_cell() 兼容接口。")
	if mirror.has_method("get_cell"):
		_check(NAME, mirror.get_cell() == Vector2i(5, 2), "Mirror get_cell 期望 (5,2)，实际 %s。" % [mirror.get_cell()])
	mirror.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 11
	var passed_checks: int = _checks - _failures.size()
	print("==== PlaceableToken 位置契约测试摘要 ====")
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
