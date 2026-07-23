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
## 批次 2B 增加单文件追加输出与稳定文本格式，批次 2C 增加单文件 2 MiB 大小限制、
## 最多 8 个文件的轮转与陈旧归档清理）。
## 本批访问 user://diagnostics/logs 目录进行追加写入与轮转，但不接入核心循环。
##
## 主要依赖：
## DiagnosticLogEntry 的构造与 validate()、DiagnosticSeverity.to_label() 等级标签，
## 以及 Godot 内建类型（int、bool、String、PackedStringArray、Array[DiagnosticLogEntry]）
## 与文件系统 API（FileAccess、DirAccess）。不依赖场景树、节点、Time、JSON 或玩法对象。
##
## 明确不负责：
## 等级过滤、控制台输出、UI 显示、快照、自检协调、核心循环接线。这些属于后续批次。
## 文件输出与内存缓冲相互隔离：append_entry_to_file 只写磁盘，不修改 _entries；
## append_entry 只写内存，不写磁盘。
##
## 关键状态生命周期：
## _entries 在构造后为空，随 append_entry 增长，由 _trim_to_limit 裁剪，
## 由 clear() 清空。max_in_memory_entries 在构造时确定，运行期不变更。
##
## 关键边界：
## - 依据 Diagnostics 红线，本类只观察/记录/只读校验，不参与玩法决策。
## - 文件输出只写入 user://diagnostics/logs，不得写入仓库资源目录、user://diagnostics 根目录
##   或 user://diagnostics/snapshots；单文件最大 2 MiB，
##   最多 8 个文件（当前文件加 .1 到 .7 共 7 个归档），总量不超过 16 MiB，
##   超限时按从旧到新轮转，删除最旧归档失败只 push_warning 不阻塞主流程。
## - 对外返回的全部 DiagnosticLogEntry 均为新建副本，外部修改不得影响内部缓冲。
## - 非法入参不 push_error、不抛异常，统一以中文错误 PackedStringArray 返回。


## 默认内存日志条目上限。
## 当 _entries 超过该数量时，从最旧条目开始删除，控制内存占用。
const DEFAULT_MAX_IN_MEMORY_ENTRIES: int = 256


## 默认日志输出目录，位于用户数据目录下的 diagnostics/logs 子目录。
## 文件输出只允许写入 user://diagnostics/logs 或其合法子目录；
## 禁止写入仓库资源目录、user://diagnostics 根目录或 user://diagnostics/snapshots。
const DEFAULT_LOG_DIRECTORY: String = "user://diagnostics/logs"

## 默认日志文件名，仅为文件名，不含任何目录分隔符或 ..。
## append_entry_to_file 校验 file_name 时会拒绝包含 /、\ 或 .. 的取值。
const DEFAULT_LOG_FILE_NAME: String = "runtime.log"


## 单个日志文件最大字节数：2 MiB。
## 写入前按 UTF-8 字节计算记录大小；当前文件加本条记录超过该值时先轮转再写入。
## 单条记录自身超过该值时直接拒绝写入，不创建、修改或轮转任何文件。
const MAX_LOG_FILE_SIZE_BYTES: int = 2 * 1024 * 1024

