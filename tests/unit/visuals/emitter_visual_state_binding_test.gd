extends SceneTree

## 存量视觉接入第二批定向测试（发射器形态状态接入，headless）。
## 覆盖：发射器 tscn 实例化并绑定 emitter_visuals.tres、形态状态契约（default/ray/particle 与脚本
##   STATE_* 精确一致，无缺失、无发明）、配置轴与运行时形态入口均经 set_content_state 正式契约驱动
##   EmitterVisual、无双 Sprite / 单 Artwork、Artwork resolver 可选择发射器根与 View、非库存契约
##   （inventory_icon 为空）。由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 注：--script 不泵帧，_ready 按既有测试惯例显式调用；不触运行行为，不改任何资源文件。

const _EMITTER_SCENE: PackedScene = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.tscn"
)
const _EMITTER_SCRIPT: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)
const _EMITTER_PROFILE_PATH: String = "res://assets/visual_profiles/emitter_visuals.tres"
const _CORE_LOOP_SCRIPT_PATH: String = "res://levels/prototypes/core_loop_prototype.gd"
const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_resolver.gd"
)
const _ResultScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_result.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)

## 公共 LightForm 契约冻结值（LightEmissionTypes.LightForm）：RAY=0 / PARTICLE=1。
const _FORM_RAY: int = 0
const _FORM_PARTICLE: int = 1

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _resolver: RefCounted = _ResolverScript.new()


func _initialize() -> void:
	_test_01_scene_binds_profile()
	_test_02_state_contract_matches_script()
	_test_03_config_axis_drives_state()
	_test_04_runtime_form_entry_drives_state()
	_test_05_no_double_sprite()
	_test_06_resolver_selects_emitter()
	_test_07_not_inventory_token()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 发射器 tscn 实例化：根脚本正确、含 EmitterVisual 子节点且已绑定 emitter_visuals.tres（校验无问题）。
func _test_01_scene_binds_profile() -> void:
	const NAME: String = "01_场景绑定Profile"
	var node: Node = _EMITTER_SCENE.instantiate()
	root.add_child(node)
	_check(NAME, node.get_script() == _EMITTER_SCRIPT, "发射器根节点应挂 EmitterConfigNode 脚本。")
	var view: Node = node.get_node_or_null("EmitterVisual")
	_check(NAME, view != null, "发射器应含 EmitterVisual 子节点。")
	if view == null:
		node.free()
		return
	var profile = view.get("visual_profile")
	_check(NAME, profile != null, "EmitterVisual 应绑定 visual_profile。")
	if profile == null:
		node.free()
		return
	_check(
		NAME,
		profile.resource_path == _EMITTER_PROFILE_PATH,
		"EmitterVisual profile 路径应为 %s，实际 %s。" % [_EMITTER_PROFILE_PATH, profile.resource_path]
	)
	_check(
		NAME,
		(profile as _ObjectVisualProfile).validate_profile().is_empty(),
		"emitter_visuals 的 validate_profile 应无问题。"
	)
	node.free()


