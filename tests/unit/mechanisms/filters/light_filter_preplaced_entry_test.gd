extends SceneTree

## 滤光片 关卡预置正式入口测试（.tscn / 场景合同 / apply_configuration / 预置收编链）。
## 覆盖：场景合同（light_filter.tscn 根为 PlaceableToken + VisualView/DebugFilm + interaction_profile=fixed +
##   未配置 mechanism_id + 默认朝向 VERTICAL / 颜色 RED）；Inspector authored 朝向/颜色（property 写入经 setter + 滤色随值切换）；
##   Typed apply_configuration 合同（orientation/color 字段写入 / null 通过 / 缺字段 / 越界拒绝且状态不变）；
##   真实预置收编链（PreplacedMechanismAdopter.adopt_all → OccupancyRegistry 单格注册 → get_preplaced_node 解析 →
##   authored 保持 → 经正式 Contract 分发：RAY 滤色 / 撞棱角 BLOCK / PARTICLE BLOCK）。
## headless extends SceneTree，由 Godot --script 运行；preload 引用避开全局 class_name 缓存；
##   全部失败项收集后统一退出（任一失败 quit(1)）。不涉及 GUI/截图。

const _Filter: GDScript = preload("res://gameplay/mechanisms/filters/light_filter.gd")
const _FilterScene: PackedScene = preload("res://gameplay/mechanisms/filters/light_filter.tscn")
const _PlaceableToken: GDScript = preload("res://gameplay/placement/placeable_token.gd")
const _Adopter: GDScript = preload("res://gameplay/placement/preplaced_mechanism_adopter.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _Contract: GDScript = preload("res://gameplay/light/interaction/light_interaction_contract.gd")
const _Result: GDScript = preload("res://gameplay/light/interaction/light_interaction_result.gd")
const _RayContext: GDScript = preload("res://gameplay/light/interaction/ray_interaction_context.gd")
const _ParticleContext: GDScript = preload(
	"res://gameplay/light/interaction/particle_interaction_context.gd"
)
const _Motion: GDScript = preload("res://gameplay/particle/particle_motion_rules.gd")
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")

const _GROUP_COUNT: int = 5

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_scene_contract()
	await _test_02_inspector_authored()
	_test_03_apply_configuration_contract()
	await _test_04_preplaced_adoption_chain()
	_test_05_reset_preservation_contract()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 构造带当前颜色的 RAY Context。
func _ray_ctx(cell: Vector2i, incoming: Vector2i, current_color: int) -> Variant:
	return _RayContext.create(cell, incoming, 1, 0, current_color)


## 构造薄膜朝向字段 Schema（INT 0..3，enum_max 可放宽以便测机关防线）。
func _make_orientation_field(enum_max: int = 3) -> Variant:
	var field: Variant = _MechanismFieldDefinition.new()
	field.field_id = _Filter.FIELD_ORIENTATION
	field.display_name = "薄膜朝向"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = enum_max
	field.default_value = 0
	return field


## 构造滤光颜色字段 Schema（INT 0..2）。
func _make_color_field() -> Variant:
	var field: Variant = _MechanismFieldDefinition.new()
	field.field_id = _Filter.FIELD_COLOR
	field.display_name = "滤光颜色"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = 2
	field.default_value = 0
	return field


## 实例化场景并挂入 root 下容器（触发 _ready / @onready）；返回 [container, filter]。
func _make_scene_filter(cell: Vector2i) -> Array:
	var container: Node2D = Node2D.new()
	root.add_child(container)
	var filter: Variant = _FilterScene.instantiate()
	(filter as Node2D).position = _GridCoordinateRules.cell_to_world(cell)
	container.add_child(filter as Node)
	return [container, filter]


func _free_tree(nodes: Array) -> void:
	for node: Variant in nodes:
		if is_instance_valid(node):
			(node as Node).free()
	await process_frame


func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== 滤光片预置正式入口测试摘要 ====")
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


## 01. 场景合同：根为 PlaceableToken/LightFilter，含 VisualView + DebugFilm，interaction_profile=fixed，
##     mechanism_id 空，默认朝向 VERTICAL、颜色 RED，形态声明 RAY+PARTICLE。
func _test_01_scene_contract() -> void:
	const G: String = "01_场景合同"
	var filter: Variant = _FilterScene.instantiate()
	_check(G, filter is _PlaceableToken, "场景根应为 PlaceableToken（预置收编合同门）。")
	_check(G, filter is _Filter, "场景根脚本应为 LightFilter。")
	_check(G, (filter as Node).has_node("VisualView"), "场景应含 VisualView 子节点。")
	_check(G, (filter as Node).has_node("DebugFilm"), "场景应含 DebugFilm 子节点。")
	_check(G, filter.interaction_profile == "fixed", "interaction_profile 应为 fixed（实际 %s）。" % [filter.interaction_profile])
	_check(G, filter.mechanism_id == &"", "未收编前 mechanism_id 应为空。")
	_check(G, filter.orientation == _Filter.FilterOrientation.VERTICAL, "默认朝向应为 VERTICAL。")
	_check(G, filter.color == _Filter.FilterColor.RED, "默认颜色应为 RED。")
	_check(G, filter.get_light_interaction_forms() == [&"RAY", &"PARTICLE"], "形态声明应为 RAY+PARTICLE。")
	(filter as Node).free()


## 02. Inspector authored 朝向/颜色：树上实例经 property 写入（= Inspector 导出属性路径）改朝向/颜色，滤色随值切换。
func _test_02_inspector_authored() -> void:
	const G: String = "02_InspectorAuthored"
	var made: Array = _make_scene_filter(Vector2i(0, 0))
	var filter: Variant = made[1]
	await process_frame

	filter.orientation = _Filter.FilterOrientation.VERTICAL
	filter.color = _Filter.FilterColor.GREEN
	_check(G, filter.orientation == _Filter.FilterOrientation.VERTICAL, "property 写入 orientation 应落盘 VERTICAL。")
	_check(G, filter.color == _Filter.FilterColor.GREEN, "property 写入 color 应落盘 GREEN。")
	var r: Variant = _Contract.dispatch_ray(filter, _ray_ctx(Vector2i(0, 0), Vector2i(1, 0), _RayColor.ColorValue.WHITE))
	_check(G, r.decision == _Result.Decision.CONTINUE
		and r.get_color_change() == _RayColor.ColorValue.GREEN,
		"白光→穿绿滤光片 期望 CONTINUE + COLOR_CHANGE(GREEN)。")
	_free_tree(made)


## 03. Typed apply_configuration 合同：合法 orientation+color 写入；null 通过；缺字段 / 越界拒绝且状态不变。
func _test_03_apply_configuration_contract() -> void:
	const G: String = "03_applyConfiguration合同"
	var filter: Variant = _Filter.new()

	var good: Variant = _MechanismConfiguration.from_type_defaults([_make_orientation_field(), _make_color_field()])
	_check(G, good != null and good.apply_override(_Filter.FIELD_ORIENTATION, 2)
		and good.apply_override(_Filter.FIELD_COLOR, 1), "合法 orientation=2/color=1 应能写入配置。")
	_check(G, filter.apply_configuration(good), "合法配置应用应返回 true。")
	_check(G, filter.orientation == 2 and filter.color == 1, "应用后 orientation=SLASH/color=GREEN。")

	filter.set_orientation(0)
	filter.set_color(0)
	_check(G, filter.apply_configuration(null), "null 配置应直接通过。")
	_check(G, filter.orientation == 0 and filter.color == 0, "null 配置不得改写状态。")

	var missing: Variant = _MechanismConfiguration.from_type_defaults([])
	_check(G, missing != null, "空 Schema 配置应可构造。")
	_check(G, not filter.apply_configuration(missing), "缺字段配置应被拒绝。")
	_check(G, filter.orientation == 0, "被拒配置不得改写朝向。")

	# 越界：放宽 orientation schema 界（enum_max=9），让值 4 进配置，由本机关防线拒绝。
	var wide: Variant = _MechanismConfiguration.from_type_defaults([_make_orientation_field(9), _make_color_field()])
	_check(G, wide != null and wide.apply_override(_Filter.FIELD_ORIENTATION, 4),
		"Schema 界放宽时值 4 可进配置（防线在本机关）。")
	_check(G, not filter.apply_configuration(wide), "越界朝向 4 应由本机关拒绝。")
	_check(G, filter.orientation == 0, "越界拒绝后朝向应保持不变。")
	filter.free()


## 04. 真实预置收编链：adopt_all 收编 → occupancy 注册 → get_preplaced_node 解析 → authored 保持 →
##     Contract 分发（RAY 滤色 / 撞棱角 BLOCK / PARTICLE BLOCK）。
func _test_04_preplaced_adoption_chain() -> void:
	const G: String = "04_预置收编链"
	var cell: Vector2i = Vector2i(2, 3)
	var made: Array = _make_scene_filter(cell)
	var filter: Variant = made[1]
	filter.orientation = _Filter.FilterOrientation.VERTICAL
	filter.color = _Filter.FilterColor.BLUE
	await process_frame

	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var adopter: _Adopter = _Adopter.new(occupancy, Callable(self, "_always_adoptable"))
	_check(G, adopter.adopt_all(made[0]) == 1, "滤光片场景实例应被收编 1。")
	var mechanism_id: StringName = occupancy.get_mechanism_at(cell)
	_check(G, mechanism_id != &"" and String(mechanism_id).begins_with("preplaced_"),
		"占用表应登记 preplaced_ 前缀 ID（实际 %s）。" % [mechanism_id])
	var resolved: Variant = adopter.get_preplaced_node(mechanism_id)
	_check(G, resolved == filter, "get_preplaced_node 应解析回原场景实例。")
	_check(G, filter.mechanism_id == mechanism_id, "实例 mechanism_id 应被写入收编 ID。")
	_check(G, filter.orientation == _Filter.FilterOrientation.VERTICAL
		and filter.color == _Filter.FilterColor.BLUE, "收编后 authored 朝向/颜色应保持。")

	var through: Variant = _Contract.dispatch_ray(resolved, _ray_ctx(cell, Vector2i(1, 0), _RayColor.ColorValue.WHITE))
	_check(G, through.decision == _Result.Decision.CONTINUE
		and through.get_color_change() == _RayColor.ColorValue.BLUE,
		"白光→穿蓝滤光片 期望 CONTINUE + COLOR_CHANGE(BLUE)。")
	var edge: Variant = _Contract.dispatch_ray(resolved, _ray_ctx(cell, Vector2i(0, -1), _RayColor.ColorValue.WHITE))
	_check(G, edge.decision == _Result.Decision.BLOCK, "白光 ↑ 撞竖滤光片棱角 期望 BLOCK。")
	var p: Variant = _Contract.dispatch_particle(resolved,
		_ParticleContext.create(cell, Vector2i(1, 0), 1, 0, _Motion.SpeedTier.STANDARD, 7))
	_check(G, p.decision == _Result.Decision.BLOCK, "光粒穿滤光片 期望 BLOCK。")
	_free_tree(made)


## 05. R 重置保留契约（规则 §6）：滤光片为无状态预置对象，无 reset hook、运行期零写入，
##     因此 LevelRuntimeController.reset_runtime（只清玩家机关，不清静态内容/预置对象）后 authored 朝向/颜色天然保留。
## [br]运行时层的"不清预置对象"由 LevelRuntimeController.reset_runtime 契约保证（reset_runtime_test 已覆盖玩家机关清理），
##     本测试锁住滤光片自身不破坏该保留：无 reset 方法 + 交互不改状态。
func _test_05_reset_preservation_contract() -> void:
	const G: String = "05_R重置保留"
	var filter: Variant = _Filter.new()
	filter.set_orientation(_Filter.FilterOrientation.SLASH)
	filter.set_color(_Filter.FilterColor.BLUE)
	# 无 reset hook：无状态预置对象不实现任何 reset 方法（若未来加状态/reset 需同步修订规则 §6）。
	_check(G, not filter.has_method("reset_runtime"), "滤光片不应实现 reset_runtime（无状态预置对象，无 reset hook）。")
	# 运行期零写入：多次交互后 authored 朝向/颜色不变（R 保留的前提）。
	for i in 3:
		_Contract.dispatch_ray(filter, _ray_ctx(Vector2i(0, 0), Vector2i(1, 0), _RayColor.ColorValue.WHITE))
		_Contract.dispatch_ray(filter, _ray_ctx(Vector2i(0, 0), Vector2i(1, -1), _RayColor.ColorValue.RED))
		_Contract.dispatch_particle(filter, _ParticleContext.create(Vector2i(0, 0), Vector2i(1, 0), 1, 0, _Motion.SpeedTier.STANDARD, 7))
	_check(G, filter.orientation == _Filter.FilterOrientation.SLASH, "多次交互后朝向应保持 authored SLASH。")
	_check(G, filter.color == _Filter.FilterColor.BLUE, "多次交互后颜色应保持 authored BLUE。")
	filter.free()


## 格合法性门桩：全部合法（测试环境无 Terrain/Wall 域，收编链自身即被测对象）。
func _always_adoptable(_cell: Vector2i) -> bool:
	return true
