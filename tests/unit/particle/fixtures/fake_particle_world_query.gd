extends RefCounted

## 光粒调度 / 执行测试专用等价只读 world query（D7-4 B2 fixtures）。
## 职责：为 ParticleStepExecutor / ParticleScheduler 的定向测试提供一个不依赖场景树 / Node / BasicCrystal 的等价只读世界查询，
##   实现 executor / scheduler 所要求的四个只读方法契约：is_in_bounds / is_wall_cell / has_crystal_at / get_light_mechanism_at。
##   方法签名与正式运行使用的 LightWorldQuery 完全一致，正式运行由 LightWorldQuery 提供同契约方法，本 fixture 仅服务测试。
## 位置：tests/unit/particle/fixtures/ 下；不进场景树、不设为 Autoload、无 class_name（不污染全局 class 注册）。
## 依赖：world query 部分零游戏脚本依赖（仅 Rect2i + Dictionary）；机关 fixture 经 preload 引用正式契约
##   LightInteractionResult（AF-02 起伪造机关实现正式契约面，不再依赖鸭子方法）。
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


## 测试用速度机关（AF-02 正式契约版；不继承任何具体机关类）。
## 实现正式契约面 get_light_interaction_forms + interact_particle（经 LightInteractionResult 表达 ±1 档位请求），
## 用于证明 Adapter / Executor / Scheduler 不依赖 ParticleAccelerator / ParticleDecelerator 类名与鸭子方法探测。
class FakeSpeedMechanism:
	extends RefCounted

	# 正式契约 Result 构造入口（preload 引用避开全局 class_name 缓存问题）。
	const _Result: GDScript = preload(
		"res://gameplay/light/interaction/light_interaction_result.gd"
	)

	## 速度增量（+1 / -1 / 0）。
	var delta: int = 0
	## 最近一次被调用时收到的入射方向（用于断言方向正确传入）。
	var last_seen_direction: Vector2i = Vector2i.ZERO
	## interact_particle 被调用次数。
	var call_count: int = 0

	## 声明仅支持 PARTICLE 交互（RAY 未声明 → Runtime 判透明）。
	func get_light_interaction_forms() -> Array[StringName]:
		return [&"PARTICLE"]

	## 正式交互入口：CONTINUE +（delta != 0 时）PARTICLE_SPEED_DELTA(delta)；记录调用事实。
	func interact_particle(particle_context: Variant) -> _Result:
		call_count += 1
		last_seen_direction = particle_context.get_incoming_direction()
		var result: _Result = _Result.continue_result()
		if delta != 0:
			result.add_speed_delta(delta)
		return result


## 测试用镜面机关（AF-02 正式契约版；不继承 SingleCellMirror）。
## 实现正式契约面 get_light_interaction_forms + interact_particle；反射公式与正式 SingleCellMirror 同源
##（SLASH=(-y,-x)，BACKSLASH=(y,x)，ZERO=非法入射哨兵→CONTINUE 安全降级）。
class FakeReflectMechanism:
	extends RefCounted

	# 正式契约 Result 构造入口。
	const _Result: GDScript = preload(
		"res://gameplay/light/interaction/light_interaction_result.gd"
	)

	## 反射公式选择：true = SLASH（(-y,-x)），false = BACKSLASH（(y,x)）。
	var slash: bool = true
	## 非法入射时返回 ZERO 的开关（模拟 SingleCellMirror 对非法方向的哨兵返回）。
	var zero_on_any: bool = false
	## interact_particle 被调用次数。
	var call_count: int = 0
	## 最近一次收到的入射方向。
	var last_seen_direction: Vector2i = Vector2i.ZERO

	## 声明支持 RAY + PARTICLE（与正式 SingleCellMirror 一致）。
	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY", &"PARTICLE"]

	## 正式交互入口：按双面反射公式 REDIRECT；ZERO 哨兵 → CONTINUE（保持入射方向）；记录调用事实。
	func interact_particle(particle_context: Variant) -> _Result:
		call_count += 1
		var incoming_direction: Vector2i = particle_context.get_incoming_direction()
		last_seen_direction = incoming_direction
		if zero_on_any:
			return _Result.continue_result()
		if slash:
			return _Result.redirect_result(Vector2i(-incoming_direction.y, -incoming_direction.x))
		return _Result.redirect_result(Vector2i(incoming_direction.y, incoming_direction.x))


## 测试用仅 RAY 机关（AF-02 §21 未声明形态语义）：声明 RAY 但不声明 PARTICLE，
## 证明 Particle 分发对未声明形态透明（不调用 interact_particle、保持传播状态）。
class RayOnlyMechanism:
	extends RefCounted

	## interact_particle 被调用次数（期望恒 0）。
	var call_count: int = 0

	## 仅声明 RAY。
	func get_light_interaction_forms() -> Array[StringName]:
		return [&"RAY"]

	## 不应被 Runtime 调用（未声明 PARTICLE = 透明）；被误调时计数暴露违规。
	func interact_particle(particle_context: Variant) -> Variant:
		call_count += 1
		return null
