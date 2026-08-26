extends SceneTree

## MetadataMoveLimitReader 定向自动测试（AF-10 第二批）。
## 只通过公开静态接口观察读取结果与兼容语义：缺失 metadata 退回默认值、enabled=false 退回默认值、
## enabled=true 取 max_count、手写 max_count<1 钳 1（编辑器侧 validate 已保证 ≥1，此处防绕过）、
## 非 Dictionary 退回默认值、字段缺失按缺省（enabled 缺省 false / max_count 缺省 1）、空根退回默认值。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _Reader: GDScript = preload(
	"res://gameplay/placement/rules/metadata_move_limit_reader.gd"
)

const _FALLBACK: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_missing_metadata_falls_back()
	_test_02_disabled_falls_back()
	_test_03_enabled_reads_max_count()
	_test_04_enabled_below_one_clamps_to_one()
	_test_05_non_dictionary_falls_back()
	_test_06_missing_fields_use_defaults()
	_test_07_null_root_falls_back()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 构造带 move_limit metadata 的游离节点（set_meta 不依赖场景树），读取后释放防泄漏。
func _read_via(raw: Variant, has_metadata: bool = true) -> int:
	var node: Node = _make_level(raw, has_metadata)
	var result: int = _Reader.read_runtime_move_limit(node, _FALLBACK)
	node.free()
	return result


func _make_level(raw: Variant, has_metadata: bool = true) -> Node:
	var node: Node = Node.new()
	if has_metadata:
		node.set_meta("move_limit", raw)
	return node


# ===== 用例 =====

## 1. metadata 缺失 → 默认值（关卡未配置的原型兼容语义）。
func _test_01_missing_metadata_falls_back() -> void:
	const NAME: String = "01_缺metadata退默认"
	_check(NAME, _read_via(null, false) == _FALLBACK, "metadata 缺失应退回默认值 %d。" % [_FALLBACK])


## 2. enabled=false → 默认值（禁用不落语义，不用 -1 哨兵；max_count 即使有值也不生效）。
func _test_02_disabled_falls_back() -> void:
	const NAME: String = "02_禁用退默认"
	_check(
		NAME,
		_read_via({"enabled": false, "max_count": 9}) == _FALLBACK,
		"enabled=false 应退回默认值，不读 max_count。"
	)


## 3. enabled=true → 取 max_count。
func _test_03_enabled_reads_max_count() -> void:
	const NAME: String = "03_启用取max_count"
	_check(NAME, _read_via({"enabled": true, "max_count": 2}) == 2, "enabled=true 应取 max_count=2。")


## 4. 手写 metadata 绕过编辑器校验（max_count<1）→ 钳 1，不用 -1 哨兵、不产生零上限卡死。
func _test_04_enabled_below_one_clamps_to_one() -> void:
	const NAME: String = "04_启用max_count钳1"
	_check(NAME, _read_via({"enabled": true, "max_count": 0}) == 1, "max_count=0 应钳为 1。")
	_check(NAME, _read_via({"enabled": true, "max_count": -3}) == 1, "max_count=-3 应钳为 1。")


## 5. metadata 非 Dictionary → push_error 诊断后退回默认值。
func _test_05_non_dictionary_falls_back() -> void:
	const NAME: String = "05_非Dictionary退默认"
	_check(NAME, _read_via(3) == _FALLBACK, "非 Dictionary metadata 应退回默认值。")


## 6. 字段缺失按缺省：enabled 缺省 false → 默认值；enabled=true 且 max_count 缺省 → 1。
func _test_06_missing_fields_use_defaults() -> void:
	const NAME: String = "06_字段缺失用缺省"
	_check(NAME, _read_via({}) == _FALLBACK, "空 Dictionary enabled 缺省 false 应退回默认值。")
	_check(NAME, _read_via({"enabled": true}) == 1, "enabled=true 且 max_count 缺省应为 1。")


## 7. 空根 → push_error 诊断后退回默认值。
func _test_07_null_root_falls_back() -> void:
	const NAME: String = "07_空根退默认"
	_check(NAME, _Reader.read_runtime_move_limit(null, _FALLBACK) == _FALLBACK, "level_root 为空应退回默认值。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 汇总报告：组数、断言数、失败明细；失败非空即整体失败。
func _report() -> void:
	print("MetadataMoveLimitReader：7 组 %d 断言，失败 %d。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % [failure])
