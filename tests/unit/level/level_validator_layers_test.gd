extends SceneTree

## LevelValidator 四层结构与跨层规则定向测试（D6-A）。
## 用纯内存 fixture（程序化最小 TileSet + 未入树 TileMapLayer 组装关卡根）固化 v0 校验器的结构识别与四层规则。
## 覆盖：合法结构 PASS、根非法、缺角色、错型、misplaced、duplicate、unexpected(WARNING)、transform、TileSet 缺失、
##   Terrain 空、Legal 越界、Wall 越界、Legal 空(WARNING)、Legal/Wall 重叠(WARNING)、Terrain 空洞、Terrain 多岛、
##   Decoration 不参与逻辑、同实例连续两次结果一致且不改场景。
## 不使用 LevelWorldQuery 或 LevelTileLayerSnapshot 生成预期；事实直接来自 TileMapLayer.get_used_cells()。
## headless extends SceneTree，由 Godot --script 运行；preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）；fixture 不入 SceneTree，各用例受控 free。

const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
# D6-B：固定对象校验已并入 LevelValidator.validate()，结构测试 fixture 需同步带上合法固定对象。
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")
const _ObjectVisualProfile: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_profile.gd")

const _GROUP_COUNT: int = 22

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行 21 组后统一报告并退出。
func _initialize() -> void:
	_test_01_full_valid_pass()
	_test_02_invalid_root()
	_test_03_missing_role()
	_test_04_wrong_type()
	_test_05_misplaced()
	_test_06_duplicate_role()
	_test_07_unexpected_tile_layer()
	_test_08_logic_transform()
	_test_09_tileset_missing()
	_test_10_terrain_empty()
	_test_11_legal_outside_terrain()
	_test_12_wall_outside_terrain()
	_test_13_legal_area_empty()
	_test_14_legal_wall_overlap()
	_test_15_terrain_hole()
	_test_16_terrain_islands()
	_test_17_decoration_no_logic()
	_test_18_twice_consistent()
	_test_19_misplaced_multi_candidates()
	_test_20_unexpected_nested()
	_test_21_wrong_type_with_extra()
	_test_22_ancestor_transform()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 用例 =====

## 1. 完全合法四层结构 PASS：0 issue。
func _test_01_full_valid_pass() -> void:
	const G: String = "01_合法结构PASS"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "合法结构期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "合法结构期望 error_count=0，实际 %d。" % result.get_error_count())
	_check(G, result.get_warning_count() == 0, "合法结构期望 warning_count=0，实际 %d。" % result.get_warning_count())
	_check(G, result.get_issues().is_empty(), "合法结构期望 0 issue，实际 %d。" % result.get_issues().size())
	root.free()


## 2. null / 非 Node2D 根 → level_root_invalid。
func _test_02_invalid_root() -> void:
	const G: String = "02_根非法"
	var r_null: _LevelValidationResult = _validate(null)
	_check(G, r_null.is_valid() == false, "null 根期望 is_valid=false。")
	_check(G, _has_code(r_null, "level_root_invalid"), "null 根期望 level_root_invalid。")
	var plain: Node = Node.new()
	var r_node: _LevelValidationResult = _validate(plain)
	_check(G, r_node.is_valid() == false, "非 Node2D 根期望 is_valid=false。")
	_check(G, _has_code(r_node, "level_root_invalid"), "非 Node2D 根期望 level_root_invalid。")
	plain.free()


## 3. 缺正式角色 → required_node_missing。
func _test_03_missing_role() -> void:
	const G: String = "03_缺角色"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	var terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(terrain)
	terrain.free()
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "缺 TerrainLayer 期望 is_valid=false。")
	_check(G, _has_code(result, "required_node_missing"), "期望 required_node_missing。")
	root.free()


