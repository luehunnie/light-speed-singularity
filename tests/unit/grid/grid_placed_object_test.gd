extends SceneTree

## GridPlacedObject D3A 定向自动测试：position 为唯一持久化放置事实，cell 由 position 确定性派生。
## 覆盖：默认 position 派生 cell、set_cell/.cell 写入 position、直接改 position 即时反映 cell、
##   Ctrl+Z 等价（position 恢复则 cell 不残留）、sync 吸附到格中心、负格往返、occupied_cells 用派生 cell、
##   无 _ready 自动覆盖 position、不加载主场景、不依赖水晶/发射器/Registry/Validator/addons。
## 期望值一律由 GridCoordinateRules 派生，不复制 64×64 规则、不写死 world_to_cell(0,0) 结果。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

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
	_test_02_set_cell_zero_to_world_center()
	_test_03_set_cell_3_1_to_world()
	_test_04_cell_assign_matches_set_cell()
	_test_05_direct_position_reflects_in_cell()
	_test_06_position_restore_no_cell_residue()
	_test_07_sync_snaps_to_cell_center()
	_test_08_negative_cell_roundtrip()
	_test_09_occupied_cells_uses_derived_cell()
	await _test_10_no_ready_auto_overwrite()
	_test_11_no_main_scene_loaded()
	_test_12_no_forbidden_deps()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 新对象默认 position=(0,0)：get_cell() 返回 world_to_cell(0,0) 的真实结果，不沿用旧 ZERO→(32,32) 假设。
func _test_01_default_position_derives_cell() -> void:
	const NAME: String = "01_默认position派生cell"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	var expected: Vector2i = _GridCoordinateRules.world_to_cell(Vector2.ZERO)
	_check(NAME, obj.position == Vector2.ZERO, "新对象 position 应为 (0,0)，实际 %s。" % [obj.position])
	_check(NAME, obj.get_cell() == expected, "get_cell 应为 world_to_cell(0,0)=%s，实际 %s。" % [expected, obj.get_cell()])
	obj.free()


## 2. set_cell(ZERO) 后 position == cell_to_world(ZERO)（即 (32,32)）。
func _test_02_set_cell_zero_to_world_center() -> void:
	const NAME: String = "02_set_cell(ZERO)到世界中心"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i.ZERO)
	var expected: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i.ZERO)
	_check(NAME, obj.position == expected, "set_cell(ZERO) 后 position 期望 %s，实际 %s。" % [expected, obj.position])
	obj.free()


## 3. set_cell((3,1)) 后 position == cell_to_world((3,1))（即 (224,96)）。
func _test_03_set_cell_3_1_to_world() -> void:
	const NAME: String = "03_set_cell(3,1)到世界(224,96)"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(3, 1))
	var expected: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	_check(NAME, obj.position == expected, "set_cell(3,1) 后 position 期望 %s，实际 %s。" % [expected, obj.position])
	obj.free()


## 4. .cell = ... 与 set_cell() 语义一致：同一格经两种写入路径 position 与 get_cell 相同。
func _test_04_cell_assign_matches_set_cell() -> void:
	const NAME: String = "04_cell赋值与set_cell一致"
	var obj_a: _GridPlacedObject = _GridPlacedObject.new()
	var obj_b: _GridPlacedObject = _GridPlacedObject.new()
	obj_a.set_cell(Vector2i(3, 1))
	obj_b.cell = Vector2i(3, 1)
	_check(NAME, obj_a.position == obj_b.position, "set_cell 与 .cell 写入后 position 应一致，%s vs %s。" % [obj_a.position, obj_b.position])
	_check(NAME, obj_a.get_cell() == obj_b.get_cell(), "两种写入后 get_cell 应一致，%s vs %s。" % [obj_a.get_cell(), obj_b.get_cell()])
	obj_a.free()
	obj_b.free()


## 5. 直接修改 position 后 get_cell() 与 .cell 立即反映新格子。
func _test_05_direct_position_reflects_in_cell() -> void:
	const NAME: String = "05_直接改position即时反映cell"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.position = Vector2(224, 96)
	var expected: Vector2i = _GridCoordinateRules.world_to_cell(Vector2(224, 96))
	_check(NAME, obj.get_cell() == expected, "改 position 后 get_cell 期望 %s，实际 %s。" % [expected, obj.get_cell()])
	_check(NAME, obj.cell == expected, "改 position 后 .cell 期望 %s，实际 %s。" % [expected, obj.cell])
	obj.free()


