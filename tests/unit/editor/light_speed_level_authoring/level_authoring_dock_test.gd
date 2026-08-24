extends SceneTree

# AF-08 Level Authoring Dock 接线测试（headless 游戏模式；真实编辑器外观 = Human Gate）。
# 覆盖：Dock 构建与 Palette 填充、选择转发（正式对象启用旋转入口）、方向旋转事务（UndoRedo 口径）、
#       放置按钮路径（桥替身提供关卡根）、修复 Stable ID、非法关卡运行拒绝。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _Dock: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/level_authoring_dock.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


# 编辑器桥替身：记录调用、提供内存关卡根。
class StubBridge extends RefCounted:
	var opened_paths: Array[String] = []
	var play_calls: int = 0
	var current_root: Node2D = null

	func open_scene(path: String) -> void:
		opened_paths.append(path)


	func get_current_scene_path() -> String:
		return "res://levels/campaign/ray_chapter/level_ray_001.tscn" if current_root != null else ""


	func get_edited_level_root() -> Node2D:
		return current_root


	func play_current_level() -> void:
		play_calls += 1


func _initialize() -> void:
	var root := _LevelRay001.instantiate() as Node2D
	var dock: CanvasItem = _Dock.new()
	var bridge := StubBridge.new()
	bridge.current_root = root
	dock.set_editor_bridge(bridge)
	dock.set_undo_redo(UndoRedo.new())
	dock._ready()

	_test_01_palette_populated(dock)
	_test_02_selection_and_rotate(dock, root)
	_test_03_place_via_dock(dock, root)
	_test_04_repair_stable_ids(dock, root)
	_test_05_play_gate(dock, bridge, root)

	dock.free()
	root.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _test_01_palette_populated(dock: CanvasItem) -> void:
	const NAME: String = "01_Palette填充"
	_check(NAME, dock._palette_list.item_count >= 5, "Palette 应列 ≥5 正式类型，实际 %d。" % dock._palette_list.item_count)


func _test_02_selection_and_rotate(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "02_选择与旋转"
	var mirror := preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn").instantiate()
	root.get_node("RuntimeObjects").add_child(mirror)
	dock.notify_selection_changed([root, mirror])
	_check(NAME, not dock._rotate_button.disabled, "选中正式对象后旋转入口应启用。")
	var orientation_before: int = mirror.orientation
	dock._on_rotate_selected()
	_check(NAME, mirror.orientation != orientation_before, "旋转应经 toggle_orientation 修改同一 orientation 字段。")
	dock._undo_redo.undo()
	_check(NAME, mirror.orientation == orientation_before, "旋转应可撤销（同一字段恢复）。")
	dock.notify_selection_changed([root])
	_check(NAME, dock._rotate_button.disabled, "取消选择后旋转入口应禁用（单方向/非正式对象同理）。")


func _test_03_place_via_dock(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "03_Dock放置路径"
	dock._palette_list.select(0)
	var objects_before: int = root.get_node("RuntimeObjects").get_child_count()
	dock._on_place_selected()
	_check(NAME, root.get_node("RuntimeObjects").get_child_count() == objects_before + 1,
		"放置后 RuntimeObjects 应 +1 节点（事务 commit 即执行）。")
	dock._on_undo()
	_check(NAME, root.get_node("RuntimeObjects").get_child_count() == objects_before,
		"撤销一步应移除放置节点。")


func _test_04_repair_stable_ids(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "04_修复StableID"
	var audit: Dictionary = dock._StableIdService.audit(root)
	_check(NAME, audit.missing >= 2, "level_ray_001 实例两个正式对象缺编辑期 ID（AF-07 前事实）。")
	dock._on_repair_stable_ids()
	var audit_after: Dictionary = dock._StableIdService.audit(root)
	_check(NAME, audit_after.missing == 0, "修复后应零缺失。")


func _test_05_play_gate(dock: CanvasItem, bridge, root: Node2D) -> void:
	const NAME: String = "05_运行前置校验"
	dock._on_play_current_level()
	_check(NAME, bridge.play_calls == 1, "合法关卡应放行 Play Current Level（桥收到 1 次调用）。")
	var legal: Node = root.get_node("LegalAreaLayer")
	legal.name = &"RenamedLayer"
	dock._on_play_current_level()
	_check(NAME, bridge.play_calls == 1, "破坏正式角色结构后应拒绝运行（校验 Gate，桥调用数不变）。")


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("level_authoring_dock_test: %d checks, %d failures" % [_checks, _failures.size()])