## 日志文件最大保留数量，含当前文件与归档。
## 当前文件 runtime.log 加 .1 到 .7 共 7 个归档，总数最多 8 个；
## 每个正常生成的文件不超过 2 MiB，目录总量因此不超过 16 MiB。
const MAX_LOG_FILE_COUNT: int = 8


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
## [br]directory_path 为日志目录，默认 DEFAULT_LOG_DIRECTORY（user://diagnostics/logs）。
##   必须等于 user://diagnostics/logs 或以其为前缀的合法子目录；res://、原生绝对路径、
##   user://diagnostics 根目录、user://diagnostics/snapshots、user:// 其他目录、通过 .. 逃逸的路径一律拒绝，
##   由 _normalize_log_directory 规范化后判定。
## [br]file_name 为日志文件名，默认 DEFAULT_LOG_FILE_NAME（runtime.log），必须只是文件名。
## [br]返回 PackedStringArray：成功时为空；失败时包含全部中文错误，不写入文件。
## [br]副作用：校验 entry 与目标路径文本后格式化日志行并按 UTF-8 字节计算大小；
##   单条超 2 MiB 立即返回错误，此前不创建目录、不打开/删除/轮转任何文件；
##   单条大小合法后才确保目录存在；当前文件加本条记录超过 2 MiB 时先按从旧到新轮转
##   （删除最旧 .7、.6 到 .1 链式重命名、当前文件重命名为 .1），再写入新的当前文件；
##   否则直接追加；每次正常写入后清理 .8 及以后陈旧归档。轮转与清理只作用于由
##   directory_path 与 file_name 推导出的日志文件，不删除目录内其他文件。
## [br]失败条件：entry 为 null；entry.validate() 返回非空错误；directory_path 或 file_name
##   去除首尾空白后为空；directory_path 越出 user://diagnostics/logs 边界；file_name 包含 /、\ 或 ..；
##   单条记录超 2 MiB；目录创建失败；必要轮转（目录打开或重命名）失败；文件打开、写入或 flush 失败。
## [br]边界条件：不修改传入 entry；不写入内存缓冲 _entries；不调用 push_error，不抛异常；
##   单条超限不触碰文件系统，目录不存在时也不会被创建；写入与 flush 后检测 FileAccess.get_error()，
##   失败以中文错误返回，不报告为成功；删除最旧归档或清理陈旧归档失败只 push_warning，
##   不阻塞本次写入、不混入返回错误；不递归记录到 RuntimeLogger；磁盘错误不混入 append_entry 的内存写入语义。
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
	# 校验目录非空与文件名文本：不合法时不创建目录、不打开文件。
	var target_problems: PackedStringArray = _validate_file_target(directory_path, file_name)
	if target_problems.size() > 0:
		return target_problems
	# 目录、文件名去空白后作为实际写入依据。
	var dir_clean: String = directory_path.strip_edges()
	var name_clean: String = file_name.strip_edges()
	# 校验并规范化目录边界：拒绝 res://、原生绝对路径、user://diagnostics 根目录、snapshots 目录、user:// 其他目录、.. 逃逸；
	# 规范化后只允许等于 user://diagnostics/logs 或以 user://diagnostics/logs/ 开头的子目录，后续一律使用规范化路径。
	var dir_resolve: Dictionary = _normalize_log_directory(dir_clean)
	if not bool(dir_resolve["valid"]):
		return PackedStringArray([String(dir_resolve["error"])])
	var dir_normalized: String = dir_resolve["path"]
	# 格式化稳定文本记录：五列 Tab 分隔，字段已转义。
	var line: String = _format_entry_line(entry)
	# 按 UTF-8 字节计算记录加换行后的大小：不得用 String.length() 代替，中文等多字节字符字节数与字符数不等。
	var line_size: int = _get_utf8_line_size_bytes(line)
	# 单条记录自身超过 2 MiB：立即返回错误，早于一切文件系统操作；
	# 此前不得创建目录、打开文件、删除文件或轮转；目录不存在时也不会被创建。
	if line_size > MAX_LOG_FILE_SIZE_BYTES:
		return PackedStringArray(["RuntimeLogger：单条日志记录 %d 字节超过单文件上限 %d 字节，拒绝写入。" % [line_size, MAX_LOG_FILE_SIZE_BYTES]])
	# 单条大小合法后才允许确保目录存在：失败时返回中文错误，不打开文件。
	var dir_problems: PackedStringArray = _ensure_directory_exists(dir_normalized)
	if dir_problems.size() > 0:
		return dir_problems
	# 拼接最终文件路径：规范化目录与文件名之间用 / 连接，user:// 路径统一使用正斜杠。
	var file_path: String = dir_normalized + "/" + name_clean
	# 获取当前文件字节大小：不存在或无法读取视为 0，由后续判断决定是否轮转。
	var current_size: int = _get_file_size_bytes(file_path)
	# 当前文件加本条记录超过 2 MiB：先执行必要轮转，再写入新的当前文件。
	if current_size + line_size > MAX_LOG_FILE_SIZE_BYTES:
		var rotate_problems: PackedStringArray = _rotate_log_files(dir_normalized, name_clean)
		if rotate_problems.size() > 0:
			# 必要轮转无法完成：禁止继续向已满当前文件追加，返回中文错误。
			return rotate_problems
	# 写入一条 UTF-8 文本记录并换行；轮转后当前文件不存在，由本函数以 WRITE 新建。
	var write_problems: PackedStringArray = _append_line_to_file(file_path, line)
	if write_problems.size() > 0:
		return write_problems
	# 每次正常写入后清理 .8 及以后陈旧归档：与是否轮转无关；
	# 失败只 push_warning，不阻塞本次写入、不混入返回错误、不递归记录到 RuntimeLogger。
	_cleanup_stale_rotated_files(dir_normalized, name_clean)
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


