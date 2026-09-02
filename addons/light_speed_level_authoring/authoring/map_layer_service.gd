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


# ===== D-04 正式墙体对象规划 =====
# 墙体的正式作者入口是 Content Palette（wall 域定义 → GridPlacedObject 派生墙节点）；
# 本服务仅保留"一键包裹全边界"的纯数据规划（cells + 样式 token），节点创建由面板经
# PaletteService.place_wall_at 编辑事务完成（输出为正式墙对象，非匿名 TileMap 格）。
# D-03 的 12 样式网格 / 6 盖章按钮 / 单格涂刷 / 占位迁移（视口点击武装流）已删除：
# 被 Human 否决的地图辅助主工作流不再保留，避免与 Palette 双入口重叠。

# 边界自动样式：按格四邻的 LegalArea 事实选直墙/外角(large_bend)/内角(small_bend)。
# 1 邻=贴该邻边的直墙；2 对邻=轴向直墙（N/S→上、W/E→左，确定性约定）；2 邻邻接=外角（贴两邻边）；
# 3 邻=内角（小角饰置缺失边顺时针端角：缺N→右上/缺E→右下/缺S→左下/缺W→左上，固定约定、可逐格重样式）；
# 4 邻=右下内角；0 邻=默认直墙上（确定性约定）。
# 返回样式 token（与 gameplay/content/wall/wall_style_catalog.gd STYLE_ORDER 冻结 token 一致）。
static func resolve_boundary_style(legal_n: bool, legal_s: bool, legal_w: bool, legal_e: bool) -> String:
	var count := (1 if legal_n else 0) + (1 if legal_s else 0) + (1 if legal_w else 0) + (1 if legal_e else 0)
	if count == 1:
		if legal_n:
			return "straight_up"
		if legal_s:
			return "straight_down"
		if legal_w:
			return "straight_left"
		return "straight_right"
	if count == 2:
		if legal_n and legal_s:
			return "straight_up"
		if legal_w and legal_e:
			return "straight_left"
		if legal_n and legal_w:
			return "large_bend_lu"
		if legal_n and legal_e:
			return "large_bend_ru"
		if legal_s and legal_w:
			return "large_bend_ld"
		return "large_bend_rd"
	if count == 3:
		if not legal_n:
			return "small_bend_tr"
		if not legal_e:
			return "small_bend_br"
		if not legal_s:
			return "small_bend_bl"
		return "small_bend_tl"
	if count == 4:
		return "small_bend_br"
	# 0 邻=默认直墙上（确定性冻结约定；token 与 wall_style_catalog STYLE_ORDER 一致）。
	return "straight_up"


# 全边界一键包裹规划（纯数据）：LegalArea 外侧相邻（4 邻）Terrain 格=包裹候选；
# 逐格局部判定天然覆盖多区域与洞口；不消耗 LegalArea。第一版只做全边界，不做局部框选。
# D-04 起 cells 的落点为正式单格墙对象（wall_block 定义 + 样式 token），不再是 WallLayer tile 写入。
static func plan_wall_wrap(level_root: Node2D) -> Dictionary:
	var legal: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_LEGAL)
	var terrain: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_TERRAIN)
	if legal == null or terrain == null:
		return {"ok": false, "reasons": PackedStringArray(["缺少 LegalArea / Terrain 层，拒绝包裹。"]), "cells": []}
	var candidates: Dictionary = {}
	for cell: Vector2i in legal.get_used_cells():
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var ring: Vector2i = cell + offset
			if legal.get_cell_source_id(ring) == -1 and terrain.get_cell_source_id(ring) != -1:
				candidates[ring] = true
	var cells: Array = []
	for cell: Variant in candidates:
		var wrapped: Vector2i = cell
		cells.append({"cell": wrapped, "style": resolve_boundary_style(
			legal.get_cell_source_id(wrapped + Vector2i(0, -1)) != -1,
			legal.get_cell_source_id(wrapped + Vector2i(0, 1)) != -1,
			legal.get_cell_source_id(wrapped + Vector2i(-1, 0)) != -1,
			legal.get_cell_source_id(wrapped + Vector2i(1, 0)) != -1)})
	return _finish_plan(level_root, cells)


# 汇总规划结果：合法性校验通过→ok 规划；否则整次拒绝（零部分写入）。
static func _finish_plan(level_root: Node2D, cells: Array) -> Dictionary:
	var reasons: PackedStringArray = _wall_cell_rejections(level_root, cells)
	if not reasons.is_empty():
		return {"ok": false, "reasons": reasons, "cells": []}
	return {"ok": true, "reasons": PackedStringArray(), "cells": cells}


# 墙格合法性（D-04 正式墙对象规则：Terrain 内 + 非 WallLayer 旧墙格 + 无正式对象占用 → 可放置；
# 任一格非法整次拒绝。不再拒绝 LegalArea 格——墙对象可与 LegalArea 同格（Validator 警告级），与
# 迁移保留的 (5,3) 内侧墙口径一致）。
static func _wall_cell_rejections(level_root: Node2D, cells: Array) -> PackedStringArray:
	var terrain: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_TERRAIN)
	var wall: TileMapLayer = _find_role(level_root, _EditorPlacementQuery.ROLE_WALL)
	var occupied: Array[Vector2i] = _EditorPlacementQuery.collect_occupied_cells(level_root)
	var reasons: PackedStringArray = PackedStringArray()
	for entry: Variant in cells:
		var cell: Vector2i = (entry as Dictionary)["cell"]
		if terrain == null or terrain.get_cell_source_id(cell) == -1:
			reasons.append("格 %s 越界/非 Terrain。" % [cell])
		elif wall != null and wall.get_cell_source_id(cell) != -1:
			reasons.append("格 %s 已有 WallLayer 旧墙格（兼容输入，拒绝重复墙体数据）。" % [cell])
		elif occupied.has(cell):
			reasons.append("格 %s 被正式对象占用。" % [cell])
	return reasons
