extends SceneTree

## AF-10 第三批集成测试：metadata inventory_entries 多类型 → 运行期道具卡/独立扣还端到端
## （真实 core_loop_prototype.tscn + 真实 Registry 定义 + 真实拖拽链）。
## 实例化真实场景、入树前写 inventory_entries metadata（不改场景文件），经公开入口与既有私有契约 seam
## （_placement_controller/_drag_flow_controller/_multi_inventory/_inventory_card_bar，同前两批先例）观察：
## 两类型动态生成两卡且旧槽位隐藏、放置只扣对应类型、回收按类型归还、道具卡真实拖拽携带 type_id、
## 拖回机关栏取消不扣、非法目标失败不扣、未知类型条目安全降级（不崩溃不错放不扣库存）、R 重置全类型恢复。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _MIRROR_TYPE_ID: StringName = &"basic_single_cell_mirror"
const _ACCEL_TYPE_ID: StringName = &"particle_accelerator"
const _GHOST_TYPE_ID: StringName = &"ghost_unknown_type"

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _SingleCellMirror: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")
const _ParticleAccelerator: GDScript = preload("res://gameplay/mechanisms/speed/particle_accelerator.gd")
const _CardView: GDScript = preload("res://gameplay/ui/inventory_card_view.gd")

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
	await _test_01_two_types_cards_and_independent_place(scene)
	await _test_02_real_card_drag_routes_type(scene)
	await _test_03_unknown_type_entry_safe(scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化、写 inventory_entries metadata、挂入 root 并泵帧触发真实 _ready（含道具卡构建与布局）。
func _ready_instance(scene: PackedScene, raw_entries: Variant) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	node.set_meta("inventory_entries", raw_entries)
	root.add_child(node)
	await process_frame
	await process_frame
	return node


## 经 InputEventMouseMotion 移动真实鼠标位置并泵一帧使视口换算生效（headless 无物理鼠标）。
func _move_mouse_to(world_position: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = world_position
	motion.global_position = world_position
	Input.parse_input_event(motion)
	await process_frame


## 场内道具卡列表（识别原型槽位容器下的 InventoryCardView；Presenter 私有记录不入测试）。
func _cards_in(node: Node2D) -> Array:
	var cards: Array = []
	for child: Node in node.prototype_token_slot.get_parent().get_children():
		if child.get_script() == _CardView:
			cards.append(child)
	return cards


## 指定类型道具卡（未找到返回 null）。
func _card_for(node: Node2D, type_id: StringName) -> Control:
	for card: Control in _cards_in(node):
		if card.type_id == type_id:
			return card
	return null


## 多类型门面（core_loop 私有 seam，同前两批先例）。
func _multi(node: Node2D) -> Variant:
	return node.get("_multi_inventory")


## 指定类型剩余。
func _remaining_for(node: Node2D, type_id: StringName) -> int:
	return int(_multi(node).get_remaining_for(type_id))


## 机关栏区域内一点（回收/取消松手目标）。
func _bar_point(node: Node2D) -> Vector2:
	return node.inventory_bar.get_global_rect().get_center()


func _free_instance(node: Node2D) -> void:
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. 两类型 metadata：动态生成两卡（旧槽位隐藏）、Σ 聚合、放置只扣对应类型（含 Registry 正式场景
##    实例化 ParticleAccelerator）、回收按类型归还、R 重置全类型恢复满。
func _test_01_two_types_cards_and_independent_place(scene: PackedScene) -> void:
	const NAME: String = "01_两卡独立扣还"
	const CELL_A: Vector2i = Vector2i(2, 6)
	const CELL_B: Vector2i = Vector2i(4, 6)
	var node: Node2D = await _ready_instance(scene, [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 2, "order": 0},
		{"content_type_id": "particle_accelerator", "initial_quantity": 2, "order": 1},
	])
	if not _check(NAME, _multi(node) != null, "有合法条目应进入多类型门面路径。"):
		await _free_instance(node)
		return
	_check(NAME, _multi(node).selected_type_id == _MIRROR_TYPE_ID, "默认选中应为首个类型（镜面）。")
	_check(NAME, node.get("_inventory_card_bar").get_card_count() == 2, "应生成两张道具卡。")
	_check(NAME, not node.prototype_token_slot.visible, "多类型模式旧原型槽位应隐藏。")
	_check(NAME, node.get("_inventory_controller").get_remaining() == 4, "Σ剩余期望 4。")
	# 直接放置事务：加速器扣 1、镜面不动；节点为 Registry 定义正式场景实例化的 ParticleAccelerator。
	var accel_result: Variant = node.get("_placement_controller").place_from_inventory(
		_ACCEL_TYPE_ID, CELL_A, _SingleCellMirror.MirrorOrientation.SLASH
	)
	if not _check(NAME, accel_result.is_success(), "加速器放置应成功。"):
		await _free_instance(node)
		return
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 1, "加速器剩余期望 1。")
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 2, "镜面剩余应保持 2。")
	var accel_id: StringName = node.get_mechanism_at(CELL_A)
	_check(NAME, accel_id != &"", "加速器应占用目标格。")
	var accel_node: Variant = node.get("_placement_controller").get_placed_node(accel_id)
	_check(NAME, accel_node != null and accel_node is _ParticleAccelerator,
		"加速器节点应为正式定义场景实例化的 ParticleAccelerator。")
	# 镜面放置：只扣镜面。
	var mirror_result: Variant = node.get("_placement_controller").place_from_inventory(
		_MIRROR_TYPE_ID, CELL_B, _SingleCellMirror.MirrorOrientation.SLASH
	)
	_check(NAME, mirror_result.is_success(), "镜面放置应成功。")
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 1, "镜面剩余期望 1。")
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 1, "加速器应不受镜面放置影响。")
	# 回收加速器：归还只回加速器栈。
	var recycle_result: Variant = node.get("_placement_controller").recycle_placed(accel_id)
	_check(NAME, recycle_result.is_success(), "回收加速器应成功。")
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 2, "回收后加速器应回满 2。")
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 1, "回收不应错误归还镜面栈（保持 1）。")
	_check(NAME, node.get_mechanism_at(CELL_A) == &"", "回收后目标格应空。")
	# R 重置：全类型恢复满。
	node.reset_runtime()
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 2 and _remaining_for(node, _MIRROR_TYPE_ID) == 2,
		"R 重置后两类型都应恢复满（2/2）。")
	await _free_instance(node)


