extends SceneTree

## 核心闭环发射器运行接线与发射流程测试（拆分片 2/3 · D4.6-T5）。
## 覆盖：启动后 FixedEmitter 格子/方向与 EmitterConfigNode 一致；build_fire_request 起点与方向来自新配置；
##   入树前改 position / ray_default_direction 后启动，FixedEmitter 使用新值；
##   改光粒方向但保持 RAY 不影响光线方向；PARTICLE 不静默创建 RAY FixedEmitter 且安全停止；
##   LevelWorldQuery 发射器格与新配置一致；自检采样不再依赖旧字段；EmissionPreview 不参与真实发射。
## 接线用例挂入 root 并 await process_frame 触发真实 _ready，再读取既有私有状态验证；场景加载/清理见 fixtures/core_loop_scene_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _FixedEmitter: GDScript = preload(
	"res://gameplay/mechanisms/emitters/fixed_emitter.gd"
)
const _FireRequest: GDScript = preload(
	"res://gameplay/light/fire_request.gd"
)
const _Fixture: GDScript = preload(
	"res://tests/integration/emitters/fixtures/core_loop_scene_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture: _Fixture = null


## SceneTree 初始化入口：加载场景，跑接线用例（挂入 root 触发真实 _ready），最后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_fixture = _Fixture.new(self)

	await _test_15_fixed_emitter_cell_matches_config(scene)
	await _test_16_fixed_emitter_direction_matches_config(scene)
	await _test_17_build_fire_request_from_config(scene)
	await _test_18_position_change_reflected(scene)
	await _test_19_ray_direction_change_reflected(scene)
	await _test_20_particle_direction_no_effect_on_ray(scene)
	await _test_21_particle_no_silent_ray_safe_stop(scene)
	await _test_22_level_world_query_cell_matches(scene)
	await _test_23_self_check_no_old_field_dependency(scene)
	await _test_24_emission_preview_not_in_real_fire(scene)

	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 接线用例（挂入 SceneTree 触发真实 _ready） =====

## 15. 启动后 _fixed_emitter.get_cell() 与 EmitterConfigNode.get_cell() 一致。
func _test_15_fixed_emitter_cell_matches_config(scene: PackedScene) -> void:
	const NAME: String = "15_FixedEmitter格子与配置一致"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "_fixed_emitter 应已构造，实际 null。")
	if fixed_emitter != null and emitter != null:
		_check(NAME, fixed_emitter.get_cell() == emitter.get_cell(), "FixedEmitter 格 %s 应与 EmitterConfigNode.get_cell() %s 一致。" % [fixed_emitter.get_cell(), emitter.get_cell()])
	await _fixture.free_settled(node)


## 16. 启动后 FixedEmitter 方向与 EmitterConfigNode.get_ray_direction_vector() 一致。
func _test_16_fixed_emitter_direction_matches_config(scene: PackedScene) -> void:
	const NAME: String = "16_FixedEmitter方向与配置一致"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	if fixed_emitter == null or emitter == null:
		_check(NAME, false, "FixedEmitter 或 Emitter 缺失。")
		await _fixture.free_settled(node)
		return
	_check(NAME, fixed_emitter.get_direction() == emitter.get_ray_direction_vector(), "FixedEmitter 方向 %s 应与 get_ray_direction_vector() %s 一致。" % [fixed_emitter.get_direction(), emitter.get_ray_direction_vector()])
	await _fixture.free_settled(node)


## 17. FixedEmitter.build_fire_request() 的起点与方向来自新配置。
func _test_17_build_fire_request_from_config(scene: PackedScene) -> void:
	const NAME: String = "17_build_fire_request来自新配置"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	if fixed_emitter == null or emitter == null:
		_check(NAME, false, "FixedEmitter 或 Emitter 缺失。")
		await _fixture.free_settled(node)
		return
	var request: _FireRequest = fixed_emitter.build_fire_request(128)
	_check(NAME, request != null, "合法方向下 build_fire_request 不应返回 null。")
	if request != null:
		_check(NAME, request.get_start_cell() == emitter.get_cell(), "FireRequest 起点 %s 应与配置格 %s 一致。" % [request.get_start_cell(), emitter.get_cell()])
		_check(NAME, request.get_direction() == emitter.get_ray_direction_vector(), "FireRequest 方向 %s 应与配置方向 %s 一致。" % [request.get_direction(), emitter.get_ray_direction_vector()])
	await _fixture.free_settled(node)


