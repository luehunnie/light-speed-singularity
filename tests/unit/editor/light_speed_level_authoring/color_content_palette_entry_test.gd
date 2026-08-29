extends SceneTree

# 阶段B 第二次 GUI Gate 修复合同测试：单一正式项"光颜色水晶"（color_crystal）经
# FormalContentDiscovery → Registry → Content Palette 条目 → place() 放置 → 颜色字段
# （默认红 / cycle 改色 / 越界拒绝）→ 类型解析不与基础水晶归并 → PackedScene 保存重载
# 颜色事实不丢。运行期就绪事实（BasicCrystal 复用 / LightFilter 契约面）一并断言。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _FormalContentDiscovery: GDScript = preload(
	"res://gameplay/content/formal_content_discovery.gd"
)
const _BusinessData: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/business_data/business_data_service.gd"
)
const _RayColor: GDScript = preload(
	"res://gameplay/light/ray_color.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)
const _ColorCrystalScript: GDScript = preload(
	"res://gameplay/crystals/color_crystal.gd"
)
const _BasicCrystalScript: GDScript = preload(
	"res://gameplay/crystals/basic_crystal.gd"
)
const _LightFilterScript: GDScript = preload(
	"res://gameplay/mechanisms/filters/light_filter.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_definitions_discovered()
	_test_02_palette_entries()
	_test_03_color_crystal_place_chain()
	_test_04_color_field_contract()
	_test_05_save_reload_roundtrip()
	_test_06_filter_place_chain()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _test_01_definitions_discovered() -> void:
	const NAME: String = "01_单一项声明发现"
	var result: Dictionary = _FormalContentDiscovery.discover()
	_check(NAME, result.ok, "定义目录应全合法：%s" % ", ".join(result.errors))
	var by_type: Dictionary = {}
	for definition: Variant in result.definitions:
		by_type[definition.content_type_id] = definition
	_check(NAME, by_type.has(&"color_crystal"), "应发现光颜色水晶声明 color_crystal。")
	if by_type.has(&"color_crystal"):
		var crystal_definition: Variant = by_type[&"color_crystal"]
		_check(NAME, crystal_definition.display_name == "光颜色水晶",
			"color_crystal 显示名应为 光颜色水晶，实际 %s。" % crystal_definition.display_name)
		_check(NAME, crystal_definition.scene != null and crystal_definition.preplaceable,
			"color_crystal 应带场景且可预放置。")
		_check(NAME, crystal_definition.get_content_domain() == &"objective_target",
			"color_crystal 应属目标域。")
	for removed_type: StringName in [&"red_crystal", &"green_crystal", &"blue_crystal"]:
		_check(NAME, not by_type.has(removed_type),
			"旧三色独立声明 %s 应已移除（单一正式项取代）。" % removed_type)
	_check(NAME, by_type.has(&"light_filter"), "应发现滤光片声明 light_filter。")
	if by_type.has(&"light_filter"):
		var filter_definition: Variant = by_type[&"light_filter"]
		_check(NAME, filter_definition.scene != null and filter_definition.preplaceable,
			"light_filter 应带场景且可预放置。")
		_check(NAME, filter_definition.get_content_domain() == &"mechanism",
			"light_filter 应属机关域。")
		var forms: Array[StringName] = filter_definition.light_interaction_forms
		_check(NAME, forms.has(&"RAY") and forms.has(&"PARTICLE"),
			"light_filter 声明应镜像节点契约面 RAY+PARTICLE，实际 %s。" % str(forms))


func _test_02_palette_entries() -> void:
	const NAME: String = "02_Palette条目"
	var registry: RefCounted = _PaletteService.build_registry()
	_check(NAME, registry != null, "Registry 应构建成功。")
	var entries: Array[Dictionary] = _PaletteService.build_palette_entries(registry)
	var expected_names: Dictionary = {
		&"color_crystal": "光颜色水晶",
		&"basic_crystal": "基础水晶",
		&"light_filter": "滤光片",
	}
	for type_id: StringName in expected_names:
		var found := false
		for entry: Dictionary in entries:
			if entry.type_id == type_id:
				found = true
				_check(NAME, entry.display_name == expected_names[type_id],
					"%s 条目显示名应为 %s，实际 %s。" % [type_id, expected_names[type_id], entry.display_name])
		_check(NAME, found, "Content Palette 应含 %s 放置入口。" % type_id)
	# Inventory 类型下拉（服务层同源事实）：光颜色水晶与滤光片必须可选。
	var inventory_options: Array[Dictionary] = _BusinessData.get_inventory_eligible_types(registry)
	var option_ids: Array[StringName] = []
	for option: Dictionary in inventory_options:
		option_ids.append(option.type_id)
	_check(NAME, option_ids.has(&"color_crystal"), "Inventory 类型下拉应含光颜色水晶，实际 %s。" % str(option_ids))
	_check(NAME, option_ids.has(&"light_filter"), "Inventory 类型下拉应含滤光片，实际 %s。" % str(option_ids))
	for legacy_type: StringName in [&"basic_crystal", &"main_emitter"]:
		_check(NAME, not option_ids.has(legacy_type), "%s 未声明入库资格，不应进下拉。" % legacy_type)
	# 库存条目校验：两类型各一条应通过（保存链前置）。
	var problems: PackedStringArray = _BusinessData.validate_inventory([
		{"content_type_id": "color_crystal", "initial_quantity": 1, "order": 0},
		{"content_type_id": "light_filter", "initial_quantity": 2, "order": 1},
	], registry)
	_check(NAME, problems.is_empty(), "光颜色水晶/滤光片库存条目应校验通过：%s" % "；".join(problems))


func _test_03_color_crystal_place_chain() -> void:
	const NAME: String = "03_光颜色水晶放置链"
	var root := _LevelRay001.instantiate() as Node2D
	get_root().add_child(root)
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var result: Dictionary = service.place(registry, &"color_crystal", root)
	_check(NAME, result.ok, "color_crystal 应放置成功：%s" % result.reason)
	if result.ok:
		var node: Node2D = result.node
		_check(NAME, node.get_script() == _ColorCrystalScript,
			"color_crystal 场景根应为 color_crystal.gd。")
		_check(NAME, node.get_script().get_base_script() == _BasicCrystalScript,
			"ColorCrystal 应直接继承 BasicCrystal（运行期复用既有水晶链）。")
		_check(NAME, node.get_parent() == root.get_node("RuntimeObjects") and node.owner == root,
			"光颜色水晶应入 RuntimeObjects 并设 owner（保存链事实）。")
		_check(NAME, node.cell == Vector2i(0, 0),
			"光颜色水晶应落在行主序空格 (0,0)，实际 %s。" % str(node.cell))
		var stable_id: String = str(node.get("stable_instance_id"))
		var crystal_id: StringName = node.get("crystal_id")
		_check(NAME, stable_id.begins_with("fci_") and String(crystal_id) == stable_id,
			"稳定 ID 与 crystal_id 应同源非空（%s / %s）。" % [stable_id, String(crystal_id)])
		_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.RED,
			"放置后默认颜色应为红（RED），实际 %s。" % str(node.get("crystal_color")))
		# 类型解析回归：独立根脚本不得归并到基础水晶（上一批三场景共用脚本的根因回归）。
		var resolved: StringName = _BusinessData.resolve_content_type_id(node, registry)
		_check(NAME, resolved == &"color_crystal",
			"光颜色水晶应解析为 color_crystal 类型，实际 %s。" % resolved)
		# 基础水晶互不串扰。
		var basic_result: Dictionary = service.place(registry, &"basic_crystal", root)
		_check(NAME, basic_result.ok, "basic_crystal 应放置成功：%s" % basic_result.reason)
		if basic_result.ok:
			_check(NAME, _BusinessData.resolve_content_type_id(basic_result.node, registry) == &"basic_crystal",
				"基础水晶应解析为 basic_crystal 类型。")
			_check(NAME, basic_result.node.get("crystal_color") == null,
				"基础水晶不应携带颜色字段。")
			basic_result.node.free()
		node.free()
	root.free()


func _test_04_color_field_contract() -> void:
	const NAME: String = "04_颜色字段合同"
	var node: Node2D = _ColorCrystalScript.new()
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.RED,
		"新实例默认颜色应为红。")
	_check(NAME, node.call("get_crystal_color") == _RayColor.ColorValue.RED,
		"get_crystal_color 应返回默认红。")
	node.call("cycle_color")
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.GREEN,
		"cycle 一次应为绿，实际 %s。" % str(node.get("crystal_color")))
	node.call("cycle_color")
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.BLUE,
		"cycle 两次应为蓝，实际 %s。" % str(node.get("crystal_color")))
	node.call("cycle_color")
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.RED,
		"cycle 三次应回绕为红，实际 %s。" % str(node.get("crystal_color")))
	node.set("crystal_color", _RayColor.ColorValue.WHITE)
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.RED,
		"越界颜色 WHITE 应被拒绝并保持原值。")
	node.set("crystal_color", _RayColor.ColorValue.GREEN)
	_check(NAME, node.get("crystal_color") == _RayColor.ColorValue.GREEN,
		"合法颜色应可写入。")
	node.free()


