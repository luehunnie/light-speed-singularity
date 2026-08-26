extends SceneTree

## MetadataInventoryReader 定向自动测试（AF-10 第一批）。
## 只通过公开静态接口观察读取结果与兼容语义：缺失 metadata 退回默认值、正常条目取数量、
## 负数量钳 0、非 Array 退回默认值、非法条目跳过不中断、无匹配类型为 0、重复条目以首个为准。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _Reader: GDScript = preload(
	"res://gameplay/placement/inventory/metadata_inventory_reader.gd"
)

const _TYPE_MIRROR: StringName = &"basic_single_cell_mirror"
const _TYPE_OTHER: StringName = &"particle_accelerator"
const _FALLBACK: int = 7

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_missing_metadata_falls_back()
	_test_02_valid_entry_reads_quantity()
	_test_03_negative_quantity_clamps_to_zero()
	_test_04_non_array_metadata_falls_back()
	_test_05_invalid_entries_skipped_others_still_parsed()
	_test_06_no_matching_type_returns_zero()
	_test_07_duplicate_type_first_wins()
	_test_08_non_int_quantity_entry_skipped()
	_test_09_bad_order_does_not_block_entry()
	_test_10_null_root_falls_back()
	_test_11_ordered_entries_sort_and_shape()
	_test_12_ordered_entries_empty_and_invalid()
	_test_13_ordered_entries_duplicate_first_wins()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 构造带 inventory_entries metadata 的游离节点（set_meta 不依赖场景树）。
func _make_level(raw_entries: Variant, has_metadata: bool = true) -> Node:
	var node: Node = Node.new()
	if has_metadata:
		node.set_meta("inventory_entries", raw_entries)
	return node


func _read(node: Node) -> int:
	return _Reader.read_initial_total_for_type(node, _TYPE_MIRROR, _FALLBACK)


# ===== 用例 =====

## 1. 缺失 metadata：返回兼容默认值（原型 PROTOTYPE_TOKEN_TOTAL 语义）。
func _test_01_missing_metadata_falls_back() -> void:
	const NAME: String = "01_缺失metadata兼容"
	var node: Node = _make_level(null, false)
	_check(NAME, _read(node) == _FALLBACK, "缺失 metadata 应返回默认值 %d。" % [_FALLBACK])
	node.free()


## 2. 正常条目：按 content_type_id 匹配读取 initial_quantity；他类型条目不影响。
func _test_02_valid_entry_reads_quantity() -> void:
	const NAME: String = "02_正常条目读取"
	var node: Node = _make_level([
		{"content_type_id": "particle_accelerator", "initial_quantity": 5, "order": 1},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
	])
	_check(NAME, _read(node) == 3, "镜面类型初始数量期望 3。")
	node.free()


## 3. 负数量：LevelInventoryEntry 构造钳为 0（本关不提供该类型）。
func _test_03_negative_quantity_clamps_to_zero() -> void:
	const NAME: String = "03_负数量钳0"
	var node: Node = _make_level([
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": -4, "order": 0},
	])
	_check(NAME, _read(node) == 0, "负数量应钳为 0。")
	node.free()


## 4. metadata 非 Array：push_error 可诊断并退回默认值。
func _test_04_non_array_metadata_falls_back() -> void:
	const NAME: String = "04_非Array退回默认"
	var node: Node = _make_level("not-an-array")
	_check(NAME, _read(node) == _FALLBACK, "非 Array metadata 应退回默认值 %d。" % [_FALLBACK])
	node.free()


## 5. 非法条目（非 Dictionary/缺字段）跳过，后续合法条目仍被解析。
func _test_05_invalid_entries_skipped_others_still_parsed() -> void:
	const NAME: String = "05_非法条目跳过"
	var node: Node = _make_level([
		"garbage-entry",
		{"initial_quantity": 9, "order": 0},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 2, "order": 2},
	])
	_check(NAME, _read(node) == 2, "非法条目应跳过且不中断，镜面数量期望 2。")
	node.free()


## 6. metadata 存在但无匹配类型条目：返回 0（显式不提供），不退回默认值。
func _test_06_no_matching_type_returns_zero() -> void:
	const NAME: String = "06_无匹配类型为0"
	var node: Node = _make_level([
		{"content_type_id": "particle_accelerator", "initial_quantity": 5, "order": 0},
	])
	_check(NAME, _read(node) == 0, "无镜面条目应返回 0（本关不提供）。")
	node.free()


## 7. 同类型重复条目：以首个为准（确定性诊断语义）。
func _test_07_duplicate_type_first_wins() -> void:
	const NAME: String = "07_重复条目取首个"
	var node: Node = _make_level([
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 8, "order": 1},
	])
	_check(NAME, _read(node) == 3, "重复条目应以首个数量 3 为准。")
	node.free()


