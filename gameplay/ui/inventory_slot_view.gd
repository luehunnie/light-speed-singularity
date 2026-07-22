class_name InventorySlotView
extends PanelContainer

## 永久视觉接口 v1.0 §12 道具栏槽位显示组件。
##
## 职责：
## 仅负责一个道具栏槽位的 UI 表现——根据 visual_profile.inventory_icon 选择显示正式图标或 ColorRect 占位符，
## 显示剩余数量文本，并按当前是否允许从道具栏拿取切换启用 / 禁用视觉。每次刷新都显式重置全部 visible、
## texture、color 与 self_modulate 状态，使张梓涵未来只需在 ObjectVisualProfile 的 .tres 中填写
## inventory_icon 即可替换道具栏图标，不需要修改脚本或场景结构。
##
## 在当前系统中的位置：
## gameplay/visuals 下视觉显示组件层（第三层），与 ObjectVisualView 并列；由 levels/prototypes/core_loop_prototype.gd
## 在刷新机关栏 UI 时驱动，挂载在现有 PrototypeTokenSlot 节点上，保持原型改动最小。本组件不持有库存事实，
## 库存数量与拿取权限由关卡控制器计算后通过 refresh_slot() 传入。
##
## 主要依赖：
## ObjectVisualProfile 视觉资源数据（读取 inventory_icon）、ColorRect 占位符、TextureRect 正式图标、Label 剩余数量。
##
## 明确不负责：
## 扣减或恢复库存、实例化镜面、处理拖拽事务、判断 RunState、修改 ObjectVisualProfile 资源内容、
## 从 world_texture 或 drag_texture 寻找图标、访问 PlaceableToken 或 SingleCellMirror 玩法状态、
## 修改关卡控制器中的库存事实、鼠标命中（命中仍由本节点继承自 Control 的 get_global_rect() 承担，但不在本脚本内实现）。
##
## 关键边界：
## - visual_profile 为空或 inventory_icon 为空时只显示 ColorRect 占位符，不读取 world_texture / drag_texture，不输出 warning。
## - 正式图标与占位符互斥显示：同一时刻只有一个可见。
## - 即使当前 inventory_icon 为空，禁用 / 启用对正式图标 self_modulate 的设置分支也完整实现，
##   以便张梓涵未来填入 inventory_icon 后无需改动脚本即可直接生效。
## - mouse_filter 与命中：InventoryIcon 设为 MOUSE_FILTER_IGNORE，不干扰 PrototypeTokenSlot 的 get_global_rect() 命中逻辑。


## 道具栏视觉资源。inventory_icon 非空时显示正式图标，为空时显示 ColorRect 占位符。
## 固定物件或尚未提供正式图标时可以留空。
@export var visual_profile: ObjectVisualProfile

# 占位符 ColorRect 在启用状态下的颜色，保留原原型栏位的蓝绿色。
const _PLACEHOLDER_COLOR_ENABLED: Color = Color(0.25, 0.85, 0.95, 1.0)
# 占位符 ColorRect 在禁用状态下的颜色，保留原原型栏位的灰色半透明。
const _PLACEHOLDER_COLOR_DISABLED: Color = Color(0.25, 0.25, 0.28, 0.7)
# 正式图标 TextureRect 在启用状态下的 self_modulate。
const _ICON_MODULATE_ENABLED: Color = Color.WHITE
# 正式图标 TextureRect 在禁用状态下的 self_modulate，统一灰色半透明。
const _ICON_MODULATE_DISABLED: Color = Color(0.45, 0.45, 0.45, 0.6)

# 占位符 ColorRect，inventory_icon 为空时显示。
@onready var _token_icon: ColorRect = $SlotMargin/SlotContent/IconStack/TokenIcon
# 正式图标 TextureRect，inventory_icon 非空时显示，位于占位符上方。
@onready var _inventory_icon: TextureRect = $SlotMargin/SlotContent/IconStack/InventoryIcon
# 剩余数量文本节点。
@onready var _remaining_label: Label = $SlotMargin/SlotContent/SlotTexts/RemainingLabel