## 2. 形态状态契约：profile states 与发射器脚本 STATE_* 常量集合精确一致（无缺失、无发明），
##    每个状态 world/drag 纹理可解析非空；default_state_id 显式为 default 且存在于 states。
func _test_02_state_contract_matches_script() -> void:
	const NAME: String = "02_形态状态契约"
	var profile: _ObjectVisualProfile = load(_EMITTER_PROFILE_PATH) as _ObjectVisualProfile
	_check(NAME, profile != null, "emitter_visuals 应可加载。")
	if profile == null:
		return

	var script_states: Array = []
	for const_name: String in _EMITTER_SCRIPT.get_script_constant_map().keys():
		if const_name.begins_with("STATE_"):
			script_states.append(_EMITTER_SCRIPT.get_script_constant_map()[const_name])
	_check(NAME, script_states.size() == 3, "发射器脚本应声明 3 个 STATE_* 常量，实际 %d。" % script_states.size())

	var profile_states: Array = []
	for state in profile.states:
		profile_states.append(state.state_id)
	_check(NAME, profile_states.size() == 3, "emitter_visuals 应有 3 个状态，实际 %d。" % profile_states.size())

	for state_id: StringName in script_states:
		_check(NAME, profile_states.has(state_id), "emitter_visuals 缺少脚本契约状态 %s。" % state_id)
		_check(
			NAME,
			profile.get_world_texture(state_id) != null,
			"状态 %s 的 world_texture 应非空。" % state_id
		)
		_check(
			NAME,
			profile.get_drag_texture(state_id) != null,
			"状态 %s 的 drag 纹理（回退 world）应非空。" % state_id
		)
	for state_id: StringName in profile_states:
		_check(
			NAME,
			script_states.has(state_id),
			"emitter_visuals 发明了脚本契约外的状态 %s。" % state_id
		)
	_check(NAME, profile.default_state_id == &"default", "default_state_id 应显式为 default。")
	_check(NAME, profile.has_state(profile.default_state_id), "default_state_id 应存在于 states。")


## 3. 配置轴驱动：场景 ready 后按 default_light_form 写入内容状态并解析纹理；
##    修改 default_light_form（Inspector setter）同样经正式契约刷新。
func _test_03_config_axis_drives_state() -> void:
	const NAME: String = "03_配置轴驱动状态"
	var node: Node = _EMITTER_SCENE.instantiate()
	root.add_child(node)
	var view: Node = node.get_node("EmitterVisual")
	view._ready()
	node._ready()
	var profile: _ObjectVisualProfile = view.get("visual_profile") as _ObjectVisualProfile
	var artwork: TextureRect = view.get_node("Artwork")
	_check(
		NAME,
		view.call("get_content_state") == &"ray",
		"默认 RAY 形态 ready 后内容状态应为 ray。"
	)
	_check(
		NAME,
		artwork.texture != null and artwork.texture == profile.get_world_texture(&"ray"),
		"ready 后 ray 状态应解析出与 profile 一致的纹理。"
	)
	node.set("default_light_form", _FORM_PARTICLE)
	_check(
		NAME,
		view.call("get_content_state") == &"particle",
		"配置切到 PARTICLE 后内容状态应为 particle。"
	)
	_check(
		NAME,
		artwork.texture != null and artwork.texture == profile.get_world_texture(&"particle"),
		"PARTICLE 配置应解析出 particle 状态纹理。"
	)
	node.free()


## 4. 运行时形态入口：set_visual_light_form（Q 切换 / R 恢复后关卡核心调用点）驱动内容状态；
##    静态映射与 core_loop 源码接线（Q 成功后、R 恢复后）经源码断言防回归。
func _test_04_runtime_form_entry_drives_state() -> void:
	const NAME: String = "04_运行时形态入口"
	var node: Node = _EMITTER_SCENE.instantiate()
	root.add_child(node)
	var view: Node = node.get_node("EmitterVisual")
	view._ready()
	node._ready()
	node.call("set_visual_light_form", _FORM_PARTICLE)
	_check(
		NAME,
		view.call("get_content_state") == &"particle",
		"set_visual_light_form(PARTICLE) 后内容状态应为 particle。"
	)
	node.call("set_visual_light_form", _FORM_RAY)
	_check(
		NAME,
		view.call("get_content_state") == &"ray",
		"set_visual_light_form(RAY) 后内容状态应为 ray。"
	)
	node.free()

	var src: String = FileAccess.get_file_as_string(_CORE_LOOP_SCRIPT_PATH)
	_check(
		NAME,
		src.find("_emitter_config.set_visual_light_form(new_form)") != -1,
		"core_loop Q 切换成功后应调用 set_visual_light_form 驱动视觉。"
	)
	_check(
		NAME,
		src.find("_emitter_config.set_visual_light_form(_fixed_emitter.get_light_form())") != -1,
		"core_loop R 恢复后应按 FixedEmitter 形态同步视觉。"
	)


