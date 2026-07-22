class_name VisualStateTexture
extends Resource

## 永久视觉资源数据接口：单一稳定视觉状态及其纹理资源。
##
## 职责：
## 保存一个内容状态（例如 default、slash、backslash、unlit、lit）对应的正式世界纹理与可选拖拽纹理，
## 供 ObjectVisualProfile 统一管理，使美术只需在 .tres 中填写纹理即可替换画面，不需要修改玩法脚本。
##
## 在当前系统中的位置：
## gameplay/visuals 下最底层的视觉资源数据接口（第一批只实现数据层）。
## 是后续 ObjectVisualView、PlaceableToken、BasicCrystal、SingleCellMirror、InventorySlotView 等显示组件
## 与机关读取纹理的统一数据来源之一；本批不实现这些显示组件，也不把本资源接入任何现有对象。
##
## 主要依赖：
## Texture2D 纹理资源与 StringName 稳定状态 ID。不依赖场景树、节点、输入、玩法状态或资源路径扫描。
##
## 明确不负责：
## 场景树查询、节点显示、输入处理、镜面反射、水晶点亮、库存数量、放置合法性、运行状态、
## 资源路径自动扫描、具体 PNG 的 preload。本资源只保存数据。
##
## 关键边界：
## - drag_texture 为空属于合法配置，由上层在拖拽时回退到同一状态的 world_texture。
## - state_id 属于代码契约，应使用稳定小写英文（default、slash、backslash、unlit、lit 等），
##   不应使用“状态1”“新状态”等不稳定命名；图片文件名可调整，但 state_id 尽量不变。
## - 本资源不缓存查询结果、不读取文件系统、不扫描 assets。


## 状态的稳定 ID，例如 default、slash、backslash、unlit、lit。
## 属于代码契约：图片文件名可以调整，但 state_id 应尽量保持不变。
@export var state_id: StringName = &"default"

## 对象正式放置在世界中时显示的纹理。不应为空。
@export var world_texture: Texture2D

## 对象作为拖拽预览时显示的可选纹理。
## 可为空；为空时由上层回退到同一状态的 world_texture。
@export var drag_texture: Texture2D


## 校验当前状态资源的配置完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的问题；无问题时返回空数组。
## [br]本函数无副作用，不修改资源内容，不输出错误。
## [br]边界条件：必须一次返回全部问题，不得遇到第一项错误就提前返回；
## [br]drag_texture 为空不视为错误；返回的问题字符串为中文并指明具体字段。
func validate_state() -> PackedStringArray:
	var problems: PackedStringArray = []
	# state_id 为空属于配置错误：状态 ID 是代码契约，缺失会导致上层无法按 ID 查找该状态。
	if state_id == &"":
		problems.append("VisualStateTexture：state_id 为空，必须填写稳定状态 ID。")
	# world_texture 为空属于配置错误：正式世界纹理缺失会导致对象在世界中无可显示内容。
	if world_texture == null:
		problems.append("VisualStateTexture：state_id=%s 的 world_texture 为空，必须填写正式世界纹理。" % [state_id])
	# drag_texture 为空不属于错误：上层会回退到同一状态的 world_texture，此处不检查。
	return problems
