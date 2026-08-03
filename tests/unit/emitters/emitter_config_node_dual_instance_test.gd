extends SceneTree

## EmitterConfigNode 双实例独立性测试（OBJ-B-Fix）。
## 直接实例化两个 res://gameplay/mechanisms/emitters/emitter_config_node.tscn，
## 证明两实例可变配置与预览状态互不影响：
##   仅修改 A 的 position / ray_default_direction / default_light_form /
##   particle_default_direction / editor_preview_visible，B 的对应字段与预览全部保持原值；
##   A、B 的 EmissionPreview 是不同节点实例；A 配置变化只刷新 A 的 Preview；
##   两实例可共享默认 visual_profile；可变配置不写入共享 Resource；
##   根 / EmitterVisual / EmissionPreview 的局部 position 均为 (0,0)。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：PARTICLE 在本场景下无 FixedEmitter / 运行编排，仅承载配置与预览，不接真实运行逻辑。

const _SCENE_PATH: String = "res://gameplay/mechanisms/emitters/emitter_config_node.tscn"

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


## SceneTree 初始化入口：等待首帧后跑三组双实例用例，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可被触发。
	await process_frame

	var scene: PackedScene = load(_SCENE_PATH) as PackedScene
	_check("00_场景可加载", scene != null, "emitter_config_node.tscn 加载失败。")

	await _test_01_baseline_distinct_previews_shared_profile(scene)
	await _test_02_modify_a_mutable_config_b_unchanged(scene)
	await _test_03_preview_independence_and_local_positions(scene)

	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 基线：两实例独立加载，预览为不同节点实例，共享默认 visual_profile，初始字段与局部位置均为默认。
func _test_01_baseline_distinct_previews_shared_profile(scene: PackedScene) -> void:
	const NAME: String = "01_基线独立与共享profile"
	var a: _EmitterConfigNode = await _make_ready_instance(scene)
	var b: _EmitterConfigNode = await _make_ready_instance(scene)
	if a == null or b == null:
		_check(NAME, false, "场景实例化或入树失败。")
		await _free_pair_and_check(a, b, NAME)
		return
	var a_preview: _EmissionPreview = a.get_node_or_null("EmissionPreview") as _EmissionPreview
	var b_preview: _EmissionPreview = b.get_node_or_null("EmissionPreview") as _EmissionPreview
	var a_visual: _ObjectVisualView = a.get_node_or_null("EmitterVisual") as _ObjectVisualView
	var b_visual: _ObjectVisualView = b.get_node_or_null("EmitterVisual") as _ObjectVisualView
	# 两实例均为 EmitterConfigNode，且是不同对象。
	_check(NAME, a is _EmitterConfigNode and b is _EmitterConfigNode, "A、B 应均为 EmitterConfigNode。")
	_check(NAME, a != b, "A、B 应为不同实例。")
	# EmissionPreview / EmitterVisual 为不同节点实例。
	_check(NAME, a_preview != null and b_preview != null, "A、B 的 EmissionPreview 子节点应存在。")
	_check(NAME, a_preview != b_preview, "A、B 的 EmissionPreview 应为不同节点实例。")
	_check(NAME, a_visual != null and b_visual != null, "A、B 的 EmitterVisual 子节点应存在。")
	_check(NAME, a_visual != b_visual, "A、B 的 EmitterVisual 应为不同节点实例。")
	# 两实例共享默认 visual_profile（load 缓存的同一资源实例）。
	_check(NAME, a.visual_profile != null, "A 应有默认 visual_profile。")
	_check(NAME, a.visual_profile == b.visual_profile, "A、B 应共享同一 visual_profile 实例。")
	# 初始字段均为默认值。
	_check(NAME, a.default_light_form == _EmitterConfigNode.LightForm.RAY, "A 默认形态应为 RAY。")
	_check(NAME, b.default_light_form == _EmitterConfigNode.LightForm.RAY, "B 默认形态应为 RAY。")
	_check(NAME, a.ray_default_direction == _EmitterConfigNode.RayDirection.RIGHT, "A 默认光线方向应为 RIGHT。")
	_check(NAME, b.ray_default_direction == _EmitterConfigNode.RayDirection.RIGHT, "B 默认光线方向应为 RIGHT。")
	_check(NAME, a.particle_default_direction == _EmitterConfigNode.ParticleDirection.RIGHT, "A 默认光粒方向应为 RIGHT。")
	_check(NAME, b.particle_default_direction == _EmitterConfigNode.ParticleDirection.RIGHT, "B 默认光粒方向应为 RIGHT。")
	_check(NAME, a.editor_preview_visible == true, "A 默认预览可见应为 true。")
	_check(NAME, b.editor_preview_visible == true, "B 默认预览可见应为 true。")
	# 根 / EmitterVisual / EmissionPreview 局部 position 均为 (0,0)。
	_check(NAME, a.position == Vector2.ZERO, "A 根局部位置应为 (0,0)，实际 %s。" % [a.position])
	_check(NAME, b.position == Vector2.ZERO, "B 根局部位置应为 (0,0)，实际 %s。" % [b.position])
	_check(NAME, a_visual.position == Vector2.ZERO, "A EmitterVisual 局部位置应为 (0,0)，实际 %s。" % [a_visual.position])
	_check(NAME, b_visual.position == Vector2.ZERO, "B EmitterVisual 局部位置应为 (0,0)，实际 %s。" % [b_visual.position])
	_check(NAME, a_preview.position == Vector2.ZERO, "A EmissionPreview 局部位置应为 (0,0)，实际 %s。" % [a_preview.position])
	_check(NAME, b_preview.position == Vector2.ZERO, "B EmissionPreview 局部位置应为 (0,0)，实际 %s。" % [b_preview.position])
	await _free_pair_and_check(a, b, NAME)


