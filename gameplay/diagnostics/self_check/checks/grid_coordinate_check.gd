class_name GridCoordinateCheck
extends RefCounted

## 网格坐标启动期自检模块（Diagnostics 批次 4B-E3）。
##
## 职责：
## 把原核心闭环原型中的 _run_grid_coordinate_self_check() 检查逻辑抽离为独立、无副作用、
## 不访问场景树的纯函数式自检；持有构造时复制的只读采样快照，逐项验证 cell↔world 往返与
## 相邻格中心距，不读取或修改真实关卡状态、core_loop 私有字段、Crystal、Node 或 TileMapLayer。
##
## 在当前系统中的位置：
## gameplay/diagnostics/self_check/checks 下自检实现层；由核心闭环原型以薄包装形式采集真实格子
## 构造本实例，再包装为 SelfCheckCallable 交由 SelfCheckRunner 执行，保持原 Debug 硬断言失败语义。
## 与既有 static run() 检查不同，本检查持有只读采样快照，因此采用无参实例方法 run()，
## 通过 Callable(instance, "run") 接入 Runner，不使用 Callable.bind、lambda 或捕获。
##
## 主要依赖：
## GridCoordinateRules（格↔世界纯换算规则，单一来源）与 GridMetrics（CELL_SIZE 唯一来源），
## 以及 SelfCheckResult 数据契约。不依赖场景树、节点、时间 API、文件系统或真实玩法对象。
##
## 明确不负责：
## 业务修复、状态自愈、日志写入、快照序列化、控制台输出、UI 显示、地图边界合法性校验、
## 放置合法性校验、TileMapLayer 读取。本模块只如实报告坐标换算的检查事实，不修改任何玩法状态，
## 不复制 cell/world 换算公式，不负责修复任何坐标或关卡状态。
##
## 关键边界：
## - _init 只复制 sample_cells，不保存调用方原数组引用，保留顺序与重复元素，不排序不去重；
##   构造完成后无公开修改接口，_sample_cells 在 run() 中只读。
## - run() 只调用 GridCoordinateRules 与 GridMetrics 的公开纯函数；不访问 core_loop、节点树、
##   TileMapLayer，不检查地图边界合法性，不修改 _sample_cells 或任何外部状态。
## - 不使用 assert、push_error 或 push_warning；全部失败条件写入 details。
## - 不因首个失败提前停止，尽可能汇总全部检查失败；采样数组为空时记入稳定中文失败详情。
## - duration_usec 固定为 0：本批不测量耗时，耗时由后续 Runner 层统一采集。
## - 不使用文件、系统时间、随机数、信号或日志。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


# 以 preload 引用脚本而非依赖全局 class_name 缓存，保证运行期可直接解析；
# 与核心闭环原型中的引用方式保持一致，避开 MCP run_project 不重建全局类型缓存的问题。
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _GridMetrics: GDScript = preload(
	"res://gameplay/grid/grid_metrics.gd"
)

# 横向相邻格中心距测试锚点：cell_to_world((1,0)).x - cell_to_world((0,0)).x 应等于 CELL_SIZE。
# 与原 _run_grid_coordinate_self_check 中的固定锚点一致，不取自采样数组。
const _HORIZONTAL_ANCHOR_A: Vector2i = Vector2i(0, 0)
const _HORIZONTAL_ANCHOR_B: Vector2i = Vector2i(1, 0)
# 纵向相邻格中心距测试锚点：cell_to_world((0,1)).y - cell_to_world((0,0)).y 应等于 CELL_SIZE。
# 与原 _run_grid_coordinate_self_check 中的固定锚点一致，不取自采样数组。
const _VERTICAL_ANCHOR_A: Vector2i = Vector2i(0, 0)
const _VERTICAL_ANCHOR_B: Vector2i = Vector2i(0, 1)

# 构造时复制的只读采样快照；run() 只读访问，不修改。
var _sample_cells: Array[Vector2i] = []


## 构造一个持有只读采样快照的网格坐标自检实例。
## [br]sample_cells 为采样格子数组，本函数会复制其内容，不保留调用方原数组引用。
## [br]保留元素顺序与重复元素，不排序、不去重、不修改输入数组。
## [br]不保存 core_loop、Node、Crystal 或其他玩法对象引用。
## [br]构造完成后无公开修改接口；_sample_cells 在后续 run() 中只读。
## [br]边界条件：空数组也合法构造，由 run() 记入失败详情；本函数不做校验也不输出错误。
func _init(sample_cells: Array[Vector2i]) -> void:
	# 复制输入数组，避免调用方之后修改原数组影响本实例的只读快照；保留顺序与重复元素。
	_sample_cells = sample_cells.duplicate()


