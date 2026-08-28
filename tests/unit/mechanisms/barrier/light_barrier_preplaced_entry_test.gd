extends SceneTree

## 光屏障 关卡预置正式入口测试（阶段A补齐验收缺口：.tscn / 占用注册 / authored 八向朝向）。
## 覆盖：场景合同（light_barrier.tscn 根为 PlaceableToken + VisualView/DebugFilm 结构 + interaction_profile=fixed
##   + 未配置 mechanism_id）；Inspector authored 朝向（property 写入经 setter + 树上 _ready 后占位薄膜线方向
##   与穿越轴垂直）；Typed apply_configuration 合同（Stable Field ID "direction" 0..7 写入 / 缺字段 / 越界拒绝且方向不变）；
##   真实预置收编链（PreplacedMechanismAdopter.adopt_all → OccupancyRegistry 单格注册 → get_preplaced_node 按格解析 →
##   经正式 Contract 分发六向非轴 BLOCK / 轴向速度门 / RAY BLOCK——运行期正确接收与射出）；双屏障双朝向同批收编。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存问题；
##   全部失败项收集后统一退出（任一失败 quit(1)）。不涉及 GUI/截图。

const _Barrier: GDScript = preload("res://gameplay/mechanisms/barrier/light_barrier.gd")
const _BarrierScene: PackedScene = preload("res://gameplay/mechanisms/barrier/light_barrier.tscn")
const _PlaceableToken: GDScript = preload("res://gameplay/placement/placeable_token.gd")
const _Adopter: GDScript = preload(
	"res://gameplay/placement/preplaced_mechanism_adopter.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _Contract: GDScript = preload(
	"res://gameplay/light/interaction/light_interaction_contract.gd"
)
const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _RayContext: GDScript = preload("res://gameplay/light/interaction/ray_interaction_context.gd")
const _ParticleContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)
const _Motion: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _DirectionDomain: GDScript = preload("res://gameplay/light/direction_domain.gd")

const _GROUP_COUNT: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_scene_contract()
	await _test_02_inspector_authored_direction()
	_test_03_apply_configuration_contract()
	await _test_04_preplaced_adoption_runtime_chain()
	await _test_05_two_barriers_two_orientations()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 构造 PARTICLE 交互 Context（mechanism_cell 为机关格；tier 为 _Motion.SpeedTier 值）。
func _particle_ctx(mechanism_cell: Vector2i, incoming: Vector2i, tier: int) -> Variant:
	return _ParticleContext.create(mechanism_cell, incoming, 1, 0, tier, 7)


## 构造 RAY 交互 Context。
func _ray_ctx(mechanism_cell: Vector2i, incoming: Vector2i) -> Variant:
	return _RayContext.create(mechanism_cell, incoming, 1, 0)


## 构造屏障朝向字段 Schema（INT 0..7，与 FIELD_DIRECTION Stable Field ID 对齐）。
func _make_direction_field(enum_max: int = 7) -> Variant:
	var field: Variant = _MechanismFieldDefinition.new()
	field.field_id = _Barrier.FIELD_DIRECTION
	field.display_name = "屏障朝向"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = enum_max
	field.default_value = 0
	return field


## 实例化场景并挂入 root 下容器（触发 _ready / @onready）；返回 [container, barrier]。
func _make_scene_barrier(cell: Vector2i) -> Array:
	var container: Node2D = Node2D.new()
	root.add_child(container)
	var barrier: Variant = _BarrierScene.instantiate()
	(barrier as Node2D).position = _GridCoordinateRules.cell_to_world(cell)
	container.add_child(barrier as Node)
	return [container, barrier]


func _free_tree(nodes: Array) -> void:
	for node: Variant in nodes:
		if is_instance_valid(node):
			(node as Node).free()
	await process_frame


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 光屏障预置正式入口测试摘要 ====")
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


# ===== 测试 =====

