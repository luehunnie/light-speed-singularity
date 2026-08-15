extends SceneTree

## OccupancyRegistry 多格占用契约定向测试（D7-R4）。
## 只通过公开接口观察 register_cells / move_cells 的事实与原子性：
## 整体原子拒绝（任一冲突不写任何数据）、平移与旋转（源/目标部分重叠）迁移、与单格路径 coexistence、
## GridPlacedObject.get_occupied_cells(anchor, orientation) 展开结果可直接作为登记输入。
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_register_cells_success()
	_test_02_register_invalid_inputs_rejected()
	_test_03_register_conflict_atomic_reject()
	_test_04_register_id_already_registered_rejected()
	_test_05_single_and_multi_coexistence()
	_test_06_unregister_multi_cell_clears_all()
	_test_07_move_cells_translation_success()
	_test_08_move_cells_rotation_overlap_success()
	_test_09_move_cells_same_set_rejected()
	_test_10_move_cells_source_mismatch_rejected()
	_test_11_move_cells_target_conflict_atomic_reject()
	_test_12_move_cells_invalid_inputs_rejected()
	_test_13_grid_placed_object_offsets_feed_registry()
	_test_14_consistency_after_operations()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 多格登记成功：正反向索引同步，get_cells_of 返回全部格。
func _test_01_register_cells_success() -> void:
	const NAME: String = "01_多格登记成功"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	var cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3)]
	_check(NAME, r.register_cells(&"m1", cells) == true, "多格登记期望 true。")
	_check(NAME, r.get_mechanism_at(Vector2i(3, 3)) == &"m1", "格 (3,3) 应指向 m1。")
	_check(NAME, r.get_mechanism_at(Vector2i(4, 3)) == &"m1", "格 (4,3) 应指向 m1。")
	_check(NAME, r.get_cells_of(&"m1") == cells, "m1 占用列表应为 [(3,3),(4,3)]，实际 %s。" % [r.get_cells_of(&"m1")])
	_check(NAME, r.has_mechanism(&"m1") == true, "m1 应已登记。")


## 2. 非法输入拒绝：空 ID、空格列表、列表内重复格。
func _test_02_register_invalid_inputs_rejected() -> void:
	const NAME: String = "02_登记非法输入拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"", [Vector2i(1, 1)]) == false, "空 ID 应拒绝。")
	_check(NAME, r.register_cells(&"m1", []) == false, "空格列表应拒绝。")
	var dup: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, 1)]
	_check(NAME, r.register_cells(&"m1", dup) == false, "重复格列表应拒绝。")
	_check(NAME, r.is_consistent() == true, "全部拒绝后占用表应保持一致。")


## 3. 冲突整体原子拒绝：任一格被其他机关占用即整体失败，无半写入。
func _test_03_register_conflict_atomic_reject() -> void:
	const NAME: String = "03_登记冲突原子拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"m1", Vector2i(4, 3)) == true, "前置单格登记应成功。")
	var cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3)]
	_check(NAME, r.register_cells(&"m2", cells) == false, "第二格冲突的多格登记应拒绝。")
	_check(NAME, r.get_mechanism_at(Vector2i(3, 3)) == &"", "未冲突格不应被半写入，实际 %s。" % [r.get_mechanism_at(Vector2i(3, 3))])
	_check(NAME, r.get_cells_of(&"m2") == [], "m2 不应有任何占用记录。")
	_check(NAME, r.get_mechanism_at(Vector2i(4, 3)) == &"m1", "既有 m1 占用应保持不变。")


## 4. 同 ID 重复登记拒绝：未清理旧占用前不得再次登记（含单格→多格、多格→多格）。
func _test_04_register_id_already_registered_rejected() -> void:
	const NAME: String = "04_同ID重复登记拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"m1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	_check(NAME, r.register_cells(&"m1", [Vector2i(5, 5), Vector2i(6, 5)]) == false, "同 ID 再次多格登记应拒绝。")
	_check(NAME, r.register_single_cell(&"m1", Vector2i(7, 7)) == false, "同 ID 单格登记应拒绝。")
	_check(NAME, r.get_cells_of(&"m1") == [Vector2i(1, 1), Vector2i(2, 1)], "m1 原占用应保持不变，实际 %s。" % [r.get_cells_of(&"m1")])


