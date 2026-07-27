extends SceneTree

## 核心闭环原型发射器场景契约测试（阶段 1 D3C-1）。
## 覆盖：场景可加载；RuntimeObjects/Emitter 为 EmitterConfigNode；Emitter.position 等于旧 emitter_cell 格中心；
##   Emitter 不保存 cell；default_light_form 为 RAY；ray_default_direction 与旧 emitter_direction 一致；
##   particle_default_direction 为 RIGHT；editor_preview_visible 为 true；
##   EmitterVisual 为直属子节点且 ObjectVisualView、本地原点、使用 emitter_visuals.tres；
##   Profile default_state_id 与状态 ID 一致且 world_texture 非空；
##   EmissionPreview 为直属子节点且类型正确且本地原点；
##   LightPathLayer 仍为根直属独立节点且单位 Transform；Emitter/RuntimeObjects 祖先链单位 Transform；
##   旧 emitter_cell/emitter_direction 仍存在且与新配置一致；不执行正式发射流程；不依赖 addons。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 全程不把场景挂入 SceneTree，避免触发 CoreLoopPrototype._ready 与正式运行时编排/自检。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _SCENE_FILE: String = "res://levels/prototypes/core_loop_prototype.tscn"
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

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _profile: _ObjectVisualProfile = null


func _initialize() -> void:
	# 运行时 load：场景或资源异常时返回 null，由用例优雅报告而非编译期失败。
	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_profile = load(_PROFILE_PATH) as _ObjectVisualProfile
	var root_node: Node2D = null
	if scene != null:
		root_node = scene.instantiate() as Node2D

	_test_01_scene_loadable(scene, root_node)
	_test_02_emitter_is_config_node(root_node)
	_test_03_emitter_position(root_node)
	_test_04_emitter_no_cell_saved(scene)
	_test_05_default_light_form_ray(root_node)
	_test_06_ray_direction_matches_old(root_node)
	_test_07_particle_direction_right(root_node)
	_test_08_editor_preview_visible(root_node)
	_test_09_emitter_visual_child(root_node)
	_test_10_emitter_visual_local_zero(root_node)
	_test_11_emitter_visual_uses_profile(root_node)
	_test_12_profile_default_state_consistent()
	_test_13_profile_world_texture_nonempty()
	_test_14_emission_preview_child(root_node)
	_test_15_emission_preview_local_zero(root_node)
	_test_16_light_path_layer_independent(root_node)
	_test_17_light_path_layer_identity(root_node)
	_test_18_ancestor_chain_identity(root_node)
	_test_19_old_fields_consistent_with_new(root_node)
	_test_20_no_runtime_fire(root_node)
	_test_21_no_addons()

	if root_node != null:
		root_node.free()
	_check("22_释放后无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 取节点辅助 =====

## 取 RuntimeObjects/Emitter；root_node 为空时返回 null。
func _get_emitter(root_node: Node2D) -> _EmitterConfigNode:
	if root_node == null:
		return null
	return root_node.get_node_or_null("RuntimeObjects/Emitter") as _EmitterConfigNode


# ===== 测试用例 =====

## 1. 场景可加载并实例化为 Node2D。
func _test_01_scene_loadable(scene: PackedScene, root_node: Node2D) -> void:
	const NAME: String = "01_场景可加载"
	_check(NAME, scene != null, "core_loop_prototype.tscn 加载失败。")
	_check(NAME, root_node != null, "场景实例化返回 null。")
	_check(NAME, root_node is Node2D, "根节点应为 Node2D。")


## 2. RuntimeObjects/Emitter 为 EmitterConfigNode。
func _test_02_emitter_is_config_node(root_node: Node2D) -> void:
	const NAME: String = "02_Emitter为EmitterConfigNode"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	_check(NAME, emitter != null, "RuntimeObjects/Emitter 节点不存在。")
	_check(NAME, emitter is _EmitterConfigNode, "Emitter 应为 EmitterConfigNode。")


## 3. Emitter.position 等于旧 emitter_cell 经 cell_to_world 的格中心。
func _test_03_emitter_position(root_node: Node2D) -> void:
	const NAME: String = "03_Emitter位置为格中心"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失，无法校验位置。")
		return
	var old_cell: Vector2i = Vector2i(root_node.get("emitter_cell"))
	var expected: Vector2 = _GridCoordinateRules.cell_to_world(old_cell)
	_check(NAME, emitter.position == expected, "Emitter.position 期望 %s（cell_to_world(%s)），实际 %s。" % [expected, old_cell, emitter.position])


## 4. Emitter 节点未在场景中保存 cell 属性（位置为唯一事实）。
func _test_04_emitter_no_cell_saved(scene: PackedScene) -> void:
	const NAME: String = "04_Emitter不保存cell"
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


## 5. default_light_form 为 RAY。
func _test_05_default_light_form_ray(root_node: Node2D) -> void:
	const NAME: String = "05_默认形态RAY"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, emitter.default_light_form == _EmitterConfigNode.LightForm.RAY, "default_light_form 应为 RAY，实际 %d。" % [emitter.default_light_form])


