extends SceneTree

## DragContext 定向自动测试：只通过公开接口验证拖拽临时事实的写入、来源判断、预览格更新、朝向保存与 clear 复位。
## 不创建正式场景、不注册 Autoload、不依赖第三方框架；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _DragContext: GDScript = preload(
	"res://gameplay/interaction/drag_context.gd"
)
const _SingleCellMirror: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)
const _RuntimeInteractionTypes: GDScript = preload(
	"res://gameplay/interaction/runtime_interaction_types.gd"
)

const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_initial_inactive()
	_test_02_begin_inventory()
	_test_03_begin_placed()
	_test_04_source_predicates()
	_test_05_mechanism_id_and_original_cell()
	_test_06_preview_cell_update()
	_test_07_orientation_saved()
	_test_08_clear_resets_all()
	_test_09_begin_again_no_residual()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 初始未激活：source=NONE，is_active()=false。
func _test_01_initial_inactive() -> void:
	const NAME: String = "01_初始未激活"
	var ctx: _DragContext = _DragContext.new()
	_check(NAME, ctx.source == _RuntimeInteractionTypes.DragSource.NONE, "初始 source 应为 NONE。")
	_check(NAME, not ctx.is_active(), "初始 is_active() 应为 false。")
	_check(NAME, not ctx.is_inventory_source(), "初始不应为库存来源。")
	_check(NAME, not ctx.is_placed_source(), "初始不应为已放置来源。")
	_check(NAME, ctx.token_type_id == &"", "初始 token_type_id 应为空。")
	_check(NAME, ctx.mechanism_id == &"", "初始 mechanism_id 应为空。")
	_check(NAME, ctx.original_cell == _DragContext.INVALID_CELL, "初始 original_cell 应为 INVALID_CELL。")
	_check(NAME, ctx.preview_cell == _DragContext.INVALID_CELL, "初始 preview_cell 应为 INVALID_CELL。")


## 2. begin_inventory：来源 INVENTORY，token_type_id 写入，已放置字段清空，预览格写入。
func _test_02_begin_inventory() -> void:
	const NAME: String = "02_begin_inventory"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_inventory(_TOKEN_TYPE, Vector2i(3, 4), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.source == _RuntimeInteractionTypes.DragSource.INVENTORY, "来源应为 INVENTORY。")
	_check(NAME, ctx.is_active(), "is_active() 应为 true。")
	_check(NAME, ctx.is_inventory_source(), "is_inventory_source() 应为 true。")
	_check(NAME, not ctx.is_placed_source(), "is_placed_source() 应为 false。")
	_check(NAME, ctx.token_type_id == _TOKEN_TYPE, "token_type_id 应写入。")
	_check(NAME, ctx.mechanism_id == &"", "库存拖拽 mechanism_id 应为空。")
	_check(NAME, ctx.original_cell == _DragContext.INVALID_CELL, "库存拖拽 original_cell 应为 INVALID_CELL。")
	_check(NAME, ctx.preview_cell == Vector2i(3, 4), "preview_cell 应为初始预览格。")


## 3. begin_placed：来源 PLACED，mechanism_id/原格/预览格写入，库存字段清空。
func _test_03_begin_placed() -> void:
	const NAME: String = "03_begin_placed"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_placed(&"mirror_7", Vector2i(5, 6), Vector2i(5, 6), _SingleCellMirror.MirrorOrientation.BACKSLASH)
	_check(NAME, ctx.source == _RuntimeInteractionTypes.DragSource.PLACED, "来源应为 PLACED。")
	_check(NAME, ctx.is_active(), "is_active() 应为 true。")
	_check(NAME, ctx.is_placed_source(), "is_placed_source() 应为 true。")
	_check(NAME, not ctx.is_inventory_source(), "is_inventory_source() 应为 false。")
	_check(NAME, ctx.mechanism_id == &"mirror_7", "mechanism_id 应写入。")
	_check(NAME, ctx.token_type_id == &"", "已放置拖拽 token_type_id 应为空。")
	_check(NAME, ctx.original_cell == Vector2i(5, 6), "original_cell 应写入。")
	_check(NAME, ctx.preview_cell == Vector2i(5, 6), "preview_cell 应为初始预览格（原格）。")


## 4. 来源判断：库存与已放置互斥。
func _test_04_source_predicates() -> void:
	const NAME: String = "04_来源判断"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_inventory(_TOKEN_TYPE, Vector2i(1, 1), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.is_inventory_source() and not ctx.is_placed_source(), "库存来源时谓词应互斥。")
	ctx.begin_placed(&"m_1", Vector2i(2, 2), Vector2i(2, 2), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.is_placed_source() and not ctx.is_inventory_source(), "已放置来源时谓词应互斥。")
	ctx.clear()
	_check(NAME, not ctx.is_inventory_source() and not ctx.is_placed_source(), "clear 后两侧均应为 false。")


