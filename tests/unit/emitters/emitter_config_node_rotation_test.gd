extends SceneTree

## EmitterConfigNode 单元测试（拆分片 5/5 · EmitterVisual 视觉角度 D3C-2.5）。
## 覆盖：EmitterVisual.rotation 由 default_light_form 与活动方向驱动（RIGHT=0、DOWN_RIGHT=PI/4、
##   DOWN=PI/2、UP=-PI/2、LEFT≈±PI）、PARTICLE 用光粒方向、两形态方向独立保存、切换形态立即更新、
##   非活动方向不改当前朝向、根节点 rotation 始终 0、EmitterVisual.position 不变、重复值不刷新朝向。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _ObjectVisualView: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
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


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_35_visual_rotation_default_right_zero()
	_test_36_visual_rotation_ray_down_right()
	_test_37_visual_rotation_ray_down()
	_test_38_visual_rotation_ray_up()
	_test_39_visual_rotation_left_pi()
	_test_40_visual_rotation_particle_uses_particle_direction()
	_test_41_ray_particle_directions_stored_separately_rotation()
	_test_42_switch_form_updates_visual_rotation_immediately()
	_test_43_non_active_direction_no_visual_rotation_change()
	_test_44_emitter_root_rotation_stays_zero()
	_test_45_emitter_visual_position_unchanged()
	_test_46_repeat_value_no_visual_rotation_refresh()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 35. 默认 RIGHT 时 EmitterVisual.rotation == 0（基础图片朝向 RIGHT）。
func _test_35_visual_rotation_default_right_zero() -> void:
	const NAME: String = "35_默认RIGHT旋转0"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	var rot: float = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot, 0.0), "默认 RIGHT 时 EmitterVisual.rotation 应为 0，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 36. RAY DOWN_RIGHT 时 EmitterVisual.rotation == PI/4。
func _test_36_visual_rotation_ray_down_right() -> void:
	const NAME: String = "36_RAY_DOWN_RIGHT旋转PI/4"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN_RIGHT
	var rot: float = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot, PI / 4.0), "RAY DOWN_RIGHT 时 rotation 应为 PI/4，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 37. RAY DOWN 时 EmitterVisual.rotation == PI/2。
func _test_37_visual_rotation_ray_down() -> void:
	const NAME: String = "37_RAY_DOWN旋转PI/2"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	var rot: float = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot, PI / 2.0), "RAY DOWN 时 rotation 应为 PI/2，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 38. RAY UP 时 EmitterVisual.rotation == -PI/2。
func _test_38_visual_rotation_ray_up() -> void:
	const NAME: String = "38_RAY_UP旋转-PI/2"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.UP
	var rot: float = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot, -PI / 2.0), "RAY UP 时 rotation 应为 -PI/2，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 39. LEFT 时方向等价于 PI 或 -PI（Vector2(-1,0).angle() 取正负 PI 均接受）。
