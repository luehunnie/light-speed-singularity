@tool
extends GridPlacedObject

## D-04 正式单格墙体作者对象（12 种官方样式；非机关，不进光交互契约）。
## 职责：持有唯一墙体样式事实 wall_style（12 样式枚举，Inspector "墙体样式" 导出属性，
##   类似 LightBarrier orientation 的作者入口），样式变化即时换贴图；保存/重载随场景持久化。
## 内容分类：GridPlacedObject 派生（非 PlaceableToken）——预置机关收编器静默跳过、
##   OccupancyRegistry / 光交互分发均不接本对象；运行期阻挡唯一入口是墙格快照
##   （core_loop 经 WallStyleCatalog.collect_wall_cells 采集 footprint 合并进 LevelTileLayerSnapshot，
##   is_wall_cell 统一事实），光学 interaction 永不调用本节点。
## 视觉：唯一子 Sprite2D 承载 64×64 官方墙素材；贴图路径经 WallStyleCatalog 冻结表解析，
##   占用格（锚格）与贴图格天然同一位置。
## Typed Configuration：apply_configuration 按 Stable Field ID "wall_style" 解释枚举整数
##   （与 LightBarrier.apply_configuration 同形），供编辑事务与未来作者工具统一入口。
## 不负责：多格结构（wall_structure.gd）、占用登记、放置合法性、TileMap WallLayer（兼容旧墙）、光传播。
## 类型约束：调用方一律通过 preload() 引用，避开全局 class_name 缓存问题。


## 12 种墙体样式（值序与 WallStyleCatalog.STYLE_ORDER 冻结序一致：四直 → 四外角 → 四内角）。
enum WallStyle {
	STRAIGHT_UP,
	STRAIGHT_DOWN,
	STRAIGHT_LEFT,
	STRAIGHT_RIGHT,
	LARGE_BEND_LU,
	LARGE_BEND_RU,
	LARGE_BEND_LD,
	LARGE_BEND_RD,
	SMALL_BEND_TL,
	SMALL_BEND_TR,
	SMALL_BEND_BL,
	SMALL_BEND_BR,
}


## 正式 Stable Field ID（内容 Schema 身份）：墙体样式字段（枚举值序与 WallStyle 一致）。
const FIELD_WALL_STYLE: StringName = &"wall_style"

const _WallStyleCatalog: GDScript = preload(
	"res://gameplay/content/wall/wall_style_catalog.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)


## 墙体样式（唯一样式事实）：Inspector 作者入口，变化即时刷新贴图；默认直墙·上。
@export_group("墙体样式")
@export var wall_style: WallStyle = WallStyle.STRAIGHT_UP : set = set_wall_style

## 墙体贴图子节点（场景唯一正式子节点；贴图由样式事实驱动，不持样式第二份）。
@onready var _wall_sprite: Sprite2D = $WallSprite


## 初始化样式贴图。
## [br]副作用：按当前 wall_style 写入 Sprite2D 贴图，不改位置、占用或任何运行期状态。
## [br]边界条件：set_wall_style 在 ready 前被调用时本刷新安全跳过，_ready 按最终样式补刷。
func _ready() -> void:
	_refresh_visual()


## 设置墙体样式（Inspector / 测试配置入口）。
## [br]new_style 是目标 WallStyle 枚举值。
## [br]无返回值；副作用是写入 wall_style 并刷新贴图。
## [br]越界值 push_error 并保持原值；节点未 ready 时刷新安全跳过（_ready 补刷）。
func set_wall_style(new_style: WallStyle) -> void:
	if new_style < 0 or new_style >= _WallStyleCatalog.STYLE_ORDER.size():
		push_error("WallBlock: 非法墙体样式：%d" % [new_style])
		return
	wall_style = new_style
	_refresh_visual()


## 正式 Typed Configuration 应用：按 Stable Field ID "wall_style" 解释枚举整数写入样式事实。
## [br]配置含未知字段或缺 wall_style 字段返回 false 且样式不变；越界由 set_wall_style 拒绝并保持原样式。
func apply_configuration(configuration: _MechanismConfiguration) -> bool:
	if configuration == null:
		return true
	var value: Variant = configuration.get_value(FIELD_WALL_STYLE)
	if not (value is int):
		push_error("WallBlock: Typed 配置缺少合法 %s 字段，拒绝应用。" % [FIELD_WALL_STYLE])
		return false
	# 注意：GDScript 的 as 优先级低于比较/逻辑运算符，布尔链中必须先落 typed 局部再比较。
	var style_value: int = value
	if style_value < 0 or style_value >= _WallStyleCatalog.STYLE_ORDER.size():
		push_error("WallBlock: Typed 配置墙体样式越界：%s。" % [value])
		return false
	set_wall_style(style_value as WallStyle)
	return true


## 本对象绝对占用格（= 锚格，单格对象）；供墙格快照采集（get_wall_cells 契约）。
## [br]无副作用；cell 由 position 确定性派生（GridPlacedObject 位置契约）。
func get_wall_cells() -> Array[Vector2i]:
	return [cell]


## 按当前样式刷新贴图：样式序号经冻结目录解析贴图路径后 load 写入 Sprite2D。
## [br]边界条件：未 ready 时直接返回；目录缺路径（不可能，冻结表完整）回退清空贴图。
func _refresh_visual() -> void:
	if not is_node_ready() or _wall_sprite == null:
		return
	var path: String = _WallStyleCatalog.texture_path_at(wall_style)
	_wall_sprite.texture = load(path) if not path.is_empty() else null
