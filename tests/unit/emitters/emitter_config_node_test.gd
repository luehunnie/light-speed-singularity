extends SceneTree

## EmitterConfigNode D3B-1 / D3C-0 定向自动测试。
## 覆盖：继承 GridPlacedObject、默认形态/方向、八光线与四光粒方向映射、active 随形态切换、
##   运行时形态支持、方向分开保存、visual_profile 可空、预览默认可见、配置变化信号、重复值不发信号、
##   profile/preview 专属信号、position 唯一事实、无禁止依赖、不加载主场景、非法值拒绝；
##   D3C-0：子节点缺失安全、EmitterVisual/EmissionPreview 识别、_ready 初始同步、RAY/PARTICLE 样式、
##   方向变化刷新预览、非活动方向保存、预览可见性同步、profile 同步、重复值不刷新、position 不影响预览本地位置、
##   不创建缺失子节点。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 非法值用例会产生预期 push_error 输出，不计入失败。

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
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
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
	_test_01_extends_grid_placed_object()
	_test_02_default_form_ray()
	_test_03_default_ray_direction_vector()
	_test_04_default_particle_direction_vector()
	_test_05_all_ray_direction_mappings()
	_test_06_all_particle_direction_mappings()
	_test_07_active_direction_switches_with_form()
	_test_08_runtime_supported_ray()
	_test_09_runtime_not_supported_particle()
	_test_10_directions_stored_separately()
	_test_11_visual_profile_nullable()
	_test_12_editor_preview_default_true()
	_test_13_configuration_changed_on_change()
	_test_14_no_signal_on_same_value()
	_test_15_profile_and_preview_signals()
	_test_16_position_is_sole_fact()
	_test_17_no_forbidden_dependencies()
	_test_18_no_main_scene_loaded()
	_test_19_illegal_values_rejected()
	_test_20_no_children_safe()
	_test_21_recognize_emitter_visual()
	_test_22_recognize_emission_preview()
	_test_23_ready_syncs_visual_profile()
	_test_24_ready_syncs_active_direction()
	_test_25_ray_particle_style_false()
	_test_26_particle_style_true()
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

## 1. 继承 GridPlacedObject：position/cell 契约由基类承担。
func _test_01_extends_grid_placed_object() -> void:
	const NAME: String = "01_继承GridPlacedObject"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config is _GridPlacedObject, "EmitterConfigNode 应为 GridPlacedObject 子类。")
	_check(NAME, config is Node2D, "EmitterConfigNode 应为 Node2D 子类（经 GridPlacedObject）。")
	config.free()


## 2. 默认形态为 RAY。
func _test_02_default_form_ray() -> void:
	const NAME: String = "02_默认形态RAY"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_default_light_form() == _EmitterConfigNode.LightForm.RAY, "默认形态应为 RAY，实际 %d。" % [config.get_default_light_form()])
	_check(NAME, config.default_light_form == _EmitterConfigNode.LightForm.RAY, "默认 default_light_form 字段应为 RAY。")
	config.free()


## 3. 默认光线方向 RIGHT → Vector2i(1,0)。
func _test_03_default_ray_direction_vector() -> void:
	const NAME: String = "03_默认光线方向RIGHT"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.RIGHT, "默认光线方向应为 RIGHT。")
	_check(NAME, config.get_ray_direction_vector() == Vector2i(1, 0), "默认光线方向向量应为 (1,0)，实际 %s。" % [config.get_ray_direction_vector()])
	config.free()


## 4. 默认光粒方向 RIGHT → Vector2i(1,0)。
func _test_04_default_particle_direction_vector() -> void:
	const NAME: String = "04_默认光粒方向RIGHT"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.RIGHT, "默认光粒方向应为 RIGHT。")
	_check(NAME, config.get_particle_direction_vector() == Vector2i(1, 0), "默认光粒方向向量应为 (1,0)，实际 %s。" % [config.get_particle_direction_vector()])
	config.free()


