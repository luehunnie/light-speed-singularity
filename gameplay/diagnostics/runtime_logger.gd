class_name RuntimeLogger
extends RefCounted

## 运行期内存日志缓冲公共组件。
##
## 职责：
## 在内存中保存经过校验的 DiagnosticLogEntry，限制条目数量并在超限时删除最旧条目，
## 向调用者返回深复制副本，避免外部直接修改内部缓冲。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下日志缓冲与单文件输出层（批次 2A 实现最小内存缓冲，
## 批次 2B 增加单文件追加输出与稳定文本格式）。
## 本批访问 user://diagnostics 目录进行追加写入，但不实现文件轮转、大小限制、
## 文件数量清理，也不接入核心循环。
##
## 主要依赖：
## DiagnosticLogEntry 的构造与 validate()、DiagnosticSeverity.to_label() 等级标签，
## 以及 Godot 内建类型（int、bool、String、PackedStringArray、Array[DiagnosticLogEntry]）
## 与文件系统 API（FileAccess、DirAccess）。不依赖场景树、节点、Time、JSON 或玩法对象。
##
## 明确不负责：
## 日志轮转、2 MiB 大小判断、最多 8 个文件清理、等级过滤、控制台输出、UI 显示、
## 快照、自检协调、核心循环接线。这些属于后续批次。
## 文件输出与内存缓冲相互隔离：append_entry_to_file 只写磁盘，不修改 _entries；
## append_entry 只写内存，不写磁盘。
##
## 关键状态生命周期：
## _entries 在构造后为空，随 append_entry 增长，由 _trim_to_limit 裁剪，
## 由 clear() 清空。max_in_memory_entries 在构造时确定，运行期不变更。
##
## 关键边界：
## - 依据 Diagnostics 红线，本类只观察/记录/只读校验，不参与玩法决策。
## - 文件输出只写入 user://diagnostics，不得写入仓库资源目录；本批不做大小判断与轮转。
## - 对外返回的全部 DiagnosticLogEntry 均为新建副本，外部修改不得影响内部缓冲。
## - 非法入参不 push_error、不抛异常，统一以中文错误 PackedStringArray 返回。


## 默认内存日志条目上限。
## 当 _entries 超过该数量时，从最旧条目开始删除，控制内存占用。
const DEFAULT_MAX_IN_MEMORY_ENTRIES: int = 256


## 默认日志输出目录，位于用户数据目录下的 diagnostics 子目录。
## 文件输出只允许写入 user:// 下路径，禁止写入仓库资源目录。
const DEFAULT_LOG_DIRECTORY: String = "user://diagnostics"

## 默认日志文件名，仅为文件名，不含任何目录分隔符或 ..。
## append_entry_to_file 校验 file_name 时会拒绝包含 /、\ 或 .. 的取值。
const DEFAULT_LOG_FILE_NAME: String = "runtime.log"


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