## 执行网格坐标规则自检。
## [br]本函数无参数，只读、无业务修复、不执行任何玩法事务、不修改 _sample_cells 或任何外部状态。
## [br]返回一个 SelfCheckResult：
## [br]  - check_id = &"grid_coordinate"；
## [br]  - passed = details 是否为空；
## [br]  - summary 为稳定中文摘要；
## [br]  - details 收录全部失败条件，每项去除首尾空白后非空；
## [br]  - duration_usec = 0。
## [br]副作用：只调用 GridCoordinateRules 与 GridMetrics 的公开纯函数；
## [br]不访问 core_loop、节点树、TileMapLayer，不检查地图边界合法性，不写文件、不写日志、
## [br]不使用 assert、push_error 或 push_warning，不自动修复任何状态。
## [br]失败语义：任一检查条件不满足即记入 details；不因首个失败提前停止，尽可能汇总全部失败；
## [br]采样数组为空时加入稳定中文失败详情；相邻格中心距测试使用固定锚点格，不取自采样数组。
## [br]边界条件：不删减原自检覆盖的任何测试案例，也不增加新规则；
## [br]不复制 cell/world 换算公式，只通过 GridCoordinateRules 正式接口验证。
func run() -> SelfCheckResult:
	var details: PackedStringArray = PackedStringArray()

	# 采样数组为空属于无法验证：记入稳定中文失败详情，不提前返回，继续执行相邻格中心距测试。
	if _sample_cells.is_empty():
		details.append("网格坐标自检：采样数组为空，无法验证 cell↔world 往返。")

	# 逐项验证每个采样格的 cell→world→cell 往返；使用 GridCoordinateRules 正式接口，不复制换算公式。
	for cell: Vector2i in _sample_cells:
		var roundtrip: Vector2i = _GridCoordinateRules.world_to_cell(_GridCoordinateRules.cell_to_world(cell))
		if roundtrip != cell:
			details.append(_format_roundtrip_failure(cell, roundtrip))

	# 横向相邻格中心距：cell_to_world((1,0)) 与 cell_to_world((0,0)) 的 x 差应等于 CELL_SIZE。
	var horizontal_spacing: float = _GridCoordinateRules.cell_to_world(_HORIZONTAL_ANCHOR_B).x - _GridCoordinateRules.cell_to_world(_HORIZONTAL_ANCHOR_A).x
	if horizontal_spacing != float(_GridMetrics.CELL_SIZE):
		details.append(_format_spacing_failure("横向", _GridMetrics.CELL_SIZE, horizontal_spacing))

	# 纵向相邻格中心距：cell_to_world((0,1)) 与 cell_to_world((0,0)) 的 y 差应等于 CELL_SIZE。
	var vertical_spacing: float = _GridCoordinateRules.cell_to_world(_VERTICAL_ANCHOR_B).y - _GridCoordinateRules.cell_to_world(_VERTICAL_ANCHOR_A).y
	if vertical_spacing != float(_GridMetrics.CELL_SIZE):
		details.append(_format_spacing_failure("纵向", _GridMetrics.CELL_SIZE, vertical_spacing))

	var summary: String = "网格坐标规则自检：cell↔world 往返与相邻格中心距。"
	return SelfCheckResult.new(&"grid_coordinate", details.is_empty(), summary, details, 0)


## 格式化一次 cell↔world 往返失败详情。
## [br]输入：cell 为被验证的采样格；actual 为 world_to_cell(cell_to_world(cell)) 的实际回程结果。
## [br]返回：稳定中文失败描述字符串，包含 cell 与 actual。
## [br]边界：仅做字符串格式化，不包含坐标公式，不修改输入，不提前返回。
static func _format_roundtrip_failure(cell: Vector2i, actual: Vector2i) -> String:
	return "网格坐标自检：cell_to_world/world_to_cell 必须互逆，cell=%s 实际回程=%s。" % [_format_vector2i(cell), _format_vector2i(actual)]


## 格式化一次相邻格中心距失败详情。
## [br]输入：axis 为方向描述（"横向"或"纵向"）；expected 为期望距离（CELL_SIZE）；actual 为实际距离。
## [br]返回：稳定中文失败描述字符串，包含 axis、expected 与 actual。
## [br]边界：仅做字符串格式化，不包含坐标公式，不修改输入，不提前返回。
static func _format_spacing_failure(axis: String, expected: int, actual: float) -> String:
	return "网格坐标自检：%s相邻格中心间距应为 %d 实际为 %s。" % [axis, expected, _format_float(actual)]


## 格式化 Vector2i 为稳定字符串，供失败详情使用。
## [br]输入：value 为待格式化的 Vector2i。
## [br]返回：形如 "(x, y)" 的字符串。
## [br]边界：仅做字符串格式化，不修改输入。
static func _format_vector2i(value: Vector2i) -> String:
	return "(%d, %d)" % [value.x, value.y]


## 格式化 float 为稳定字符串，供失败详情使用。
## [br]输入：value 为待格式化的浮点数。
## [br]返回：去尾零的字符串表示。
## [br]边界：仅做字符串格式化，不修改输入。
static func _format_float(value: float) -> String:
	return String.num(value)
