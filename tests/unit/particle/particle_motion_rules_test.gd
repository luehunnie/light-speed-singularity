extends SceneTree

## ParticleMotionRules 定向测试（D7-4 B1）。
## 覆盖：SpeedTier 数值；六个 Tick 表值（正交 8/4/2、斜向 11/6/3）；方向无关性（正交等价 / 斜向等价）；
##   三档 +1/-1 饱和；非法 speed / direction / delta 一致哨兵处理。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；不读写 assets、不生成资源文件。

const _ParticleMotionRules: GDScript = preload(
	"res://gameplay/particle/particle_motion_rules.gd"
)

const _GROUP_COUNT: int = 9

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 9 组后统一报告并退出。
func _initialize() -> void:
	_test_01_speedtier_values()
	_test_02_orthogonal_ticks()
	_test_03_diagonal_ticks()
	_test_04_direction_independence()
	_test_05_accelerate_saturation()
	_test_06_decelerate_saturation()
	_test_07_invalid_speed_tier()
	_test_08_invalid_direction()
	_test_09_invalid_delta()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. SpeedTier 数值冻结：SLOW=0 / STANDARD=1 / FAST=2。
func _test_01_speedtier_values() -> void:
	const G: String = "01_SpeedTier数值"
	var T = _ParticleMotionRules.SpeedTier
	_check(G, T.SLOW == 0, "SLOW 期望 0，实际 %d。" % T.SLOW)
	_check(G, T.STANDARD == 1, "STANDARD 期望 1，实际 %d。" % T.STANDARD)
	_check(G, T.FAST == 2, "FAST 期望 2，实际 %d。" % T.FAST)


## 2. 正交 Tick 表：SLOW=8 / STANDARD=4 / FAST=2。
func _test_02_orthogonal_ticks() -> void:
	const G: String = "02_正交Tick表"
	var T = _ParticleMotionRules.SpeedTier
	var ortho: Vector2i = Vector2i(1, 0)
	_check(G, _ParticleMotionRules.ticks_for(T.SLOW, ortho) == 8, "SLOW 正交期望 8。")
	_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, ortho) == 4, "STANDARD 正交期望 4。")
	_check(G, _ParticleMotionRules.ticks_for(T.FAST, ortho) == 2, "FAST 正交期望 2。")


## 3. 斜向 Tick 表：SLOW=11 / STANDARD=6 / FAST=3。
func _test_03_diagonal_ticks() -> void:
	const G: String = "03_斜向Tick表"
	var T = _ParticleMotionRules.SpeedTier
	var diag: Vector2i = Vector2i(1, 1)
	_check(G, _ParticleMotionRules.ticks_for(T.SLOW, diag) == 11, "SLOW 斜向期望 11。")
	_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, diag) == 6, "STANDARD 斜向期望 6。")
	_check(G, _ParticleMotionRules.ticks_for(T.FAST, diag) == 3, "FAST 斜向期望 3。")


## 4. 方向无关性：四个正交等价、四个斜向等价（不依赖具体方向只看正交/斜向）。
func _test_04_direction_independence() -> void:
	const G: String = "04_方向无关性"
	var T = _ParticleMotionRules.SpeedTier
	var orthos: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
	]
	for d: Vector2i in orthos:
		_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, d) == 4,
			"正交 (%d, %d) 期望 STANDARD=4。" % [d.x, d.y])
	var diags: Array[Vector2i] = [
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	for d: Vector2i in diags:
		_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, d) == 6,
			"斜向 (%d, %d) 期望 STANDARD=6。" % [d.x, d.y])


## 5. 加速饱和（+1）：SLOW→STANDARD / STANDARD→FAST / FAST→FAST（封顶）。
func _test_05_accelerate_saturation() -> void:
	const G: String = "05_加速饱和+1"
	var T = _ParticleMotionRules.SpeedTier
	_check(G, _ParticleMotionRules.apply_speed_delta(T.SLOW, 1) == T.STANDARD, "SLOW+1 期望 STANDARD。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.STANDARD, 1) == T.FAST, "STANDARD+1 期望 FAST。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.FAST, 1) == T.FAST, "FAST+1 期望 FAST（封顶）。")


## 6. 减速饱和（-1）：SLOW→SLOW（封底）/ STANDARD→SLOW / FAST→STANDARD。
func _test_06_decelerate_saturation() -> void:
	const G: String = "06_减速饱和-1"
	var T = _ParticleMotionRules.SpeedTier
	_check(G, _ParticleMotionRules.apply_speed_delta(T.SLOW, -1) == T.SLOW, "SLOW-1 期望 SLOW（封底）。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.STANDARD, -1) == T.SLOW, "STANDARD-1 期望 SLOW。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.FAST, -1) == T.STANDARD, "FAST-1 期望 STANDARD。")


## 7. 非法 SpeedTier：ticks_for 返回 INVALID_TICKS；apply_speed_delta 返回 SLOW（安全地板）。
func _test_07_invalid_speed_tier() -> void:
	const G: String = "07_非法SpeedTier"
	_check(G, _ParticleMotionRules.ticks_for(99, Vector2i(1, 0)) == _ParticleMotionRules.INVALID_TICKS,
		"非法 speed=99 的 ticks_for 期望 INVALID_TICKS。")
	_check(G, _ParticleMotionRules.ticks_for(-1, Vector2i(1, 1)) == _ParticleMotionRules.INVALID_TICKS,
		"非法 speed=-1 的 ticks_for 期望 INVALID_TICKS。")
	_check(G, _ParticleMotionRules.apply_speed_delta(99, 1) == _ParticleMotionRules.SpeedTier.SLOW,
		"非法 speed=99 的 apply_speed_delta(+1) 期望 SLOW。")
	_check(G, _ParticleMotionRules.is_valid_speed_tier(99) == false, "is_valid_speed_tier(99) 期望 false。")
	_check(G, _ParticleMotionRules.is_valid_speed_tier(_ParticleMotionRules.SpeedTier.STANDARD) == true,
		"is_valid_speed_tier(STANDARD) 期望 true。")


## 8. 非法方向：ZERO 与超范围方向 ticks_for 返回 INVALID_TICKS。
func _test_08_invalid_direction() -> void:
	const G: String = "08_非法方向"
	var T = _ParticleMotionRules.SpeedTier
	_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, Vector2i.ZERO) == _ParticleMotionRules.INVALID_TICKS,
		"ZERO 方向 ticks_for 期望 INVALID_TICKS。")
	_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, Vector2i(2, 0)) == _ParticleMotionRules.INVALID_TICKS,
		"(2,0) 方向 ticks_for 期望 INVALID_TICKS。")
	_check(G, _ParticleMotionRules.ticks_for(T.STANDARD, Vector2i(1, 2)) == _ParticleMotionRules.INVALID_TICKS,
		"(1,2) 方向 ticks_for 期望 INVALID_TICKS。")


## 9. 非法 delta：非 ±1 的 apply_speed_delta 返回原档位（安全 no-op）。
func _test_09_invalid_delta() -> void:
	const G: String = "09_非delta"
	var T = _ParticleMotionRules.SpeedTier
	_check(G, _ParticleMotionRules.apply_speed_delta(T.STANDARD, 0) == T.STANDARD,
		"delta=0 期望返回原档 STANDARD。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.FAST, 2) == T.FAST,
		"delta=2 期望返回原档 FAST。")
	_check(G, _ParticleMotionRules.apply_speed_delta(T.SLOW, -2) == T.SLOW,
		"delta=-2 期望返回原档 SLOW。")


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ParticleMotionRules 测试摘要（D7-4 B1）====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
