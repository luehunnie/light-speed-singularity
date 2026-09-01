class_name RayMechanismResult
extends RefCounted

## 普通光线机关光学响应结果（Day 1 D1-B）：RayMechanismAdapter 与核心传播循环之间的最小结果协议，
## 表达"保持原方向继续 / 改向 / 停止 / 形态转换"四态，并透传颜色变更（color_change）；不携带伤害、光强、分光或其它未来机关字段。
## 由 Adapter 构造返回；核心在薄包装中读取 kind 与 outgoing_direction，映射为既有 Vector2i 传播语义。
## 关键边界：BLOCK 当前仅作协议保留——原型无实际阻挡型机关，未知机关与非法方向策略以 Adapter 既有行为为准，不得借本类型新增玩法。
## outgoing_direction 仅在 REDIRECT / FORM_CHANGE 时被核心采用；CONTINUE 时核心沿用 incoming_direction。

const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

## 机关光学响应五态（C-08 扩展 REDIRECT_CROSS）。
## [br]CONTINUE：保持入射方向继续传播（无光学效果或未知机关）。
## [br]REDIRECT：使用 outgoing_direction 作为后续传播方向（镜面反射等已支持机关）。
## [br]BLOCK：停止传播；当前原型仅作为协议保留，不引入新阻挡玩法。
## [br]FORM_CHANGE：形态转换载荷（阶段C-01 光形式转换器）。
## [br]REDIRECT_CROSS：改向 + 透明跨过 cross_direction 邻格（C-08 双格平面镜；执行层记录跨界格路径但不重复判机关）。
enum Kind {
	CONTINUE,
	REDIRECT,
	BLOCK,
	FORM_CHANGE,
	REDIRECT_CROSS,
}

## 响应类型，决定核心传播循环如何更新方向。由 Adapter 构造时写入，核心读取后即丢弃，不缓存、不跨脉冲保留。
var kind: Kind

## REDIRECT / FORM_CHANGE 时的出射方向（八方向 Vector2i 单位向量）；CONTINUE 与 BLOCK 时不被核心采用，非法方向下保持 Vector2i.ZERO。
var outgoing_direction: Vector2i

## FORM_CHANGE 的目标形态（LightForm 值：RAY / PARTICLE）；其余 Kind 恒为 -1 哨兵（阶段C-01 光形式转换器）。
var target_form: int = -1

## REDIRECT_CROSS 的跨界方向（C-08；正交四方向，该方向邻格被透明跨过）；其余 Kind 恒为 Vector2i.ZERO。
var cross_direction: Vector2i = Vector2i.ZERO

## 分光分支载荷透传（C-08；元素为 LightInteractionResult.BranchSpec——跨模块内类不做静态元素类型标注，
##   类型与合法性由 Contract 层 validate 强制）。仅 CONTINUE / REDIRECT 时可能非空；本类只透传引用，不改写分支。
var spawned_branches: Array = []

## COLOR_CHANGE 目标色（ColorValue 枚举值）；无颜色变更时恒为 NONE 哨兵，供核心在响应后更新光线颜色。
var color_change: int = _RayColor.ColorValue.NONE

## 构造一个机关光学响应结果；只写字段，CONTINUE 时 outgoing_direction 可记入射方向以便调试，BLOCK 时不被采用。
func _init(
		p_kind: Kind = Kind.CONTINUE,
		p_outgoing_direction: Vector2i = Vector2i.ZERO
) -> void:
	kind = p_kind
	outgoing_direction = p_outgoing_direction


## 构造“保持原方向继续”结果；direction 仅作出射方向记录以便调试，核心在 CONTINUE 时仍沿用入射方向。
static func continue_with(direction: Vector2i) -> RayMechanismResult:
	return RayMechanismResult.new(Kind.CONTINUE, direction)


## 构造“改向”结果；direction 须为非零八方向单位向量，非法方向应由 Adapter 转入 BLOCK 而非传入本方法。
static func redirect_to(direction: Vector2i) -> RayMechanismResult:
	return RayMechanismResult.new(Kind.REDIRECT, direction)


## 构造“停止传播”结果；BLOCK 仅作协议保留，用于节点失效或镜面非法入射等既有“安全停止”场景，不新增阻挡玩法。
static func block() -> RayMechanismResult:
	return RayMechanismResult.new(Kind.BLOCK, Vector2i.ZERO)


## 构造“形态转换”结果（阶段C-01 光形式转换器）：RAY 传播在机关格内转换为 target_form 形态并沿 direction 出射；
##   RAY→PARTICLE 标准速度 / PARTICLE→RAY 默认白色由执行适配层按平台默认生成，本结果只携带目标形态 + 输出方向。
static func form_change(target_form: int, direction: Vector2i) -> RayMechanismResult:
	var result: RayMechanismResult = RayMechanismResult.new(Kind.FORM_CHANGE, direction)
	result.target_form = target_form
	return result


## 构造“改向 + 透明跨格”结果（C-08 双格平面镜）：出射沿 redirect_direction，cross_direction 方向邻格被
##   透明跨过（执行层记录该格路径但不重复判机关——同机关跨格不重复触发）。方向合法性由 Contract 层 validate 强制。
static func redirect_cross(redirect_direction: Vector2i, cross_direction: Vector2i) -> RayMechanismResult:
	var result: RayMechanismResult = RayMechanismResult.new(Kind.REDIRECT_CROSS, redirect_direction)
	result.cross_direction = cross_direction
	return result
