extends SceneTree

## BasicCrystal PackedScene 模板契约测试（OBJ-A）。
## 覆盖：模板根局部原点 (0,0)；直属子节点无 (32,32) 二次补偿；两实例 position 独立；
##   点亮其中一个不影响另一个；两实例共享默认 VisualProfile；可变运行状态不共享且不写入共享资源。
## 位置契约：position 是唯一位置事实，cell 由 position 经 GridCoordinateRules 派生，(32,32) 仅是 64×64 格左上角到中心的偏移。
## 共享 Profile 不变性：activate/lit/reset 任一实例时不改写共享 VisualProfile 引用，且 Profile 内每个状态条目的
##   state_id、world_texture、drag_texture 及 default_state_id、inventory_icon 字段内容逐字段保持一致。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _SCENE_PATH: String = "res://gameplay/crystals/basic_crystal.tscn"
const _PROFILE_PATH: String = "res://assets/visual_profiles/basic_crystal_visuals.tres"

const _BasicCrystal: GDScript = preload(
	"res://gameplay/crystals/basic_crystal.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 本轮创建的水晶实例，统一释放避免 --script 模式泄漏。
var _instances: Array[BasicCrystal] = []


## SceneTree 初始化入口：加载模板场景，跑模板契约用例，最后统一释放、报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_模板可加载", scene != null, "basic_crystal.tscn 加载失败。")
	if scene == null:
		_report()
		quit(1)
		return

	await _test_01_template_root_origin_zero(scene)
	await _test_02_no_child_32_32_compensation(scene)
	await _test_03_two_instances_position_independent(scene)
	await _test_04_lighting_one_does_not_affect_other(scene)
	await _test_05_shared_default_visual_profile(scene)
	await _test_06_mutable_runtime_state_not_shared(scene)

	_cleanup()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 模板契约用例 =====

## 1. 模板根节点局部原点为 (0,0)：未覆盖 position 的模板实例 position 归零，cell 由 (0,0) 派生。
func _test_01_template_root_origin_zero(scene: PackedScene) -> void:
	const NAME: String = "01_模板根局部原点为零"
	var crystal: _BasicCrystal = await _make_ready_instance(scene)
	_check(NAME, crystal.position == Vector2.ZERO, "模板实例根 position 期望 (0,0)，实际 %s。" % [crystal.position])
	_check(NAME, crystal.cell == Vector2i.ZERO, "模板实例根 cell 应由 (0,0) 派生为 (0,0)，实际 %s。" % [crystal.cell])


## 2. 直属子节点无 (32,32) 二次补偿：VisualView 本地 position 归零，且无直属子节点以 (32,32) 作为位置补偿。
func _test_02_no_child_32_32_compensation(scene: PackedScene) -> void:
	const NAME: String = "02_子节点无32_32二次补偿"
	var crystal: _BasicCrystal = await _make_ready_instance(scene)
	var view: _ObjectVisualView = crystal.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, view != null, "VisualView 子节点缺失。")
	if view != null:
		_check(NAME, view.position == Vector2.ZERO, "VisualView 本地 position 期望 (0,0)，实际 %s。" % [view.position])
		_check(NAME, view.get_parent() == crystal, "VisualView 应为 Crystal 直属子节点。")
	# 任何 Node2D 直属子节点都不应以 (32,32) 作为位置补偿。
	for child: Node in crystal.get_children():
		var c2d: Node2D = child as Node2D
		if c2d != null:
			_check(NAME, c2d.position != Vector2(32, 32), "直属子节点 %s 不应使用 (32,32) 二次补偿，实际 %s。" % [c2d.name, c2d.position])


## 3. 两个实例 position 独立：分别设置不同格中心 position，互不串扰，cell 各自由 position 派生。
func _test_03_two_instances_position_independent(scene: PackedScene) -> void:
	const NAME: String = "03_两实例position独立"
	var a: _BasicCrystal = await _make_ready_instance(scene)
	var b: _BasicCrystal = await _make_ready_instance(scene)
	var pos_a: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	var pos_b: Vector2 = _GridCoordinateRules.cell_to_world(Vector2i(7, 5))
	a.position = pos_a
	b.position = pos_b
	_check(NAME, a.position == pos_a, "A.position 期望 %s，实际 %s。" % [pos_a, a.position])
	_check(NAME, b.position == pos_b, "B.position 期望 %s，实际 %s。" % [pos_b, b.position])
	_check(NAME, a.position != b.position, "两实例 position 应不同。")
	_check(NAME, a.cell == Vector2i(3, 1), "A.cell 期望 (3,1)，实际 %s。" % [a.cell])
	_check(NAME, b.cell == Vector2i(7, 5), "B.cell 期望 (7,5)，实际 %s。" % [b.cell])


