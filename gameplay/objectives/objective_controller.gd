class_name ObjectiveController
extends RefCounted

## 关卡目标完成事实唯一所有者（D3-D）。
## 职责：按 cell 激活普通独立水晶、判断当前目标是否全部完成、运行期重置水晶与完成事实。
## 依赖 LevelObjectRegistry（水晶按显式 crystal_id 与 cell 双向索引）；每次需要集合时通过 Registry 只读副本取得，不保存第二套水晶数组快照。
## 不负责运行状态机、pulse_generation、光线传播、光路视觉、库存/放置/拖拽、发射器、UI、Diagnostics、场景树；四态仍由运行状态控制器唯一持有，本类不调用其接口。
## 完成规则：Registry 无水晶时永远未完成（空集合不误判完成）；所有已登记水晶激活后完成；任一未激活则未完成；重复激活安全无副作用；reset_runtime 后完成事实归 false。


# 用 preload 引用 LevelObjectRegistry 类型，避开 MCP run_project 不重建全局 class_name 缓存的问题。
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")


## 关卡稳定对象索引（引用，调用方保证生命周期）。
var _registry: _LevelObjectRegistry


## 构造目标控制器；只持有 Registry 引用，不复制水晶集合。
func _init(registry: _LevelObjectRegistry) -> void:
	_registry = registry


## 尝试激活指定格上的普通独立水晶；该格无水晶时安全无效果，不破坏状态。
## [br]返回 true 表示该格存在水晶且激活请求被接受（已激活水晶重复命中也返回 true，activate() 自身幂等）；返回 false 表示该格无水晶。
## [br]不以此返回值表示关卡是否完成，完成事实单独由 is_completed() 读取。
func try_activate_crystal_at(cell: Vector2i) -> bool:
	var crystal: BasicCrystal = _registry.get_crystal_at(cell)
	if crystal == null:
		return false
	crystal.activate()
	return true


## 重置所有已登记水晶为未点亮；完成事实因水晶全部未点亮而自然恢复为 false（is_completed() 将返回 false）。重复调用安全。
func reset_runtime() -> void:
	for crystal: BasicCrystal in _registry.get_all_crystals():
		crystal.reset_runtime()


## 当前目标是否全部完成；Registry 无水晶时返回 false（空集合不误判完成），所有已登记水晶激活后返回 true。
func is_completed() -> bool:
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
