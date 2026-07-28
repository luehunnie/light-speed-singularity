extends SceneTree

## 核心闭环原型发射器场景契约测试（阶段 1 D3C-2）。
## 覆盖：生产脚本不再定义 emitter_cell / emitter_direction；RuntimeObjects/Emitter 为 EmitterConfigNode；
##   Emitter.position 是唯一场景位置事实、不保存 cell；光线方向仅由 ray_default_direction 保存；
##   启动后 FixedEmitter 格子/方向与 EmitterConfigNode 一致；build_fire_request 起点与方向来自新配置；
##   入树前改 position / ray_default_direction 后启动，FixedEmitter 使用新值；
##   改光粒方向但保持 RAY 不影响光线方向；PARTICLE 不静默创建 RAY FixedEmitter 且安全停止；
##   LevelWorldQuery 发射器格与新配置一致；自检采样不再依赖旧字段；LightPathLayer 独立；EmissionPreview 不参与真实发射；
##   不依赖 addons；测试结束释放节点无 SceneTree 残留。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 静态结构用例不挂入 SceneTree；接线用例挂入 root 并 await process_frame 触发真实 _ready，再读取既有私有状态验证。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _SCENE_FILE: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _SCRIPT_FILE: String = "res://levels/prototypes/core_loop_prototype.gd"
const _PROFILE_PATH: String = "res://assets/visual_profiles/emitter_visuals.tres"

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
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

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _profile: _ObjectVisualProfile = null


