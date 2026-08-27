extends SceneTree

## 存量视觉接入第一批定向测试（加速器/减速器正式视觉绑定 + 三正式 Profile inventory_icon）。
## 覆盖：两机关原始 tscn 实例化并绑定各自新 ObjectVisualProfile、8 方向状态与脚本 STATE_* 契约
##   精确一致（无缺失、无发明）、default_state_id 明确、set_content_state 逐一驱动 Artwork 非空纹理、
##   镜面/加速器/减速器三 profile 的 inventory_icon 非空且直引现有纹理、Artwork resolver 可选择机关视觉。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：--script 不泵帧，_ready 按既有测试惯例显式调用；不触运行行为，不改任何资源文件。

const _ACCEL_SCENE: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.tscn"
)
const _DECEL_SCENE: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_decelerator.tscn"
)
const _ACCEL_SCRIPT: GDScript = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.gd"
)
const _DECEL_SCRIPT: GDScript = preload(
	"res://gameplay/mechanisms/speed/particle_decelerator.gd"
)
const _ACCEL_PROFILE_PATH: String = "res://assets/visual_profiles/particle_accelerator_visuals.tres"
const _DECEL_PROFILE_PATH: String = "res://assets/visual_profiles/particle_decelerator_visuals.tres"
const _MIRROR_PROFILE_PATH: String = "res://assets/visual_profiles/single_cell_mirror_visuals.tres"
const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_resolver.gd"
)
const _ResultScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_result.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _resolver: RefCounted = _ResolverScript.new()


func _initialize() -> void:
	_test_01_scenes_bind_profiles()
	_test_02_state_contract_matches_script(_ACCEL_SCENE, _ACCEL_SCRIPT, _ACCEL_PROFILE_PATH, "加速器")
	_test_02_state_contract_matches_script(_DECEL_SCENE, _DECEL_SCRIPT, _DECEL_PROFILE_PATH, "减速器")
	_test_03_set_content_state_drives_artwork()
	_test_04_inventory_icons_non_null()
	_test_05_resolver_selects_mechanism_visual()
	await _test_06_direction_rotation_and_arrow_fallback()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 两机关 tscn 实例化：根脚本正确、含 VisualView 子节点且已绑定各自 profile 资源（路径正确、校验无问题）。
func _test_01_scenes_bind_profiles() -> void:
	const NAME: String = "01_场景绑定Profile"
	var cases: Array = [
		[_ACCEL_SCENE, _ACCEL_SCRIPT, _ACCEL_PROFILE_PATH, "加速器"],
		[_DECEL_SCENE, _DECEL_SCRIPT, _DECEL_PROFILE_PATH, "减速器"],
	]
	for entry: Array in cases:
		var node: Node = (entry[0] as PackedScene).instantiate()
		root.add_child(node)
		_check(NAME, node.get_script() == entry[1], "%s 根节点应挂各自机关脚本。" % entry[3])
		var view: Node = node.get_node_or_null("VisualView")
		_check(NAME, view != null, "%s 应含 VisualView 子节点。" % entry[3])
		if view == null:
			node.free()
			continue
		var profile = view.get("visual_profile")
		_check(NAME, profile != null, "%s 的 VisualView 应绑定 visual_profile。" % entry[3])
		if profile == null:
			node.free()
			continue
		_check(
			NAME,
			profile.resource_path == entry[2],
			"%s profile 资源路径应为 %s，实际 %s。" % [entry[3], entry[2], profile.resource_path]
		)
		_check(
			NAME,
			(profile as _ObjectVisualProfile).validate_profile().is_empty(),
			"%s profile 的 validate_profile 应无问题。" % entry[3]
		)
		node.free()