## 4. 点亮其中一个不影响另一个：activate A 后 A 点亮、B 仍未点亮，视觉状态各自独立。
func _test_04_lighting_one_does_not_affect_other(scene: PackedScene) -> void:
	const NAME: String = "04_点亮其一不影响另一个"
	var a: _BasicCrystal = await _make_ready_instance(scene)
	var b: _BasicCrystal = await _make_ready_instance(scene)
	var va: _ObjectVisualView = a.get_node_or_null("VisualView") as _ObjectVisualView
	var vb: _ObjectVisualView = b.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, not a.is_activated and not b.is_activated, "初始两者均应未点亮。")
	a.activate()
	_check(NAME, a.is_activated, "A activate 后应点亮。")
	_check(NAME, not b.is_activated, "点亮 A 不应影响 B 的 is_activated。")
	_check(NAME, va != null and va.get_content_state() == &"lit", "A 视觉应为 lit。")
	_check(NAME, vb != null and vb.get_content_state() == &"unlit", "B 视觉应保持 unlit。")


## 5. 两实例共享默认 VisualProfile：均为 basic_crystal_visuals.tres，且为同一资源实例（默认不可变资源可共享）。
func _test_05_shared_default_visual_profile(scene: PackedScene) -> void:
	const NAME: String = "05_共享默认VisualProfile"
	var a: _BasicCrystal = await _make_ready_instance(scene)
	var b: _BasicCrystal = await _make_ready_instance(scene)
	var va: _ObjectVisualView = a.get_node_or_null("VisualView") as _ObjectVisualView
	var vb: _ObjectVisualView = b.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, va != null and va.visual_profile != null, "A 的 visual_profile 不应为空。")
	_check(NAME, vb != null and vb.visual_profile != null, "B 的 visual_profile 不应为空。")
	if va != null and vb != null and va.visual_profile != null:
		_check(NAME, va.visual_profile.resource_path == _PROFILE_PATH, "A visual_profile 应为 basic_crystal_visuals.tres，实际 %s。" % [va.visual_profile.resource_path])
		_check(NAME, va.visual_profile == vb.visual_profile, "两实例应共享同一默认 VisualProfile 资源实例。")


