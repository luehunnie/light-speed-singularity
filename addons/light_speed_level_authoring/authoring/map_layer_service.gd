@tool
extends RefCounted

# AF-08 Map Layer Assist 服务（Guide §23.1/§23.2/§24/§94）：四层地图的显式辅助操作与快照。
# 只做 Guide 冻结的显式操作：Initialize LegalArea from Terrain、清理 LegalArea 越界、
# 清理 Wall 越界、清理 Wall∩LegalArea 重叠；不静默同步、不做自动修复（修复由 Validator 报告 + 作者显式触发）。
# Undo：所有操作先 snapshot_layer 取照，再 apply，由调用方把 before/after 包进同一编辑事务（原子）。
# 标准绘制仍由 Godot TileMap 编辑器承担（Guide §94：不做第二个地图编辑器）。


const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)
const _LevelValidator: GDScript = preload(
	"res://gameplay/level/validation/level_validator.gd"
)


# 层快照：cell → {source: int, atlas: Vector2i}；restore 后与拍照时刻逐格一致（含清除后补回）。
static func snapshot_layer(layer: TileMapLayer) -> Dictionary:
	var snapshot: Dictionary = {}
	for cell: Vector2i in layer.get_used_cells():
		snapshot[cell] = {
			"source": layer.get_cell_source_id(cell),
			"atlas": layer.get_cell_atlas_coords(cell),
		}
	return snapshot


# 按快照恢复一层：先清除快照外全部格，再逐格写回 source/atlas（与拍照时刻一致）。
static func restore_layer(layer: TileMapLayer, snapshot: Dictionary) -> void:
	for cell: Vector2i in layer.get_used_cells():
		if not snapshot.has(cell):
			layer.erase_cell(cell)
	for cell: Variant in snapshot:
		var entry: Dictionary = snapshot[cell]
		layer.set_cell(cell, entry.get("source", 0), entry.get("atlas", Vector2i.ZERO))


# Initialize LegalArea from Terrain（Guide §23.1）：为无 LegalArea tile 的 Terrain 格补 LegalArea tile。
# [br]写回 tile 取该层既有首个 tile 的 source/atlas，层为空时回退 source 0 / atlas (0,0)。
# [br]返回新增格列表（空列表 = LegalArea 已覆盖全部 Terrain）。不删除任何既有 LegalArea 格。
static func initialize_legal_from_terrain(level_root: Node2D) -> Array[Vector2i]:
	var terrain: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_TERRAIN)
	var legal: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_LEGAL)
	if terrain == null or legal == null:
		push_error("MapLayerService：Terrain/LegalArea 层缺失，拒绝初始化。")
		return []
	var source := 0
	var atlas := Vector2i.ZERO
	var used: Array[Vector2i] = legal.get_used_cells()
	if not used.is_empty():
		source = legal.get_cell_source_id(used[0])
		atlas = legal.get_cell_atlas_coords(used[0])
	var added: Array[Vector2i] = []
	for cell: Vector2i in terrain.get_used_cells():
		if legal.get_cell_source_id(cell) == -1:
			legal.set_cell(cell, source, atlas)
			added.append(cell)
	return added


# 找出 LegalArea 落在 Terrain 外的格（Guide §23.2：Editor 立即提示 + 显式一键清理）。
static func find_legal_outside_terrain(level_root: Node2D) -> Array[Vector2i]:
	return _find_outside(level_root, _EditorPlacementQuery.ROLE_LEGAL)


# 找出 Wall 落在 Terrain 外的格（Guide §24：Wall 不应画到 Terrain 外）。
static func find_wall_outside_terrain(level_root: Node2D) -> Array[Vector2i]:
	return _find_outside(level_root, _EditorPlacementQuery.ROLE_WALL)


# 找出 Wall 与 LegalArea 重叠格（Guide §24：重叠须显式清理，不静默修）。
static func find_wall_on_legal(level_root: Node2D) -> Array[Vector2i]:
	var wall: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_WALL)
	var legal: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_LEGAL)
	if wall == null or legal == null:
		return []
	var overlap: Array[Vector2i] = []
	for cell: Vector2i in legal.get_used_cells():
		if wall.get_cell_source_id(cell) != -1:
			overlap.append(cell)
	return overlap


# 清理 LegalArea 越界格；返回实际清除列表（供撤销与结果提示）。
static func clean_legal_outside_terrain(level_root: Node2D) -> Array[Vector2i]:
	return _erase_in(_find_role(level_root, _EditorPlacementQuery.ROLE_LEGAL), find_legal_outside_terrain(level_root))


# 清理 Wall 越界格；返回实际清除列表。
static func clean_wall_outside_terrain(level_root: Node2D) -> Array[Vector2i]:
	return _erase_in(_find_role(level_root, _EditorPlacementQuery.ROLE_WALL), find_wall_outside_terrain(level_root))


# 清理 Wall∩LegalArea 重叠中的 LegalArea 侧（保留 Wall 事实）；返回实际清除列表。
static func clean_legal_on_wall(level_root: Node2D) -> Array[Vector2i]:
	return _erase_in(_find_role(level_root, _EditorPlacementQuery.ROLE_LEGAL), find_wall_on_legal(level_root))


# 常用检查：复用统一 LevelValidator（Editor 简短提示口径；完整列表见 Validator 面板域）。
# [br]返回 {valid: bool, errors: int, warnings: int, first_messages: PackedStringArray（前 5 条）}。
static func collect_issues(level_root: Node) -> Dictionary:
	var result: Variant = _LevelValidator.new().validate(level_root)
	var issues: Array = result.get_issues()
	var errors := 0
	var warnings := 0
	var first: PackedStringArray = PackedStringArray()
	for issue: Variant in issues:
		if issue.get_severity() == 0:
			errors += 1
		else:
			warnings += 1
		if first.size() < 5:
			first.append(issue.get_message())
	return {"valid": result.is_valid(), "errors": errors, "warnings": warnings, "first_messages": first}


static func _find_role(level_root: Node2D, role: String) -> TileMapLayer:
	return _EditorPlacementQuery.find_layer(level_root, role)


# 找某层落在 Terrain 外的格。
static func _find_outside(level_root: Node2D, role: String) -> Array[Vector2i]:
	var terrain: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_TERRAIN)
	var layer: TileMapLayer = _find_role(level_root, role)
	if terrain == null or layer == null:
		return []
	var outside: Array[Vector2i] = []
	for cell: Vector2i in layer.get_used_cells():
		if terrain.get_cell_source_id(cell) == -1:
			outside.append(cell)
	return outside


# 在指定层逐格清除；返回实际清除列表。
static func _erase_in(layer: TileMapLayer, cells: Array[Vector2i]) -> Array[Vector2i]:
	if layer == null:
		return []
	var erased: Array[Vector2i] = []
	for cell: Vector2i in cells:
		if layer.get_cell_source_id(cell) != -1:
			layer.erase_cell(cell)
			erased.append(cell)
	return erased