## 6. ray_default_direction 与旧 emitter_direction 一致。
func _test_06_ray_direction_matches_old(root_node: Node2D) -> void:
	const NAME: String = "06_光线方向与旧emitter_direction一致"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var old_dir: Vector2i = Vector2i(root_node.get("emitter_direction"))
	var new_vec: Vector2i = _EmitterConfigNode.ray_direction_to_vector(emitter.ray_default_direction)
	_check(NAME, new_vec == old_dir, "新光线方向向量 %s 应与旧 emitter_direction %s 一致。" % [new_vec, old_dir])


## 7. particle_default_direction 为 RIGHT。
func _test_07_particle_direction_right(root_node: Node2D) -> void:
	const NAME: String = "07_光粒方向RIGHT"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, emitter.particle_default_direction == _EmitterConfigNode.ParticleDirection.RIGHT, "particle_default_direction 应为 RIGHT，实际 %d。" % [emitter.particle_default_direction])


## 8. editor_preview_visible 为 true。
func _test_08_editor_preview_visible(root_node: Node2D) -> void:
	const NAME: String = "08_编辑器预览可见"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, emitter.editor_preview_visible == true, "editor_preview_visible 应为 true，实际 %s。" % [emitter.editor_preview_visible])


## 9. EmitterVisual 为 Emitter 直属子节点且类型为 ObjectVisualView。
func _test_09_emitter_visual_child(root_node: Node2D) -> void:
	const NAME: String = "09_EmitterVisual直属ObjectVisualView"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var visual: Node = emitter.get_node_or_null("EmitterVisual")
	_check(NAME, visual != null, "EmitterVisual 子节点不存在。")
	_check(NAME, visual is _ObjectVisualView, "EmitterVisual 应为 ObjectVisualView。")
	_check(NAME, visual != null and visual.get_parent() == emitter, "EmitterVisual 应为 Emitter 直属子节点。")


## 10. EmitterVisual 本地位置为 Vector2.ZERO。
func _test_10_emitter_visual_local_zero(root_node: Node2D) -> void:
	const NAME: String = "10_EmitterVisual本地原点"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var visual: _ObjectVisualView = emitter.get_node_or_null("EmitterVisual") as _ObjectVisualView
	if visual == null:
		_check(NAME, false, "EmitterVisual 缺失或类型不符。")
		return
	_check(NAME, visual.position == Vector2.ZERO, "EmitterVisual.position 应为 ZERO，实际 %s。" % [visual.position])


## 11. EmitterVisual 使用 emitter_visuals.tres。
func _test_11_emitter_visual_uses_profile(root_node: Node2D) -> void:
	const NAME: String = "11_EmitterVisual使用emitter_visuals.tres"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var visual: _ObjectVisualView = emitter.get_node_or_null("EmitterVisual") as _ObjectVisualView
	if visual == null:
		_check(NAME, false, "EmitterVisual 缺失或类型不符。")
		return
	_check(NAME, visual.visual_profile != null, "EmitterVisual.visual_profile 不应为空。")
	if visual.visual_profile == null:
		return
	_check(NAME, visual.visual_profile.resource_path == _PROFILE_PATH, "visual_profile 路径应为 %s，实际 %s。" % [_PROFILE_PATH, visual.visual_profile.resource_path])
	# DisplayMode 默认 WORLD、FeedbackState 默认 NONE。
	_check(NAME, visual.get_display_mode() == _ObjectVisualView.DisplayMode.WORLD, "DisplayMode 应为 WORLD，实际 %d。" % [visual.get_display_mode()])
	_check(NAME, visual.get_feedback() == _ObjectVisualView.FeedbackState.NONE, "FeedbackState 应为 NONE，实际 %d。" % [visual.get_feedback()])
	_check(NAME, visual.initial_state_id == &"default", "initial_state_id 应为 default，实际 %s。" % [visual.initial_state_id])
	_check(NAME, visual.visible == true, "EmitterVisual 应可见。")


