extends SceneTree

## DragFlowController 单元测试（拆分片 3/4 · 拖回机关栏回收与取消事务）。
## 覆盖：回收成功、回收失败恢复正式节点、cancel_current_drag 恢复拖拽前状态。
## 只通过公开接口验证一次拖拽的业务生命周期；桩与装配见 fixtures/placement_flow_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 失败路径用例会产生预期 push_error 输出，不计入失败。

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
	_test_08_recycle_success()
	_test_09_recycle_failure()
	_test_10_cancel_current_drag()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 8. 回收成功：调用 recycle_placed、不扣移动次数、库存增加。
func _test_08_recycle_success() -> void:
	const NAME: String = "08_回收成功"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, true, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "回收后应结束拖拽。")
	_check(NAME, not ctx.pc.has_placed(placed.mechanism_id), "映射应已移除。")
	_check(NAME, not ctx.occ.has_mechanism(placed.mechanism_id), "占用应已移除。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL, "库存应恢复满，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.move_consumer.count == 0, "回收不应扣移动次数。")


## 9. 回收失败：正式节点恢复、库存不变。
func _test_09_recycle_failure() -> void:
	const NAME: String = "09_回收失败"
	var occ: _Fixture._FailUnregisterForIdRegistry = _Fixture._FailUnregisterForIdRegistry.new()
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, occ, _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.MOVE_WINDOW, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	occ.fail_id = placed.mechanism_id
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, true, false, Vector2i(1, 1))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "回收失败后应结束拖拽。")
	_check(NAME, ctx.pc.has_placed(placed.mechanism_id), "回收失败映射应保留。")
	_check(NAME, ctx.occ.has_mechanism(placed.mechanism_id), "回收失败占用应保留。")
	_check(NAME, token.placed_visible, "正式节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "正式节点应回原格。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "回收失败库存应不变。")


## 10. cancel_current_drag：预览清理、正式节点恢复、Context 清空。
func _test_10_cancel_current_drag() -> void:
	const NAME: String = "10_cancel_current_drag"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	var token: _Fixture._DragStubToken = ctx.pc.get_placed_node(placed.mechanism_id) as _Fixture._DragStubToken
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	ctx.fc.cancel_current_drag()
	_check(NAME, not ctx.fc.is_dragging(), "取消后应结束拖拽。")
	_check(NAME, token.placed_visible, "正式节点应恢复可见。")
	_check(NAME, token.cell == Vector2i(1, 1), "正式节点应回原格。")
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "预览应被清理。")
	_check(NAME, ctx.occ.get_mechanism_at(Vector2i(1, 1)) == placed.mechanism_id, "原占用应保留。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 3
	var passed_checks: int = _checks - _failures.size()
	print("==== DragFlowController 回收与取消 测试摘要 ====")
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
