extends SceneTree

## InventoryCardBar / InventoryCardView 定向自动测试（AF-10 第三批）。
## 覆盖：fake 定义两卡动态生成、展示顺序、各自数量独立刷新、选中 type_id、
## 图标活绑定（同 profile 换 inventory_icon 后 refresh 即取新值）、
## 图标源变更后重新构建取新值（替换资源场景语义）、缺图 fallback（profile 空 / inventory_icon 空；
## 正式 definition 真实链自存量视觉接入第一批起显示真实图标：镜面/加速器 profile 均设 inventory_icon）、
## 未知类型安全降级、空计划恢复旧槽位、指针命中 hit-test（泵帧布局后）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _CardBar: GDScript = preload("res://gameplay/ui/inventory_card_bar.gd")
const _CardView: GDScript = preload("res://gameplay/ui/inventory_card_view.gd")
const _VisualViewScene: PackedScene = preload("res://gameplay/visuals/object_visuals/object_visual_view.tscn")
const _VisualProfile: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_profile.gd")
const _RuntimeDefinitionIndex: GDScript = preload(
	"res://gameplay/placement/inventory/runtime_definition_index.gd"
)

const _TYPE_FAKE_A: StringName = &"fake_type_a"
const _TYPE_FAKE_B: StringName = &"fake_type_b"
const _TYPE_MIRROR: StringName = &"basic_single_cell_mirror"
const _TYPE_ACCEL: StringName = &"particle_accelerator"

## 测试桩：正式 Registry 鸭子（get_definition 按类型返回 fake 定义或 null）。
class FakeRegistry:
	var _definitions: Dictionary = {}

	func get_definition(type_id: StringName) -> Variant:
		return _definitions.get(type_id, null)


## 测试桩：FormalContentDefinition 鸭子（display_name + scene）。
class FakeDefinition:
	var display_name: String = ""
	var scene: PackedScene = null

	func _init(p_name: String, p_scene: PackedScene) -> void:
		display_name = p_name
		scene = p_scene


var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready/布局可触发。
	await process_frame
	await _test_01_fake_two_cards_order_and_counts()
	await _test_02_selection_type_id()
	await _test_03_icon_live_binding_and_rebuild()
	await _test_04_missing_icon_fallback()
	await _test_05_formal_definitions_real_chain()
	await _test_06_unknown_type_safe_and_empty_plan()
	await _test_07_hit_test_after_layout()
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 构造带图标纹理的独立 ObjectVisualProfile（fake 正式形状）。
func _make_profile(icon: Texture2D) -> Resource:
	var profile: ObjectVisualProfile = _VisualProfile.new()
	profile.inventory_icon = icon
	return profile


## 构造以指定 profile 为 visual_profile 的可实例化 fake 机关场景（打包游离实例，不落盘）。
func _make_scene_with_profile(profile: Resource) -> PackedScene:
	var view: Node2D = _VisualViewScene.instantiate() as Node2D
	view.visual_profile = profile
	var packed: PackedScene = PackedScene.new()
	packed.pack(view)
	view.free()
	return packed


## 构造两类型 fake Registry（A=3 带图标、B=2 带图标）。
func _make_fake_registry(tex_a: Texture2D, tex_b: Texture2D) -> FakeRegistry:
	var registry: FakeRegistry = FakeRegistry.new()
	registry._definitions[_TYPE_FAKE_A] = FakeDefinition.new("机关甲", _make_scene_with_profile(_make_profile(tex_a)))
	registry._definitions[_TYPE_FAKE_B] = FakeDefinition.new("机关乙", _make_scene_with_profile(_make_profile(tex_b)))
	return registry


## 两类型 metadata 计划（B order 0 在前、A order 1 在后，验证按 entries 顺序建卡）。
func _two_entries() -> Array:
	return [
		{"content_type_id": "fake_type_b", "initial_quantity": 2, "order": 0},
		{"content_type_id": "fake_type_a", "initial_quantity": 3, "order": 1},
	]


## 建独立测试容器（挂 root，视口坐标即全局坐标）+ Presenter；返回 {container, bar, legacy}。
func _make_bar_env() -> Dictionary:
	var container: HBoxContainer = HBoxContainer.new()
	root.add_child(container)
	var legacy: PanelContainer = PanelContainer.new()
	container.add_child(legacy)
	var bar: Variant = _CardBar.new()
	bar.setup(container, legacy)
	return {"container": container, "bar": bar, "legacy": legacy}


