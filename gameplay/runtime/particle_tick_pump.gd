class_name ParticleTickPump
extends RefCounted

## 光粒 Tick 现实时间驱动泵（D7-4 B3b-2）。
## 职责：按冻结的现实时间间隔（PARTICLE_TICK_SECONDS = 0.1s）等待，并经 advance_tick Callable 请求上层（LevelRuntimeController）推进一次整数 Tick。
##   这是纯技术驱动器——只承担"SceneTreeTimer 创建 + await 循环 + 按回调返回值决定是否继续"，不承担任何 gameplay 判定。
## 位置：位于 gameplay/runtime 下；介于 LevelRuntimeController（推进逻辑所有者）与 SceneTreeTimer 之间，
##   把 SceneTreeTimer 创建 / await 循环 / generation wait cancellation 的循环骨架从 LRC 抽出，避免 LRC 堆积异步细节与重复泵代码。
## 依赖：仅 Godot SceneTree（run 时由调用方传入用于 create_timer；本类不持久持有 tree / 不持有任何 controller）；
##   不 preload 任何 gameplay 脚本，不引用 ParticleScheduler / RunStateController / ObjectiveController。
## 不负责（硬边界——本类绝不做以下任何一项）：
##   - 不持有 / 修改 RunStateController、ObjectiveController、ParticleScheduler、ParticleRuntimeState；
##   - 不产生 / 自增 / 比较 generation（generation 唯一真值为 LevelRuntimeController._pulse_generation）；
##   - 不解释 BatchEvent、不激活 Crystal、不创建 / 移动 / 终止光粒；
##   - 不决定 MOVE_WINDOW / COMPLETED、不调 finish_pulse、不刷新 UI；
##   - 不成为第二个 Runtime manager（无 gameplay 事实、无 gameplay 判定、无 gameplay 副作用）。
## 正式 cadence 冻结：run() 不再接受 tick_seconds 参数；现实间隔恒为 PARTICLE_TICK_SECONDS(0.1)，其 0.1 字面量唯一来源为
##   gameplay/core/particle_tick_timing.gd 的 TICK_SECONDS（D7-4 B4b-2 起与视觉 Tween 时长换算共用，不形成两份独立 0.1 常量），
##   调用方（含生产 LRC）无法注入任意秒数。测试不使用本类——测试经 tests/** 的 ControllableParticleTickPump 驱动同一 callback。
## generation await cancellation 正确性来源：上层 advance_tick Callable 内的首行 generation 守卫——
##   旧 generation 的 await 回来后 advance_tick 返回 false，本泵立即退出循环，不推进、不结束、不改状态。
##   正确性保证来自 generation token（LevelRuntimeController._pulse_generation），不依赖 stop_all_timers / 全局 Timer 清理。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题；本类声明 class_name 仅为可读性，LRC 不依赖全局缓存解析。


## 正式光粒 Tick 现实间隔（冻结，0.1 秒字面量唯一来源为 gameplay/core/particle_tick_timing.gd 的 TICK_SECONDS）。
## 0.1 秒只驱动现实时间——gameplay Tick 真值仍为 ParticleScheduler._current_tick 整数递增，
## 现实间隔不得成为 gameplay 状态真值。run() 内部固定使用本常量，不接受外部覆盖（D7-4 B3b-2.1 MF-2）。
## D7-4 B4b-2：0.1 字面量上移到共享 ParticleTickTiming，本常量改为转发其 TICK_SECONDS——视觉 Tween 时长
##   (duration_ticks * TICK_SECONDS) 与本泵 await 间隔共用同一来源，不形成两份独立 0.1 常量。await/pump 行为不变。
const PARTICLE_TICK_SECONDS: float = preload("res://gameplay/core/particle_tick_timing.gd").TICK_SECONDS


## 按冻结现实间隔循环推进整数 Tick（fire-and-forget；调用方不 await）。
## [br]职责：每次等待 PARTICLE_TICK_SECONDS 后调用 advance_tick(expected_generation)；
##   返回 true → 继续下一 Tick；返回 false → 停止本链。
## [br]输入：tree 为当前 SceneTree（用于 create_timer，run 作用域内使用，不持久持有）；
##   advance_tick 为上层推进回调，签名 (expected_generation: int) -> bool，内部完成 generation 守卫、
##   scheduler.advance_one_tick、BatchEvent 应用、drain 判定与 pulse finish（全部 gameplay 逻辑归上层，本泵不介入）；
##   expected_generation 为本链启动时捕获的 generation 快照（真值仍为 LRC._pulse_generation，本泵不持有 / 不比较）。
## [br]副作用：仅 SceneTreeTimer 创建与 await；不读写任何 gameplay 状态——所有 gameplay 变更由 advance_tick 完成。
## [br]边界：本泵不持有 generation、不判定 drain、不解释事件；advance_tick 返回 false 即停
##   （generation 不匹配 / 已 drain / 已不在 PULSE_ACTIVE，三种情况由上层统一编码为返回 false）。
##   一次 Particle pulse 只启动一条本泵链——LevelRuntimeController.request_fire 在 PULSE_ACTIVE 时被 RunStateController 拒绝，
##   故正常路径不会启动第二条链；本泵不引入额外 bool guard，正确性依赖 generation + RunState。
func run(
		tree: SceneTree,
		advance_tick: Callable,
		expected_generation: int
) -> void:
	while true:
		await tree.create_timer(PARTICLE_TICK_SECONDS).timeout
		# 纯技术守卫：上层 Object 已 free（测试 cleanup / 关卡卸载）时 callable 失效，本泵静默退出。
		# 不替代 generation / RunState 正确性——gameplay 正确性仍由上层 advance_tick 首行 generation 守卫保证，
		# 本守卫只防止对已释放 Object 调用方法，不持有 / 不比较 generation，不构成第二份 gameplay 状态真值。
		if not advance_tick.is_valid():
			return
		# await 回来后第一件事：交回上层 advance_tick；其首行 generation 守卫决定旧链是否立即退出。
		# 本泵不碰 generation、不 advance、不 finish——仅据返回值决定是否继续下一 Tick。
		var should_continue: bool = advance_tick.call(expected_generation)
		if not should_continue:
			return
