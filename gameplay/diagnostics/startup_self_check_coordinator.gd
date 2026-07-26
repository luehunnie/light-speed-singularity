extends RefCounted

## 启动自检协调器（D3-F1）。
##
## 职责：
## 把核心闭环原型中七项启动自检的编排、三层 Debug 硬断言与启动摘要日志整块迁出为独立 RefCounted。
## 按固定顺序构建并执行七项 SelfCheckCallable，汇总每项成功/失败，全部通过时写一条 INFO 启动摘要日志。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下启动期自检编排器；由 core_loop_prototype._ready 在 Debug 构建中调用，
## 不作为 Node、不设为 Autoload、不接入运行期玩法流程。
##
## 主要依赖：
## DiagnosticsController（执行自检与摘要日志落盘）、七项自检模块（OccupancyRegistry/GridCoordinate/
## MirrorReflection/RuntimeState/RuntimeMove/PlayerMechanismIdSnapshot/InventoryConsistency）、
## SelfCheckCallable/SelfCheckResult/SelfCheckRunResult 数据契约、DiagnosticLogEntry/DiagnosticSeverity
## 摘要日志契约。场景相关数据（网格采样格、库存一致性快照）由调用方采集后以纯数据传入。
##
## 明确不负责：
## 不采集场景数据（Node 生命周期、水晶、Registry 校验仍由核心负责）、不持有 RunState/库存/放置/光线/
## Objective/UI、不修改任何游戏运行事实、不参与玩法决策、不自愈数据。
##
## 关键边界：
## - is_debug=false 时跳过全部七项执行并返回 ran=false 的空汇总；Release 构建按当前规则跳过。
## - halt_on_failure=true 时逐项执行，遇第一项失败即按原三层 assert 中止（保留原硬断言语义）；
##   halt_on_failure=false 时跑完全部七项只记录结果，供自动测试注入失败场景而不触发断言中止。
## - 自检总数恒为七项，执行顺序与原 _ready 调用顺序一致；不新建“第八项”。
## - 摘要日志仅在七项全部通过且 is_debug=true 时写入一次，结构（severity/module/execution/message）不变。
## - 不使用 Node.name 作为正式 ID；不读取 core_loop_prototype 私有字段。


# 诊断控制器：核心持有的唯一实例；协调器通过它执行 SelfCheckRunner 并落盘摘要日志。
const _DiagnosticsController: GDScript = preload(
	"res://gameplay/diagnostics/diagnostics_controller.gd"
)
const _SelfCheckCallable: GDScript = preload(
	"res://gameplay/diagnostics/self_check/self_check_callable.gd"
)
const _SelfCheckResult: GDScript = preload(
	"res://gameplay/diagnostics/self_check/self_check_result.gd"
)
const _SelfCheckRunResult: GDScript = preload(
	"res://gameplay/diagnostics/self_check/self_check_run_result.gd"
)
const _DiagnosticSeverity: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_severity.gd"
)
const _DiagnosticLogEntry: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_log_entry.gd"
)
# 七项自检模块；五项为无参 static run()，网格坐标与库存一致性两项由调用方传入纯数据构造实例。
const _OccupancyRegistryCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/occupancy_registry_check.gd"
)
const _GridCoordinateCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/grid_coordinate_check.gd"
)
const _MirrorReflectionCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/mirror_reflection_check.gd"
)
const _RuntimeStateCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/runtime_state_check.gd"
)
const _RuntimeMoveCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/runtime_move_check.gd"
)
const _PlayerMechanismIdSnapshotCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/player_mechanism_id_snapshot_check.gd"
)
const _InventoryConsistencyCheck: GDScript = preload(
	"res://gameplay/diagnostics/self_check/checks/inventory_consistency_check.gd"
)
const _InventoryConsistencySnapshot: GDScript = preload(
	"res://gameplay/placement/inventory_consistency_snapshot.gd"
)


