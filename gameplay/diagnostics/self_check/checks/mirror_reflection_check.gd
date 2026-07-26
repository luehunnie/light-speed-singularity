class_name MirrorReflectionCheck
extends RefCounted

## 基础单格镜面八方向反射纯函数自检模块（Diagnostics 批次 4B-B1）。
##
## 职责：
## 把原核心闭环原型中的 _run_single_cell_mirror_reflection_self_check() 检查逻辑抽离为独立、
## 无副作用、不访问场景树的纯函数式自检；只通过 SingleCellMirror 的正式静态 API 与
## MirrorOrientation 验证 SLASH / BACKSLASH 各 8 组合法映射，以及 Vector2i.ZERO 和超过单位
## 长度向量的非法返回规则。不复制或重新实现镜面反射公式，不访问真实关卡镜面节点。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；本批只迁移这一项检查逻辑，
## 暂不接入 SelfCheckRunner，核心闭环原型仍以薄包装形式在 Debug 构建中调用本模块 run()。
##
## 主要依赖：
## SingleCellMirror 的静态纯函数 reflect_direction_for_orientation / is_valid_incoming_direction_value
## 与 MirrorOrientation 枚举，以及 SelfCheckResult 数据契约。
## 不依赖场景树、节点、时间 API、文件系统或玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、其他自检项的迁移或
## SelfCheckRunner 接入。本模块只如实报告检查事实，不修改任何玩法状态。
##
## 关键边界：
## - orientation 是运行中镜面方向的唯一事实来源；自检只把目标朝向作为参数传入纯函数，
## [br]不实例化镜面节点、不修改真实镜面、不触发光线传播。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能汇总全部失败。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


# 以 preload 引用 SingleCellMirror 脚本，避开 MCP run_project 不重建全局类型缓存的问题，
# 与核心闭环原型中的引用方式保持一致。
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")


## 执行基础单格镜面八方向反射纯函数自检。
## [br]本函数无参数。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"single_cell_mirror_reflection"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]副作用：无；只调用 SingleCellMirror 的静态纯函数，不创建镜面节点，不修改真实镜面、
## OccupancyRegistry、库存、水晶、RunState 或光路；不访问场景树，不使用 Node，不写文件，
## 不写日志，不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能汇总全部失败。
## [br]边界条件：必须保留原自检覆盖的全部方向和朝向案例（SLASH / BACKSLASH 各 8 组合法映射
## [br]与 4 项非法方向返回规则），不得删减；反射公式由 SingleCellMirror 静态 API 提供，本模块不复制。
static func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()

	var slash_cases: Dictionary[Vector2i, Vector2i] = {
		Vector2i.RIGHT: Vector2i.UP,
		Vector2i.UP: Vector2i.RIGHT,
		Vector2i.LEFT: Vector2i.DOWN,
		Vector2i.DOWN: Vector2i.LEFT,
		Vector2i(1, -1): Vector2i(1, -1),
		Vector2i(-1, 1): Vector2i(-1, 1),
		Vector2i(-1, -1): Vector2i(1, 1),
		Vector2i(1, 1): Vector2i(-1, -1),
	}
	var backslash_cases: Dictionary[Vector2i, Vector2i] = {
		Vector2i.RIGHT: Vector2i.DOWN,
		Vector2i.DOWN: Vector2i.RIGHT,
		Vector2i.LEFT: Vector2i.UP,
		Vector2i.UP: Vector2i.LEFT,
		Vector2i(1, 1): Vector2i(1, 1),
		Vector2i(-1, -1): Vector2i(-1, -1),
		Vector2i(1, -1): Vector2i(-1, 1),
		Vector2i(-1, 1): Vector2i(1, -1),
	}

	for incoming_direction: Vector2i in slash_cases:
		var reflected_direction: Vector2i = _SingleCellMirrorScript.reflect_direction_for_orientation(
			_SingleCellMirrorScript.MirrorOrientation.SLASH,
			incoming_direction
		)
		if reflected_direction != slash_cases[incoming_direction]:
			details.append("SLASH %s 应反射为 %s，实际为 %s。" % [incoming_direction, slash_cases[incoming_direction], reflected_direction])

	for incoming_direction: Vector2i in backslash_cases:
		var reflected_direction: Vector2i = _SingleCellMirrorScript.reflect_direction_for_orientation(
			_SingleCellMirrorScript.MirrorOrientation.BACKSLASH,
			incoming_direction
		)
		if reflected_direction != backslash_cases[incoming_direction]:
			details.append("BACKSLASH %s 应反射为 %s，实际为 %s。" % [incoming_direction, backslash_cases[incoming_direction], reflected_direction])

	if _SingleCellMirrorScript.is_valid_incoming_direction_value(Vector2i.ZERO):
		details.append("Vector2i.ZERO 必须非法，实际被判定为合法。")
	if _SingleCellMirrorScript.reflect_direction_for_orientation(_SingleCellMirrorScript.MirrorOrientation.SLASH, Vector2i.ZERO) != Vector2i.ZERO:
		details.append("零方向反射应安全返回 ZERO，实际非 ZERO。")
	if _SingleCellMirrorScript.is_valid_incoming_direction_value(Vector2i(2, 0)):
		details.append("超过单位长度的方向必须非法，实际被判定为合法。")
	if _SingleCellMirrorScript.reflect_direction_for_orientation(_SingleCellMirrorScript.MirrorOrientation.BACKSLASH, Vector2i(2, 0)) != Vector2i.ZERO:
		details.append("超过单位长度方向反射应安全返回 ZERO，实际非 ZERO。")

	var summary: String = "基础单格镜面八方向反射纯函数自检：SLASH/BACKSLASH 各 8 组合法映射与非法方向返回规则。"
	return SelfCheckResult.new(&"single_cell_mirror_reflection", details.is_empty(), summary, details, 0)
