@tool
class_name GridPlacedObject
extends Node2D

## 固定格场景对象基础节点（阶段 1 编辑器关卡基础 D3A）。
## 位置契约：position 是唯一持久化的关卡放置事实（关卡局部网格坐标系）；cell 由 position 确定性派生，不再独立序列化。
## 职责：只经 GridCoordinateRules 做 cell↔position 纯换算，保留 .cell / set_cell / get_cell 访问兼容性。
## 边界：不引用玩法对象、Registry、Validator、世界查询或核心循环；不做父链 Transform 校验、地图边界、占用登记或合法性校验；
##   不复制 64×64 公式，不持有运行期状态机；不使用 _ready/_process 自动覆盖 position，不监听 transform，不引入编辑器吸附或 Undo 插件。
## 持久化语义：仅 position 随场景保存；cell 为计算属性，不作为第二份数据写入 .tscn。


## 格坐标纯换算规则唯一来源：preload 引用以避开 Godot MCP 运行期未重建全局 class 缓存的类型解析问题。
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)


## 格子坐标（Vector2i），由 position 确定性派生，非持久化事实。
## getter：position → world_to_cell；setter：cell_to_world → position。保留 .cell 访问兼容性。
## 不使用 @export / 显式后备字段 / 元数据，不序列化到场景；setter 不引用 cell，无递归。
var cell: Vector2i:
	get:
		return _GridCoordinateRules.world_to_cell(position)
	set(next_cell):
		position = _GridCoordinateRules.cell_to_world(next_cell)


## 设置目标格并经计算属性 setter 写入 position。委派给 cell setter，语义与直接赋值 .cell 一致。
func set_cell(next_cell: Vector2i) -> void:
	cell = next_cell


## 读取当前派生格。委派给 cell getter，结果随 position 实时变化。
func get_cell() -> Vector2i:
	return cell


## 将 position 重居中到当前派生格的中心：读取 position 派生的 cell，再回写该格中心世界坐标。
## 用于人工或外部改动 position 后的吸附恢复；只写本节点 position，不改外部状态。
func sync_world_position_from_cell() -> void:
	position = _GridCoordinateRules.cell_to_world(get_cell())


## 相对 cell 的占用偏移；单格默认 [Vector2i.ZERO]，子类可重写表达多格占用。每次返回新数组。
## 方向参数（冻结多格占用接口）：p_orientation 为前向兼容方向槽（int，默认 0=默认方向），
##   不在此建立方向枚举/方向系统；基类不解释方向，单格对象任意方向均只占 [ZERO]，
##   未来多格子类按自身枚举（GDScript 枚举底层即 int）传入并重写本方法。
func get_occupied_offsets(p_orientation: int = 0) -> Array[Vector2i]:
	return [Vector2i.ZERO]


## 实际占用的绝对格子列表（anchor_cell 加各方向偏移）；单格默认 [anchor_cell]。每次返回新数组。
## anchor_cell 由调用方显式传入，p_orientation 原样透传给 get_occupied_offsets；基类不解释方向，
##   单格对象任意方向均只占 [anchor_cell]；不保存 orientation，不新增锚点/位置后备字段，不实现多格占用。
func get_occupied_cells(anchor_cell: Vector2i, p_orientation: int = 0) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset: Vector2i in get_occupied_offsets(p_orientation):
		cells.append(anchor_cell + offset)
	return cells
