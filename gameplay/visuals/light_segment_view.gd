class_name LightSegmentView
extends Node2D

## 永久光线路段显示组件（永久视觉接口 v1.0 第三批 B2）。
##
## 职责：根据 visual_profile 与当前传播方向选择水平 / 垂直 / 两种斜向四方向纹理，
## 正式纹理与黄色占位块互斥显示；运行时颜色由 light_color 统一调制正式纹理与占位块。
## 本组件只负责单格光路视觉，不处理 cell、世界坐标换算、传播、反射、阻挡或水晶逻辑。
##
## 在当前系统中的位置：
## gameplay/visuals 下与 ObjectVisualView 平行的独立光路显示组件，依赖 LightSegmentVisualProfile；
## 由核心闭环原型控制器在“每进入一个格子”时实例化一个，定位到格中心并加入 LightPathLayer。
##
## 关键边界（对应冻结决策）：
## - visual_profile 为空或对应方向纹理为空时，静默回退到黄色占位块，不输出 warning。
## - 不修改光传播方向、不调用镜面反射、不判断阻挡、不点亮水晶、不修改运行状态。
## - 不根据纹理反向决定方向；方向只由 set_direction() 写入，仅用于选择纹理。
## - 每次 refresh_visual() 都显式重设 Artwork.texture / visible / self_modulate 与
##   PlaceholderBlock.visible / color，避免从有纹理切换到无纹理时残留旧图片。
## - 同一格允许多个 LightSegmentView 共存，本组件不做 cell 去重或对象池。
## - 用 preload 引用 LightSegmentVisualProfile 脚本作为类型，避开 MCP run_project 不重建全局类型缓存的问题。


# 用 preload 引用光线路段视觉资源脚本，作为 visual_profile 与方法参数的静态类型。
const _LightSegmentVisualProfile: GDScript = preload("res://gameplay/visuals/light_segment_visual_profile.gd")

## 该光线路段的视觉资源集合。可为空；为空或对应方向纹理为空时回退到黄色占位块。
@export var visual_profile: _LightSegmentVisualProfile

# 占位 ColorRect 子节点：纹理缺失时显示的黄色方块。默认可见，默认颜色保持旧占位视觉。
@onready var _placeholder_block: ColorRect = $PlaceholderBlock
# 美术 TextureRect 子节点：承载四方向正式光线纹理。默认隐藏，位于 PlaceholderBlock 之后（覆盖在上层）。
@onready var _artwork: TextureRect = $Artwork

# 当前传播方向，仅用于选择四方向纹理，不参与传播逻辑。默认 RIGHT。
var _direction: Vector2i = Vector2i.RIGHT
# 当前光线颜色，同时调制正式纹理 self_modulate 与占位块 color。默认保持旧占位视觉的黄色。
var _light_color: Color = Color(1.0, 0.95, 0.2, 0.75)


## 初始化并按当前 profile / 方向 / 颜色刷新一次视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：调用 refresh_visual()，把 set_profile / set_direction / set_light_color 在节点 ready 前写入的值应用到子节点。
## [br]边界条件：若子节点尚未 ready，refresh_visual() 会安全返回；本函数在 @onready 变量已就绪后调用，确保首次显示正确。
func _ready() -> void:
	refresh_visual()


## 替换当前视觉资源集合并立即刷新视觉。
## [br]next_profile 是新的光线路段视觉资源，可为空。
## [br]无返回值；副作用是写入 visual_profile 并调用 refresh_visual()。
## [br]边界条件：本函数不校验资源内容，不修改 next_profile；为空时刷新后回退到黄色占位块，不输出 warning。
func set_profile(next_profile: _LightSegmentVisualProfile) -> void:
	visual_profile = next_profile
	refresh_visual()


## 设置当前传播方向并立即刷新视觉。
## [br]next_direction 是光进入该格时的传播方向，仅用于选择四方向纹理。
## [br]无返回值；副作用是写入 _direction 并调用 refresh_visual()。
## [br]边界条件：本函数不修改光传播逻辑、不调用反射；非法方向会令 profile.get_texture_for_direction() 返回 null，从而回退到占位块。
func set_direction(next_direction: Vector2i) -> void:
	_direction = next_direction
	refresh_visual()


## 设置当前光线颜色并立即刷新视觉。
## [br]next_color 是光线显示颜色，同时调制正式纹理 self_modulate 与占位块 color。
## [br]无返回值；副作用是写入 _light_color 并调用 refresh_visual()。
## [br]边界条件：本函数不引入 RGB 玩法逻辑，颜色只用于显示。
func set_light_color(next_color: Color) -> void:
	_light_color = next_color
	refresh_visual()


## 一次性配置 profile、方向与颜色并刷新视觉（精简统一入口）。
## [br]next_profile 是视觉资源，next_direction 是传播方向，next_color 是光线颜色。
## [br]无返回值；副作用是写入三项字段并调用一次 refresh_visual()。
## [br]边界条件：等价于依次调用 set_profile / set_direction / set_light_color，但只刷新一次。
func configure(next_profile: _LightSegmentVisualProfile, next_direction: Vector2i, next_color: Color) -> void:
	visual_profile = next_profile
	_direction = next_direction
	_light_color = next_color
	refresh_visual()


## 按当前 profile、方向与颜色合成并刷新全部视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：显式重设 Artwork.texture / visible / self_modulate 与 PlaceholderBlock.visible / color；
## [br]有对应纹理时显示 Artwork 并隐藏占位块，否则隐藏 Artwork（且清空 texture）并显示占位块。
## [br]边界条件：子节点尚未 ready 时安全返回，不输出 warning；从有纹理切回空纹理时 Artwork.texture 必须被清空，避免残留旧图。
func refresh_visual() -> void:
	# 子节点尚未 ready（控制器在 add_child 前设置字段）时安全返回，_ready() 会再次刷新。
	if _artwork == null or _placeholder_block == null:
		return

	var texture: Texture2D = _resolve_texture()
	# 每次刷新显式重设全部相关属性，避免从有纹理切换到无纹理时残留旧图片。
	# self_modulate 与占位块 color 都始终跟随 light_color，保证正式纹理与占位块共用同一光线颜色。
	_artwork.self_modulate = _light_color
	_placeholder_block.color = _light_color
	if texture == null:
		_artwork.texture = null
		_artwork.visible = false
		_placeholder_block.visible = true
	else:
		_artwork.texture = texture
		_artwork.visible = true
		_placeholder_block.visible = false


## 按当前 profile 与方向解析应显示的纹理。
## [br]本函数无参数。
## [br]返回目标 Texture2D；visual_profile 为空、方向非法或对应字段为空时返回 null。
## [br]本函数无副作用，不修改 profile 或方向，不输出 warning。
func _resolve_texture() -> Texture2D:
	if visual_profile == null:
		return null
	return visual_profile.get_texture_for_direction(_direction)