## 校验日志写入目标的目录非空与文件名合法性。
## [br]directory_path 为日志目录，允许含首尾空白。
## [br]file_name 为日志文件名，允许含首尾空白。
## [br]返回 PackedStringArray：全部合法时为空；存在问题时包含全部中文错误。
## [br]本函数无副作用：不修改入参，不创建目录，不打开文件。
## [br]边界条件：directory_path 或 file_name 去除首尾空白后为空视为非法；
##   file_name 必须只是文件名，不得包含 /、\ 或 ..，防止越出目录或路径穿越；
##   directory_path 的 user://diagnostics/logs 边界校验由 _normalize_log_directory 负责。
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


## 校验并规范化日志目录，确保其等于 user://diagnostics/logs 或位于其合法子目录内。
## [br]dir_clean 为已去除首尾空白的日志目录，调用方保证非空。
## [br]返回 Dictionary：合法时 {"valid": true, "path": 规范化路径, "error": ""}；
##   非法时 {"valid": false, "path": "", "error": 中文错误}。
## [br]本函数无副作用：不修改入参，不访问文件系统，仅做文本规范化与边界判定。
## [br]失败条件：不以 user:// 开头（涵盖 res://、原生绝对路径、相对路径）；通过 .. 逃逸到 user:// 根之上；
##   规范化后既不等于 user://diagnostics/logs 也不以 user://diagnostics/logs/ 开头
##   （涵盖 user://diagnostics 根目录、user://diagnostics/snapshots、logs_evil、logs2 等）。
## [br]边界条件：先 strip_edges 由调用方完成；统一反斜杠为正斜杠后按段处理 . 与 ..；
##   .. 不得逃逸到 user:// 根之上；前缀判断含明确的 / 边界（DEFAULT_LOG_DIRECTORY + "/"），
##   不得仅用 starts_with("user://diagnostics/logs")，避免匹配 logs_evil、logs2 等同级伪前缀；
##   不改变默认目录。
func _normalize_log_directory(dir_clean: String) -> Dictionary:
	# 非 user:// 一律拒绝：涵盖 res://、原生绝对路径（如 C:\、/home）与相对路径。
	if not dir_clean.begins_with("user://"):
		return {"valid": false, "path": "", "error": "RuntimeLogger：directory_path 必须位于 user:// 下，不得使用 res://、原生绝对路径或相对路径。"}
	# 取 user:// 之后部分，统一反斜杠为正斜杠后按 / 切分；allow_empty=false 跳过空段，容忍多余斜杠。
	var remainder: String = dir_clean.substr("user://".length()).replace("\\", "/")
	var raw_segments: PackedStringArray = remainder.split("/", false)
	var normalized_segments: PackedStringArray = []
	for segment: String in raw_segments:
		if segment == ".":
			# 当前目录段：忽略，不改变规范化结果。
			continue
		elif segment == "..":
			# 上一级段：栈空仍遇 .. 即视为逃逸到 user:// 根之上，拒绝。
			if normalized_segments.is_empty():
				return {"valid": false, "path": "", "error": "RuntimeLogger：directory_path 不得通过 .. 逃逸到 user://diagnostics/logs 之外。"}
			normalized_segments.remove_at(normalized_segments.size() - 1)
		else:
			normalized_segments.append(segment)
	# 重建规范化路径：段为空时即 user:// 根，必将在后续边界判定中被拒绝。
	var normalized: String = "user://"
	if normalized_segments.size() > 0:
		normalized += "/".join(normalized_segments)
	# 边界判定：只允许等于 user://diagnostics/logs 或以 user://diagnostics/logs/ 开头；
	# 前缀判断含明确的 / 边界（DEFAULT_LOG_DIRECTORY + "/"），避免匹配 logs_evil、logs2 等同级伪前缀。
	if normalized != DEFAULT_LOG_DIRECTORY and not normalized.begins_with(DEFAULT_LOG_DIRECTORY + "/"):
		return {"valid": false, "path": "", "error": "RuntimeLogger：directory_path 必须位于 user://diagnostics/logs 或其子目录内，不得指向 user://diagnostics 根目录、snapshots 或 user:// 其他目录。"}
	return {"valid": true, "path": normalized, "error": ""}


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


