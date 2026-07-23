class_name RuntimeLogger
extends RefCounted

## 运行期内存日志缓冲公共组件。
##
## 职责：
## 在内存中保存经过校验的 DiagnosticLogEntry，限制条目数量并在超限时删除最旧条目，
## 向调用者返回深复制副本，避免外部直接修改内部缓冲。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下日志缓冲层（批次 2A 只实现最小内存缓冲）。
## 本批不访问文件系统、不进行日志文本格式化、不实现文件轮转，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 DiagnosticLogEntry 的构造与 validate()，以及 Godot 内建类型（int、bool、
## PackedStringArray、Array[DiagnosticLogEntry]）。不依赖场景树、节点、Time、JSON、
## FileAccess、DirAccess 或玩法对象。
##
## 明确不负责：
## 日志文本格式化、磁盘写入、日志文件轮转、等级过滤、控制台输出、UI 显示、
## 快照、自检协调、核心循环接线。这些属于后续批次。
##
## 关键状态生命周期：
## _entries 在构造后为空，随 append_entry 增长，由 _trim_to_limit 裁剪，
## 由 clear() 清空。max_in_memory_entries 在构造时确定，运行期不变更。
##
## 关键边界：
## - 依据 Diagnostics 红线，本类只观察/记录/只读校验，不参与玩法决策。
## - 本批只操作内存，不访问 user:// 或任何文件系统路径。
## - 对外返回的全部 DiagnosticLogEntry 均为新建副本，外部修改不得影响内部缓冲。
## - 非法入参不 push_error、不抛异常，统一以中文错误 PackedStringArray 返回。


## 默认内存日志条目上限。
## 当 _entries 超过该数量时，从最旧条目开始删除，控制内存占用。
const DEFAULT_MAX_IN_MEMORY_ENTRIES: int = 256


## 内存日志条目上限，运行期不变更。
## 构造时由 p_max_in_memory_entries 决定；小于 1 时内部使用 1，保证至少可容纳一条。
var max_in_memory_entries: int

## 内部日志缓冲，按写入顺序保存 DiagnosticLogEntry 副本。
## 外部不得直接访问；通过 get_entries() 获取深复制副本。
var _entries: Array[DiagnosticLogEntry] = []


## 构造运行期内存日志缓冲。
## [br]p_max_in_memory_entries 为内存日志条目上限，默认 256。
## [br]本函数仅初始化上限与空缓冲，不做校验也不输出错误。
## [br]副作用：设置 max_in_memory_entries，清空 _entries。
## [br]边界条件：p_max_in_memory_entries 小于 1 时内部使用 1，不 push_error、不抛异常。
func _init(
		p_max_in_memory_entries: int = DEFAULT_MAX_IN_MEMORY_ENTRIES
) -> void:
	# 上限小于 1 视为非法：不抛异常，统一降级到 1，保证缓冲至少可容纳一条日志。
	max_in_memory_entries = maxi(p_max_in_memory_entries, 1)
	_entries = []


## 追加一条诊断日志到内存缓冲。
## [br]entry 为待追加的 DiagnosticLogEntry，允许为 null。
## [br]返回 PackedStringArray：成功时为空；失败时包含全部中文错误，不写入缓冲。
## [br]副作用：校验通过时向 _entries 追加 entry 的副本，并在超限时从最旧条目开始删除。
## [br]失败条件：entry 为 null；或 entry.validate() 返回非空错误。
## [br]边界条件：不修改传入 entry；超限时删除最旧条目直到满足 max_in_memory_entries。
func append_entry(entry: DiagnosticLogEntry) -> PackedStringArray:
	# null 入参：不抛异常，返回中文错误，不写入缓冲。
	if entry == null:
		return PackedStringArray(["RuntimeLogger：entry 为 null，必须传入 DiagnosticLogEntry。"])
	# 一次获取全部校验错误：不提前返回，不降级处理，复用条目自身公共契约。
	var problems: PackedStringArray = entry.validate()
	if problems.size() > 0:
		# 校验失败：返回全部错误，不写入缓冲，不修改传入 entry。
		return problems
	# 校验通过：保存新建副本，避免外部后续修改原 entry 影响内部缓冲。
	_entries.append(_copy_entry(entry))
	# 追加后可能超限：从最旧条目开始删除，控制内存占用。
	_trim_to_limit()
	return PackedStringArray()


## 返回内部缓冲的深复制副本。
## [br]本函数无参数。
## [br]返回新的 Array[DiagnosticLogEntry]：数组本身新建，且其中每条日志也是新建副本。
## [br]副作用：无；外部修改返回结果不得影响内部缓冲。
## [br]边界条件：缓冲为空时返回新的空数组；不暴露内部数组引用。
func get_entries() -> Array[DiagnosticLogEntry]:
	# 新建类型化数组，逐条复制：外部修改返回数组或其中条目均不影响内部缓冲。
	var copies: Array[DiagnosticLogEntry] = []
	copies.resize(_entries.size())
	for index: int in range(_entries.size()):
		copies[index] = _copy_entry(_entries[index])
	return copies


## 返回当前内存缓冲中的日志条目数量。
## [br]本函数无参数。
## [br]返回 int：当前 _entries 大小。
## [br]本函数无副作用。
func size() -> int:
	return _entries.size()


## 判断内存缓冲是否为空。
## [br]本函数无参数。
## [br]返回 bool：true 表示无日志条目，false 表示至少有一条。
## [br]本函数无副作用。
func is_empty() -> bool:
	return _entries.is_empty()


## 清空内存缓冲。
## [br]本函数无参数。
## [br]返回 void：结果体现在 _entries 被清空。
## [br]副作用：清空 _entries；只清理内存，不访问磁盘、不写文件、不轮转。
## [br]边界条件：重复调用安全；max_in_memory_entries 不变。
func clear() -> void:
	# 只清理内存缓冲：本批不访问文件系统，不触发日志轮转或删除。
	_entries.clear()


## 复制一条 DiagnosticLogEntry，生成字段相同的新实例。
## [br]entry 为待复制的条目，调用方保证非 null。
## [br]返回新的 DiagnosticLogEntry，字段与入参一致但为独立实例。
## [br]本函数无副作用：不修改入参，不访问缓冲。
## [br]边界条件：仅复制字段值，不做校验；调用方负责保证入参合法。
func _copy_entry(entry: DiagnosticLogEntry) -> DiagnosticLogEntry:
	# 用同一套字段构造新实例：RefCounted 副本保证外部与内部互不影响。
	return DiagnosticLogEntry.new(
		entry.timestamp_unix_msec,
		entry.severity,
		entry.module_name,
		entry.execution_id,
		entry.message
	)


## 裁剪内部缓冲至 max_in_memory_entries 上限。
## [br]本函数无参数。
## [br]返回 void：结果体现在 _entries 可能被删除最旧条目。
## [br]副作用：当 _entries 超过上限时，从索引 0（最旧）开始逐条删除，直到满足上限。
## [br]边界条件：上限已满足时不做任何操作；max_in_memory_entries 至少为 1。
func _trim_to_limit() -> void:
	# 超限时从最旧条目开始删除：_entries 按写入顺序排列，索引 0 即最旧。
	while _entries.size() > max_in_memory_entries:
		_entries.remove_at(0)
