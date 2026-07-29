extends SceneTree

## 核心闭环原型场景静态结构与节点接线测试（拆分片 1/3 · D4.6-T5）。
## 覆盖：场景可加载；生产脚本不再定义 emitter_cell/emitter_direction；RuntimeObjects/Emitter 为 EmitterConfigNode；
##   Emitter.position 是唯一场景位置事实、不保存 cell；光线方向仅由 ray_default_direction 保存；default_light_form 为 RAY；
##   EmitterVisual/EmissionPreview 直属子节点；LightPathLayer 根直属独立；Emitter 祖先链单位 Transform；不依赖 addons。
## 静态结构用例不挂入 SceneTree，不触发 _ready；场景加载/节点定位/清理见 fixtures/core_loop_scene_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _SCENE_FILE: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _SCRIPT_FILE: String = "res://levels/prototypes/core_loop_prototype.gd"

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _Fixture: GDScript = preload(
	"res://tests/integration/emitters/fixtures/core_loop_scene_fixture.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture: _Fixture = null


## SceneTree 初始化入口：加载场景并实例化静态根，跑静态结构用例，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_fixture = _Fixture.new(self)
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

	_report()
	quit(0 if _failures.is_empty() else 1)


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
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
	_check(NAME, emitter != null, "RuntimeObjects/Emitter 节点不存在。")
	_check(NAME, emitter is _EmitterConfigNode, "Emitter 应为 EmitterConfigNode。")


## 6. Emitter.position 是唯一场景位置事实：场景中 Emitter 节点保存 position 属性。
func _test_06_emitter_position_sole_fact(scene: PackedScene, root_node: Node2D) -> void:
	const NAME: String = "06_Emitter_position唯一位置事实"
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
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
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	# ray_default_direction 默认 RIGHT → 向量 (1,0)，与旧 emitter_direction 一致。
	_check(NAME, emitter.ray_default_direction == _EmitterConfigNode.RayDirection.RIGHT, "ray_default_direction 应为 RIGHT，实际 %d。" % [emitter.ray_default_direction])
	_check(NAME, _EmitterConfigNode.ray_direction_to_vector(emitter.ray_default_direction) == Vector2i.RIGHT, "光线方向向量应为 (1,0)。")


## 9. default_light_form 为 RAY。
func _test_09_default_light_form_ray(root_node: Node2D) -> void:
	const NAME: String = "09_默认形态RAY"
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
	if emitter == null:
		_check(NAME, false, "Emitter 缺失。")
		return
	_check(NAME, emitter.default_light_form == _EmitterConfigNode.LightForm.RAY, "default_light_form 应为 RAY，实际 %d。" % [emitter.default_light_form])


## 10. EmitterVisual 为 Emitter 直属子节点且类型为 ObjectVisualView。
func _test_10_emitter_visual_child(root_node: Node2D) -> void:
	const NAME: String = "10_EmitterVisual直属ObjectVisualView"
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
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
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
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
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
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
	var emitter: _EmitterConfigNode = _fixture.get_emitter(root_node)
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


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 14
	var passed_checks: int = _checks - _failures.size()
	print("==== 核心闭环场景静态结构 测试摘要 ====")
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
