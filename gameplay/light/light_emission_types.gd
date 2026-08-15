class_name LightEmissionTypes
extends RefCounted

## 光发射公共类型契约（D7-4 B1）。
## 职责：集中持有光发射形态枚举 LightForm（RAY/PARTICLE）与八方向传播方向合法性纯函数，
##   作为 PARTICLE 光粒运行系统与未来发射器共享的最小稳定类型契约，避免 LightForm 数值与八方向合法集合
##   分散在 fire_request.gd / ParticleMotionRules / 未来 scheduler 各自复制一份形成第二套事实来源。
## 位置：位于 gameplay/light 下，与 fire_request.gd 同目录；本模块是“光形态枚举 + 八方向合法性”的唯一公共来源。
## 依赖：不 preload 任何游戏脚本；不引用 EmitterConfigNode、FireRequest、ParticleMotionRules 或 ParticleRuntimeState，
##   不定义第二份 LightForm，不修改 EmitterConfigNode.LightForm，不定义玩家方向输入枚举。
## 不负责：发射请求、传播步进、速度档位、运行期状态、视觉尺寸、场景树读取、Autoload、文件、时间或随机数。
## 边界条件：LightForm 数值 RAY=0 / PARTICLE=1 已被既有发射器场景序列化隐式依赖，修改会破坏场景兼容边界，禁止更改；
##   合法八方向为 (±1,0)(0,±1)(±1,±1) 共 8 个单位向量，Vector2i.ZERO 与任一分量绝对值 >1 均非法；
##   本模块只定义枚举与无副作用纯函数，不做任何运行期计算或状态修改。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


## 光发射形态。RAY 为连续路径光线；PARTICLE 为离散移动光粒。
## 数值 RAY=0 / PARTICLE=1 与既有 EmitterConfigNode.LightForm 及发射器场景序列化对齐，
## 修改任意数值会破坏场景兼容边界，禁止更改。
enum LightForm {
	## 光线形态：连续路径，厚度 16px。数值 0（冻结，勿改）。
	RAY = 0,
	## 光粒形态：离散移动实体，主体 24×16px。数值 1（冻结，勿改）。
	PARTICLE = 1,
}


## 八方向合法集合（单位向量，两分量绝对值均不超过 1 且非零）。
## 唯一合法事实来源；is_valid_direction 据此判定，不依赖运行期发射器向量算法。
const _VALID_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
	Vector2i(0, -1),
	Vector2i(1, -1),
]


## 判定方向是否为合法八方向之一（纯判断，无副作用）。
## [br]输入：direction 是待判定的 Vector2i，不被本函数修改。
## [br]返回：true 表示 direction 为八个单位方向之一；Vector2i.ZERO 与任一分量绝对值 >1 返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入。
## [br]失败：不会失败；任意 Vector2i 输入均返回确定布尔结果。
## [br]边界：合法集合即 _VALID_DIRECTIONS，不依赖运行期发射器向量算法；
##   本函数是八方向合法性的唯一公共判定入口，ParticleMotionRules / ParticleRuntimeState 通过 preload 复用，不另立合法集合。
static func is_valid_direction(direction: Vector2i) -> bool:
	return direction in _VALID_DIRECTIONS


## 判定方向是否为斜向（两分量绝对值均为 1，纯判断，无副作用）。
## [br]输入：direction 是待判定的 Vector2i，不被本函数修改。
## [br]返回：true 表示 direction 为四个斜向单位方向 (±1,±1) 之一；正交方向与非法方向返回 false。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入。
## [br]失败：不会失败；任意 Vector2i 输入均返回确定布尔结果。
## [br]边界：本函数只识别“是否斜向”，不替代 is_valid_direction 的合法性判定；
##   非法方向（如 (2,2)/(0,0)）因分量绝对值不为 1 自然返回 false，不与正交方向混淆。
##   ParticleMotionRules 据本函数在正交 / 斜向两张 Tick 表之间选择，不重复维护斜向判定。
static func is_diagonal_direction(direction: Vector2i) -> bool:
	return absi(direction.x) == 1 and absi(direction.y) == 1