func _test_05_save_reload_roundtrip() -> void:
	const NAME: String = "05_保存重载"
	var root := _LevelRay001.instantiate() as Node2D
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var result: Dictionary = service.place(registry, &"color_crystal", root)
	if not _check(NAME, result.ok, "保存链放置应成功：%s" % result.reason):
		root.free()
		return
	var placed: Node2D = result.node
	placed.set("crystal_color", _RayColor.ColorValue.BLUE)
	var saved_id: String = str(placed.get("stable_instance_id"))
	var saved_cell: Vector2i = placed.cell
	var packed := PackedScene.new()
	packed.pack(root)
	var reloaded_root := packed.instantiate() as Node2D
	var reloaded: Node = _find_color_crystal(reloaded_root)
	_check(NAME, reloaded != null, "重载后应存在光颜色水晶节点。")
	if reloaded != null:
		_check(NAME, reloaded.get("crystal_color") == _RayColor.ColorValue.BLUE,
			"重载后颜色应保持蓝，实际 %s。" % str(reloaded.get("crystal_color")))
		_check(NAME, str(reloaded.get("stable_instance_id")) == saved_id,
			"重载后稳定 ID 应保持 %s。" % saved_id)
		_check(NAME, String(reloaded.get("crystal_id")) == saved_id,
			"重载后 crystal_id 应与稳定 ID 同源。")
		_check(NAME, (reloaded as Node2D).cell == saved_cell,
			"重载后格子应保持 %s。" % str(saved_cell))
	reloaded_root.free()
	root.free()