## 4. 角色错型 → required_node_type_invalid。
func _test_04_wrong_type() -> void:
	const G: String = "04_角色错型"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	var terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(terrain)
	terrain.free()
	var fake: Node2D = Node2D.new()
	fake.name = &"TerrainLayer"
	root.add_child(fake)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "TerrainLayer 错型期望 is_valid=false。")
	_check(G, _has_code(result, "required_node_type_invalid"), "期望 required_node_type_invalid。")
	root.free()


## 5. 角色 misplaced → required_node_misplaced，路径指向错位节点。
func _test_05_misplaced() -> void:
	const G: String = "05_角色错位"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	var terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(terrain)
	root.get_node("RuntimeObjects").add_child(terrain)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "TerrainLayer 错位期望 is_valid=false。")
	_check(G, _has_code(result, "required_node_misplaced"), "期望 required_node_misplaced。")
	_check(G, _has_path(result, "required_node_misplaced", "RuntimeObjects/TerrainLayer"), "期望 misplaced 路径为 RuntimeObjects/TerrainLayer。")
	root.free()


## 6. duplicate role → duplicate_role_node。
func _test_06_duplicate_role() -> void:
	const G: String = "06_重复角色"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	var extra: TileMapLayer = _new_tile_layer("TerrainLayer", _make_min_tile_set(), [Vector2i(0, 0)])
	root.get_node("RuntimeObjects").add_child(extra)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "重复 TerrainLayer 期望 is_valid=false。")
	_check(G, _has_code(result, "duplicate_role_node"), "期望 duplicate_role_node。")
	_check(G, _has_path(result, "duplicate_role_node", "RuntimeObjects/TerrainLayer"), "期望 duplicate 路径为 RuntimeObjects/TerrainLayer。")
	root.free()


## 7. unexpected TileMapLayer → WARNING 且 valid。
func _test_07_unexpected_tile_layer() -> void:
	const G: String = "07_额外TileMapLayer"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	root.add_child(_new_tile_layer("ExtraLayer", _make_min_tile_set(), [Vector2i(0, 0)]))
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "unexpected 为 WARNING 期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "unexpected 期望 0 ERROR。")
	_check(G, _has_code(result, "unexpected_tile_layer"), "期望 unexpected_tile_layer。")
	root.free()


## 8. 非法逻辑 transform → logic_transform_invalid。
func _test_08_logic_transform() -> void:
	const G: String = "08_非法transform"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	(root.get_node("TerrainLayer") as TileMapLayer).position = Vector2(5, 5)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "transform 非法期望 is_valid=false。")
	_check(G, _has_code(result, "logic_transform_invalid"), "期望 logic_transform_invalid。")
	root.free()


## 9. TileSet 缺失 → tileset_missing。
func _test_09_tileset_missing() -> void:
	const G: String = "09_TileSet缺失"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	(root.get_node("TerrainLayer") as TileMapLayer).tile_set = null
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "TileSet 缺失期望 is_valid=false。")
	_check(G, _has_code(result, "tileset_missing"), "期望 tileset_missing。")
	root.free()


## 10. Terrain 空 → terrain_empty。
func _test_10_terrain_empty() -> void:
	const G: String = "10_Terrain空"
	var root: Node2D = _make_root([], [], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "Terrain 空期望 is_valid=false。")
	_check(G, _has_code(result, "terrain_empty"), "期望 terrain_empty。")
	root.free()


## 11. Legal 越界 Terrain → legal_outside_terrain（cell 级）。
func _test_11_legal_outside_terrain() -> void:
	const G: String = "11_Legal越界"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(5, 5)], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "Legal 越界期望 is_valid=false。")
	_check(G, _has_cell_issue(result, "legal_outside_terrain", Vector2i(5, 5)), "期望 legal_outside_terrain(5,5)。")
	root.free()


## 12. Wall 越界 Terrain → wall_outside_terrain（cell 级）。
func _test_12_wall_outside_terrain() -> void:
	const G: String = "12_Wall越界"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [Vector2i(7, 7)], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "Wall 越界期望 is_valid=false。")
	_check(G, _has_cell_issue(result, "wall_outside_terrain", Vector2i(7, 7)), "期望 wall_outside_terrain(7,7)。")
	root.free()


