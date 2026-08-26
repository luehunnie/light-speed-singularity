extends SceneTree

## AF-10 第一批集成测试：预置机关收编 + metadata 库存初始化端到端（真实 core_loop_prototype.tscn）。
## 实例化真实场景、入树前向 RuntimeObjects 注入预置镜面（不改场景文件），经公开入口与既有私有契约 seam
## （_inventory_controller/_placement_controller/_preplaced_adopter，同 core_loop_real_light_path 先例）观察：
## 预置收编可查询、反射链可达、不扣库存；metadata 镜面×3 → 3 次放置 3→2→1→0、第 4 次拒绝、失败不扣；
## R 重置恢复初始库存并保留预置机关原状；metadata 缺失退回原型默认 1。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
# 略大于生产脉冲视觉持续时间 1.0s，确保异步结束协程在释放前于活动控制器上恢复。
const _PULSE_SETTLE_MS: int = 1150
const _MIRROR_TYPE_ID: StringName = &"basic_single_cell_mirror"

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _SingleCellMirror: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _MirrorScene: PackedScene = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "core_loop_prototype.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return
	await _test_01_metadata_initializes_three(scene)
	var placed_instance: Node2D = await _test_02_preplaced_adopted_queryable(scene)
	await _test_03_preplaced_mirror_reflects_path(placed_instance)
	var conflict_instance: Node2D = await _test_04_illegal_and_conflict_preplaced_safe_fail(scene)
	await _test_05_inventory_three_placements_fourth_rejected(conflict_instance)
	await _test_06_reset_restores_inventory_and_preplaced(conflict_instance)
	await _test_07_missing_metadata_falls_back_to_one(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _ready；入树前固定库存与预置 fixture（镜面×3、剥离场景
## RuntimeObjects 内已 authored 的镜面子节点——场景是活体作者 fixture，本测试基线自持，不依赖场景内容）。
func _ready_instance(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	_prepare_fixture(node)
	root.add_child(node)
	await process_frame
	return node


## 入树前固定实例级 fixture：写镜面×3 inventory_entries、剥离场景已 authored 的 RuntimeObjects 镜面子节点。
func _prepare_fixture(node: Node2D) -> void:
	node.set_meta("inventory_entries", [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
	])
	var runtime_objects: Node = node.get_node("RuntimeObjects")
	for child: Node in runtime_objects.get_children():
		if child.get_script() == _SingleCellMirror:
			child.free()


## 入树前向 RuntimeObjects 注入一个位于 cell 的预置镜面（SLASH 默认朝向）并返回该节点。
func _inject_preplaced_mirror(node: Node2D, cell: Vector2i) -> Node2D:
	var mirror: Node2D = _MirrorScene.instantiate() as Node2D
	mirror.position = _GridCoordinateRules.cell_to_world(cell)
	(node.get_node("RuntimeObjects") as Node2D).add_child(mirror)
	return mirror


## 库存剩余（私有契约 seam，同既有测试读 _fixed_emitter 先例）。
func _remaining(node: Node2D) -> int:
	return int(node.get("_inventory_controller").get_remaining())


## 玩家放置映射数量。
func _placed_count(node: Node2D) -> int:
	return int(node.get("_placement_controller").get_placed_count())


## 预置收编数量。
func _preplaced_count(node: Node2D) -> int:
	return int(node.get("_preplaced_adopter").get_preplaced_count())


## 由 LightPathLayer 子节点 global_position 反查路径格序列（真实运行结果的视觉投影）。
func _path_cells(node: Node2D) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var lpl: Node2D = node.get_node_or_null("LightPathLayer") as Node2D
	if lpl == null:
		return cells
	for child: Node in lpl.get_children():
		cells.append(_GridCoordinateRules.world_to_cell((child as Node2D).global_position))
	return cells


## 释放前等待脉冲视觉持续时间过后异步结束协程在活动控制器上恢复；fired=false 无脉冲直接释放。
func _settle_and_free(node: Node2D, fired: bool) -> void:
	if fired:
		var start_ms: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
			await process_frame
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. metadata 初始化：inventory_entries 镜面×3 → 库存总量/剩余为 3；无预置机关时收编 0。
func _test_01_metadata_initializes_three(scene: PackedScene) -> void:
	const NAME: String = "01_metadata镜面3初始化"
	var node: Node2D = await _ready_instance(scene)
	_check(NAME, _remaining(node) == 3, "metadata 镜面×3 下库存剩余期望 3，实际 %d。" % [_remaining(node)])
	_check(NAME, _placed_count(node) == 0, "初始玩家放置映射期望 0。")
	_check(NAME, _preplaced_count(node) == 0, "无预置机关时收编数量期望 0。")
	await _settle_and_free(node, false)


## 2. 预置收编：RuntimeObjects 注入镜面(3,3) → 占用可查询、进收编映射、不扣库存、不可被玩家拿取。
##    返回该实例供用例 3 继续验证反射链。
func _test_02_preplaced_adopted_queryable(scene: PackedScene) -> Node2D:
	const NAME: String = "02_预置镜面收编可查询"
	const CELL: Vector2i = Vector2i(3, 3)
	var node: Node2D = scene.instantiate() as Node2D
	_prepare_fixture(node)
	var mirror: Node2D = _inject_preplaced_mirror(node, CELL)
	root.add_child(node)
	await process_frame
	var mechanism_id: StringName = node.get_mechanism_at(CELL)
	_check(NAME, mechanism_id != &"", "预置镜面格 (3,3) 应可经公开查询命中机关 ID。")
	_check(NAME, _preplaced_count(node) == 1, "收编映射数量期望 1。")
	_check(NAME, (mirror as PlaceableToken).mechanism_id == mechanism_id, "预置节点 mechanism_id 应为收编 ID。")
	_check(NAME, not node.get("_placement_controller").has_placed(mechanism_id), "预置机关不应进入玩家放置映射（拖拽/回收安全忽略的守卫）。")
	_check(NAME, _remaining(node) == 3, "预置收编不应扣玩家库存，剩余期望 3，实际 %d。" % [_remaining(node)])
	_check(NAME, _placed_count(node) == 0, "预置收编不应产生玩家放置，实际 %d。" % [_placed_count(node)])
	return node


## 3. 反射链可达（承接用例 2 实例）：预置镜面 (3,3) SLASH 把 RIGHT 反射为 UP，
##    路径 (2,3)→(3,3)（入射到镜面，镜面格投影两次）→(3,2)→(3,1)（穿过水晶并点亮）→(3,0)（边界止），
##    脉冲结束后关卡完成标签可见。
func _test_03_preplaced_mirror_reflects_path(node: Node2D) -> void:
	const NAME: String = "03_预置镜面反射链可达"
	if not _check(NAME, is_instance_valid(node), "实例应有效。"):
		return
	node.start_run()
	node.fire_light()
	var cells: Array[Vector2i] = _path_cells(node)
	_check(NAME, cells.size() == 6, "反射路径段数期望 6，实际 %d。" % [cells.size()])
	if cells.size() == 6:
		_check(NAME, cells[0] == Vector2i(2, 3), "首格期望 (2,3)，实际 %s。" % [cells[0]])
		_check(NAME, cells[1] == Vector2i(3, 3), "次格期望镜面格 (3,3)，实际 %s。" % [cells[1]])
		_check(NAME, cells[2] == Vector2i(3, 3), "镜面离射段起点期望 (3,3)，实际 %s。" % [cells[2]])
		_check(NAME, cells[3] == Vector2i(3, 2), "反射后格期望 (3,2)，实际 %s。" % [cells[3]])
		_check(NAME, cells[4] == Vector2i(3, 1), "光应穿过水晶格 (3,1)，实际 %s。" % [cells[4]])
		_check(NAME, cells[5] == Vector2i(3, 0), "末格期望边界前 (3,0)，实际 %s。" % [cells[5]])
	_check(NAME, not cells.has(Vector2i(4, 3)), "反射后不应再沿 RIGHT 到达 (4,3)。")
	await _settle_and_free_fired_and_check_complete(node, NAME)


## 等待脉冲结束协程恢复后校验完成标签（反射链点亮水晶 → 关卡完成），再释放实例。
func _settle_and_free_fired_and_check_complete(node: Node2D, name: String) -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame
	if is_instance_valid(node):
		var complete_label: Node = node.get_node_or_null("CanvasLayer/CompleteLabel")
		_check(name, complete_label != null and complete_label.visible, "预置镜面反射点亮水晶后完成标签应可见。")
		node.free()
	await process_frame


## 4. 安全失败：墙格 (5,3) 预置拒绝收编；(7,7) 双预置冲突，首个收编、第二个回滚。
##    返回该实例供用例 5/6 继续验证库存与重置。
func _test_04_illegal_and_conflict_preplaced_safe_fail(scene: PackedScene) -> Node2D:
	const NAME: String = "04_非法格与占用冲突安全失败"
	var node: Node2D = scene.instantiate() as Node2D
	_prepare_fixture(node)
	var wall_mirror: Node2D = _inject_preplaced_mirror(node, Vector2i(5, 3))
	var first_dup: Node2D = _inject_preplaced_mirror(node, Vector2i(7, 7))
	var second_dup: Node2D = _inject_preplaced_mirror(node, Vector2i(7, 7))
	root.add_child(node)
	await process_frame
	_check(NAME, node.get_mechanism_at(Vector2i(5, 3)) == &"", "墙格预置机关不应登记占用。")
	_check(NAME, (wall_mirror as PlaceableToken).mechanism_id == &"", "被拒墙格节点 mechanism_id 应保持为空。")
	var adopted_id: StringName = node.get_mechanism_at(Vector2i(7, 7))
	_check(NAME, adopted_id != &"", "冲突格首个预置机关应收编登记。")
	_check(NAME, (first_dup as PlaceableToken).mechanism_id == adopted_id, "首个冲突节点应持有收编 ID。")
	_check(NAME, (second_dup as PlaceableToken).mechanism_id == &"", "第二个冲突节点 mechanism_id 应复位为空。")
	_check(NAME, _preplaced_count(node) == 1, "安全失败后收编数量期望 1，实际 %d。" % [_preplaced_count(node)])
	_check(NAME, is_instance_valid(second_dup), "被拒节点不应被销毁（保持场景原状可诊断）。")
	return node


## 5. metadata 库存 3→2→1→0：三次合法放置各扣一；第 4 次库存不足拒绝；墙格放置失败不扣。
func _test_05_inventory_three_placements_fourth_rejected(node: Node2D) -> void:
	const NAME: String = "05_库存3到0与第4次拒绝"
	if not _check(NAME, is_instance_valid(node), "实例应有效。"):
		return
	var pc: Variant = node.get("_placement_controller")
	var orientation: int = _SingleCellMirror.MirrorOrientation.SLASH
	for i: int in range(3):
		var cell: Vector2i = Vector2i(2 + i * 2, 6)
		var result: Variant = pc.place_from_inventory(_MIRROR_TYPE_ID, cell, orientation)
		_check(NAME, result.is_success(), "第 %d 次放置应成功（cell=%s）。" % [i + 1, cell])
		_check(NAME, _remaining(node) == 2 - i, "第 %d 次放置后剩余期望 %d，实际 %d。" % [i + 1, 2 - i, _remaining(node)])
		_check(NAME, node.get_mechanism_at(cell) != &"", "第 %d 次放置格应可查询到玩家机关。" % [i + 1])
	_check(NAME, _placed_count(node) == 3, "三次放置后玩家映射期望 3。")
	var fourth: Variant = pc.place_from_inventory(_MIRROR_TYPE_ID, Vector2i(8, 6), orientation)
	_check(NAME, not fourth.is_success(), "库存为 0 后第 4 次放置应被拒绝。")
	_check(NAME, _remaining(node) == 0, "被拒放置后剩余应保持 0，实际 %d。" % [_remaining(node)])
	_check(NAME, node.get_mechanism_at(Vector2i(8, 6)) == &"", "被拒放置不应登记占用。")
	var wall_result: Variant = pc.place_from_inventory(_MIRROR_TYPE_ID, Vector2i(5, 3), orientation)
	_check(NAME, not wall_result.is_success(), "墙格放置应失败（目标格非法）。")
	_check(NAME, _remaining(node) == 0, "失败放置不应扣库存，剩余应保持 0，实际 %d。" % [_remaining(node)])


## 6. R 重置：库存恢复初始 3、玩家机关清空、预置机关保持原格原 ID 原节点（场景原状）。
func _test_06_reset_restores_inventory_and_preplaced(node: Node2D) -> void:
	const NAME: String = "06_R重置恢复库存与预置原状"
	if not _check(NAME, is_instance_valid(node), "实例应有效。"):
		return
	var preplaced_id_before: StringName = node.get_mechanism_at(Vector2i(7, 7))
	var preplaced_node_before: Variant = node.get("_preplaced_adopter").get_preplaced_node(preplaced_id_before)
	node.reset_runtime()
	await process_frame
	await process_frame
	_check(NAME, _remaining(node) == 3, "R 后库存应恢复初始 3，实际 %d。" % [_remaining(node)])
	_check(NAME, _placed_count(node) == 0, "R 后玩家放置映射应清空。")
	_check(NAME, node.get_mechanism_at(Vector2i(2, 6)) == &"", "R 后玩家放置格占用应注销。")
	var preplaced_id_after: StringName = node.get_mechanism_at(Vector2i(7, 7))
	_check(NAME, preplaced_id_after == preplaced_id_before, "R 后预置机关 ID 应保持不变：%s vs %s。" % [preplaced_id_before, preplaced_id_after])
	_check(NAME, node.get("_preplaced_adopter").get_preplaced_node(preplaced_id_after) == preplaced_node_before, "R 后预置机关节点应为原实例。")
	_check(NAME, _preplaced_count(node) == 1, "R 后收编数量应保持 1。")
	await _settle_and_free(node, false)


## 7. metadata 缺失兼容：remove_meta 后退回原型默认 1（放置一次即空，第二次拒绝）。
func _test_07_missing_metadata_falls_back_to_one(scene: PackedScene) -> void:
	const NAME: String = "07_metadata缺失默认1"
	var node: Node2D = scene.instantiate() as Node2D
	node.remove_meta("inventory_entries")
	root.add_child(node)
	await process_frame
	_check(NAME, _remaining(node) == 1, "metadata 缺失时库存应退回原型默认 1，实际 %d。" % [_remaining(node)])
	var pc: Variant = node.get("_placement_controller")
	var orientation: int = _SingleCellMirror.MirrorOrientation.SLASH
	var first: Variant = pc.place_from_inventory(_MIRROR_TYPE_ID, Vector2i(2, 6), orientation)
	_check(NAME, first.is_success(), "默认库存 1 时首次放置应成功。")
	_check(NAME, _remaining(node) == 0, "首次放置后剩余期望 0。")
	var second: Variant = pc.place_from_inventory(_MIRROR_TYPE_ID, Vector2i(4, 6), orientation)
	_check(NAME, not second.is_success(), "默认库存 1 时第二次放置应被拒绝。")
	await _settle_and_free(node, false)


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== AF-10 预置机关与metadata库存集成测试摘要 ====")
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
