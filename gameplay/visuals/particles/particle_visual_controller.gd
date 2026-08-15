class_name ParticleVisualController
extends RefCounted

## Particle 视觉控制器（D7-4 B4a 起；B4b-2 加 Tween 生命周期与 authoritative timing）。
## 职责：接收 detached EMITTED / TICK_BATCH_COMMITTED / CLEARED 事件，维护 runtime_id→视觉 record 的纯视觉映射。
##   每条 record = { generation, view, tween, serial, last_completed_serial, target_cell, duration_seconds }。
##   按 authoritative timing（事件携带的 next_move_tick - tick）经共享 ParticleTickTiming.TICK_SECONDS 换算 Tween 现实时长，
##   在 EMITTED 立即起第一段视觉传播、MOVE commit 校准 entered_cell 并起下一段、TERMINATE/CLEARED/generation advance 取消并清理。
##   本控制器是 Particle gameplay→visual 的唯一视觉所有者；事件 payload 由 ParticleVisualEvent 纯构造器产出，
##   本控制器只解释 detached 值数据，绝不反向触及 gameplay（duration_ticks 全来自事件 next_move_tick，绝不自行重算 Tick）。
## 位置：gameplay/visuals/particles 下；与 LightVisualController 平行，完整拥有光粒视觉节点集合与 Tween 生命周期。
## 依赖：ParticleView 场景与脚本（含 begin_propagation_tween 视觉 Tween helper）、ParticleVisualEvent（事件类型/outcome 常量）、
##   ParticleTickTiming（gameplay/core 共享 0.1s cadence——与 ParticleTickPump await 间隔共用同一 0.1 字面量，不形成两份独立常量）；
##   不 preload gameplay/particle 调度器 / 光粒运行期状态 / 步执行器 / 运动规则 / world query / Objective / RunState。
## 不负责（硬边界——本控制器绝不做以下任何一项）：
##   - 修改光粒 gameplay 状态、调用调度器、发起发射、操作目标、推进整数 Tick、推导运行状态、读取光粒内部 raw 状态；
##   - 调用运动规则 / 自行重算 ticks；本控制器的 runtime_id→record 映射只是视觉所有权，不是 gameplay truth——映射的存在/顺序不反映调度器活动光粒真值。
## 边界条件：事件 payload 皆为 detached 值 Dictionary（外部修改零影响 gameplay）；EMITTED 按 runtime_id 去重（重复 event 不产生双 View）。
##   TICK_BATCH_COMMITTED 按 events 顺序逐条处理：MOVE → kill 旧 Tween + 校准 entered_cell + 起下一段（duration_ticks = event.next_move_tick - envelope.tick）；
##   TERMINATE → kill Tween + 不 set entered_cell（entered_cell 是未进入的阻挡格，不 snap 到非法格中心）+ 删 View；
##   CLEARED → kill 全部 Tween + 全清 View（仅 new_generation > watermark 时）。
##   M4-E4 墙体边界消失：MOVE / EMITTED 携带 next_step_blocked=true（事件内确定性前瞻：离开方向下一格为墙 / 越界）时，
##   本段插值不走满格——改走半程边界 Tween（目标 = 本格与阻挡格中心连线中点即格边界面，duration = 半步 authoritative 时长），
##   Tween finished（== 接触边界时刻）立即删 View；光粒绝不插值到墙格中心。gameplay TERMINATE 仍在整步结束 Tick commit（整数 Tick 真值不变），
##   届时 _remove_view 对已删 record 安全 no-op；stale 四重守卫同样约束该删除（generation / rid / view / serial 全匹配才删）。
##   Tween ownership/token：每次新 Tween serial+=1；Tween finished 回调经四重守卫（generation 仍匹配 / rid 仍登记 / view 仍同一实例 / serial 仍当前版本）
##     才更新 last_completed_serial；stale finished（已被 replace / clear / generation advance 取代）一律 no-op；
##     finished 永不推进 gameplay / 改 cell truth / 激活水晶 / 结束 pulse——它最多更新一个视觉 ledger 字段。
##   stale 完成防护的现实保证：replace / TERMINATE / CLEAR / generation advance 均先 kill 旧 Tween（kill 后 finished 不再触发），serial 守卫为同帧竞态的二级防线。
##   D7-4 B4b-1 MF-2 generation high-watermark 语义保留（纯 visual event version filter，不调 gameplay 查询确认 generation）：
##   EMITTED gen<watermark 忽略（不复活旧 View）；gen>watermark 推进 watermark + 清旧 View 后创建；gen==watermark 正常创建（同 gen 多粒合法、runtime_id 仍去重）。
##   TICK envelope.gen!=watermark 整批忽略；nested event.gen!=envelope.gen 忽略该 event；MOVE/TERMINATE 还要求 record.generation 与事件 generation 匹配。
##   CLEARED new>watermark 推进 + 清旧 View；new<=watermark 视为 stale/duplicate，不清当前较新 View。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ParticleViewScript: GDScript = preload("res://gameplay/visuals/particles/particle_view.gd")
const _ParticleViewScene: PackedScene = preload("res://gameplay/visuals/particles/particle_view.tscn")
const _ParticleVisualEvent: GDScript = preload("res://gameplay/visuals/particles/particle_visual_event.gd")
# 0.1 秒现实 cadence 单一来源（与 ParticleTickPump 共用同一字面量）；visual 据此把 authoritative duration_ticks 换算为 Tween 现实时长。
const _ParticleTickTiming: GDScript = preload("res://gameplay/core/particle_tick_timing.gd")


