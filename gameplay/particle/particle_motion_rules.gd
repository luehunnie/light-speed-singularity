class_name ParticleMotionRules
extends RefCounted

## 光粒运动纯规则共享模块（D7-4 B1）。
## 职责：集中持有光粒 SpeedTier 枚举、整数 Tick 表与速度档位饱和纯函数，
##   作为光粒运行系统与未来机关（加速器 / 减速器 / 光屏障）共享的唯一“速度档位 ↔ 整数 Tick”事实来源，
##   避免 Tick 数值与饱和表分散在 scheduler / executor / 机关内部各自复制一份形成第二套玩法真值。
## 位置：位于 gameplay/particle 下；本模块是“光粒速度档位 + 整数 Tick 表 + 饱和”的唯一规则来源。
## 依赖：通过 preload 引用 res://gameplay/light/light_emission_types.gd 复用八方向合法性与斜向判定，
##   不定义第二份方向合法集合，不复制八方向向量；不依赖 ParticleRuntimeState、scheduler、executor、world query 或视觉。
## 不负责：scheduler、executor、Tick 推进、移动执行、碰撞、Timer、Node、_process、浮点秒数玩法真值、场景树读取、文件、时间或随机数。
## 边界条件：Tick 表冻结值 SLOW/STANDARD/FAST × 正交/斜向 共 6 项，斜向值是对 √2 距离差的整数 Tick 近似；
##   速度饱和 FAST+1→FAST、SLOW-1→SLOW（两端封顶），中间档 ±1 线性移动；
##   非法 speed/direction 一律 push_error + 安全哨兵返回（counts 返回 INVALID_TICKS，SpeedTier 返回 SLOW 或原档位），
##   不发明 Result 类型，与 EmitterConfigNode / GridCoordinateRules 既有错误边界风格一致。
## 类型约束：调用方一律通过 preload() 引用以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


const _LightEmissionTypes: GDScript = preload(
	"res://gameplay/light/light_emission_types.gd"
)


## 光粒速度档位。SLOW/STANDARD/FAST 三档；数值被未来 scheduler / 机关与可能的状态序列化隐式依赖，禁止更改。
enum SpeedTier {
	## 慢速：正交 8 Tick / 格，斜向 11 Tick / 格。数值 0。
	SLOW = 0,
	## 标准速度：正交 4 Tick / 格，斜向 6 Tick / 格。主发射器默认初始档位。数值 1。
	STANDARD = 1,
	## 快速：正交 2 Tick / 格，斜向 3 Tick / 格。数值 2。
	FAST = 2,
}


## 非法 speed/direction 输入下 ticks_for 的统一哨兵返回值。
## 取负值以与任何合法正整数 Tick 区分；调用方据此可立即识别 bug，push_error 已同步上报。
const INVALID_TICKS: int = -1


# 正交移动（↑ ↓ ← →）每格 Tick 表。唯一来源，禁止在他处复制。
const _TICKS_ORTHOGONAL: Dictionary = {
	SpeedTier.SLOW: 8,
	SpeedTier.STANDARD: 4,
	SpeedTier.FAST: 2,
}

# 斜向移动（↗ ↘ ↙ ↖）每斜向格 Tick 表；对 √2 距离差的整数近似。唯一来源，禁止在他处复制。
const _TICKS_DIAGONAL: Dictionary = {
	SpeedTier.SLOW: 11,
	SpeedTier.STANDARD: 6,
	SpeedTier.FAST: 3,
}


## 判定 speed_tier 是否为合法 SpeedTier 值（纯判断，无副作用）。
## [br]输入：speed_tier 是待判定的整数。
## [br]返回：true 表示 speed_tier 属于 SpeedTier 枚举值集合；否则返回 false。
## [br]副作用：无。
## [br]失败：不会失败；任意 int 输入均返回确定布尔结果。
## [br]边界：合法集合即 SpeedTier.values()，不依赖外部映射；本函数是 SpeedTier 合法性的唯一公共判定入口。
static func is_valid_speed_tier(speed_tier: int) -> bool:
	return speed_tier in SpeedTier.values()


## 计算指定速度档位沿指定方向移动一格所需的整数 Tick（纯计算，无副作用）。
## [br]输入：speed_tier 为 SpeedTier 枚举值；direction 为合法八方向 Vector2i。
## [br]返回：正交方向返回 _TICKS_ORTHOGONAL[speed_tier]，斜向返回 _TICKS_DIAGONAL[speed_tier]。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入。
## [br]失败：speed_tier 非法或 direction 非法时 push_error 并返回 INVALID_TICKS（-1），不抛异常。
## [br]边界：斜向判定复用 LightEmissionTypes.is_diagonal_direction，不重复维护；
##   1 Tick ≈ 0.1 秒仅为人类直觉换算，玩法真值是本函数返回的整数 Tick，不使用浮点秒数；
##   本函数不推进 Tick、不执行移动、不读写 world query 或视觉。
static func ticks_for(speed_tier: int, direction: Vector2i) -> int:
	if not is_valid_speed_tier(speed_tier):
		push_error("ParticleMotionRules：非法 SpeedTier 值 %d，返回 INVALID_TICKS。" % speed_tier)
		return INVALID_TICKS
	if not _LightEmissionTypes.is_valid_direction(direction):
		push_error("ParticleMotionRules：非法方向 (%d, %d)，返回 INVALID_TICKS。" % [direction.x, direction.y])
		return INVALID_TICKS
	if _LightEmissionTypes.is_diagonal_direction(direction):
		return int(_TICKS_DIAGONAL[speed_tier])
	return int(_TICKS_ORTHOGONAL[speed_tier])


## 对速度档位施加 +1 / -1 变化并按饱和表返回新档位（纯计算，无副作用）。
## [br]输入：speed_tier 为 SpeedTier 枚举值；delta 仅接受 +1（加速一档）或 -1（减速一档）。
## [br]返回：按冻结饱和表返回新 SpeedTier——SLOW+1→STANDARD、STANDARD+1→FAST、FAST+1→FAST（封顶）；
##   SLOW-1→SLOW（封底）、STANDARD-1→SLOW、FAST-1→STANDARD。
## [br]副作用：无；不读取或修改任何实例状态，不修改输入。
## [br]失败：speed_tier 非法时 push_error 并返回 SLOW（安全地板）；delta 非 ±1 时 push_error 并返回原 speed_tier（安全 no-op）。
## [br]边界：饱和表两端封顶，不循环、不抛异常；本函数不推进 Tick、不执行移动、不读写 world query 或视觉；
##   速度变化从机关之后的下一传播步开始生效的时机由未来 executor 决定，本函数只负责档位推导。
static func apply_speed_delta(speed_tier: int, delta: int) -> int:
	if not is_valid_speed_tier(speed_tier):
		push_error("ParticleMotionRules：非法 SpeedTier 值 %d，返回 SLOW。" % speed_tier)
		return SpeedTier.SLOW
	if delta == 1:
		match speed_tier:
			SpeedTier.SLOW: return SpeedTier.STANDARD
			SpeedTier.STANDARD: return SpeedTier.FAST
			SpeedTier.FAST: return SpeedTier.FAST
	elif delta == -1:
		match speed_tier:
			SpeedTier.SLOW: return SpeedTier.SLOW
			SpeedTier.STANDARD: return SpeedTier.SLOW
			SpeedTier.FAST: return SpeedTier.STANDARD
	push_error("ParticleMotionRules：非法 delta %d（仅接受 ±1），返回原档位 %d。" % [delta, speed_tier])
	return speed_tier
