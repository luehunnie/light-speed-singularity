extends SceneTree

## DragFlowController 单元测试（拆分片 2/4 · 已放置对象重新拖拽与移动事务）。
## 覆盖：已放置机关拖起、原格松手、非法格松手、成功跨格移动、跨格后 orientation 保持。
## 只通过公开接口验证一次拖拽的业务生命周期；桩与装配见 fixtures/placement_flow_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)
const _Fixture: GDScript = preload(
	"res://tests/unit/placement/fixtures/placement_flow_fixture.gd"
)

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"
const _TOTAL: int = 3

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 持有装配夹具，避免工厂 RefCounted 在 Callable 单引用下被提前回收导致 null::create。
var _fixture: _Fixture = null


func _initialize() -> void:
	_fixture = _Fixture.new()
	_test_04_placed_drag_begin()
	_test_05_original_cell_release()
	_test_06_illegal_cell_release()
	_test_07_cross_cell_move_success()
	_test_13_orientation_preserved()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 4. 已放置机关拖拽开始：原节点隐藏、原占用与映射仍存在。
func _test_04_placed_drag_begin() -> void:
	const NAME: String = "04_已放置拖拽开始"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	var ok: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ok, "try_begin_drag 应返回 true。")
	_check(NAME, ctx.fc.is_dragging(), "应处于拖拽中。")
	_check(NAME, not token.placed_visible, "正式节点应被隐藏。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")
	_check(NAME, ctx.pc.has_placed(placed.mechanism_id), "映射应保留。")
	_check(NAME, ctx.factory.created_previews.size() == 1, "应创建预览。")


## 5. 原格松手：节点恢复、不请求扣移动次数。
func _test_05_original_cell_release() -> void:
	const NAME: String = "05_原格松手"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "原格松手应结束拖拽。")
	_check(NAME, token.placed_visible, "节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应仍在原格。")
	_check(NAME, ctx.move_consumer.count == 0, "原格松手不应扣移动次数。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


## 6. 非法格松手：节点恢复原格和显示、不扣次数。
func _test_06_illegal_cell_release() -> void:
	const NAME: String = "06_非法格松手"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(100, 100))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "非法格松手应结束拖拽。")
	_check(NAME, token.placed_visible, "节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "节点应回原格，实际 %s。" % [token.cell])
	_check(NAME, ctx.move_consumer.count == 0, "非法格不应扣次数。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


## 7. 成功跨格：调用 move_placed、节点最终显示、只请求扣一次移动次数。
func _test_07_cross_cell_move_success() -> void:
	const NAME: String = "07_成功跨格"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(3, 3))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "跨格成功应结束拖拽。")
	_check(NAME, token.cell == Vector2i(3, 3), "节点应移至目标格，实际 %s。" % [token.cell])
	_check(NAME, token.placed_visible, "节点应最终显示。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(3, 3)) == placed.mechanism_id, "新占用应成立。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == &"", "旧占用应移除。")
	_check(NAME, ctx.move_consumer.count == 1, "应只扣一次移动次数，实际 %d。" % [ctx.move_consumer.count])
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "移动不应改变库存。")


## 13. orientation 保持：拖拽/移动/取消不改写正式机关 orientation。
func _test_13_orientation_preserved() -> void:
	const NAME: String = "13_orientation保持"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	token.set_orientation(2)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(3, 3))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, token.orientation == 2, "跨格移动后 orientation 应保持为 2，实际 %s。" % [token.orientation])
	_check(NAME, token.cell == Vector2i(3, 3), "节点应已移至目标格。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== DragFlowController 已放置拖拽与移动 测试摘要 ====")
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