## 以追加或新建方式向当前日志文件写入一条 UTF-8 文本记录并换行。
## [br]file_path 为最终日志文件路径，调用方保证已通过目录与文件名校验。
## [br]line 为已格式化、已转义的五列文本记录，调用方保证非空。
## [br]返回 PackedStringArray：成功时为空；文件打开、写入或 flush 失败时包含中文错误。
## [br]副作用：已存在文件以 READ_WRITE 打开并定位到末尾追加；不存在文件以 WRITE 创建并写入；
##   写入后 flush 并检测 FileAccess.get_error()，失败时关闭文件并以中文错误返回。
## [br]失败条件：文件打开失败；store_string 或 flush 后 get_error() 返回非 OK。
## [br]边界条件：不修改内存缓冲；不修改传入 line；不调用 push_error，不抛异常；不截断既有内容；
##   写入或 flush 失败不得报告为成功；store_string 默认以 UTF-8 编码，与 _get_utf8_line_size_bytes 的字节口径一致。
func _append_line_to_file(file_path: String, line: String) -> PackedStringArray:
	# 已存在文件用 READ_WRITE 打开（不截断）再 seek_end；新文件用 WRITE 创建。
	# 不使用单一 READ_WRITE 处理新文件，避免“不存在时是否创建”的语义歧义造成写入失败。
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
	# 写入一条 UTF-8 文本记录并换行，随后 flush 落盘。
	file.store_string(line + "\n")
	file.flush()
	# 检测真实写入错误：store_string 与 flush 均可能失败，get_error 返回非 OK 即视为写入失败。
	var write_error: int = file.get_error()
	if write_error != OK:
		# 写入或 flush 失败：关闭文件，以中文错误返回，不得报告为成功。
		file.close()
		return PackedStringArray(["RuntimeLogger：写入日志文件 %s 失败，错误码 %d。" % [file_path, write_error]])
	file.close()
	return PackedStringArray()


## 计算一条日志记录写入文件后占用的 UTF-8 字节数（含末尾换行）。
## [br]line 为已格式化的五列文本记录，不含末尾换行。
## [br]返回 int：line 的 UTF-8 字节数加 1（换行符在 UTF-8 中占 1 字节）。
## [br]本函数无副作用：不修改入参，不访问文件系统。
## [br]边界条件：不得用 String.length() 代替 UTF-8 字节长度，中文等多字节字符的字符数与字节数不等；
##   空串返回 1（仅换行符）。
func _get_utf8_line_size_bytes(line: String) -> int:
	# to_utf8_buffer 返回 UTF-8 编码字节，size() 为字节数；换行符在 UTF-8 中占 1 字节。
	return line.to_utf8_buffer().size() + 1


## 获取指定文件的字节大小。
## [br]file_path 为最终日志文件路径。
## [br]返回 int：文件存在且可读时返回字节大小；不存在或打开失败时返回 0。
## [br]本函数无副作用：不修改文件内容，不调用 push_error，不抛异常。
## [br]边界条件：文件不存在返回 0，调用方据此按空文件处理；打开失败（如被占用）返回 0，
##   后续写入若同样失败会以中文错误返回，不会静默超限。
func _get_file_size_bytes(file_path: String) -> int:
	# 不存在视为 0 字节，调用方据此判断是否需要轮转。
	if not FileAccess.file_exists(file_path):
		return 0
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	# 打开失败无法获取大小：返回 0，避免抛异常；后续写入若同样失败会以错误返回。
	if file == null:
		return 0
	var length: int = file.get_length()
	file.close()
	return length


