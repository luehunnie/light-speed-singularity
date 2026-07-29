extends SceneTree

## EmitterConfigNode 单元测试（拆分片 4/5 · 配置到子节点的运行时同步）。
## 覆盖 D3C-0：方向变化刷新预览、非活动方向保存、预览可见性同步、profile 同步、
##   重复值不刷新、position 不影响预览本地位置、不创建缺失子节点。
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
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
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
	_test_27_ray_direction_refreshes_preview()
	_test_28_particle_direction_refreshes_preview()
	_test_29_non_active_direction_kept_preview_correct()
	_test_30_editor_preview_visible_sync()
	_test_31_visual_profile_modify_syncs()
	_test_32_repeat_value_no_refresh()
	_test_33_position_does_not_move_preview_local()
	_test_34_no_missing_child_creation()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 27. RAY 状态下光线方向变化刷新 Preview。
func _test_27_ray_direction_refreshes_preview() -> void:
	const NAME: String = "27_RAY下光线方向刷新预览"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	_check(NAME, preview.get_preview_direction() == Vector2i(0, 1), "RAY 下改光线方向应刷新预览为 (0,1)，实际 %s。" % [preview.get_preview_direction()])
	_check(NAME, preview.is_particle_style() == false, "RAY 下 particle_style 应保持 false。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 28. PARTICLE 状态下光粒方向变化刷新 Preview。
func _test_28_particle_direction_refreshes_preview() -> void:
	const NAME: String = "28_PARTICLE下光粒方向刷新预览"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.DOWN
	_check(NAME, preview.get_preview_direction() == Vector2i(0, 1), "PARTICLE 下改光粒方向应刷新预览为 (0,1)，实际 %s。" % [preview.get_preview_direction()])
	_check(NAME, preview.is_particle_style() == true, "PARTICLE 下 particle_style 应保持 true。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 29. 修改非活动形态方向仍保存配置，但 Preview 活动方向保持正确。
func _test_29_non_active_direction_kept_preview_correct() -> void:
	const NAME: String = "29_非活动方向保存且预览正确"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	# RAY 活动，改光粒（非活动）方向：配置保存，预览活动方向不变。
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "光粒方向应保存为 UP。")
	_check(NAME, preview.get_preview_direction() == Vector2i(1, 0), "RAY 活动时预览方向应保持光线 (1,0)，实际 %s。" % [preview.get_preview_direction()])
	_check(NAME, preview.is_particle_style() == false, "RAY 活动时 particle_style 应保持 false。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 30. editor_preview_visible 变化同步给 EmissionPreview。
func _test_30_editor_preview_visible_sync() -> void:
	const NAME: String = "30_editor_preview_visible同步"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	config.editor_preview_visible = false
	_check(NAME, preview.is_preview_enabled() == false, "关闭预览后 preview_enabled 应为 false。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 31. visual_profile 修改同步给 EmitterVisual。
func _test_31_visual_profile_modify_syncs() -> void:
	const NAME: String = "31_visual_profile修改同步"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile
	_check(NAME, visual.visual_profile == profile, "修改 visual_profile 应同步给 EmitterVisual。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 32. 重复设置相同值不重复刷新子节点、不重复发信号。
func _test_32_repeat_value_no_refresh() -> void:
	const NAME: String = "32_重复值不刷新不发信号"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile
	var visual_count_after_set: int = visual.profile_set_count
	var preview_count_after_ready: int = preview.state_set_count
	var counters: Dictionary = _connect_counters(config)
	# 全部重复当前值，不应刷新子节点或发信号。
	config.visual_profile = profile
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	config.ray_default_direction = _EmitterConfigNode.RayDirection.RIGHT
	config.editor_preview_visible = true
	_check(NAME, visual.profile_set_count == visual_count_after_set, "重复 profile 不应再调 set_profile，实际 %d。" % [visual.profile_set_count])
	_check(NAME, preview.state_set_count == preview_count_after_ready, "重复值不应再调 set_preview_state，实际 %d。" % [preview.state_set_count])
	_check(NAME, counters["config"] == 0, "重复值不应发 configuration_changed，实际 %d。" % [counters["config"]])
	_check(NAME, counters["profile"] == 0, "重复 profile 不应发 visual_profile_changed，实际 %d。" % [counters["profile"]])
	_check(NAME, counters["preview"] == 0, "重复预览值不应发 preview_visibility_changed，实际 %d。" % [counters["preview"]])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 33. 修改 EmitterConfigNode.position 不改变 Preview 本地位置（子节点自然跟随父节点移动）。
func _test_33_position_does_not_move_preview_local() -> void:
	const NAME: String = "33_position不影响预览本地位置"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var preview: _StubPreview = _StubPreview.new()
	preview.name = "EmissionPreview"
	config.add_child(preview)
	root.add_child(config)
	config._ready()
	var local_before: Vector2 = preview.position
	config.position = _GridCoordinateRules.cell_to_world(Vector2i(3, 1))
	_check(NAME, preview.position == local_before, "父节点 position 改变后预览本地位置应不变，实际 %s。" % [preview.position])
	_check(NAME, preview.position == Vector2.ZERO, "预览本地位置应保持 ZERO。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 34. 子节点缺失时不自动创建 EmitterVisual / EmissionPreview。
func _test_34_no_missing_child_creation() -> void:
	const NAME: String = "34_不创建缺失子节点"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	root.add_child(config)
	config._ready()
	config.visual_profile = _ObjectVisualProfile.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.editor_preview_visible = false
	_check(NAME, config.get_child_count() == 0, "缺失子节点时不应自动创建，实际 %d。" % [config.get_child_count()])
	_check(NAME, config.get_node_or_null("EmitterVisual") == null, "不应创建 EmitterVisual。")
	_check(NAME, config.get_node_or_null("EmissionPreview") == null, "不应创建 EmissionPreview。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


# ===== 辅助 =====

## 连接三类信号到同一计数字典，返回 {config, profile, preview, profile_arg, preview_arg}。
func _connect_counters(config: _EmitterConfigNode) -> Dictionary:
	var counters: Dictionary = {
		"config": 0,
		"profile": 0,
		"preview": 0,
		"profile_arg": null,
		"preview_arg": false,
	}
	config.configuration_changed.connect(func() -> void: counters["config"] += 1)
	config.visual_profile_changed.connect(func(p: _ObjectVisualProfile) -> void:
		counters["profile"] += 1
		counters["profile_arg"] = p)
	config.preview_visibility_changed.connect(func(v: bool) -> void:
		counters["preview"] += 1
		counters["preview_arg"] = v)
	return counters


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 8
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 运行时同步 测试摘要 ====")
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