# 视觉父节点：所有 ParticleView add_child 到此（与光路视觉同层）。控制器是唯一向该父节点添加光粒视觉的所有者。
var _visual_parent: Node = null
# runtime_id -> 视觉 record Dictionary（generation / view / tween / serial / last_completed_serial / target_cell / duration_seconds）。
# 仅视觉所有权，非 gameplay truth；清理时先 kill Tween + queue_free View 再清空，重复清理安全。
var _records: Dictionary = {}
# 视觉 generation high-watermark（D7-4 B4b-1 MF-2）：纯 visual event version filter，非 gameplay generation 真值。
# 初始 -1 = 未见过任何事件；首事件到来时初始化；EMITTED future-gen / CLEARED new>current 推进并清旧 View。
var _current_visual_generation: int = -1


## 构造控制器：注入视觉父节点（场景中的 LightPathLayer 或等价 Node）。控制器自持映射，不持有 gameplay 引用。
func _init(visual_parent: Node) -> void:
	_visual_parent = visual_parent


## 处理一个 detached 事件：按 type 分发到 EMITTED / TICK_BATCH_COMMITTED / CLEARED。
## [br]输入：event 为 ParticleVisualEvent.build_* 产出的 detached Dictionary。
## [br]副作用：按类型创建/更新/移除 View 与 Tween；不读 gameplay、不调 scheduler/Objective/RunState。
## [br]边界：未知 type 安全忽略（不报错，不改动现有 View）。
func handle_event(event: Dictionary) -> void:
	var event_type: String = event.get("type", "")
	match event_type:
		_ParticleVisualEvent.TYPE_EMITTED:
			_on_emitted(event)
		_ParticleVisualEvent.TYPE_TICK_BATCH_COMMITTED:
			_on_tick_committed(event)
		_ParticleVisualEvent.TYPE_CLEARED:
			_on_cleared(event)
		_:
			pass


