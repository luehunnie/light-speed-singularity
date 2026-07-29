extends SceneTree

## EmitterConfigNode 单元测试（拆分片 2/5 · 信号与契约）。
## 覆盖：预览默认可见、配置变化信号、重复值不发信号、profile/preview 专属信号、
##   position 唯一事实、无禁止依赖、不加载主场景、非法值拒绝。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 非法值用例会产生预期 push_error 输出，不计入失败。

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_12_editor_preview_default_true()
	_test_13_configuration_changed_on_change()
	_test_14_no_signal_on_same_value()
	_test_15_profile_and_preview_signals()
	_test_16_position_is_sole_fact()
	_test_17_no_forbidden_dependencies()
	_test_18_no_main_scene_loaded()
	_test_19_illegal_values_rejected()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

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
	var group_count: int = 8
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 信号与契约 测试摘要 ====")
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