## 12. Profile default_state_id 与状态 ID 一致。
func _test_12_profile_default_state_consistent() -> void:
	const NAME: String = "12_Profile默认状态一致"
	if _profile == null:
		_check(NAME, false, "emitter_visuals.tres 加载失败。")
		return
	_check(NAME, _profile.default_state_id == &"default", "default_state_id 应为 default，实际 %s。" % [_profile.default_state_id])
	_check(NAME, _profile.states.size() >= 1, "states 应至少 1 项，实际 %d。" % [_profile.states.size()])
	if _profile.states.size() >= 1 and _profile.states[0] != null:
		_check(NAME, _profile.states[0].state_id == _profile.default_state_id, "状态 ID %s 应与 default_state_id %s 一致。" % [_profile.states[0].state_id, _profile.default_state_id])


## 13. Profile world_texture 非空。
func _test_13_profile_world_texture_nonempty() -> void:
	const NAME: String = "13_Profile_world_texture非空"
	if _profile == null:
		_check(NAME, false, "emitter_visuals.tres 加载失败。")
		return
	if _profile.states.size() >= 1 and _profile.states[0] != null:
		_check(NAME, _profile.states[0].world_texture != null, "default 状态 world_texture 不应为空。")
	else:
		_check(NAME, false, "states[0] 缺失，无法校验 world_texture。")


## 14. EmissionPreview 为 Emitter 直属子节点且类型正确。
func _test_14_emission_preview_child(root_node: Node2D) -> void:
	const NAME: String = "14_EmissionPreview直属子节点"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var preview: Node = emitter.get_node_or_null("EmissionPreview")
	_check(NAME, preview != null, "EmissionPreview 子节点不存在。")
	_check(NAME, preview is _EmissionPreview, "EmissionPreview 类型应正确。")
	_check(NAME, preview != null and preview.get_parent() == emitter, "EmissionPreview 应为 Emitter 直属子节点。")


## 15. EmissionPreview 本地位置为 Vector2.ZERO。
func _test_15_emission_preview_local_zero(root_node: Node2D) -> void:
	const NAME: String = "15_EmissionPreview本地原点"
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	var preview: _EmissionPreview = emitter.get_node_or_null("EmissionPreview") as _EmissionPreview
	if preview == null:
		_check(NAME, false, "EmissionPreview 缺失或类型不符。")
		return
	_check(NAME, preview.position == Vector2.ZERO, "EmissionPreview.position 应为 ZERO，实际 %s。" % [preview.position])


## 16. LightPathLayer 仍是根节点直属独立节点，不随 Emitter 移动。
func _test_16_light_path_layer_independent(root_node: Node2D) -> void:
	const NAME: String = "16_LightPathLayer根直属独立"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	var lpl: Node2D = root_node.get_node_or_null("LightPathLayer") as Node2D
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	_check(NAME, lpl != null, "LightPathLayer 节点不存在。")
	_check(NAME, lpl != null and lpl.get_parent() == root_node, "LightPathLayer 应为根节点直属子节点。")
	_check(NAME, lpl != null and emitter != null and not lpl.is_ancestor_of(emitter), "LightPathLayer 不应是 Emitter 的祖先。")
	_check(NAME, lpl != null and emitter != null and not emitter.is_ancestor_of(lpl), "Emitter 不应是 LightPathLayer 的祖先。")