## 将一条诊断日志以稳定文本格式追加写入单个日志文件。
## [br]entry 为待写入的 DiagnosticLogEntry，允许为 null。
## [br]directory_path 为日志目录，默认 DEFAULT_LOG_DIRECTORY（user://diagnostics）。
## [br]file_name 为日志文件名，默认 DEFAULT_LOG_FILE_NAME（runtime.log），必须只是文件名。
## [br]返回 PackedStringArray：成功时为空；失败时包含全部中文错误，不写入文件。
## [br]副作用：校验通过时确保目录存在，以追加模式向日志文件写入一条 UTF-8 文本记录并换行。
## [br]失败条件：entry 为 null；entry.validate() 返回非空错误；directory_path 或 file_name
##   去除首尾空白后为空；file_name 包含 /、\ 或 ..；目录创建失败；文件打开失败。
## [br]边界条件：不修改传入 entry；不写入内存缓冲 _entries；不调用 push_error，不抛异常；
##   不做 2 MiB 大小判断、不轮转、不清理旧文件；磁盘错误不混入 append_entry 的内存写入语义。
func append_entry_to_file(
		entry: DiagnosticLogEntry,
		directory_path: String = DEFAULT_LOG_DIRECTORY,
		file_name: String = DEFAULT_LOG_FILE_NAME
) -> PackedStringArray:
	# null 入参：不抛异常，返回中文错误，不写文件、不写内存。
	if entry == null:
		return PackedStringArray(["RuntimeLogger：entry 为 null，必须传入 DiagnosticLogEntry。"])
	# 复用条目自身公共校验契约：一次返回全部错误，不写入文件。
	var entry_problems: PackedStringArray = entry.validate()
	if entry_problems.size() > 0:
		return entry_problems
	# 校验目录与文件名：不合法时不创建目录、不打开文件。
	var target_problems: PackedStringArray = _validate_file_target(directory_path, file_name)
	if target_problems.size() > 0:
		return target_problems
	# 目录去空白后作为实际写入路径前缀，文件名同样去空白。
	var dir_clean: String = directory_path.strip_edges()
	var name_clean: String = file_name.strip_edges()
	# 确保目录存在：失败时返回中文错误，不打开文件。
	var dir_problems: PackedStringArray = _ensure_directory_exists(dir_clean)
	if dir_problems.size() > 0:
		return dir_problems
	# 拼接最终文件路径：目录与文件名之间用 / 连接，user:// 路径统一使用正斜杠。
	var file_path: String = dir_clean + "/" + name_clean
	# 格式化稳定文本记录：五列 Tab 分隔，字段已转义。
	var line: String = _format_entry_line(entry)
	# 追加模式：已存在文件用 READ_WRITE 打开（不截断）再 seek_end；新文件用 WRITE 创建。
	# 不使用单一 READ_WRITE，避免对该标志“不存在时是否创建”的语义歧义造成写入失败。
	var file: FileAccess = null
	if FileAccess.file_exists(file_path):
		file = FileAccess.open(file_path, FileAccess.READ_WRITE)
	else:
		file = FileAccess.open(file_path, FileAccess.WRITE)
	# 打开失败：返回中文错误与错误码，不调用 push_error，不抛异常。
	if file == null:
		var open_error: int = FileAccess.get_open_error()
		return PackedStringArray(["RuntimeLogger：无法打开日志文件 %s，错误码 %d。" % [file_path, open_error]])
	# 已存在文件定位到末尾以追加，而非覆盖既有内容。
	file.seek_end(0)
	# 写入一条 UTF-8 文本记录并换行；store_string 默认以 UTF-8 编码。
	file.store_string(line + "\n")
	file.close()
	return PackedStringArray()


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


## 将一条 DiagnosticLogEntry 格式化为稳定五列文本记录。
## [br]entry 为待格式化的条目，调用方保证非 null 且已通过 validate()。
## [br]返回 String：五列以 Tab 分隔，依次为 timestamp_unix_msec、severity_label、
##   module_name、execution_id、message；后四列字段内容已转义。
## [br]本函数无副作用：不修改入参，不访问文件系统，不访问内存缓冲。
## [br]边界条件：timestamp 使用原始整数，不做日期和时区格式化；
##   severity 使用 DiagnosticSeverity.to_label()；字段中的反斜杠、Tab、回车、换行已转义。
func _format_entry_line(entry: DiagnosticLogEntry) -> String:
	# timestamp 直接取整数转字符串，不做任何日期/时区格式化，保持稳定可解析。
	var timestamp_text: String = str(entry.timestamp_unix_msec)
	# severity 转稳定大写标签；越界值由 to_label 统一降级为 UNKNOWN，不在此处报错。
	var severity_text: String = _escape_field(String(DiagnosticSeverity.to_label(entry.severity)))
	# module_name 与 execution_id 为 StringName，转 String 后转义，避免内部含分隔符破坏列结构。
	var module_text: String = _escape_field(String(entry.module_name))
	var execution_text: String = _escape_field(String(entry.execution_id))
	# message 最可能含换行/Tab，必须转义以保证单行记录语义。
	var message_text: String = _escape_field(entry.message)
	# 五列以 Tab 分隔，调用方在写入时再追加换行符。
	return timestamp_text + "\t" + severity_text + "\t" + module_text + "\t" + execution_text + "\t" + message_text


