extends SceneTree

## LevelData 资源契约与 LevelDataCapture 提取器定向测试（D7-R2）。
## 覆盖：默认构造、validate 全部校验域（四层/固定对象/枚举/level_id）、unavailable level_id 政策、
##   WARNING 级规则不在数据校验域、.tres 保存/加载 round-trip、Resource.duplicate(true) 深拷贝独立性、
##   内存 fixture 捕获字段全对齐、捕获 null 失败路径、捕获只读与两次一致、真实编辑示例场景捕获、
##   schema 演化 additive-only 证明（旧式 .tres 缺失导出属性回落脚本默认值且 validate 确定性）。
## fixture：程序化最小 TileSet + 未入树 TileMapLayer 组装关卡根（与 level_validator_layers_test 同口径）。
## 约束：不修改场景/资源；round-trip 临时文件写 user:// 并在用例内清理；实例受控 free。
## headless extends SceneTree，由 Godot --script 运行；preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）。

const _LevelData: GDScript = preload("res://gameplay/level/data/level_data.gd")
const _LevelDataCapture: GDScript = preload("res://gameplay/level/data/level_data_capture.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")

const _EDITING_EXAMPLE_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
const _ROUNDTRIP_PATH: String = "user://d7r2_level_data_roundtrip_test.tres"
const _OLD_TRES_PARTIAL_PATH: String = "user://d7r2_level_data_old_partial.tres"
const _OLD_TRES_VALID_PATH: String = "user://d7r2_level_data_old_valid.tres"
const _GROUP_COUNT: int = 17

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 15 组后统一报告并退出。
func _initialize() -> void:
	_test_01_default_and_empty_terrain()
	_test_02_fully_valid()
	_test_03_layer_rules()
	_test_04_emitter_position_rules()
	_test_05_crystal_rules()
	_test_06_overlap()
	_test_07_enum_domains()
	_test_08_level_id_policy()
	_test_09_warning_rules_out_of_scope()
	_test_10_roundtrip_save_load()
	_test_11_duplicate_deep_copy()
	_test_12_capture_valid_fixture()
	_test_13_capture_null_paths()
	_test_14_capture_readonly_consistent()
	_test_15_capture_real_scene()
	_test_16_old_tres_missing_properties_defaults()
	_test_17_old_tres_minimal_valid()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 用例 =====

## 1. 默认构造：字段默认值明确；空 Terrain + 空 crystal_id 下 validate 报告对应问题。
func _test_01_default_and_empty_terrain() -> void:
	const G: String = "01_默认构造"
	var data: _LevelData = _LevelData.new()
	_check(G, data.level_id == &"", "默认 level_id 应为空（unavailable 政策）。")
	_check(G, data.terrain_cells.is_empty() and data.wall_cells.is_empty() and data.legal_area_cells.is_empty(), "默认三层格应为空数组。")
	_check(G, data.emitter_form == 0 and data.emitter_ray_direction == 0 and data.emitter_particle_direction == 0, "默认枚举应为 0。")
	_check(G, data.emitter_allow_form_switch == false, "默认 allow_form_switch 应为 false。")
	_check(G, data.crystal_id == &"", "默认 crystal_id 应为空。")
	var problems: PackedStringArray = data.validate()
	_check(G, _has(problems, "terrain_cells 为空"), "默认数据应报 terrain 空。")
	_check(G, _has(problems, "crystal_id 为空"), "默认数据应报 crystal_id 空。")
	_check(G, _has(problems, "emitter_cell") and _has(problems, "位于 Terrain 之外"), "默认数据应报 emitter 越界 Terrain。")


## 2. 完全合法数据：validate 返回空。
func _test_02_fully_valid() -> void:
	const G: String = "02_完全合法"
	var data: _LevelData = _valid_data()
	var problems: PackedStringArray = data.validate()
	_check(G, problems.is_empty(), "完全合法数据 validate 应为空，实际：%s。" % ", ".join(problems))


