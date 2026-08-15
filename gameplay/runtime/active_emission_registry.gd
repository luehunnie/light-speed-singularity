class_name ActiveEmissionRegistry
extends RefCounted

## 活动 emission 登记表（M4-E1；M4-E2 扩展双向 particle_runtime_id 映射）。
## 职责：作为主发射器“活动 emission”的纯 Runtime 身份 bookkeeping 组件——按单调 emission_id 登记每次成功发射、
##   记录其 generation / 光形态、在 emission 结束时标记完成，并提供活动计数 / 是否有活动 / 全清入口。
##   M4-E2 起：每条 emission record 携带 generation + form + particle_runtime_ids 集合，并维护 runtime_id → emission_id 反向索引，
##   使 Particle TERMINATE(runtime_id) 能反查所属 emission、在最后一个 runtime 解绑时由 LRC 推进该 emission 结束。
##   emission_id 单调递增、RAY/PARTICLE 共用同一 ID 空间、R 后不复用（计数器不回拨）；runtime_id 集合支持“一次 emission 多粒子”。
## 位置：gameplay/runtime 下；纯身份 bookkeeping 组件，由 LevelRuntimeController 唯一持有并驱动
##   （allocate/bind_particle_runtime/unbind_particle_runtime/mark_finished/clear 仅 LRC 调用）。
## 依赖：零 gameplay 脚本依赖（generation / form 仅作为 int 存储，不校验、不解释；runtime_id 仅作为 int 索引）；
##   不 preload 任何控制器 / 视觉 / 调度器 / RunState / Objective。
## 不负责（硬边界——本组件绝不做以下任何一项）：
##   - 操作 RunStateController / 决定 PULSE_ACTIVE / 决定 COMPLETED / 结算生命周期（结算由 LRC 据 has_active 推进）；
##   - 依赖 / 修改 ParticleScheduler / 创建或移动光粒 / 触发 RayExecution；
##   - 创建 Timer / 推进 Tick / 维护 cooldown（emission_id / generation / runtime_id 三者完全不同职责）；
##   - 创建 / 销毁视觉节点 / 发布事件（视觉由 LightVisualController / ParticleVisualController 等独立驱动）；
##   - 决定 Objective（最后 emission 结束后 active_count==0 的事实由 LRC 读取 has_active 推进结算）。
## 三身份区别（绝不混用）：
##   - generation：Runtime/reset 异步失效 token（同一 Runtime epoch 内多次发射共享同一 generation；真值 LRC._runtime_generation）；
##   - emission_id：单次成功发射的唯一身份（同一 generation 内每次发射各自一个 emission_id，单调递增、跨 R 不复用）；
##   - runtime_id：单颗光粒的唯一身份（由 ParticleScheduler 单调分配；一次 PARTICLE emission 可绑定一个或多个 runtime_id）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## emission_id -> 活动登记 Dictionary（{ "generation": int, "form": int, "runtime_ids": Array[int] }）；
## 活动 emission 数量即本表 size。mark_finished 直接 erase 并清理其 runtime 反向索引；不保留历史
## （历史 emission_id 已由单调计数器不可复用，无需在表内留存）。
var _emissions: Dictionary = {}
## runtime_id -> emission_id 反向索引（M4-E2）；仅登记已 bind_particle_runtime 的光粒。
## 与 _emissions[id]["runtime_ids"] 严格双向同步：bind 两边同写、unbind 两边同删、mark_finished 清整条 emission 时清残留反向项。
var _runtime_to_emission: Dictionary = {}
## 下一个待分配的 emission_id；从 1 起，单调递增，跨 clear 不回拨（R 后不复用 emission_id）。
var _next_emission_id: int = 1


## 登记一次成功发射：分配唯一单调 emission_id、记录其 generation 与光形态，返回该 emission_id。
## [br]输入：generation 为本次发射所属 Runtime epoch token（LRC._runtime_generation；本组件只原样存储，不校验 / 不解释）；
##   form 为本次发射的光形态（LightEmissionTypes.LightForm 数值；本组件只原样存储）。
## [br]返回：本次发射的 emission_id（>=1，单调递增；RAY/PARTICLE 共用同一 ID 空间）。
## [br]副作用：写 _emissions[emission_id] = { generation, form, runtime_ids: [] }；_next_emission_id += 1。
## [br]边界：不判 RunState、不查 scheduler、不建 Timer、不触视觉；allocate 本身永远成功（无拒绝路径），拒绝发射由 LRC 在 allocate 之前完成。
##   generation 与 emission_id 职责不同——allocate 只把 generation 原样记入 record 供下游诊断，不比较、不自增。
func allocate(generation: int, form: int) -> int:
	var emission_id: int = _next_emission_id
	_emissions[emission_id] = {
		"generation": generation,
		"form": form,
		"runtime_ids": [],
	}
	_next_emission_id += 1
	return emission_id


