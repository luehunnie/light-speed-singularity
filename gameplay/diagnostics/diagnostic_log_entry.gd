class_name DiagnosticLogEntry
extends RefCounted

## 诊断日志条目公共数据契约。
##
## 职责：
## 保存一条诊断日志的事实数据（时间戳、等级、模块、执行 ID、消息），并提供只读校验；
## 供后续 RuntimeLogger 构造、序列化和写入 user://diagnostics/。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下日志条目数据层（批次 1A 只实现条目数据契约与校验）。
## 本批不实现日志记录器、文件写入、轮转、快照、自检或控制器，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 DiagnosticSeverity 的 Level 枚举与 is_valid 校验函数，以及 Godot 内建类型。
## 不依赖场景树、节点、玩法状态或文件系统。
##
## 明确不负责：
## 日志聚合、等级过滤、文件写入、JSON 序列化、轮转、控制台输出、UI 显示。
## 这些属于后续批次的 RuntimeLogger 等组件。
##
## 关键边界：
## - 本类只保存数据并只读校验：不修改字段、不 push_error、不抛异常、不写文件。
## - validate() 一次返回全部中文错误，不提前返回，不降级处理。
## - timestamp_unix_msec 使用 Unix 毫秒时间戳且必须非负；时间来源由上层 RuntimeLogger 提供。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 日志产生时刻的 Unix 毫秒时间戳。
## 由上层调用方传入（通常来自 Time.get_ticks_msec 或系统时间），必须非负。
var timestamp_unix_msec: int

## 日志等级，取值必须为 DiagnosticSeverity.Level 中的合法枚举值。
var severity: int

## 产生该日志的模块名，使用稳定 StringName，例如 &"OccupancyRegistry"。
## 不得为空；用于在日志中定位来源模块。
var module_name: StringName

## 本次执行的稳定 ID，用于关联同一运行期的全部日志。
## 不得为空；由上层在运行期开始时生成并传入。
var execution_id: StringName

## 日志正文消息。strip_edges 后必须非空；不得仅含空白。
var message: String


## 构造一条诊断日志条目。
## [br]p_timestamp 为 Unix 毫秒时间戳，必须非负。
## [br]p_severity 为 DiagnosticSeverity.Level 枚举值。
## [br]p_module 为来源模块名，不得为空。
## [br]p_execution 为本次执行 ID，不得为空。
## [br]p_message 为日志正文，strip_edges 后不得为空。
## [br]本函数仅赋值字段，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
func _init(
		p_timestamp: int,
		p_severity: int,
		p_module: StringName,
		p_execution: StringName,
		p_message: String
) -> void:
	timestamp_unix_msec = p_timestamp
	severity = p_severity
	module_name = p_module
	execution_id = p_execution
	message = p_message


## 只读校验当前条目的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改字段、不 push_error、不抛异常、不写文件。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]message 仅含空白视为错误（用 strip_edges 判定，不修改原字段）。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# 时间戳为负属于非法输入：Unix 毫秒时间戳必须非负。
	if timestamp_unix_msec < 0:
		problems.append("DiagnosticLogEntry：timestamp_unix_msec 为负，必须为非负 Unix 毫秒时间戳。")
	# 等级必须落在 DiagnosticSeverity.Level 合法范围内，交由公共契约判定，避免本类重复定义口径。
	if not DiagnosticSeverity.is_valid(severity):
		problems.append("DiagnosticLogEntry：severity=%d 不是合法的 DiagnosticSeverity.Level 值。" % [severity])
	# 模块名为空会导致日志无法定位来源模块。
	if module_name == &"":
		problems.append("DiagnosticLogEntry：module_name 为空，必须填写来源模块名。")
	# 执行 ID 为空会导致日志无法关联到运行期。
	if execution_id == &"":
		problems.append("DiagnosticLogEntry：execution_id 为空，必须填写执行 ID。")
	# 消息仅含空白属于无效正文：用 strip_edges 判定，不修改原 message 字段。
	if message.strip_edges() == "":
		problems.append("DiagnosticLogEntry：message 去除首尾空白后为空，必须填写日志正文。")
	return problems