## 3. 四层规则：wall/legal 越界 Terrain 各报一条且带格上下文。
func _test_03_layer_rules() -> void:
	const G: String = "03_四层规则"
	var data: _LevelData = _valid_data()
	data.wall_cells.append(Vector2i(5, 0))
	var problems: PackedStringArray = data.validate()
	_check(G, problems.size() == 1, "wall 越界应恰报 1 条，实际 %d。" % problems.size())
	_check(G, _has(problems, "(5, 0)"), "wall 越界信息应带格上下文。")
	data = _valid_data()
	data.legal_area_cells.append(Vector2i(0, 5))
	problems = data.validate()
	_check(G, problems.size() == 1 and _has(problems, "legal_area_cells"), "legal 越界应恰报 1 条。" )


## 4. 发射器位置：越界 Terrain / 位于 Wall。
func _test_04_emitter_position_rules() -> void:
	const G: String = "04_发射器位置"
	var data: _LevelData = _valid_data()
	data.emitter_cell = Vector2i(9, 9)
	var problems: PackedStringArray = data.validate()
	_check(G, _has(problems, "emitter_cell (9, 9) 位于 Terrain 之外"), "应报 emitter 越界。")
	data = _valid_data()
	data.wall_cells.append(Vector2i(1, 0))
	data.emitter_cell = Vector2i(1, 0)
	problems = data.validate()
	_check(G, _has(problems, "emitter_cell (1, 0) 位于 Wall"), "应报 emitter 位于 Wall。")


## 5. 水晶：ID 空 / 越界 / 位于 Wall。
func _test_05_crystal_rules() -> void:
	const G: String = "05_水晶规则"
	var data: _LevelData = _valid_data()
	data.crystal_id = &""
	_check(G, _has(data.validate(), "crystal_id 为空"), "应报 crystal_id 空。")
	data = _valid_data()
	data.crystal_cell = Vector2i(9, 9)
	_check(G, _has(data.validate(), "crystal_cell (9, 9) 位于 Terrain 之外"), "应报 crystal 越界。")
	data = _valid_data()
	data.wall_cells.append(Vector2i(2, 0))
	data.crystal_cell = Vector2i(2, 0)
	_check(G, _has(data.validate(), "crystal_cell (2, 0) 位于 Wall"), "应报 crystal 位于 Wall。")


## 6. 发射器与水晶同格重叠。
func _test_06_overlap() -> void:
	const G: String = "06_同格重叠"
	var data: _LevelData = _valid_data()
	data.crystal_cell = data.emitter_cell
	_check(G, _has(data.validate(), "占同一格"), "应报同格重叠。")


## 7. 枚举域：form / ray / particle 非法值各报一条。
func _test_07_enum_domains() -> void:
	const G: String = "07_枚举域"
	var data: _LevelData = _valid_data()
	data.emitter_form = 7
	data.emitter_ray_direction = 99
	data.emitter_particle_direction = 99
	var problems: PackedStringArray = data.validate()
	_check(G, _count_start(problems, "emitter_form") == 1, "应报 emitter_form 非法。")
	_check(G, _count_start(problems, "emitter_ray_direction") == 1, "应报 emitter_ray_direction 非法。")
	_check(G, _count_start(problems, "emitter_particle_direction") == 1, "应报 emitter_particle_direction 非法。")


## 8. level_id 政策：空合法；非空且干净合法；非空含空白报一条。
func _test_08_level_id_policy() -> void:
	const G: String = "08_level_id政策"
	var data: _LevelData = _valid_data()
	data.level_id = &"level_001"
	_check(G, data.validate().is_empty(), "非空干净 level_id 应合法。")
	data.level_id = &"level 001"
	var problems: PackedStringArray = data.validate()
	_check(G, problems.size() == 1 and _has(problems, "level_id"), "含空白 level_id 应恰报 1 条。")


## 9. WARNING 级规则（legal_area_empty / legal_wall_overlap）不在数据校验域：legal 在 Wall 上不报、legal 空不报。
func _test_09_warning_rules_out_of_scope() -> void:
	const G: String = "09_WARNING域外"
	var data: _LevelData = _valid_data()
	data.legal_area_cells = [Vector2i(1, 1)]
	var problems: PackedStringArray = data.validate()
	_check(G, problems.is_empty(), "legal 空 / legal 与 Wall 重叠属场景 WARNING 域，数据 validate 不应报告，实际：%s。" % ", ".join(problems))


