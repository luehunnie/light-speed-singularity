extends RefCounted

## 可控光粒 Tick 驱动泵替身（D7-4 B3b-2.1 MF-1 / MF-2 测试技术 seam）。
## 职责：实现与正式 ParticleTickPump 相同的 run() 签名（鸭子类型；LRC 以 Variant 持有，对生产代码透明），
##   但 run() 不进入 await 循环——只捕获 LRC 注册的 callback + expected_generation，立即返回。测试经 resume_one_tick()
##   显式驱动"下一次 callback 触发"，不真实等待 0.1 秒。
## 位置：tests/unit/runtime/fixtures/ 下；绝不进入 gameplay/**。无 class_name（不污染全局 class 注册），由 runtime_controller_fixture preload。
## 多链语义：每次 run() 登记一条新链（callback + expected_generation 快照）。这与正式泵"每次 request_fire 启动一条新 await 协程"
##   的真实拓扑一致——R 后旧链未 resume 前"挂起"，新 fire 再启一条新链；resume_one_tick() 触发"当前帧所有挂起 timer 一起到期"，
##   逐条调一次 callback：旧链因 generation mismatch 在 _on_particle_tick 首行守卫永久 no-op（return false → 标记 stopped），
##   新链（generation 匹配）正常推进。故正式泵与测试替身最终都调用 LRC 传给它们的同一个 callback（_on_particle_tick → _process_particle_tick），
##   只有一套 gameplay Tick 实现。
## 依赖：零 gameplay 脚本依赖；只持有 Callable（弱语义——Callable 不强引用上层 Object，LRC 在树期间不被释放）。
## 不负责（硬边界——与正式泵一致，本替身绝不做以下任何一项）：
##   - 不持有 / 修改 ParticleScheduler / ParticleRuntimeState / generation / RunState / Objective；
##   - 不解释 BatchEvent、不激活 Crystal、不创建 / 移动 / 终止光粒；
##   - 不决定 MOVE_WINDOW / COMPLETED、不调 finish_pulse、不刷新 UI；
##   - 不成为第二个 Runtime manager；只控制"什么时候触发下一次已注册的 callback"。
## 类型约束：由 fixture 经 preload() 路径引用，不依赖全局 class_name 缓存。


## 单条 pump 链：捕获一次 run() 调用的 callback + expected_generation 快照 + 停止标记。
class _Chain:
	extends RefCounted

	## LRC 注册的推进回调（_on_particle_tick），签名 (expected_generation: int) -> bool。
	var callback: Callable
	## 本链启动时（request_fire → _begin_particle_pulse → ParticleTickDriver.start_pump_if_idle）捕获的 generation 快照；真值仍为 LRC._runtime_generation。
	var expected_generation: int = -1
	## 本链是否已停止（callback 返回 false / callable 失效）。停止后 resume 不再触发本链。
	var stopped: bool = false

	func _init(p_callback: Callable, p_expected_generation: int) -> void:
		callback = p_callback
		expected_generation = p_expected_generation


## 已登记的 pump 链集合（按 run() 调用顺序；含已停止链，便于诊断只读）。
var _chains: Array = []


## 注册一条新 pump 链——与正式泵 run() 签名一致，供 LRC 透明调用。
## [br]输入：tree 在本替身中被忽略（无真实 SceneTreeTimer）；advance_tick 为 LRC 推进回调；
##   expected_generation 为本链 generation 快照。
## [br]副作用：仅 append 一条 _Chain；不进入 await 循环、不触发任何 callback——callback 由测试经 resume_one_tick() 显式触发。
func run(_tree: SceneTree, advance_tick: Callable, expected_generation: int) -> void:
	_chains.append(_Chain.new(advance_tick, expected_generation))


## 显式触发"下一次 callback"：对每条未停止链各调用一次其 callback。
## [br]语义等价于正式泵"现实 0.1s timer 到期一次"——多链并存时（R 后旧链 + 新 fire 新链）一次 resume 即"一帧内所有挂起 timer 齐到期"。
## [br]callback 返回 false（generation mismatch / 已 drain / 已不在 PULSE_ACTIVE）→ 本链标记 stopped，后续 resume 不再触发。
## [br]返回 true 表示本次 resume 后仍有至少一条链继续（可继续 resume）；false 表示全部链已停止（再 resume 不会再推进任何 Tick）。
## [br]不真实等待；不判定 gameplay——drain / finish / RunState 全由 callback（_on_particle_tick）内部决定。
func resume_one_tick() -> bool:
	var any_continuing: bool = false
	for chain: _Chain in _chains:
		if chain.stopped:
			continue
		if not chain.callback.is_valid():
			chain.stopped = true
			continue
		var should_continue: bool = chain.callback.call(chain.expected_generation)
		if not should_continue:
			chain.stopped = true
		else:
			any_continuing = true
	return any_continuing


## 是否已开始（run() 至少被调用过一次，即至少登记过一条链）。
func is_started() -> bool:
	return not _chains.is_empty()


## 当前仍在继续的链数量（未停止）；0 表示无活动 pump 链。
func active_chain_count() -> int:
	var n: int = 0
	for chain: _Chain in _chains:
		if not chain.stopped:
			n += 1
	return n