## EMITTED：创建一个 ParticleView（runtime_id 去重——重复 event 不产生双 View），校准到 emitter cell，立即起第一段视觉传播 Tween。
## [br]D7-4 B4b-1 MF-2 generation high-watermark：gen<watermark 忽略；gen>watermark 推进 watermark + 清旧 View 后创建；gen==watermark 正常创建。
## [br]D7-4 B4b-2：第一段 Tween duration_ticks = event.next_move_tick - event.step_started_tick，视觉目标格 = cell + direction（纯视觉几何）。
func _on_emitted(event: Dictionary) -> void:
	var event_generation: int = event["generation"]
	var runtime_id: int = event["runtime_id"]
	# stale：旧 generation EMITTED 忽略（不复活已被新 generation 取代的旧 View）。首次（watermark==-1）不触发。
	if _current_visual_generation != -1 and event_generation < _current_visual_generation:
		return
	# future：新 generation EMITTED 推进 watermark 并清旧 View（旧 generation 全部 View + Tween 释放）。
	if event_generation > _current_visual_generation:
		_advance_generation(event_generation)
	# 此处 event_generation == _current_visual_generation（含首次初始化）。同 generation 内 runtime_id 去重。
	if _records.has(runtime_id):
		return
	var view: _ParticleViewScript = _ParticleViewScene.instantiate()
	if not is_instance_valid(view):
		push_error("ParticleVisualController: ParticleView 实例化失败 @ runtime_id=%d" % runtime_id)
		return
	var cell: Vector2i = event["cell"]
	var direction: Vector2i = event["direction"]
	view.configure(cell, direction)
	_visual_parent.add_child(view)
	_records[runtime_id] = {
		"generation": event_generation,
		"view": view,
		"tween": null,
		"serial": 0,
		"last_completed_serial": 0,
		"target_cell": cell,
		"duration_seconds": 0.0,
		"boundary_stop": false,
		"remove_on_finish": false,
	}
	# 立即起第一段视觉传播（duration_ticks 来自 authoritative next_move_tick - step_started_tick）。
	var duration_ticks: int = int(event["next_move_tick"]) - int(event["step_started_tick"])
	# M4-E4：发射前方格已确定性为墙 / 越界 → 半程边界 Tween + 接触即删（不 Tween 到墙格中心）。
	if bool(event.get("next_step_blocked", false)):
		_start_boundary_approach(runtime_id, cell, direction, duration_ticks)
	else:
		_start_propagation(runtime_id, cell, direction, duration_ticks)


## TICK_BATCH_COMMITTED：按 events 顺序逐条处理。
## [br]MOVE → kill 旧 Tween + 校准 entered_cell + 起下一段；TERMINATE → kill Tween + 不 snap 非法格 + 删 View。
## [br]D7-4 B4b-1 MF-2：envelope.generation != watermark 整批忽略；nested event.generation != envelope.generation 忽略该 event。
func _on_tick_committed(event: Dictionary) -> void:
	var envelope_generation: int = event.get("generation", -1)
	# envelope generation 不匹配当前 watermark → 整批忽略（旧 generation TICK 不动新 View/Tween）。
	if envelope_generation != _current_visual_generation:
		return
	var envelope_tick: int = int(event.get("tick", 0))
	var events: Array = event.get("events", [])
	for detached_event in events:
		# nested event generation 与 envelope 不一致 → 忽略该 event（防 envelope 正确但 nested 错位）。
		if int(detached_event.get("generation", -1)) != envelope_generation:
			continue
		var runtime_id: int = detached_event["runtime_id"]
		var outcome: String = detached_event["outcome"]
		if outcome == _ParticleVisualEvent.OUTCOME_MOVE:
			_update_view_for_move(runtime_id, detached_event, envelope_generation, envelope_tick)
		elif outcome == _ParticleVisualEvent.OUTCOME_TERMINATE:
			_remove_view(runtime_id, envelope_generation)


## MOVE：校准对应 runtime_id 的 View 到 committed entered_cell，更新 rotation，并起下一段视觉传播 Tween。
## [br]处理顺序：① kill 当前旧 Tween；② set_cell(entered_cell) 校准；③ set_direction 更新 rotation；④ 起 next Tween（duration = next_move_tick - envelope.tick）。
## [br]视觉不等待下一次 MOVE 才播放上一段——校准后立即起下一段，视觉误差不在 commit 间累计。
## [br]未登记的 runtime_id（如 R 后残留 / 未收到 EMITTED）安全忽略，不创建 View。
## [br]D7-4 B4b-1 MF-2：record.generation 必须与事件 generation 匹配——stale MOVE 不得动新 View。
func _update_view_for_move(runtime_id: int, detached_event: Dictionary, expected_generation: int, envelope_tick: int) -> void:
	if not _records.has(runtime_id):
		return
	# 登记 record 的 generation 必须匹配事件 generation（防 stale MOVE 动新 View）。
	if int(_records[runtime_id].get("generation", -1)) != expected_generation:
		return
	var view: _ParticleViewScript = _records[runtime_id]["view"]
	if not is_instance_valid(view):
		_kill_record_tween(_records[runtime_id])
		_records.erase(runtime_id)
		return
	var entered_cell: Vector2i = detached_event["entered_cell"]
	var direction: Vector2i = detached_event["direction"]
	# 校准到 committed cell（snap 锚点；随后 Tween 从此格向下一格传播，误差不累计）。
	view.set_cell(entered_cell)
	view.set_direction(direction)
	# 起下一段：duration_ticks = authoritative next_move_tick - envelope.tick（kill 旧 Tween 在 _start_propagation 首行完成）。
	var duration_ticks: int = int(detached_event["next_move_tick"]) - envelope_tick
	# M4-E4：离开方向下一格已确定性为墙 / 越界 → 半程边界 Tween + 接触即删（不 Tween 到墙格中心）。
	if bool(detached_event.get("next_step_blocked", false)):
		_start_boundary_approach(runtime_id, entered_cell, direction, duration_ticks)
	else:
		_start_propagation(runtime_id, entered_cell, direction, duration_ticks)