## 8. 数量非 int（float）：条目跳过；仅有该条目时结果为 0。
func _test_08_non_int_quantity_entry_skipped() -> void:
	const NAME: String = "08_非int数量跳过"
	var node: Node = _make_level([
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3.0, "order": 0},
	])
	_check(NAME, _read(node) == 0, "float 数量条目应跳过，无有效条目结果为 0。")
	node.free()


## 9. order 缺省/非法：不阻断条目解析（order 本批仅保留）。
func _test_09_bad_order_does_not_block_entry() -> void:
	const NAME: String = "09_order非法不阻断"
	var node: Node = _make_level([
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 4},
	])
	_check(NAME, _read(node) == 4, "order 缺省不应阻断解析，数量期望 4。")
	node.free()


## 10. 关卡根为 null：push_error 可诊断并退回默认值。
func _test_10_null_root_falls_back() -> void:
	const NAME: String = "10_空根退回默认"
	_check(
		NAME,
		_Reader.read_initial_total_for_type(null, _TYPE_MIRROR, _FALLBACK) == _FALLBACK,
		"null 关卡根应返回默认值 %d。" % [_FALLBACK]
	)


## 11. read_ordered_entries（AF-10 第三批）：order 升序、同 order 保持书写序、条目三字段形状。
func _test_11_ordered_entries_sort_and_shape() -> void:
	const NAME: String = "11_多类型计划排序形状"
	var node: Node = _make_level([
		{"content_type_id": "particle_accelerator", "initial_quantity": 5, "order": 2},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
		{"content_type_id": "particle_decelerator", "initial_quantity": 1, "order": 1},
	])
	var plan: Array = _Reader.read_ordered_entries(node)
	_check(NAME, plan.size() == 3, "合法条目应全部保留，期望 3，实际 %d。" % [plan.size()])
	if plan.size() == 3:
		_check(NAME, StringName(plan[0]["content_type_id"]) == _TYPE_MIRROR
			and StringName(plan[1]["content_type_id"]) == &"particle_decelerator"
			and StringName(plan[2]["content_type_id"]) == _TYPE_OTHER,
			"应按 order 升序（镜面/减速/加速），实际 %s。" % [str(plan)])
		_check(NAME, int(plan[0]["initial_quantity"]) == 3 and int(plan[0]["order"]) == 0,
			"首条目应为镜面 数量3 order0。")
	node.free()
	# 同 order 稳定排序：保持 metadata 书写序。
	var stable: Node = _make_level([
		{"content_type_id": "type_b", "initial_quantity": 1, "order": 5},
		{"content_type_id": "type_a", "initial_quantity": 2, "order": 5},
	])
	var stable_plan: Array = _Reader.read_ordered_entries(stable)
	_check(NAME, stable_plan.size() == 2 and StringName(stable_plan[0]["content_type_id"]) == &"type_b",
		"同 order 应保持书写序（b 在前）。")
	stable.free()


## 12. read_ordered_entries：缺失 metadata / 非 Array / 无合法条目 / null 根 → 空数组（调用方回退）。
func _test_12_ordered_entries_empty_and_invalid() -> void:
	const NAME: String = "12_多类型计划空回退"
	var missing: Node = _make_level(null, false)
	_check(NAME, _Reader.read_ordered_entries(missing).is_empty(), "缺失 metadata 应返回空数组。")
	missing.free()
	var not_array: Node = _make_level("not-an-array")
	_check(NAME, _Reader.read_ordered_entries(not_array).is_empty(), "非 Array metadata 应返回空数组。")
	not_array.free()
	var all_invalid: Node = _make_level(["garbage", {"initial_quantity": 3, "order": 0}, 42])
	_check(NAME, _Reader.read_ordered_entries(all_invalid).is_empty(), "全部非法条目应返回空数组。")
	all_invalid.free()
	_check(NAME, _Reader.read_ordered_entries(null).is_empty(), "null 根应返回空数组。")


## 13. read_ordered_entries：重复类型以首个为准（与 read_initial_total_for_type 同语义）。
func _test_13_ordered_entries_duplicate_first_wins() -> void:
	const NAME: String = "13_多类型计划重复取首"
	var node: Node = _make_level([
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 8, "order": 1},
		{"content_type_id": "particle_accelerator", "initial_quantity": 2, "order": 2},
	])
	var plan: Array = _Reader.read_ordered_entries(node)
	_check(NAME, plan.size() == 2, "重复类型应只保留首个，期望 2 条，实际 %d。" % [plan.size()])
	if plan.size() == 2:
		_check(NAME, StringName(plan[0]["content_type_id"]) == _TYPE_MIRROR and int(plan[0]["initial_quantity"]) == 3,
			"重复类型应以首个数量 3 为准。")
	node.free()


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 13
	var passed_checks: int = _checks - _failures.size()
	print("==== 库存metadata读取器定向测试摘要 ====")
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
