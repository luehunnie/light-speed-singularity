class_name RuntimeDiagnosticsSnapshotBuilder
extends RefCounted

## Runtime 只读诊断快照构造器（D7-R1）。
## 职责：把 LevelRuntimeController 私有的运行期事实（generation / 移动次数 / cooldown / 活动 emission /
##   绑定光粒 / Particle tick / Ray 段数）一次性组装为 detached 纯值 Dictionary，供 Diagnostics 侧
##   RuntimeSnapshotSampler 经只读 Callable 读取——Runtime 不依赖 Diagnostics，Diagnostics 不持有玩法 Node。
## 位置：gameplay/runtime 下（Runtime 侧只读出口，与 ray_emission_driver 同层）；纯静态构造器，无实例状态。
## 依赖：ActiveEmissionRegistry / EmitterFireCooldown / ParticleScheduler / LightVisualController（经 preload 类型引用，
##   只调用各自只读访问器）；不 preload 任何 Diagnostics 脚本、不访问场景树、不创建 Timer。
## 不负责（硬边界）：修改任何被读取组件的状态（不推进 Tick、不 finish emission、不重置 cooldown、不动视觉）、
##   序列化 JSON、写盘、水晶/库存/放置事实采集（由 Diagnostics 侧 Sampler 自行只读采集）、判断关卡完成。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ActiveEmissionRegistry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _EmitterFireCooldown: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_fire_cooldown.gd")
const _ParticleScheduler: GDScript = preload("res://gameplay/particle/particle_scheduler.gd")
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")


## 组装一份 detached 运行期事实快照（全部为纯值 / 独立数组副本，调用方修改不影响任何真值）。
## [br]输入：registry / cooldown / scheduler / light_visual_controller 为 LRC 持有的同一实例（只读访问器）；
##   generation / moves_used / moves_remaining / move_limit / allow_form_switch 为 LRC 当前标量事实。
## [br]返回 Dictionary，冻结键：runtime_generation、runtime_moves_used、runtime_moves_remaining、runtime_move_limit、
##   fire_cooldown_ready、allow_form_switch、total_emissions_allocated、active_emission_count、
##   emissions（[{emission_id, generation, form, runtime_ids: Array[int]}]）、
##   particles（[{runtime_id, emission_id, generation, cell, direction, speed_tier, step_started_tick, next_move_tick, active}]）、
##   particle_tick、particle_active_count、ray_segment_count。
## [br]副作用：无——只调用各组件只读访问器与 scheduler.get_particle_state_snapshot（其自身保证 detached 值副本）；
##   不推进 Tick、不 mark_finished、不消费 / 重置 cooldown、不改视觉。
## [br]边界：光粒枚举经 registry 的 emission→runtime_ids 映射（与 scheduler 活动索引一致——bind/unbind 与
##   光粒移出严格同步）；未知字段不出现，键集合唯一由本函数冻结。
static func build(
		registry: _ActiveEmissionRegistry,
		cooldown: _EmitterFireCooldown,
		scheduler: _ParticleScheduler,
		light_visual_controller: _LightVisualController,
		generation: int,
		moves_used: int,
		moves_remaining: int,
		move_limit: int,
		allow_form_switch: bool
) -> Dictionary:
	var emissions: Array = []
	var particles: Array = []
	# 活动枚举按 allocate 插入顺序（registry Dictionary 键序）；runtime_ids 已是独立副本。
	for emission_id: int in registry.get_active_emission_ids():
		var runtime_ids: Array[int] = registry.get_emission_runtime_ids(emission_id)
		emissions.append({
			"emission_id": emission_id,
			"generation": registry.get_generation(emission_id),
			"form": registry.get_form(emission_id),
			"runtime_ids": runtime_ids,
		})
		# 每颗绑定光粒取 scheduler detached 八字段快照，附加 emission_id 关联（纯值拷贝）。
		for runtime_id: int in runtime_ids:
			var particle: Variant = scheduler.get_particle_state_snapshot(runtime_id)
			if particle == null:
				# 防御：bind/unbind 与光粒移出应严格同步，理论不可达；跳过不中断采样。
				continue
			var record: Dictionary = {}
			for key: String in particle.keys():
				record[key] = particle[key]
			record["emission_id"] = emission_id
			particles.append(record)
	return {
		"runtime_generation": generation,
		"runtime_moves_used": moves_used,
		"runtime_moves_remaining": moves_remaining,
		"runtime_move_limit": move_limit,
		"fire_cooldown_ready": cooldown.is_ready(),
		"allow_form_switch": allow_form_switch,
		"total_emissions_allocated": registry.get_total_allocated(),
		"active_emission_count": registry.active_count(),
		"emissions": emissions,
		"particles": particles,
		"particle_tick": scheduler.get_current_tick(),
		"particle_active_count": scheduler.get_active_count(),
		"ray_segment_count": light_visual_controller.get_segment_count(),
	}