## 01. 场景合同：light_barrier.tscn 根为 PlaceableToken/LightBarrier，结构含 VisualView + DebugFilm，
##     interaction_profile="fixed"（仅关卡预置），mechanism_id 未配置（待 Adopter 收编分配），默认朝向 RIGHT。
func _test_01_scene_contract() -> void:
	const G: String = "01_场景合同"
	var barrier: Variant = _BarrierScene.instantiate()
	_check(G, barrier is _PlaceableToken, "场景根应为 PlaceableToken（预置收编合同门）。")
	_check(G, barrier is _Barrier, "场景根脚本应为 LightBarrier。")
	_check(G, (barrier as Node).has_node("VisualView"), "场景应含 VisualView 子节点（视觉承载）。")
	_check(G, (barrier as Node).has_node("DebugFilm"), "场景应含 DebugFilm 子节点（纹理缺失占位后备）。")
	_check(G, barrier.interaction_profile == "fixed", "interaction_profile 应为 fixed（仅关卡预置，实际 %s）。"
		% [barrier.interaction_profile])
	_check(G, barrier.mechanism_id == &"", "未收编前 mechanism_id 应为空。")
	_check(G, barrier.direction == _Barrier.BarrierDirection.RIGHT, "默认朝向应为 RIGHT。")
	_check(G, barrier.get_light_interaction_forms() == [&"RAY", &"PARTICLE"], "场景实例形态声明应为 RAY+PARTICLE。")
	(barrier as Node).free()


## 02. Inspector authored 朝向：树上实例经 property 写入（= Inspector 导出属性路径）改朝向，
##     分区判定随 authored 值切换；_ready 后占位薄膜线与穿越轴垂直（RIGHT→竖线；DOWN→横线）。
func _test_02_inspector_authored_direction() -> void:
	const G: String = "02_InspectorAuthored朝向"
	var made: Array = _make_scene_barrier(Vector2i(0, 0))
	var barrier: Variant = made[1]
	await process_frame

	barrier.direction = _Barrier.BarrierDirection.RIGHT
	_check(G, barrier.direction == _Barrier.BarrierDirection.RIGHT, "property 写入应经 setter 落盘 RIGHT。")
	_check(G, barrier.is_on_traversal_axis(Vector2i(1, 0))
		and barrier.is_on_traversal_axis(Vector2i(-1, 0)), "RIGHT 朝向轴向应为 →/←。")
	_check(G, not barrier.is_on_traversal_axis(Vector2i(0, 1)), "RIGHT 朝向 ↓ 应为非轴。")
	var film_right: Line2D = (barrier as Node).get_node("DebugFilm") as Line2D
	_check(G, film_right.visible, "无 visual_profile 时占位薄膜线应显示。")
	var fr_p0: Vector2 = film_right.points[0]
	var fr_p1: Vector2 = film_right.points[1]
	_check(G, fr_p0 == -fr_p1 and fr_p0.x == 0 and absi(fr_p0.y) == 28,
		"RIGHT 朝向占位薄膜线应为竖直（⊥ 穿越轴）。")

	barrier.direction = _Barrier.BarrierDirection.DOWN
	_check(G, barrier.is_on_traversal_axis(Vector2i(0, 1))
		and barrier.is_on_traversal_axis(Vector2i(0, -1)), "DOWN 朝向轴向应为 ↓/↑。")
	_check(G, not barrier.is_on_traversal_axis(Vector2i(1, 0)), "DOWN 朝向 → 应为非轴。")
	var film_down: Line2D = (barrier as Node).get_node("DebugFilm") as Line2D
	var fd_p0: Vector2 = film_down.points[0]
	var fd_p1: Vector2 = film_down.points[1]
	_check(G, fd_p0 == -fd_p1 and fd_p0.y == 0 and absi(fd_p0.x) == 28,
		"DOWN 朝向占位薄膜线应为水平（⊥ 穿越轴）。")

	# authored 朝向切换后运行期行为随新事实：DOWN 朝向时 ↑ 与穿越轴共轴（进入速度门，STANDARD → CONTINUE -1），
	# → 为非轴 BLOCK——证明 Inspector/authored 配置真实驱动运行期接收与射出。
	var on_axis: Variant = _Contract.dispatch_particle(
		barrier, _particle_ctx(Vector2i(0, 0), Vector2i(0, -1), _Motion.SpeedTier.STANDARD))
	_check(G, on_axis.decision == _Result.Decision.CONTINUE
		and on_axis.get_speed_delta() == -1, "DOWN 朝向 ↑ 轴向 STANDARD 应 CONTINUE -1。")
	var off_axis: Variant = _Contract.dispatch_particle(
		barrier, _particle_ctx(Vector2i(0, 0), Vector2i(1, 0), _Motion.SpeedTier.FAST))
	_check(G, off_axis.decision == _Result.Decision.BLOCK, "DOWN 朝向 → 非轴 FAST 应 BLOCK。")
	_free_tree(made)