## 2. 真实道具卡拖拽链：从加速器卡拿取携带 type_id（只扣加速器）、拖回机关栏取消不扣、
##    非法目标（墙格）失败不扣、拖回场上已放置加速器回收入对应类型。
func _test_02_real_card_drag_routes_type(scene: PackedScene) -> void:
	const NAME: String = "02_道具卡拖拽路由"
	const CELL_A: Vector2i = Vector2i(2, 6)
	const WALL_CELL: Vector2i = Vector2i(5, 3)
	var node: Node2D = await _ready_instance(scene, [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 2, "order": 0},
		{"content_type_id": "particle_accelerator", "initial_quantity": 2, "order": 1},
	])
	var accel_card: Control = _card_for(node, _ACCEL_TYPE_ID)
	if not _check(NAME, accel_card != null, "应存在加速器道具卡。"):
		await _free_instance(node)
		return
	var drag_flow: Variant = node.get("_drag_flow_controller")
	# 从加速器卡拖到世界格：选中与扣减都应路由到加速器。
	var card_center: Vector2 = accel_card.get_global_rect().get_center()
	await _move_mouse_to(card_center)
	_check(NAME, drag_flow.try_begin_drag(card_center), "从加速器卡拿取应能开始拖拽。")
	_check(NAME, _multi(node).selected_type_id == _ACCEL_TYPE_ID, "拿取按下应写入选中类型（加速器）。")
	var drop_world: Vector2 = _GridCoordinateRules.cell_to_world(CELL_A)
	await _move_mouse_to(drop_world)
	drag_flow.update_preview(drop_world)
	drag_flow.finish_drag(drop_world)
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 1, "道具卡放置后加速器剩余期望 1。")
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 2, "镜面不应被错误扣减（保持 2）。")
	_check(NAME, node.get_mechanism_at(CELL_A) != &"", "加速器应落目标格。")
	# 拖回机关栏取消：不扣库存。
	var mirror_card: Control = _card_for(node, _MIRROR_TYPE_ID)
	var mirror_center: Vector2 = mirror_card.get_global_rect().get_center()
	await _move_mouse_to(mirror_center)
	_check(NAME, drag_flow.try_begin_drag(mirror_center), "从镜面卡拿取应能开始拖拽。")
	var bar: Vector2 = _bar_point(node)
	await _move_mouse_to(bar)
	drag_flow.update_preview(bar)
	drag_flow.finish_drag(bar)
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 2, "拖回机关栏取消不应扣库存。")
	# 非法目标（墙格）失败：不扣库存、不落节点。
	await _move_mouse_to(mirror_center)
	_check(NAME, drag_flow.try_begin_drag(mirror_center), "再次从镜面卡拿取应能开始。")
	var wall_world: Vector2 = _GridCoordinateRules.cell_to_world(WALL_CELL)
	await _move_mouse_to(wall_world)
	drag_flow.update_preview(wall_world)
	drag_flow.finish_drag(wall_world)
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 2, "墙格失败不应扣镜面库存。")
	_check(NAME, node.get_mechanism_at(WALL_CELL) == &"", "墙格不应被占用。")
	# 拖回场上已放置加速器到机关栏：回收入加速器栈。
	await _move_mouse_to(_GridCoordinateRules.cell_to_world(CELL_A))
	_check(NAME, drag_flow.try_begin_drag(_GridCoordinateRules.cell_to_world(CELL_A)), "拖起已放置加速器应成功。")
	await _move_mouse_to(bar)
	drag_flow.update_preview(bar)
	drag_flow.finish_drag(bar)
	_check(NAME, _remaining_for(node, _ACCEL_TYPE_ID) == 2, "回收应归还加速器栈（回满 2）。")
	_check(NAME, node.get_mechanism_at(CELL_A) == &"", "回收后格应空。")
	await _free_instance(node)


