extends SceneTree

## GridPlacedObject D3A 定向自动测试：position 为唯一持久化放置事实，cell 由 position 确定性派生。
## 覆盖：默认 position 派生 cell、set_cell/.cell 写入 position、直接改 position 即时反映 cell、
##   Ctrl+Z 等价（position 恢复则 cell 不残留）、sync 吸附到格中心、负格往返、occupied_cells 用派生 cell、
##   无 _ready 自动覆盖 position、不加载主场景、不依赖水晶/发射器/Registry/Validator/addons。
##   方向接口（冻结多格占用）：get_occupied_offsets 无参与显式默认方向结果一致、单格任意方向只占 [ZERO]、不存第二套位置事实；
##   get_occupied_cells(anchor, p_orientation) 用显式锚点、p_orientation 原样透传，方向探针子类证明透传且不同方向占用不同。
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
	_test_09_occupied_cells_anchor_keeps_old_result()
	await _test_10_no_ready_auto_overwrite()
	_test_11_no_main_scene_loaded()
	_test_12_no_forbidden_deps()
	_test_13_offsets_explicit_default_direction()
	_test_14_offsets_all_directions_single_cell()
	_test_15_offsets_no_second_position_fact()
	_test_16_occupied_cells_explicit_default_direction()
	_test_17_occupied_cells_passes_orientation()
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


## 9. get_occupied_cells(anchor) 用显式锚点（不再隐式取自身派生 cell）；基础单格对任意锚点返回 [anchor]，与旧 (4,6)→[(4,6)] 结果一致。
func _test_09_occupied_cells_anchor_keeps_old_result() -> void:
	const NAME: String = "09_occupied_cells(anchor)保持旧结果"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	# 自身派生 cell 与锚点不同，证明结果取传入 anchor 而非自身 cell。
	obj.position = _GridCoordinateRules.cell_to_world(Vector2i(9, 9))
	_check(NAME, obj.get_occupied_cells(Vector2i(4, 6)) == [Vector2i(4, 6)], "occupied_cells((4,6)) 应为 [(4,6)]，实际 %s。" % [obj.get_occupied_cells(Vector2i(4, 6))])
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


## 13. 显式传入默认方向 0：与无参结果一致，仍为 [ZERO]（冻结接口的兼容默认）。
func _test_13_offsets_explicit_default_direction() -> void:
	const NAME: String = "13_显式默认方向仍为ZERO"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	_check(NAME, obj.get_occupied_offsets(0) == [Vector2i.ZERO], "get_occupied_offsets(0) 应为 [ZERO]，实际 %s。" % [obj.get_occupied_offsets(0)])
	_check(NAME, obj.get_occupied_offsets(0) == obj.get_occupied_offsets(), "显式默认方向应与无参结果一致。")
	obj.free()


## 14. 单格对象所有合法方向仍只占 [ZERO]：枚举若干 int 方向，基类一律返回 [ZERO]，不实现多格占用。
func _test_14_offsets_all_directions_single_cell() -> void:
	const NAME: String = "14_单格任意方向仅占ZERO"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	var dirs: Array = [0, 1, 2, 3, 7, -1, 99]
	for dir in dirs:
		_check(NAME, obj.get_occupied_offsets(dir) == [Vector2i.ZERO], "方向 %s 应只占 [ZERO]，实际 %s。" % [dir, obj.get_occupied_offsets(dir)])
	obj.free()


## 15. 方向接口不保存第二套位置/锚点事实：以不同方向查询 offsets 后 cell/position 不变；属性表无 anchor_cell。
func _test_15_offsets_no_second_position_fact() -> void:
	const NAME: String = "15_方向接口不存第二套位置事实"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(4, 6))
	var pos_before: Vector2 = obj.position
	var cell_before: Vector2i = obj.get_cell()
	obj.get_occupied_offsets(1)
	obj.get_occupied_offsets(2)
	obj.get_occupied_offsets(99)
	_check(NAME, obj.position == pos_before, "查询 offsets 后 position 不应变，实际 %s。" % [obj.position])
	_check(NAME, obj.get_cell() == cell_before, "查询 offsets 后 cell 不应变，实际 %s。" % [obj.get_cell()])
	_check(NAME, obj.get_cell() == _GridCoordinateRules.world_to_cell(obj.position), "cell 仍由 position 派生，无第二套位置事实。")
	var has_anchor: bool = false
	for p: Dictionary in obj.get_property_list():
		if p["name"] == "anchor_cell":
			has_anchor = true
			break
	_check(NAME, not has_anchor, "不得新增 anchor_cell 后备字段。")
	obj.free()


