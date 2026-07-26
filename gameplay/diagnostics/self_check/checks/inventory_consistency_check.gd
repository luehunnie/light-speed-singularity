class_name InventoryConsistencyCheck
extends RefCounted

## 库存一致性启动期自检模块（Diagnostics 批次 4B-G3）。
##
## 职责：
## 把核心闭环原型 _assert_inventory_consistency() 中的库存一致性纯规则结果包装为
## SelfCheckResult，为启动期 SelfCheckRunner 提供无参实例方法 run()。本模块只持有
## InventoryConsistencySnapshot 构造时冻结的只读快照引用，不持有 Node、PlaceableToken、
## OccupancyRegistry 或 core_loop，不访问场景树，不读取任何全局或单例状态。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；由未来批次（G4）从真实
## placed_tokens_by_id 与 OccupancyRegistry 采集等价事实构造 InventoryConsistencySnapshot，
## 再以 InventoryConsistencyCheck.new(snapshot) 包装为无参 Callable(check, "run") 交由
## SelfCheckRunner 执行。本批只建立 Check 与公开接口，不接线，不接入 _ready()，不修改 core_loop，
## 不修改运行期 assert，不接入启动自检。
##
## 主要依赖：
## InventoryConsistencyRules（玩法层共享纯规则，单一来源）与 InventoryConsistencySnapshot
## （只读纯数据快照），以及 SelfCheckResult 数据契约。通过 preload 引用脚本而非依赖全局
## class_name 缓存，保证运行期可直接解析，与 inventory_consistency_rules.gd 等模块保持一致。
## 不依赖 core_loop_prototype、PlaceableToken、OccupancyRegistry、Diagnostics、场景树、节点、
## 时间 API 或文件系统。
##
## 明确不负责：
## 采集快照、is_instance_valid 与 is_queued_for_deletion 等 Node 生命周期检查、查询
## OccupancyRegistry、修改库存、修复占用、执行运行期硬 assert、决定事务是否提交或回滚、
## 记录日志或保存快照。Node 生命周期保护仍属于 core_loop，下一批 G4 才接线；本模块不用于
## 业务事务决策。
##
## 关键边界：
## - _init 只持有传入的 InventoryConsistencySnapshot 只读引用，不重新复制其六组数组；
##   Snapshot 已在自身构造时复制输入且无公开修改接口，因此 Check 持有其只读引用即可保证内容稳定。
## - run() 只调用 InventoryConsistencyRules.collect_failures 与快照只读接口；不访问 core_loop、
##   节点树、OccupancyRegistry，不修改 _snapshot 或任何外部状态。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 尽量保留 Rules 返回的全部失败详情；不因首个失败提前停止。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 快照引用为空时不触发运行时空引用错误，返回 passed=false 并加入稳定中文契约错误，
##   SelfCheckResult.validate() 仍必须通过。
## - 不使用文件、系统时间、随机数、信号或日志。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与 inventory_consistency_rules.gd 等模块的引用方式保持一致，避开 MCP run_project 不重建全局类型缓存的问题。
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)
const _InventoryConsistencyRules: GDScript = preload(
	"res://gameplay/placement/rules/inventory_consistency_rules.gd"
)

# 构造时持有的只读快照引用；run() 只读访问，不修改，不重新复制其内部数组。
# Snapshot 已在自身构造时复制输入且无公开修改接口，因此持有其只读引用即可保证内容稳定。
var _snapshot: _InventoryConsistencySnapshot = null


## 构造一个持有只读库存一致性快照的自检实例。
## [br]职责：把调用方采集并构造好的 InventoryConsistencySnapshot 只读引用保存为本实例字段，
## [br]供 run() 交给 InventoryConsistencyRules 做纯规则校验。
## [br]输入：snapshot 为 InventoryConsistencySnapshot 只读快照实例；允许为 null，
## [br]由 run() 以稳定契约错误表达，不在构造期触发错误。
## [br]返回：无；构造完成后 _snapshot 即为只读引用。
## [br]副作用：只保存快照引用，不重新复制其六组数组，不保存调用方容器引用；
## [br]不保存 core_loop、Node、PlaceableToken、OccupancyRegistry 或其他玩法对象引用；
## [br]不访问场景树、文件、时间或随机数。
## [br]失败：本构造函数不判定数据错误，不 assert、不 push_error、不修复；
## [br]对齐契约由 InventoryConsistencySnapshot.validate() 在 Rules 读取前自检。
## [br]边界：构造完成后无公开修改接口；_snapshot 在后续 run() 中只读；
## [br]不对 Snapshot 增加 setter 或可变接口；Check 不修改 Snapshot。
func _init(snapshot: _InventoryConsistencySnapshot) -> void:
	# 仅持有只读引用；Snapshot 自身已复制输入，Check 不再重复复制其内部数组。
	_snapshot = snapshot


## 执行库存一致性纯规则自检。
## [br]本函数无参数，只读、无业务修复、不执行任何玩法事务、不修改 _snapshot 或任何外部状态。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"inventory_consistency"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要（通过时为「库存与玩家机关占用快照一致」，
## [br]    失败时为「库存与玩家机关占用快照存在不一致」）；
## [br]  - details 尽量保留 InventoryConsistencyRules.collect_failures 返回的全部失败详情，
## [br]    每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]职责：把 InventoryConsistencyRules 的纯规则结果包装为 SelfCheckResult，
## [br]为启动期 SelfCheckRunner 提供无参 run()。
## [br]输入：无；只读访问构造时持有的 _snapshot。
## [br]返回：SelfCheckResult，见上方字段说明。
## [br]副作用：只调用 InventoryConsistencyRules.collect_failures 与快照只读接口；
## [br]不复制任何库存或占用规则，不访问 core_loop、节点树、OccupancyRegistry，
## [br]不修改 _snapshot，不创建或修改 Node，不写文件、不写日志，
## [br]不使用 assert、push_error 或 push_warning，不修复任何库存或占用数据。
## [br]失败语义：快照引用为空时不触发运行时空引用错误，返回 passed=false 并加入稳定中文契约错误；
## [br]否则尽量保留 Rules 返回的全部失败详情；不因首个失败提前停止。
## [br]边界条件：duration_usec 固定为 0；重复 run() 结果稳定；
## [br]SelfCheckCallable.duplicate_definition() 后 Callable 仍引用同一个只读快照；
## [br]不访问场景树，不读取任何全局或单例状态；不用于业务事务决策。
func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()
	var passed: bool = false

	# 快照引用为空属于契约错误：不触发运行时空引用错误，直接返回失败并加入稳定中文契约错误，
	# 不调用 Rules.collect_failures 以避免对 null 快照触发运行时空引用错误。
	if _snapshot == null:
		details.append("库存一致性自检：快照引用为空，必须传入非空 InventoryConsistencySnapshot。")
	else:
		# 复用玩法层共享纯规则单一来源，不复制任何库存或占用规则；尽量保留全部失败详情。
		var failures: PackedStringArray = _InventoryConsistencyRules.collect_failures(_snapshot)
		for failure: String in failures:
			details.append(failure)
		passed = details.is_empty()

	# 稳定中文摘要：通过时表示一致，失败时表示存在不一致（含空快照契约错误）。
	var summary: String = "库存与玩家机关占用快照一致" if passed else "库存与玩家机关占用快照存在不一致"
	return SelfCheckResult.new(&"inventory_consistency", passed, summary, details, 0)
