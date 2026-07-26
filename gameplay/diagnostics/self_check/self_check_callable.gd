class_name SelfCheckCallable
extends RefCounted

## 自检可调用对象公共数据契约。
##
## 职责：
## 保存一条自检的定义（稳定 ID、显示名、回调），并提供只读校验与定义复制；
## 供 SelfCheckRunner 注册、去重和按顺序调用使用。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check 下自检定义数据层（批次 4A 只实现定义契约与执行边界）。
## 本批不实现 SelfCheckRunner 的真实自检迁移、RuntimeLogger、RuntimeSnapshot、DiagnosticsController，
## 也不接入核心循环。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（StringName、String、Callable、PackedStringArray）。
## 不依赖场景树、节点、Object、玩法状态、时间 API 或文件系统。
##
## 明确不负责：
## 实际执行检查、生成 SelfCheckResult、聚合多条结果、日志写入、文件写入、UI 显示。
## 这些属于 SelfCheckRunner 等后续组件。
##
## 关键边界：
## - 本类只保存定义并只读校验：构造后字段不再变更、不 push_error、不抛异常、不写文件、不访问场景树。
## - validate() 不实际调用 callback，只验证其有效性与可调用性。
## - 本类不得额外保存 Node、Object 或玩法状态字段；Callable 是执行边界需要的 Godot 类型，仅此一项。
## - validate() 一次返回全部中文错误，不提前返回。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 自检项的稳定 ID，使用稳定 StringName，例如 &"occupancy_double_index"。
## 不得为空；用于在 SelfCheckRunner 中去重和定位检查来源。
var check_id: StringName

## 自检项的显示名，去除首尾空白后必须非空；用于在日志和 UI 中人类可读地描述检查。
var display_name: String

## 自检回调，签名应为 () -> SelfCheckResult。
## 由 SelfCheckRunner 在 run_all 中按注册顺序调用；本类不调用它，也不保存其返回值。
var callback: Callable


## 构造一条自检定义。
## [br]p_check_id 为自检项稳定 ID，不得为空。
## [br]p_display_name 为显示名，strip_edges 后不得为空。
## [br]p_callback 为自检回调，必须有效且可调用；本函数不调用它。
## [br]本函数仅赋值字段，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
func _init(
		p_check_id: StringName,
		p_display_name: String,
		p_callback: Callable
) -> void:
	check_id = p_check_id
	display_name = p_display_name
	callback = p_callback


## 只读校验当前定义对象的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改字段、不调用 callback、不 push_error、不抛异常、不访问场景树/玩法对象。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]callback 仅验证有效性与可调用性（is_valid 同时覆盖这两点），不实际调用。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# check_id 为空会导致定义无法在 Runner 中去重和定位。
	if check_id == &"":
		problems.append("SelfCheckCallable：check_id 为空，必须填写自检项稳定 ID。")
	# 显示名仅含空白属于无效描述：用 strip_edges 判定，不修改原 display_name 字段。
	if display_name.strip_edges() == "":
		problems.append("SelfCheckCallable：display_name 去除首尾空白后为空，必须填写显示名。")
	# callback 无效属于不可执行定义：is_valid 同时判断是否绑定了可调用的目标对象与方法，
	# 即同时覆盖「有效」与「可以调用」两项要求；此处不实际调用 callback。
	if not callback.is_valid():
		problems.append("SelfCheckCallable：callback 无效或不可调用，必须绑定可调用的目标对象与方法。")
	return problems


## 深复制当前定义，返回新的 SelfCheckCallable。
## [br]本函数无参数。
## [br]返回新的 SelfCheckCallable，其 check_id、display_name 与本对象一致，callback 共享同一绑定。
## [br]说明：Callable 是 Godot 的引用型值，复制定义时不重建其绑定，仅复制定义容器；
## [br]Runner 通过本函数保存副本，避免调用方之后修改原定义影响已注册项。
## [br]本函数无副作用：不修改本对象、不调用 callback、不 push_error、不抛异常。
func duplicate_definition() -> SelfCheckCallable:
	return SelfCheckCallable.new(check_id, display_name, callback)