## 5. 无双渲染：发射器子树无 Sprite2D、恰一个 ObjectVisualView、恰一个 TextureRect（Artwork）；
##    发射器脚本经 set_content_state 驱动纹理，无并行 texture 赋值。
func _test_05_no_double_sprite() -> void:
	const NAME: String = "05_无双Sprite"
	var node: Node = _EMITTER_SCENE.instantiate()
	root.add_child(node)
	var views: Array = []
	var sprites: Array = []
	var textures: Array = []
	_collect_visual_nodes(node, views, sprites, textures)
	_check(NAME, sprites.is_empty(), "发射器子树不应存在 Sprite2D（%d 个）。" % sprites.size())
	_check(NAME, views.size() == 1, "发射器子树应恰有一个 ObjectVisualView（%d 个）。" % views.size())
	_check(NAME, textures.size() == 1, "发射器子树应恰有一个 TextureRect 即 Artwork（%d 个）。" % textures.size())
	node.free()

	var emitter_src: String = FileAccess.get_file_as_string(
		"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
	)
	_check(
		NAME,
		emitter_src.find("set_content_state") != -1 and emitter_src.find(".texture =") == -1,
		"发射器脚本应只经 set_content_state 驱动纹理，无并行 texture 赋值。"
	)


## 6. Artwork resolver：选择发射器根解析为单目标（主目标 EmitterVisual、组件根为发射器自身）；
##    直接选择 EmitterVisual 亦为单目标。
func _test_06_resolver_selects_emitter() -> void:
	const NAME: String = "06_resolver可选择"
	var node: Node = _EMITTER_SCENE.instantiate()
	root.add_child(node)
	var view: Node = node.get_node("EmitterVisual")
	var result: RefCounted = _resolver.resolve(node)
	_check(
		NAME,
		result.get_status() == _ResultScript.Status.SINGLE_TARGET,
		"发射器根应解析为单目标。"
	)
	var primary: Node = result.get_primary_target()
	_check(NAME, primary != null and primary.name == "EmitterVisual", "主目标应为 EmitterVisual。")
	_check(NAME, result.get_component_root() == node, "组件根应为发射器自身。")

	var direct: RefCounted = _resolver.resolve(view)
	_check(
		NAME,
		direct.get_status() == _ResultScript.Status.SINGLE_TARGET and direct.get_primary_target() == view,
		"直接选择 EmitterVisual 应解析为单目标且主目标为自身。"
	)
	node.free()


## 7. 非库存契约：发射器非库存 Token，inventory_icon 保持为空，脚本不引用库存图标字段。
func _test_07_not_inventory_token() -> void:
	const NAME: String = "07_非库存契约"
	var profile: _ObjectVisualProfile = load(_EMITTER_PROFILE_PATH) as _ObjectVisualProfile
	_check(NAME, profile != null, "emitter_visuals 应可加载。")
	if profile == null:
		return
	_check(NAME, profile.inventory_icon == null, "发射器非库存 Token，inventory_icon 应为空。")
	var emitter_src: String = FileAccess.get_file_as_string(
		"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
	)
	_check(
		NAME,
		emitter_src.find("inventory_icon") == -1,
		"发射器脚本不应引用 inventory_icon。"
	)


# ===== 辅助 =====

## 递归收集发射器子树中的 ObjectVisualView / Sprite2D / TextureRect 节点。
func _collect_visual_nodes(node: Node, out_views: Array, out_sprites: Array, out_textures: Array) -> void:
	for child: Node in node.get_children():
		if child is ObjectVisualView:
			out_views.append(child)
		if child is Sprite2D:
			out_sprites.append(child)
		if child is TextureRect:
			out_textures.append(child)
		_collect_visual_nodes(child, out_views, out_sprites, out_textures)


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
	print("==== 发射器视觉状态绑定测试摘要 ====")
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