## SceneTree 初始化入口：先跑静态结构用例，再跑需触发 _ready 的接线用例，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_profile = load(_PROFILE_PATH) as _ObjectVisualProfile
	var static_node: Node2D = null
	if scene != null:
		static_node = scene.instantiate() as Node2D

	# 静态结构用例（不挂入 SceneTree，不触发 _ready）。
	_test_01_scene_loadable(scene, static_node)
	_test_02_no_emitter_cell_field(static_node)
	_test_03_no_emitter_direction_field(static_node)
	_test_04_no_old_fields_in_script_source()
	_test_05_emitter_is_config_node(static_node)
	_test_06_emitter_position_sole_fact(scene, static_node)
	_test_07_emitter_no_cell_saved(scene)
	_test_08_direction_only_via_ray_default(static_node)
	_test_09_default_light_form_ray(static_node)
	_test_10_emitter_visual_child(static_node)
	_test_11_emission_preview_child(static_node)
	_test_12_light_path_layer_independent(static_node)
	_test_13_ancestor_chain_identity(static_node)
	_test_14_no_addons(scene)

	if static_node != null:
		static_node.free()

	# 接线用例（挂入 root、await process_frame 触发真实 _ready，再读私有状态）。
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

	_check("25_释放后无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 取节点辅助 =====

## 取 RuntimeObjects/Emitter；root_node 为空时返回 null。
func _get_emitter(root_node: Node2D) -> _EmitterConfigNode:
	if root_node == null:
		return null
	return root_node.get_node_or_null("RuntimeObjects/Emitter") as _EmitterConfigNode


## 实例化场景并挂入 root，泵一帧触发真实 _ready；返回根节点（场景为空或实例化失败返回 null）。
func _instantiate_and_ready(scene: PackedScene) -> Node2D:
	if scene == null:
		return null
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		return null
	root.add_child(node)
	await process_frame
	return node


## 释放一个挂入过 root 的节点并泵一帧，让删除落地避免残留子节点影响后续用例。
func _free_settled(node: Node2D) -> void:
	if node == null:
		return
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 静态结构用例 =====

## 1. 场景可加载并实例化为 Node2D。
func _test_01_scene_loadable(scene: PackedScene, root_node: Node2D) -> void:
	const NAME: String = "01_场景可加载"
	_check(NAME, scene != null, "core_loop_prototype.tscn 加载失败。")
	_check(NAME, root_node != null, "场景实例化返回 null。")
	_check(NAME, root_node is Node2D, "根节点应为 Node2D。")


## 2. core_loop_prototype.gd 不再定义 emitter_cell 字段。
func _test_02_no_emitter_cell_field(root_node: Node2D) -> void:
	const NAME: String = "02_不再定义emitter_cell"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	_check(NAME, root_node.get("emitter_cell") == null, "emitter_cell 字段应已删除，实际仍存在 %s。" % [root_node.get("emitter_cell")])


## 3. core_loop_prototype.gd 不再定义 emitter_direction 字段。
func _test_03_no_emitter_direction_field(root_node: Node2D) -> void:
	const NAME: String = "03_不再定义emitter_direction"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	_check(NAME, root_node.get("emitter_direction") == null, "emitter_direction 字段应已删除，实际仍存在 %s。" % [root_node.get("emitter_direction")])


## 4. 生产脚本源码中不再出现旧字段名（含自检采样不再依赖旧字段）。
func _test_04_no_old_fields_in_script_source() -> void:
	const NAME: String = "04_脚本源码无旧字段"
	var f: FileAccess = FileAccess.open(_SCRIPT_FILE, FileAccess.READ)
	_check(NAME, f != null, "无法打开 core_loop_prototype.gd 读取文本。")
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	_check(NAME, not text.contains("emitter_cell"), "core_loop_prototype.gd 不应再出现 emitter_cell。")
	_check(NAME, not text.contains("emitter_direction"), "core_loop_prototype.gd 不应再出现 emitter_direction。")


## 5. RuntimeObjects/Emitter 为 EmitterConfigNode。
func _test_05_emitter_is_config_node(root_node: Node2D) -> void:
	const NAME: String = "05_Emitter为EmitterConfigNode"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	_check(NAME, emitter != null, "RuntimeObjects/Emitter 节点不存在。")
	_check(NAME, emitter is _EmitterConfigNode, "Emitter 应为 EmitterConfigNode。")


## 6. Emitter.position 是唯一场景位置事实：场景中 Emitter 节点保存 position 属性。
func _test_06_emitter_position_sole_fact(scene: PackedScene, root_node: Node2D) -> void:
	const NAME: String = "06_Emitter_position唯一位置事实"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	# 运行期实例 position 与场景保存值一致（cell (1,3) → 世界 (96,224)）。
	_check(NAME, emitter.position == _GridCoordinateRules.cell_to_world(Vector2i(1, 3)), "Emitter.position 期望 (96,224)，实际 %s。" % [emitter.position])
	if scene == null:
		_check(NAME, false, "场景未加载，无法检查 SceneState。")
		return
	var state: SceneState = scene.get_state()
	var found_emitter: bool = false
	var has_position: bool = false
	for i: int in range(state.get_node_count()):
		if state.get_node_name(i) == &"Emitter":
			found_emitter = true
			for j: int in range(state.get_node_property_count(i)):
				if state.get_node_property_name(i, j) == &"position":
					has_position = true
	_check(NAME, found_emitter, "SceneState 中未找到 Emitter 节点。")
	_check(NAME, has_position, "Emitter 节点应在场景中保存 position 属性。")


## 7. Emitter 节点未在场景中保存 cell 属性（位置为唯一事实，cell 由 position 派生）。
func _test_07_emitter_no_cell_saved(scene: PackedScene) -> void:
	const NAME: String = "07_Emitter不保存cell"
	if scene == null:
		_check(NAME, false, "场景未加载，无法检查 SceneState。")
		return
	var state: SceneState = scene.get_state()
	var found_emitter: bool = false
	var has_cell: bool = false
	for i: int in range(state.get_node_count()):
		if state.get_node_name(i) == &"Emitter":
			found_emitter = true
			for j: int in range(state.get_node_property_count(i)):
				if state.get_node_property_name(i, j) == &"cell":
					has_cell = true
	_check(NAME, found_emitter, "SceneState 中未找到 Emitter 节点。")
	_check(NAME, not has_cell, "Emitter 节点不应保存 cell 属性。")


## 8. 光线方向仅由 ray_default_direction 保存：场景中 Emitter 保存 ray_default_direction，不保存 emitter_direction。
func _test_08_direction_only_via_ray_default(root_node: Node2D) -> void:
	const NAME: String = "08_方向仅由ray_default_direction保存"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	# ray_default_direction 默认 RIGHT → 向量 (1,0)，与旧 emitter_direction 一致。
	_check(NAME, emitter.ray_default_direction == _EmitterConfigNode.RayDirection.RIGHT, "ray_default_direction 应为 RIGHT，实际 %d。" % [emitter.ray_default_direction])
	_check(NAME, _EmitterConfigNode.ray_direction_to_vector(emitter.ray_default_direction) == Vector2i.RIGHT, "光线方向向量应为 (1,0)。")


## 9. default_light_form 为 RAY。
func _test_09_default_light_form_ray(root_node: Node2D) -> void:
	const NAME: String = "09_默认形态RAY"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, emitter.default_light_form == _EmitterConfigNode.LightForm.RAY, "default_light_form 应为 RAY，实际 %d。" % [emitter.default_light_form])


