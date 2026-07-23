class_name OccupancyRegistryCheck
extends RefCounted

## OccupancyRegistry 启动期轻量自检模块（Diagnostics 批次 4B-B1）。
##
## 职责：
## 把原核心闭环原型中的 _run_occupancy_registry_self_check() 检查逻辑抽离为独立、无副作用、
## 不访问场景树的纯函数式自检；只创建并操作临时 OccupancyRegistry 实例，验证登记、查询、
## 冲突拒绝、解除、清空和双向索引一致性，不读取或修改真实关卡占用状态、placed_tokens_by_id、
## 库存或场景节点。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；本批只迁移这一项检查逻辑，
## 暂不接入 SelfCheckRunner，核心闭环原型仍以薄包装形式在 Debug 构建中调用本模块 run()。
##
## 主要依赖：
## OccupancyRegistry 公共接口（register_single_cell / unregister / clear / get_mechanism_at /
## has_mechanism_at / has_mechanism / get_cells_of / is_consistent）与 SelfCheckResult 数据契约。
## 不依赖场景树、节点、时间 API、文件系统或玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、其他自检项的迁移或
## SelfCheckRunner 接入。本模块只如实报告检查事实，不修改任何玩法状态。
##
## 关键边界：
## - run() 只使用临时 OccupancyRegistry，真实关卡 occupancy 从不参与本流程。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能汇总全部检查失败。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


# 以 preload 引用 OccupancyRegistry 脚本，避开 MCP run_project 不重建全局类型缓存的问题，
# 与核心闭环原型中的引用方式保持一致。
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")


## 执行 OccupancyRegistry 启动期轻量自检。
## [br]本函数无参数。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"occupancy_registry"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]副作用：只创建并操作临时 OccupancyRegistry 实例；不修改真实关卡 occupancy、
## placed_tokens_by_id、库存、RunState、光路、水晶或场景节点；不访问场景树，不使用 Node，
## 不写文件，不写日志，不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能汇总全部失败。
## [br]边界条件：自检格子刻意远离当前第 3 行光路（使用 (10, 10)）；不删减原自检覆盖的任何测试案例；
## [br]is_consistent() 为 OccupancyRegistry 公共 API，其内部 push_error 行为属既有接口职责，非本模块输出。
static func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()
	var registry: _OccupancyRegistry = _OccupancyRegistry.new()
	var debug_id: StringName = &"debug_probe"
	var debug_cell: Vector2i = Vector2i(10, 10)

	# 首次登记应成功，且双向索引同步写入。
	if not registry.register_single_cell(debug_id, debug_cell):
		details.append("首次登记应成功，实际返回 false。")
	if registry.get_mechanism_at(debug_cell) != debug_id:
		details.append("按格查询应返回已登记 ID，实际为 %s。" % [registry.get_mechanism_at(debug_cell)])
	if not registry.has_mechanism_at(debug_cell):
		details.append("has_mechanism_at 应为 true，实际为 false。")
	if registry.get_cells_of(debug_id) != [debug_cell]:
		details.append("按 ID 查询应返回其占用格 [%s]，实际为 %s。" % [debug_cell, registry.get_cells_of(debug_id)])
	# 同一格被另一机关重复占用 → 必须拒绝，不覆盖既有占用。
	if registry.register_single_cell(&"other_probe", debug_cell):
		details.append("重复占用同一格应被拒绝，实际返回 true。")
	# 同一机关未清理就登记到新位置 → 必须拒绝，原占用保持不变。
	if registry.register_single_cell(debug_id, Vector2i(11, 11)):
		details.append("同一 ID 重复登记应被拒绝，实际返回 true。")
	if registry.get_mechanism_at(debug_cell) != debug_id:
		details.append("拒绝后原占用应保持不变，实际为 %s。" % [registry.get_mechanism_at(debug_cell)])
	# 解除后双向索引同步清理，重复解除不报错。
	if not registry.unregister(debug_id):
		details.append("解除已登记机关应成功，实际返回 false。")
	if registry.has_mechanism_at(debug_cell):
		details.append("解除后该格应无占用，实际仍被占用。")
	if registry.unregister(debug_id):
		details.append("重复解除不存在的机关应安全返回 false，实际返回 true。")
	if not registry.is_consistent():
		details.append("两个反向索引应一致，实际不一致。")
	# 自检完成，清空临时占用表；真实关卡 occupancy 从未参与本流程。
	registry.clear()
	if not registry.mechanism_at.is_empty():
		details.append("清空后 mechanism_at 应为空，实际非空。")
	if not registry.is_consistent():
		details.append("清空后仍应一致，实际不一致。")

	var summary: String = "OccupancyRegistry 启动期轻量自检：登记、查询、冲突拒绝、解除、清空与一致性。"
	return SelfCheckResult.new(&"occupancy_registry", details.is_empty(), summary, details, 0)
