extends SceneTree

## AF-03 Level Inventory Runtime / Entry 定向合同测试（Guide §15.1/§15.2/§15.5 + §16）。
## 覆盖：Authoring Entry 形状（三字段、无配置面、数量钳制）、setup（order 排序/重复拒绝/非法拒绝零变更）、
## type_id → quantity 多类型数量池、Spawn 预留两阶段（reserve/commit/cancel）、回还预留两阶段、
## Reset restore、一致性判断与残留校准、detached 快照。
## headless extends SceneTree；全部通过 quit(0)，任一失败 quit(1)。


const _LevelInventoryEntry: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_entry.gd"
)
const _LevelInventoryRuntime: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_runtime.gd"
)

const _MIRROR: StringName = &"basic_single_cell_mirror"
const _ACCELERATOR: StringName = &"particle_accelerator"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_entry_shape()
	_test_02_setup_order_and_rejection()
	_test_03_spawn_reservation_two_phase()
	_test_04_return_reservation_two_phase()
	_test_05_reset_and_reconcile()
	_test_06_snapshot_detached()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. Entry 形状：数量负值钳为 0；空类型非法；配置覆盖面不存在（形状即约束）。
func _test_01_entry_shape() -> void:
	const NAME: String = "01_Entry形状"
	var entry: _LevelInventoryEntry = _LevelInventoryEntry.new(_MIRROR, -3, 2)
	_check(NAME, entry.initial_quantity == 0, "负数量应钳为 0。")
	_check(NAME, entry.validate().is_empty(), "合法条目零错误。")
	var bad: _LevelInventoryEntry = _LevelInventoryEntry.new(&"", 1, 0)
	_check(NAME, not bad.validate().is_empty(), "空类型应非法。")


## 2. setup：order 升序生效；重复 type_id / 非法条目 / 非成员拒绝且旧池零变更。
func _test_02_setup_order_and_rejection() -> void:
	const NAME: String = "02_setup"
	var runtime: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	var ok: bool = runtime.setup([
		_LevelInventoryEntry.new(_ACCELERATOR, 2, 5),
		_LevelInventoryEntry.new(_MIRROR, 3, 1),
	])
	_check(NAME, ok, "合法条目 setup 应成功。")
	_check(NAME, runtime.get_type_ids() == [_MIRROR, _ACCELERATOR], "类型清单应按 order 升序。")
	_check(NAME, runtime.get_total(_MIRROR) == 3 and runtime.get_remaining(_MIRROR) == 3, "镜初始满库存 3。")
	_check(NAME, runtime.get_total(_ACCELERATOR) == 2, "加速器初始 2。")
	_check(NAME, not runtime.setup([_LevelInventoryEntry.new(_MIRROR, 1, 0), _LevelInventoryEntry.new(_MIRROR, 1, 1)]), "重复类型应拒绝。")
	_check(NAME, not runtime.setup(["不是条目"]), "非成员应拒绝。")
	_check(NAME, runtime.get_remaining(_MIRROR) == 3, "失败 setup 零变更。")
	_check(NAME, not runtime.has_type(&"unknown") and runtime.get_remaining(&"unknown") == 0, "未登记类型查询安全。")


## 3. Spawn 预留两阶段：reserve 锁容量不动 remaining；commit 才扣；cancel 释放；容量尽拒绝。
func _test_03_spawn_reservation_two_phase() -> void:
	const NAME: String = "03_Spawn预留"
	var runtime: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	runtime.setup([_LevelInventoryEntry.new(_MIRROR, 1, 0)])
	_check(NAME, runtime.try_reserve_spawn(_MIRROR), "满库存应可预留。")
	_check(NAME, runtime.get_remaining(_MIRROR) == 1 and runtime.get_reserved_spawn(_MIRROR) == 1, "预留不动 remaining。")
	_check(NAME, not runtime.try_reserve_spawn(_MIRROR), "容量已锁尽应拒绝二次预留。")
	_check(NAME, runtime.commit_reserved_spawn(_MIRROR), "确认预留应成功。")
	_check(NAME, runtime.get_remaining(_MIRROR) == 0 and runtime.get_reserved_spawn(_MIRROR) == 0, "确认后正式消耗。")
	_check(NAME, not runtime.try_reserve_spawn(_MIRROR), "耗尽后不可再预留。")
	_check(NAME, not runtime.commit_reserved_spawn(_MIRROR), "无预留确认应失败。")
	_check(NAME, runtime.cancel_reserved_spawn(_MIRROR) == false, "无预留取消应失败。")
	# cancel 路径：预留后取消 → 容量回到可预留。
	runtime.setup([_LevelInventoryEntry.new(_MIRROR, 1, 0)])
	runtime.try_reserve_spawn(_MIRROR)
	_check(NAME, runtime.cancel_reserved_spawn(_MIRROR), "取消预留应成功。")
	_check(NAME, runtime.get_remaining(_MIRROR) == 1 and runtime.try_reserve_spawn(_MIRROR), "取消后容量恢复可预留。")


