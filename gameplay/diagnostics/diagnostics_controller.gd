class_name DiagnosticsController
extends RefCounted

## 诊断控制器（Diagnostics 批次 5A-H2）。
##
## 职责：
## 作为轻量、强类型、非 Node 的 RefCounted 协调入口，统一委托现有 RuntimeLogger、
## SelfCheckRunner 与 RuntimeSnapshot 三个公共契约，向调用方提供最小且语义明确的诊断执行边界。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下最外层协调器（批次 5A-H2 只建立 Controller 与独立自动测试）。
## 本批不接入 core_loop，不参与任何玩法流程；主场景不调用本类。
##
## 主要依赖（全部以 preload 显式引用，不依赖全局 class_name 缓存）：
## RuntimeLogger、DiagnosticLogEntry（日志）；RuntimeSnapshot、RuntimeSnapshotData、
## RuntimeSnapshotJsonResult、RuntimeSnapshotWriteResult（快照）；
## SelfCheckCallable、SelfCheckRunResult、SelfCheckRunner（自检）。
## 不依赖 core_loop、Node、PlaceableToken、OccupancyRegistry、Crystal 或场景树。
##
## 明确不负责：
## - 不采集玩法数据：SnapshotData 由调用方构造后传入，Controller 不读取 core_loop、Crystal 或场景树。
## - 不处理业务事务：不决定事务提交或回滚，不执行状态切换，不修复库存、占用或关卡。
## - SelfCheck 硬断言由调用方负责：Controller 只执行并返回结果；启动期硬 assert 与运行期库存硬断言不经过本接口。
## - 不作为 Autoload、不访问场景树、不创建 UI、不解析字符串调试命令、不成为事件总线、不自动采集玩法数据。
## - 不重复实现日志、快照或 Runner 算法，只做无损窄委托。
##
## 关键边界：
## - Controller 长期只持有 RuntimeLogger 一个实例；每次 SelfCheck 都新建 SelfCheckRunner，
##   不长期保存检查定义、Runner 或 SnapshotData，避免旧快照、重复注册与长期状态残留。
## - 全部公开接口保持强类型：无 Variant、无 Dictionary、无未类型 Array。
## - 依据 Diagnostics 红线，本类只观察/委托/返回结果，不参与玩法决策。