## 5. 单格与多格路径 coexistence：同一表内互不干扰，索引隔离。
func _test_05_single_and_multi_coexistence() -> void:
	const NAME: String = "05_单格多格共存"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_single_cell(&"s1", Vector2i(0, 0)) == true, "单格登记应成功。")
	_check(NAME, r.register_cells(&"w1", [Vector2i(2, 2), Vector2i(2, 3)]) == true, "多格登记应成功。")
	_check(NAME, r.get_mechanism_at(Vector2i(0, 0)) == &"s1", "(0,0) 应指向 s1。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 2)) == &"w1", "(2,2) 应指向 w1。")
	_check(NAME, r.get_cells_of(&"s1") == [Vector2i(0, 0)], "s1 应只占一格。")
	_check(NAME, r.get_cells_of(&"w1").size() == 2, "w1 应占两格。")


## 6. unregister 清除多格机关全部占用格，正反向索引同步。
func _test_06_unregister_multi_cell_clears_all() -> void:
	const NAME: String = "06_多格注销清全部格"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	_check(NAME, r.unregister(&"w1") == true, "多格注销应成功。")
	_check(NAME, r.has_mechanism_at(Vector2i(1, 1)) == false, "(1,1) 应已释放。")
	_check(NAME, r.has_mechanism_at(Vector2i(2, 1)) == false, "(2,1) 应已释放。")
	_check(NAME, r.has_mechanism(&"w1") == false, "w1 应已不存在。")


## 7. 多格平移原子迁移成功：旧格全部释放、新格全部归属、占用列表整体替换。
func _test_07_move_cells_translation_success() -> void:
	const NAME: String = "07_多格平移成功"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	var source: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1)]
	var target: Array[Vector2i] = [Vector2i(1, 3), Vector2i(2, 3)]
	_check(NAME, r.move_cells(&"w1", source, target) == true, "多格平移期望 true。")
	_check(NAME, r.has_mechanism_at(Vector2i(1, 1)) == false, "旧格 (1,1) 应已释放。")
	_check(NAME, r.has_mechanism_at(Vector2i(2, 1)) == false, "旧格 (2,1) 应已释放。")
	_check(NAME, r.get_mechanism_at(Vector2i(1, 3)) == &"w1", "新格 (1,3) 应指向 w1。")
	_check(NAME, r.get_mechanism_at(Vector2i(2, 3)) == &"w1", "新格 (2,3) 应指向 w1。")
	_check(NAME, r.get_cells_of(&"w1") == target, "w1 占用列表应整体替换为目标格，实际 %s。" % [r.get_cells_of(&"w1")])


## 8. 多格旋转重叠迁移成功：源/目标共享锚点格（双格平面镜 TOP→BOTTOM 语义）不构成冲突。
func _test_08_move_cells_rotation_overlap_success() -> void:
	const NAME: String = "08_多格旋转重叠成功"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	# 机关规则_双格平面镜 v0.6 §2.1：锚点 (x,y)，TOP 占 (x-1,y),(x,y)，BOTTOM 占 (x,y),(x+1,y)，旋转锚点不变。
	_check(NAME, r.register_cells(&"w1", [Vector2i(4, 5), Vector2i(5, 5)]) == true, "前置 TOP 朝向登记应成功。")
	var source: Array[Vector2i] = [Vector2i(4, 5), Vector2i(5, 5)]
	var target: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	_check(NAME, r.move_cells(&"w1", source, target) == true, "旋转重叠迁移（共享 (5,5)）期望 true。")
	_check(NAME, r.has_mechanism_at(Vector2i(4, 5)) == false, "旧格 (4,5) 应已释放。")
	_check(NAME, r.get_mechanism_at(Vector2i(5, 5)) == &"w1", "重叠锚点格 (5,5) 应仍指向 w1。")
	_check(NAME, r.get_mechanism_at(Vector2i(6, 5)) == &"w1", "新格 (6,5) 应指向 w1。")
	_check(NAME, r.get_cells_of(&"w1") == target, "w1 占用列表应为 BOTTOM 朝向格，实际 %s。" % [r.get_cells_of(&"w1")])