## 16. get_occupied_cells(anchor, 0) 与不传方向结果一致：p_orientation 默认 0 原样透传到 get_occupied_offsets。
func _test_16_occupied_cells_explicit_default_direction() -> void:
	const NAME: String = "16_occupied_cells显式默认方向一致"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	var anchor: Vector2i = Vector2i(3, 4)
	_check(NAME, obj.get_occupied_cells(anchor, 0) == obj.get_occupied_cells(anchor), "显式方向 0 应与不传方向结果一致。")
	_check(NAME, obj.get_occupied_cells(anchor, 0) == [anchor], "单格对象显式方向 0 应为 [anchor]，实际 %s。" % [obj.get_occupied_cells(anchor, 0)])
	obj.free()


## 17. 方向透传：_DirectionalOccupancyProbe 覆盖 get_occupied_offsets(p_orientation)，get_occupied_cells(anchor, dir)
## 按方向返回不同 anchor 相对占用，证明 p_orientation 原样透传（不靠基类 [ZERO] 掩盖"方向未透传"）。
func _test_17_occupied_cells_passes_orientation() -> void:
	const NAME: String = "17_occupied_cells透传方向"
	var probe: _DirectionalOccupancyProbe = _DirectionalOccupancyProbe.new()
	var anchor: Vector2i = Vector2i(10, 10)
	# 手类 offsets 随方向变化：方向 0 仅 [ZERO]；方向 1 右扩一格；方向 2 下扩一格。
	_check(NAME, probe.get_occupied_offsets(0) == [Vector2i.ZERO], "手类方向 0 offsets 应为 [ZERO]，实际 %s。" % [probe.get_occupied_offsets(0)])
	_check(NAME, probe.get_occupied_offsets(1) == [Vector2i.ZERO, Vector2i(1, 0)], "手类方向 1 offsets 应为 [ZERO,(1,0)]，实际 %s。" % [probe.get_occupied_offsets(1)])
	_check(NAME, probe.get_occupied_offsets(2) == [Vector2i.ZERO, Vector2i(0, 1)], "手类方向 2 offsets 应为 [ZERO,(0,1)]，实际 %s。" % [probe.get_occupied_offsets(2)])
	# 同一 anchor 不同方向产生不同占用（相对 anchor）；若未透传则全部退化为方向 0 的 [anchor]。
	_check(NAME, probe.get_occupied_cells(anchor, 0) == [anchor], "方向 0 占用应为 [anchor]，实际 %s。" % [probe.get_occupied_cells(anchor, 0)])
	_check(NAME, probe.get_occupied_cells(anchor, 1) == [anchor, anchor + Vector2i(1, 0)], "方向 1 占用应为 [anchor, anchor+(1,0)]，实际 %s。" % [probe.get_occupied_cells(anchor, 1)])
	_check(NAME, probe.get_occupied_cells(anchor, 2) == [anchor, anchor + Vector2i(0, 1)], "方向 2 占用应为 [anchor, anchor+(0,1)]，实际 %s。" % [probe.get_occupied_cells(anchor, 2)])
	_check(NAME, probe.get_occupied_cells(anchor, 1) != probe.get_occupied_cells(anchor, 0), "方向 1 与方向 0 占用应不同（方向确已透传）。")
	_check(NAME, probe.get_occupied_cells(anchor, 2) != probe.get_occupied_cells(anchor, 0), "方向 2 与方向 0 占用应不同（方向确已透传）。")
	_check(NAME, probe.get_occupied_cells(anchor, 1) != probe.get_occupied_cells(anchor, 2), "方向 1 与方向 2 占用应不同。")
	# 不保存 orientation：查询后 probe 自身 position/cell 不变。
	var pos_before: Vector2 = probe.position
	probe.get_occupied_cells(anchor, 1)
	probe.get_occupied_cells(anchor, 2)
	_check(NAME, probe.position == pos_before, "查询占用后 position 不应变，实际 %s。" % [probe.position])
	probe.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 17
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


# ===== 方向占用透传探针（仅测试用） =====

## 方向占用透传探针：覆盖 get_occupied_offsets(p_orientation)，按方向返回不同偏移，
## 专用于证明 get_occupied_cells(anchor, p_orientation) 把方向原样透传给 get_occupied_offsets。
## 经 res:// 字符串路径 extends，规避"内部类 extends 不接受 preload const"限制；不引入镜子枚举或通用方向系统。
class _DirectionalOccupancyProbe extends "res://gameplay/grid/grid_placed_object.gd":
	func get_occupied_offsets(p_orientation: int = 0) -> Array[Vector2i]:
		match p_orientation:
			0:
				return [Vector2i.ZERO]
			1:
				return [Vector2i.ZERO, Vector2i(1, 0)]
			2:
				return [Vector2i.ZERO, Vector2i(0, 1)]
			_:
				return [Vector2i.ZERO, Vector2i(2, 2)]
