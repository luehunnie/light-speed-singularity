extends SceneTree

## AF-10 第二批集成测试：关卡根 metadata move_limit → 运行期移动限制端到端（真实 core_loop_prototype.tscn + 真实拖拽链）。
## 实例化真实场景、入树前写 move_limit metadata（不改场景文件），经公开入口（start_run/reset_runtime/place_from_inventory）
## 与既有私有契约 seam（_drag_flow_controller/_level_runtime_controller/_inventory_controller，同第一批先例）观察：
## enabled max_count=1 → 首次跨格移动成功扣 1、第二次拒绝保持原格、非法目标失败不扣、库存全程不被错误扣减、
## R 重置恢复计数；enabled max_count=2 → 上限覆盖；disabled/缺 metadata → 保持场景导出默认兼容。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _MIRROR_TYPE_ID: StringName = &"basic_single_cell_mirror"

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _SingleCellMirror: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _MoveLimitReader: GDScript = preload("res://gameplay/placement/rules/metadata_move_limit_reader.gd")

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
	await _test_01_limit_one_first_success_second_rejected(scene)
	await _test_02_enabled_two_overrides(scene)
	await _test_03_disabled_and_missing_keep_default(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化、写 move_limit metadata、入树前固定库存 fixture（场景可携带作者 authored inventory_entries，
## 本测试只关心移动限次语义，镜面×3 显式覆盖避免场景内容演化影响基线）、挂入 root 并泵一帧触发真实 _ready。
func _ready_instance(scene: PackedScene, move_limit_meta: Variant, set_meta: bool) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	node.set_meta("inventory_entries", [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
	])
	if set_meta:
		node.set_meta(_MoveLimitReader.METADATA_KEY, move_limit_meta)
	root.add_child(node)
	await process_frame
	return node


## 经真实拖拽链执行一次已放置机关跨格移动（拖起 → 预览 → 松手）；返回是否成功拖起。
## [br]核心的指针解析世界格取自 get_global_mouse_position()（真实鼠标），故每次调用前先泵一帧移动鼠标到目标格中心，
## 保证拖起/预览/松手三步解析到同一格（与真实玩家输入等价的指针事实）。
func _drag_move(node: Node2D, from_cell: Vector2i, to_cell: Vector2i) -> bool:
	await _move_mouse_to(_GridCoordinateRules.cell_to_world(from_cell))
	var drag_flow: Variant = node.get("_drag_flow_controller")
	var began: bool = drag_flow.try_begin_drag(_GridCoordinateRules.cell_to_world(from_cell))
	await _move_mouse_to(_GridCoordinateRules.cell_to_world(to_cell))
	drag_flow.update_preview(_GridCoordinateRules.cell_to_world(to_cell))
	drag_flow.finish_drag(_GridCoordinateRules.cell_to_world(to_cell))
	return began


## 经 InputEventMouseMotion 移动真实鼠标位置并泵一帧使视口换算生效（headless 无物理鼠标）。
func _move_mouse_to(world_position: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = world_position
	motion.global_position = world_position
	Input.parse_input_event(motion)
	await process_frame


## 已用运行期移动次数（LevelRuntimeController 唯一事实持有者）。
func _moves_used(node: Node2D) -> int:
	return int(node.get("_level_runtime_controller").get_runtime_moves_used())


## 剩余运行期移动次数。
func _moves_remaining(node: Node2D) -> int:
	return int(node.get("_level_runtime_controller").get_runtime_moves_remaining())


## 库存剩余数量。
func _inventory_remaining(node: Node2D) -> int:
	return int(node.get("_inventory_controller").get_remaining())


func _free_instance(node: Node2D) -> void:
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. enabled max_count=1 全链：SETUP 放置不扣次 → READY 后非法目标失败不扣 → 首次跨格成功扣 1 →
##    第二次跨格拒绝（机关保持原格、计数不动、库存不被错误扣减）→ R 重置恢复计数。
func _test_01_limit_one_first_success_second_rejected(scene: PackedScene) -> void:
	const NAME: String = "01_limit1首成后拒"
	const CELL_A: Vector2i = Vector2i(2, 6)
	const CELL_B: Vector2i = Vector2i(4, 6)
	const CELL_C: Vector2i = Vector2i(6, 6)
	const WALL_CELL: Vector2i = Vector2i(5, 3)
	var node: Node2D = await _ready_instance(scene, {"enabled": true, "max_count": 1}, true)
	_check(NAME, node.runtime_move_limit == 1, "metadata enabled max_count=1 应覆盖运行期上限为 1，实际 %d。" % [node.runtime_move_limit])
	_check(NAME, _moves_remaining(node) == 1, "初始剩余期望 1。")
	# SETUP 放置库存镜面（SETUP 放置不消耗运行期移动次数）。
	var place_result: Variant = node.get("_placement_controller").place_from_inventory(
		_MIRROR_TYPE_ID, CELL_A, _SingleCellMirror.MirrorOrientation.SLASH
	)
	if not _check(NAME, place_result.is_success(), "SETUP 放置应成功。"):
		await _free_instance(node)
		return
	var inventory_after_place: int = _inventory_remaining(node)
	_check(NAME, _moves_used(node) == 0, "SETUP 放置后 used 期望 0。")
	# 开始运行 → READY_TO_FIRE（运行期计次状态）。
	node.start_run()
	# 非法目标（墙格）失败不扣次：拖起成功、提交被 PlacementController 拒绝、机关回原格、计数与库存不动。
	_check(NAME, await _drag_move(node, CELL_A, WALL_CELL), "墙格移动尝试应能拖起。")
	_check(NAME, node.get_mechanism_at(CELL_A) != &"", "失败移动后机关应保持原格 A。")
	_check(NAME, _moves_used(node) == 0, "非法目标失败不应扣次，used 期望 0。")
	# 首次跨格移动成功：扣 1、机关落 B、库存不被错误扣减。
	_check(NAME, await _drag_move(node, CELL_A, CELL_B), "首次跨格移动应能拖起。")
	_check(NAME, node.get_mechanism_at(CELL_B) != &"", "首次跨格移动后机关应在 B。")
	_check(NAME, node.get_mechanism_at(CELL_A) == &"", "首次跨格移动后原格 A 应空。")
	_check(NAME, _moves_used(node) == 1, "首次成功移动后 used 期望 1。")
	_check(NAME, _moves_remaining(node) == 0, "首次成功移动后剩余期望 0。")
	_check(NAME, _inventory_remaining(node) == inventory_after_place, "成功移动不应扣库存，剩余期望 %d。" % [inventory_after_place])
	# 第二次跨格移动拒绝：达上限（可观察拒绝路径 + push_warning 原因），机关保持 B、计数与库存不动。
	_check(NAME, await _drag_move(node, CELL_B, CELL_C), "达上限后拖起仍应允许（承担回收/取消）。")
	_check(NAME, node.get_mechanism_at(CELL_B) != &"", "被拒移动后机关应保持原格 B。")
	_check(NAME, node.get_mechanism_at(CELL_C) == &"", "被拒目标格 C 不应被占用。")
	_check(NAME, _moves_used(node) == 1, "被拒移动不应扣次，used 期望 1。")
	_check(NAME, _inventory_remaining(node) == inventory_after_place, "被拒移动不应扣库存。")
	# R 重置：清零计数、恢复剩余至上限（库存恢复初始总量由第一批 reset 用例覆盖，此处只断言移动事实）。
	node.reset_runtime()
	_check(NAME, _moves_used(node) == 0, "R 重置后 used 期望 0。")
	_check(NAME, _moves_remaining(node) == 1, "R 重置后剩余应恢复为上限 1。")
	await _free_instance(node)


## 2. enabled max_count=2 → 上限覆盖场景导出值且剩余随量（证明读的是 max_count 而非仅 enabled 开关）。
func _test_02_enabled_two_overrides(scene: PackedScene) -> void:
	const NAME: String = "02_limit2覆盖导出值"
	var node: Node2D = await _ready_instance(scene, {"enabled": true, "max_count": 2}, true)
	_check(NAME, node.runtime_move_limit == 2, "metadata enabled max_count=2 应覆盖为 2，实际 %d。" % [node.runtime_move_limit])
	_check(NAME, _moves_remaining(node) == 2, "初始剩余期望 2。")
	await _free_instance(node)


## 3. disabled / 缺 metadata → 保持场景导出默认兼容（实例化后、入树前的导出原值）。
func _test_03_disabled_and_missing_keep_default(scene: PackedScene) -> void:
	const NAME: String = "03_禁用与缺失保持默认"
	var raw: Node2D = scene.instantiate() as Node2D
	var exported_default: int = raw.runtime_move_limit
	raw.free()
	var disabled_node: Node2D = await _ready_instance(scene, {"enabled": false, "max_count": 9}, true)
	_check(
		NAME,
		disabled_node.runtime_move_limit == exported_default,
		"enabled=false 应保持导出默认 %d，实际 %d。" % [exported_default, disabled_node.runtime_move_limit]
	)
	await _free_instance(disabled_node)
	var missing_node: Node2D = await _ready_instance(scene, null, false)
	_check(
		NAME,
		missing_node.runtime_move_limit == exported_default,
		"metadata 缺失应保持导出默认 %d，实际 %d。" % [exported_default, missing_node.runtime_move_limit]
	)
	_check(
		NAME,
		_moves_remaining(missing_node) == exported_default,
		"metadata 缺失时初始剩余应为导出默认 %d。" % [exported_default]
	)
	await _free_instance(missing_node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 汇总报告：组数、断言数、失败明细；失败非空即整体失败。
func _report() -> void:
	print("core_loop_move_limit：3 组 %d 断言，失败 %d。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % [failure])