## 10. .tres 保存/加载 round-trip：全部字段逐项相等，validate 结果一致；临时文件清理。
func _test_10_roundtrip_save_load() -> void:
	const G: String = "10_roundtrip"
	var data: _LevelData = _valid_data()
	data.level_id = &"level_roundtrip"
	data.emitter_form = 1
	data.emitter_allow_form_switch = true
	data.emitter_ray_direction = 3
	data.emitter_particle_direction = 4
	var save_err: int = ResourceSaver.save(data, _ROUNDTRIP_PATH)
	_check(G, save_err == OK, "ResourceSaver.save 应返回 OK，实际 %d。" % save_err)
	var loaded: Resource = ResourceLoader.load(_ROUNDTRIP_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(G, loaded != null and is_instance_of(loaded, _LevelData), "加载结果应为 LevelData 实例。")
	var back: _LevelData = loaded
	_check(G, back.level_id == &"level_roundtrip", "round-trip level_id 应相等。")
	_check(G, back.terrain_cells == data.terrain_cells and back.wall_cells == data.wall_cells and back.legal_area_cells == data.legal_area_cells, "round-trip 三层格应相等。")
	_check(G, back.emitter_cell == data.emitter_cell and back.crystal_cell == data.crystal_cell, "round-trip 固定对象格应相等。")
	_check(G, back.emitter_form == 1 and back.emitter_allow_form_switch == true and back.emitter_ray_direction == 3 and back.emitter_particle_direction == 4, "round-trip 发射器配置应相等。")
	_check(G, back.crystal_id == data.crystal_id, "round-trip crystal_id 应相等。")
	_check(G, back.validate().is_empty(), "round-trip 后 validate 仍应为空。")
	var rm_err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(_ROUNDTRIP_PATH))
	_check(G, rm_err == OK, "round-trip 临时文件应清理成功，实际 %d。" % rm_err)


## 11. Resource.duplicate(true) 深拷贝：修改副本数组不影响原资源。
func _test_11_duplicate_deep_copy() -> void:
	const G: String = "11_深拷贝"
	var data: _LevelData = _valid_data()
	var copy: _LevelData = data.duplicate(true)
	_check(G, copy != data and copy.terrain_cells == data.terrain_cells, "深拷贝内容应相等且非同实例。")
	copy.terrain_cells.append(Vector2i(7, 7))
	copy.level_id = &"changed"
	_check(G, not data.terrain_cells.has(Vector2i(7, 7)), "修改副本数组不应影响原资源。")
	_check(G, data.level_id == &"", "修改副本标量不应影响原资源。")


## 12. 捕获合法内存 fixture：全部字段与场景配置对齐，level_id 保持空。
func _test_12_capture_valid_fixture() -> void:
	const G: String = "12_捕获合法"
	var root: Node2D = _make_root()
	var data: _LevelData = _LevelDataCapture.capture(root)
	_check(G, data != null, "合法根捕获应成功。")
	if data == null:
		root.free()
		return
	_check(G, data.level_id == &"", "捕获 level_id 应保持空（unavailable 政策）。")
	_check(G, data.terrain_cells == _cells_3x3(), "捕获 terrain 应等于 3×3 fixture。")
	_check(G, data.wall_cells == [Vector2i(1, 1)], "捕获 wall 应等于 fixture。")
	_check(G, data.legal_area_cells == [Vector2i(0, 0)], "捕获 legal 应等于 fixture。")
	_check(G, data.emitter_cell == Vector2i(0, 0), "捕获 emitter_cell 应为 (0,0)。")
	_check(G, data.emitter_form == _EmitterConfigNode.LightForm.PARTICLE, "捕获形态应为 PARTICLE。")
	_check(G, data.emitter_allow_form_switch == true, "捕获 allow_form_switch 应为 true。")
	_check(G, data.emitter_ray_direction == _EmitterConfigNode.RayDirection.LEFT, "捕获 ray 方向应为 LEFT。")
	_check(G, data.emitter_particle_direction == _EmitterConfigNode.ParticleDirection.UP_LEFT, "捕获 particle 方向应为 UP_LEFT。")
	_check(G, data.crystal_cell == Vector2i(2, 0) and data.crystal_id == &"crystal_d7r2", "捕获水晶事实应对齐。")
	_check(G, data.validate().is_empty(), "捕获结果 validate 应为空，实际：%s。" % ", ".join(data.validate()))
	root.free()