## 5. 八个光线方向映射全部正确。
func _test_05_all_ray_direction_mappings() -> void:
	const NAME: String = "05_八光线方向映射"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var cases: Array = [
		[_EmitterConfigNode.RayDirection.RIGHT, Vector2i(1, 0)],
		[_EmitterConfigNode.RayDirection.DOWN_RIGHT, Vector2i(1, 1)],
		[_EmitterConfigNode.RayDirection.DOWN, Vector2i(0, 1)],
		[_EmitterConfigNode.RayDirection.DOWN_LEFT, Vector2i(-1, 1)],
		[_EmitterConfigNode.RayDirection.LEFT, Vector2i(-1, 0)],
		[_EmitterConfigNode.RayDirection.UP_LEFT, Vector2i(-1, -1)],
		[_EmitterConfigNode.RayDirection.UP, Vector2i(0, -1)],
		[_EmitterConfigNode.RayDirection.UP_RIGHT, Vector2i(1, -1)],
	]
	for case: Array in cases:
		var d: int = case[0]
		var expected: Vector2i = case[1]
		var got: Vector2i = _EmitterConfigNode.ray_direction_to_vector(d)
		_check(NAME, got == expected, "RayDirection %d 应映射到 %s，实际 %s。" % [d, expected, got])
	config.free()


## 6. 四个光粒方向映射全部正确。
func _test_06_all_particle_direction_mappings() -> void:
	const NAME: String = "06_四光粒方向映射"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var cases: Array = [
		[_EmitterConfigNode.ParticleDirection.RIGHT, Vector2i(1, 0)],
		[_EmitterConfigNode.ParticleDirection.DOWN, Vector2i(0, 1)],
		[_EmitterConfigNode.ParticleDirection.LEFT, Vector2i(-1, 0)],
		[_EmitterConfigNode.ParticleDirection.UP, Vector2i(0, -1)],
	]
	for case: Array in cases:
		var d: int = case[0]
		var expected: Vector2i = case[1]
		var got: Vector2i = _EmitterConfigNode.particle_direction_to_vector(d)
		_check(NAME, got == expected, "ParticleDirection %d 应映射到 %s，实际 %s。" % [d, expected, got])
	config.free()


## 7. get_active_direction_vector 随形态切换返回对应方向。
func _test_07_active_direction_switches_with_form() -> void:
	const NAME: String = "07_active随形态切换"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, 1), "RAY 形态 active 应为光线方向 (0,1)，实际 %s。" % [config.get_active_direction_vector()])
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, -1), "PARTICLE 形态 active 应为光粒方向 (0,-1)，实际 %s。" % [config.get_active_direction_vector()])
	# 切回 RAY：active 应回到光线方向，且光线方向未被形态切换覆盖。
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.get_active_direction_vector() == Vector2i(0, 1), "切回 RAY 后 active 应为 (0,1)，实际 %s。" % [config.get_active_direction_vector()])
	config.free()


## 8. RAY 形态 is_runtime_form_supported 为 true。
func _test_08_runtime_supported_ray() -> void:
	const NAME: String = "08_RAY运行时支持"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.is_runtime_form_supported() == true, "RAY 形态应支持运行时。")
	config.free()


## 9. PARTICLE 形态 is_runtime_form_supported 为 false（不抛假结果、不自动降级）。
func _test_09_runtime_not_supported_particle() -> void:
	const NAME: String = "09_PARTICLE运行时不支持"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.is_runtime_form_supported() == false, "PARTICLE 形态不应支持运行时。")
	_check(NAME, config.get_default_light_form() == _EmitterConfigNode.LightForm.PARTICLE, "设置后形态应仍为 PARTICLE，未自动降级为 RAY。")
	config.free()


## 10. 光线与光粒方向分开保存；切换形态不丢失另一方向。
func _test_10_directions_stored_separately() -> void:
	const NAME: String = "10_方向分开保存"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.DOWN, "切到 PARTICLE 后光线方向应仍为 DOWN。")
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "切到 PARTICLE 后光粒方向应为 UP。")
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.DOWN, "切回 RAY 后光线方向应仍为 DOWN。")
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "切回 RAY 后光粒方向应仍为 UP。")
	config.free()