## 10. EmitterVisual 为 Emitter 直属子节点且类型为 ObjectVisualView。
func _test_10_emitter_visual_child(root_node: Node2D) -> void:
	const NAME: String = "10_EmitterVisual直属ObjectVisualView"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var visual: Node = emitter.get_node_or_null("EmitterVisual")
	_check(NAME, visual != null, "EmitterVisual 子节点不存在。")
	_check(NAME, visual is _ObjectVisualView, "EmitterVisual 应为 ObjectVisualView。")
	_check(NAME, visual != null and visual.get_parent() == emitter, "EmitterVisual 应为 Emitter 直属子节点。")


## 11. EmissionPreview 为 Emitter 直属子节点且类型正确。
func _test_11_emission_preview_child(root_node: Node2D) -> void:
	const NAME: String = "11_EmissionPreview直属子节点"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var preview: Node = emitter.get_node_or_null("EmissionPreview")
	_check(NAME, preview != null, "EmissionPreview 子节点不存在。")
	_check(NAME, preview is _EmissionPreview, "EmissionPreview 类型应正确。")
	_check(NAME, preview != null and preview.get_parent() == emitter, "EmissionPreview 应为 Emitter 直属子节点。")


## 12. LightPathLayer 仍是根节点直属独立节点，不随 Emitter 移动。
func _test_12_light_path_layer_independent(root_node: Node2D) -> void:
	const NAME: String = "12_LightPathLayer根直属独立"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	var lpl: Node2D = root_node.get_node_or_null("LightPathLayer") as Node2D
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	_check(NAME, lpl != null, "LightPathLayer 节点不存在。")
	_check(NAME, lpl != null and lpl.get_parent() == root_node, "LightPathLayer 应为根节点直属子节点。")
	_check(NAME, lpl != null and emitter != null and not lpl.is_ancestor_of(emitter), "LightPathLayer 不应是 Emitter 的祖先。")
	_check(NAME, lpl != null and emitter != null and not emitter.is_ancestor_of(lpl), "Emitter 不应是 LightPathLayer 的祖先。")


## 13. Emitter/RuntimeObjects 祖先链单位 Transform（Emitter 仅承载 origin，基为单位）。
func _test_13_ancestor_chain_identity(root_node: Node2D) -> void:
	const NAME: String = "13_Emitter祖先链单位Transform"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	_check(NAME, root_node.transform == Transform2D.IDENTITY, "根节点 Transform 应为单位，实际 %s。" % [root_node.transform])
	var runtime_objects: Node2D = root_node.get_node_or_null("RuntimeObjects") as Node2D
	_check(NAME, runtime_objects != null, "RuntimeObjects 节点不存在。")
	_check(NAME, runtime_objects != null and runtime_objects.transform == Transform2D.IDENTITY, "RuntimeObjects Transform 应为单位，实际 %s。" % [runtime_objects.transform])
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter != null:
		_check(NAME, emitter.rotation == 0.0, "Emitter rotation 应为 0，实际 %s。" % [emitter.rotation])
		_check(NAME, emitter.scale == Vector2.ONE, "Emitter scale 应为 (1,1)，实际 %s。" % [emitter.scale])
		_check(NAME, emitter.get_parent() == runtime_objects, "Emitter 应为 RuntimeObjects 直属子节点。")


