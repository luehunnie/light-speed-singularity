extends RefCounted

## 光粒调度 / 执行测试专用等价只读 world query（D7-4 B2 fixtures）。
## 职责：为 ParticleStepExecutor / ParticleScheduler 的定向测试提供一个不依赖场景树 / Node / BasicCrystal 的等价只读世界查询，
##   实现 executor / scheduler 所要求的四个只读方法契约：is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at。
##   方法签名与正式运行使用的 LightWorldQuery 完全一致，正式运行由 LightWorldQuery 提供同契约方法，本 fixture 仅服务测试。
## 位置：tests/unit/particle/fixtures/ 下；不进场景树、不设为 Autoload、无 class_name（不污染全局 class 注册）。
## 依赖：零游戏脚本依赖；仅用 Rect2i 边界 + Dictionary 配置 wall / crystal / mechanism。
## 不负责：真实 Terrain / Wall TileMapLayer、LevelObjectRegistry、OccupancyRegistry、水晶点亮、机关状态机、视觉。
## 边界条件：is_in_bounds 以 _bounds.has_point 判定（默认 32×32 居中矩形，可 set_bounds 覆盖）；
##   wall / crystal / mechanism 三张字典按格配置；get_light_mechanism_at 未配置格返回 null。


## 当前边界矩形（默认居中 32×32）。
var _bounds: Rect2i = Rect2i(-16, -16, 32, 32)
## 墙体格集合。
var _walls: Dictionary = {}
## 水晶格集合（仅标记存在，不点亮）。
var _crystals: Dictionary = {}
## 机关格映射：cell -> 任意实现机关公开能力的对象（如 FakeSpeedMechanism）。
var _mechanisms: Dictionary = {}


## 覆盖边界矩形。
func set_bounds(b: Rect2i) -> void:
	_bounds = b


## 登记一格为墙体。
func add_wall(cell: Vector2i) -> void:
	_walls[cell] = true


## 登记一格为水晶格（仅存在性标记）。
func add_crystal(cell: Vector2i) -> void:
	_crystals[cell] = true


## 登记一格的机关对象。
func add_mechanism(cell: Vector2i, mechanism: Variant) -> void:
	_mechanisms[cell] = mechanism


## 格是否在边界内。
func is_in_bounds(cell: Vector2i) -> bool:
	return _bounds.has_point(cell)


## 格是否为墙体。
func is_wall_cell(cell: Vector2i) -> bool:
	return _walls.has(cell)


## 格是否有水晶（仅存在性，不点亮）。
func has_crystal_at(cell: Vector2i) -> bool:
	return _crystals.has(cell)


## 取该格机关对象；未配置返回 null。
func get_light_mechanism_at(cell: Vector2i) -> Variant:
	return _mechanisms.get(cell, null)


## 测试用速度机关（不继承任何具体机关类）。
## 仅暴露 get_speed_modifier(Vector2i) -> int，用于证明 Adapter / Executor / Scheduler
##   不依赖 ParticleAccelerator / ParticleDecelerator 类名，只依赖公共方法契约。
class FakeSpeedMechanism:
	extends RefCounted

	## 速度增量（+1 / -1 / 0）。
	var delta: int = 0
	## 最近一次被调用时收到的入射方向（用于断言方向正确传入）。
	var last_seen_direction: Vector2i = Vector2i.ZERO
	## get_speed_modifier 被调用次数。
	var call_count: int = 0

	## 返回配置的 delta 并记录入射方向与调用次数。
	func get_speed_modifier(incoming_direction: Vector2i) -> int:
		call_count += 1
		last_seen_direction = incoming_direction
		return delta
