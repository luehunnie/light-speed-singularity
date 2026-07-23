class_name SelfCheckRunner
extends RefCounted

## 自检运行协调器公共数据契约。
##
## 职责：
## 注册自检定义、按 check_id 去重、按注册顺序调用 callback 并汇总为 SelfCheckRunResult；
## 提供 SelfCheckRunner 与外部世界之间的最小强类型执行边界。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check 下自检协调层（批次 4A 只实现协调入口与执行边界）。
## 本批不迁移核心循环中的真实自检，不实现 RuntimeLogger、RuntimeSnapshot、DiagnosticsController，
## 也不接入核心循环、场景树或 Autoload。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（Array[SelfCheckCallable]、StringName、Variant、PackedStringArray）
## 与 SelfCheckCallable、SelfCheckResult、SelfCheckRunResult。
## 不依赖场景树、节点、时间 API、文件系统或玩法对象。
##
## 明确不负责：
## 真实自检实现（占用表、网格坐标、镜面反射、状态转换、移动次数、库存一致性）、
## 日志写入、文件写入、JSON 序列化、UI 显示、核心循环接线。
## 这些属于后续批次与具体回调。
##
## 关键边界：
## - Runner 只验证 Callable 有效性和返回值类型，不保证回调内部不产生致命脚本错误。
## - GDScript 不能可靠捕获回调内部的致命脚本错误；回调内部必须自行保证不产生致命脚本错误。
## - 不得声称 Runner 能捕获所有运行时异常。
## - run_all 不写文件、不写 RuntimeLogger、不访问场景树、不修改任何玩法状态。
## - 本批不自行测量执行耗时，不调用 Time.get_ticks_usec、系统时间或随机数；
## [br]SelfCheckResult.duration_usec 由具体回调主动提供。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取或修改业务私有字段。


## 已注册的自检定义列表，按注册顺序保存定义副本。
var _checks: Array[SelfCheckCallable] = []


## 注册一条自检定义。
## [br]definition 为待注册的 SelfCheckCallable，不得为 null。
## [br]返回 PackedStringArray，包含全部拒绝原因（中文）；注册成功时返回空数组。
## [br]副作用：注册成功时会向 _checks 追加 definition.duplicate_definition() 的副本。
## [br]失败条件：definition 为 null、定义自身校验失败、check_id 与已注册项重复。
## [br]边界条件：不调用 callback、不修改输入 definition、不抛异常、不访问场景树/玩法状态。
func register_check(definition: SelfCheckCallable) -> PackedStringArray:
	var problems: PackedStringArray = []
	# null 定义属于非法输入，单独报错避免后续访问空对象。
	if definition == null:
		problems.append("SelfCheckRunner：register_check 收到 null 定义，必须传入 SelfCheckCallable。")
		return problems
	# 先汇总定义自身校验错误，不提前返回。
	for problem: String in definition.validate():
		problems.append("SelfCheckRunner：register_check 定义校验失败：%s" % [problem])
	# 重复 check_id 拒绝，保证 Runner 内 ID 唯一。
	for existing: SelfCheckCallable in _checks:
		if existing.check_id == definition.check_id:
			problems.append("SelfCheckRunner：check_id「%s」已注册，不得重复注册同一自检项。" % [String(definition.check_id)])
			break
	# 存在任意拒绝原因则不保存，原样返回全部问题。
	if not problems.is_empty():
		return problems
	# 保存定义副本，避免调用方之后修改原定义影响已注册项。
	_checks.append(definition.duplicate_definition())
	return problems


## 判断给定 check_id 是否已注册。
## [br]check_id 为待查询的稳定 ID。
## [br]返回 true 表示已注册同名 check_id；返回 false 表示未注册。
## [br]本函数无副作用：不修改 _checks、不 push_error、不抛异常、不访问场景树/玩法状态。
func has_check(check_id: StringName) -> bool:
	for existing: SelfCheckCallable in _checks:
		if existing.check_id == check_id:
			return true
	return false


## 返回已注册自检定义数量。
## [br]本函数无参数。
## [br]返回 _checks 的元素个数。
## [br]本函数无副作用：不修改 _checks、不 push_error、不抛异常。
func size() -> int:
	return _checks.size()