## 启动自检项总数，恒为七；与 _ready 中原调用顺序一致，不得新增或删减。
const CHECK_COUNT: int = 7

# 七项执行 ID，与 definitions 构建顺序一一对应；保持 Diagnostics 摘要稳定执行标识。
const _EXECUTION_ID_OCCUPANCY: StringName = &"startup_occupancy_registry"
const _EXECUTION_ID_GRID: StringName = &"startup_grid_coordinate"
const _EXECUTION_ID_MIRROR: StringName = &"startup_single_cell_mirror_reflection"
const _EXECUTION_ID_RUNTIME_STATE: StringName = &"startup_runtime_state_rules"
const _EXECUTION_ID_RUNTIME_MOVE: StringName = &"startup_runtime_move_rules"
const _EXECUTION_ID_PLAYER_MECHANISM: StringName = &"startup_player_mechanism_id_snapshot"
const _EXECUTION_ID_INVENTORY: StringName = &"startup_inventory_consistency"

# 协调器长期持有的唯一状态：诊断控制器实例，用于执行自检与摘要日志落盘。
var _diagnostics: _DiagnosticsController
# 保留实例型自检（GridCoordinateCheck/InventoryConsistencyCheck）的引用：GDScript Callable 不持有 RefCounted，
# 若不保留，实例在 _build_definitions 返回后即被回收，Callable 调用时触发 null::method 使该项误判失败。
var _retained_checks: Array = []


## 构造启动自检协调器。
## [br]无参数；内部构造唯一 DiagnosticsController 实例，不创建 Node、不访问场景树、不执行自检。
## [br]副作用：仅初始化 _diagnostics。
func _init() -> void:
	_diagnostics = _DiagnosticsController.new()


## 按固定顺序执行七项启动自检并汇总结果。
## [br]grid_sample_cells 为核心采集的网格坐标采样格（含发射器格、水晶格、墙体格、边界角）。
## [br]inventory_snapshot 为核心采集的库存一致性只读快照（含 Node 生命周期保护后的事实）。
## [br]is_debug 控制是否执行；Release 注入 false 跳过全部七项。
## [br]halt_on_failure 控制失败时是否触发三层 assert 中止；生产 Debug 传 true，自动测试传 false 以便检视失败汇总。
## [br]返回 _StartupSelfCheckSummary：ran/check_count/execution_ids/passed_flags/all_passed/摘要日志信息。
## [br]副作用：is_debug=true 时通过 DiagnosticsController 执行七项自检（每次内部新建 SelfCheckRunner），
##   全部通过时写一条 INFO 摘要日志到 user://diagnostics/logs；不修改任何玩法运行事实。
## [br]失败条件：halt_on_failure=true 且某项未通过时，按原三层 assert 中止；is_debug=false 时不执行、不中止。
## [br]边界条件：is_debug=false 直接返回 ran=false 的空汇总；halt_on_failure=false 时跑完全部七项只记录结果。
func run_all(
		grid_sample_cells: Array[Vector2i],
		inventory_snapshot: _InventoryConsistencySnapshot,
		is_debug: bool,
		halt_on_failure: bool
) -> _StartupSelfCheckSummary:
	var summary: _StartupSelfCheckSummary = _StartupSelfCheckSummary.new()
	summary.check_count = CHECK_COUNT
	# Release 守卫：跳过全部七项执行，返回不伪报成功的空汇总。
	if not is_debug:
		summary.ran = false
		summary.all_passed = false
		return summary
	summary.ran = true
	summary.all_passed = true

	# 清空上轮保留的实例型自检引用（协调器通常仅启动期调用一次，仍以防重复调用残留）。
	_retained_checks.clear()
	var definitions: Array[_SelfCheckCallable] = _build_definitions(grid_sample_cells, inventory_snapshot)
	var execution_ids: Array[StringName] = _build_execution_ids()
	# 逐项执行：遇失败时 halt_on_failure=true 立即按原三层 assert 中止，保留“首项失败即停止”语义。
	for index: int in range(definitions.size()):
		var definition: _SelfCheckCallable = definitions[index]
		var execution_id: StringName = execution_ids[index]
		var run_result: _SelfCheckRunResult = _diagnostics.run_self_check(definition, execution_id)
		var passed: bool = run_result.is_success()
		summary.execution_ids.append(execution_id)
		summary.passed_flags.append(passed)
		if not passed:
			summary.all_passed = false
			if halt_on_failure:
				_assert_run_result(run_result, execution_id)
	# 仅七项全部通过时写一条 INFO 启动摘要日志；失败时不写摘要。
	if summary.all_passed:
		_write_summary_log(summary)
	return summary