## 把一颗光粒 runtime_id 绑定到指定 emission（M4-E2；M4-E2.1 bind/rebind 原子一致性收口）；建立 emission_id→runtime_id 与 runtime_id→emission_id 双向索引。
## [br]由 LRC._begin_particle_emission 在 scheduler.emit_particle 成功后调用；同一 emission 可绑多个 runtime（未来一次 emission 多粒子）。
## [br]输入：emission_id 须为已 allocate 且仍活动的 emission；runtime_id 为 scheduler 分配的光粒身份。
## [br]原子一致性（M4-E2.1 三规则，任一不满足即零副作用拒绝）：
## [br]  - emission 未登记 → 拒绝（返回 false），不写任何映射；
## [br]  - runtime_id 已绑到**其它** emission（cross-emission rebind）→ 明确拒绝（返回 false），两侧映射完全不变
## [br]    （不覆盖 reverse、不在原 emission forward 留 stale、mark_finished 任一侧不删另一侧 reverse）；
## [br]  - 同 emission 重复 bind 同 runtime_id → 幂等（返回 true），不重复 append forward。
## [br]返回：成功绑定（含幂等重复 bind）返回 true；未登记 emission / cross-emission rebind 返回 false。
## [br]边界：本组件不报错（LRC 调用前已校验；runtime_id 为 scheduler 单调分配的新值，正常路径永不会 cross-emission）；去重与拒绝是本组件防御性职责。
func bind_particle_runtime(emission_id: int, runtime_id: int) -> bool:
	if not _emissions.has(emission_id):
		return false
	var existing: int = find_emission_for_runtime(runtime_id)
	if existing != 0:
		# runtime_id 已绑定：同 emission 幂等 true；跨 emission 明确拒绝（零副作用）。
		return existing == emission_id
	_emissions[emission_id]["runtime_ids"].append(runtime_id)
	_runtime_to_emission[runtime_id] = emission_id
	return true


## 反查一颗光粒 runtime_id 所属的 emission_id（M4-E2）。
## [br]返回：已绑定 runtime_id 的所属 emission_id；未绑定返回 0（emission_id 从 1 起，0 表“无所属”）。
## [br]边界：纯只读查询；不修改双向索引。
func find_emission_for_runtime(runtime_id: int) -> int:
	if not _runtime_to_emission.has(runtime_id):
		return 0
	return int(_runtime_to_emission[runtime_id])


## 解绑一颗光粒 runtime_id（M4-E2）；双向索引同删。
## [br]由 LRC._on_particle_terminated 在 Particle TERMINATE 上报后调用，用于把光粒移出其 emission 的 runtime 集合。
## [br]返回：被解绑 runtime 原属的 emission_id（便于 LRC 紧接着判定该 emission 是否已无 runtime）；
##   runtime_id 未绑定时返回 0（安全 no-op，不报错）。
## [br]副作用：删 _runtime_to_emission[runtime_id]；从 _emissions[emission_id]["runtime_ids"] 移除该 runtime_id。
## [br]边界：不 mark_finished emission——最后一个 runtime 解绑后 emission 是否结束由 LRC 据 get_emission_runtime_count 判定；
##   本组件不结算生命周期、不切 RunState、不触视觉。
func unbind_particle_runtime(runtime_id: int) -> int:
	if not _runtime_to_emission.has(runtime_id):
		return 0
	var emission_id: int = int(_runtime_to_emission[runtime_id])
	_runtime_to_emission.erase(runtime_id)
	if _emissions.has(emission_id):
		var runtimes: Array = _emissions[emission_id]["runtime_ids"]
		runtimes.erase(runtime_id)
	return emission_id


## 指定 emission 当前绑定的光粒 runtime 数量（M4-E2 只读诊断 / LRC 判定用）。
## [br]返回：emission_id 仍活动时返回其 runtime_ids 数量（RAY emission 恒为 0；PARTICLE emission = 已绑未解绑的光粒数）；
##   emission 未登记 / 已 finish 返回 0。
## [br]边界：纯只读；LRC 据本值 ==0 判定“该 PARTICLE emission 已无活动光粒，可 mark_finished”。
func get_emission_runtime_count(emission_id: int) -> int:
	if not _emissions.has(emission_id):
		return 0
	return _emissions[emission_id]["runtime_ids"].size()


