extends SceneTree

## DragFlowController 单元测试（拆分片 1/4 · 库存栏拖拽与放置事务）。
## 覆盖：库存拖拽开始、库存合法放置成功、库存非法格与扣库存事务失败回滚。
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
	_test_01_inventory_drag_begin()
	_test_02_inventory_place_success()
	_test_03_inventory_illegal_and_transaction_fail()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 库存拖拽开始：Context 激活、预览创建、库存不变。
func _test_01_inventory_drag_begin() -> void:
	const NAME: String = "01_库存拖拽开始"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx, false, true, Vector2i(5, 5))
	var ok: bool = ctx.fc.try_begin_drag(Vector2.ZERO)
	_check(NAME, ok, "try_begin_drag 应返回 true。")
	_check(NAME, ctx.fc.is_dragging(), "应处于拖拽中。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL, "库存应不变，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.factory.created_previews.size() == 1, "应创建一个预览节点。")
	_check(NAME, ctx.fc.is_dragging(), "Context 应激活。")


## 2. 库存合法放置成功：PlacementController 被调用、库存扣一、预览清理、Context 清空。
func _test_02_inventory_place_success() -> void:
	const NAME: String = "02_库存放置成功"
	var ctx: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx, false, true, Vector2i(5, 5))
	ctx.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx, false, false, Vector2i(5, 5))
	ctx.fc.update_preview(Vector2.ZERO)
	ctx.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx.fc.is_dragging(), "放置后应结束拖拽。")
	_check(NAME, ctx.pc.get_placed_count() == 1, "应已放置一个机关。")
	_check(NAME, ctx.inv.get_remaining() == _TOTAL - 1, "库存应扣一，实际 %d。" % [ctx.inv.get_remaining()])
	_check(NAME, ctx.factory.created_previews.size() == 1, "应只创建过一个预览。")
	_check(NAME, ctx.factory.created_previews[0].is_queued_for_deletion(), "预览应被 queue_free。")
	_check(NAME, ctx.ui_refresher.count >= 1, "应刷新 UI。")
	_check(NAME, ctx.asserter.count >= 1, "应执行一致性断言。")


## 3. 库存非法或事务失败：库存不变、无正式机关残留、拖拽清理。
func _test_03_inventory_illegal_and_transaction_fail() -> void:
	const NAME: String = "03_库存非法或事务失败"
	# 非法格（边界外）。
	var ctx_a: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _InventoryController.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx_a, false, true, Vector2i(100, 100))
	ctx_a.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx_a, false, false, Vector2i(100, 100))
	ctx_a.fc.update_preview(Vector2.ZERO)
	ctx_a.fc.finish_drag(Vector2.ZERO)
	_check(NAME, not ctx_a.fc.is_dragging(), "非法放置后应结束拖拽。")
	_check(NAME, ctx_a.pc.get_placed_count() == 0, "非法格不应创建正式机关。")
	_check(NAME, ctx_a.inv.get_remaining() == _TOTAL, "非法格库存应不变，实际 %d。" % [ctx_a.inv.get_remaining()])
	_check(NAME, ctx_a.factory.created_previews[0].is_queued_for_deletion(), "非法格预览应被清理。")
	# 事务失败（扣库存失败）。
	var ctx_b: _Fixture._DragCtx = _fixture.make_drag_flow(self, _OccupancyRegistry.new(), _Fixture._FailConsumeInventory.new(_TOTAL), _RuntimeInteractionTypes.RunState.SETUP, 1)
	_fixture.set_drag_pointer(ctx_b, false, true, Vector2i(5, 5))
	ctx_b.fc.try_begin_drag(Vector2.ZERO)
	_fixture.set_drag_pointer(ctx_b, false, false, Vector2i(5, 5))
	ctx_b.fc.update_preview(Vector2.ZERO)
	ctx_b.fc.finish_drag(Vector2.ZERO)
	_check(NAME, ctx_b.pc.get_placed_count() == 0, "事务失败不应残留正式机关。")
	_check(NAME, ctx_b.inv.get_remaining() == _TOTAL, "事务失败库存应不变，实际 %d。" % [ctx_b.inv.get_remaining()])
	_check(NAME, not ctx_b.fc.is_dragging(), "事务失败后应结束拖拽。")


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
	print("==== DragFlowController 库存拖拽与放置 测试摘要 ====")
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
