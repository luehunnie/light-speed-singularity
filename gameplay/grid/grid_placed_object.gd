@tool
class_name GridPlacedObject
extends Node2D

## 固定格场景对象基础节点（阶段 1 编辑器关卡基础 D1 / 方法 A）。
## 职责：维护固定格场景对象的唯一逻辑位置 cell（Vector2i），并把它单向派生为显示用世界坐标 position。
## 在当前系统中的位置：位于 gameplay/grid，是后续 BasicCrystal、编辑器发射器等固定格场景对象将继承的基础节点；
##   只依赖稳定格坐标换算模块 GridCoordinateRules，不引用任何玩法对象、Registry、Validator、世界查询或核心循环。
## 主要依赖：preload gameplay/grid/grid_coordinate_rules.gd 的静态 cell_to_world()；世界格尺寸唯一来源仍为 GridMetrics。
## 明确不负责（D1 边界）：
##   - 不做 position→cell 反向同步、不监听编辑器拖动、不自动吸附回写、不实现 Undo/Redo、不做 EditorPlugin；
##   - 不使用 _process() 持续写入 position；
##   - 不做占用登记、地图合法性校验、关卡级校验、子视觉状态读写；
##   - 不引用 BasicCrystal、Emitter、Registry、LevelValidator、世界查询、核心循环或库存。
## 关键状态生命周期：cell 是唯一逻辑位置事实；position 是 cell 的显示结果。
##   cell 经 Inspector 或 set_cell() 修改后，setter 立即调用 sync_world_position_from_cell() 写入 position；
##   _ready() 在编辑器与运行时各执行一次幂等同步，保证场景加载后 position 不漂移。
##   反向同步（position→cell）属于方法 B，D1 不实现，但本类保留单向边界以供后续接入。
## 64×64 / Vector2i / R 重置 / 运行期布局权限红线：本类只消费 GridCoordinateRules 的纯换算，
##   不复制 CELL_SIZE 数值，不持有运行期状态机或占用事实，因此与 R 完整重置、运行期布局权限无耦合。


## 唯一逻辑位置（格子坐标）。修改后立即经 cell_to_world 单向同步到世界 position。
## 合法取值：任意 Vector2i，包括负格；D1 不做地图边界或合法性校验（负格不被基础类拒绝）。
## 生命周期：随节点存在；setter 幂等，重复设置同一值结果稳定。
## 调用边界：Inspector 直接编辑或程序调用 set_cell() 均经同一 setter；setter 块内对 cell 赋值直接写后备字段，不递归。
@export var cell: Vector2i = Vector2i.ZERO:
	set(next_cell):
		# Godot 4：setter 块内对同名属性赋值直接写后备字段，不会再触发本 setter，故无递归。
		# 必须在 setter 块内直接写后备字段；若委托给另一方法再赋值 cell 会重新触发 setter 形成递归。
		cell = next_cell
		sync_world_position_from_cell()


## 格坐标纯换算规则唯一来源：preload 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)


func _ready() -> void:
	# 场景加载与运行时初始化时幂等同步：position 始终由 cell 派生，不依赖外部调用顺序。
	# @tool 下编辑器与运行时各触发一次；纯赋值，重复调用结果稳定，不产生递归 setter。
	sync_world_position_from_cell()


## 设置唯一逻辑位置并立即单向同步世界 position。
## [br]next_cell 为目标格子坐标 Vector2i，允许负格；不被本函数做合法性校验。
## [br]无返回值；主要结果体现在 cell 字段与节点 position 上。
## [br]副作用：写入 cell 并经 cell_to_world 改写节点世界 position；不修改子节点、占用表或运行状态。
## [br]失败与边界：本函数不拒绝任何 Vector2i；重复设置同一值结果稳定；不会回写 cell 形成递归。
func set_cell(next_cell: Vector2i) -> void:
	cell = next_cell


## 读取唯一逻辑位置。
## [br]无参数。
## [br]返回当前 cell（Vector2i）；未经任何校验，可能为负格。
## [br]副作用：无。
func get_cell() -> Vector2i:
	return cell


## 由 cell 单向派生并写入世界 position。
## [br]无参数；读取当前 cell，经 GridCoordinateRules.cell_to_world 换算后赋值给 position。
## [br]无返回值；结果体现在节点 position 上。
## [br]副作用：改写节点世界 position；不修改 cell，不形成 cell↔position 循环。
## [br]失败与边界：纯赋值，幂等，重复调用结果稳定；人工改变 position 后可由本函数恢复。
## [br]边界：本函数是 D1 唯一同步方向（cell→position）；反向 position→cell 属于方法 B，D1 不实现。
func sync_world_position_from_cell() -> void:
	# 世界坐标只由 GridCoordinateRules 换算，不复制 64×64 公式，保证格尺寸唯一来源。
	position = _GridCoordinateRules.cell_to_world(cell)


## 返回本对象相对 cell 的占用偏移列表。
## [br]无参数。
## [br]返回 Array[Vector2i]；单格默认返回 [Vector2i.ZERO]；子类可重写以表达多格占用。
## [br]副作用：无；每次返回新数组，调用方修改不影响内部状态。
## [br]失败与边界：D1 不做合法性或重叠校验；偏移语义为"相对 cell 的格子偏移"，不登记到任何 OccupancyRegistry。
func get_occupied_offsets() -> Array[Vector2i]:
	return [Vector2i.ZERO]


## 返回本对象实际占用的绝对格子列表（cell 加各偏移）。
## [br]无参数。
## [br]返回 Array[Vector2i]；单格默认返回 [cell]。
## [br]副作用：无；每次返回新数组。
## [br]失败与边界：D1 不做合法性、重叠或地图边界校验；不登记到 OccupancyRegistry，不参与通关判断。
func get_occupied_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset: Vector2i in get_occupied_offsets():
		cells.append(cell + offset)
	return cells
