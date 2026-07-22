class_name LightSegmentVisualProfile
extends Resource

## 永久光线路段视觉资源数据接口：四方向可替换纹理（永久视觉接口 v1.0 第三批 B2）。
##
## 职责：集中保存水平、垂直、两种斜向四种光线路段纹理，提供“方向 → 纹理”的纯映射，
## 使张梓涵以后只修改本 .tres 资源即可替换四种光线图片，不需要修改光传播代码。
##
## 在当前系统中的位置：
## gameplay/visuals 下与 ObjectVisualProfile 平行的独立视觉资源数据接口，只服务光线路径段；
## 被 LightSegmentView 读取以选择四方向纹理。不复用 ObjectVisualProfile / VisualStateTexture，
## 因为光线路径段是“每进入一个格子创建一个视觉”的逐格模型，不存在对象内容状态切换。
##
## 关键边界（对应冻结决策）：
## - 四个纹理全部为空属于合法配置，运行时由 LightSegmentView 静默回退到黄色占位块，本资源不输出 warning。
## - 纹理负责形状，运行时颜色由 LightSegmentView 的 light_color 负责调制，本资源不保存颜色。
## - 不缓存查询结果，不读取文件系统，不修改资源自身。
## - 非法方向返回空 StringName 或 null，不错误映射到任意纹理。
## - 不创建 default_texture / fallback_texture 第五字段；回退由 LightSegmentView 负责。


## 水平光线纹理（方向 LEFT / RIGHT）。可为空。
@export var horizontal_texture: Texture2D
## 垂直光线纹理（方向 UP / DOWN）。可为空。
@export var vertical_texture: Texture2D
## 斜向 “/” 光线纹理（方向 (1,-1) / (-1,1)，左下到右上）。可为空。
@export var slash_texture: Texture2D
## 斜向 “\” 光线纹理（方向 (1,1) / (-1,-1)，左上到右下）。可为空。
@export var backslash_texture: Texture2D

# 四方向状态名契约：仅用于 get_segment_state_for_direction() 的诊断返回，当前不驱动显示，也不作为纹理查找键。
const STATE_HORIZONTAL: StringName = &"horizontal"
const STATE_VERTICAL: StringName = &"vertical"
const STATE_SLASH: StringName = &"slash"
const STATE_BACKSLASH: StringName = &"backslash"

# 合法光线路段方向集合：四个正交方向 + 四个单位斜向方向（Godot 二维坐标 Y 轴向下）。
# ZERO、超单位长度向量（如 (2,0)、(0,-2)、(2,2)）均不属于本集合，不得映射到任意纹理。
const _VALID_DIRECTIONS: Array[Vector2i] = [
	Vector2i.LEFT, Vector2i.RIGHT,
	Vector2i.UP, Vector2i.DOWN,
	Vector2i(1, -1), Vector2i(-1, 1),
	Vector2i(1, 1), Vector2i(-1, -1),
]


## 判断一个方向是否是合法的光线路段方向。
## [br]direction 是待检查的 Vector2i 方向。
## [br]返回 true 表示方向属于四正交或四单位斜向；返回 false 表示 ZERO、超单位长度或其他非法方向。
## [br]本静态函数无副作用，不创建资源实例，不输出 warning。
## [br]边界条件：Godot 二维坐标 Y 轴向下，LEFT/RIGHT 为水平，UP/DOWN 为垂直；本函数只判定方向合法性，不查纹理。
static func is_valid_segment_direction(direction: Vector2i) -> bool:
	return direction in _VALID_DIRECTIONS


## 取得指定方向对应的稳定状态名。
## [br]direction 是待映射的 Vector2i 方向。
## [br]返回对应状态 StringName；非法方向返回空 StringName（&""）。
## [br]本静态函数无副作用，不输出 warning；边界条件：LEFT/RIGHT → horizontal，UP/DOWN → vertical，
## [br](1,-1)/(-1,1) → slash，(1,1)/(-1,-1) → backslash；非法方向不映射到任意状态。
static func get_segment_state_for_direction(direction: Vector2i) -> StringName:
	match direction:
		Vector2i.LEFT, Vector2i.RIGHT:
			return STATE_HORIZONTAL
		Vector2i.UP, Vector2i.DOWN:
			return STATE_VERTICAL
		Vector2i(1, -1), Vector2i(-1, 1):
			return STATE_SLASH
		Vector2i(1, 1), Vector2i(-1, -1):
			return STATE_BACKSLASH
		_:
			return &""


## 取得指定方向对应的光线纹理。
## [br]direction 是待查询的 Vector2i 方向。
## [br]返回对应字段的 Texture2D；方向非法或对应字段为空时返回 null。
## [br]本函数无副作用，不修改资源自身，不输出 warning。
## [br]边界条件：非法方向在进入 match 前即返回 null，绝不错误映射到任意纹理；字段为空返回 null 属于合法配置。
func get_texture_for_direction(direction: Vector2i) -> Texture2D:
	if not is_valid_segment_direction(direction):
		return null
	match direction:
		Vector2i.LEFT, Vector2i.RIGHT:
			return horizontal_texture
		Vector2i.UP, Vector2i.DOWN:
			return vertical_texture
		Vector2i(1, -1), Vector2i(-1, 1):
			return slash_texture
		Vector2i(1, 1), Vector2i(-1, -1):
			return backslash_texture
		_:
			return null


## 校验当前光线路段视觉资源的配置完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray；当前四字段全空属于合法配置，故始终返回空数组。
## [br]本函数无副作用，不修改资源内容，不输出 warning；保留接口供未来扩展校验（例如非空纹理尺寸一致性）。
func validate_profile() -> PackedStringArray:
	return PackedStringArray()