# 以 preload 显式引用依赖脚本，避开 MCP run_project 不重建全局 class 缓存的问题；
# 同时与 gameplay/diagnostics 下既有检查模块的引用方式保持一致。
# 这些 const 同时作为本脚本内强类型注解使用，等价于各自 class_name 指向的同一脚本资源。
const _RuntimeLogger: GDScript = preload(
	"res://gameplay/diagnostics/logging/runtime_logger.gd"
)
const _DiagnosticLogEntry: GDScript = preload(
	"res://gameplay/diagnostics/logging/diagnostic_log_entry.gd"
)
const _RuntimeSnapshot: GDScript = preload(
	"res://gameplay/diagnostics/snapshot/runtime_snapshot.gd"
)
const _RuntimeSnapshotData: GDScript = preload(
	"res://gameplay/diagnostics/snapshot/runtime_snapshot_data.gd"
)
const _RuntimeSnapshotJsonResult: GDScript = preload(
	"res://gameplay/diagnostics/snapshot/runtime_snapshot_json_result.gd"
)
const _RuntimeSnapshotWriteResult: GDScript = preload(
	"res://gameplay/diagnostics/snapshot/runtime_snapshot_write_result.gd"
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
const _SelfCheckRunner: GDScript = preload(
	"res://gameplay/diagnostics/self_check/self_check_runner.gd"
)


## 长期持有的唯一状态：运行期内存日志缓冲实例。
## 构造时创建，运行期不变更；不持有 Node、Runner、检查定义或 SnapshotData。
var _logger: _RuntimeLogger


## 构造一个诊断控制器。
## [br]本函数无参数，不新增通用配置 Dictionary。
## [br]职责：按 RuntimeLogger 当前真实构造接口创建一个 Logger（使用其正式默认内存上限）；
## [br]不创建 Node、不创建 Runner、不执行文件写入、不执行自检、不保存 SnapshotData。
## [br]副作用：仅初始化 _logger。
## [br]边界条件：RuntimeLogger 构造默认值由其自身契约决定，本类不复制配置常量、不覆盖默认上限。
func _init() -> void:
	# 使用 RuntimeLogger 正式无参默认构造：p_max_in_memory_entries 取其 DEFAULT_MAX_IN_MEMORY_ENTRIES。
	_logger = _RuntimeLogger.new()


## 执行一次自检并返回汇总结果。
## [br]definition 为待执行的自检定义，类型为 SelfCheckCallable，由调用方负责构造与生命周期。
## [br]execution_id 为本次运行的稳定执行 ID，原样透传给 Runner，不得为空（空值由 Runner 记为结构错误）。
## [br]返回 SelfCheckRunResult：注册失败时返回保留 execution_id 的合法失败结果；
## [br]注册成功时原样返回 run_all 的结果，不吞掉结构错误。
## [br]副作用：每次调用都新建 SelfCheckRunner；不写日志、不写文件、不访问场景树、不修改 definition。
## [br]失败处理：register_check 返回非空错误时不执行 run_all，直接构造合法失败 SelfCheckRunResult。
## [br]边界条件：不执行 assert；不保存 definition；不保存 Runner；不改变 execution_id；
## [br]不调用 duplicate_definition 之外的非公开实现；SelfCheck 硬断言由调用方负责，不经过本接口。
func run_self_check(
		definition: _SelfCheckCallable,
		execution_id: StringName
) -> _SelfCheckRunResult:
	# 每次调用新建 Runner：避免旧快照、重复注册与长期状态残留。
	var runner: _SelfCheckRunner = _SelfCheckRunner.new()
	# 注册定义：register_check 内部会复制定义，不修改入参，返回空数组表示成功。
	var register_problems: PackedStringArray = runner.register_check(definition)
	# 注册失败：返回合法失败结果，保留 execution_id，不执行 run_all，不伪装成功、不运行无效检查。
	# 使用强类型空结果数组 Array[SelfCheckResult] 满足 SelfCheckRunResult 构造契约，不得用未类型 Array。
	if not register_problems.is_empty():
		var empty_results: Array[_SelfCheckResult] = []
		return _SelfCheckRunResult.new(execution_id, empty_results, register_problems)
	# 注册成功：原样返回 run_all 结果，结构错误由 Runner 收集于结果 errors 中，不被吞掉。
	return runner.run_all(execution_id)


## 将一条诊断日志记录到 RuntimeLogger 内存缓冲（不写盘）。
## [br]entry 为强类型 DiagnosticLogEntry，由调用方构造。
## [br]返回 PackedStringArray：成功时为空；失败时包含 RuntimeLogger 现有错误契约的全部中文错误。
## [br]副作用：委托 RuntimeLogger.append_entry，向内存缓冲追加条目副本；不写文件、不访问场景树。
## [br]边界条件：不创建四个等级快捷函数；不用 bool 混淆“仅缓冲”与“写盘”语义；不自动记录 SelfCheck；不吞掉校验错误。
func record_entry(entry: _DiagnosticLogEntry) -> PackedStringArray:
	# 仅内存语义：委托 append_entry，错误契约原样上返。
	return _logger.append_entry(entry)


## 将一条诊断日志明确写入 RuntimeLogger 当前正式日志文件接口（落盘）。
## [br]entry 为强类型 DiagnosticLogEntry，由调用方构造。
## [br]directory_path 为日志目录，默认 RuntimeLogger.DEFAULT_LOG_DIRECTORY（user://diagnostics/logs）。
## [br]file_name 为日志文件名，默认 RuntimeLogger.DEFAULT_LOG_FILE_NAME（runtime.log）。
## [br]返回 PackedStringArray：成功时为空；失败时包含 RuntimeLogger 现有错误契约的全部中文错误。
## [br]副作用：委托 RuntimeLogger.append_entry_to_file，可能创建目录、轮转与收敛清理归档；
## [br]不写入内存缓冲、不访问场景树。
## [br]边界条件：不自动每帧落盘；不吞掉写盘错误；轮转、大小限制、目录与路径安全规则仍由 RuntimeLogger 负责。
func write_entry_to_file(
		entry: _DiagnosticLogEntry,
		directory_path: String = _RuntimeLogger.DEFAULT_LOG_DIRECTORY,
		file_name: String = _RuntimeLogger.DEFAULT_LOG_FILE_NAME
) -> PackedStringArray:
	# 明确写盘语义：委托 append_entry_to_file，错误契约原样上返。
	return _logger.append_entry_to_file(entry, directory_path, file_name)


## 将已构造好的 RuntimeSnapshotData 序列化为稳定 JSON 文本。
## [br]data 为调用方构造的只读快照数据，Controller 不采集、不修改、不长期保存。
## [br]返回 RuntimeSnapshotJsonResult：成功时 json_text 非空、errors 为空；失败时 errors 包含全部中文错误。
## [br]副作用：委托 RuntimeSnapshot.serialize（静态）；不访问文件系统、不写日志、不访问场景树。
## [br]边界条件：不使用 Dictionary 代替 RuntimeSnapshotData；不修改 data 及其子对象；
## [br]成功判定与直接调用 RuntimeSnapshot 一致。
func serialize_snapshot(data: _RuntimeSnapshotData) -> _RuntimeSnapshotJsonResult:
	# 无损窄委托：序列化与校验全部由 RuntimeSnapshot 负责，Controller 不重复实现。
	return _RuntimeSnapshot.serialize(data)


## 将已构造好的 RuntimeSnapshotData 保存到 user://diagnostics/snapshots 目录树。
## [br]data 为调用方构造的只读快照数据，Controller 不采集、不修改、不长期保存。
## [br]directory_path 为目标目录，默认 RuntimeSnapshot.DEFAULT_SNAPSHOT_DIRECTORY。
## [br]返回 RuntimeSnapshotWriteResult：成功时 file_path 非空、errors 为空；失败时 errors 包含全部中文错误。
## [br]副作用：委托 RuntimeSnapshot.save（静态），可能创建目录、写入 JSON 文件并按修改时间收敛清理历史快照；
## [br]不写日志、不访问场景树、不修改 data。
## [br]边界条件：写盘错误原样表达；轮转、数量与容量限制、目录与路径安全规则仍由 RuntimeSnapshot 负责。
func save_snapshot(
		data: _RuntimeSnapshotData,
		directory_path: String = _RuntimeSnapshot.DEFAULT_SNAPSHOT_DIRECTORY
) -> _RuntimeSnapshotWriteResult:
	# 无损窄委托：落盘与保留策略全部由 RuntimeSnapshot 负责，Controller 不长期保存 data。
	return _RuntimeSnapshot.save(data, directory_path)