func _free_bar_env(env: Dictionary) -> void:
	var container: Control = env["container"]
	if is_instance_valid(container):
		container.free()
	await process_frame


## 取卡视图列表（遍历容器识别 InventoryCardView；Presenter 私有记录不入测试）。
func _cards_in(container: Control) -> Array:
	var cards: Array = []
	for child: Node in container.get_children():
		if child.get_script() == _CardView:
			cards.append(child)
	return cards


## 取卡内图标纹理（IconTexture.texture；不可见时为 null 语义一致）。
func _card_icon(card: Control) -> Texture2D:
	return card.get_node("CardMargin/CardContent/IconStack/IconTexture").texture


func _card_placeholder_visible(card: Control) -> bool:
	return card.get_node("CardMargin/CardContent/IconStack/PlaceholderIcon").visible


func _card_remaining_text(card: Control) -> String:
	return card.get_node("CardMargin/CardContent/CardTexts/RemainingLabel").text


func _card_name_text(card: Control) -> String:
	return card.get_node("CardMargin/CardContent/CardTexts/NameLabel").text


# ===== 用例 =====

## 1. fake 定义两卡：按 entries 顺序生成两卡、名称来自定义、各自数量独立刷新、旧槽位隐藏。
func _test_01_fake_two_cards_order_and_counts() -> void:
	const NAME: String = "01_fake两卡顺序独立数量"
	var tex_a: PlaceholderTexture2D = PlaceholderTexture2D.new()
	var tex_b: PlaceholderTexture2D = PlaceholderTexture2D.new()
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	bar.build_cards(_CardBar.build_card_models(_make_fake_registry(tex_a, tex_b), _two_entries()))
	await process_frame
	var cards: Array = _cards_in(env["container"])
	if not _check(NAME, cards.size() == 2, "应生成两卡，实际 %d。" % [cards.size()]):
		await _free_bar_env(env)
		return
	if not _check(NAME, cards[0].type_id == _TYPE_FAKE_B and cards[1].type_id == _TYPE_FAKE_A,
		"卡顺序应按 entries 展示序（B 在前 A 在后）。"):
		await _free_bar_env(env)
		return
	_check(NAME, _card_name_text(cards[0]) == "机关乙" and _card_name_text(cards[1]) == "机关甲",
		"卡名应来自 fake 定义 display_name。")
	_check(NAME, not env["legacy"].visible, "建卡后旧槽位应隐藏。")
	# 数量独立：B=0、A=2 各自刷新互不影响。
	bar.refresh(
		func(type_id: StringName): return (2 - 2) if type_id == _TYPE_FAKE_B else 2,
		func(type_id: StringName): return type_id == _TYPE_FAKE_A
	)
	_check(NAME, _card_remaining_text(cards[0]) == "剩余：0", "B 卡应显示剩余 0，实际 %s。" % [_card_remaining_text(cards[0])])
	_check(NAME, _card_remaining_text(cards[1]) == "剩余：2", "A 卡应显示剩余 2，实际 %s。" % [_card_remaining_text(cards[1])])
	await _free_bar_env(env)


## 2. 选中 type_id：set/get 往返、未知类型忽略、默认选中首卡。
func _test_02_selection_type_id() -> void:
	const NAME: String = "02_选中type_id"
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	bar.build_cards(_CardBar.build_card_models(_make_fake_registry(PlaceholderTexture2D.new(), PlaceholderTexture2D.new()), _two_entries()))
	await process_frame
	_check(NAME, bar.get_selected_type_id() == _TYPE_FAKE_B, "默认选中应为首卡类型 B。")
	_check(NAME, bar.set_selected_type(_TYPE_FAKE_A), "选中已知类型应返回 true。")
	_check(NAME, bar.get_selected_type_id() == _TYPE_FAKE_A, "选中后应读到 A。")
	_check(NAME, not bar.set_selected_type(&"missing"), "未知类型应忽略并返回 false。")
	_check(NAME, bar.get_selected_type_id() == _TYPE_FAKE_A, "未知类型不得改选中。")
	await _free_bar_env(env)