## 2. 修改 A 的五项可变配置，B 的对应字段全部保持原值；A 可变配置不重写共享 visual_profile。
func _test_02_modify_a_mutable_config_b_unchanged(scene: PackedScene) -> void:
	const NAME: String = "02_修改A_B配置不变"
	var a: _EmitterConfigNode = await _make_ready_instance(scene)
	var b: _EmitterConfigNode = await _make_ready_instance(scene)
	if a == null or b == null:
		_check(NAME, false, "场景实例化或入树失败。")
		await _free_pair_and_check(a, b, NAME)
		return
	var shared_profile: _ObjectVisualProfile = a.visual_profile
	# 用字典累计信号，避免 GDScript 闭包对原始 int 的捕获不持久（参考 sync 测试同模式）。
	var profile_signal: Dictionary = {"count": 0}
	a.visual_profile_changed.connect(func(_p: _ObjectVisualProfile) -> void: profile_signal["count"] += 1)
	# 仅修改 A 的五项可变配置。
	a.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 2))
	a.ray_default_direction = _EmitterConfigNode.RayDirection.UP
	a.particle_default_direction = _EmitterConfigNode.ParticleDirection.LEFT
	a.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	a.editor_preview_visible = false
	# A 五项字段已变更。
	_check(NAME, a.position == _GridCoordinateRules.cell_to_world(Vector2i(3, 2)), "A.position 应已修改。")
	_check(NAME, a.ray_default_direction == _EmitterConfigNode.RayDirection.UP, "A 光线方向应为 UP。")
	_check(NAME, a.particle_default_direction == _EmitterConfigNode.ParticleDirection.LEFT, "A 光粒方向应为 LEFT。")
	_check(NAME, a.default_light_form == _EmitterConfigNode.LightForm.PARTICLE, "A 形态应为 PARTICLE。")
	_check(NAME, a.editor_preview_visible == false, "A 预览可见应为 false。")
	# 可变配置不重写共享 Resource：A 仍指向同一 profile，且未发 visual_profile_changed。
	_check(NAME, a.visual_profile == shared_profile, "A 可变配置变化不应重写 visual_profile 引用。")
	_check(NAME, profile_signal["count"] == 0, "可变配置变化不应发 visual_profile_changed，实际 %d。" % [profile_signal["count"]])
	# B 五项字段全部保持原值。
	_check(NAME, b.position == Vector2.ZERO, "B.position 应保持 (0,0)，实际 %s。" % [b.position])
	_check(NAME, b.ray_default_direction == _EmitterConfigNode.RayDirection.RIGHT, "B 光线方向应保持 RIGHT。")
	_check(NAME, b.particle_default_direction == _EmitterConfigNode.ParticleDirection.RIGHT, "B 光粒方向应保持 RIGHT。")
	_check(NAME, b.default_light_form == _EmitterConfigNode.LightForm.RAY, "B 形态应保持 RAY。")
	_check(NAME, b.editor_preview_visible == true, "B 预览可见应保持 true。")
	# B 仍共享同一 visual_profile（未被 A 的可变配置牵连）。
	_check(NAME, b.visual_profile == shared_profile, "B 仍应共享同一 visual_profile。")
	await _free_pair_and_check(a, b, NAME)


