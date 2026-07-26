class_name InventoryConsistencyRules
extends RefCounted

## 库存一致性纯规则共享模块（Diagnostics 批次 4B-G2）。
##
## 职责：
## 只承载核心闭环原型 _assert_inventory_consistency() 中的 A/B/C 三类纯数据规则：
## 数量规则（remaining 区间与剩余加已放置等于总数）、已放置机关快照规则（字典登记 ID 与
## 机关自身 mechanism_id 快照一致）、OccupancyRegistry 快照规则（占用表本体一致性标志、
## token.cell 查询 ID 与字典登记 ID 一致、登记格数量为 1、唯一占用格与 token.cell 一致）。
## 本模块只对 InventoryConsistencySnapshot 做纯规则校验，不执行任何事务，不访问场景树，
## 不调用 Node 生命周期，不写文件，不使用时间或随机数，不负责日志、断言或自动修复。
##
## 在当前系统中的位置：
## gameplay/placement 下玩法层共享规则；本批不接入 core_loop，也不接入启动自检。
## 后续批次将在不改变运行期 assert 的前提下，把同一组规则作为正式玩法层与 Diagnostics
## 自检共用的唯一规则来源，确保玩法规则单一来源，Diagnostics 不拥有玩法规则，只消费其公开静态接口。
##
## 主要依赖：
## 通过 preload 引用 res://gameplay/placement/inventory_consistency_snapshot.gd 取得
## InventoryConsistencySnapshot 类型；不依赖 core_loop_prototype、PlaceableToken、
## OccupancyRegistry、Diagnostics、场景树、节点、时间 API 或文件系统。
##
## 明确不负责：
## is_instance_valid 与 is_queued_for_deletion 等 Node 生命周期检查仍由 core_loop 负责；
## OccupancyRegistry 反向多余条目检查、静态机关检查、重复 Dictionary key 检查、
## 总库存非负新规则、零总库存专项业务规则、自动修复、新库存业务限制均不在本模块。
##
## 关键边界：
## - collect_failures 只读取快照公开只读接口，不读取任何 Node 或 OccupancyRegistry 内部算法。
## - 不复制 OccupancyRegistry 内部规则，不检查反向多余占用。
## - 尽量汇总全部可安全检查的失败，仅在快照契约无效时提前返回以避免越界。
## - 失败详情使用稳定中文文本，并包含条目索引与相关 ID/格子。
## - 合法快照返回空 PackedStringArray；重复调用结果稳定；不修改输入快照。


# 以 preload 引用 InventoryConsistencySnapshot 脚本，避开 MCP run_project 不重建全局类型缓存的问题，
# 与 PlayerMechanismResetRules 等模块的引用方式保持一致。
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)


## 汇总库存一致性快照的全部可安全检查失败。
## [br]职责：依次执行契约自检、A 类数量规则、B 类机关快照规则、C 类占用快照规则，汇总全部失败详情。
## [br]输入：snapshot 为 InventoryConsistencySnapshot 只读快照实例。
## [br]返回：PackedStringArray，长度为 0 表示快照完全合法；非空时每项为一条稳定中文失败详情，
## 包含条目索引与相关 ID/格子。
## [br]副作用：无；不读取任何 Node、OccupancyRegistry、场景树、文件；不使用 assert、push_error、push_warning；
## 不写日志、文件或快照；不修复输入；不修改 snapshot。
## [br]失败：本函数不抛异常；契约无效时把契约错误复制到结果并立即返回，避免越界；
## 其余分支尽量汇总全部可安全检查的失败。
## [br]边界：执行顺序固定为 1.契约自检 → 2.remaining>=0 → 3.remaining<=total →
## 4.remaining+entry_count==total → 5.occupancy_consistent → 6.逐条目 B/C 规则；
## occupancy_first_cell 仅在 occupancy_cell_count == 1 时与 token_cell 比较，count == 0 的占位值不参与比较；
## 合法快照返回空 PackedStringArray；重复调用结果稳定。
static func collect_failures(
		snapshot: _InventoryConsistencySnapshot
		) -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()

	# 1. 先做契约自检；契约无效时复制契约错误并立即返回，避免后续按索引读取时越界。
	var contract_errors: PackedStringArray = snapshot.validate()
	if not contract_errors.is_empty():
		for contract_error: String in contract_errors:
			failures.append(contract_error)
		return failures

	# 标量事实只读取一次，避免在多条规则中重复调用。
	var total_count: int = snapshot.get_total_count()
	var remaining_count: int = snapshot.get_remaining_count()
	var entry_count: int = snapshot.get_entry_count()

	# 2. A 类数量规则：remaining >= 0。
	if remaining_count < 0:
		failures.append(
				"库存剩余数量不能小于 0：remaining=%d。"
				% [remaining_count]
				)

	# 3. A 类数量规则：remaining <= total。
	if remaining_count > total_count:
		failures.append(
				"库存剩余数量不能超过总数量：remaining=%d，total=%d。"
				% [remaining_count, total_count]
				)

	# 4. A 类数量规则：remaining + entry_count == total。
	if remaining_count + entry_count != total_count:
		failures.append(
				"库存剩余数量加已放置数量不等于总数量：remaining=%d，entry_count=%d，total=%d。"
				% [remaining_count, entry_count, total_count]
				)

	# 5. C 类占用快照规则：OccupancyRegistry 本体一致性标志为 true。
	if not snapshot.is_occupancy_consistent():
		failures.append(
				"占用表本体一致性标志为 false：occupancy_consistent=false。"
				)

	# 6. 逐条目执行 B 类机关快照规则与 C 类占用快照规则，尽量汇总全部可安全检查的失败。
	for index: int in range(entry_count):
		var dictionary_id: StringName = snapshot.get_dictionary_id(index)
		var token_id: StringName = snapshot.get_token_id(index)
		var token_cell: Vector2i = snapshot.get_token_cell(index)
		var occupancy_id: StringName = snapshot.get_occupancy_id_at_token_cell(index)
		var occupancy_cell_count: int = snapshot.get_occupancy_cell_count(index)

		# B 类：字典登记 ID == 机关自身 mechanism_id 快照值。
		if dictionary_id != token_id:
			failures.append(
					"条目 %d 的字典登记 ID 与机关自身 mechanism_id 不一致：dictionary_id=%s，token_id=%s。"
					% [index, dictionary_id, token_id]
					)

		# C 类：token.cell 处查询到的占用表 ID == 字典登记 ID。
		if occupancy_id != dictionary_id:
			failures.append(
					"条目 %d 的占用表查询 ID 与字典登记 ID 不一致：occupancy_id=%s，dictionary_id=%s，token_cell=%s。"
					% [index, occupancy_id, dictionary_id, token_cell]
					)

		# C 类：字典登记 ID 对应的占用格数量 == 1。
		if occupancy_cell_count != 1:
			failures.append(
					"条目 %d 的占用格数量不为 1：cell_count=%d，dictionary_id=%s。"
					% [index, occupancy_cell_count, dictionary_id]
					)

		# C 类：仅当占用格数量 == 1 时，比较唯一占用格与 token.cell；
		# count == 0 时的占位 Vector2i.ZERO 不作为真实登记格参与比较。
		if occupancy_cell_count == 1:
			var occupancy_first_cell: Vector2i = snapshot.get_occupancy_first_cell(index)
			if occupancy_first_cell != token_cell:
				failures.append(
						"条目 %d 的唯一占用格与机关 cell 不一致：first_cell=%s，token_cell=%s，dictionary_id=%s。"
						% [index, occupancy_first_cell, token_cell, dictionary_id]
						)

	return failures
