class_name GridCoordinateRules
extends RefCounted

## 网格坐标纯换算规则共享模块（Diagnostics 批次 4B-E2）。
## 职责：集中保存核心闭环原型在世界逻辑格坐标 Vector2i 与世界坐标 Vector2 之间的纯函数换算规则，
## 供关卡控制器、世界机关视觉脚本和现有网格坐标启动自检通过 preload() + static 调用复用，
## 避免坐标公式在 core_loop_prototype.gd 与共享自检之间重复维护形成第二套换算事实来源。
## 位置：位于 gameplay/grid 下，与 GridMetrics 同目录；本模块只读取 GridMetrics 的正式尺度常量，
## 不复制 CELL_SIZE 数值，是 32→64 世界坐标迁移后唯一的"格↔世界纯换算规则"事实来源。
## 依赖：只 preload gameplay/grid/grid_metrics.gd；不引用 CoreLoopPrototype、PlaceableToken、
## SingleCellMirror、OccupancyRegistry 或 TileMapLayer，因此不会形成循环依赖。
## 不负责：地图边界校验、格子合法性校验、放置/拖拽/光传播事务、场景树读取、节点 position 写入、
## 文件、时间、随机数或任何运行期状态修改；本模块只做无副作用的纯坐标换算。
## 边界条件：原点隐式为世界坐标 Vector2.ZERO，格中心偏移为半格（CELL_SIZE / 2.0），
## world_to_cell 使用 floori 向下取整，负坐标向负无穷方向取整；正式 TileMapLayer 不参与本模块的逻辑换算，
## 后续若由 map_to_local/local_to_map 接管，本模块的纯换算规则仍可作为无场景依赖的对照基准保留。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


## 正式尺度常量唯一来源：preload 共享常量模块，避免 64 世界格尺寸分散手写；不加 class_name 以避开 MCP 全局类型缓存问题。
const _GridMetrics: GDScript = preload(
	"res://gameplay/grid/grid_metrics.gd"
)


## 将格子坐标转换为对应世界逻辑格中心点的世界坐标。
## [br]cell 是要转换的 Vector2i 逻辑格坐标，不被本函数修改。
## [br]返回该格中心点的世界坐标 Vector2；原点隐式为世界坐标 Vector2.ZERO，中心偏移为半格（CELL_SIZE / 2.0），
## 即 cell_to_world(Vector2i.ZERO) 在 CELL_SIZE=64 时返回 Vector2(32, 32)。
## [br]副作用：无；纯函数，不读实例字段、不写场景树、不读写文件、不使用时间或随机数。
## [br]失败与边界：本函数不检查 cell 是否在 map_bounds 内，也不对结果做 clamp/round/snap；
## 不依赖 TileMapLayer.map_to_local()，逻辑结果不受窗口分辨率或 CanvasLayer UI 尺寸影响。
static func cell_to_world(cell: Vector2i) -> Vector2:
	# 格中心 = 格原点 + 半格偏移；CELL_SIZE=64 时半格为 32，即 cell_to_world(Vector2i.ZERO) == Vector2(32, 32)。
	# 尺度常量只从 GridMetrics 读取，不复制 CELL_SIZE 数值，保证 64 世界格尺寸唯一来源。
	return Vector2(
		cell.x * _GridMetrics.CELL_SIZE + _GridMetrics.CELL_SIZE / 2.0,
		cell.y * _GridMetrics.CELL_SIZE + _GridMetrics.CELL_SIZE / 2.0
	)


## 将世界坐标转换为包含该世界点的逻辑格坐标。
## [br]world_position 是鼠标或节点的世界坐标，不被本函数修改。
## [br]返回包含该世界点的 Vector2i 逻辑格坐标；使用 floori 向下取整，
## 即 world_to_cell(Vector2(63.999, 63.999)) == Vector2i.ZERO，world_to_cell(Vector2(64, 64)) == Vector2i(1, 1)。
## [br]副作用：无；纯函数，不读实例字段、不写场景树、不读写文件、不使用时间或随机数。
## [br]失败与边界：负坐标向负无穷方向取整，即 world_to_cell(Vector2(-0.001, -0.001)) == Vector2i(-1, -1)；
## 本函数不检查结果格子是否合法，地图合法性另由放置检查处理；不依赖 TileMapLayer.local_to_map()，
## 不对输入做 clamp/round/snap，逻辑结果不受窗口分辨率或 CanvasLayer UI 尺寸影响。
static func world_to_cell(world_position: Vector2) -> Vector2i:
	# 坐标换算统一在此共享模块完成，避免机关或 UI 产生第二套换算规则；负坐标由 floori 向下取整。
	return Vector2i(
		floori(world_position.x / float(_GridMetrics.CELL_SIZE)),
		floori(world_position.y / float(_GridMetrics.CELL_SIZE))
	)