## 判断是否未注册任何自检定义。
## [br]本函数无参数。
## [br]返回 true 表示当前没有已注册定义。
## [br]本函数无副作用：不修改 _checks、不 push_error、不抛异常。
func is_empty() -> bool:
	return _checks.is_empty()


## 清空全部已注册自检定义。
## [br]本函数无参数。
## [br]无返回值。
## [br]副作用：清空 _checks，释放全部已注册定义副本。
## [br]边界条件：不调用任何 callback、不 push_error、不抛异常、不访问场景树/玩法状态。
func clear() -> void:
	_checks.clear()


## 按注册顺序执行全部自检并汇总结果。
## [br]execution_id 为本次运行的稳定执行 ID，不得为空。
## [br]返回 SelfCheckRunResult，包含逐条结果与结构错误。
## [br]副作用：调用各定义的 callback；不写文件、不写 RuntimeLogger、不修改 _checks、不访问场景树、不修改玩法状态。
## [br]失败条件：execution_id 为空时返回仅含结构错误的结果；无检查项时返回仅含结构错误的结果。
## [br]执行规则：
## [br]1. 按注册顺序调用 callback；
## [br]2. callback 预期返回 SelfCheckResult；返回 null 时生成失败 SelfCheckResult；
## [br]3. 返回类型错误时生成失败 SelfCheckResult；
## [br]4. 每项最终结果复制后保存；
## [br]5. passed=false 不阻止后续检查；
## [br]6. 一个无效返回不阻止后续检查。
## [br]关键边界：Runner 只验证 Callable 有效性和返回值类型；
## [br]GDScript 不能可靠捕获回调内部致命脚本错误，回调必须自行保证不产生致命脚本错误；
## [br]不得声称 Runner 能捕获所有运行时异常。
func run_all(execution_id: StringName) -> SelfCheckRunResult:
	var errors: PackedStringArray = []
	# execution_id 为空属于结构错误：返回仅含错误的结果，不执行任何检查。
	if execution_id == &"":
		errors.append("SelfCheckRunner：run_all 收到空 execution_id，必须填写执行 ID。")
		return SelfCheckRunResult.new(execution_id, [], errors)
	# 无检查项属于结构错误：返回仅含错误的结果，避免空运行被误判为成功。
	if _checks.is_empty():
		errors.append("SelfCheckRunner：run_all 没有已注册的检查项，无法执行运行。")
		return SelfCheckRunResult.new(execution_id, [], errors)
	# 按注册顺序逐项执行；Variant 仅用于接收 callback 返回值的局部执行边界，不向外泄漏。
	var collected: Array[SelfCheckResult] = []
	collected.resize(_checks.size())
	for index: int in range(_checks.size()):
		var definition: SelfCheckCallable = _checks[index]
		# 执行边界：用 Variant 接收回调返回值，随后只做类型判定与归并，不保留 Variant。
		var raw_return: Variant = definition.callback.call()
		var produced: SelfCheckResult = null
		# 返回 null 视为执行失败：生成标注来源的失败结果，不阻止后续检查。
		if raw_return == null:
			produced = SelfCheckResult.new(
				definition.check_id,
				false,
				"自检回调返回 null，视为执行失败。",
				PackedStringArray(),
				0
			)
		# 返回类型错误视为执行失败：生成标注来源的失败结果，不阻止后续检查。
		elif not (raw_return is SelfCheckResult):
			produced = SelfCheckResult.new(
				definition.check_id,
				false,
				"自检回调返回类型错误，预期 SelfCheckResult。",
				PackedStringArray(),
				0
			)
		# 类型正确：原样接收，由下方复制后保存。
		else:
			produced = raw_return
		# 复制后保存，避免回调内部缓存被后续修改影响汇总完整性。
		collected[index] = SelfCheckResult.new(
			produced.check_id,
			produced.passed,
			produced.summary,
			produced.details,
			produced.duration_usec
		)
	return SelfCheckRunResult.new(execution_id, collected, errors)
