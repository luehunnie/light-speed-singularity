extends SceneTree

# AF-08 Map Layer Assist 服务测试。
# 覆盖：Initialize LegalArea from Terrain（补格、不删既有）、LegalArea/Wall 越界发现与清理、
#       Wall∩LegalArea 重叠清理（保留 Wall 事实）、快照/恢复（撤销数据面）、常用检查（统一 Validator 口径）。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _MapLayerService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/map_layer_service.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_initialize_legal_from_terrain()
	_test_02_clean_outside()
	_test_03_clean_wall_on_legal()
	_test_04_snapshot_restore()
	_test_05_collect_issues()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _make_root() -> Node2D:
	return _LevelRay001.instantiate() as Node2D


func _test_01_initialize_legal_from_terrain() -> void:
	const NAME: String = "01_初始化LegalArea"
	var root := _make_root()
	var legal: TileMapLayer = root.get_node("LegalAreaLayer")
	var legal_before: int = legal.get_used_cells().size()
	for cell: Vector2i in legal.get_used_cells():
		legal.erase_cell(cell)
	var added: Array = _MapLayerService.initialize_legal_from_terrain(root)
	_check(NAME, added.size() == legal_before, "清空后初始化应补回 %d 格，实际 %d。" % [legal_before, added.size()])
	var added_again: Array = _MapLayerService.initialize_legal_from_terrain(root)
	_check(NAME, added_again.is_empty(), "LegalArea 已覆盖全部 Terrain 时应零新增。")
	root.free()


func _test_02_clean_outside() -> void:
	const NAME: String = "02_越界发现与清理"
	var root := _make_root()
	var legal: TileMapLayer = root.get_node("LegalAreaLayer")
	var wall: TileMapLayer = root.get_node("WallLayer")
	_check(NAME, _MapLayerService.find_legal_outside_terrain(root).is_empty(), "初始关卡应无 LegalArea 越界。")
	legal.set_cell(Vector2i(30, 30), 0, Vector2i.ZERO)
	wall.set_cell(Vector2i(31, 31), 0, Vector2i.ZERO)
	_check(NAME, _MapLayerService.find_legal_outside_terrain(root) == [Vector2i(30, 30)], "应发现 LegalArea 越界 (30,30)。")
	_check(NAME, _MapLayerService.find_wall_outside_terrain(root) == [Vector2i(31, 31)], "应发现 Wall 越界 (31,31)。")
	var erased_legal: Array = _MapLayerService.clean_legal_outside_terrain(root)
	var erased_wall: Array = _MapLayerService.clean_wall_outside_terrain(root)
	_check(NAME, erased_legal == [Vector2i(30, 30)] and erased_wall == [Vector2i(31, 31)], "清理应各移除 1 越界格。")
	_check(NAME, _MapLayerService.find_legal_outside_terrain(root).is_empty()
		and _MapLayerService.find_wall_outside_terrain(root).is_empty(), "清理后应零越界残留。")
	root.free()


func _test_03_clean_wall_on_legal() -> void:
	const NAME: String = "03_Wall∩Legal重叠清理"
	var root := _make_root()
	var legal: TileMapLayer = root.get_node("LegalAreaLayer")
	var wall: TileMapLayer = root.get_node("WallLayer")
	var wall_cells: Array = wall.get_used_cells()
	_check(NAME, _MapLayerService.find_wall_on_legal(root) == wall_cells,
		"level_ray_001 的 Wall 格均与 LegalArea 重叠（初始即重叠事实）。")
	var erased: Array = _MapLayerService.clean_legal_on_wall(root)
	_check(NAME, erased.size() == wall_cells.size(), "清理应移除与 Wall 重叠的全部 LegalArea 格。")
	_check(NAME, _MapLayerService.find_wall_on_legal(root).is_empty(), "清理后应零重叠。")
	_check(NAME, wall.get_used_cells().size() == wall_cells.size(), "清理保留 Wall 事实（Wall 格数不变）。")
	root.free()


func _test_04_snapshot_restore() -> void:
	const NAME: String = "04_快照与恢复"
	var root := _make_root()
	var legal: TileMapLayer = root.get_node("LegalAreaLayer")
	var before: Dictionary = _MapLayerService.snapshot_layer(legal)
	var cells_before: int = before.size()
	var cell_sample: Vector2i = legal.get_used_cells()[0]
	legal.erase_cell(cell_sample)
	legal.set_cell(Vector2i(40, 40), 0, Vector2i.ZERO)
	_MapLayerService.restore_layer(legal, before)
	_check(NAME, legal.get_used_cells().size() == cells_before, "恢复后格数应与快照一致。")
	_check(NAME, legal.get_cell_source_id(cell_sample) != -1, "快照内被误删格应被补回。")
	_check(NAME, legal.get_cell_source_id(Vector2i(40, 40)) == -1, "快照外新增格应被清除。")
	root.free()


func _test_05_collect_issues() -> void:
	const NAME: String = "05_常用检查"
	var root := _make_root()
	var issues: Dictionary = _MapLayerService.collect_issues(root)
	_check(NAME, issues.valid and issues.errors == 0, "合法关卡应通过检查（0 错误）。")
	var broken := Node2D.new()
	var broken_issues: Dictionary = _MapLayerService.collect_issues(broken)
	_check(NAME, not broken_issues.valid and broken_issues.errors > 0, "非关卡根应报错误。")
	broken.free()
	root.free()


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("map_layer_service_test: %d checks, %d failures" % [_checks, _failures.size()])
