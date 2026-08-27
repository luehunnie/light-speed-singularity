@tool
extends EditorPlugin

# AF-08 Level Authoring Assist 插件（Guide §2.3）：轻量关卡内容辅助包唯一 EditorPlugin。
# 职责：注册 Dock、转发 EditorSelection、2D 占格 / 合法性 / 失败原因 Overlay（Guide §10.1）、
#   Play Current Level 编辑器桥（Guide §89：保存 → Preflight → 交给统一 LevelRuntimeHost，环境变量注入当前关卡路径）。
# 边界：不替代 Godot 2D / Inspector / TileMap；全部业务逻辑在 authoring/ 服务内（本文件只做编辑器接线与绘制）。


const _LevelAuthoringDock: GDScript = preload(
	"res://addons/light_speed_level_authoring/ui/level_authoring_dock.gd"
)
const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _PaletteService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/palette_service.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _GridMetrics: GDScript = preload("res://gameplay/grid/grid_metrics.gd")
# 正式对象两类基脚本（与 StableIdService 口径一致）。
const _PlaceableTokenScript: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _GridPlacedObjectScript: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)

# Play Current Level 环境变量（与 LevelRuntimeHost.PLAY_CURRENT_LEVEL_ENV 同名冻结）。
const PLAY_CURRENT_LEVEL_ENV: String = "LIGHT_SPEED_PLAY_CURRENT_LEVEL"
# 统一 Host Scene（Guide §4.3：不建第二套 Runtime）。
const HOST_SCENE_PATH: String = "res://gameplay/runtime/level_runtime_host.tscn"

# Overlay 颜色（合法 / 非法；只影响 Editor 视口，不落盘）。
const _COLOR_VALID: Color = Color(0.25, 1.0, 0.4, 0.30)
const _COLOR_INVALID: Color = Color(1.0, 0.25, 0.2, 0.38)

# Dock 页签中文标题（仅改用户可见名，不扩大功能）。
const DOCK_TITLE: String = "关卡编辑器"

var _dock: Control = null
var _editor_selection: EditorSelection = null
var _last_selection_transform_hash: int = -1


func _enter_tree() -> void:
	_dock = _LevelAuthoringDock.new()
	_dock.name = DOCK_TITLE
	_dock.set_editor_bridge(_EditorBridge.new())
	_dock.set_undo_redo(get_undo_redo())
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	_editor_selection = get_editor_interface().get_selection()
	_editor_selection.selection_changed.connect(_on_selection_changed)


func _exit_tree() -> void:
	if _editor_selection != null:
		_editor_selection.selection_changed.disconnect(_on_selection_changed)
		_editor_selection = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _on_selection_changed() -> void:
	if _dock == null or _editor_selection == null:
		return
	var selected: Array = _editor_selection.get_selected_nodes()
	_dock.notify_selection_changed(selected)
	_last_selection_transform_hash = -1
	update_overlays()


# 拖拽跟随：编辑器拖动节点不发出独立信号，_process 低成本哈希检测位置变化后请求重绘 Overlay。
func _process(_delta: float) -> void:
	if _dock == null or _editor_selection == null:
		return
	var hash_value := _selection_transform_hash()
	if hash_value != _last_selection_transform_hash:
		_last_selection_transform_hash = hash_value
		update_overlays()


func _selection_transform_hash() -> int:
	var hash_value := 0
	for node: Variant in _editor_selection.get_selected_nodes():
		if node is Node2D:
			var positioned: Node2D = node
			hash_value = hash(hash_value ^ hash(positioned.global_position))
	return hash_value