## 6. 可变运行状态不共享且不写入共享资源（字段级不变性）：
## 步骤1-3 实例化两实例、确认共享同一 VisualProfile、记录 Profile 每个状态字段；
## 步骤4-6 激活 A 后 B 运行/视觉状态不变、共享 Profile 引用与字段内容不变；
## 步骤7-8 A 进入 lit 正式状态、再次确认 B 与 Profile 不变；
## 步骤9-10 reset A 后 Profile 字段内容仍不变。
## 三层区分：Profile 配置资源（共享、运行期不可变）、ObjectVisualView 当前显示状态（每实例独立）、
## BasicCrystal 运行状态 is_activated（每实例独立）；不通过主动改写共享 Profile 验证传播。
func _test_06_mutable_runtime_state_not_shared(scene: PackedScene) -> void:
	const NAME: String = "06_可变运行状态不共享"
	# 步骤1：实例化两个 BasicCrystal。
	var a: _BasicCrystal = await _make_ready_instance(scene)
	var b: _BasicCrystal = await _make_ready_instance(scene)
	var va: _ObjectVisualView = a.get_node_or_null("VisualView") as _ObjectVisualView
	var vb: _ObjectVisualView = b.get_node_or_null("VisualView") as _ObjectVisualView
	_check(NAME, va != null and vb != null, "两实例的 VisualView 必须存在。")
	if va == null or vb == null:
		return
	# 步骤2：确认两者共享同一个 VisualProfile 引用。
	var shared_profile: ObjectVisualProfile = va.visual_profile
	_check(NAME, shared_profile != null, "共享 VisualProfile 不应为空。")
	_check(NAME, va.visual_profile == vb.visual_profile, "两实例应共享同一默认 VisualProfile 资源实例。")
	if shared_profile == null:
		return
	# 步骤3：记录共享 Profile 状态列表及每个状态字段（state_id、world_texture、drag_texture 等）。
	var snap_before: Dictionary = _profile_content_signature(shared_profile)
	# 步骤4：激活第一个实例（点亮，切换到 lit）。
	a.activate()
	# 步骤5：验证第二个实例运行状态与视觉状态均不变。
	_check(NAME, a.is_activated, "A activate 后应点亮。")
	_check(NAME, not b.is_activated, "点亮 A 不应影响 B 的 is_activated。")
	_check(NAME, va.get_content_state() == &"lit", "A 视觉应为 lit。")
	_check(NAME, vb.get_content_state() == &"unlit", "B 视觉应保持 unlit。")
	# 步骤6：验证共享 Profile 引用稳定且字段内容未被改写。
	_check(NAME, va.visual_profile == shared_profile, "activate 后共享 VisualProfile 引用不应被替换。")
	_check(NAME, _profile_content_signature(shared_profile) == snap_before, "activate 不应改写共享 Profile 任何字段内容。")
	# 步骤7：A 已进入 lit 正式状态，重复点亮验证幂等不污染共享 Profile。
	a.activate()
	# 步骤8：再次验证第二实例与 Profile 不变。
	_check(NAME, a.is_activated, "A 重复点亮后仍应点亮。")
	_check(NAME, not b.is_activated, "A 重复点亮不应影响 B。")
	_check(NAME, vb.get_content_state() == &"unlit", "A 点亮态下 B 视觉应仍为 unlit。")
	_check(NAME, va.visual_profile == shared_profile, "点亮态下共享 VisualProfile 引用不应被替换。")
	_check(NAME, _profile_content_signature(shared_profile) == snap_before, "点亮态下共享 Profile 内容应不变。")
	# 步骤9：reset 第一个实例。
	a.reset_runtime()
	# 步骤10：再次验证 Profile 字段内容不变，且 B 仍不受影响。
	_check(NAME, not a.is_activated, "A reset 后应未点亮。")
	_check(NAME, not b.is_activated, "B 应始终未点亮，不受 A 的 activate/reset 影响。")
	_check(NAME, va.get_content_state() == &"unlit", "A reset 后视觉应为 unlit。")
	_check(NAME, vb.get_content_state() == &"unlit", "B 视觉应始终 unlit。")
	_check(NAME, va.visual_profile == shared_profile, "reset 后共享 VisualProfile 引用不应被替换。")
	_check(NAME, _profile_content_signature(shared_profile) == snap_before, "reset 不应改写共享 Profile 任何字段内容。")


# ===== 辅助 =====

## 取共享 Profile 全部稳定配置字段的内容签名，用于操作前后逐字段比对：
## resource_path、default_state_id、inventory_icon 资源路径、states 数量及每个状态的
## state_id、world_texture 与 drag_texture 的稳定资源路径——任一配置字段被运行期改写都会使签名变化。
## 仅读取字段，不修改 Profile；不把纹理 instance_id 等运行期对象身份混入"资源内容不变"签名，
## 空纹理以空字符串占位；两实例共享同一 VisualProfile 的事实由 _test_05/_test_06 的引用一致性断言单独验证。
func _profile_content_signature(profile: ObjectVisualProfile) -> Dictionary:
	var sig: Dictionary = {}
	sig["path"] = profile.resource_path
	sig["default_state_id"] = String(profile.default_state_id)
	sig["inventory_icon_path"] = profile.inventory_icon.resource_path if profile.inventory_icon != null else ""
	sig["states_count"] = profile.states.size()
	var state_sigs: Array = []
	for state: VisualStateTexture in profile.states:
		var s: Dictionary = {}
		s["state_id"] = String(state.state_id)
		s["world_texture_path"] = state.world_texture.resource_path if state.world_texture != null else ""
		s["drag_texture_path"] = state.drag_texture.resource_path if state.drag_texture != null else ""
		state_sigs.append(s)
	sig["states"] = state_sigs
	return sig


## 实例化模板并挂入 root 触发真实 _ready，用于位置/视觉/状态契约验证。
func _make_ready_instance(scene: PackedScene) -> _BasicCrystal:
	var crystal: _BasicCrystal = scene.instantiate() as _BasicCrystal
	root.add_child(crystal)
	await process_frame
	_instances.append(crystal)
	return crystal


## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 释放本轮创建的水晶实例（连带 VisualView 子节点），跳过已释放实例。
func _cleanup() -> void:
	for i: int in range(_instances.size()):
		var crystal: BasicCrystal = _instances[i]
		if is_instance_valid(crystal):
			root.remove_child(crystal)
			crystal.free()
	_instances.clear()


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 6
	var passed_checks: int = _checks - _failures.size()
	print("==== BasicCrystal PackedScene 模板契约 测试摘要 ====")
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