## 03. Typed apply_configuration 合同（Stable Field ID "direction"）：合法 0..7 写入；null 通过不写入；
##     缺 direction 字段拒绝；Schema 放行但值越界（8）由本机关拒绝且方向不变。
func _test_03_apply_configuration_contract() -> void:
	const G: String = "03_applyConfiguration合同"
	var barrier: Variant = _Barrier.new()

	var good: Variant = _MechanismConfiguration.from_type_defaults([_make_direction_field()])
	_check(G, good != null and good.apply_override(_Barrier.FIELD_DIRECTION, 5), "合法朝向值 5 应能写入配置。")
	_check(G, barrier.apply_configuration(good), "合法配置应用应返回 true。")
	_check(G, barrier.direction == 5, "应用后朝向应为 5（UP_LEFT）。")

	barrier.set_direction(2)
	_check(G, barrier.apply_configuration(null), "null 配置应直接通过。")
	_check(G, barrier.direction == 2, "null 配置不得改写朝向。")

	var missing: Variant = _MechanismConfiguration.from_type_defaults([])
	_check(G, missing != null, "空 Schema 配置应可构造。")
	_check(G, not barrier.apply_configuration(missing), "缺 direction 字段的配置应被拒绝。")
	_check(G, barrier.direction == 2, "被拒配置不得改写朝向。")

	var wide: Variant = _MechanismConfiguration.from_type_defaults([_make_direction_field(9)])
	_check(G, wide != null and wide.apply_override(_Barrier.FIELD_DIRECTION, 8),
		"Schema 界放宽时值 8 可进配置（防线在本机关）。")
	_check(G, not barrier.apply_configuration(wide), "越界值 8 应由本机关拒绝。")
	_check(G, barrier.direction == 2, "越界拒绝后朝向应保持不变。")

	# 全 8 值数据驱动：Typed 写入朝向后分区判定随值正确切换。
	for value: int in range(8):
		var config: Variant = _MechanismConfiguration.from_type_defaults([_make_direction_field()])
		config.apply_override(_Barrier.FIELD_DIRECTION, value)
		if barrier.apply_configuration(config):
			var axis: Vector2i = _Barrier.direction_to_vector(value)
			_check(G, barrier.is_on_traversal_axis(axis)
				and barrier.is_on_traversal_axis(_DirectionDomain.opposite(axis)),
				"Typed 朝向 %d 轴向两向应共轴。" % value)
		else:
			_check(G, false, "Typed 朝向 %d 合法值应用被拒。" % value)
	barrier.free()


## 04. 真实预置收编链：RuntimeObjects 容器 + 场景实例（authored LEFT）→ adopt_all 收编 1 →
##     OccupancyRegistry 按格注册（preplaced_ 前缀）→ get_preplaced_node 解析原实例 → authored 朝向保持 →
##     经正式 Contract 分发：六向非轴 BLOCK / 轴向 SLOW BLOCK、STANDARD CONTINUE -1 / RAY 恒 BLOCK。
func _test_04_preplaced_adoption_runtime_chain() -> void:
	const G: String = "04_预置收编运行链"
	var cell: Vector2i = Vector2i(2, 3)
	var made: Array = _make_scene_barrier(cell)
	var barrier: Variant = made[1]
	barrier.direction = _Barrier.BarrierDirection.LEFT
	await process_frame

	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _Adopter.new(occupancy, Callable(self, "_always_adoptable"))
	_check(G, adopter.adopt_all(made[0]) == 1, "屏障场景实例应被收编 1。")
	var mechanism_id: StringName = occupancy.get_mechanism_at(cell)
	_check(G, mechanism_id != &"" and String(mechanism_id).begins_with("preplaced_"),
		"占用表应登记 preplaced_ 前缀 ID（实际 %s）。" % [mechanism_id])
	_check(G, adopter.has_preplaced(mechanism_id), "收编映射应含该 ID。")
	var resolved: Variant = adopter.get_preplaced_node(mechanism_id)
	_check(G, resolved == barrier, "get_preplaced_node 应解析回原场景实例（core_loop._get_mechanism_node 同路径）。")
	_check(G, barrier.mechanism_id == mechanism_id, "实例 mechanism_id 应被写入收编 ID。")
	_check(G, barrier.direction == _Barrier.BarrierDirection.LEFT, "收编后 authored 朝向应保持 LEFT。")
	_check(G, occupancy.is_consistent(), "占用表应保持一致。")

	# 运行期接收与射出（按格解析出的实例经正式 Contract 分发）。
	var traversal_axis: Vector2i = Vector2i(-1, 0)
	for token: StringName in _DirectionDomain.CLOCKWISE_ORDER:
		var incoming: Vector2i = _DirectionDomain.to_vector(token)
		if _DirectionDomain.same_axis(incoming, traversal_axis):
			continue
		var blocked: Variant = _Contract.dispatch_particle(
			resolved, _particle_ctx(cell, incoming, _Motion.SpeedTier.FAST))
		_check(G, blocked.decision == _Result.Decision.BLOCK,
			"非轴 %s FAST 应 BLOCK（六向）。" % token)
	var slow: Variant = _Contract.dispatch_particle(
		resolved, _particle_ctx(cell, Vector2i(-1, 0), _Motion.SpeedTier.SLOW))
	_check(G, slow.decision == _Result.Decision.BLOCK, "轴向 ← SLOW 应 BLOCK（能量不足）。")
	var standard: Variant = _Contract.dispatch_particle(
		resolved, _particle_ctx(cell, Vector2i(-1, 0), _Motion.SpeedTier.STANDARD))
	_check(G, standard.decision == _Result.Decision.CONTINUE
		and standard.get_speed_delta() == -1, "轴向 ← STANDARD 应 CONTINUE -1。")
	for token: StringName in [&"LEFT", &"RIGHT", &"UP"]:
		var ray_result: Variant = _Contract.dispatch_ray(
			resolved, _ray_ctx(cell, _DirectionDomain.to_vector(token)))
		_check(G, ray_result.decision == _Result.Decision.BLOCK,
			"RAY 入射 %s 应恒 BLOCK。" % token)
	_free_tree(made)