## 按固定顺序构建七项 SelfCheckCallable。
## [br]顺序：occupancy → grid_coordinate → mirror_reflection → runtime_state → runtime_move →
##   player_mechanism_id_snapshot → inventory_consistency，与原 _ready 调用顺序一致。
## [br]五项无参 static run() 直接包装；grid_coordinate 与 inventory_consistency 由调用方传入纯数据构造实例，
##   再以 Callable(instance, "run") 接入，不使用 bind/lambda/捕获。
func _build_definitions(
		grid_sample_cells: Array[Vector2i],
		inventory_snapshot: _InventoryConsistencySnapshot
) -> Array[_SelfCheckCallable]:
	var definitions: Array[_SelfCheckCallable] = []
	# 1. OccupancyRegistry 启动期轻量自检。
	definitions.append(SelfCheckCallable.new(
		&"occupancy_registry",
		"OccupancyRegistry 启动期轻量自检",
		_OccupancyRegistryCheck.run
	))
	# 2. 网格坐标规则自检（持有只读采样快照）。
	var grid_check: _GridCoordinateCheck = _GridCoordinateCheck.new(grid_sample_cells)
	_retained_checks.append(grid_check)
	definitions.append(SelfCheckCallable.new(
		&"grid_coordinate",
		"网格坐标规则自检",
		Callable(grid_check, "run")
	))
	# 3. 基础单格镜面八方向反射纯函数自检。
	definitions.append(SelfCheckCallable.new(
		&"single_cell_mirror_reflection",
		"基础单格镜面八方向反射纯函数自检",
		_MirrorReflectionCheck.run
	))
	# 4. 运行状态纯规则自检。
	definitions.append(SelfCheckCallable.new(
		&"runtime_state_rules",
		"运行状态规则自检",
		_RuntimeStateCheck.run
	))
	# 5. 运行期移动次数纯函数自检。
	definitions.append(SelfCheckCallable.new(
		&"runtime_move_rules",
		"运行期移动规则自检",
		_RuntimeMoveCheck.run
	))
	# 6. 玩家机关 ID 快照、R 库存计算与残留引用自检。
	definitions.append(SelfCheckCallable.new(
		&"player_mechanism_id_snapshot",
		"玩家机关 ID 快照、R 库存计算与残留引用自检",
		_PlayerMechanismIdSnapshotCheck.run
	))
	# 7. 库存与玩家机关占用一致性自检（持有只读快照）。
	var inventory_check: _InventoryConsistencyCheck = _InventoryConsistencyCheck.new(inventory_snapshot)
	_retained_checks.append(inventory_check)
	definitions.append(SelfCheckCallable.new(
		&"inventory_consistency",
		"库存与玩家机关占用一致性自检",
		Callable(inventory_check, "run")
	))
	return definitions


## 返回与 definitions 同序的七项执行 ID 数组。
func _build_execution_ids() -> Array[StringName]:
	return [
		_EXECUTION_ID_OCCUPANCY,
		_EXECUTION_ID_GRID,
		_EXECUTION_ID_MIRROR,
		_EXECUTION_ID_RUNTIME_STATE,
		_EXECUTION_ID_RUNTIME_MOVE,
		_EXECUTION_ID_PLAYER_MECHANISM,
		_EXECUTION_ID_INVENTORY,
	]