## 根据当前文件名与归档编号构造归档文件名。
## [br]file_name 为当前日志文件名，调用方保证仅为文件名（无目录分隔符或 ..）。
## [br]index 为归档编号，1 表示最新归档，MAX_LOG_FILE_COUNT - 1（7）表示最旧归档。
## [br]返回 String：在最终扩展名前插入“.<index>”；无扩展名时追加“.<index>”。
## [br]本函数无副作用：不修改入参，不访问文件系统。
## [br]边界条件：runtime.log -> runtime.1.log；example.txt -> example.1.txt；
##   runtime（无扩展名）-> runtime.1；多段扩展名取最后一段为扩展名。
func _build_rotated_file_name(file_name: String, index: int) -> String:
	var extension: String = file_name.get_extension()
	# 无扩展名：直接在文件名后追加“.<index>”。
	if extension.is_empty():
		return file_name + "." + str(index)
	# 有扩展名：在最终扩展名前插入“.<index>”，保持原扩展名不变。
	return file_name.get_basename() + "." + str(index) + "." + extension


## 对当前日志文件执行从旧到新的轮转。
## [br]directory_path 为日志目录，调用方保证已去空白、已存在、已通过边界校验。
## [br]file_name 为当前日志文件名，调用方保证仅为文件名。
## [br]返回 PackedStringArray：必要步骤成功时为空；目录打开或必要重命名失败时包含中文错误。
## [br]副作用：删除最旧 .7（失败只 push_warning）；将 .6 重命名为 .7，依次到 .1 重命名为 .2；
##   将当前文件重命名为 .1；释放目录句柄。陈旧归档（.8 及以后）清理由调用方在正常写入后统一执行。
## [br]失败条件：无法打开日志目录；必要重命名（含当前文件重命名为 .1）失败。
## [br]边界条件：删除最旧 .7 失败不加入返回错误、不阻塞，只 push_warning；
##   源文件不存在时跳过对应重命名，不视为错误；轮转后由调用方写入新的当前文件；
##   只操作由 directory_path 与 file_name 推导出的文件，不删除无关文件。
func _rotate_log_files(directory_path: String, file_name: String) -> PackedStringArray:
	var dir_access: DirAccess = DirAccess.open(directory_path)
	if dir_access == null:
		var open_error: int = DirAccess.get_open_error()
		return PackedStringArray(["RuntimeLogger：无法打开日志目录 %s 进行轮转，错误码 %d。" % [directory_path, open_error]])
	# 1. 删除最旧 .7：非关键，失败只 push_warning，不加入返回错误、不阻塞本次写入。
	var oldest_name: String = _build_rotated_file_name(file_name, MAX_LOG_FILE_COUNT - 1)
	if dir_access.file_exists(oldest_name):
		var remove_error: int = dir_access.remove(oldest_name)
		if remove_error != OK:
			push_warning("RuntimeLogger：删除最旧归档 %s 失败，错误码 %d，已跳过。" % [oldest_name, remove_error])
	# 2. 从 .6 到 .1 依次重命名为下一编号：必要步骤，失败返回错误并阻止本次写入。
	#    从高编号向低编号处理，保证每个目标槽位在写入前已被上一级重命名腾空。
	var index: int = MAX_LOG_FILE_COUNT - 2
	while index >= 1:
		var src_name: String = _build_rotated_file_name(file_name, index)
		var dst_name: String = _build_rotated_file_name(file_name, index + 1)
		# 源归档不存在表示该编号暂无归档，跳过，不视为错误。
		if dir_access.file_exists(src_name):
			var rename_error: int = dir_access.rename(src_name, dst_name)
			if rename_error != OK:
				return PackedStringArray(["RuntimeLogger：轮转重命名 %s 为 %s 失败，错误码 %d。" % [src_name, dst_name, rename_error]])
		index -= 1
	# 3. 当前文件重命名为 .1：必要步骤，失败返回错误并阻止本次写入。
	if dir_access.file_exists(file_name):
		var first_name: String = _build_rotated_file_name(file_name, 1)
		var rename_error: int = dir_access.rename(file_name, first_name)
		if rename_error != OK:
			return PackedStringArray(["RuntimeLogger：轮转重命名当前文件 %s 为 %s 失败，错误码 %d。" % [file_name, first_name, rename_error]])
	# 释放目录句柄：陈旧归档清理由调用方在写入后统一执行，避免每次轮转重复清理。
	dir_access = null
	return PackedStringArray()