## 13. Legal 空 → legal_area_empty（WARNING）且 valid。
func _test_13_legal_area_empty() -> void:
	const G: String = "13_Legal空"
	var root: Node2D = _make_root(_cells_3x3(), [], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "Legal 空为 WARNING 期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "Legal 空期望 0 ERROR。")
	_check(G, _has_code(result, "legal_area_empty"), "期望 legal_area_empty。")
	root.free()


## 14. Legal/Wall 重叠 → legal_wall_overlap（WARNING）且 valid。
func _test_14_legal_wall_overlap() -> void:
	const G: String = "14_LegalWall重叠"
	var root: Node2D = _make_root([Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)], [Vector2i(1, 1)], [Vector2i(1, 1)], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "Legal/Wall 重叠为 WARNING 期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "重叠期望 0 ERROR。")
	_check(G, _has_cell_issue(result, "legal_wall_overlap", Vector2i(1, 1)), "期望 legal_wall_overlap(1,1)。")
	root.free()


## 15. Terrain 内部空洞不报错。
func _test_15_terrain_hole() -> void:
	const G: String = "15_Terrain空洞"
	var root: Node2D = _make_root(_cells_3x3_hole(), [Vector2i(0, 0)], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "Terrain 含空洞期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "含空洞期望 0 ERROR。")
	_check(G, result.get_warning_count() == 0, "含空洞期望 0 WARNING。")
	root.free()


## 16. 多个不连通 Terrain 岛不报错。
func _test_16_terrain_islands() -> void:
	const G: String = "16_Terrain多岛"
	var root: Node2D = _make_root(_cells_islands(), [Vector2i(0, 0)], [], [])
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "Terrain 多岛期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "多岛期望 0 ERROR。")
	_check(G, result.get_warning_count() == 0, "多岛期望 0 WARNING。")
	root.free()


## 17. Decoration 任意越界/重叠不产生逻辑 Issue。
func _test_17_decoration_no_logic() -> void:
	const G: String = "17_Decoration不参与逻辑"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], _cells_deco_garbage())
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "Decoration 越界/重叠期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "Decoration 不应产生 ERROR。")
	_check(G, result.get_warning_count() == 0, "Decoration 不应产生 WARNING。")
	root.free()


## 18. 同一实例连续 validate 两次结果一致，场景状态不变。
func _test_18_twice_consistent() -> void:
	const G: String = "18_两次一致"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(9, 9)], [], [])
	root.add_child(_new_tile_layer("ExtraLayer", _make_min_tile_set(), []))
	var child_count_before: int = root.get_child_count()
	var validator: _LevelValidator = _LevelValidator.new()
	var r1: _LevelValidationResult = validator.validate(root)
	var r2: _LevelValidationResult = validator.validate(root)
	_check(G, _signature(r1) == _signature(r2), "同一实例两次 validate 结果序列应一致。")
	_check(G, _has_code(r1, "legal_outside_terrain") and _has_code(r1, "unexpected_tile_layer"), "期望含 legal_outside_terrain 与 unexpected_tile_layer。")
	_check(G, root.get_child_count() == child_count_before, "两次 validate 不应改变子节点数，期望 %d。" % child_count_before)
	_check(G, (root.get_node("TerrainLayer") as Node2D).position == Vector2.ZERO, "两次 validate 不应改变节点 transform。")
	root.free()