func _test_39_visual_rotation_left_pi() -> void:
	const NAME: String = "39_LEFT旋转等价PI"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.LEFT
	var rot: float = config._get_emitter_visual().rotation
	var ok: bool = is_equal_approx(rot, PI) or is_equal_approx(rot, -PI)
	_check(NAME, ok, "LEFT 时 rotation 应等价于 PI 或 -PI，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 40. PARTICLE 形态使用 particle_default_direction 计算 rotation。
func _test_40_visual_rotation_particle_uses_particle_direction() -> void:
	const NAME: String = "40_PARTICLE用光粒方向"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.DOWN
	var rot: float = config._get_emitter_visual().rotation
	# particle DOWN → Vector2(0,1).angle() = PI/2；同时验证未误用光线方向（默认 RIGHT → 0）。
	_check(NAME, is_equal_approx(rot, PI / 2.0), "PARTICLE DOWN 时 rotation 应为 PI/2，实际 %s。" % [rot])
	# 改光粒方向为 UP：rotation 应跟随光粒方向变为 -PI/2。
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	rot = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot, -PI / 2.0), "PARTICLE UP 时 rotation 应为 -PI/2，实际 %s。" % [rot])
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 41. RAY 与 PARTICLE 分别保存自己的方向；rotation 随活动形态取对应方向（不互相覆盖）。
func _test_41_ray_particle_directions_stored_separately_rotation() -> void:
	const NAME: String = "41_两形态方向分开保存_rotation"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	# RAY 活动：光线方向 DOWN → PI/2；光粒方向另存为 UP（非活动）。
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, PI / 2.0), "RAY 活动且光线 DOWN 时 rotation 应为 PI/2。")
	# 切到 PARTICLE：rotation 立即取此前保存的光粒方向 UP → -PI/2，证明两方向独立保存。
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, -PI / 2.0), "切到 PARTICLE 后 rotation 应立即取光粒 UP 即 -PI/2。")
	# 切回 RAY：rotation 回到光线 DOWN → PI/2，证明光线方向未被形态切换覆盖。
	config.default_light_form = _EmitterConfigNode.LightForm.RAY
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, PI / 2.0), "切回 RAY 后 rotation 应回到光线 DOWN 即 PI/2。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 42. 切换形态立即更新视觉角度（无须额外触发）。
func _test_42_switch_form_updates_visual_rotation_immediately() -> void:
	const NAME: String = "42_切换形态立即更新旋转"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	# RAY 默认 RIGHT → 0；预设光粒方向 DOWN。
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.DOWN
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, 0.0), "切换前 RAY RIGHT rotation 应为 0。")
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, PI / 2.0), "切到 PARTICLE 后应立即更新为光粒 DOWN 即 PI/2。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 43. 修改非活动形态方向不改变当前视觉角度（配置保存但 rotation 不变）。
func _test_43_non_active_direction_no_visual_rotation_change() -> void:
	const NAME: String = "43_非活动方向不改当前旋转"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	# RAY 活动，光线方向保持 RIGHT → rotation 0。
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, 0.0), "RAY RIGHT 初始 rotation 应为 0。")
	# 修改非活动光粒方向：配置保存，但当前视觉朝向不变。
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	_check(NAME, config.get_particle_direction() == _EmitterConfigNode.ParticleDirection.UP, "光粒方向应保存为 UP。")
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, 0.0), "RAY 活动时改光粒方向，rotation 应保持 0。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 44. Emitter 根节点 rotation 始终为 0（只旋转 EmitterVisual，不旋转根节点）。
func _test_44_emitter_root_rotation_stays_zero() -> void:
	const NAME: String = "44_根节点rotation始终0"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP
	_check(NAME, is_equal_approx(config.rotation, 0.0), "Emitter 根节点 rotation 应始终为 0，实际 %s。" % [config.rotation])
	# EmitterVisual 确实被旋转（非 0），证明旋转落在子节点而非根节点。
	_check(NAME, not is_equal_approx(config._get_emitter_visual().rotation, 0.0), "EmitterVisual 应被旋转（非 0），证明旋转未落在根节点。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 45. EmitterVisual.position 在方向/形态变化后保持不变（不修改 local position）。
func _test_45_emitter_visual_position_unchanged() -> void:
	const NAME: String = "45_EmitterVisual本地位置不变"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	var pos_before: Vector2 = visual.position
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	config.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	config.particle_default_direction = _EmitterConfigNode.ParticleDirection.LEFT
	_check(NAME, visual.position == pos_before, "方向/形态变化后 EmitterVisual 本地位置应不变，实际 %s。" % [visual.position])
	_check(NAME, visual.position == Vector2.ZERO, "EmitterVisual 本地位置应保持 ZERO。")
	config.free()
	_check(NAME, root.get_child_count() == 0, "释放后 root 应无残留。")


## 46. 重复设置同值不重复刷新视觉朝向、不发信号（rotation 不变且 configuration_changed 计数为 0）。
func _test_46_repeat_value_no_visual_rotation_refresh() -> void:
	const NAME: String = "46_重复值不刷新视觉朝向"
	var config: _EmitterConfigNode = _EmitterConfigNode.new()
	var visual: _StubVisual = _StubVisual.new()
	visual.name = "EmitterVisual"
	config.add_child(visual)
	root.add_child(config)
	config._ready()
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	var rot_before: float = config._get_emitter_visual().rotation
	_check(NAME, is_equal_approx(rot_before, PI / 2.0), "前置：RAY DOWN rotation 应为 PI/2。")
	var counters: Dictionary = _connect_counters(config)
	# 重复当前光线方向：不应刷新朝向、不应发信号。
	config.ray_default_direction = _EmitterConfigNode.RayDirection.DOWN
	_check(NAME, is_equal_approx(config._get_emitter_visual().rotation, rot_before), "重复光线方向后 rotation 应不变。")
	_check(NAME, counters["config"] == 0, "重复光线方向不应发 configuration_changed，实际 %d。" % [counters["config"]])
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
	var group_count: int = 12
	var passed_checks: int = _checks - _failures.size()
	print("==== EmitterConfigNode 视觉角度 测试摘要 ====")
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