## 2. 8 方向状态契约：profile states 与机关脚本 STATE_* 常量集合精确一致（无缺失、无发明），
##    每个状态 world/drag 纹理可解析非空；default_state_id 为 right 且存在于 states。
func _test_02_state_contract_matches_script(scene: PackedScene, script: GDScript, profile_path: String, label: String) -> void:
	const NAME: String = "02_8方向状态契约"
	var profile: _ObjectVisualProfile = load(profile_path) as _ObjectVisualProfile
	_check(NAME, profile != null, "%s profile 应可加载。" % label)
	if profile == null:
		return

	# 从脚本常量表收集 STATE_* 契约值（不硬编码，反射脚本唯一事实）。
	var script_states: Array = []
	for const_name: String in script.get_script_constant_map().keys():
		if const_name.begins_with("STATE_"):
			script_states.append(script.get_script_constant_map()[const_name])
	_check(NAME, script_states.size() == 8, "%s 脚本应声明 8 个 STATE_* 常量，实际 %d。" % [label, script_states.size()])

	var profile_states: Array = []
	for state in profile.states:
		profile_states.append(state.state_id)
	_check(NAME, profile_states.size() == 8, "%s profile 应有 8 个状态，实际 %d。" % [label, profile_states.size()])

	for state_id: StringName in script_states:
		_check(
			NAME,
			profile_states.has(state_id),
			"%s profile 缺少脚本契约状态 %s。" % [label, state_id]
		)
		_check(
			NAME,
			profile.get_world_texture(state_id) != null,
			"%s 状态 %s 的 world_texture 应非空。" % [label, state_id]
		)
		_check(
			NAME,
			profile.get_drag_texture(state_id) != null,
			"%s 状态 %s 的 drag 纹理（回退 world）应非空。" % [label, state_id]
		)
	for state_id: StringName in profile_states:
		_check(
			NAME,
			script_states.has(state_id),
			"%s profile 发明了脚本契约外的状态 %s。" % [label, state_id]
		)
	_check(NAME, profile.default_state_id == &"right", "%s default_state_id 应为 right。" % label)
	_check(NAME, profile.has_state(profile.default_state_id), "%s default_state_id 应存在于 states。" % label)


## 3. set_content_state 驱动 view：两机关场景 ready 后逐一写入 8 状态，Artwork 纹理均非空且等于 profile 世界纹理。
func _test_03_set_content_state_drives_artwork() -> void:
	const NAME: String = "03_内容状态驱动纹理"
	var cases: Array = [
		[_ACCEL_SCENE, _ACCEL_SCRIPT, "加速器"],
		[_DECEL_SCENE, _DECEL_SCRIPT, "减速器"],
	]
	var state_ids: Array[StringName] = [&"right", &"down_right", &"down", &"down_left", &"left", &"up_left", &"up", &"up_right"]
	for entry: Array in cases:
		var node: Node = (entry[0] as PackedScene).instantiate()
		root.add_child(node)
		var view: Node = node.get_node("VisualView")
		view._ready()
		var profile: _ObjectVisualProfile = view.get("visual_profile") as _ObjectVisualProfile
		var artwork: TextureRect = view.get_node("Artwork")
		_check(
			NAME,
			artwork.texture != null and artwork.texture == profile.get_world_texture(&"right"),
			"%s ready 后初始状态 right 应解析出纹理。" % entry[2]
		)
		for state_id: StringName in state_ids:
			view.set_content_state(state_id)
			_check(
				NAME,
				artwork.texture != null and artwork.texture == profile.get_world_texture(state_id),
				"%s set_content_state(%s) 后 Artwork 纹理应非空且匹配。" % [entry[2], state_id]
			)
		node.free()


## 4. 三正式 profile inventory_icon 非空且直引现有纹理（不复制资产）。
func _test_04_inventory_icons_non_null() -> void:
	const NAME: String = "04_三图标非空"
	var icon_cases: Array = [
		[_MIRROR_PROFILE_PATH, "mirror_slash.png", "镜面"],
		[_ACCEL_PROFILE_PATH, "light_up_speed_mechine.png", "加速器"],
		[_DECEL_PROFILE_PATH, "light_down_speed_mechine.png", "减速器"],
	]
	for entry: Array in icon_cases:
		var profile: _ObjectVisualProfile = load(entry[0]) as _ObjectVisualProfile
		_check(NAME, profile != null, "%s profile 应可加载。" % entry[2])
		if profile == null:
			continue
		var icon: Texture2D = profile.inventory_icon
		_check(NAME, icon != null, "%s 的 inventory_icon 应非空。" % entry[2])
		if icon != null:
			_check(
				NAME,
				icon.resource_path.contains(entry[1]),
				"%s inventory_icon 应直引 %s，实际 %s。" % [entry[2], entry[1], icon.resource_path]
			)


## 5. Artwork resolver：选择两机关根应解析为单目标，主目标为其 VisualView，组件根为机关自身。
func _test_05_resolver_selects_mechanism_visual() -> void:
	const NAME: String = "05_resolver可选择"
	for entry: Array in [[_ACCEL_SCENE, "加速器"], [_DECEL_SCENE, "减速器"]]:
		var node: Node = (entry[0] as PackedScene).instantiate()
		root.add_child(node)
		var result: RefCounted = _resolver.resolve(node)
		_check(
			NAME,
			result.get_status() == _ResultScript.Status.SINGLE_TARGET,
			"%s 根应解析为单目标。" % entry[1]
		)
		var primary: Node = result.get_primary_target()
		_check(
			NAME,
			primary != null and primary.name == "VisualView",
			"%s 主目标应为 VisualView。" % entry[1]
		)
		_check(NAME, result.get_component_root() == node, "%s 组件根应为机关自身。" % entry[1])
		node.free()

