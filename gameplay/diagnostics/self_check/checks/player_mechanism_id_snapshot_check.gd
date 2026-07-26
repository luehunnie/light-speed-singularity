class_name PlayerMechanismIdSnapshotCheck
extends RefCounted

## 玩家机关 ID 快照启动期自检模块（Diagnostics 批次 4B-C2）。
##
## 职责：
## 把原核心闭环原型中的 _run_player_mechanism_id_snapshot_self_check() 检查逻辑抽离为独立、
## 无副作用、不访问场景树的纯函数式自检；覆盖玩家机关 ID 快照复制、源表删除后快照独立性、
## String/StringName 等价 ID 去重、R 重置库存剩余计算边界，以及临时 OccupancyRegistry 残留引用查询。
## 不读取或修改真实关卡占用状态、placed_tokens_by_id、库存或场景节点。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；由核心闭环原型以薄包装形式构造
## SelfCheckCallable 并交由 SelfCheckRunner 执行，保持原 Debug 硬断言失败语义。
##
## 主要依赖：
## PlayerMechanismResetRules 三个公开静态规则（玩法层共享规则，单一来源）与 OccupancyRegistry
## 公共接口（register_single_cell / unregister / is_consistent 与公开字段 mechanism_at），
## 以及 SelfCheckResult 数据契约。不依赖场景树、节点、时间 API、文件系统或真实玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、R 重置事务编排。
## 本模块只如实报告检查事实，不修改任何玩法状态，不复制三个共享规则的实现。
##
## 关键边界：
## - run() 只读：只创建并操作临时 OccupancyRegistry 与临时 Dictionary，真实关卡 occupancy 从不参与本流程。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能汇总全部检查失败。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与核心闭环原型及 OccupancyRegistryCheck 中的引用方式保持一致。
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _PlayerMechanismResetRules: GDScript = preload("res://gameplay/placement/rules/player_mechanism_reset_rules.gd")


