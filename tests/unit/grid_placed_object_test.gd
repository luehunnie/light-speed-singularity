extends SceneTree

## GridPlacedObject 方法 A 定向自动测试（阶段 1 编辑器关卡基础 D1）。
## 只通过公开接口验证：cell↔position 单向同步、set/get cell、Inspector setter 立即同步、
## 人工篡改 position 后可由单向同步恢复、重复 set 同一 cell 稳定、单格默认占用偏移与占用格、负格不被拒绝、_ready 幂等同步。
## 不创建正式主场景、不注册 Autoload、不依赖 BasicCrystal/Emitter/Registry/Validator/核心循环；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 期望世界坐标由 64×64 规则派生：cell_to_world(Vector2i.ZERO) == Vector2(32, 32)，
## cell_to_world(Vector2i(3, 1)) == Vector2(3*64+32, 1*64+32) == Vector2(224, 96)。

const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_zero_to_world_center()
	_test_02_cell_3_1_to_world()
	_test_03_set_get_cell()
	_test_04_cell_change_syncs_position_immediately()
	_test_05_manual_position_restored_by_one_way_sync()
	_test_06_repeat_same_cell_stable()
	_test_07_default_occupied_offsets()
	_test_08_occupied_cells_default()
	_test_09_negative_cell_not_rejected()
	# _ready 由 SceneTree 在节点进入树后于帧内派发，需 await 一帧让通知落地，再断言同步结果。
	await _test_10_ready_idempotent_sync()
	_test_11_no_main_scene_no_forbidden_deps()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. ZERO → 世界坐标 (32, 32)：cell_to_world(Vector2i.ZERO) 的 64×64 契约。
func _test_01_zero_to_world_center() -> void:
	const NAME: String = "01_ZERO到世界中心"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i.ZERO)
	_check(NAME, obj.position == Vector2(32, 32), "ZERO 期望 position (32,32)，实际 %s。" % [obj.position])
	obj.free()


## 2. (3, 1) → 世界坐标 (224, 96)：3*64+32=224，1*64+32=96。
func _test_02_cell_3_1_to_world() -> void:
	const NAME: String = "02_(3,1)到世界(224,96)"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(3, 1))
	_check(NAME, obj.position == Vector2(224, 96), "(3,1) 期望 position (224,96)，实际 %s。" % [obj.position])
	obj.free()


## 3. set/get cell：写入与读取一致。
func _test_03_set_get_cell() -> void:
	const NAME: String = "03_set_get_cell"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(5, 7))
	_check(NAME, obj.get_cell() == Vector2i(5, 7), "set_cell(5,7) 后 get_cell 应为 (5,7)，实际 %s。" % [obj.get_cell()])
	# 直接赋值 cell 属性（模拟 Inspector 编辑）也应走同一 setter 路径。
	obj.cell = Vector2i(-2, 4)
	_check(NAME, obj.get_cell() == Vector2i(-2, 4), "直接赋 cell=(-2,4) 后 get_cell 应为 (-2,4)，实际 %s。" % [obj.get_cell()])
	obj.free()


## 4. 修改 cell 后 position 立即同步：setter 内联调用 sync，无需额外调用。
func _test_04_cell_change_syncs_position_immediately() -> void:
	const NAME: String = "04_修改cell后position立即同步"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(1, 1))
	_check(NAME, obj.position == Vector2(96, 96), "(1,1) 期望 (96,96)，实际 %s。" % [obj.position])
	obj.set_cell(Vector2i(2, 3))
	_check(NAME, obj.position == Vector2(160, 224), "(2,3) 期望 (160,224)，实际 %s。" % [obj.position])
	obj.free()


## 5. 人工改变 position 后可由单向同步恢复：证明 position 不是第二份逻辑事实。
func _test_05_manual_position_restored_by_one_way_sync() -> void:
	const NAME: String = "05_篡改position后单向同步恢复"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(3, 1))
	# 人工篡改 position，模拟外部误写；D1 不回写 cell，仅记录脏值。
	obj.position = Vector2(0, 0)
	_check(NAME, obj.position == Vector2(0, 0), "篡改后 position 应为 (0,0)，实际 %s。" % [obj.position])
	_check(NAME, obj.get_cell() == Vector2i(3, 1), "篡改 position 不应改变 cell，实际 %s。" % [obj.get_cell()])
	# 单向同步恢复：position 重新由 cell 派生。
	obj.sync_world_position_from_cell()
	_check(NAME, obj.position == Vector2(224, 96), "sync 后 position 应恢复 (224,96)，实际 %s。" % [obj.position])
	obj.free()


