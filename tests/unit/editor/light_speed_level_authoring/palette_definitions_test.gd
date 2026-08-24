extends SceneTree

# AF-08 Content Palette 服务 + 正式内容声明 .tres 合同测试。
# 覆盖：真实定义目录发现（5 类型、全合法、token 唯一）、Registry 构建、Palette 条目生成、
#       放置（首格合法、稳定 ID 分配、RuntimeObjects 容器、owner 落保存链）、
#       连续放置占用递进、未声明类型拒绝、直发/延迟两种放置模式。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _FormalContentDiscovery: GDScript = preload(
	"res://gameplay/content/formal_content_discovery.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_definitions_discovered()
	_test_02_palette_entries()
	_test_03_place_and_occupancy()
	_test_04_unknown_type_rejected()
	_test_05_deferred_mode()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _test_01_definitions_discovered() -> void:
	const NAME: String = "01_真实声明发现"
	var result: Dictionary = _FormalContentDiscovery.discover()
	_check(NAME, result.ok, "定义目录应全合法：%s" % ", ".join(result.errors))
	_check(NAME, result.definitions.size() >= 5, "应有 ≥5 个正式定义（镜/加速/减速/水晶/发射器），实际 %d。" % result.definitions.size())
	var type_ids: Array[StringName] = []
	for definition: Variant in result.definitions:
		type_ids.append(definition.content_type_id)
	for expected: StringName in [&"basic_single_cell_mirror", &"particle_accelerator", &"particle_decelerator", &"basic_crystal", &"main_emitter"]:
		_check(NAME, type_ids.has(expected), "应包含正式类型 %s。" % expected)


func _test_02_palette_entries() -> void:
	const NAME: String = "02_Palette条目"
	var registry: RefCounted = _PaletteService.build_registry()
	_check(NAME, registry != null, "Registry 应构建成功。")
	var entries: Array[Dictionary] = _PaletteService.build_palette_entries(registry)
	_check(NAME, entries.size() == registry.get_type_count(), "全部定义默认可预放置，条目数应=登记数（%d/%d）。" % [
		entries.size(), registry.get_type_count()])
	var has_mirror := false
	for entry: Dictionary in entries:
		if entry.type_id == &"basic_single_cell_mirror":
			has_mirror = true
			_check(NAME, entry.display_name == "基础单格镜" and entry.category == &"optics",
				"镜面条目应消费声明元数据。")
	_check(NAME, has_mirror, "Palette 应含镜面。")


func _test_03_place_and_occupancy() -> void:
	const NAME: String = "03_放置与占用递进"
	var root := _LevelRay001.instantiate() as Node2D
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var first: Dictionary = service.place(registry, &"basic_single_cell_mirror", root)
	_check(NAME, first.ok, "镜面应放置成功：%s" % first.reason)
	_check(NAME, str(first.stable_instance_id).begins_with("fci_"), "应立即分配稳定 ID。")
	var mirror: Node2D = first.node
	_check(NAME, mirror.get_parent() == root.get_node("RuntimeObjects"), "应进入 RuntimeObjects 正式容器。")
	_check(NAME, mirror.owner == root, "应设置 owner（保存链事实）。")
	_check(NAME, mirror.position == Vector2(32, 32), "首格应为行主序首个合法空格 (0,0) 中心 (32,32)，实际 %s。" % str(mirror.position))
	var second: Dictionary = service.place(registry, &"basic_single_cell_mirror", root)
	_check(NAME, second.ok and second.cell == Vector2i(1, 0),
		"第二面镜应跳过已占用格到 (1,0)，实际 %s。" % str(second.cell))
	root.free()


func _test_04_unknown_type_rejected() -> void:
	const NAME: String = "04_未声明类型拒绝"
	var root := _LevelRay001.instantiate() as Node2D
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var result: Dictionary = service.place(registry, &"no_such_type", root)
	_check(NAME, not result.ok and result.node == null, "未声明类型应拒绝且零节点残留。")
	root.free()


func _test_05_deferred_mode() -> void:
	const NAME: String = "05_延迟入树模式"
	var root := _LevelRay001.instantiate() as Node2D
	var registry: RefCounted = _PaletteService.build_registry()
	var service: RefCounted = _PaletteService.new()
	var result: Dictionary = service.place(registry, &"particle_accelerator", root, false)
	_check(NAME, result.ok, "延迟模式应构建成功：%s" % result.reason)
	_check(NAME, result.node != null and result.node.get_parent() == null, "延迟模式节点不应入树。")
	_check(NAME, result.container == root.get_node("RuntimeObjects"), "应返回目标容器供事务登记。")
	result.container.add_child(result.node)
	_check(NAME, result.node.get_parent() != null, "调用方 add_child 后应正常入树（事务 do 段路径）。")
	root.free()


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("palette_definitions_test: %d checks, %d failures" % [_checks, _failures.size()])