## 对单项失败结果执行原三层 Debug 硬断言。
## [br]保留执行级（errors 非空）、结构级（validate 非空）、检查级（is_success 为 false）三层，
##   断言信息汇总 execution_id/errors/validate/每项 check 详情，不降级为 warning。
## [br]halt_on_failure=true 时调用；任一层失败即中止，后续自检不再执行。
func _assert_run_result(
		run_result: _SelfCheckRunResult,
		execution_id: StringName
) -> void:
	var structure_problems: PackedStringArray = run_result.validate()
	var assert_lines: PackedStringArray = PackedStringArray()
	assert_lines.append("execution_id=%s" % [execution_id])
	assert_lines.append("errors=%s" % [run_result.errors])
	assert_lines.append("validate=%s" % [structure_problems])
	for index: int in range(run_result.results.size()):
		var item: _SelfCheckResult = run_result.results[index]
		if item == null:
			assert_lines.append("results[%d]=null" % [index])
		else:
			assert_lines.append("results[%d] check_id=%s summary=%s details=%s" % [index, item.check_id, item.summary, item.details])
	var assert_message: String = "\n".join(assert_lines)
	# 第一层：执行级错误（注册/协调失败）。
	assert(run_result.errors.is_empty(), "启动自检：执行级错误（注册/协调失败）：\n%s" % [assert_message])
	# 第二层：结果结构（validate() 字段问题）。
	assert(structure_problems.is_empty(), "启动自检：结果结构无效：\n%s" % [assert_message])
	# 第三层：检查未通过（任一 passed=false）。
	assert(run_result.is_success(), "启动自检：检查未通过：\n%s" % [assert_message])


## 七项全部通过后写一条 INFO 启动摘要日志。
## [br]结构（timestamp/severity/module/execution/message）与原核心实现一致；写入失败只逐项 push_warning，
##   不 assert、不中断启动、不改变 RunState；同一次启动只写一条摘要，不逐项记录 PASS。
func _write_summary_log(summary: _StartupSelfCheckSummary) -> void:
	# 时间戳取 Unix 毫秒，满足 DiagnosticLogEntry 契约。
	var timestamp_unix_msec: int = int(Time.get_unix_time_from_system() * 1000.0)
	# 构造参数顺序严格匹配 DiagnosticLogEntry 签名（timestamp, severity, module, execution, message）。
	var entry: _DiagnosticLogEntry = _DiagnosticLogEntry.new(
		timestamp_unix_msec,
		_DiagnosticSeverity.Level.INFO,
		&"startup_self_check",
		&"startup_all_self_checks",
		"七项启动自检全部通过"
	)
	summary.summary_entry = entry
	summary.summary_log_written = true
	# 写盘失败不致命：原样收集问题并 push_warning，不中断流程。
	var write_problems: PackedStringArray = _diagnostics.write_entry_to_file(entry)
	for problem: String in write_problems:
		summary.summary_log_problems.append(problem)
		push_warning("启动摘要日志写入失败：%s" % [problem])


## 启动自检汇总结果。
## [br]ran：是否真正执行（is_debug=false 时为 false）。
## [br]check_count：恒为 CHECK_COUNT=7。
## [br]execution_ids/passed_flags：已执行项的执行 ID 与是否通过，按下标一一对应；跳过时为空。
## [br]all_passed：仅当 ran 且全部通过时为 true；跳过或任一失败时为 false，不伪报成功。
## [br]summary_entry/summary_log_written/summary_log_problems：摘要日志条目与落盘信息。
class _StartupSelfCheckSummary:
	var ran: bool = false
	var check_count: int = 0
	var execution_ids: Array[StringName] = []
	var passed_flags: Array[bool] = []
	var all_passed: bool = false
	var summary_log_written: bool = false
	var summary_log_problems: PackedStringArray = PackedStringArray()
	var summary_entry: Variant = null
