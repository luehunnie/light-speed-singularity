extends PanelContainer

## 多类型道具卡单卡视图（AF-10 第三批）：一张卡的纯呈现——名称、剩余数量、正式图标与降级占位符。
## 图标唯一来源 = ObjectVisualProfile.inventory_icon（永久视觉接口 v1.0 §12 冻结契约）：
## 本组件每次 refresh 都从 visual_profile 现场读取 inventory_icon，不复制/不缓存第二份纹理路径，
## 美术替换 .tres 中的图标资源后无需改脚本，下次刷新/重建即显示新图标；
## profile 为空、inventory_icon 为空或加载失败时显示 ColorRect 占位符并保持剩余数量正常显示。
## 视觉常量与 InventorySlotView 同源：经 preload 读取其冻结色值，不在本文件维护第二份配色事实。
## 子节点全部在 setup() 内代码构建（无 @onready），支持 headless 无帧泵构造与测试。
## 不负责：库存事实、选中事实（InventoryCardBar 持有）、类型解析、Registry 访问、输入命中决策。


const _InventorySlotViewScript: GDScript = preload(
	"res://gameplay/ui/inventory_slot_view.gd"
)

## 本卡类型 ID（构造后不变）。
var type_id: StringName = &""
## 正式视觉资源（图标唯一来源）；未知类型可为 null（占位符降级）。
var visual_profile = null

# 占位符 ColorRect，inventory_icon 为空时显示。
var _placeholder_icon: ColorRect
# 正式图标 TextureRect，inventory_icon 非空时显示，位于占位符上方。
var _icon_texture: TextureRect
# 名称与剩余数量文本。
var _name_label: Label
var _remaining_label: Label
# 选中高亮（未选中时轻微压暗；可用性仍由图标/占位符调制表达）。
const _SELECTED_MODULATE: Color = Color.WHITE
const _UNSELECTED_MODULATE: Color = Color(0.82, 0.84, 0.9, 1.0)


## 构建卡内部节点树；type_id/display_name/visual_profile 来自 InventoryCardBar.build_card_models。
## [br]display_name 为 Registry 定义显示名；未知类型由调用方传 type_id 字符串作显示名。
func setup(p_type_id: StringName, display_name: String, p_visual_profile = null) -> void:
	type_id = p_type_id
	visual_profile = p_visual_profile
	custom_minimum_size = Vector2(148, 52)
	var margin := MarginContainer.new()
	margin.name = "CardMargin"
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var content := HBoxContainer.new()
	content.name = "CardContent"
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)
	var icon_stack := Control.new()
	icon_stack.name = "IconStack"
	icon_stack.custom_minimum_size = Vector2(28, 28)
	content.add_child(icon_stack)
	_placeholder_icon = ColorRect.new()
	_placeholder_icon.name = "PlaceholderIcon"
	_placeholder_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_placeholder_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_stack.add_child(_placeholder_icon)
	_icon_texture = TextureRect.new()
	_icon_texture.name = "IconTexture"
	_icon_texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_stack.add_child(_icon_texture)
	var texts := VBoxContainer.new()
	texts.name = "CardTexts"
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(texts)
	_name_label = Label.new()
	_name_label.name = "NameLabel"
	_name_label.text = display_name
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(_name_label)
	_remaining_label = Label.new()
	_remaining_label.name = "RemainingLabel"
	_remaining_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(_remaining_label)
	refresh(0, false, false)


## 刷新卡显示；每次显式重置图标/占位互斥、可用性调制、选中调制与剩余文本。
## [br]remaining 为该类型当前剩余；is_available 表示剩余 > 0 且当前状态允许拿取；is_selected 为选中高亮。
## [br]图标在此时点从 visual_profile.inventory_icon 现场读取（活绑定，非缓存副本）。
func refresh(remaining: int, is_available: bool, is_selected: bool) -> void:
	var icon: Texture2D = _resolve_inventory_icon()
	if icon == null:
		_icon_texture.texture = null
		_icon_texture.visible = false
		_placeholder_icon.visible = true
	else:
		_icon_texture.texture = icon
		_icon_texture.visible = true
		_placeholder_icon.visible = false
	if is_available:
		_placeholder_icon.color = _InventorySlotViewScript._PLACEHOLDER_COLOR_ENABLED
		_icon_texture.self_modulate = _InventorySlotViewScript._ICON_MODULATE_ENABLED
	else:
		_placeholder_icon.color = _InventorySlotViewScript._PLACEHOLDER_COLOR_DISABLED
		_icon_texture.self_modulate = _InventorySlotViewScript._ICON_MODULATE_DISABLED
	self_modulate = _SELECTED_MODULATE if is_selected else _UNSELECTED_MODULATE
	_remaining_label.text = "剩余：%d" % remaining


## 取本卡应显示的正式图标；visual_profile 为空或 inventory_icon 为空返回 null（占位符降级）。
## [br]不读取 world_texture / drag_texture，不进行跨字段回退（与 InventorySlotView 同边界）。
func _resolve_inventory_icon() -> Texture2D:
	if visual_profile == null:
		return null
	return visual_profile.inventory_icon