## 转义字段内容中的特殊字符，保证单行五列结构不被破坏。
## [br]value 为待转义的原始字符串。
## [br]返回 String：反斜杠替换为 \\，Tab 替换为 \t，回车替换为 \r，换行替换为 \n。
## [br]本函数无副作用：不修改入参，返回新字符串。
## [br]边界条件：先处理反斜杠，避免后续替换引入的字符被二次转义；空串原样返回。
func _escape_field(value: String) -> String:
	# 先替换反斜杠：若先替换其他字符，其引入的 \ 会被本步二次转义，导致语义错误。
	var escaped: String = value.replace("\\", "\\\\")
	# 再替换控制字符为可见转义序列，保证单行记录不再含真实 Tab/回车/换行。
	escaped = escaped.replace("\t", "\\t")
	escaped = escaped.replace("\r", "\\r")
	escaped = escaped.replace("\n", "\\n")
	return escaped


## 校验日志写入目标的目录与文件名合法性。
## [br]directory_path 为日志目录，允许含首尾空白。
## [br]file_name 为日志文件名，允许含首尾空白。
## [br]返回 PackedStringArray：全部合法时为空；存在问题时包含全部中文错误。
## [br]本函数无副作用：不修改入参，不创建目录，不打开文件。
## [br]边界条件：directory_path 或 file_name 去除首尾空白后为空视为非法；
##   file_name 必须只是文件名，不得包含 /、\ 或 ..，防止越出目录或路径穿越。
func _validate_file_target(directory_path: String, file_name: String) -> PackedStringArray:
	var problems: PackedStringArray = []
	var dir_clean: String = directory_path.strip_edges()
	var name_clean: String = file_name.strip_edges()
	# 目录去空白后不得为空：空目录无法定位日志文件。
	if dir_clean.is_empty():
		problems.append("RuntimeLogger：directory_path 去除首尾空白后为空，必须指定日志目录。")
	# 文件名去空白后不得为空：空文件名无法构成日志路径。
	if name_clean.is_empty():
		problems.append("RuntimeLogger：file_name 去除首尾空白后为空，必须指定日志文件名。")
	# 文件名必须只是文件名：含分隔符或 .. 可能越出目录或路径穿越，统一拒绝。
	elif name_clean.contains("/") or name_clean.contains("\\") or name_clean.contains(".."):
		problems.append("RuntimeLogger：file_name 必须只是文件名，不得包含 /、\\ 或 ..。")
	return problems


## 确保日志目录存在，不存在则递归创建。
## [br]directory_path 为日志目录，调用方保证已去空白且非空。
## [br]返回 PackedStringArray：创建成功或目录已存在时为空；失败时包含中文错误。
## [br]副作用：当目录不存在时在 user:// 下递归创建目录。
## [br]边界条件：目录已存在视为成功；创建失败返回中文错误，不抛异常、不 push_error。
func _ensure_directory_exists(directory_path: String) -> PackedStringArray:
	# 递归创建目录：已存在时 Godot 返回 OK，无需事先判断是否存在。
	var make_error: int = DirAccess.make_dir_recursive_absolute(directory_path)
	# OK 与 ERR_ALREADY_EXISTS 都视为目录已就绪，其余错误码视为创建失败。
	if make_error != OK and make_error != ERR_ALREADY_EXISTS:
		return PackedStringArray(["RuntimeLogger：无法创建日志目录 %s，错误码 %d。" % [directory_path, make_error]])
	return PackedStringArray()
