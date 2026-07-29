extends SceneTree

## EmitterConfigNode 单元测试（拆分片 3/5 · 子节点识别与 _ready 初始同步）。
## 覆盖 D3C-0：子节点缺失安全、EmitterVisual/EmissionPreview 识别、_ready 初始同步、
##   RAY/PARTICLE 样式、不创建缺失子节点。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _EmissionPreview: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emission_preview.gd"
)


# 仅用于测试：继承 ObjectVisualView 但把 refresh_visual 置空，避免依赖其场景子节点；
# 计数 set_profile 调用以验证单向同步与重复值不刷新。
class _StubVisual extends ObjectVisualView:
	var profile_set_count: int = 0
	func set_profile(next_profile: ObjectVisualProfile) -> void:
		super.set_profile(next_profile)
		profile_set_count += 1
	func refresh_visual() -> void:
		pass


# 仅用于测试：继承 EmissionPreview 计数 set_preview_state 调用，验证配置到预览的单向同步。
class _StubPreview extends EmissionPreview:
	var state_set_count: int = 0
	func set_preview_state(direction: Vector2i, particle_style: bool, enabled: bool) -> void:
		super.set_preview_state(direction, particle_style, enabled)
		state_set_count += 1


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_20_no_children_safe()
	_test_21_recognize_emitter_visual()
	_test_22_recognize_emission_preview()
	_test_23_ready_syncs_visual_profile()
	_test_24_ready_syncs_active_direction()
	_test_25_ray_particle_style_false()
	_test_26_particle_style_true()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 20. 没有子节点时 _ready 与各 setter 均安全跳过，不崩溃、不创建子节点。
func _test_20_no_children_safe() -> void:
	const NAME: String = "20_无子节点_ready与setter安全"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	root.add_child(config)
	config._ready()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.visual_profile = _ObjectVisualProfile.new()
	config.editor_preview_visible = false
	_check(NAME, config.get_child_count() == 0, "无子节点时不应创建子节点，实际 %d。" % [config.get_child_count()])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 21. 名为 EmitterVisual 的 ObjectVisualView 能被识别并同步 visual_profile。
func _test_21_recognize_emitter_visual() -> void:
	const NAME: String = "21_识别EmitterVisual"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile  # 子节点尚未存在，setter 安全跳过
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	_check(NAME, visual.profile_set_count >= 1, "_ready 应调用 set_profile 同步 visual_profile。")
	_check(NAME, visual.visual_profile == profile, "名为 EmitterVisual 的 ObjectVisualView 应被识别并同步 profile。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 22. 名为 EmissionPreview 的 EmissionPreview 能被识别并同步默认活动方向。
func _test_22_recognize_emission_preview() -> void:
	const NAME: String = "22_识别EmissionPreview"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	_check(NAME, preview.state_set_count >= 1, "_ready 应调用 set_preview_state。")
	_check(NAME, preview.get_preview_direction() == Vector2i(1, 0), "名为 EmissionPreview 的 EmissionPreview 应被识别并同步默认活动方向 (1,0)，实际 %s。" % [preview.get_preview_direction()])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 23. _ready 初始同步 visual_profile 给 EmitterVisual。
func _test_23_ready_syncs_visual_profile() -> void:
	const NAME: String = "23_ready同步visual_profile"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	_check(NAME, visual.visual_profile == profile, "_ready 应将 visual_profile 同步给 EmitterVisual。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 24. _ready 初始同步活动方向给 EmissionPreview。
func _test_24_ready_syncs_active_direction() -> void:
	const NAME: String = "24_ready同步活动方向"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	_check(NAME, preview.get_preview_direction() == Vector2i(0, 1), "_ready 应同步活动方向 (0,1)，实际 %s。" % [preview.get_preview_direction()])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 25. 默认 RAY 形态对应 particle_style=false。
func _test_25_ray_particle_style_false() -> void:
	const NAME: String = "25_RAY下particle_style=false"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	_check(NAME, preview.is_particle_style() == false, "RAY 形态 particle_style 应为 false。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 26. 切换到 PARTICLE 后 particle_style=true。
func _test_26_particle_style_true() -> void:
	const NAME: String = "26_PARTICLE下particle_style=true"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, preview.is_particle_style() == true, "切到 PARTICLE 后 particle_style 应为 true。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 子节点识别与初始同步 测试摘要 ====")
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