## 5. mechanism_id 和 original_cell：已放置拖拽后可正确读取。
func _test_05_mechanism_id_and_original_cell() -> void:
	const NAME: String = "05_mechanism_id和original_cell"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_placed(&"mirror_42", Vector2i(9, 8), Vector2i(9, 8), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.mechanism_id == &"mirror_42", "mechanism_id 应为 mirror_42。")
	_check(NAME, ctx.original_cell == Vector2i(9, 8), "original_cell 应为 (9,8)。")


## 6. preview_cell 更新：update_preview_cell 改写预览格，不影响其他字段。
func _test_06_preview_cell_update() -> void:
	const NAME: String = "06_preview_cell更新"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_placed(&"m_2", Vector2i(1, 1), Vector2i(1, 1), _SingleCellMirror.MirrorOrientation.SLASH)
	ctx.update_preview_cell(Vector2i(7, 7))
	_check(NAME, ctx.preview_cell == Vector2i(7, 7), "update_preview_cell 后 preview_cell 应为 (7,7)。")
	_check(NAME, ctx.original_cell == Vector2i(1, 1), "更新预览格不应改动 original_cell。")
	_check(NAME, ctx.mechanism_id == &"m_2", "更新预览格不应改动 mechanism_id。")


## 7. orientation 保存：库存拖拽保存 SLASH，已放置拖拽保存传入朝向。
func _test_07_orientation_saved() -> void:
	const NAME: String = "07_orientation保存"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_inventory(_TOKEN_TYPE, Vector2i(1, 1), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.original_orientation == _SingleCellMirror.MirrorOrientation.SLASH, "库存拖拽 orientation 应为 SLASH。")
	ctx.begin_placed(&"m_3", Vector2i(2, 2), Vector2i(2, 2), _SingleCellMirror.MirrorOrientation.BACKSLASH)
	_check(NAME, ctx.original_orientation == _SingleCellMirror.MirrorOrientation.BACKSLASH, "已放置拖拽 orientation 应保存为 BACKSLASH。")


## 8. clear 后全部恢复默认。
func _test_08_clear_resets_all() -> void:
	const NAME: String = "08_clear复位"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_placed(&"m_4", Vector2i(4, 4), Vector2i(4, 4), _SingleCellMirror.MirrorOrientation.BACKSLASH)
	ctx.update_preview_cell(Vector2i(8, 8))
	ctx.clear()
	_check(NAME, ctx.source == _RuntimeInteractionTypes.DragSource.NONE, "clear 后 source 应为 NONE。")
	_check(NAME, not ctx.is_active(), "clear 后 is_active() 应为 false。")
	_check(NAME, ctx.token_type_id == &"", "clear 后 token_type_id 应为空。")
	_check(NAME, ctx.mechanism_id == &"", "clear 后 mechanism_id 应为空。")
	_check(NAME, ctx.original_cell == _DragContext.INVALID_CELL, "clear 后 original_cell 应为 INVALID_CELL。")
	_check(NAME, ctx.preview_cell == _DragContext.INVALID_CELL, "clear 后 preview_cell 应为 INVALID_CELL。")
	_check(NAME, ctx.original_orientation == _SingleCellMirror.MirrorOrientation.SLASH, "clear 后 orientation 应回 SLASH。")


## 9. 连续开始新拖拽不会残留旧事实：库存→已放置切换时旧库存字段清空，反之亦然。
func _test_09_begin_again_no_residual() -> void:
	const NAME: String = "09_连续拖拽无残留"
	var ctx: _DragContext = _DragContext.new()
	ctx.begin_inventory(_TOKEN_TYPE, Vector2i(1, 1), _SingleCellMirror.MirrorOrientation.SLASH)
	ctx.begin_placed(&"m_5", Vector2i(2, 2), Vector2i(2, 2), _SingleCellMirror.MirrorOrientation.BACKSLASH)
	_check(NAME, ctx.mechanism_id == &"m_5", "切换到已放置后 mechanism_id 应为新值。")
	_check(NAME, ctx.token_type_id == &"", "切换到已放置后旧 token_type_id 应清空。")
	_check(NAME, ctx.original_cell == Vector2i(2, 2), "切换到已放置后 original_cell 应为新值。")
	ctx.begin_inventory(_TOKEN_TYPE, Vector2i(3, 3), _SingleCellMirror.MirrorOrientation.SLASH)
	_check(NAME, ctx.token_type_id == _TOKEN_TYPE, "切换回库存后 token_type_id 应为新值。")
	_check(NAME, ctx.mechanism_id == &"", "切换回库存后旧 mechanism_id 应清空。")
	_check(NAME, ctx.original_cell == _DragContext.INVALID_CELL, "切换回库存后 original_cell 应为 INVALID_CELL。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== DragContext 测试摘要 ====")
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