## 13. 捕获失败路径：根非法 / 缺层 / 发射器 0 与 2 / 水晶 2 / 非有限 position → null。
func _test_13_capture_null_paths() -> void:
	const G: String = "13_捕获失败"
	_check(G, _LevelDataCapture.capture(null) == null, "null 根应返回 null。")
	var plain: Node = Node.new()
	_check(G, _LevelDataCapture.capture(plain) == null, "非 Node2D 根应返回 null。")
	plain.free()
	var root: Node2D = _make_root()
	var terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(terrain)
	terrain.free()
	_check(G, _LevelDataCapture.capture(root) == null, "缺 TerrainLayer 应返回 null。")
	root.free()
	var no_emitter: Node2D = _make_root()
	no_emitter.get_node("RuntimeObjects/Emitter").free()
	_check(G, _LevelDataCapture.capture(no_emitter) == null, "发射器数量 0 应返回 null。")
	no_emitter.free()
	var two_emitter: Node2D = _make_root()
	var extra_e: _EmitterConfigNode = _EmitterConfigNode.new()
	extra_e.name = &"Emitter2"
	two_emitter.get_node("RuntimeObjects").add_child(extra_e)
	_check(G, _LevelDataCapture.capture(two_emitter) == null, "发射器数量 2 应返回 null。")
	two_emitter.free()
	var two_crystal: Node2D = _make_root()
	var extra_c: _BasicCrystal = _BasicCrystal.new()
	extra_c.name = &"BasicCrystal2"
	two_crystal.get_node("RuntimeObjects").add_child(extra_c)
	_check(G, _LevelDataCapture.capture(two_crystal) == null, "水晶数量 2 应返回 null。")
	two_crystal.free()
	var bad_pos: Node2D = _make_root()
	(bad_pos.get_node("RuntimeObjects/Emitter") as Node2D).position = Vector2(NAN, 0.0)
	_check(G, _LevelDataCapture.capture(bad_pos) == null, "非有限 emitter position 应返回 null。")
	bad_pos.free()


## 14. 捕获只读 + 两次一致：捕获前后发射器/水晶 position 与格集合不变。
func _test_14_capture_readonly_consistent() -> void:
	const G: String = "14_捕获只读"
	var root: Node2D = _make_root()
	var emitter: Node2D = root.get_node("RuntimeObjects/Emitter")
	var crystal: Node2D = root.get_node("RuntimeObjects/BasicCrystal")
	var e_pos: Vector2 = emitter.position
	var c_pos: Vector2 = crystal.position
	var cells_before: Array = root.get_node("TerrainLayer").get_used_cells()
	var first: _LevelData = _LevelDataCapture.capture(root)
	var second: _LevelData = _LevelDataCapture.capture(root)
	_check(G, first != null and second != null, "两次捕获均应成功。")
	_check(G, emitter.position == e_pos and crystal.position == c_pos, "捕获不应改固定对象 position。")
	_check(G, root.get_node("TerrainLayer").get_used_cells() == cells_before, "捕获不应改层格子。")
	_check(G, first.terrain_cells == second.terrain_cells and first.wall_cells == second.wall_cells and first.legal_area_cells == second.legal_area_cells, "两次捕获三层格应一致。")
	_check(G, first.emitter_cell == second.emitter_cell and first.crystal_cell == second.crystal_cell and first.crystal_id == second.crystal_id, "两次捕获固定对象应一致。")
	root.free()


## 15. 真实编辑示例场景捕获：非 null、validate 为空、level_id 空、terrain 非空、实例不入树受控 free。
func _test_15_capture_real_scene() -> void:
	const G: String = "15_真实场景"
	var packed: PackedScene = load(_EDITING_EXAMPLE_PATH)
	_check(G, packed != null, "编辑示例场景应可加载。")
	var root: Node2D = packed.instantiate()
	var data: _LevelData = _LevelDataCapture.capture(root)
	_check(G, data != null, "真实场景捕获应成功。")
	if data != null:
		_check(G, data.validate().is_empty(), "真实场景捕获 validate 应为空，实际：%s。" % ", ".join(data.validate()))
		_check(G, data.level_id == &"", "真实场景捕获 level_id 应保持空。")
		_check(G, not data.terrain_cells.is_empty(), "真实场景 terrain 应非空。")
	root.free()


# ===== schema 演化（additive-only） =====