## 3. 未知类型条目：照常建卡（type_id 作显示名 + 占位图标），拿取/放置安全失败不扣库存不错放，不崩溃。
func _test_03_unknown_type_entry_safe(scene: PackedScene) -> void:
	const NAME: String = "03_未知类型安全"
	const CELL_A: Vector2i = Vector2i(2, 6)
	var node: Node2D = await _ready_instance(scene, [
		{"content_type_id": "ghost_unknown_type", "initial_quantity": 1, "order": 0},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 1, "order": 1},
	])
	if not _check(NAME, _multi(node) != null, "含未知条目仍应进入多类型路径。"):
		await _free_instance(node)
		return
	_check(NAME, node.get("_inventory_card_bar").get_card_count() == 2, "未知类型条目应照常建卡（2 张）。")
	var ghost_card: Control = _card_for(node, _GHOST_TYPE_ID)
	if not _check(NAME, ghost_card != null, "应存在未知类型卡。"):
		await _free_instance(node)
		return
	_check(NAME, _cards_in(node)[0].type_id == _GHOST_TYPE_ID, "未知类型卡应按 order 排在首位。")
	_check(NAME, ghost_card.get_node("CardMargin/CardContent/CardTexts/NameLabel").text == "ghost_unknown_type",
		"未知类型卡显示名应为 type_id。")
	# 真实拖拽未知卡：预览与放置安全失败（不崩溃、不扣库存、不落节点）。
	var drag_flow: Variant = node.get("_drag_flow_controller")
	var center: Vector2 = ghost_card.get_global_rect().get_center()
	await _move_mouse_to(center)
	var began: bool = drag_flow.try_begin_drag(center)
	var drop_world: Vector2 = _GridCoordinateRules.cell_to_world(CELL_A)
	await _move_mouse_to(drop_world)
	if began:
		drag_flow.update_preview(drop_world)
		drag_flow.finish_drag(drop_world)
	_check(NAME, _remaining_for(node, _GHOST_TYPE_ID) == 1, "未知类型放置失败不应扣库存（保持 1）。")
	_check(NAME, node.get_mechanism_at(CELL_A) == &"", "未知类型不应落正式节点。")
	# 同关镜面照常可放（未知条目不拖垮合法类型）。
	var mirror_result: Variant = node.get("_placement_controller").place_from_inventory(
		_MIRROR_TYPE_ID, CELL_A, _SingleCellMirror.MirrorOrientation.SLASH
	)
	_check(NAME, mirror_result.is_success(), "未知条目在场时镜面放置应照常成功。")
	_check(NAME, _remaining_for(node, _MIRROR_TYPE_ID) == 0, "镜面剩余期望 0。")
	await _free_instance(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 汇总报告：组数、断言数、失败明细；失败非空即整体失败。
func _report() -> void:
	print("core_loop_multi_type_inventory：3 组 %d 断言，失败 %d。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % [failure])