## 05. 双屏障双朝向同批收编：A=RIGHT、B=DOWN；↓ 入射对 A 非轴 BLOCK、对 B 轴向 CONTINUE -1；
##     两实例各自方向事实独立、占用一致，证明多实例 authored 六向入口同链路承载。
func _test_05_two_barriers_two_orientations() -> void:
	const G: String = "05_双屏障双朝向"
	var container: Node2D = Node2D.new()
	root.add_child(container)
	var barrier_a: Variant = _BarrierScene.instantiate()
	(barrier_a as Node2D).position = _GridCoordinateRules.cell_to_world(Vector2i(1, 1))
	container.add_child(barrier_a as Node)
	barrier_a.direction = _Barrier.BarrierDirection.RIGHT
	var barrier_b: Variant = _BarrierScene.instantiate()
	(barrier_b as Node2D).position = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	container.add_child(barrier_b as Node)
	barrier_b.direction = _Barrier.BarrierDirection.DOWN
	await process_frame

	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _Adopter.new(occupancy, Callable(self, "_always_adoptable"))
	_check(G, adopter.adopt_all(container) == 2, "双屏障应同批收编 2。")
	var id_a: StringName = occupancy.get_mechanism_at(Vector2i(1, 1))
	var id_b: StringName = occupancy.get_mechanism_at(Vector2i(3, 1))
	_check(G, id_a != id_b and id_a != &"" and id_b != &"", "两屏障应登记不同非空 ID。")

	# ↓ 入射：A（RIGHT）非轴 BLOCK；B（DOWN）轴向 STANDARD CONTINUE -1。
	var hit_a: Variant = _Contract.dispatch_particle(
		adopter.get_preplaced_node(id_a), _particle_ctx(Vector2i(1, 1), Vector2i(0, 1), _Motion.SpeedTier.STANDARD))
	_check(G, hit_a.decision == _Result.Decision.BLOCK, "屏障 A（RIGHT）↓ 应非轴 BLOCK。")
	var hit_b: Variant = _Contract.dispatch_particle(
		adopter.get_preplaced_node(id_b), _particle_ctx(Vector2i(3, 1), Vector2i(0, 1), _Motion.SpeedTier.STANDARD))
	_check(G, hit_b.decision == _Result.Decision.CONTINUE
		and hit_b.get_speed_delta() == -1, "屏障 B（DOWN）↓ 应轴向 CONTINUE -1。")
	_check(G, barrier_a.direction == _Barrier.BarrierDirection.RIGHT
		and barrier_b.direction == _Barrier.BarrierDirection.DOWN,
		"两实例 authored 朝向应各自独立保持。")
	_check(G, occupancy.is_consistent(), "双屏障占用表应保持一致。")
	_free_tree([container])


## 格合法性门桩：全部合法（测试环境无 Terrain/Wall 域，收编链自身即被测对象）。
func _always_adoptable(_cell: Vector2i) -> bool:
	return true