## 标记指定 emission 结束（从活动表中移除并清理其 runtime 反向索引）；未登记的 emission_id 安全 no-op。
## [br]输入：emission_id 为 allocate 返回值。
## [br]副作用：erase _emissions[emission_id]（若存在）；同步清该 emission 残留 runtime 的反向索引（正常路径 PARTICLE emission finish 时 runtime 已全部解绑，此处为防御性兜底）；不回拨计数器。
## [br]边界：不结算生命周期——最后一个 emission 结束后 active_count==0 的事实由 LRC 读取 has_active 推进结算；本组件不决定 COMPLETED / MOVE_WINDOW。
func mark_finished(emission_id: int) -> void:
	if not _emissions.has(emission_id):
		return
	var runtimes: Array = _emissions[emission_id]["runtime_ids"]
	for runtime_id: Variant in runtimes:
		_runtime_to_emission.erase(runtime_id)
	_emissions.erase(emission_id)


## 指定 emission_id 是否仍活动（M4-E2 spec API；= _emissions.has(emission_id)）。
## [br]LRC._finish_emission 据本值短路已结束 / 未知 emission 的重复结算回调。
func is_active(emission_id: int) -> bool:
	return _emissions.has(emission_id)


## 当前活动 emission 数量（allocate 增、mark_finished 减、clear 归零）。
func active_count() -> int:
	return _emissions.size()


## 是否存在活动 emission（active_count > 0）；LRC 据此判定 PULSE_ACTIVE 是否仍有未结清的 emission。
func has_active() -> bool:
	return not _emissions.is_empty()


## 取指定 emission_id 的光形态（只读诊断 / 测试；未登记返回 -1）。
func get_form(emission_id: int) -> int:
	if not _emissions.has(emission_id):
		return -1
	return int(_emissions[emission_id]["form"])


## 取指定 emission_id 登记时的 generation（只读诊断 / 测试；未登记返回 -1）。
## [br]注意：本值为 allocate 时 LRC 传入的 epoch token 快照，非 gameplay generation 真值；真值唯一来源 LRC._runtime_generation。
func get_generation(emission_id: int) -> int:
	if not _emissions.has(emission_id):
		return -1
	return int(_emissions[emission_id]["generation"])


## 已累计分配的 emission 数量（只读诊断 / 测试；= _next_emission_id - 1，跨 clear 单调不回拨）。
## [br]用于证明 emission_id 单调递增、R 后不复用（clear 不重置计数器）。
func get_total_allocated() -> int:
	return _next_emission_id - 1


## 下一个将分配的 emission_id（只读诊断 / 测试；clear 不重置）。
func get_next_emission_id() -> int:
	return _next_emission_id


## 当前已绑定（未解绑）的光粒 runtime 总数（只读诊断 / 测试；= _runtime_to_emission.size()）。
## [br]用于证明 PARTICLE emission 与 runtime 的双向映射规模；不反映 scheduler 真实活动光粒数（真值 scheduler.get_active_count）。
func get_bound_runtime_count() -> int:
	return _runtime_to_emission.size()


## 全部活动 emission_id 列表（D7-R1 只读诊断；按 allocate 插入顺序）。
## [br]返回独立 Array[int] 副本：调用方修改返回值不影响 _emissions；不暴露内部 Dictionary。
## [br]边界：纯只读；R 后（clear）返回空数组；不排序、不去重（键唯一保证无重复）。
func get_active_emission_ids() -> Array[int]:
	var ids: Array[int] = []
	for key: Variant in _emissions.keys():
		ids.append(int(key))
	return ids


## 指定 emission 当前绑定的光粒 runtime_id 列表（D7-R1 只读诊断）。
## [br]返回独立 Array[int] 副本：调用方修改返回值不影响该 emission record 的 runtime_ids；
## [br]emission 未登记 / 已 finish 返回空数组；RAY emission 恒为空数组。
## [br]边界：纯只读；不 mark_finished、不解绑、不回拨。
func get_emission_runtime_ids(emission_id: int) -> Array[int]:
	var ids: Array[int] = []
	if not _emissions.has(emission_id):
		return ids
	for runtime_id: Variant in _emissions[emission_id]["runtime_ids"]:
		ids.append(int(runtime_id))
	return ids


## 清空全部活动 emission 与 runtime 反向索引（R 完整重置时由 LRC 调用）；计数器不回拨（R 后不复用 emission_id）。
## [br]副作用：_emissions.clear()；_runtime_to_emission.clear()；_next_emission_id 保持不变。
## [br]边界：不结算生命周期、不改 RunState、不触视觉；幂等（空表时只空遍历）。
func clear() -> void:
	_emissions.clear()
	_runtime_to_emission.clear()