## 删除指定 runtime_id 的 View（TERMINATE）；未登记或已释放则安全 no-op。
## [br]TERMINATE 的 entered_cell 是尝试但未真正进入的非法/墙体格——故不 set_cell(entered_cell)、不把 View snap 到非法格中心。
## [br]D7-4 B4b-1 MF-2：record.generation 必须与事件 generation 匹配——stale TERMINATE 不得删新 View。
func _remove_view(runtime_id: int, expected_generation: int) -> void:
	if not _records.has(runtime_id):
		return
	if int(_records[runtime_id].get("generation", -1)) != expected_generation:
		return
	_kill_record_tween(_records[runtime_id])
	var view: _ParticleViewScript = _records[runtime_id]["view"]
	if is_instance_valid(view):
		view.queue_free()
	_records.erase(runtime_id)


## CLEARED 事件入口（D7-4 B4b-1 MF-2）：仅 new_generation > current_visual_generation 时推进 watermark 并清旧 View + kill 全部 Tween。
## [br]new_generation <= current_visual_generation 视为 stale / duplicate clear——不清当前较新 generation 的 View/Tween。
func _on_cleared(event: Dictionary) -> void:
	var new_generation: int = event["new_generation"]
	if new_generation <= _current_visual_generation:
		return
	_advance_generation(new_generation)


## 推进 visual generation high-watermark：释放全部旧 View + kill 全部 Tween、清空映射、写新 watermark。
## [br]由 EMITTED future-gen 与 CLEARED new>current 两条路径调用；调用后 watermark == new_generation。
func _advance_generation(new_generation: int) -> void:
	_free_all_views()
	_current_visual_generation = new_generation


## 公共全清入口：释放全部 Particle View + kill 全部 Tween 并清空映射（幂等——空映射时只空遍历）。
## [br]不修改水晶/完成状态/库存/占用/运行状态/scheduler；不重置 watermark（watermark 仅由事件驱动 _advance_generation）。
func clear_all() -> void:
	_free_all_views()


## 释放全部 Particle View + kill Tween 并清空 _records（内部共享；不触碰 watermark）。
func _free_all_views() -> void:
	for runtime_id in _records:
		_kill_record_tween(_records[runtime_id])
		var view: _ParticleViewScript = _records[runtime_id]["view"]
		if is_instance_valid(view):
			view.queue_free()
	_records.clear()


# ===== Tween 生命周期（视觉层统一取消入口；不复制 kill 逻辑） =====

