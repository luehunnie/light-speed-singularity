class_name DiagnosticSeverity
extends RefCounted

## 诊断日志等级公共数据契约。
##
## 职责：
## 定义运行期诊断日志使用的等级枚举及其只读校验与标签转换，供 DiagnosticLogEntry
## 与后续 RuntimeLogger、RuntimeSnapshot 等诊断组件共用同一套等级口径。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下最底层的等级定义（批次 1A 只实现等级数据契约）。
## 本批不实现日志记录器、文件写入、轮转、快照、自检或控制器，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（int、StringName）；不依赖场景树、节点、玩法状态或文件系统。
##
## 明确不负责：
## 日志条目构造、消息格式化、文件写入、等级过滤策略、控制台输出、UI 显示。
## 这些属于后续批次的 RuntimeLogger 等组件。
##
## 关键边界：
## - Level 是代码契约，枚举值即稳定 ID，不得用 Dictionary 或 Variant 模拟。
## - 本类无实例状态，全部接口为静态函数，无副作用。
## - 未知等级值不得抛异常或 push_error；统一由 is_valid 返回 false、to_label 返回 &"UNKNOWN"。
## - 依据 Diagnostics 红线，本类只参与观察/记录口径定义，不参与玩法决策。


## 诊断日志等级枚举。
## 值即稳定 ID，由低到高表示严重程度递增；不得在本类之外用 Dictionary 重建该口径。
enum Level {
	## 调试等级：仅 Debug 版输出的高频细节信息，Release 版默认关闭。
	DEBUG,
	## 信息等级：常规运行信息，例如启动、关卡加载、脉冲开始等。
	INFO,
	## 警告等级：非致命异常，例如占用残留自检失败、日志轮转删除失败等。
	WARNING,
	## 错误等级：致命或需立即关注的问题，Release 版默认保留。
	ERROR,
}


## 判断给定整数是否为合法 Level 枚举值。
## [br]level 是待校验的整数，应来自 Level 枚举或外部输入。
## [br]返回 true 表示该值落在 DEBUG..ERROR 范围内；返回 false 表示未知或越界值。
## [br]本函数无副作用：不修改入参，不输出错误，不抛异常。
## [br]边界条件：负数、超出枚举上界的值一律返回 false，不抛异常。
static func is_valid(level: int) -> bool:
	return level >= Level.DEBUG and level <= Level.ERROR


## 将给定等级转换为稳定大写标签。
## [br]level 是待转换的整数，应来自 Level 枚举。
## [br]返回值：合法值分别返回 &"DEBUG"、&"INFO"、&"WARNING"、&"ERROR"；未知值返回 &"UNKNOWN"。
## [br]本函数无副作用：不修改入参，不输出错误，不抛异常。
## [br]边界条件：越界值不抛异常，统一返回 &"UNKNOWN"，便于上层在日志中安全降级显示。
static func to_label(level: int) -> StringName:
	match level:
		Level.DEBUG:
			return &"DEBUG"
		Level.INFO:
			return &"INFO"
		Level.WARNING:
			return &"WARNING"
		Level.ERROR:
			return &"ERROR"
		# 未知或越界等级：不抛异常，统一返回 UNKNOWN，保证调用方始终拿到合法 StringName。
		_:
			return &"UNKNOWN"