## 16. 旧式 .tres（假设未来新增字段后回看的旧文件：缺少 wall/legal/emitter 部分导出属性与 crystal_id）
## 手工构造仅含部分属性的 .tres 并加载：缺失属性回落脚本默认值（空数组 / 0 / false / 空 StringName），
## 已存在属性按文件加载；validate 确定性报告 crystal_id 空，不崩溃、不静默造值。
## 同时证明 ResourceSaver 原生按属性名序列化且缺省属性不写盘——additive-only 是 Godot 原生行为。
func _test_16_old_tres_missing_properties_defaults() -> void:
	const G: String = "16_旧tres缺省回落"
	var text: String = _old_tres_text(&"old_partial", [
		"level_id = &\"old_level\"",
		"terrain_cells = Array[Vector2i]([Vector2i(0, 0), Vector2i(1, 0)])",
		"crystal_cell = Vector2i(1, 0)",
	])
	var write_ok: bool = _write_user_file(_OLD_TRES_PARTIAL_PATH, text)
	_check(G, write_ok, "旧式 .tres 应写入成功。")
	var loaded: Resource = ResourceLoader.load(_OLD_TRES_PARTIAL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(G, loaded != null and is_instance_of(loaded, _LevelData), "旧式 .tres 应加载为 LevelData。")
	var back: _LevelData = loaded
	# 缺失属性 → 脚本默认值。
	_check(G, back.wall_cells.is_empty() and back.legal_area_cells.is_empty(), "缺失 wall/legal 属性应回落空数组默认值。")
	_check(G, back.emitter_form == 0 and back.emitter_ray_direction == 0 and back.emitter_particle_direction == 0, "缺失枚举属性应回落 0 默认值。")
	_check(G, back.emitter_allow_form_switch == false, "缺失 allow_form_switch 应回落 false。")
	_check(G, back.emitter_cell == Vector2i.ZERO, "缺失 emitter_cell 应回落 (0,0)。")
	_check(G, back.crystal_id == &"", "缺失 crystal_id 应回落空（不得静默造 ID）。")
	# 存在属性 → 按文件值加载。
	_check(G, back.level_id == &"old_level" and back.terrain_cells.size() == 2 and back.crystal_cell == Vector2i(1, 0), "已写入属性应按文件值加载。")
	# validate 确定性：恰好 1 条 crystal_id 空。
	var problems: PackedStringArray = back.validate()
	_check(G, problems.size() == 1 and _has(problems, "crystal_id 为空"), "缺省回落数据 validate 应恰报 crystal_id 空 1 条，实际 %d：%s。" % [problems.size(), ", ".join(problems)])
	var rm_err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(_OLD_TRES_PARTIAL_PATH))
	_check(G, rm_err == OK, "旧式 .tres 临时文件应清理成功，实际 %d。" % rm_err)


## 17. 旧式最小合法 .tres（只写校验所需事实，其余全缺省）：加载后 validate 为空——
## 证明 additive-only 下“旧数据 + 缺省默认值”可构成完整合法关卡数据。
func _test_17_old_tres_minimal_valid() -> void:
	const G: String = "17_旧tres最小合法"
	var text: String = _old_tres_text(&"old_valid", [
		"level_id = &\"old_level\"",
		"terrain_cells = Array[Vector2i]([Vector2i(0, 0), Vector2i(1, 0)])",
		"crystal_cell = Vector2i(1, 0)",
		"crystal_id = &\"crystal_old\"",
	])
	var write_ok: bool = _write_user_file(_OLD_TRES_VALID_PATH, text)
	_check(G, write_ok, "最小旧式 .tres 应写入成功。")
	var back: _LevelData = ResourceLoader.load(_OLD_TRES_VALID_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(G, back != null, "最小旧式 .tres 应加载成功。")
	if back != null:
		_check(G, back.validate().is_empty(), "缺省回落后的最小旧式数据 validate 应为空，实际：%s。" % ", ".join(back.validate()))
	var rm_err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(_OLD_TRES_VALID_PATH))
	_check(G, rm_err == OK, "最小旧式 .tres 临时文件应清理成功，实际 %d。" % rm_err)


