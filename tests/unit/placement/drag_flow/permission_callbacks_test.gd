extends SceneTree

## DragFlowController 单元测试（拆分片 4/4 · 状态权限、连续拖拽清理与回调时点）。
## 覆盖：COMPLETED 权限拒绝、连续拖拽之间无旧节点/旧事实残留、UI 刷新与一致性断言只在正确时点执行。
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
	_test_11_permission_denied()
	_test_12_consecutive_drags_no_residual()
	_test_14_ui_and_consistency_callbacks()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 11. 权限拒绝：不开始拖拽、不创建预览。
func _test_11_permission_denied() -> void:
	const NAME: String = "11_权限拒绝"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.COMPLETED, 0)
	_fixture.set_drag_pointer(ctx, false, true, Vector2i(5, 5))
	var ok_inv: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, not ok_inv, "COMPLETED 库存拖拽应被拒绝。")
	_check(NAME, not ctx.fc.is_dragging(), "不应进入拖拽。")
	_check(NAME, ctx.factory.created_previews.size() == 0, "不应创建预览。")
	# COMPLETED 下已放置机关拖起亦被拒绝。
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	var ok_placed: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, not ok_placed, "COMPLETED 已放置拖拽应被拒绝。")
	_check(NAME, ctx.factory.created_previews.size() == 0, "COMPLETED 不应创建预览。")


## 12. 连续拖拽之间无旧节点或旧事实残留。
func _test_12_consecutive_drags_no_residual() -> void:
	const NAME: String = "12_连续拖拽无残留"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	# 第一次：库存拖拽后取消。
	_fixture.set_drag_pointer(ctx, false, true, Vector2i(5, 5))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ctx.fc.is_dragging(), "第一次应进入拖拽。")
	ctx.fc.cancel_current_drag()
	_check(NAME, not ctx.fc.is_dragging(), "第一次取消后应结束拖拽。")
	# 第二次：已放置机关拖拽。
	var placed := ctx.pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), 1)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(1, 1))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ctx.fc.is_dragging(), "第二次应进入拖拽。")
	_check(NAME, ctx.factory.created_previews.size() == 2, "应累计创建两个预览，实际 %d。" % [ctx.factory.created_previews.size()])
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "第一次预览应已清理。")
	_check(NAME, not ctx.factory.created_previews[1].is_queued_for_deletion(), "第二次预览应仍存活。")
	ctx.fc.cancel_current_drag()


## 14. UI 刷新与一致性回调只在正确时点执行。
func _test_14_ui_and_consistency_callbacks() -> void:
	const NAME: String = "14_回调时点"
	# 取消（无状态变化）：触发断言，不刷新 UI。
	var ctx_a: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx_a, false, true, Vector2i(5, 5))
	ctx_a.fc.try_begin_drag(Vector2.ZERO)
	ctx_a.fc.cancel_current_drag()
	_check(NAME, ctx_a.ui_refresher.count == 0, "取消不应刷新 UI，实际 %d。" % [ctx_a.ui_refresher.count])
	_check(NAME, ctx_a.asserter.count >= 1, "普通取消应执行一致性断言。")
	# R 取消（should_assert_consistency=false）：不触发断言，不刷新 UI。
	var ctx_b: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx_b, false, true, Vector2i(5, 5))
	ctx_b.fc.try_begin_drag(Vector2.ZERO)
	ctx_b.fc.cancel_current_drag(false)
	_check(NAME, ctx_b.ui_refresher.count == 0, "R 取消不应刷新 UI。")
	_check(NAME, ctx_b.asserter.count == 0, "R 取消不应执行一致性断言。")
	# 库存放置成功：刷新 UI + 断言各至少一次。
	var ctx_c: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx_c, false, true, Vector2i(5, 5))
	ctx_c.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx_c, false, false, Vector2i(5, 5))
	ctx_c.fc.update_preview(Vector2.ZERO)
	ctx_c.fc.finish_drag(Vector2.ZERO)
	_check(NAME, ctx_c.ui_refresher.count >= 1, "放置成功应刷新 UI。")
	_check(NAME, ctx_c.asserter.count >= 1, "放置成功应执行断言。")


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
	print("==== DragFlowController 权限与回调 测试摘要 ====")
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
