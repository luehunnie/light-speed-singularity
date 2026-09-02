@tool
extends GridPlacedObject

## D-04 正式多格墙体作者对象（三格横墙 / 三格竖墙 / 三格L墙；非机关，不进光交互契约）。
## 职责：以单节点承载三格墙体的结构事实 structure（横/竖/L，场景内固定声明）与 L 专用
##   四旋向事实 corner_orientation（Inspector "L墙旋向" 导出属性，横/竖忽略），
##   footprint 经 get_occupied_offsets 整体展开（单身份、整体选中/拖动/删除、原子占用），
##   视觉由三枚 64×64 官方素材子节点自动组成（直墙/外角/内角按 D-03 冻结几何约定）。
## 内容分类：GridPlacedObject 派生（非 PlaceableToken）——预置机关收编器静默跳过、
##   光交互分发永不调用；运行期阻挡唯一入口是墙格快照（collect_wall_cells → LevelTileLayerSnapshot）。
## 组成约定（D-03 冻结）：横=整条 straight_up；竖=整条 straight_left；L=拐角外角
##   （ES→lu / SW→ru / WN→rd / NE→ld）+ 两臂各自轴向直墙（横臂 straight_up、竖臂 straight_left）。
## Typed Configuration：apply_configuration 支持 "structure" 与 "corner_orientation" 两个 Stable Field。
## 不负责：单格样式墙（wall_block.gd）、占用登记、放置合法性、TileMap WallLayer（兼容旧墙）、光传播。
## 类型约束：调用方一律通过 preload() 引用，避开全局 class_name 缓存问题。


## 多格墙体结构（场景内固定声明：h/v/l 三个 .tscn 分别实例化同一脚本并写定 structure）。
enum Structure {
	STRAIGHT_H,
	STRAIGHT_V,
	CORNER_L,
}

## L 墙四旋向（两字母 = 两臂自拐角延伸方向；值序冻结，横/竖结构不解释本字段）。
enum CornerOrientation {
	ARMS_ES,
	ARMS_SW,
	ARMS_WN,
	ARMS_NE,
}


## 正式 Stable Field ID（内容 Schema 身份）。
const FIELD_STRUCTURE: StringName = &"structure"
const FIELD_CORNER_ORIENTATION: StringName = &"corner_orientation"

const _WallStyleCatalog: GDScript = preload(
	"res://gameplay/content/wall/wall_style_catalog.gd"
)
const _GridMetrics: GDScript = preload("res://gameplay/grid/grid_metrics.gd")
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)


## 墙体结构（场景写定事实；Inspector 展示但语义上由所选 Palette 条目决定）。
@export_group("墙体结构")
@export var structure: Structure = Structure.STRAIGHT_H

## L 墙旋向（仅 CORNER_L 解释；变化即时重组三段贴图与占格）。
@export var corner_orientation: CornerOrientation = CornerOrientation.ARMS_ES : set = set_corner_orientation

## 三段贴图子节点（场景固定三个 WallSeg；位置与贴图由结构事实驱动）。
## [br]以 helper 解析而非数组字面量直赋：无类型字面量向 typed Array 成员直赋在 4.6 会静默落空数组。
@onready var _segments: Array[Sprite2D] = _resolve_segments()


## 解析场景固定三段子节点（WallSeg0/1/2）；$ 返回 Node，按实际类型安全入 typed 数组。
func _resolve_segments() -> Array[Sprite2D]:
	var segments: Array[Sprite2D] = []
	for segment: Sprite2D in [$WallSeg0, $WallSeg1, $WallSeg2]:
		segments.append(segment)
	return segments


## 初始化三段视觉。
## [br]副作用：按当前结构事实写入三段位置与贴图；不改占用或运行期状态。
func _ready() -> void:
	_refresh_visual()


## 设置 L 墙旋向（Inspector / 测试配置入口）。
## [br]new_orientation 是目标 CornerOrientation。
## [br]无返回值；副作用是写入 corner_orientation 并刷新三段视觉。
## [br]越界值 push_error 并保持原值；未 ready 时刷新安全跳过（_ready 补刷）。
func set_corner_orientation(new_orientation: CornerOrientation) -> void:
	if new_orientation < 0 or new_orientation > 3:
		push_error("WallStructure: 非法 L 墙旋向：%d" % [new_orientation])
		return
	corner_orientation = new_orientation
	_refresh_visual()


## C-08 多格 footprint 契约（覆写 GridPlacedObject）：按结构事实展开锚格相对偏移。
## [br]横 [(-1,0),(0,0),(1,0)]；竖 [(0,-1),(0,0),(0,1)]；L 拐角 (0,0) + 两臂（随旋向）。
## [br]无副作用；不写占用表、不改 position；偏移列表无重复项。
func get_occupied_offsets(_p_orientation: int = 0) -> Array[Vector2i]:
	match structure:
		Structure.STRAIGHT_H:
			return [Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)]
		Structure.STRAIGHT_V:
			return [Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)]
		Structure.CORNER_L:
			var offsets: Array[Vector2i] = [Vector2i.ZERO]
			offsets.append_array(_corner_arm_offsets(corner_orientation))
			return offsets
		_:
			return [Vector2i.ZERO]