## 起一段视觉传播 Tween：kill 旧 Tween、serial+=1、算目标格与时长、经 View 创建绑定 Tween、登记并连 finished 守卫回调。
## [br]输入：runtime_id 须已登记；from_cell 为本段起始格（已校准的 cell）；direction 决定目标格 = from_cell + direction（纯视觉几何，不创建 gameplay state）；
##   duration_ticks 来自 authoritative timing（EMITTED: next_move_tick - step_started_tick；MOVE: next_move_tick - envelope.tick）。
## [br]副作用：kill record 旧 Tween；写 record.serial/target_cell/duration_seconds/tween；连 Tween.finished（回调内 4 重守卫）。
## [br]边界：不调运动规则、不读 gameplay；duration_ticks<=0 时 duration_seconds=0（Tween 零时长即 snap 到目标，无累计误差）。
func _start_propagation(runtime_id: int, from_cell: Vector2i, direction: Vector2i, duration_ticks: int) -> void:
	var record: Dictionary = _records[runtime_id]
	_kill_record_tween(record)
	record["serial"] = int(record["serial"]) + 1
	var started_serial: int = int(record["serial"])
	var target_cell: Vector2i = from_cell + direction
	var duration_seconds: float = maxi(duration_ticks, 0) * _ParticleTickTiming.TICK_SECONDS
	record["target_cell"] = target_cell
	record["duration_seconds"] = duration_seconds
	# 正常满格传播：清 M4-E4 边界截断标记（record 跨 Tween 复用，防止上一段边界态泄漏到本段）。
	record["boundary_stop"] = false
	record["remove_on_finish"] = false
	var view: _ParticleViewScript = record["view"]
	if not is_instance_valid(view):
		return
	var tween: Tween = view.begin_propagation_tween(target_cell, duration_seconds)
	record["tween"] = tween
	if tween != null:
		# 连 finished：绑定 rid / 起始 view 实例 / 起始 serial / 起始 generation；回调内 4 重守卫确认仍是当前 Tween 才记 ledger。
		tween.finished.connect(Callable(self, "_on_tween_finished").bind(
			runtime_id, view, started_serial, int(record["generation"])))


## 起一段 M4-E4 半程边界 Tween（下一格确定性墙 / 越界时替代满格传播）。
## [br]kill 旧 Tween、serial+=1、目标 = from_cell 与 from_cell+direction 两格中心连线中点（格边界面）；
##   duration = authoritative 半步时长（满格 center→center Tween 线性，跨格边界恰在半时长点）；
##   标记 remove_on_finish=true——Tween finished（接触边界时刻）经 _on_tween_finished 四重守卫后立即删 View。
## [br]不调运动规则、不读 gameplay；同帧竞态下若 finished 先于本函数登记被 kill，kill 保证不触发（serial 守卫兜底）。
func _start_boundary_approach(runtime_id: int, from_cell: Vector2i, direction: Vector2i, duration_ticks: int) -> void:
	var record: Dictionary = _records[runtime_id]
	_kill_record_tween(record)
	record["serial"] = int(record["serial"]) + 1
	var started_serial: int = int(record["serial"])
	var duration_seconds: float = maxi(duration_ticks, 0) * _ParticleTickTiming.TICK_SECONDS * 0.5
	record["target_cell"] = from_cell + direction
	record["duration_seconds"] = duration_seconds
	record["boundary_stop"] = true
	record["remove_on_finish"] = true
	var view: _ParticleViewScript = record["view"]
	if not is_instance_valid(view):
		return
	var tween: Tween = view.begin_boundary_tween(from_cell, direction, duration_seconds)
	record["tween"] = tween
	if tween != null:
		tween.finished.connect(Callable(self, "_on_tween_finished").bind(
			runtime_id, view, started_serial, int(record["generation"])))


## 视觉层统一取消入口：kill record 当前 Tween 并清空引用（幂等；serial 不回退，作为历史 ledger）。
## [br]kill 后 Tween.finished 不再触发，保证 stale completion 在源头无法发生；serial 守卫为同帧竞态二级防线。
func _kill_record_tween(record: Dictionary) -> void:
	var tween: Tween = record.get("tween", null)
	if tween != null:
		tween.kill()
	record["tween"] = null