## 3. A 配置变化只刷新 A 的 Preview；B 的 Preview 可见性、方向、显示状态不变；移动 A 不改子节点局部位置。
func _test_03_preview_independence_and_local_positions(scene: PackedScene) -> void:
	const NAME: String = "03_预览独立与局部位置"
	var a: _EmitterConfigNode = await _make_ready_instance(scene)
	var b: _EmitterConfigNode = await _make_ready_instance(scene)
	if a == null or b == null:
		_check(NAME, false, "场景实例化或入树失败。")
		await _free_pair_and_check(a, b, NAME)
		return
	var a_preview: _EmissionPreview = a.get_node_or_null("EmissionPreview") as _EmissionPreview
	var b_preview: _EmissionPreview = b.get_node_or_null("EmissionPreview") as _EmissionPreview
	var a_visual: _ObjectVisualView = a.get_node_or_null("EmitterVisual") as _ObjectVisualView
	# 修改 A：形态切 PARTICLE、光粒 LEFT、预览关闭、光线 UP，并移动根 position。
	a.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	a.particle_default_direction = _EmitterConfigNode.ParticleDirection.LEFT
	a.ray_default_direction = _EmitterConfigNode.RayDirection.UP
	a.editor_preview_visible = false
	a.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 2))
	# A 的 Preview 反映 A 的配置：活动方向为光粒 LEFT=(-1,0)、particle_style=true、enabled=false。
	_check(NAME, a_preview != b_preview, "A、B 的 EmissionPreview 应为不同节点实例。")
	_check(NAME, a_preview.get_preview_direction() == Vector2i(-1, 0), "A 预览方向应为光粒 LEFT=(-1,0)，实际 %s。" % [a_preview.get_preview_direction()])
	_check(NAME, a_preview.is_particle_style() == true, "A 预览应为光粒样式。")
	_check(NAME, a_preview.is_preview_enabled() == false, "A 预览 enabled 应为 false。")
	# B 的 Preview 可见性、方向、显示状态全部不变（运行时 visible 恒为 false，方向 (1,0)、非光粒、enabled true）。
	_check(NAME, b_preview.get_preview_direction() == Vector2i(1, 0), "B 预览方向应保持 (1,0)，实际 %s。" % [b_preview.get_preview_direction()])
	_check(NAME, b_preview.is_particle_style() == false, "B 预览样式应保持非光粒。")
	_check(NAME, b_preview.is_preview_enabled() == true, "B 预览 enabled 应保持 true。")
	_check(NAME, b_preview.visible == false, "B 预览运行时可见性应保持 false。")
	_check(NAME, a_preview.visible == false, "A 预览运行时可见性应为 false。")
	# 移动 A 根 position 后，A 的 EmitterVisual / EmissionPreview 局部位置仍为 (0,0)（子节点自然跟随，不偏移）。
	_check(NAME, a.position == _GridCoordinateRules.cell_to_world(Vector2i(3, 2)), "A 根 position 应已移动。")
	_check(NAME, a_visual.position == Vector2.ZERO, "A 移动后 EmitterVisual 局部位置应仍为 (0,0)，实际 %s。" % [a_visual.position])
	_check(NAME, a_preview.position == Vector2.ZERO, "A 移动后 EmissionPreview 局部位置应仍为 (0,0)，实际 %s。" % [a_preview.position])
	_check(NAME, b.position == Vector2.ZERO, "B 根 position 应保持 (0,0)。")
	await _free_pair_and_check(a, b, NAME)


# ===== 辅助 =====

## 实例化场景并挂入 root，等待一帧触发真实 _ready，返回 EmitterConfigNode 根。
func _make_ready_instance(scene: PackedScene) -> _EmitterConfigNode:
	if scene == null:
		return null
	var node: _EmitterConfigNode = scene.instantiate() as _EmitterConfigNode
	if node == null:
		return null
	root.add_child(node)
	await process_frame
	return node


## 释放一对实例并断言 root 无残留。
func _free_pair_and_check(a: Node, b: Node, name: String) -> void:
	if a != null:
		a.free()
	if b != null:
		b.free()
	await process_frame
	_check(name, root.get_child_count() == 0, "释放后 root 应无残留，实际 %d。" % [root.get_child_count()])


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 3
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 双实例独立性 测试摘要 ====")
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