## 17. LightPathLayer Transform 保持单位。
func _test_17_light_path_layer_identity(root_node: Node2D) -> void:
	const NAME: String = "17_LightPathLayer单位Transform"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	var lpl: Node2D = root_node.get_node_or_null("LightPathLayer") as Node2D
	if lpl == null:
		_check(NAME, false, "LightPathLayer 缺失。")
		return
	_check(NAME, lpl.transform == Transform2D.IDENTITY, "LightPathLayer Transform 应为单位，实际 %s。" % [lpl.transform])


## 18. Emitter/RuntimeObjects 祖先链单位 Transform（Emitter 仅承载 origin，基为单位）。
func _test_18_ancestor_chain_identity(root_node: Node2D) -> void:
	const NAME: String = "18_Emitter祖先链单位Transform"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	_check(NAME, root_node.transform == Transform2D.IDENTITY, "根节点 Transform 应为单位，实际 %s。" % [root_node.transform])
	var runtime_objects: Node2D = root_node.get_node_or_null("RuntimeObjects") as Node2D
	_check(NAME, runtime_objects != null, "RuntimeObjects 节点不存在。")
	_check(NAME, runtime_objects != null and runtime_objects.transform == Transform2D.IDENTITY, "RuntimeObjects Transform 应为单位，实际 %s。" % [runtime_objects.transform])
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter != null:
		# Emitter 承载位置事实（origin 非零），但旋转/缩放基应为单位。
		_check(NAME, emitter.rotation == 0.0, "Emitter rotation 应为 0，实际 %s。" % [emitter.rotation])
		_check(NAME, emitter.scale == Vector2.ONE, "Emitter scale 应为 (1,1)，实际 %s。" % [emitter.scale])
		_check(NAME, emitter.get_parent() == runtime_objects, "Emitter 应为 RuntimeObjects 直属子节点。")


## 19. 旧 emitter_cell / emitter_direction 仍存在且与新配置一致（D3C-2 前过渡双事实）。
func _test_19_old_fields_consistent_with_new(root_node: Node2D) -> void:
	const NAME: String = "19_旧字段与新配置一致"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	var old_cell: Variant = root_node.get("emitter_cell")
	var old_dir: Variant = root_node.get("emitter_direction")
	_check(NAME, old_cell != null, "旧 emitter_cell 字段应仍存在。")
	_check(NAME, old_dir != null, "旧 emitter_direction 字段应仍存在。")
	var emitter: _EmitterConfigNode = _get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, Vector2i(old_cell) == emitter.cell, "旧 emitter_cell %s 应与 Emitter 派生格 %s 一致。" % [Vector2i(old_cell), emitter.cell])
	var new_vec: Vector2i = _EmitterConfigNode.ray_direction_to_vector(emitter.ray_default_direction)
	_check(NAME, Vector2i(old_dir) == new_vec, "旧 emitter_direction %s 应与新光线方向向量 %s 一致。" % [Vector2i(old_dir), new_vec])


## 20. 不加载或执行正式发射流程：场景未入树，运行时编排控制器与固定发射器均未构造。
func _test_20_no_runtime_fire(root_node: Node2D) -> void:
	const NAME: String = "20_不执行正式发射流程"
	if root_node == null:
		_check(NAME, false, "根节点缺失。")
		return
	_check(NAME, not root_node.is_inside_tree(), "场景不应挂入 SceneTree。")
	_check(NAME, root_node.get("_level_runtime_controller") == null, "_level_runtime_controller 应未构造（null），实际 %s。" % [root_node.get("_level_runtime_controller")])
	_check(NAME, root_node.get("_fixed_emitter") == null, "_fixed_emitter 应未构造（null），实际 %s。" % [root_node.get("_fixed_emitter")])


## 21. 不依赖 addons：场景文件与资源路径不含 addons。
func _test_21_no_addons() -> void:
	const NAME: String = "21_不依赖addons"
	var f: FileAccess = FileAccess.open(_SCENE_FILE, FileAccess.READ)
	_check(NAME, f != null, "无法打开 core_loop_prototype.tscn 读取文本。")
	if f != null:
		var text: String = f.get_as_text()
		f.close()
		_check(NAME, not text.contains("addons"), "场景文件不应引用 addons。")
	_check(NAME, not _SCENE_PATH.contains("addons"), "场景路径不应含 addons。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 22
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