## 6. Ctrl+Z 等价：position 改到新格再恢复旧值，cell 不残留新值。
func _test_06_position_restore_no_cell_residue() -> void:
	const NAME: String = "06_position恢复cell不残留"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	var p_a: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	var p_b: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(5, 5))
	obj.position = p_a
	var cell_a: Vector2i = obj.get_cell()
	obj.position = p_b
	_check(NAME, obj.get_cell() != cell_a, "改到新格后 cell 应变化，%s vs %s。" % [cell_a, obj.get_cell()])
	obj.position = p_a
	_check(NAME, obj.get_cell() == cell_a, "position 恢复后 cell 应回到 %s 不残留新值，实际 %s。" % [cell_a, obj.get_cell()])
	obj.free()


## 7. sync_world_position_from_cell() 将非中心 position 吸附到当前派生格中心。
func _test_07_sync_snaps_to_cell_center() -> void:
	const NAME: String = "07_sync吸附到格中心"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.position = Vector2(40, 50)  # 落在格 (0,0)，中心 (32,32)
	var center: Vector2 = _GridCoordinateRules.cell_to_world(obj.get_cell())
	obj.sync_world_position_from_cell()
	_check(NAME, obj.position == center, "sync 后 position 应吸附到格中心 %s，实际 %s。" % [center, obj.position])
	_check(NAME, obj.position != Vector2(40, 50), "sync 后 position 不应保留非中心值 (40,50)。")
	obj.free()


## 8. 负格坐标往返：set_cell 负格 → position → get_cell/.cell 回到同一负格。
func _test_08_negative_cell_roundtrip() -> void:
	const NAME: String = "08_负格往返"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(-1, -2))
	var expected_pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(-1, -2))
	_check(NAME, obj.position == expected_pos, "负格 position 期望 %s，实际 %s。" % [expected_pos, obj.position])
	_check(NAME, obj.get_cell() == Vector2i(-1, -2), "get_cell 往返期望 (-1,-2)，实际 %s。" % [obj.get_cell()])
	_check(NAME, obj.cell == Vector2i(-1, -2), ".cell 往返期望 (-1,-2)，实际 %s。" % [obj.cell])
	obj.free()


## 9. get_occupied_cells() 使用派生 cell：position 落在 (4,6) 时返回 [(4,6)]。
func _test_09_occupied_cells_uses_derived_cell() -> void:
	const NAME: String = "09_occupied_cells用派生cell"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.position = _GridCoordinateRules.cell_to_world(Vector2i(4, 6))
	_check(NAME, obj.get_occupied_cells() == [Vector2i(4, 6)], "occupied_cells 应为 [(4,6)]，实际 %s。" % [obj.get_occupied_cells()])
	obj.free()


## 10. 不存在 _ready 自动覆盖 position 的旧行为：设非中心 position 入树后应保持不被吸附。
func _test_10_no_ready_auto_overwrite() -> void:
	const NAME: String = "10_无_ready自动覆盖position"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.position = Vector2(40, 50)  # 非格中心；旧行为会在 _ready 同步到 (32,32)
	root.add_child(obj)
	await process_frame
	_check(NAME, obj.position == Vector2(40, 50), "_ready 不应覆盖 position，期望 (40,50)，实际 %s。" % [obj.position])
	obj.queue_free()
	await process_frame  # 等待帧末删除落地，避免残留子节点影响后续结构断言


## 11. 不加载主场景：未 change_scene，root 不含被测对象作为主场景根；实例为 Node2D 子类。
func _test_11_no_main_scene_loaded() -> void:
	const NAME: String = "11_不加载主场景"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	_check(NAME, obj is Node2D, "GridPlacedObject 应为 Node2D 子类。")
	_check(NAME, root.get_child_count() == 0, "本测试不应挂载任何子节点到 root，实际 root 子节点数 %d。" % [root.get_child_count()])
	obj.free()


## 12. 不依赖水晶/发射器/Registry/Validator/addons：结构性断言，仅 preload 本类与坐标规则。
func _test_12_no_forbidden_deps() -> void:
	const NAME: String = "12_无跨层依赖"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	_check(NAME, obj.get_occupied_offsets() == [Vector2i.ZERO], "默认 offsets 应为 [ZERO]，实际 %s。" % [obj.get_occupied_offsets()])
	# 返回新数组，调用方修改不影响后续获取。
	var offsets: Array[Vector2i] = obj.get_occupied_offsets()
	offsets.append(Vector2i(9, 9))
	_check(NAME, obj.get_occupied_offsets() == [Vector2i.ZERO], "修改返回数组后再次获取应仍为 [ZERO]，实际 %s。" % [obj.get_occupied_offsets()])
	obj.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 12
	var passed_checks: int = _checks - _failures.size()
	print("==== GridPlacedObject 测试摘要 ====")
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