## 执行玩家机关 ID 快照、R 库存恢复计算与临时占用残留查询自检。
## [br]本函数无参数，只读、无业务修复。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"player_mechanism_id_snapshot"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]副作用：只创建并操作临时 OccupancyRegistry 与临时 Dictionary；不修改真实关卡 occupancy、
## placed_tokens_by_id、库存、RunState、光路、水晶或场景节点；不访问场景树，不使用 Node，
## 不写文件，不写日志，不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能汇总全部失败；
## [br]不使用 assert、push_error 或 push_warning。
## [br]边界条件：自检格子刻意远离当前光路（使用 (12, 12)）；不删减原自检覆盖的任何测试案例；
## [br]is_consistent() 为 OccupancyRegistry 公共 API，其内部行为属既有接口职责，非本模块输出。
static func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()

	# --- 玩家机关 ID 快照复制 ---

	var empty_source: Dictionary = {}
	var empty_snapshot: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(empty_source)
	if not empty_snapshot.is_empty():
		details.append("空 Dictionary 应返回空快照，实际 size=%d。" % [empty_snapshot.size()])

	var one_source: Dictionary = {&"mirror_one": null}
	var one_snapshot: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(one_source)
	if one_snapshot.size() != 1:
		details.append("单个 ID 应完整复制，实际 size=%d。" % [one_snapshot.size()])
	if not one_snapshot.has(&"mirror_one"):
		details.append("单个 ID 内容应保留 mirror_one，实际缺失。")

	var multi_source: Dictionary = {&"mirror_a": null, &"mirror_b": null, &"mirror_c": null}
	var multi_snapshot: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(multi_source)
	if multi_snapshot.size() != 3:
		details.append("多个 ID 数量不应遗漏，实际 size=%d。" % [multi_snapshot.size()])
	if not multi_snapshot.has(&"mirror_a"):
		details.append("快照应包含 mirror_a，实际缺失。")
	if not multi_snapshot.has(&"mirror_b"):
		details.append("快照应包含 mirror_b，实际缺失。")
	if not multi_snapshot.has(&"mirror_c"):
		details.append("快照应包含 mirror_c，实际缺失。")

	# 删除源 Dictionary 不应影响已复制的快照。
	multi_source.clear()
	if multi_snapshot.size() != 3:
		details.append("删除源 Dictionary 不应影响快照，实际 size=%d。" % [multi_snapshot.size()])
	if not (multi_snapshot.has(&"mirror_a") and multi_snapshot.has(&"mirror_b") and multi_snapshot.has(&"mirror_c")):
		details.append("快照内容应独立于源 Dictionary，实际内容缺失。")

	# 快照中不应出现重复 ID。
	var seen_ids: Dictionary[StringName, bool] = {}
	for snapshot_id: StringName in multi_snapshot:
		if seen_ids.has(snapshot_id):
			details.append("快照中不应出现重复 ID：%s。" % [snapshot_id])
		seen_ids[snapshot_id] = true

	# String 与 StringName 形式的等价键应只产生一个逻辑 ID。
	var equivalent_source: Dictionary = {}
	equivalent_source["mirror_equivalent"] = null
	equivalent_source[&"mirror_equivalent"] = null
	var equivalent_snapshot: Array[StringName] = _PlayerMechanismResetRules.copy_player_mechanism_ids(equivalent_source)
	if equivalent_snapshot.size() != 1:
		details.append("String/StringName 等价 ID 应只产生一个逻辑 ID，实际 size=%d。" % [equivalent_snapshot.size()])
	if not equivalent_snapshot.has(&"mirror_equivalent"):
		details.append("等价 ID 快照应包含 mirror_equivalent，实际缺失。")
	var seen_equivalent_ids: Dictionary[StringName, bool] = {}
	for equivalent_id: StringName in equivalent_snapshot:
		if seen_equivalent_ids.has(equivalent_id):
			details.append("等价 ID 快照中不应出现重复 ID：%s。" % [equivalent_id])
		seen_equivalent_ids[equivalent_id] = true
	equivalent_source.clear()
	if equivalent_snapshot.size() != 1:
		details.append("删除等价源 Dictionary 不应影响快照，实际 size=%d。" % [equivalent_snapshot.size()])
	if not equivalent_snapshot.has(&"mirror_equivalent"):
		details.append("等价快照内容应独立于源 Dictionary，实际缺失。")

	# --- R 重置库存剩余计算边界 ---

	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(0, 0) != 0:
		details.append("库存计算 total=0 unresolved=0 应返回 0。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(1, 0) != 1:
		details.append("库存计算 total=1 unresolved=0 应返回 1。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(1, 1) != 0:
		details.append("库存计算 total=1 unresolved=1 应返回 0。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(2, 1) != 1:
		details.append("库存计算 total=2 unresolved=1 应返回 1。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(2, 2) != 0:
		details.append("库存计算 total=2 unresolved=2 应返回 0。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(1, 5) != 0:
		details.append("库存计算未清理数量超过总数时应夹到 0。")
	if _PlayerMechanismResetRules.compute_inventory_remaining_after_reset(2, -1) != 2:
		details.append("库存计算负数未清理数量应安全夹到完整库存。")

	# --- 临时 OccupancyRegistry 残留引用查询 ---

	var residual_registry: _OccupancyRegistry = _OccupancyRegistry.new()
	var residual_id: StringName = &"residual_probe"
	var residual_cell: Vector2i = Vector2i(12, 12)

	if _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(residual_registry, residual_id):
		details.append("空 registry 不应引用任意 ID，实际查询到引用。")
	if not residual_registry.register_single_cell(residual_id, residual_cell):
		details.append("临时 registry 正常登记应成功，实际返回 false。")
	if not _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(residual_registry, residual_id):
		details.append("正常登记后应能查询到 ID 引用，实际未查询到。")
	if not residual_registry.unregister(residual_id):
		details.append("临时 registry 注销应成功，实际返回 false。")
	if _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(residual_registry, residual_id):
		details.append("注销后不应再查询到 ID 引用，实际仍查询到。")
	# 只保留 cell→ID 单向残留，也应查询到 ID 引用。
	residual_registry.mechanism_at[residual_cell] = residual_id
	if not _PlayerMechanismResetRules.registry_has_any_reference_to_mechanism(residual_registry, residual_id):
		details.append("只有 cell→ID 单向残留时也应查询到 ID 引用，实际未查询到。")
	residual_registry.mechanism_at.clear()
	if not residual_registry.is_consistent():
		details.append("清理临时单向残留后 registry 应恢复一致，实际不一致。")

	var summary: String = "玩家机关 ID 快照自检：快照复制、源表独立性、等价 ID 去重、R 库存计算与残留引用查询。"
	return SelfCheckResult.new(&"player_mechanism_id_snapshot", details.is_empty(), summary, details, 0)
