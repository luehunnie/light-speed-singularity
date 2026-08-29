class_name RayColor
extends RefCounted

## 光线颜色唯一事实来源（玩法颜色，API 契约 §38.3 / Q46 冻结）。
## 职责：持有离散枚举 ColorValue（WHITE/RED/GREEN/BLUE + NONE 哨兵），提供 is_valid 等无副作用纯函数。
##   颜色只属于光线（RAY）形态；光粒（PARTICLE）不带颜色（玩法设计 §6/§7）。
##   玩法颜色与视觉 Color 严格分离——本枚举是玩法事实，不得以 Godot Color 作为玩法颜色真相（§38.3）。
## 位置：gameplay/light 下，与 direction_domain.gd、light_emission_types.gd 同级；
##   被滤光片（滤色目标）、颜色水晶（ColorCondition）、传播核心（追踪光线颜色状态）、光形式转换器（颜色重置）共享。
## 依赖：不 preload 任何游戏脚本；不引用机关、Runtime、场景树、占用、库存。
## 不负责：滤色逻辑（白光→单色、同色保持、异色吸收属滤光片机关局部规则）、视觉颜色映射（属视觉层）、光粒颜色（光粒无颜色）。
## 边界条件：ColorValue 数值冻结（WHITE=0/RED=1/GREEN=2/BLUE=3/NONE=-1），序列化边界禁止更改；
##   NONE 是"吸收/非法"哨兵，非真实颜色；本模块纯静态无状态，不进场景树。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。

## 颜色值枚举。数值已冻结（NONE=-1 / WHITE=0 / RED=1 / GREEN=2 / BLUE=3），序列化边界禁止更改。
enum ColorValue {
	## 哨兵：吸收 / 非法输入，非真实颜色。
	NONE = -1,
	## 白色（默认，主发射器初始光色）。
	WHITE = 0,
	RED = 1,
	GREEN = 2,
	BLUE = 3,
}

## 判定一个颜色值是否为真实四色（WHITE/RED/GREEN/BLUE，排除哨兵 NONE）。
## [br]value 是待判定的 ColorValue（本质为 int，越界值也需防御）。
## [br]返回 true 表示 value 是真实颜色；NONE（-1）及范围外值返回 false。
## [br]副作用：无；不读取或修改任何实例状态。
static func is_valid(value: ColorValue) -> bool:
	return value >= ColorValue.WHITE and value <= ColorValue.BLUE