func _find_color_crystal(scene_root: Node) -> Node:
	if scene_root.get_script() == _ColorCrystalScript:
		return scene_root
	for child in scene_root.get_children():
		var found: Node = _find_color_crystal(child)
		if found != null:
			return found
	return null


func _test_06_filter_place_chain() -> void:
	const NAME: String = "06_滤光片放置链"
	var root := _LevelRay001.instantiate() as Node2D
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var result: Dictionary = service.place(registry, &"light_filter", root)
	_check(NAME, result.ok, "滤光片应放置成功：%s" % result.reason)
	if result.ok:
		var node: Node2D = result.node
		_check(NAME, node.get_script() == _LightFilterScript,
			"滤光片场景根应为 light_filter.gd。")
		_check(NAME, node.get_parent() == root.get_node("RuntimeObjects") and node.owner == root,
			"滤光片应入 RuntimeObjects 并设 owner（保存链事实）。")
		_check(NAME, str(node.get("stable_instance_id")).begins_with("fci_"),
			"滤光片应立即分配稳定 ID。")
		_check(NAME, node.get("mechanism_id") == &"",
			"滤光片放置后 mechanism_id 应为空（PreplacedMechanismAdopter 收编前提）。")
		var forms: Array = node.get_light_interaction_forms()
		_check(NAME, forms.has(&"RAY") and forms.has(&"PARTICLE") and node.has_method("interact_ray"),
			"滤光片正式 API 契约面应可直接调用（forms=%s）。" % str(forms))
	root.free()


func _check(group: String, condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])
	return condition


func _report() -> void:
	print("color_content_palette_entry_test: %d checks, %d failures" % [_checks, _failures.size()])