## Tween.finished 回调（4 重守卫）：generation 仍匹配 / rid 仍登记 / view 仍同一实例 / serial 仍当前版本，全满足才记 last_completed_serial。
## [br]任一不满足 → no-op（stale 完成被 replace / clear / generation advance 取代）。永不推进 gameplay / 改 cell truth。
## [br]本回调为视觉 ledger 收尾的唯一副作用——仅写 last_completed_serial，供测试与诊断确认当前 Tween 是否自然完成。
func _on_tween_finished(
		runtime_id: int,
		view_at_start: _ParticleViewScript,
		started_serial: int,
		generation_at_start: int
) -> void:
	if not _records.has(runtime_id):
		return
	var record: Dictionary = _records[runtime_id]
	if int(record.get("generation", -1)) != generation_at_start:
		return
	if record.get("view", null) != view_at_start:
		return
	if int(record.get("serial", -1)) != started_serial:
		return
	if not is_instance_valid(view_at_start):
		return
	record["last_completed_serial"] = started_serial
	# M4-E4 墙体边界消失：半程边界 Tween 自然完成（== 接触边界时刻）→ 立即删 View（四重守卫已全过）。
	# gameplay TERMINATE 仍在整步结束 Tick commit，届时 _remove_view 对已删 record 安全 no-op——运行体 / 视觉均不进墙格中心。
	if bool(record.get("remove_on_finish", false)):
		_remove_view(runtime_id, generation_at_start)


# ===== 只读访问器（供测试与诊断） =====

## 当前持有的 Particle View 数量（只读快照；非 gameplay 真值）。
func get_view_count() -> int:
	return _records.size()


## 是否存在指定 runtime_id 的 View（只读）。
func has_view(runtime_id: int) -> bool:
	return _records.has(runtime_id)


## 取指定 runtime_id 的 View 节点（只读；未登记返回 null）。不暴露可写字典。
func get_view(runtime_id: int) -> Node:
	if not _records.has(runtime_id):
		return null
	return _records[runtime_id]["view"]


## 当前 visual generation high-watermark（只读诊断 / 测试；非 gameplay generation 真值；初始 -1 = 未见过事件）。
func get_current_visual_generation() -> int:
	return _current_visual_generation


## 指定 runtime_id 登记 record 的 generation（只读诊断 / 测试；未登记返回 -1）。
func get_view_generation(runtime_id: int) -> int:
	if not _records.has(runtime_id):
		return -1
	return int(_records[runtime_id]["generation"])


## 指定 runtime_id 当前 Tween（只读诊断 / 测试；未登记或已 kill 返回 null）。
func get_view_tween(runtime_id: int) -> Tween:
	if not _records.has(runtime_id):
		return null
	return _records[runtime_id].get("tween", null)


## 指定 runtime_id 当前 Tween serial/token（只读诊断 / 测试；每次新 Tween +1，未登记返回 -1）。
func get_view_tween_serial(runtime_id: int) -> int:
	if not _records.has(runtime_id):
		return -1
	return int(_records[runtime_id].get("serial", -1))


## 指定 runtime_id 当前 Tween 的视觉目标格（只读诊断 / 测试；未登记返回 Vector2i(-1,-1)）。
func get_view_tween_target_cell(runtime_id: int) -> Vector2i:
	if not _records.has(runtime_id):
		return Vector2i(-1, -1)
	return _records[runtime_id].get("target_cell", Vector2i(-1, -1))


## 指定 runtime_id 当前 Tween 的现实时长秒（只读诊断 / 测试；未登记返回 -1.0）。
func get_view_tween_duration_seconds(runtime_id: int) -> float:
	if not _records.has(runtime_id):
		return -1.0
	return float(_records[runtime_id].get("duration_seconds", -1.0))


## 指定 runtime_id 最近一次通过 4 重守卫自然完成的 Tween serial（只读诊断 / 测试；未登记或从未完成返回 -1）。
func get_view_last_completed_serial(runtime_id: int) -> int:
	if not _records.has(runtime_id):
		return -1
	return int(_records[runtime_id].get("last_completed_serial", -1))


## 指定 runtime_id 当前 Tween 是否为 M4-E4 半程边界截断（只读诊断 / 测试；未登记返回 false）。
func is_view_boundary_stop(runtime_id: int) -> bool:
	if not _records.has(runtime_id):
		return false
	return bool(_records[runtime_id].get("boundary_stop", false))


## 指定 runtime_id 当前 Tween 是否标记完成即删 View（只读诊断 / 测试；未登记返回 false）。
func is_view_remove_on_finish(runtime_id: int) -> bool:
	if not _records.has(runtime_id):
		return false
	return bool(_records[runtime_id].get("remove_on_finish", false))