## 19. 无直属角色 + 多个同名 misplaced 候选：恰好一个 misplaced（确定性首选），其余候选各一个 duplicate。
func _test_19_misplaced_multi_candidates() -> void:
	const G: String = "19_多同名错位"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(0, 0)], [], [])
	var direct_terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(direct_terrain)
	direct_terrain.free()
	# 在 RuntimeObjects 下挂三个同名 TerrainLayer 候选；按 C/B/A 的树序加入，使 DFS 首项为 C，
	# 但按相对 NodePath 排序后首选必须为 A（验证确定性，不依赖遍历顺序）。
	var runtime: Node = root.get_node("RuntimeObjects")
	runtime.add_child(_make_named_holder_with_terrain("HolderC"))
	runtime.add_child(_make_named_holder_with_terrain("HolderB"))
	runtime.add_child(_make_named_holder_with_terrain("HolderA"))
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "多同名错位期望 is_valid=false。")
	_check(G, _count_code(result, "required_node_misplaced") == 1, "期望恰好 1 个 required_node_misplaced，实际 %d。" % _count_code(result, "required_node_misplaced"))
	_check(G, _count_code(result, "duplicate_role_node") == 2, "期望 2 个 duplicate_role_node（剩余候选），实际 %d。" % _count_code(result, "duplicate_role_node"))
	_check(G, _has_path(result, "required_node_misplaced", "RuntimeObjects/HolderA/TerrainLayer"), "期望 misplaced 首选路径为 RuntimeObjects/HolderA/TerrainLayer。")
	_check(G, _has_path(result, "duplicate_role_node", "RuntimeObjects/HolderB/TerrainLayer"), "期望 duplicate 路径含 RuntimeObjects/HolderB/TerrainLayer。")
	_check(G, _has_path(result, "duplicate_role_node", "RuntimeObjects/HolderC/TerrainLayer"), "期望 duplicate 路径含 RuntimeObjects/HolderC/TerrainLayer。")
	root.free()


## 20. 嵌套非正式 TileMapLayer → unexpected_tile_layer（WARNING）且 is_valid=true。
func _test_20_unexpected_nested() -> void:
	const G: String = "20_嵌套额外层"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(0, 0)], [], [])
	var debug: TileMapLayer = _new_tile_layer("DebugCollisionTiles", _make_min_tile_set(), [Vector2i(0, 0)])
	root.get_node("RuntimeObjects").add_child(debug)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == true, "嵌套 unexpected 为 WARNING 期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "嵌套 unexpected 期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, _has_code(result, "unexpected_tile_layer"), "期望 unexpected_tile_layer。")
	_check(G, _has_path(result, "unexpected_tile_layer", "RuntimeObjects/DebugCollisionTiles"), "期望 unexpected 路径为 RuntimeObjects/DebugCollisionTiles。")
	root.free()


## 21. 直属正式角色错型 + 其他位置额外同名节点：type_invalid + duplicate，额外节点不再报 misplaced。
func _test_21_wrong_type_with_extra() -> void:
	const G: String = "21_错型加额外同名"
	var root: Node2D = _make_root(_cells_3x3(), [Vector2i(0, 0)], [], [])
	var direct_terrain: Node = root.get_node("TerrainLayer")
	root.remove_child(direct_terrain)
	direct_terrain.free()
	var fake: Node2D = Node2D.new()
	fake.name = &"TerrainLayer"
	root.add_child(fake)
	var extra: TileMapLayer = _new_tile_layer("TerrainLayer", _make_min_tile_set(), [])
	root.get_node("RuntimeObjects").add_child(extra)
	var result: _LevelValidationResult = _validate(root)
	_check(G, result.is_valid() == false, "错型期望 is_valid=false。")
	_check(G, _count_code(result, "required_node_type_invalid") == 1, "期望 1 个 required_node_type_invalid，实际 %d。" % _count_code(result, "required_node_type_invalid"))
	_check(G, _count_code(result, "duplicate_role_node") == 1, "期望 1 个 duplicate_role_node，实际 %d。" % _count_code(result, "duplicate_role_node"))
	_check(G, _count_code(result, "required_node_misplaced") == 0, "额外同名节点不应再报 required_node_misplaced，实际 %d。" % _count_code(result, "required_node_misplaced"))
	_check(G, _has_path(result, "required_node_type_invalid", "TerrainLayer"), "期望 type_invalid 路径为直属 TerrainLayer。")
	_check(G, _has_path(result, "duplicate_role_node", "RuntimeObjects/TerrainLayer"), "期望 duplicate 路径为 RuntimeObjects/TerrainLayer。")
	root.free()


