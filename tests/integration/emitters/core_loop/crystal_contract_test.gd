extends SceneTree

## 核心闭环 Crystal 场景契约与释放残留测试（拆分片 3/3 · D4.6-T5）。
## 覆盖：Crystal 为 BasicCrystal、cell==Vector2i(3,1)、position==该格中心；场景不保存 cell、保存 position；
##   VisualView 本地 position 归零、visual_profile 仍为 basic_crystal_visuals.tres；初始 unlit，activate 后 lit，reset_runtime 后恢复 unlit；
##   测试结束释放节点无 SceneTree 残留。
## 接线用例挂入 root 并 await process_frame 触发真实 _ready；场景加载/清理见 fixtures/core_loop_scene_fixture.gd。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _CRYSTAL_PROFILE_PATH: String = "res://assets/visual_profiles/basic_crystal_visuals.tres"

const _BasicCrystal: GDScript = preload(
	"res://gameplay/crystals/basic_crystal.gd"
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


## SceneTree 初始化入口：加载场景，跑 Crystal 契约用例，校验释放无残留，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_fixture = _Fixture.new(self)

	await _test_25_crystal_cell_and_position(scene)
	_test_26_crystal_no_cell_saved_in_scene(scene)
	await _test_27_crystal_visualview_zero_and_profile(scene)
	await _test_28_crystal_unlit_activate_lit_reset_unlit(scene)

	_check("29_释放后无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== Crystal 位置契约用例（D4A） =====

## 25. Crystal 为 BasicCrystal，cell==Vector2i(3,1)，position==该格中心 (224,96)。
func _test_25_crystal_cell_and_position(scene: PackedScene) -> void:
	const NAME: String = "25_Crystal格与位置"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var crystal: _BasicCrystal = node.get_node_or_null("RuntimeObjects/Crystal") as _BasicCrystal
	_check(NAME, crystal != null, "RuntimeObjects/Crystal 节点不存在。")
	if crystal != null:
		_check(NAME, crystal is _BasicCrystal, "Crystal 应为 BasicCrystal。")
		_check(NAME, crystal.cell == Vector2i(3, 1), "Crystal.cell 期望 (3,1)，实际 %s。" % [crystal.cell])
		var expected_pos: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
		_check(NAME, crystal.position == expected_pos, "Crystal.position 期望 %s，实际 %s。" % [expected_pos, crystal.position])
	await _fixture.free_settled(node)


## 26. Crystal 节点场景中不保存 cell、保存 position（position 为唯一位置事实）。
func _test_26_crystal_no_cell_saved_in_scene(scene: PackedScene) -> void:
	const NAME: String = "26_Crystal不保存cell保存position"
	if scene == null:
		_check(NAME, false, "场景未加载，无法检查 SceneState。")
		return
	var state: SceneState = scene.get_state()
	var found_crystal: bool = false
	var has_cell: bool = false
	var has_position: bool = false
	for i: int in range(state.get_node_count()):
		if state.get_node_name(i) == &"Crystal":
			found_crystal = true
			for j: int in range(state.get_node_property_count(i)):
				var pname: StringName = state.get_node_property_name(i, j)
				if pname == &"cell":
					has_cell = true
				elif pname == &"position":
					has_position = true
	_check(NAME, found_crystal, "SceneState 中未找到 Crystal 节点。")
	_check(NAME, not has_cell, "Crystal 节点不应保存 cell 属性。")
	_check(NAME, has_position, "Crystal 节点应保存 position 属性。")


## 27. Crystal/VisualView 本地 position 归零、visual_profile 仍为 basic_crystal_visuals.tres。
func _test_27_crystal_visualview_zero_and_profile(scene: PackedScene) -> void:
	const NAME: String = "27_VisualView归零且profile不变"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var crystal: _BasicCrystal = node.get_node_or_null("RuntimeObjects/Crystal") as _BasicCrystal
	if crystal == null:
		_check(NAME, false, "Crystal 缺失。")
		await _fixture.free_settled(node)
		return
	var view: _ObjectVisualView = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, view != null, "VisualView 子节点不存在。")
	if view != null:
		_check(NAME, view.position == Vector2.ZERO, "VisualView 本地 position 应归零，实际 %s。" % [view.position])
		_check(NAME, view.get_parent() == crystal, "VisualView 应为 Crystal 直属子节点。")
		_check(NAME, view.visual_profile != null, "VisualView.visual_profile 不应为空。")
		_check(NAME, view.visual_profile != null and view.visual_profile.resource_path == _CRYSTAL_PROFILE_PATH, "visual_profile 应为 basic_crystal_visuals.tres，实际 %s。" % [view.visual_profile.resource_path if view.visual_profile != null else "null"])
	await _fixture.free_settled(node)


## 28. 初始 unlit，activate 后 lit，reset_runtime 后恢复 unlit。
func _test_28_crystal_unlit_activate_lit_reset_unlit(scene: PackedScene) -> void:
	const NAME: String = "28_Crystal初始unlit激活lit重置unlit"
	var node: Node2D = await _fixture.instantiate_and_ready(scene)
	if node == null:
		_check(NAME, false, "场景实例化或入树失败。")
		return
	var crystal: _BasicCrystal = node.get_node_or_null("RuntimeObjects/Crystal") as _BasicCrystal
	var view: _ObjectVisualView = null
	if crystal != null:
		view = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, crystal != null and view != null, "Crystal 或 VisualView 缺失。")
	if crystal != null and view != null:
		_check(NAME, not crystal.is_activated, "初始应未点亮。")
		_check(NAME, view.get_content_state() == &"unlit", "初始内容状态应为 unlit，实际 %s。" % [view.get_content_state()])
		crystal.activate()
		_check(NAME, crystal.is_activated, "activate 后应已点亮。")
		_check(NAME, view.get_content_state() == &"lit", "activate 后内容状态应为 lit，实际 %s。" % [view.get_content_state()])
		crystal.reset_runtime()
		_check(NAME, not crystal.is_activated, "reset 后应未点亮。")
		_check(NAME, view.get_content_state() == &"unlit", "reset 后内容状态应为 unlit，实际 %s。" % [view.get_content_state()])
	await _fixture.free_settled(node)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== 核心闭环 Crystal 场景契约 测试摘要 ====")
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
