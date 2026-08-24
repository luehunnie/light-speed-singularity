extends SceneTree

# AF-08 编辑期统一 Placement Query 测试。
# 覆盖：真实关卡构建、四种失败原因（OUTSIDE_TERRAIN / WALL_BLOCKED / OBJECT_OCCUPIED×2）、
#       合法空格 allowed、被忽略自身占用（移动语义）、缺层拒绝构建。
# 语义合同：编辑期与 Runtime/Validator 共用 SharedPlacementQuery 同一规则源（Guide §10.2）。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_reasons_on_real_level()
	_test_02_ignored_occupant()
	_test_03_missing_layers_rejected()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _test_01_reasons_on_real_level() -> void:
	const NAME: String = "01_真实关卡失败原因"
	var root := _LevelRay001.instantiate() as Node2D
	var query: RefCounted = _EditorPlacementQuery.new()
	_check(NAME, query.build(root), "真实关卡应可构建编辑期查询。")
	# Terrain 外（level_ray_001 地图为 0..15）。
	var outside: Variant = query.evaluate([Vector2i(30, 3)])
	_check(NAME, not outside.is_allowed() and outside.issues[0] == &"OUTSIDE_TERRAIN",
		"Terrain 外应报 OUTSIDE_TERRAIN，实际 %s。" % str(outside.issues))
	# 墙格 (5,3)（AF-07 冻结布局：光路终点墙）。
	var wall_result: Variant = query.evaluate([Vector2i(5, 3)])
	_check(NAME, not wall_result.is_allowed() and wall_result.issues[0] == &"WALL_BLOCKED",
		"墙格应报 WALL_BLOCKED，实际 %s。" % str(wall_result.issues))
	# 发射器格 (1,3)（世界 (96,224)）。
	var emitter_result: Variant = query.evaluate([Vector2i(1, 3)])
	_check(NAME, not emitter_result.is_allowed() and emitter_result.issues[0] == &"OBJECT_OCCUPIED",
		"发射器格应报 OBJECT_OCCUPIED（静态阻挡），实际 %s。" % str(emitter_result.issues))
	# 水晶格 (3,1)（世界 (224,96)）。
	var crystal_result: Variant = query.evaluate([Vector2i(3, 1)])
	_check(NAME, not crystal_result.is_allowed() and crystal_result.issues[0] == &"OBJECT_OCCUPIED",
		"水晶格应报 OBJECT_OCCUPIED（编辑期占用登记），实际 %s。" % str(crystal_result.issues))
	# 合法空格。
	var free_result: Variant = query.evaluate([Vector2i(2, 1)])
	_check(NAME, free_result.is_allowed(), "空格 (2,1) 应合法，实际 %s。" % str(free_result.issues))
	root.free()


func _test_02_ignored_occupant() -> void:
	const NAME: String = "02_忽略自身占用"
	var root := _LevelRay001.instantiate() as Node2D
	var query: RefCounted = _EditorPlacementQuery.new()
	query.build(root)
	var crystal: Node2D = root.get_node("RuntimeObjects/Crystal")
	var self_result: Variant = query.evaluate([Vector2i(3, 1)], crystal)
	_check(NAME, self_result.is_allowed(), "忽略水晶自身占用后其格应合法（移动中语义），实际 %s。" % str(self_result.issues))
	root.free()


func _test_03_missing_layers_rejected() -> void:
	const NAME: String = "03_缺层拒绝"
	var root := _LevelRay001.instantiate() as Node2D
	var removed: Node = root.get_node("LegalAreaLayer")
	root.remove_child(removed)
	removed.free()
	var query: RefCounted = _EditorPlacementQuery.new()
	_check(NAME, not query.build(root) and not query.is_ready(), "缺 LegalArea 层应拒绝构建，不静默降级。")
	root.free()


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("editor_placement_query_test: %d checks, %d failures" % [_checks, _failures.size()])
