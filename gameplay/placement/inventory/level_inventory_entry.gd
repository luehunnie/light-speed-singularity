class_name LevelInventoryEntry
extends RefCounted

## Level Inventory Authoring Entry（AF-03 / P0-5，Guide §15.1）：每关库存条目只保存
## content_type_id / initial_quantity / order 三项；显示名、图标、描述、默认状态一律来自 Definition。
## Guide 11.2 冻结：关卡 Inventory Entry 不允许私自覆盖 Spawn 初始配置 —— 由本类形状本身保证
## （不存在任何配置字段）；运行期配置一律取 Definition Type Default。


## 库存类型（须为 FormalContentRegistry 已声明的 mechanism 域类型；空值即非法）。
var content_type_id: StringName = &""
## 初始数量（钳制为非负；0 表示本关不提供该类型）。
var initial_quantity: int = 0
## 机关栏排序（作者声明；小者在前，同序按登记顺序稳定）。
var order: int = 0


## 构造库存条目；数量钳制为非负。
func _init(p_content_type_id: StringName = &"", p_initial_quantity: int = 0, p_order: int = 0) -> void:
	content_type_id = p_content_type_id
	initial_quantity = maxi(p_initial_quantity, 0)
	order = p_order


## 条目合法性：类型非空且数量非负（供运行时 setup 校验，重复类型由 Runtime 统一检测）。
func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if content_type_id == &"":
		errors.append("content_type_id 为空。")
	if initial_quantity < 0:
		errors.append("initial_quantity 为负。")
	return errors
