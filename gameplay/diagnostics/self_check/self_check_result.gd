class_name SelfCheckResult
extends RefCounted

## 自检结果公共数据契约。
##
## 职责：
## 保存一次自检的事实结果（检查 ID、是否通过、摘要、明细、耗时），并提供只读校验；
## 供后续 SelfCheckRunner 汇总、RuntimeLogger 记录和 RuntimeSnapshot 序列化使用。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下自检结果数据层（批次 1B 只实现结果数据契约与校验）。
## 本批不实现 SelfCheckRunner、RuntimeLogger、RuntimeSnapshot、DiagnosticsController、
## JSON 序列化、文件写入，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（StringName、bool、String、PackedStringArray、int）。
## 不依赖 DiagnosticSeverity、场景树、节点、时间 API、文件系统或玩法对象。
##
## 明确不负责：
## 执行检查、聚合多条结果、等级判定、日志写入、JSON 序列化、文件轮转、控制台输出、UI 显示。
## 这些属于后续批次的 SelfCheckRunner 等组件。
##
## 关键边界：
## - 本类只保存数据并只读校验：不修改字段（构造后字段不再变更）、不 push_error、不抛异常、不写文件。
## - validate() 一次返回全部中文错误，不提前返回，不降级处理。
## - duration_usec 由上层调用方传入（通常来自 Time.get_ticks_usec 差值），本类不访问任何时间 API。
## - passed=false 时允许 details 为空（失败检查可以只给摘要）；validate 不以此为错误。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 自检项的稳定 ID，使用稳定 StringName，例如 &"occupancy_double_index"。
## 不得为空；用于在结果汇总中定位检查来源。
var check_id: StringName

## 该自检项是否通过。true 表示通过，false 表示失败或异常。
var passed: bool

## 自检结果摘要，去除首尾空白后必须非空；用于在日志和快照中简短描述结果。
var summary: String

## 自检明细，零项或多项；每项去除首尾空白后必须非空。
## passed=false 时允许为空；passed=true 时也可以为空（通过检查无需额外明细）。
var details: PackedStringArray

## 自检耗时，单位微秒（usec），必须非负。
## 由上层调用方传入，本类不访问时间 API。
var duration_usec: int


## 构造一条自检结果。
## [br]p_check_id 为自检项稳定 ID，不得为空。
## [br]p_passed 表示是否通过。
## [br]p_summary 为结果摘要，strip_edges 后不得为空。
## [br]p_details 为明细数组，默认空数组；每项 strip_edges 后不得为空；传入后会被复制，调用方之后修改原数组不影响本结果。
## [br]p_duration_usec 为耗时（微秒），默认 0，必须非负。
## [br]本函数仅赋值字段，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
func _init(
		p_check_id: StringName,
		p_passed: bool,
		p_summary: String,
		p_details: PackedStringArray = PackedStringArray(),
		p_duration_usec: int = 0
) -> void:
	check_id = p_check_id
	passed = p_passed
	summary = p_summary
	# 复制传入数组，避免调用方之后修改原 PackedStringArray 影响本结果的数据完整性。
	details = p_details.duplicate()
	duration_usec = p_duration_usec


## 只读校验当前结果对象的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改字段、不 push_error、不抛异常、不访问时间/文件/场景树/玩法对象。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]details 中每一项去除首尾空白后必须非空；passed=false 时 details 为空不算错误。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# check_id 为空会导致结果无法定位到检查来源。
	if check_id == &"":
		problems.append("SelfCheckResult：check_id 为空，必须填写自检项稳定 ID。")
	# 摘要仅含空白属于无效结果描述：用 strip_edges 判定，不修改原 summary 字段。
	if summary.strip_edges() == "":
		problems.append("SelfCheckResult：summary 去除首尾空白后为空，必须填写结果摘要。")
	# 耗时为负属于非法输入：微秒耗时必须非负。
	if duration_usec < 0:
		problems.append("SelfCheckResult：duration_usec 为负，必须为非负微秒耗时。")
	# 逐项检查明细：每项去除首尾空白后必须非空；空 details（无论 passed 取值）不在此处报错。
	for index: int in range(details.size()):
		if details[index].strip_edges() == "":
			problems.append("SelfCheckResult：details 第 %d 项去除首尾空白后为空，明细项不得仅含空白。" % [index + 1])
	return problems