## 18. 入树前修改 Emitter.position，启动后 FixedEmitter 使用修改后的格子。
func _test_18_position_change_reflected(scene: PackedScene) -> void:
	const NAME: String = "18_入树前改position后FixedEmitter用新格"
	if scene == null:
		_check(NAME, false, "场景未加载。")
		return
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		_check(NAME, false, "场景实例化返回 null。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	var moved_cell: Vector2i = Vector2i(5, 6)
	emitter.position = _GridCoordinateRules.cell_to_world(moved_cell)
	get_root().add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "改 position 后 _fixed_emitter 应仍构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_cell() == moved_cell, "FixedEmitter 格 %s 应为入树前修改的格 %s。" % [fixed_emitter.get_cell(), moved_cell])
	await _fixture.free_settled(node)


## 19. 入树前修改 ray_default_direction，启动后 FixedEmitter 使用修改后的方向。
func _test_19_ray_direction_change_reflected(scene: PackedScene) -> void:
	const NAME: String = "19_入树前改ray方向后FixedEmitter用新方向"
	if scene == null:
		_check(NAME, false, "场景未加载。")
		return
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		_check(NAME, false, "场景实例化返回 null。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	emitter.ray_default_direction = _EmitterConfigNode.RayDirection.UP
	get_root().add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	var expected_vec: Vector2i = _EmitterConfigNode.ray_direction_to_vector(_EmitterConfigNode.RayDirection.UP)
	_check(NAME, fixed_emitter != null, "改方向后 _fixed_emitter 应仍构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_direction() == expected_vec, "FixedEmitter 方向 %s 应为入树前修改的 UP 向量 %s。" % [fixed_emitter.get_direction(), expected_vec])
	await _fixture.free_settled(node)


## 20. 修改光粒方向但保持 RAY，不影响运行时光线方向。
func _test_20_particle_direction_no_effect_on_ray(scene: PackedScene) -> void:
	const NAME: String = "20_改光粒方向不影响光线方向"
	if scene == null:
		_check(NAME, false, "场景未加载。")
		return
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		_check(NAME, false, "场景实例化返回 null。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	# 保持 RAY，把光粒方向改为 LEFT；光线方向应仍为 ray_default_direction（RIGHT）。
	emitter.particle_default_direction = _EmitterConfigNode.ParticleDirection.LEFT
	get_root().add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "保持 RAY 时 _fixed_emitter 应已构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_direction() == Vector2i.RIGHT, "改光粒方向后光线方向应仍为 (1,0)，实际 %s。" % [fixed_emitter.get_direction()])
	await _fixture.free_settled(node)


## 21. default_light_form=PARTICLE 时不静默创建 RAY FixedEmitter，且路径安全停止不产生空对象。
func _test_21_particle_no_silent_ray_safe_stop(scene: PackedScene) -> void:
	const NAME: String = "21_PARTICLE不静默创建RAY且安全停止"
	if scene == null:
		_check(NAME, false, "场景未加载。")
		return
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		_check(NAME, false, "场景实例化返回 null。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	get_root().add_child(node)
	await process_frame
	# PARTICLE 未接运行时：不构造 FixedEmitter，不构造运行期编排控制器，避免后续空引用。
	_check(NAME, node.get("_fixed_emitter") == null, "PARTICLE 不应静默创建 RAY FixedEmitter，实际非 null。")
	_check(NAME, node.get("_level_runtime_controller") == null, "PARTICLE 不应构造运行期编排控制器，实际非 null。")
	_check(NAME, is_instance_valid(node), "PARTICLE 安全停止后节点应仍有效，不应崩溃释放。")
	await _fixture.free_settled(node)


## 22. LevelWorldQuery 的发射器格与新配置一致。
func _test_22_level_world_query_cell_matches(scene: PackedScene) -> void:
	const NAME: String = "22_LevelWorldQuery发射器格与新配置一致"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	var lwq: Variant = node.get("_level_world_query")
	_check(NAME, lwq != null, "_level_world_query 应已构造，实际 null。")
	if emitter != null and lwq != null:
		var lwq_emitter_cell: Vector2i = Vector2i(lwq.get("_emitter_cell"))
		_check(NAME, lwq_emitter_cell == emitter.get_cell(), "LevelWorldQuery 发射器格 %s 应与配置格 %s 一致。" % [lwq_emitter_cell, emitter.get_cell()])
	await _fixture.free_settled(node)


## 23. 自检采样不再依赖旧 emitter_cell：启动后采样函数仍可用且 FixedEmitter 格在采样集合中。
func _test_23_self_check_no_old_field_dependency(scene: PackedScene) -> void:
	const NAME: String = "23_自检采样不依赖旧emitter_cell"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "_fixed_emitter 应已构造。")
	# 旧字段已删除，采样函数只能基于 _fixed_emitter.get_cell()；调用采集函数验证其不依赖旧字段且可正常运行。
	if fixed_emitter != null:
		var sample_cells = node.call("_collect_grid_coordinate_sample_cells")
		_check(NAME, sample_cells.has(fixed_emitter.get_cell()), "采样集合应包含 FixedEmitter 格 %s，实际 %s。" % [fixed_emitter.get_cell(), sample_cells])
	await _fixture.free_settled(node)


## 24. EmissionPreview 不参与真实发射：运行时（非编辑器）其 visible 为 false。
func _test_24_emission_preview_not_in_real_fire(scene: PackedScene) -> void:
	const NAME: String = "24_EmissionPreview运行时不参与真实发射"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _fixture.get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		await _fixture.free_settled(node)
		return
	var preview: _EmissionPreview = emitter.get_node_or_null("EmissionPreview") as _EmissionPreview
	_check(NAME, preview != null, "EmissionPreview 缺失。")
	if preview != null:
		_check(NAME, preview.visible == false, "运行时 EmissionPreview.visible 应为 false，不参与真实发射，实际 %s。" % [preview.visible])
	await _fixture.free_settled(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== 核心闭环发射器运行接线 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
