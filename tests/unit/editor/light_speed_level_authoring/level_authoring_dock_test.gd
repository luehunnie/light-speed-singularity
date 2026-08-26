extends SceneTree

# AF-08/09 Level Authoring Dock 接线测试（headless 游戏模式；真实编辑器外观 = Human Gate）。
# AF-09 面板化后：Dock 为组合根，原按钮路径移入各面板——本测试经 dock.get_panel(...) 驱动
# 同等覆盖：面板装配与 Palette 填充、选择转发（旋转入口）、放置/撤销事务、修复 Stable ID、
# 非法关卡运行拒绝。由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。


const _Dock: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/level_authoring_dock.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
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
	var undo_redo := UndoRedo.new()
	dock.set_undo_redo(undo_redo)
	dock._ready()

	_test_01_palette_populated(dock)
	_test_02_selection_and_rotate(dock, root)
	_test_03_place_via_dock(dock, root, undo_redo)
	_test_04_repair_stable_ids(dock, root)
	_test_05_play_gate(dock, bridge, root)

	dock.free()
	root.free()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _palette(dock: CanvasItem) -> Object:
	return dock.get_panel("content_palette")


func _test_01_palette_populated(dock: CanvasItem) -> void:
	const NAME: String = "01_Palette填充"
	var palette: Object = _palette(dock)
	_check(NAME, palette.get("_list").item_count >= 5, "Palette 应列 ≥5 正式类型，实际 %d。" % palette.get("_list").item_count)


func _test_02_selection_and_rotate(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "02_选择与旋转"
	var mirror := preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn").instantiate()
	root.get_node("RuntimeObjects").add_child(mirror)
	dock.notify_selection_changed([root, mirror])
	var palette: Object = _palette(dock)
	_check(NAME, not palette.get("_rotate_button").disabled, "选中正式对象后旋转入口应启用。")
	var orientation_before: int = mirror.orientation
	palette.call("_on_rotate_selected")
	_check(NAME, mirror.orientation != orientation_before, "旋转应经 toggle_orientation 修改同一 orientation 字段。")
	dock._on_undo_pressed()
	_check(NAME, mirror.orientation == orientation_before, "旋转应可撤销（同一字段恢复）。")
	dock.notify_selection_changed([root])
	_check(NAME, palette.get("_rotate_button").disabled, "取消选择后旋转入口应禁用（单方向/非正式对象同理）。")


func _test_03_place_via_dock(dock: CanvasItem, root: Node2D, undo_redo: Object) -> void:
	const NAME: String = "03_Dock放置路径"
	var palette: Object = _palette(dock)
	palette.get("_list").select(0)
	var runtime_objects: Node = root.get_node("RuntimeObjects")
	var objects_before: int = runtime_objects.get_child_count()
	palette.call("_on_place_selected")
	_check(NAME, runtime_objects.get_child_count() == objects_before + 1,
		"放置后 RuntimeObjects 应 +1 节点（事务 commit 即执行）。")
	var placed: Node = runtime_objects.get_child(runtime_objects.get_child_count() - 1)
	_check(NAME, placed.get_parent() == runtime_objects, "placed 应为 RuntimeObjects 直属子节点。")
	_check(NAME, placed.owner == root, "放置事务应把 owner 设到 placed（非容器），0 帧即生效。")
	_check(NAME, not str(placed.get("stable_instance_id")).is_empty(),
		"放置节点应携带非空稳定实例 ID。")
	palette.call("_on_undo")
	_check(NAME, runtime_objects.get_child_count() == objects_before,
		"撤销一步应移除放置节点。")
	_check(NAME, runtime_objects.owner == root,
		"撤销不应改动容器 RuntimeObjects 自身 owner（undo_properties 错绑容器的回归）。")
	undo_redo.redo()
	_check(NAME, runtime_objects.get_child_count() == objects_before + 1,
		"重做应恢复放置节点。")
	_check(NAME, runtime_objects.get_child(runtime_objects.get_child_count() - 1) == placed
		and placed.owner == root, "重做后应为同一节点且 owner 仍为关卡根。")
	palette.call("_on_undo")
	_check(NAME, runtime_objects.get_child_count() == objects_before,
		"收尾撤销应还原树（不向后续用例泄漏放置节点）。")
	# 失败反馈：容器缺失时 Dock 日志必须写明原因，不得静默（先重选：place 后 refresh 重建列表会清空选择）。
	runtime_objects.name = "RuntimeObjectsHidden"
	palette.get("_list").select(0)
	palette.call("_on_place_selected")
	_check(NAME, dock.get_log_text().contains("放置失败：关卡缺少 RuntimeObjects"),
		"缺 RuntimeObjects 容器时放置失败应在 Dock 日志写明原因。")
	runtime_objects.name = "RuntimeObjects"
	# 撤销失败反馈：注入无 undo 能力的管理器须明确报错，不得静默（真管理器分支留真实编辑器验收）。
	dock.set_undo_redo(RefCounted.new())
	dock._on_undo_pressed()
	_check(NAME, dock.get_log_text().contains("撤销失败：撤销管理器无 undo 能力"),
		"无 undo 能力的撤销管理器应在 Dock 日志写明失败原因。")
	dock.set_undo_redo(undo_redo)


func _test_04_repair_stable_ids(dock: CanvasItem, root: Node2D) -> void:
	const NAME: String = "04_修复StableID"
	var audit: Dictionary = _StableIdService.audit(root)
	_check(NAME, audit.missing >= 2, "level_ray_001 实例两个正式对象缺编辑期 ID（AF-07 前事实）。")
	_palette(dock).call("_on_repair_stable_ids")
	var audit_after: Dictionary = _StableIdService.audit(root)
	_check(NAME, audit_after.missing == 0, "修复后应零缺失。")


func _test_05_play_gate(dock: CanvasItem, bridge, root: Node2D) -> void:
	const NAME: String = "05_运行前置校验"
	_palette(dock)  # 面板存在性（运行入口在关卡工具面板）。
	dock.get_panel("level_tools").call("_on_play_current_level")
	_check(NAME, bridge.play_calls == 1, "合法关卡应放行 Play Current Level（桥收到 1 次调用）。")
	var legal: Node = root.get_node("LegalAreaLayer")
	legal.name = &"RenamedLayer"
	dock.get_panel("level_tools").call("_on_play_current_level")
	_check(NAME, bridge.play_calls == 1, "破坏正式角色结构后应拒绝运行（校验 Gate，桥调用数不变）。")


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("level_authoring_dock_test: %d checks, %d failures" % [_checks, _failures.size()])