## 14. 不依赖 addons：场景文件与资源路径不含 addons。
func _test_14_no_addons(scene: PackedScene) -> void:
	const NAME: String = "14_不依赖addons"
	var f: FileAccess = FileAccess.open(_SCENE_FILE, FileAccess.READ)
	_check(NAME, f != null, "无法打开 core_loop_prototype.tscn 读取文本。")
	if f != null:
		var text: String = f.get_as_text()
		f.close()
		_check(NAME, not text.contains("addons"), "场景文件不应引用 addons。")
	_check(NAME, not _SCENE_PATH.contains("addons"), "场景路径不应含 addons。")


# ===== 接线用例（挂入 SceneTree 触发真实 _ready） =====

## 15. 启动后 _fixed_emitter.get_cell() 与 EmitterConfigNode.get_cell() 一致。
func _test_15_fixed_emitter_cell_matches_config(scene: PackedScene) -> void:
	const NAME: String = "15_FixedEmitter格子与配置一致"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "_fixed_emitter 应已构造，实际 null。")
	if fixed_emitter != null and emitter != null:
		_check(NAME, fixed_emitter.get_cell() == emitter.get_cell(), "FixedEmitter 格 %s 应与 EmitterConfigNode.get_cell() %s 一致。" % [fixed_emitter.get_cell(), emitter.get_cell()])
	await _free_settled(node)


## 16. 启动后 FixedEmitter 方向与 EmitterConfigNode.get_ray_direction_vector() 一致。
func _test_16_fixed_emitter_direction_matches_config(scene: PackedScene) -> void:
	const NAME: String = "16_FixedEmitter方向与配置一致"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	if fixed_emitter == null or emitter == null:
		_check(NAME, false, "FixedEmitter 或 Emitter 缺失。")
		await _free_settled(node)
		return
	_check(NAME, fixed_emitter.get_direction() == emitter.get_ray_direction_vector(), "FixedEmitter 方向 %s 应与 get_ray_direction_vector() %s 一致。" % [fixed_emitter.get_direction(), emitter.get_ray_direction_vector()])
	await _free_settled(node)


## 17. FixedEmitter.build_fire_request() 的起点与方向来自新配置。
func _test_17_build_fire_request_from_config(scene: PackedScene) -> void:
	const NAME: String = "17_build_fire_request来自新配置"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _get_emitter(node)
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	if fixed_emitter == null or emitter == null:
		_check(NAME, false, "FixedEmitter 或 Emitter 缺失。")
		await _free_settled(node)
		return
	var request: _FireRequest = fixed_emitter.build_fire_request(128)
	_check(NAME, request != null, "合法方向下 build_fire_request 不应返回 null。")
	if request != null:
		_check(NAME, request.get_start_cell() == emitter.get_cell(), "FireRequest 起点 %s 应与配置格 %s 一致。" % [request.get_start_cell(), emitter.get_cell()])
		_check(NAME, request.get_direction() == emitter.get_ray_direction_vector(), "FireRequest 方向 %s 应与配置方向 %s 一致。" % [request.get_direction(), emitter.get_ray_direction_vector()])
	await _free_settled(node)


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
	var emitter: _EmitterConfigNode = _get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	var moved_cell: Vector2i = Vector2i(5, 6)
	emitter.position = _GridCoordinateRules.cell_to_world(moved_cell)
	root.add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "改 position 后 _fixed_emitter 应仍构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_cell() == moved_cell, "FixedEmitter 格 %s 应为入树前修改的格 %s。" % [fixed_emitter.get_cell(), moved_cell])
	await _free_settled(node)


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
	var emitter: _EmitterConfigNode = _get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	emitter.ray_default_direction = _EmitterConfigNode.RayDirection.UP
	root.add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	var expected_vec: Vector2i = _EmitterConfigNode.ray_direction_to_vector(_EmitterConfigNode.RayDirection.UP)
	_check(NAME, fixed_emitter != null, "改方向后 _fixed_emitter 应仍构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_direction() == expected_vec, "FixedEmitter 方向 %s 应为入树前修改的 UP 向量 %s。" % [fixed_emitter.get_direction(), expected_vec])
	await _free_settled(node)


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
	var emitter: _EmitterConfigNode = _get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	# 保持 RAY，把光粒方向改为 LEFT；光线方向应仍为 ray_default_direction（RIGHT）。
	emitter.particle_default_direction = _EmitterConfigNode.ParticleDirection.LEFT
	root.add_child(node)
	await process_frame
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "保持 RAY 时 _fixed_emitter 应已构造。")
	if fixed_emitter != null:
		_check(NAME, fixed_emitter.get_direction() == Vector2i.RIGHT, "改光粒方向后光线方向应仍为 (1,0)，实际 %s。" % [fixed_emitter.get_direction()])
	await _free_settled(node)


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
	var emitter: _EmitterConfigNode = _get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		node.free()
		return
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	root.add_child(node)
	await process_frame
	# PARTICLE 未接运行时：不构造 FixedEmitter，不构造运行期编排控制器，避免后续空引用。
	_check(NAME, node.get("_fixed_emitter") == null, "PARTICLE 不应静默创建 RAY FixedEmitter，实际非 null。")
	_check(NAME, node.get("_level_runtime_controller") == null, "PARTICLE 不应构造运行期编排控制器，实际非 null。")
	_check(NAME, is_instance_valid(node), "PARTICLE 安全停止后节点应仍有效，不应崩溃释放。")
	await _free_settled(node)