## 解析目录项名称，判断是否为当前 file_name 的归档并返回其编号。
## [br]item 为目录枚举得到的文件名。
## [br]base_name 为当前文件名去除最终扩展名后的前缀。
## [br]extension 为当前文件名的最终扩展名，无扩展名时为空串。
## [br]返回 int：匹配“<base_name>.<编号>”或“<base_name>.<编号>.<extension>”时返回编号；否则返回 -1。
## [br]本函数无副作用：不修改入参，不访问文件系统。
## [br]边界条件：当前文件自身与无关前缀、无关扩展名文件均返回 -1；编号非整数返回 -1。
func _parse_rotated_index(item: String, base_name: String, extension: String) -> int:
	# 必须以“<base_name>.”开头，排除前缀不同的无关文件。
	if not item.begins_with(base_name + "."):
		return -1
	var remainder: String = item.substr(base_name.length() + 1)
	var index_text: String
	if extension.is_empty():
		# 无扩展名：remainder 即编号文本。
		index_text = remainder
	else:
		# 有扩展名：remainder 应为“<编号>.<extension>”，截取编号部分。
		var suffix: String = "." + extension
		if not remainder.ends_with(suffix):
			return -1
		index_text = remainder.substr(0, remainder.length() - suffix.length())
	# 编号必须为合法整数，否则视为无关文件。
	if not index_text.is_valid_int():
		return -1
	return index_text.to_int()


## 清理超过保留范围的陈旧归档文件（编号大于等于 MAX_LOG_FILE_COUNT 的 .8、.9 等）。
## [br]directory_path 为日志目录，调用方保证已去空白、已存在。
## [br]file_name 为当前日志文件名，用于推导归档命名前缀与扩展名。
## [br]返回 void：结果仅体现在删除陈旧归档；全部失败处理只 push_warning。
## [br]副作用：枚举目录，删除匹配当前 file_name 命名规则且编号 >= MAX_LOG_FILE_COUNT 的归档；
##   不删除当前文件、.1 到 .7 归档或任何无关文件。
## [br]失败条件：无法打开目录（只 push_warning）；单个陈旧归档删除失败（只 push_warning）。
## [br]边界条件：不递归记录到 RuntimeLogger，避免日志器记录自身导致循环；
##   只匹配由 file_name 推导出的归档命名，不扫描或删除无关前缀、无关扩展名文件。
func _cleanup_stale_rotated_files(directory_path: String, file_name: String) -> void:
	var dir_access: DirAccess = DirAccess.open(directory_path)
	if dir_access == null:
		push_warning("RuntimeLogger：无法打开日志目录 %s 进行陈旧归档清理。" % directory_path)
		return
	var extension: String = file_name.get_extension()
	var base_name: String = file_name.get_basename()
	dir_access.list_dir_begin()
	var item: String = dir_access.get_next()
	while item != "":
		# 跳过子目录，只处理文件；list_dir_begin 默认不含 . 与 ..。
		if not dir_access.current_is_dir():
			var stale_index: int = _parse_rotated_index(item, base_name, extension)
			# 编号 >= MAX_LOG_FILE_COUNT 的归档超出保留范围，删除；失败只 push_warning。
			if stale_index >= MAX_LOG_FILE_COUNT:
				var remove_error: int = dir_access.remove(item)
				if remove_error != OK:
					push_warning("RuntimeLogger：清理陈旧归档 %s 失败，错误码 %d，已跳过。" % [item, remove_error])
		item = dir_access.get_next()
	dir_access.list_dir_end()