## 11. visual_profile 允许为空。
func _test_11_visual_profile_nullable() -> void:
	const NAME: String = "11_visual_profile可空"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.get_visual_profile() == null, "默认 visual_profile 应为 null，实际 %s。" % [config.get_visual_profile()])
	_check(NAME, config.visual_profile == null, "visual_profile 字段默认应为 null。")
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	config.visual_profile = profile
	_check(NAME, config.get_visual_profile() == profile, "赋值后 get_visual_profile 应返回同一资源。")
	config.visual_profile = null
	_check(NAME, config.get_visual_profile() == null, "置空后 visual_profile 应为 null。")
	# ObjectVisualProfile 为 RefCounted，随引用计数自动回收，不调用 free()。
	config.free()


## 12. editor_preview_visible 默认 true。
func _test_12_editor_preview_default_true() -> void:
	const NAME: String = "12_预览默认可见"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, config.is_editor_preview_visible() == true, "默认 editor_preview_visible 应为 true。")
	_check(NAME, config.editor_preview_visible == true, "editor_preview_visible 字段默认应为 true。")
	config.free()


## 13. 配置实际变化时发 configuration_changed。
func _test_13_configuration_changed_on_change() -> void:
	const NAME: String = "13_配置变化发信号"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var counters: Dictionary = _connect_counters(config)
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, counters["config"] == 1, "切换形态应发一次 configuration_changed，实际 %d。" % [counters["config"]])
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	_check(NAME, counters["config"] == 2, "改光线方向应再发一次，实际 %d。" % [counters["config"]])
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	_check(NAME, counters["config"] == 3, "改光粒方向应再发一次，实际 %d。" % [counters["config"]])
	config.free()


## 14. 重复设置相同值不重复发信号。
func _test_14_no_signal_on_same_value() -> void:
	const NAME: String = "14_重复值不发信号"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	var counters: Dictionary = _connect_counters(config)
	# 全部重复当前值，不应触发任何信号。
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	config.editor_preview_visible = true
	_check(NAME, counters["config"] == 0, "重复相同值不应发 configuration_changed，实际 %d。" % [counters["config"]])
	_check(NAME, counters["preview"] == 0, "重复相同预览值不应发 preview_visibility_changed，实际 %d。" % [counters["preview"]])
	config.free()


## 15. profile 与 preview 专属信号；两者变化同时发 configuration_changed。
func _test_15_profile_and_preview_signals() -> void:
	const NAME: String = "15_profile与preview专属信号"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var counters: Dictionary = _connect_counters(config)
	var profile_a: _ObjectVisualProfile = _ObjectVisualProfile.new()
	var profile_b: _ObjectVisualProfile = _ObjectVisualProfile.new()
	# 设置 profile：发 visual_profile_changed 与 configuration_changed。
	config.visual_profile = profile_a
	_check(NAME, counters["profile"] == 1, "设置 profile 应发一次 visual_profile_changed，实际 %d。" % [counters["profile"]])
	_check(NAME, counters["profile_arg"] == profile_a, "visual_profile_changed 参数应为 profile_a。")
	_check(NAME, counters["config"] == 1, "设置 profile 应同时发一次 configuration_changed，实际 %d。" % [counters["config"]])
	# 重复同一 profile：不发信号。
	config.visual_profile = profile_a
	_check(NAME, counters["profile"] == 1, "重复同一 profile 不应再发 visual_profile_changed，实际 %d。" % [counters["profile"]])
	_check(NAME, counters["config"] == 1, "重复同一 profile 不应再发 configuration_changed，实际 %d。" % [counters["config"]])
	# 换 profile_b：再发一次。
	config.visual_profile = profile_b
	_check(NAME, counters["profile"] == 2, "换 profile 应再发一次 visual_profile_changed，实际 %d。" % [counters["profile"]])
	_check(NAME, counters["config"] == 2, "换 profile 应再发一次 configuration_changed，实际 %d。" % [counters["config"]])
	# 切换预览可见性：发 preview_visibility_changed 与 configuration_changed。
	config.editor_preview_visible = false
	_check(NAME, counters["preview"] == 1, "切预览应发一次 preview_visibility_changed，实际 %d。" % [counters["preview"]])
	_check(NAME, counters["preview_arg"] == false, "preview_visibility_changed 参数应为 false。")
	_check(NAME, counters["config"] == 3, "切预览应同时发一次 configuration_changed，实际 %d。" % [counters["config"]])
	# 重复 false：不发。
	config.editor_preview_visible = false
	_check(NAME, counters["preview"] == 1, "重复 false 不应再发 preview_visibility_changed，实际 %d。" % [counters["preview"]])
	_check(NAME, counters["config"] == 3, "重复 false 不应再发 configuration_changed，实际 %d。" % [counters["config"]])
	# profile_a/profile_b 为 RefCounted，随引用计数自动回收，不调用 free()。
	config.free()


