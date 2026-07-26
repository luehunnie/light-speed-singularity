class_name SelfCheckRunResult
extends RefCounted

## 自检运行结果公共数据契约。
##
## 职责：
## 保存一次 run_all 的汇总结果（执行 ID、逐条 SelfCheckResult、结构错误），并提供只读校验、
## 成功判定与深复制；供后续 RuntimeLogger 记录和 RuntimeSnapshot 序列化使用。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check 下自检运行汇总数据层（批次 4A 只实现汇总数据契约）。
## 本批不实现 RuntimeLogger、RuntimeSnapshot、DiagnosticsController，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（StringName、Array[SelfCheckResult]、PackedStringArray）与 SelfCheckResult。
## 不依赖场景树、节点、时间 API、文件系统或玩法对象。
##
## 明确不负责：
## 执行检查、注册定义、去重、日志写入、文件写入、JSON 序列化、UI 显示。
## 这些属于 SelfCheckRunner 与后续组件。
##
## 关键边界：
## - 本类只保存数据并只读校验：构造后字段不再变更、不 push_error、不抛异常、不写文件、不访问场景树。
## - 构造时复制 errors，并深复制每个非 null SelfCheckResult；保留 null 元素由 validate() 报告。
## - passed=false 本身不是数据结构错误，但会让 is_success() 返回 false。
## - validate() 一次返回全部中文错误，不提前返回。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 本次运行的稳定执行 ID，使用稳定 StringName，例如 &"run_20260723_001"。
## 不得为空；用于在日志和快照中定位本次 run_all 调用。
var execution_id: StringName

## 逐条自检结果，按执行顺序排列；允许包含 null 元素，由 validate() 报告。
var results: Array[SelfCheckResult]

## 本次运行的结构错误集合，由 Runner 在 run_all 中收集（例如空 execution_id、无检查项）。
var errors: PackedStringArray


## 构造一次自检运行结果。
## [br]p_execution_id 为执行 ID，不得为空。
## [br]p_results 为逐条结果数组；每个非 null 元素会被深复制，null 元素原样保留由 validate() 报告。
## [br]p_errors 为结构错误数组，传入后会被复制，调用方之后修改原数组不影响本结果。
## [br]本函数仅赋值字段，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
func _init(
		p_execution_id: StringName,
		p_results: Array[SelfCheckResult],
		p_errors: PackedStringArray = PackedStringArray()
) -> void:
	execution_id = p_execution_id
	# 深复制每个非 null SelfCheckResult，保留 null 元素由 validate() 报告；
	# 避免调用方之后修改原结果对象影响本汇总的数据完整性。
	var copied: Array[SelfCheckResult] = []
	copied.resize(p_results.size())
	for index: int in range(p_results.size()):
		var source: SelfCheckResult = p_results[index]
		if source == null:
			copied[index] = null
		else:
			copied[index] = SelfCheckResult.new(
				source.check_id,
				source.passed,
				source.summary,
				source.details,
				source.duration_usec
			)
	results = copied
	# 复制传入错误数组，避免调用方之后修改原 PackedStringArray 影响本汇总。
	errors = p_errors.duplicate()


## 只读校验当前汇总对象的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改字段、不 push_error、不抛异常、不访问场景树/玩法对象。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]null result 安全报错；逐项汇总每个 SelfCheckResult.validate() 的错误。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# execution_id 为空会导致汇总无法定位到本次运行。
	if execution_id == &"":
		problems.append("SelfCheckRunResult：execution_id 为空，必须填写执行 ID。")
	# results 为空属于结构错误：一次运行至少应包含一条结果。
	if results.is_empty():
		problems.append("SelfCheckRunResult：results 为空，至少应包含一条自检结果。")
	# 逐项检查：null 安全报错，非 null 汇总其自身校验错误。
	for index: int in range(results.size()):
		var result: SelfCheckResult = results[index]
		if result == null:
			problems.append("SelfCheckRunResult：results 第 %d 项为 null，运行中不应出现 null 结果。" % [index + 1])
			continue
		# 汇总每条结果自身的字段错误，带索引前缀便于定位。
		for sub_problem: String in result.validate():
			problems.append("SelfCheckRunResult：results 第 %d 项报告：%s" % [index + 1, sub_problem])
	return problems


## 判断本次运行是否整体成功。
## [br]本函数无参数。
## [br]返回 true 当且仅当：errors 为空、validate() 为空、results 非空、每项 result 非 null 且 passed=true。
## [br]本函数无副作用：不修改字段、不 push_error、不抛异常。
## [br]边界条件：passed=false 本身不是数据结构错误，但会让本函数返回 false；
## [br]存在 null 结果或结构错误时本函数返回 false。
func is_success() -> bool:
	# 结构错误或字段校验错误一律视为不成功。
	if not errors.is_empty():
		return false
	# validate() 为空保证 execution_id 非空、results 非空、无 null 结果、各结果字段完整。
	if not validate().is_empty():
		return false
	# 任一项未通过则整体不成功；此处 results 必非空且无 null，已由 validate() 保证。
	for result: SelfCheckResult in results:
		if not result.passed:
			return false
	return true


## 深复制当前汇总，返回新的 SelfCheckRunResult。
## [br]本函数无参数。
## [br]返回新的 SelfCheckRunResult，其 execution_id、errors 与本对象一致，
## [br]每个非 null SelfCheckResult 被深复制，null 元素原样保留。
## [br]本函数无副作用：不修改本对象、不 push_error、不抛异常。
## [br]实现说明：复用 _init 的深复制逻辑，保证 duplicate_result 与构造口径一致。
func duplicate_result() -> SelfCheckRunResult:
	return SelfCheckRunResult.new(execution_id, results, errors)