## 3. 图标契约：同 profile 换 inventory_icon 后 refresh 即取新值（活绑定不缓存）；
##    定义图标源（场景）替换后重新构建取新值。
func _test_03_icon_live_binding_and_rebuild() -> void:
	const NAME: String = "03_图标活绑定重建取新"
	var tex_a: PlaceholderTexture2D = PlaceholderTexture2D.new()
	var tex_b: PlaceholderTexture2D = PlaceholderTexture2D.new()
	var registry: FakeRegistry = _make_fake_registry(tex_a, tex_b)
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	var models: Array[Dictionary] = _CardBar.build_card_models(registry, _two_entries())
	bar.build_cards(models)
	await process_frame
	var cards: Array = _cards_in(env["container"])
	if not _check(NAME, cards.size() == 2, "应生成两卡。"):
		await _free_bar_env(env)
		return
	_check(NAME, _card_icon(cards[1]) == tex_a, "A 卡初始应显示纹理 A。")
	# 活绑定：直接改该卡 profile 的 inventory_icon，refresh 后立即显示新纹理（不重建、不缓存路径）。
	cards[1].visual_profile.inventory_icon = tex_b
	cards[1].refresh(3, true, false)
	_check(NAME, _card_icon(cards[1]) == tex_b, "同 profile 换图标后 refresh 应显示纹理 B。")
	# 源替换语义：definition.scene 换成新图标场景后重新构建，新卡取新值。
	registry._definitions[_TYPE_FAKE_A] = FakeDefinition.new("机关甲", _make_scene_with_profile(_make_profile(tex_b)))
	bar.build_cards(_CardBar.build_card_models(registry, _two_entries()))
	await process_frame
	var rebuilt: Array = _cards_in(env["container"])
	_check(NAME, rebuilt.size() == 2 and _card_icon(rebuilt[1]) == tex_b,
		"图标源替换后重新构建应取新纹理 B。")
	await _free_bar_env(env)


## 4. 缺图 fallback：profile 存在但 inventory_icon 为空 → 占位符可见、数量文本照常、图标隐藏。
func _test_04_missing_icon_fallback() -> void:
	const NAME: String = "04_缺图fallback"
	var registry: FakeRegistry = FakeRegistry.new()
	# profile 无 inventory_icon（合法：固定物件无道具栏图标）。
	registry._definitions[_TYPE_FAKE_A] = FakeDefinition.new("机关甲", _make_scene_with_profile(_make_profile(null)))
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	bar.build_cards(_CardBar.build_card_models(registry, [
		{"content_type_id": "fake_type_a", "initial_quantity": 4, "order": 0},
	]))
	await process_frame
	var cards: Array = _cards_in(env["container"])
	if not _check(NAME, cards.size() == 1, "应生成一卡。"):
		await _free_bar_env(env)
		return
	bar.refresh(func(_t: StringName): return 4, func(_t: StringName): return true)
	_check(NAME, _card_placeholder_visible(cards[0]), "inventory_icon 为空应显示占位符。")
	_check(NAME, _card_icon(cards[0]) == null, "图标纹理应为空。")
	_check(NAME, _card_remaining_text(cards[0]) == "剩余：4", "缺图不影响数量显示。")
	await _free_bar_env(env)


## 5. 正式 definition 真实链（FormalContentDiscovery → Registry → 卡数据）：
##    镜面与加速器场景均含 VisualView + profile 且 profile 设 inventory_icon（存量视觉接入第一批），
##    各得一卡并直接显示真实图标纹理，不再降级占位符。
func _test_05_formal_definitions_real_chain() -> void:
	const NAME: String = "05_正式定义真实链"
	var index: Variant = _RuntimeDefinitionIndex.new()
	var registry: Variant = index.get_registry()
	if not _check(NAME, registry != null, "正式 Registry 构建失败（发现目录不可用）。"):
		return
	var models: Array[Dictionary] = _CardBar.build_card_models(registry, [
		{"content_type_id": "basic_single_cell_mirror", "initial_quantity": 3, "order": 0},
		{"content_type_id": "particle_accelerator", "initial_quantity": 2, "order": 1},
	])
	if not _check(NAME, models.size() == 2, "正式两类型应得两模型，实际 %d。" % [models.size()]):
		return
	_check(NAME, StringName(models[0]["type_id"]) == _TYPE_MIRROR, "首模型应为镜面。")
	_check(NAME, models[0]["display_name"] != String(_TYPE_MIRROR), "镜面显示名应来自正式定义而非 type_id。")
	_check(NAME, models[0]["visual_profile"] != null, "镜面场景应解析出 visual_profile。")
	_check(NAME, models[1]["visual_profile"] != null, "加速器场景应解析出 visual_profile（本批已绑定）。")
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	bar.build_cards(models)
	await process_frame
	var cards: Array = _cards_in(env["container"])
	if _check(NAME, cards.size() == 2, "正式链应建两卡，实际 %d。" % [cards.size()]):
		bar.refresh(
			func(type_id: StringName): return 3 if type_id == _TYPE_MIRROR else 2,
			func(_t: StringName): return true
		)
		_check(NAME, _card_icon(cards[0]) != null, "镜面 profile 的 inventory_icon 应显示真实纹理。")
		_check(NAME, not _card_placeholder_visible(cards[0]), "镜面有图标不应显示占位符。")
		_check(NAME, _card_icon(cards[1]) != null, "加速器 profile 的 inventory_icon 应显示真实纹理。")
		_check(NAME, not _card_placeholder_visible(cards[1]), "加速器有图标不应显示占位符。")
		_check(NAME, _card_remaining_text(cards[0]) == "剩余：3" and _card_remaining_text(cards[1]) == "剩余：2",
			"正式链两卡数量应各自独立显示。")
	await _free_bar_env(env)


