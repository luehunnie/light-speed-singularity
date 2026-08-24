class_name FootprintContract
extends RefCounted

## Placement Footprint Contract（AF-03 / P0-4，Guide §13）：逻辑占格的唯一纯计算来源。
## 禁止从视觉推导占格（Guide 13.1）：不得读 Sprite 尺寸 / CollisionShape / 美术节点位置。
## 简单机关走 Definition 静态声明（默认 [(0,0)]）；动态占格机关走 Typed Configuration 驱动偏移
## （Definition.footprint_field_id 声明 VECTOR2I_ARRAY 字段，Guide 13.2）。
## 纯函数边界（Guide 13.2）：无 WorldQuery、无 SceneTree、无 Runtime State、无副作用；
## anchor 语义（Guide 13.3）由 Definition 声明层承载，本模块只做 anchor + offsets 的确定性展开。


const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)


## 计算一次放置/移动候选的绝对占格集合（纯函数）。
## [br]definition 提供 static_footprint_offsets（或 footprint_field_id 动态声明）；
## [br]configuration 为当前实例配置（动态足迹时读取声明字段值；静态足迹可传 null）。
## [br]返回 anchor + offsets 的绝对格数组（副本）；动态字段缺失/非法（空列表/含非 Vector2i）回退静态足迹。
static func footprint_cells(
	definition: _MechanismDefinition,
	configuration: _MechanismConfiguration,
	anchor_cell: Vector2i
) -> Array[Vector2i]:
	var offsets := footprint_offsets(definition, configuration)
	var cells: Array[Vector2i] = []
	for offset: Vector2i in offsets:
		cells.append(anchor_cell + offset)
	return cells


## 计算相对 anchor 的占格偏移（纯函数）：动态声明优先，静态声明兜底。
static func footprint_offsets(
	definition: _MechanismDefinition,
	configuration: _MechanismConfiguration
) -> Array[Vector2i]:
	if definition.footprint_field_id != &"" and configuration != null:
		var dynamic_offsets: Variant = configuration.get_value(definition.footprint_field_id)
		if _is_valid_offset_list(dynamic_offsets):
			var typed_offsets: Array[Vector2i] = []
			for entry: Variant in dynamic_offsets:
				typed_offsets.append(entry)
			return typed_offsets
	return definition.static_footprint_offsets.duplicate()


## 偏移列表合法性（纯判断）：非空数组、成员全为 Vector2i、无重复格。
static func _is_valid_offset_list(offsets: Variant) -> bool:
	if not (offsets is Array) or (offsets as Array).is_empty():
		return false
	var seen: Dictionary = {}
	for entry: Variant in offsets:
		if not (entry is Vector2i):
			return false
		if seen.has(entry):
			return false
		seen[entry] = true
	return true