## 9. 无变化迁移拒绝：目标集合与源集合相同（顺序无关）返回 false 且事实不变。
func _test_09_move_cells_same_set_rejected() -> void:
	const NAME: String = "09_同集迁移拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	var same_reordered: Array[Vector2i] = [Vector2i(2, 1), Vector2i(1, 1)]
	_check(NAME, r.move_cells(&"w1", same_reordered, same_reordered) == false, "同集（乱序）迁移应拒绝。")
	_check(NAME, r.get_cells_of(&"w1") == [Vector2i(1, 1), Vector2i(2, 1)], "拒绝后占用列表应保持原顺序原值，实际 %s。" % [r.get_cells_of(&"w1")])


## 10. 源格列表不一致拒绝：与当前占用集合不同即失败且事实不变。
func _test_10_move_cells_source_mismatch_rejected() -> void:
	const NAME: String = "10_源不一致拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	var wrong_source: Array[Vector2i] = [Vector2i(1, 1), Vector2i(9, 9)]
	_check(NAME, r.move_cells(&"w1", wrong_source, [Vector2i(5, 5), Vector2i(6, 5)]) == false, "源不一致迁移应拒绝。")
	var partial_source: Array[Vector2i] = [Vector2i(1, 1)]
	_check(NAME, r.move_cells(&"w1", partial_source, [Vector2i(5, 5)]) == false, "部分源迁移应拒绝。")
	_check(NAME, r.get_cells_of(&"w1") == [Vector2i(1, 1), Vector2i(2, 1)], "拒绝后占用应保持不变，实际 %s。" % [r.get_cells_of(&"w1")])
	_check(NAME, r.has_mechanism_at(Vector2i(5, 5)) == false, "目标格不应被半写入。")


## 11. 目标冲突整体原子拒绝：目标任一格被其他机关占用即失败，无任何半写入（含部分目标空闲的场景）。
func _test_11_move_cells_target_conflict_atomic_reject() -> void:
	const NAME: String = "11_目标冲突原子拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置 w1 登记应成功。")
	_check(NAME, r.register_single_cell(&"s1", Vector2i(6, 5)) == true, "前置 s1 阻挡登记应成功。")
	var target: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	_check(NAME, r.move_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)], target) == false, "目标含阻挡格的迁移应拒绝。")
	_check(NAME, r.has_mechanism_at(Vector2i(5, 5)) == false, "空闲目标格不应被半写入。")
	_check(NAME, r.get_mechanism_at(Vector2i(6, 5)) == &"s1", "阻挡格应仍指向 s1。")
	_check(NAME, r.get_cells_of(&"w1") == [Vector2i(1, 1), Vector2i(2, 1)], "w1 源占用应保持不变，实际 %s。" % [r.get_cells_of(&"w1")])


## 12. 非法输入拒绝：空 ID、未登记 ID、空源/目标列表、列表内重复格。
func _test_12_move_cells_invalid_inputs_rejected() -> void:
	const NAME: String = "12_迁移非法输入拒绝"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	_check(NAME, r.move_cells(&"", [Vector2i(1, 1)], [Vector2i(2, 2)]) == false, "空 ID 应拒绝。")
	_check(NAME, r.move_cells(&"ghost", [Vector2i(1, 1)], [Vector2i(2, 2)]) == false, "未登记 ID 应拒绝。")
	_check(NAME, r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)]) == true, "前置多格登记应成功。")
	_check(NAME, r.move_cells(&"w1", [], [Vector2i(5, 5)]) == false, "空源列表应拒绝。")
	_check(NAME, r.move_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)], []) == false, "空目标列表应拒绝。")
	var dup: Array[Vector2i] = [Vector2i(5, 5), Vector2i(5, 5)]
	_check(NAME, r.move_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)], dup) == false, "重复目标格应拒绝。")
	_check(NAME, r.is_consistent() == true, "全部拒绝后占用表应保持一致。")