## 22. 祖先 transform（含关卡根）非单位变换 → ancestor_transform_invalid（AF-09 P0 幽灵墙阻断）：
## 格子是唯一事实，祖先位移/旋转/缩放使视觉随节点动而碰撞/占位不动；进运行（Play Gate 委派本校验）前必须阻断。
func _test_22_ancestor_transform() -> void:
	const G: String = "22_祖先transform"
	# 关卡根（= Walls/WallLayer 父节点）位移：报错且阻断，同一根只报一次。
	var moved_root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	moved_root.position = Vector2(32, 0)
	var r_moved: _LevelValidationResult = _validate(moved_root)
	_check(G, r_moved.is_valid() == false, "关卡根位移期望 is_valid=false。")
	_check(G, _has_code(r_moved, "ancestor_transform_invalid"), "关卡根位移期望 ancestor_transform_invalid。")
	var count: int = 0
	for issue in r_moved.get_issues():
		if str(issue.get_code()) == "ancestor_transform_invalid":
			count += 1
	_check(G, count == 1, "同一祖先只应报一次，实际 %d。" % count)
	moved_root.free()
	# 根旋转同理。
	var rotated_root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	rotated_root.rotation = 0.5
	_check(G, _has_code(_validate(rotated_root), "ancestor_transform_invalid"), "关卡根旋转期望报错。")
	rotated_root.free()
	# 根缩放同理。
	var scaled_root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	scaled_root.scale = Vector2(2.0, 2.0)
	_check(G, _has_code(_validate(scaled_root), "ancestor_transform_invalid"), "关卡根缩放期望报错。")
	scaled_root.free()
	# 对照：identity 祖先不报（合法结构零 issue 由用例 1 覆盖，此处补防御性对照）。
	var clean_root: Node2D = _make_root(_cells_3x3(), [Vector2i(1, 1)], [], [])
	_check(G, not _has_code(_validate(clean_root), "ancestor_transform_invalid"),
		"identity 祖先不应报 ancestor_transform_invalid。")
	clean_root.free()


# ===== fixture =====## 组装结构合法的关卡根：六个正式角色齐备、类型正确、transform 单位、TileSet 已绑；四层格子由参数指定。
func _make_root(terrain_cells: Array, legal_cells: Array, wall_cells: Array, deco_cells: Array) -> Node2D:
	var ts: TileSet = _make_min_tile_set()
	var root: Node2D = Node2D.new()
	root.name = &"LevelRoot"
	root.add_child(_new_tile_layer("TerrainLayer", ts, terrain_cells))
	root.add_child(_new_tile_layer("WallLayer", ts, wall_cells))
	root.add_child(_new_tile_layer("LegalAreaLayer", ts, legal_cells))
	root.add_child(_new_tile_layer("DecorationLayer", ts, deco_cells))
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	root.add_child(runtime)
	# D6-B：结构合法的 fixture 必须同时满足固定对象合同（恰好 1 Emitter + 1 Crystal），否则被并入 validate() 的固定对象校验报错。
	_populate_runtime_objects(runtime)
	var light: Node2D = Node2D.new()
	light.name = &"LightPathLayer"
	root.add_child(light)
	return root


