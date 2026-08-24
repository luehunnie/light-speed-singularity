class_name MechanismFieldDefinition
extends Resource

## 机关配置字段声明（AF-03 / P0-4，Guide §11.3 / §11.4）：Stable Field ID 的唯一 Schema 载体。
## 三层字段身份（Guide 11.3）：field_id 是内容 Schema 长期契约身份；display_name 是作者界面名称；
## 内部 GDScript property path 属实现细节，公共系统不得把它当长期契约引用。
## @export 本身不等于正式作者字段：只有经本声明进入 Definition.configuration_fields 的字段才是正式 Designer API。
## 本类只声明“字段有什么约束”，不保存任何实例值；实例值由 MechanismConfiguration 按 Schema 约束存储。


## 字段值类型域（Guide 11.1 Typed Configuration：公共系统不得把配置退化成自由 Dictionary）。
enum ValueType {
	BOOL,
	INT,
	FLOAT,
	STRING_NAME,
	VECTOR2I,
	VECTOR2I_ARRAY,
}


## 稳定字段 ID（内容 Schema 身份；空值即非法）。
@export var field_id: StringName = &""
## 作者显示名（空值即非法）。
@export var display_name: String = ""
## 值类型；INT 类型可另以 enum_min/enum_max 声明枚举界。
@export var value_type: ValueType = ValueType.INT
## INT 枚举下界（含）；仅当 enum_max >= enum_min 时生效，否则 INT 为无枚举约束的普通整数。
@export var enum_min: int = 0
## INT 枚举上界（含）；小于 enum_min 表示无枚举约束。
@export var enum_max: int = -1
## 类型默认值（Type Default 层，Guide 11.2）；构造时按值类型与枚举界校验。
@export var default_value: Variant = 0
## 该字段由哪个 Typed Player Interaction Action 驱动（Guide §12；空 = 不由玩家循环动作直接驱动）。
@export var player_action: StringName = &""


## 校验声明合法性（供 MechanismDefinition.validate_definition 复用）：ID/显示名非空、默认值合法。
func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if field_id == &"":
		errors.append("field_id 为空。")
	if display_name.is_empty():
		errors.append("display_name 为空。")
	if not is_valid_value(default_value):
		errors.append("default_value 与字段类型/枚举界不匹配：%s。" % [str(default_value)])
	return errors


## 判断值是否满足本字段类型与枚举界（纯判断，无副作用）。
func is_valid_value(value: Variant) -> bool:
	match value_type:
		ValueType.BOOL:
			return value is bool
		ValueType.INT:
			if not (value is int):
				return false
			if enum_max >= enum_min:
				return value >= enum_min and value <= enum_max
			return true
		ValueType.FLOAT:
			return value is float
		ValueType.STRING_NAME:
			return value is StringName
		ValueType.VECTOR2I:
			return value is Vector2i
		ValueType.VECTOR2I_ARRAY:
			if not (value is Array):
				return false
			for entry: Variant in value:
				if not (entry is Vector2i):
					return false
			return true
	return false


## 是否声明了 INT 枚举界（供循环动作提案计算周期）。
func has_enum_range() -> bool:
	return value_type == ValueType.INT and enum_max >= enum_min