## 13. GridPlacedObject 契约衔接：方向占用子类 get_occupied_cells(anchor, orientation) 展开结果可直接登记，方向不同占用格不同。
func _test_13_grid_placed_object_offsets_feed_registry() -> void:
	const NAME: String = "13_GridPlacedObject衔接"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	var probe: _DirectionalTwoCellProbe = _DirectionalTwoCellProbe.new()
	var anchor: Vector2i = Vector2i(5, 5)
	var horizontal: Array[Vector2i] = probe.get_occupied_cells(anchor, 0)
	var vertical: Array[Vector2i] = probe.get_occupied_cells(anchor, 1)
	_check(NAME, horizontal == [Vector2i(5, 5), Vector2i(6, 5)], "方向 0 应占 [(5,5),(6,5)]，实际 %s。" % [horizontal])
	_check(NAME, vertical == [Vector2i(5, 5), Vector2i(5, 6)], "方向 1 应占 [(5,5),(5,6)]，实际 %s。" % [vertical])
	_check(NAME, r.register_cells(&"w1", horizontal) == true, "按方向 0 展开结果登记应成功。")
	_check(NAME, r.move_cells(&"w1", horizontal, vertical) == true, "换方向（旋转）原子迁移应成功。")
	_check(NAME, r.get_cells_of(&"w1") == vertical, "迁移后应占方向 1 的格，实际 %s。" % [r.get_cells_of(&"w1")])
	probe.free()


## 14. 混合操作后 is_consistent 全程成立（单格/多格登记、平移、旋转、注销交错）。
func _test_14_consistency_after_operations() -> void:
	const NAME: String = "14_混合操作一致性"
	var r: _OccupancyRegistry = _OccupancyRegistry.new()
	r.register_single_cell(&"s1", Vector2i(0, 0))
	r.register_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)])
	r.move_cells(&"w1", [Vector2i(1, 1), Vector2i(2, 1)], [Vector2i(1, 2), Vector2i(2, 2)])
	r.register_cells(&"w2", [Vector2i(8, 8), Vector2i(9, 8)])
	r.move_cells(&"w2", [Vector2i(8, 8), Vector2i(9, 8)], [Vector2i(9, 8), Vector2i(10, 8)])
	r.unregister(&"w1")
	_check(NAME, r.is_consistent() == true, "混合操作后双向索引应完全一致。")
	_check(NAME, r.get_cells_of(&"w2") == [Vector2i(9, 8), Vector2i(10, 8)], "w2 应占旋转后格，实际 %s。" % [r.get_cells_of(&"w2")])
	_check(NAME, r.get_cells_of(&"s1") == [Vector2i(0, 0)], "s1 应不受影响。")


# ===== 支撑 =====

## 方向占用探针：覆盖 get_occupied_offsets(p_orientation)，按方向返回两格偏移，
## 模拟未来两格机关（如双格平面镜）经 GridPlacedObject 冻结接口展开占用，证明 OccupancyRegistry 与基类契约衔接。
class _DirectionalTwoCellProbe extends "res://gameplay/grid/grid_placed_object.gd":
	func get_occupied_offsets(p_orientation: int = 0) -> Array[Vector2i]:
		if p_orientation == 1:
			return [Vector2i.ZERO, Vector2i(0, 1)]
		return [Vector2i.ZERO, Vector2i(1, 0)]


## 记录断言：失败项收集到 _failures，全部通过时 _checks 递增。
func _check(group_name: String, condition: bool, reason: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append("[%s] %s" % [group_name, reason])


## 统一报告：输出通过/失败统计与全部失败项。
func _report() -> void:
	print("occupancy_registry_multi_cell_test: %d checks, %d failures" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL " + failure)