## 本对象绝对占用格（锚格 + 全部偏移）；供墙格快照采集（get_wall_cells 契约）。
## [br]无副作用；移动节点（position 变化）后占格整体随之平移（原子语义）。
func get_wall_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset: Vector2i in get_occupied_offsets():
		cells.append(cell + offset)
	return cells


## 正式 Typed Configuration 应用：解释 "structure" / "corner_orientation" 枚举整数字段。
## [br]未知字段或缺字段返回 false 且结构不变；越界值拒绝并保持原值。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var field_ids := configuration.get_field_ids()
	if field_ids.is_empty():
		return true
	for field_id: StringName in field_ids:
		var value: Variant = configuration.get_value(field_id)
		if field_id == FIELD_STRUCTURE:
			if not (value is int) or not _apply_int_field(value, 0, 2, "structure"):
				return false
		elif field_id == FIELD_CORNER_ORIENTATION:
			if not (value is int) or not _apply_int_field(value, 0, 3, "corner_orientation"):
				return false
		else:
			push_error("WallStructure: Typed 配置含未知字段 %s，拒绝应用。" % [field_id])
			return false
	return true


## 按当前结构事实刷新三段视觉：每段 = 偏移像素位置 + 冻结组成约定解析的 64×64 贴图。
## [br]边界条件：未 ready 时直接返回；段节点缺失时跳过对应段（场景契约破损由场景测试捕获）。
func _refresh_visual() -> void:
	if not is_node_ready():
		return
	var segment_specs := _segment_specs()
	for i: int in _segments.size():
		if i >= segment_specs.size() or _segments[i] == null:
			continue
		_segments[i].position = Vector2(segment_specs[i]["offset"]) * _GridMetrics.CELL_SIZE
		_segments[i].texture = load(segment_specs[i]["texture_path"])


## Typed 配置整数经既有 setter 应用（复用越界拒绝与视觉刷新路径）。
func _apply_int_field(value: int, min_value: int, max_value: int, field_name: String) -> bool:
	if value < min_value or value > max_value:
		push_error("WallStructure: Typed 配置 %s 越界：%d。" % [field_name, value])
		return false
	if field_name == "structure":
		structure = value as Structure
	else:
		set_corner_orientation(value as CornerOrientation)
	return true


## 按结构事实产出三段规格（offset: Vector2i 格偏移；texture_path: 冻结素材路径）。
## [br]组成约定为 D-03 冻结口径：横全 straight_up、竖全 straight_left、L=外角拐角 + 两轴向直臂。
func _segment_specs() -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	match structure:
		Structure.STRAIGHT_H:
			for offset: Vector2i in [Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)]:
				specs.append({"offset": offset, "texture_path": _style_path("straight_up")})
		Structure.STRAIGHT_V:
			for offset: Vector2i in [Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)]:
				specs.append({"offset": offset, "texture_path": _style_path("straight_left")})
		Structure.CORNER_L:
			var arms := _corner_arm_offsets(corner_orientation)
			specs.append({"offset": Vector2i.ZERO, "texture_path": _style_path(_corner_style())})
			for arm: Vector2i in arms:
				specs.append({"offset": arm, "texture_path": _style_path(_arm_style(arm))})
	return specs


## L 墙两臂相对拐角的格偏移（随旋向；ES 右+下 / SW 左+下 / WN 左+上 / NE 右+上）。
static func _corner_arm_offsets(orientation: CornerOrientation) -> Array[Vector2i]:
	match orientation:
		CornerOrientation.ARMS_ES:
			return [Vector2i(1, 0), Vector2i(0, 1)]
		CornerOrientation.ARMS_SW:
			return [Vector2i(-1, 0), Vector2i(0, 1)]
		CornerOrientation.ARMS_WN:
			return [Vector2i(-1, 0), Vector2i(0, -1)]
		CornerOrientation.ARMS_NE:
			return [Vector2i(1, 0), Vector2i(0, -1)]
		_:
			return [Vector2i(1, 0), Vector2i(0, 1)]


## L 拐角外角样式 token（D-03 冻结映射：ES→lu / SW→ru / WN→rd / NE→ld）。
func _corner_style() -> String:
	match corner_orientation:
		CornerOrientation.ARMS_ES:
			return "large_bend_lu"
		CornerOrientation.ARMS_SW:
			return "large_bend_ru"
		CornerOrientation.ARMS_WN:
			return "large_bend_rd"
		CornerOrientation.ARMS_NE:
			return "large_bend_ld"
		_:
			return "large_bend_lu"


## L 两臂轴向直墙 token（横臂=上边直墙、竖臂=左边直墙；与 D-03 _arm_style 一致）。
static func _arm_style(arm_offset: Vector2i) -> String:
	return "straight_up" if arm_offset.x != 0 else "straight_left"


## 样式 token → 冻结素材路径（未登记返回空串）。
static func _style_path(token: String) -> String:
	var index: int = _WallStyleCatalog.index_of(token)
	return _WallStyleCatalog.texture_path_at(index)