## 刷新道具栏槽位显示。
## [br]remaining 是当前库存剩余数量；is_available 表示当前库存大于 0 且运行状态允许从道具栏拿取。
## [br]无返回值；副作用是每次显式重置 TokenIcon.visible / TokenIcon.color、
## [br]InventoryIcon.visible / InventoryIcon.texture / InventoryIcon.self_modulate 与 RemainingLabel.text。
## [br]边界条件：本函数不扣减或恢复库存、不判断 RunState、不访问 PlaceableToken 或 SingleCellMirror 玩法状态、
## [br]不读取 world_texture / drag_texture；visual_profile 为空或 inventory_icon 为空时只显示占位符且不输出 warning。
func refresh_slot(remaining: int, is_available: bool) -> void:
	_refresh_icon()
	_apply_availability_visual(is_available)
	_update_remaining_text(remaining)


## 选择显示正式图标还是占位符，并显式设置两者的 visible 与 texture。
## [br]本函数无参数、无返回值。
## [br]副作用：visual_profile 非空且 inventory_icon 非空时，把正式图标写入 InventoryIcon.texture 并显示，
## [br]同时隐藏占位符；否则清空 InventoryIcon.texture 并隐藏，显示占位符。
## [br]边界条件：不读取 world_texture / drag_texture；inventory_icon 为空时 InventoryIcon.texture 设为 null 且不可见，
## [br]不会因空纹理产生 warning；正式图标与占位符严格互斥，不会同时可见。
func _refresh_icon() -> void:
	var icon: Texture2D = _resolve_inventory_icon()
	if icon == null:
		# 占位符分支：清空并隐藏正式图标，显示 ColorRect 占位符。
		_inventory_icon.texture = null
		_inventory_icon.visible = false
		_token_icon.visible = true
		return

	# 正式图标分支：写入正式图标并显示，隐藏占位符。
	_inventory_icon.texture = icon
	_inventory_icon.visible = true
	_token_icon.visible = false


## 按当前是否允许拿取切换启用 / 禁用视觉，显式设置占位符颜色与正式图标 self_modulate。
## [br]is_available 为 true 表示启用状态，为 false 表示禁用状态。
## [br]无返回值；副作用是同时设置 TokenIcon.color 与 InventoryIcon.self_modulate。
## [br]边界条件：无论当前显示的是占位符还是正式图标，两个属性都显式重置，
## [br]避免从禁用恢复启用时留下永久灰显；对隐藏节点设置颜色 / 调制无副作用，保证未来填入 inventory_icon 后分支完整可用。
func _apply_availability_visual(is_available: bool) -> void:
	if is_available:
		_token_icon.color = _PLACEHOLDER_COLOR_ENABLED
		_inventory_icon.self_modulate = _ICON_MODULATE_ENABLED
	else:
		_token_icon.color = _PLACEHOLDER_COLOR_DISABLED
		_inventory_icon.self_modulate = _ICON_MODULATE_DISABLED


## 更新剩余数量文本。
## [br]remaining 是当前库存剩余数量。
## [br]无返回值；副作用是把 RemainingLabel.text 设为“剩余：N”。
## [br]边界条件：remaining 由关卡控制器传入，本函数只负责显示，不修改库存事实。
func _update_remaining_text(remaining: int) -> void:
	_remaining_label.text = "剩余：%d" % remaining


## 取得当前应显示的道具栏正式图标。
## [br]本函数无参数。
## [br]返回 visual_profile.inventory_icon；visual_profile 为空或 inventory_icon 为空时返回 null。
## [br]本函数无副作用，不读取 world_texture / drag_texture，不输出 warning。
## [br]边界条件：仅以 inventory_icon 作为道具栏图标来源，不进行任何跨字段回退。
func _resolve_inventory_icon() -> Texture2D:
	if visual_profile == null:
		return null
	return visual_profile.inventory_icon
