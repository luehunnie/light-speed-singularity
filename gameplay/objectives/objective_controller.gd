class_name ObjectiveController
extends RefCounted

## 关卡目标完成事实唯一所有者（D3-D；AF-04 / P0-6 起统一完成状态）。
## 职责：按 cell 激活普通独立水晶、判断当前目标是否全部完成、运行期重置水晶与完成事实；
##   绑定 ObjectiveModel 后按 Target + Condition + Group 统一完成状态（Guide B §25.4）：
##   apply_hit 走模型路由，is_completed 折算全部 Required 完成；未绑定时保持 D3-D 水晶激活语义不变。
## 依赖 LevelObjectRegistry（水晶按显式 crystal_id 与 cell 双向索引）；每次需要集合时通过 Registry 只读副本取得，不保存第二套水晶数组快照。
## 不负责运行状态机、pulse_generation、光线传播、光路视觉、库存/放置/拖拽、发射器、UI、Diagnostics、场景树；五态（SETUP/READY_TO_FIRE/PULSE_ACTIVE/MOVE_WINDOW/COMPLETED）仍由运行状态控制器唯一持有，本类不调用其接口。
## 完成规则（水晶原型路径）：Registry 无水晶时永远未完成（空集合不误判完成）；所有已登记水晶激活后完成；任一未激活则未完成；重复激活安全无副作用；reset_runtime 后完成事实归 false。
## 时间 seam：统一状态依赖窗口超时判定，时间戳经可注入 Callable 取得（测试可控，正式取引擎毫秒钟）。
## AF-04 刻意不接线（同 AF-02/03 先例）：Ray/Particle 驱动器仍走 try_activate_crystal_at 原型路径；
##   命中事实改经 ObjectiveHitContext + apply_hit 的接线留 GUI 验收批次。


# 用 preload 引用 LevelObjectRegistry 类型，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _ObjectiveModel: GDScript = preload("res://gameplay/objectives/objective_model.gd")
const _ObjectiveHitContext: GDScript = preload("res://gameplay/objectives/objective_hit_context.gd")


## 关卡稳定对象索引（引用，调用方保证生命周期）。
var _registry: _LevelObjectRegistry

## 目标运行时模型（null = 未绑定，走水晶原型路径）。
var _objective_model: _ObjectiveModel = null

## 时间 seam（()->float 秒；默认空 Callable 表示取引擎毫秒钟）。测试注入可控时间源。
var _time_now: Callable


## 构造目标控制器；只持有 Registry 引用，不复制水晶集合。time_now 可选注入时间 seam。
func _init(registry: _LevelObjectRegistry, time_now: Callable = Callable()) -> void:
	_registry = registry
	_time_now = time_now


## 绑定统一目标模型（Target + Condition + Group）；绑定后 apply_hit / is_completed 走模型统一完成状态。
func set_objective_model(objective_model: _ObjectiveModel) -> void:
	_objective_model = objective_model


## 是否已绑定统一目标模型。
func has_objective_model() -> bool:
	return _objective_model != null


## 应用一次目标命中事实（Guide B §25.1 ObjectiveHitContext）。
## [br]已绑定模型：按格路由求值（条件 AND / Base Success），通过则登记成功并通报所属组，返回是否通过。
## [br]未绑定模型：等价水晶原型路径（Base Success 语义），委托 try_activate_crystal_at。
func apply_hit(hit: Variant) -> bool:
	var hit_context: _ObjectiveHitContext = hit as _ObjectiveHitContext
	if hit_context == null:
		return false
	if _objective_model == null:
		return try_activate_crystal_at(hit_context.get_cell())
	return _objective_model.apply_hit(hit_context, _now_seconds())


## 当前时间秒（时间 seam 优先；未注入取引擎毫秒钟）。
func _now_seconds() -> float:
	if _time_now.is_valid():
		return float(_time_now.call())
	return Time.get_ticks_msec() / 1000.0


## 尝试激活指定格上的普通独立水晶；该格无水晶时安全无效果，不破坏状态。
## [br]返回 true 表示该格存在水晶且激活请求被接受（已激活水晶重复命中也返回 true，activate() 自身幂等）；返回 false 表示该格无水晶。
## [br]不以此返回值表示关卡是否完成，完成事实单独由 is_completed() 读取。
func try_activate_crystal_at(cell: Vector2i) -> bool:
	var crystal: BasicCrystal = _registry.get_crystal_at(cell)
	if crystal == null:
		return false
	crystal.activate()
	return true


## 重置所有已登记水晶为未点亮；完成事实因水晶全部未点亮而自然恢复为 false（is_completed() 将返回 false）。
## [br]已绑定模型时同步重置模型（目标成功记录 / 组步数 / 锁定全部归零）。重复调用安全。
func reset_runtime() -> void:
	for crystal: BasicCrystal in _registry.get_all_crystals():
		crystal.reset_runtime()
	if _objective_model != null:
		_objective_model.reset_runtime()


## 当前目标是否全部完成；Registry 无水晶时返回 false（空集合不误判完成），所有已登记水晶激活后返回 true。
## [br]已绑定模型时改由模型统一判定：全部 Required（独立目标 + 组）完成即完成，Optional 不阻挡。
func is_completed() -> bool:
	if _objective_model != null:
		return _objective_model.is_complete(_now_seconds())
	var crystals: Array[BasicCrystal] = _registry.get_all_crystals()
	if crystals.is_empty():
		return false
	for crystal: BasicCrystal in crystals:
		if not crystal.is_activated:
			return false
	return true


## 必需水晶数量（Registry 中已登记水晶总数）；空 Registry 返回 0。
func get_required_count() -> int:
	return _registry.get_crystal_count()


## 当前已激活水晶数量；每次按 Registry 只读副本统计，不缓存。
func get_activated_count() -> int:
	var count: int = 0
	for crystal: BasicCrystal in _registry.get_all_crystals():
		if crystal.is_activated:
			count += 1
	return count