## 6. 未知类型安全降级（type_id 作显示名 + null profile）；空计划清除全部卡并恢复旧槽位。
func _test_06_unknown_type_safe_and_empty_plan() -> void:
	const NAME: String = "06_未知类型与空计划"
	var registry: FakeRegistry = FakeRegistry.new()
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	var models: Array[Dictionary] = _CardBar.build_card_models(registry, [
		{"content_type_id": "fake_type_a", "initial_quantity": 3, "order": 0},
		{"content_type_id": "missing_type", "initial_quantity": 1, "order": 1},
	])
	_check(NAME, models.size() == 2, "未知类型不建第二 schema，照常产模型。")
	_check(NAME, models[1]["display_name"] == "missing_type", "未知类型显示名应为 type_id。")
	_check(NAME, models[1]["visual_profile"] == null, "未知类型 profile 应为 null。")
	_check(NAME, int(models[1]["quantity"]) == 1, "未知类型数量照常携带。")
	bar.build_cards(models)
	await process_frame
	_check(NAME, bar.get_card_count() == 2, "未知类型卡应照常生成（安全降级不剔除）。")
	_check(NAME, _card_name_text(_cards_in(env["container"])[1]) == "missing_type", "未知类型卡名应为 type_id。")
	# 空计划：清卡、恢复旧槽位、清空选中。
	bar.build_cards([])
	await process_frame
	_check(NAME, bar.get_card_count() == 0, "空计划应清除全部卡。")
	_check(NAME, env["legacy"].visible, "空计划应恢复旧槽位可见。")
	_check(NAME, bar.get_selected_type_id() == &"", "空计划应清空选中。")
	await _free_bar_env(env)


## 7. 指针命中：泵帧布局后按视口坐标命中对应卡；空白处返回空。
func _test_07_hit_test_after_layout() -> void:
	const NAME: String = "07_指针命中"
	var env: Dictionary = _make_bar_env()
	var bar: Variant = env["bar"]
	bar.build_cards(_CardBar.build_card_models(_make_fake_registry(PlaceholderTexture2D.new(), PlaceholderTexture2D.new()), _two_entries()))
	await process_frame
	var cards: Array = _cards_in(env["container"])
	if not _check(NAME, cards.size() == 2, "应生成两卡。"):
		await _free_bar_env(env)
		return
	var rect_b: Rect2 = cards[0].get_global_rect()
	var rect_a: Rect2 = cards[1].get_global_rect()
	_check(NAME, rect_b.has_point(rect_b.get_center()) and bar.get_card_type_id_at(rect_b.get_center()) == _TYPE_FAKE_B,
		"B 卡中心应命中 B 类型。")
	_check(NAME, bar.get_card_type_id_at(rect_a.get_center()) == _TYPE_FAKE_A, "A 卡中心应命中 A 类型。")
	_check(NAME, rect_b.size.x > 1.0 and rect_b.size.y > 1.0, "布局后卡应有实际尺寸，实际 %s。" % [str(rect_b.size)])
	_check(NAME, bar.get_card_type_id_at(rect_b.position + Vector2(-8, -8)) == &"",
		"卡外空白应返回空类型。")
	await _free_bar_env(env)


# ===== 断言与报告 =====

func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== 道具卡Presenter定向测试摘要 ====")
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
