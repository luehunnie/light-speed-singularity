class_name PlayerMechanismResetRules
extends RefCounted

## 玩家可放置机关 R 重置共享纯规则模块（Diagnostics 批次 4B-C2）。
##
## 职责：
## 只承载玩家可放置机关在 R 重置过程中使用的三组纯数据规则：复制玩家机关 ID 快照、
## 根据冻结输入计算重置后库存剩余、查询 OccupancyRegistry 是否仍引用某个机关 ID。
## 本模块只负责纯规则，不执行 R 重置事务，不修改实际玩法对象，不访问场景树，
## 不调用 Node 生命周期，不写文件，不使用时间或随机数，不负责日志、断言或自动修复。
##
## 在当前系统中的位置：
## gameplay/placement 下玩法层共享规则；核心闭环原型的正式 R 重置路径与本批迁出的
## PlayerMechanismIdSnapshotCheck 自检都调用同一组规则，确保玩法规则单一来源，
## Diagnostics 不拥有玩法规则，只消费其公开静态接口。
##
## 主要依赖：
## OccupancyRegistry 公开查询接口（has_mechanism 与公开字段 mechanism_at）。
## 不依赖 core_loop_prototype、Diagnostics、场景树、节点、时间 API 或文件系统。
##
## 明确不负责：
## R 重置事务编排、节点销毁、库存实际写回、占用注销、状态机切换、UI 刷新、
## 日志输出、断言判定、自动修复、快照序列化。这些由调用方负责。
##
## 关键边界：
## - 三个公开 static func 行为与原核心闭环原型辅助函数完全一致，只是去掉前导下划线并改为正式名称。
## - 除复制输入容器（ID 快照）外，不修改调用方传入的数据。
## - 不把 OccupancyRegistry 的内部规则复制进来，只调用其公开查询接口。
## - 不添加与本次规则无关的函数。


# 以 preload 引用 OccupancyRegistry 脚本，避开 MCP run_project 不重建全局类型缓存的问题，
# 与核心闭环原型及 OccupancyRegistryCheck 中的引用方式保持一致。
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")


## 复制玩家机关 ID 快照（纯函数，无副作用）。
## [br]职责：返回源 Dictionary 当前键的去重 StringName 快照。
## [br]输入：source 是要复制键集合的玩家机关映射，通常为 placed_tokens_by_id，也可由自检传入临时 Dictionary。
## [br]返回：Array[StringName]，包含源 Dictionary 当前键的去重快照；返回后源 Dictionary 的增删不会影响快照。
## [br]副作用：无；不读取或修改真实 OccupancyRegistry、库存、节点树、拖拽状态、RunState、光路或水晶。
## [br]失败：本函数不判定失败，不抛异常；非 StringName 键按 StringName 语义转换并去重。
## [br]边界：调用方会在清理玩家机关时遍历该快照，而不是边遍历 placed_tokens_by_id 边 erase，
## 避免 Dictionary 迭代器被修改导致漏项或未定义行为；String 与 StringName 形式的等价键只产生一个逻辑 ID。
static func copy_player_mechanism_ids(source: Dictionary) -> Array[StringName]:
	var mechanism_ids: Array[StringName] = []
	for key: Variant in source.keys():
		var mechanism_id: StringName = StringName(key)
		if not mechanism_ids.has(mechanism_id):
			mechanism_ids.append(mechanism_id)
	return mechanism_ids


## 计算 R 重置清理玩家机关后的库存剩余数量（纯函数，无副作用）。
## [br]职责：返回夹在合法库存区间内的剩余数量。
## [br]输入：total 是该机关类型的总库存数量；unresolved_player_token_count 是因 OccupancyRegistry
## 残留引用而未能确认清理、仍保留在场上的玩家机关数量。
## [br]返回：clampi(total - unresolved_player_token_count, 0, total)；全部清理时恢复 total，
## 仍有未清理机关时扣除对应数量，异常超量或负数输入也夹在合法库存区间内。
## [br]副作用：无；不读取或修改真实库存、玩家机关映射、OccupancyRegistry、节点树、拖拽状态、RunState、光路或水晶。
## [br]失败：本函数不判定失败，不抛异常；任意 int 输入都返回夹区间后的稳定结果。
## [br]边界：不修改调用方传入的任何数据；负数 unresolved 视为 0 处理后回到完整库存 total。
static func compute_inventory_remaining_after_reset(total: int, unresolved_player_token_count: int) -> int:
	return clampi(total - unresolved_player_token_count, 0, total)


## 查询指定 OccupancyRegistry 是否仍有任一索引引用指定机关 ID（只读，无副作用）。
## [br]职责：同时检查 ID→格子与格子→ID 两个方向，判断是否仍存在该 ID 引用。
## [br]输入：registry 是要检查的占用表实例；mechanism_id 是要查找的玩家机关 ID。
## [br]返回：true 表示任一方向仍存在该 ID 引用；false 表示两个方向都没有该 ID 引用。
## [br]副作用：无；不调用 registry.clear()，不修复、不删除、不改写 registry 内部 Dictionary，
## 不修改玩家节点或库存。
## [br]失败：本函数不判定失败，不抛异常；只如实报告查询事实。
## [br]边界：只调用 OccupancyRegistry 公开查询接口 has_mechanism 与公开字段 mechanism_at，
## 不复制其内部规则；刻意双向检查，便于在 unregister 失败时区分“占用已提前缺失”和“仍存在残留引用”。
static func registry_has_any_reference_to_mechanism(
		registry: _OccupancyRegistry,
		mechanism_id: StringName
) -> bool:
	if registry.has_mechanism(mechanism_id):
		return true

	for cell: Vector2i in registry.mechanism_at:
		if registry.mechanism_at[cell] == mechanism_id:
			return true

	return false