## 4. 回还预留两阶段：reserve 锁归还容量；commit 才加 remaining；cancel 释放；与 Spawn 预留互斥容量。
func _test_04_return_reservation_two_phase() -> void:
	const NAME: String = "04_回还预留"
	var runtime: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	runtime.setup([_LevelInventoryEntry.new(_ACCELERATOR, 2, 0)])
	runtime.try_reserve_spawn(_ACCELERATOR)
	runtime.commit_reserved_spawn(_ACCELERATOR)
	_check(NAME, runtime.get_remaining(_ACCELERATOR) == 1, "消耗后剩余 1。")
	_check(NAME, runtime.try_reserve_return(_ACCELERATOR), "未满应可预留回还。")
	_check(NAME, runtime.get_remaining(_ACCELERATOR) == 1 and runtime.get_reserved_return(_ACCELERATOR) == 1, "回还预留不动 remaining。")
	_check(NAME, not runtime.try_reserve_return(_ACCELERATOR), "剩余+预留已达总量应拒绝。")
	_check(NAME, runtime.commit_reserved_return(_ACCELERATOR), "确认回还应成功。")
	_check(NAME, runtime.get_remaining(_ACCELERATOR) == 2, "确认后归还。")
	_check(NAME, not runtime.commit_reserved_return(_ACCELERATOR), "无回还预留确认应失败。")
	# cancel 路径：先消耗一单位腾出容量，预留回还后取消。
	runtime.try_reserve_spawn(_ACCELERATOR)
	runtime.commit_reserved_spawn(_ACCELERATOR)
	runtime.try_reserve_return(_ACCELERATOR)
	_check(NAME, runtime.cancel_reserved_return(_ACCELERATOR), "取消回还预留应成功。")
	_check(NAME, runtime.get_remaining(_ACCELERATOR) == 1, "取消不动 remaining。")


## 5. Reset restore 恢复初始并清预留；残留校准按公式钳制并暴露越界。
func _test_05_reset_and_reconcile() -> void:
	const NAME: String = "05_Reset与校准"
	var runtime: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	runtime.setup([
		_LevelInventoryEntry.new(_MIRROR, 3, 0),
		_LevelInventoryEntry.new(_ACCELERATOR, 2, 1),
	])
	runtime.try_reserve_spawn(_MIRROR)
	runtime.commit_reserved_spawn(_MIRROR)
	runtime.reset_to_initial()
	_check(NAME, runtime.get_remaining(_MIRROR) == 3 and runtime.get_remaining(_ACCELERATOR) == 2, "Reset 恢复全部初始数量。")
	_check(NAME, runtime.get_reserved_spawn(_MIRROR) == 0, "Reset 清除遗留预留。")
	runtime.try_reserve_spawn(_MIRROR)
	runtime.commit_reserved_spawn(_MIRROR)
	_check(NAME, runtime.is_consistent_with_spawned_count(_MIRROR, 1), "remaining+spawned==total 一致性成立。")
	_check(NAME, not runtime.is_consistent_with_spawned_count(_MIRROR, 0), "不一致计数应判 false。")
	_check(NAME, runtime.reconcile_with_spawned_count(_MIRROR, 1), "合法残留校准返回 true。")
	_check(NAME, runtime.get_remaining(_MIRROR) == 2, "校准按公式扣除残留。")
	_check(NAME, not runtime.reconcile_with_spawned_count(_MIRROR, 9), "越界残留返回 false。")


## 6. 全池 detached 快照：篡改不影响内部事实。
func _test_06_snapshot_detached() -> void:
	const NAME: String = "06_快照"
	var runtime: _LevelInventoryRuntime = _LevelInventoryRuntime.new()
	runtime.setup([_LevelInventoryEntry.new(_MIRROR, 2, 0)])
	var snapshot: Dictionary = runtime.snapshot()
	snapshot[_MIRROR]["remaining"] = 99
	_check(NAME, runtime.get_remaining(_MIRROR) == 2, "快照篡改不影响数量池。")


## 单项断言。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 报告。
func _report() -> void:
	print("level_inventory_runtime_test：检查 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % failure)
