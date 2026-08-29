@tool
class_name FormalContentDefinition
extends Resource

## 正式内容类型声明基类（AF-01 / P0-1，Guide 4.1）。
## 只承载类型级共享事实与作者元数据；三个子域：mechanism / objective_target / emitter。
## 边界（Guide 4.2）：Definition 只声明"有什么能力"，不保存能力算法；算法属机关脚本。
## 身份（Guide 6）：content_type_id 是唯一类型身份；节点名、节点路径、网格坐标均不是身份。
## 本批最小集仅含身份与发现所需字段；视觉槽位、稳定字段/事件/动作 ID 等能力域按后续阶段 additive 扩展。


## 稳定类型身份 token；空值即非法定义（Discovery 拒绝）。
@export var content_type_id: StringName = &""
## 作者显示名；空值即非法定义。
@export var display_name: String = ""
## 作者分组 token（自由 token，非身份）。
@export var category: StringName = &""
## 类型场景实现；缺失即非法定义（Guide 5.3）。
@export var scene: PackedScene = null
## 是否允许预放置。
@export var preplaceable: bool = true
## 是否可进入关卡库存配置（Inventory 面板类型下拉与运行期库存事实的唯一资格声明）。
## [br]作者域声明：true 即可在 Inventory 下拉配置并随 inventory_entries 序列化；
## 运行期玩家拿取/放置/回收的实际能力另由场景根契约（PlaceableToken 派生链）与
## Interaction Profile 共同决定，本字段只声明库存资格，不隐含运行期交互能力。
@export var inventory_eligible: bool = false
## 是否支持稳定实例身份。
@export var supports_stable_instance: bool = true
## 是否支持作者备注。
@export var supports_editor_note: bool = true


## 内容域 token；子类覆写为 mechanism / objective_target / emitter，基类返回空。
func get_content_domain() -> StringName:
	return &""


## 校验定义合法性，返回错误清单（空清单 = 合法）；调用方为 Discovery。
func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if content_type_id == &"":
		errors.append("content_type_id 为空。")
	if display_name.is_empty():
		errors.append("display_name 为空。")
	if scene == null:
		errors.append("PackedScene 缺失。")
	return errors