## 16. position 仍是唯一位置事实，cell 由 position 派生；无 emitter_position/emitter_id 双事实。
func _test_16_position_is_sole_fact() -> void:
	const NAME: String = "16_position唯一事实"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var cell: Vector2i = Vector2i(3, 1)
	config.position = _GridCoordinateRules.cell_to_world(cell)
	_check(NAME, config.get_cell() == cell, "position 写入后 cell 应派生为 (3,1)，实际 %s。" % [config.get_cell()])
	_check(NAME, config.cell == cell, ".cell 应与 get_cell 一致为 (3,1)。")
	var prop_names: PackedStringArray = _property_names(config)
	_check(NAME, not prop_names.has("emitter_position"), "不应存在 emitter_position 属性（位置双事实）。")
	_check(NAME, not prop_names.has("emitter_id"), "本批不应存在 emitter_id 属性。")
	# cell 仍由基类派生提供，非本类重新导出。
	_check(NAME, prop_names.has("cell"), "cell 应由基类提供。")
	_check(NAME, prop_names.has("position"), "position 应为 Node2D 原生属性。")
	config.free()


## 17. 不依赖 FixedEmitter/CoreLoopPrototype/LightPathLayer/RayExecutionModule/Validator/addons。
##    D3C-0 起合法引用 ObjectVisualView 与 EmissionPreview 两个直属子节点类型，不再禁止。
func _test_17_no_forbidden_dependencies() -> void:
	const NAME: String = "17_无禁止依赖"
	var src: String = _EmitterConfigNode.source_code
	for token: String in ["FixedEmitter", "CoreLoopPrototype", "LightPathLayer", "RayExecutionModule", "Validator", "addons"]:
		_check(NAME, not src.contains(token), "源码不应引用禁止依赖 %s。" % [token])


## 18. 不加载正式主场景：未 change_scene，root 无主场景子节点。
func _test_18_no_main_scene_loaded() -> void:
	const NAME: String = "18_不加载主场景"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	_check(NAME, root.get_child_count() == 0, "测试期间不应向 root 挂载节点，实际 root 子节点数 %d。" % [root.get_child_count()])
	config.free()


## 19. 非法枚举值被拒绝并保持旧值（允许产生预期 push_error，不计入失败）。
func _test_19_illegal_values_rejected() -> void:
	const NAME: String = "19_非法值拒绝"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	config.default_light_form = 99  # 非法 LightForm：预期 push_error
	_check(NAME, config.get_default_light_form() == _EmitterConfigNode.LightForm.RAY, "非法 LightForm 应被拒绝保持 RAY，实际 %d。" % [config.get_default_light_form()])
	config.ray_default_direction = 99  # 非法 RayDirection：预期 push_error
	_check(NAME, config.get_ray_direction() == _EmitterConfigNode.RayDirection.RIGHT, "非法 RayDirection 应被拒绝保持 RIGHT，实际 %d。" % [config.get_ray_direction()])
	_check(NAME, config.get_ray_direction_vector() == Vector2i(1, 0), "拒绝后光线方向向量仍为 (1,0)。")
	config.particle_default_direction = 99  # 非法 ParticleDirection：预期 push_error
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.RIGHT, "非法 ParticleDirection 应被拒绝保持 RIGHT，实际 %d。" % [config.get_particle_direction()])
	# 非法值不应发 configuration_changed。
	var counters: Dictionary = _connect_counters(config)
	config.default_light_form = 99
	config.ray_default_direction = 99
	config.particle_default_direction = 99
	_check(NAME, counters["config"] == 0, "非法值被拒绝不应发 configuration_changed，实际 %d。" % [counters["config"]])
	config.free()


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


## 取节点全部属性名，用于结构性断言。
func _property_names(node: Object) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for prop: Dictionary in node.get_property_list():
		names.append(prop["name"])
	return names


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 34
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 测试摘要 ====")
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