## 22. LevelWorldQuery 的发射器格与新配置一致。
func _test_22_level_world_query_cell_matches(scene: PackedScene) -> void:
	const NAME: String = "22_LevelWorldQuery发射器格与新配置一致"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _get_emitter(node)
	var lwq: Variant = node.get("_level_world_query")
	_check(NAME, lwq != null, "_level_world_query 应已构造，实际 null。")
	if emitter != null and lwq != null:
		var lwq_emitter_cell: Vector2i = Vector2i(lwq.get("_emitter_cell"))
		_check(NAME, lwq_emitter_cell == emitter.get_cell(), "LevelWorldQuery 发射器格 %s 应与配置格 %s 一致。" % [lwq_emitter_cell, emitter.get_cell()])
	await _free_settled(node)


## 23. 自检采样不再依赖旧 emitter_cell：启动后采样函数仍可用且 FixedEmitter 格在采样集合中。
func _test_23_self_check_no_old_field_dependency(scene: PackedScene) -> void:
	const NAME: String = "23_自检采样不依赖旧emitter_cell"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var fixed_emitter: _FixedEmitter = node.get("_fixed_emitter") as _FixedEmitter
	_check(NAME, fixed_emitter != null, "_fixed_emitter 应已构造。")
	# 旧字段已删除，采样函数只能基于 _fixed_emitter.get_cell()；调用采集函数验证其不依赖旧字段且可正常运行。
	if fixed_emitter != null:
		var sample_cells = node.call("_collect_grid_coordinate_sample_cells")
		_check(NAME, sample_cells.has(fixed_emitter.get_cell()), "采样集合应包含 FixedEmitter 格 %s，实际 %s。" % [fixed_emitter.get_cell(), sample_cells])
	await _free_settled(node)


## 24. EmissionPreview 不参与真实发射：运行时（非编辑器）其 visible 为 false。
func _test_24_emission_preview_not_in_real_fire(scene: PackedScene) -> void:
	const NAME: String = "24_EmissionPreview运行时不参与真实发射"
	var node: Node2D = await _instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var emitter: _EmitterConfigNode = _get_emitter(node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		await _free_settled(node)
		return
	var preview: _EmissionPreview = emitter.get_node_or_null("EmissionPreview") as _EmissionPreview
	_check(NAME, preview != null, "EmissionPreview 缺失。")
	if preview != null:
		_check(NAME, preview.visible == false, "运行时 EmissionPreview.visible 应为 false，不参与真实发射，实际 %s。" % [preview.visible])
	await _free_settled(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 25
	var passed_checks: int = _checks - _failures.size()
	print("==== 核心闭环发射器场景契约测试摘要 ====")
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