## D6-B：在 RuntimeObjects 下放置合法固定对象——Emitter@(0,0) + Crystal@(1,0)，均带 Profile，
## 使结构合法的 fixture 也满足 v0 固定对象合同。对象落在多数 fixture 的 terrain 内（含 (0,0)/(1,0)）；
## 仅 test_14 的 terrain 额外补 (1,0)（见该用例）。
func _populate_runtime_objects(runtime: Node2D) -> void:
	var emitter_profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	var emitter: _EmitterConfigNode = _EmitterConfigNode.new()
	emitter.name = &"Emitter"
	emitter.position = _GridCoordinateRules.cell_to_world(Vector2i(0, 0))
	emitter.visual_profile = emitter_profile
	runtime.add_child(emitter)
	var crystal_profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	var crystal: _BasicCrystal = _BasicCrystal.new()
	crystal.name = &"BasicCrystal"
	crystal.position = _GridCoordinateRules.cell_to_world(Vector2i(1, 0))
	crystal.crystal_id = &"crystal_layers"
	var view: _ObjectVisualView = _ObjectVisualView.new()
	view.name = &"VisualView"
	view.visual_profile = crystal_profile
	crystal.add_child(view)
	runtime.add_child(crystal)


## 构造最小可用 TileSet：单 atlas 源、无纹理；set_cell 引用 source 0 即可使 get_used_cells 返回该格。
func _make_min_tile_set() -> TileSet:
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	tile_set.add_source(source)
	return tile_set


## 用给定 TileSet 与格列表构造未入树的 TileMapLayer 并逐格 set_cell；transform 保持单位。
func _new_tile_layer(layer_name: String, tile_set: TileSet, cells: Array) -> TileMapLayer:
	var layer: TileMapLayer = TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = tile_set
	for c in cells:
		layer.set_cell(c, 0, Vector2i.ZERO, 0)
	return layer


## 构造 Node2D 容器，内含一个空格同名 TerrainLayer 候选，用于多候选 misplaced fixture（容器名决定路径排序）。
func _make_named_holder_with_terrain(holder_name: String) -> Node2D:
	var holder: Node2D = Node2D.new()
	holder.name = StringName(holder_name)
	holder.add_child(_new_tile_layer("TerrainLayer", _make_min_tile_set(), []))
	return holder


## 3×3 实心 Terrain 格。
func _cells_3x3() -> Array:
	return [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]


## 3×3 挖去中心 (1,1) 的含洞 Terrain 格。
func _cells_3x3_hole() -> Array:
	return [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]


## 两个不连通 Terrain 岛。
func _cells_islands() -> Array:
	return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(5, 5), Vector2i(6, 5)]


## Decoration 垃圾格：越界、与 Terrain 重叠、负坐标混合，用于证明装饰层不参与任何逻辑。
func _cells_deco_garbage() -> Array:
	return [Vector2i(9, 9), Vector2i(1, 1), Vector2i(-3, -3)]


# ===== 断言辅助 =====

## 新建无状态校验器并校验 root。
func _validate(root: Node) -> _LevelValidationResult:
	return _LevelValidator.new().validate(root)


## 结果中是否存在指定 code 的 issue。
func _has_code(result: _LevelValidationResult, code: String) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			return true
	return false


## 结果中是否存在指定 code 且 cell 匹配的 cell 级 issue。
func _has_cell_issue(result: _LevelValidationResult, code: String, cell: Vector2i) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code and issue.has_cell() and issue.get_cell() == cell:
			return true
	return false


## 结果中是否存在指定 code 且 node_path 匹配的 issue。
func _has_path(result: _LevelValidationResult, code: String, node_path: String) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code and str(issue.get_node_path()) == node_path:
			return true
	return false


## 结果中指定 code 的 issue 数量。
func _count_code(result: _LevelValidationResult, code: String) -> int:
	var n: int = 0
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			n += 1
	return n


## issue 序列签名（含全部排序键），用于比较两次结果是否逐项一致。
func _signature(result: _LevelValidationResult) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for issue in result.get_issues():
		parts.append("%d|%s|%s|%d|%d,%d|%s" % [
			issue.get_severity(), str(issue.get_code()), str(issue.get_node_path()),
			int(issue.has_cell()), issue.get_cell().x, issue.get_cell().y, str(issue.get_object_id())
		])
	return "\n".join(parts)


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelValidator 四层结构与规则 测试摘要 ====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