## 构造旧式 .tres 文本：按 Godot 4.6 属性名序列化格式手写，仅包含给定的属性行（模拟缺失后续可选属性的旧文件）。
func _old_tres_text(id_tag: StringName, property_lines: Array) -> String:
	var body: String = "\n".join(property_lines)
	return "[gd_resource type=\"Resource\" script_class=\"LevelData\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://gameplay/level/data/level_data.gd\" id=\"1_%s\"]\n\n[resource]\nscript = ExtResource(\"1_%s\")\n%s\n" % [String(id_tag), String(id_tag), body]


## 将文本写入 user:// 临时文件；成功返回 true。
func _write_user_file(path: String, text: String) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


# ===== fixture =====

## 组装结构合法且配置明确的关卡根：3×3 Terrain + Wall(1,1) + Legal(0,0)；
## Emitter@(0,0)（PARTICLE / 允许切换 / LEFT / UP_LEFT）+ Crystal@(2,0)。
func _make_root() -> Node2D:
	var ts: TileSet = _make_min_tile_set()
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	root.add_child(_new_tile_layer("TerrainLayer", ts, _cells_3x3()))
	root.add_child(_new_tile_layer("WallLayer", ts, [Vector2i(1, 1)]))
	root.add_child(_new_tile_layer("LegalAreaLayer", ts, [Vector2i(0, 0)]))
	root.add_child(_new_tile_layer("DecorationLayer", ts, []))
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	var emitter: _EmitterConfigNode = _EmitterConfigNode.new()
	emitter.name = &"Emitter"
	emitter.position = _GridCoordinateRules.cell_to_world(Vector2i(0, 0))
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	emitter.allow_form_switch = true
	emitter.ray_default_direction = _EmitterConfigNode.RayDirection.LEFT
	emitter.particle_default_direction = _EmitterConfigNode.ParticleDirection.UP_LEFT
	runtime.add_child(emitter)
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.name = &"BasicCrystal"
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(2, 0))
	crystal.crystal_id = &"crystal_d7r2"
	runtime.add_child(crystal)
	var light: Node2D = Node2D.new()
	light.name = &"LightPathLayer"
	root.add_child(light)
	return root


## 与 _valid_data 同口径的完全合法数据（Terrain 3×3、Wall(1,1)、Legal(0,0)、Emitter(0,0)、Crystal(2,0)）。
func _valid_data() -> _LevelData:
	var data: _LevelData = _LevelData.new()
	data.terrain_cells = _cells_3x3()
	data.wall_cells = [Vector2i(1, 1)]
	data.legal_area_cells = [Vector2i(0, 0)]
	data.emitter_cell = Vector2i(0, 0)
	data.emitter_form = 0
	data.emitter_allow_form_switch = false
	data.emitter_ray_direction = 0
	data.emitter_particle_direction = 0
	data.crystal_cell = Vector2i(2, 0)
	data.crystal_id = &"crystal_valid"
	return data


## 构造最小可用 TileSet：单 atlas 源、无纹理；set_cell 引用 source 0 即可使 get_used_cells 返回该格。
func _make_min_tile_set() -> TileSet:
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	tile_set.add_source(source)
	return tile_set


## 用给定 TileSet 与格列表构造未入树的 TileMapLayer 并逐格 set_cell。
func _new_tile_layer(layer_name: String, tile_set: TileSet, cells: Array) -> TileMapLayer:
	var layer: TileMapLayer = TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = tile_set
	for c in cells:
		layer.set_cell(c, 0, Vector2i.ZERO, 0)
	return layer


## 3×3 实心 Terrain 格。
func _cells_3x3() -> Array[Vector2i]:
	return [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]


# ===== 断言辅助 =====

func _check(group: String, cond: bool, reason: String) -> void:
	_checks += 1
	if not cond:
		_failures.append("[%s] %s" % [group, reason])


func _has(problems: PackedStringArray, fragment: String) -> bool:
	for p in problems:
		if p.contains(fragment):
			return true
	return false


func _count_start(problems: PackedStringArray, prefix: String) -> int:
	var n: int = 0
	for p in problems:
		if p.contains(prefix):
			n += 1
	return n


func _report() -> void:
	print("LevelDataTest：共 %d 组。" % _GROUP_COUNT)
	print("LevelDataTest：断言 %d 项，失败 %d 项。" % [_checks, _failures.size()])
	if not _failures.is_empty():
		for f in _failures:
			print("FAIL " + f)
	else:
		print("LevelDataTest：ALL PASS")