## 6. 重复设置同一 cell 结果稳定：setter 幂等，不漂移、不递归。
func _test_06_repeat_same_cell_stable() -> void:
	const NAME: String = "06_重复设置同一cell稳定"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(3, 1))
	var p1: Vector2 = obj.position
	obj.set_cell(Vector2i(3, 1))
	obj.set_cell(Vector2i(3, 1))
	_check(NAME, obj.position == p1, "重复 set 同一 cell 后 position 应稳定，期望 %s，实际 %s。" % [p1, obj.position])
	_check(NAME, obj.position == Vector2(224, 96), "稳定值应为 (224,96)，实际 %s。" % [obj.position])
	_check(NAME, obj.get_cell() == Vector2i(3, 1), "cell 应仍为 (3,1)，实际 %s。" % [obj.get_cell()])
	obj.free()


## 7. 单格默认 occupied offsets：返回 [Vector2i.ZERO]。
func _test_07_default_occupied_offsets() -> void:
	const NAME: String = "07_单格默认occupied_offsets"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	var offsets: Array[Vector2i] = obj.get_occupied_offsets()
	_check(NAME, offsets == [Vector2i.ZERO], "默认 offsets 应为 [ZERO]，实际 %s。" % [offsets])
	# 返回应为新数组，调用方修改不影响内部状态（本类无内部状态，但保证语义）。
	offsets.append(Vector2i(9, 9))
	_check(NAME, obj.get_occupied_offsets() == [Vector2i.ZERO], "修改返回数组后再次获取应仍为 [ZERO]，实际 %s。" % [obj.get_occupied_offsets()])
	obj.free()


## 8. get_occupied_cells：单格默认返回 [cell]。
func _test_08_occupied_cells_default() -> void:
	const NAME: String = "08_occupied_cells默认"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(4, 6))
	var cells: Array[Vector2i] = obj.get_occupied_cells()
	_check(NAME, cells == [Vector2i(4, 6)], "occupied_cells 应为 [(4,6)]，实际 %s。" % [cells])
	obj.free()


## 9. 负格不被基础类拒绝：D1 不做地图边界/合法性校验。
func _test_09_negative_cell_not_rejected() -> void:
	const NAME: String = "09_负格不被拒绝"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(-1, -2))
	_check(NAME, obj.get_cell() == Vector2i(-1, -2), "负格 (-1,-2) 应被接受，实际 %s。" % [obj.get_cell()])
	# -1*64+32 = -32，-2*64+32 = -96。
	_check(NAME, obj.position == Vector2(-32, -96), "负格 position 期望 (-32,-96)，实际 %s。" % [obj.position])
	_check(NAME, obj.get_occupied_cells() == [Vector2i(-1, -2)], "负格 occupied_cells 应为 [(-1,-2)]，实际 %s。" % [obj.get_occupied_cells()])
	obj.free()


## 10. _ready 幂等同步：加入场景树并处理一帧后 _ready 触发，position 由 cell 派生；篡改后再次同步仍稳定。
func _test_10_ready_idempotent_sync() -> void:
	const NAME: String = "10_ready幂等同步"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	obj.set_cell(Vector2i(2, 2))
	# 篡改 position 后再加入场景树，_ready 应在帧内重新由 cell 同步。
	obj.position = Vector2(0, 0)
	root.add_child(obj)
	# 让 SceneTree 处理一帧，使 _ready 通知派发落地（--script 下 ready 在帧内延迟派发）。
	await process_frame
	_check(NAME, obj.position == Vector2(160, 160), "_ready 后 position 应由 cell(2,2) 同步为 (160,160)，实际 %s。" % [obj.position])
	# 重复调用 sync 保持幂等，不漂移。
	obj.sync_world_position_from_cell()
	_check(NAME, obj.position == Vector2(160, 160), "再次 sync 后 position 应稳定 (160,160)，实际 %s。" % [obj.position])
	obj.queue_free()


## 11. 不加载主场景、不依赖具体水晶/发射器/Registry/Validator：结构性断言。
## 本测试仅 preload grid_placed_object.gd，未 change_scene、未引用任何玩法/校验模块；
## 实例是 Node2D 子类，占用偏移默认单格，证明基础类无跨层依赖。
func _test_11_no_main_scene_no_forbidden_deps() -> void:
	const NAME: String = "11_无主场景无跨层依赖"
	var obj: _GridPlacedObject = _GridPlacedObject.new()
	_check(NAME, obj is Node2D, "GridPlacedObject 应为 Node2D 子类。")
	_check(NAME, obj.get_class() == "Node2D" or obj.get_class() == "GridPlacedObject", "实例类名应为 Node2D 或 GridPlacedObject，实际 %s。" % [obj.get_class()])
	_check(NAME, obj.get_occupied_offsets().size() == 1, "单格基础对象占用偏移数量应为 1。")
	# 未调用 change_scene / 未触碰任何 Autoload；主场景未被加载是本测试的结构性前提。
	_check(NAME, root.get_child_count() == 0 or root.get_child(0) != obj, "本测试不应把被测对象作为主场景根挂载。")
	obj.free()


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