# 2D Overlay（Guide §10.1）：为每个选中的正式对象画真实占格 + 合法/非法 + 失败原因。
# 查询链复用统一 Placement Query（Editor/Runtime/Validator 同一语义源）；每次重绘按当前事实重建（只读、无缓存失效问题）。
func _forward_canvas_draw_over_viewport(overlay: Control) -> void:
	if _editor_selection == null:
		return
	var root := get_editor_interface().get_edited_scene_root()
	if not (root is Node2D):
		return
	var query := _EditorPlacementQuery.new()
	if not query.build(root):
		return
	var registry = _PaletteService.build_registry()
	var root_transform_inverse: Transform2D = (root as Node2D).get_global_transform().affine_inverse()
	var view_transform: Transform2D = overlay.get_viewport_transform()
	var font := overlay.get_theme_default_font()
	var font_size := overlay.get_theme_default_font_size()
	var cell_size: Vector2 = _GridMetrics.SINGLE_CELL_WORLD_SIZE
	for node: Variant in _editor_selection.get_selected_nodes():
		if not (node is Node2D) or not _matches_formal_scripts(node):
			continue
		var formal: Node2D = node
		var local_position: Vector2 = root_transform_inverse * formal.get_global_transform().origin
		var anchor: Vector2i = _GridCoordinateRules.world_to_cell(local_position)
		var cells: Array[Vector2i] = []
		for offset: Vector2i in _footprint_offsets_of(formal, registry):
			cells.append(anchor + offset)
		var result: Variant = query.evaluate(cells, formal)
		var color := _COLOR_VALID if result.is_allowed() else _COLOR_INVALID
		for cell: Vector2i in cells:
			var world_rect := Rect2(_GridCoordinateRules.cell_to_world(cell), cell_size)
			overlay.draw_rect(view_transform * world_rect, color, false, 2.0)
			overlay.draw_rect(view_transform * world_rect, Color(color.r, color.g, color.b, color.a * 0.4))
		if not result.is_allowed():
			var reasons := PackedStringArray()
			for issue: StringName in result.issues:
				reasons.append(String(issue))
			var label_position: Vector2 = view_transform * (local_position + Vector2(0, -cell_size.y * 0.5))
			overlay.draw_string(font, label_position, "；".join(reasons),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _COLOR_INVALID)


# 经 Formal Declaration 查节点类型足迹（scene 资源路径匹配；未声明回退单格）。
func _footprint_offsets_of(node: Node2D, registry) -> Array[Vector2i]:
	if registry != null and not node.scene_file_path.is_empty():
		for type_id: StringName in registry.get_type_ids():
			var definition: Variant = registry.get_definition(type_id)
			if definition.scene != null and definition.scene.resource_path == node.scene_file_path:
				var declared: Array[Vector2i] = definition.static_footprint_offsets
				if not declared.is_empty():
					return declared
	return [Vector2i.ZERO]


func _matches_formal_scripts(candidate: Variant) -> bool:
	var node: Node2D = candidate
	return node is _PlaceableTokenScript or node is _GridPlacedObjectScript


# ===== Play Current Level 编辑器桥（Guide §89 流程）=====

# 编辑器能力桥：Dock 只依赖此对象（headless 测试注入替身）。
class _EditorBridge extends RefCounted:
	func open_scene(path: String) -> void:
		EditorInterface.open_scene_from_path(path)


	func get_current_scene_path() -> String:
		return EditorInterface.get_edited_scene_root().scene_file_path


	func get_edited_level_root() -> Node2D:
		var root: Variant = EditorInterface.get_edited_scene_root()
		return root if root is Node2D else null


	# Guide §89：保存 / 准备 → Preflight（Dock 已做）→ 交给统一 Host。
	# 环境变量注入当前关卡路径；2 秒后自清（子进程已在启动时继承，防后续普通 F6 残留重放旧关卡）。
	func play_current_level() -> void:
		var scene_path := EditorInterface.get_edited_scene_root().scene_file_path
		if scene_path.is_empty():
			return
		EditorInterface.save_scene()
		OS.set_environment(PLAY_CURRENT_LEVEL_ENV, scene_path)
		EditorInterface.play_custom_scene(HOST_SCENE_PATH)
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.create_timer(2.0).timeout.connect(
				func() -> void: OS.unset_environment("LIGHT_SPEED_PLAY_CURRENT_LEVEL"))
