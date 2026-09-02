@tool
extends FormalContentDefinition

## D-04 墙体内容域声明（最小 typed wall content 分类，Guide 4.1 分域口径）。
## 墙体是正式作者内容但不是机关：不声明光交互形态、不进库存、不进控制域；
##   光学 interaction 永不解析墙对象（运行期阻挡唯一入口为墙格快照合并）。
## 本域仅承载类型身份、场景与静态 Footprint（Palette 放置锚点扫描用）；
##   动态 footprint（L 墙旋向）由节点自身 get_occupied_offsets 按事实展开，不走 footprint_field_id。
## 类型约束：调用方一律通过 preload() 引用，避开全局 class_name 缓存问题。


## 静态 Footprint 声明（与 MechanismDefinition 同形，Palette 首个合法空格扫描用）：
## anchor 相对偏移格；默认单格 [(0,0)]；非空、无重复格。
@export var static_footprint_offsets: Array[Vector2i] = [Vector2i.ZERO]


## 内容域 token：wall。
func get_content_domain() -> StringName:
	return &"wall"


## 校验：基类域 + 静态足迹非空无重复（口径与 MechanismDefinition 一致）。
func validate_definition() -> PackedStringArray:
	var errors := super.validate_definition()
	if static_footprint_offsets.is_empty():
		errors.append("static_footprint_offsets 为空（至少须含 anchor 偏移 (0,0)）。")
	var seen_cells: Dictionary = {}
	for offset: Vector2i in static_footprint_offsets:
		if seen_cells.has(offset):
			errors.append("static_footprint_offsets 存在重复偏移格 %s。" % [offset])
		seen_cells[offset] = true
	return errors