## 6. direction 派生 Artwork 旋转 + DebugArrow 占位后备语义：
##    旋转基准 = 加速器贴图（light_up，绿箭头绘制朝左）PI / 减速器贴图（light_down，红箭头绘制朝右）0；
##    RIGHT/LEFT/UP 三档角度逐一按模 2π 对表（非公式回声；-π 与 +π 视觉等价按模判定，非边界 wrapf）；
##    正式纹理可解析时箭头隐藏；profile 置空（纹理缺失）时箭头显示且末点指向 direction（DOWN → (0,28)）。
##    headless --script 下 _initialize 不泵帧、_ready 不触发，故 add_child 后 await process_frame
##    等 _ready/_refresh_direction_visual 完成再断言（repo 既有异步边界约定）。
func _test_06_direction_rotation_and_arrow_fallback() -> void:
	const NAME: String = "06_方向旋转与箭头后备"
	var cases: Array = [
		# [场景, 标签, RIGHT 期望角, LEFT 期望角(wrap), UP 期望角(wrap), LEFT/UP/DOWN 枚举值]
		[_ACCEL_SCENE, "加速器", PI, 0.0, PI / 2.0, _ACCEL_SCRIPT.AcceleratorDirection.LEFT,
			_ACCEL_SCRIPT.AcceleratorDirection.UP, _ACCEL_SCRIPT.AcceleratorDirection.DOWN],
		[_DECEL_SCENE, "减速器", PI, 0.0, PI / 2.0, _DECEL_SCRIPT.DeceleratorDirection.LEFT,
			_DECEL_SCRIPT.DeceleratorDirection.UP, _DECEL_SCRIPT.DeceleratorDirection.DOWN],
	]
	for entry: Array in cases:
		var node: Node = (entry[0] as PackedScene).instantiate()
		root.add_child(node)
		await process_frame
		var view: Node = node.get_node("VisualView")
		var artwork: TextureRect = view.get_node("Artwork")
		var arrow: Line2D = node.get_node("DebugArrow")
		_check(
			NAME,
			is_equal_approx(wrapf(artwork.rotation - entry[2], -PI, PI), 0.0),
			"%s 默认 RIGHT 旋转角（模 2π）期望 %f，实际 %f。" % [entry[1], entry[2], artwork.rotation]
		)
		_check(NAME, arrow.visible == false, "%s 正式纹理可解析时 DebugArrow 应隐藏。" % entry[1])
		_check(
			NAME,
			artwork.pivot_offset == Vector2(32.0, 32.0),
			"%s 旋转 pivot 应为纹理中心 (32,32)，实际 (%f,%f)。"
				% [entry[1], artwork.pivot_offset.x, artwork.pivot_offset.y]
		)
		node.set_direction(entry[5])
		_check(
			NAME,
			is_equal_approx(wrapf(artwork.rotation - entry[3], -PI, PI), 0.0),
			"%s LEFT 旋转角（模 2π）期望 %f，实际 %f。" % [entry[1], entry[3], artwork.rotation]
		)
		_check(NAME, arrow.visible == false, "%s LEFT 下纹理可解析时 DebugArrow 仍应隐藏。" % entry[1])
		node.set_direction(entry[6])
		_check(
			NAME,
			is_equal_approx(wrapf(artwork.rotation - entry[4], -PI, PI), 0.0),
			"%s UP 旋转角（模 2π）期望 %f，实际 %f。" % [entry[1], entry[4], artwork.rotation]
		)
		# 纹理缺失后备：置空 profile 后箭头显示且末点指向 direction（DOWN → (0,28)）。
		view.set_profile(null)
		node.set_direction(entry[7])
		_check(NAME, arrow.visible == true, "%s 纹理缺失时 DebugArrow 应显示（占位后备）。" % entry[1])
		_check(
			NAME,
			arrow.points[1] == Vector2(0.0, 28.0),
			"%s 纹理缺失时箭头末点应指向 DOWN (0,28)，实际 %s。" % [entry[1], arrow.points[1]]
		)
		node.free()


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
	print("==== 速度机关视觉绑定测试摘要 ====")
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
