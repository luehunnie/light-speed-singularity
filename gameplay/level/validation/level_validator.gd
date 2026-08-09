class_name LevelValidator
extends RefCounted

## 关卡四层结构与跨层规则校验器（D6-A v0）。
## 只读当前场景 TileMapLayer 事实，输出 LevelValidationResult。无状态：不跨调用保存场景节点或 used-cell 缓存。
## 不 push_error/push_warning；不修改场景。原始事实直接来自传入 level_root 子树的 TileMapLayer。
## 本批仅覆盖：六个正式角色结构识别（存在/类型/位置/重复）、逻辑 transform、TileSet 绑定，
##   以及 Terrain/Legal/Wall 跨层规则。不做 Emitter/Crystal/对象/VisualProfile/自动修复等（属 D6-B/C）。

const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")

# 正式 TileMapLayer 角色名（按绘制顺序：地形→墙→合法区→装饰）。
const _TILE_ROLES: Array = ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]
# 正式 Node2D 角色名。
const _NODE2D_ROLES: Array = ["RuntimeObjects", "LightPathLayer"]


## 冻结校验入口。输入：关卡根 Node。输出：确定性排序后的 LevelValidationResult。
## 无副作用：不改场景、不缓存。root 为空或非 Node2D 时仅返回 level_root_invalid 单条结果。
func validate(level_root: Node) -> _LevelValidationResult:
	var issues: Array = []
	if level_root == null or not (level_root is Node2D):
		_add_struct(issues, _err(), &"level_root_invalid", "关卡根为空或非 Node2D。", NodePath())
		return _LevelValidationResult.new(issues)
	var root: Node2D = level_root
	var direct: Dictionary = _collect_direct_children(root)
	var by_name: Dictionary = _collect_descendants_by_name(root)
	var valid_direct: Dictionary = {}
	_validate_roles(root, direct, by_name, valid_direct, issues)
	_validate_unexpected_tile_layers(root, by_name, issues)
	_validate_logic_transforms(root, valid_direct, issues)
	_validate_tilesets(root, valid_direct, issues)
	_validate_layer_data(root, valid_direct, issues)
	return _LevelValidationResult.new(issues)


# ===== 结构识别 =====

## 校验六个正式角色：直属存在性/类型/位置/重复，并将“存在且类型正确”的直属节点记入 valid_direct 供后续检查。
func _validate_roles(
		root: Node2D,
		direct: Dictionary,
		by_name: Dictionary,
		valid_direct: Dictionary,
		issues: Array
) -> void:
	for role in _all_roles():
		var node: Node = direct.get(role, null)
		var named: Array = by_name.get(role, [])
		if node != null:
			if _is_correct_type(node, role):
				valid_direct[role] = node
			else:
				_add_struct(issues, _err(), &"required_node_type_invalid",
					"角色 %s 直属节点类型不正确。" % role, root.get_path_to(node))
			for other in named:
				if other != node:
					_add_struct(issues, _err(), &"duplicate_role_node",
						"角色 %s 出现额外同名节点。" % role, root.get_path_to(other))
		elif not named.is_empty():
			# 无直属角色但全树存在 N>=1 同名候选：对一个确定性首选报 misplaced，其余各报 duplicate。
			# 首选按相对 NodePath 排序后取第一项（不依赖遍历顺序）；节点路径唯一，同一节点不兼报 misplaced+duplicate。
			var path_to_node: Dictionary = {}
			var paths: Array = []
			for c in named:
				var p: String = str(root.get_path_to(c))
				path_to_node[p] = c
				paths.append(p)
			paths.sort()
			_add_struct(issues, _err(), &"required_node_misplaced",
				"角色 %s 未作为根直属节点。" % role, root.get_path_to(path_to_node[paths[0]]))
			for i in range(1, paths.size()):
				_add_struct(issues, _err(), &"duplicate_role_node",
					"角色 %s 出现额外同名节点。" % role, root.get_path_to(path_to_node[paths[i]]))
		else:
			_add_struct(issues, _err(), &"required_node_missing",
				"缺少正式角色 %s。" % role, NodePath())


## 关卡子树中任意名称不属于正式角色名的 TileMapLayer → unexpected_tile_layer（WARNING）。
## 扫描整个 level_root 子树（含嵌套），node_path 指向实际额外层；正式角色名的 TileMapLayer 不在此报
##   （由 required_node_misplaced / duplicate_role_node 负责）。不判定 level_root 自身为 TileMapLayer 的
##   特殊情况：合法 root 已要求 Node2D 关卡根，不为 root 创造额外语义。
func _validate_unexpected_tile_layers(root: Node2D, by_name: Dictionary, issues: Array) -> void:
	var formal: Dictionary = {}
	for role in _all_roles():
		formal[role] = true
	for role_name in by_name:
		if formal.has(role_name):
			continue
		var nodes: Array = by_name[role_name]
		for child in nodes:
			if child is TileMapLayer:
				_add_struct(issues, _warn(), &"unexpected_tile_layer",
					"存在非正式角色名的 TileMapLayer：%s。" % role_name, root.get_path_to(child))


## 四个逻辑 TileMapLayer 与 RuntimeObjects 必须为零位移/零旋转/单位缩放。
func _validate_logic_transforms(root: Node2D, valid_direct: Dictionary, issues: Array) -> void:
	for role in _TILE_ROLES + ["RuntimeObjects"]:
		var node: Node = valid_direct.get(role, null)
		if node == null:
			continue
		if not _is_identity_transform(node as Node2D):
			_add_struct(issues, _err(), &"logic_transform_invalid",
				"角色 %s 的逻辑 transform 必须为零位移/零旋转/单位缩放。" % role, root.get_path_to(node))


## 四个正式 TileMapLayer 必须绑定非空 TileSet（不锁死资源路径）。
func _validate_tilesets(root: Node2D, valid_direct: Dictionary, issues: Array) -> void:
	for role in _TILE_ROLES:
		var node: Node = valid_direct.get(role, null)
		if node == null:
			continue
		var layer: TileMapLayer = node as TileMapLayer
		if layer.tile_set == null:
			_add_struct(issues, _err(), &"tileset_missing",
				"角色 %s 的 TileSet 未绑定。" % role, root.get_path_to(node))


# ===== 四层数据规则 =====

## Terrain/Legal/Wall 跨层规则。每个正式逻辑层最多读一次 used cells；Decoration 绝不参与逻辑。
func _validate_layer_data(root: Node2D, valid_direct: Dictionary, issues: Array) -> void:
	# 缺层或缺 TileSet 返回 null，跳过该层逻辑（结构/TileSet 问题已另行上报）。
	var terrain_cells: Variant = _read_layer_cells(valid_direct.get("TerrainLayer", null))
	var wall_cells: Variant = _read_layer_cells(valid_direct.get("WallLayer", null))
	var legal_cells: Variant = _read_layer_cells(valid_direct.get("LegalAreaLayer", null))
	var terrain_node: Node = valid_direct.get("TerrainLayer", null)
	var wall_node: Node = valid_direct.get("WallLayer", null)
	var legal_node: Node = valid_direct.get("LegalAreaLayer", null)
	# Terrain 空 → ERROR。
	if terrain_cells != null and (terrain_cells as Array).is_empty():
		_add_struct(issues, _err(), &"terrain_empty",
			"TerrainLayer 未放置任何地形格。", root.get_path_to(terrain_node))
	# Legal：空 → WARNING；每格越界 Terrain → ERROR；每格与 Wall 重叠 → WARNING。
	if legal_cells != null:
		var legal_arr: Array = legal_cells as Array
		if legal_arr.is_empty():
			_add_struct(issues, _warn(), &"legal_area_empty",
				"LegalAreaLayer 未放置任何合法区格。", root.get_path_to(legal_node))
		else:
			var terrain_set: Dictionary = _to_set(terrain_cells)
			var wall_set: Dictionary = _to_set(wall_cells)
			for c in legal_arr:
				if terrain_cells != null and not terrain_set.has(c):
					_add_cell(issues, _err(), &"legal_outside_terrain",
						"LegalArea 格 %s 位于 Terrain 之外。" % [c], root.get_path_to(legal_node), c)
				if wall_cells != null and wall_set.has(c):
					_add_cell(issues, _warn(), &"legal_wall_overlap",
						"LegalArea 格 %s 与 Wall 重叠。" % [c], root.get_path_to(legal_node), c)
	# Wall：每格越界 Terrain → ERROR（Wall 为空合法，不报）。
	if wall_cells != null:
		var terrain_set: Dictionary = _to_set(terrain_cells)
		for c in (wall_cells as Array):
			if terrain_cells != null and not terrain_set.has(c):
				_add_cell(issues, _err(), &"wall_outside_terrain",
					"Wall 格 %s 位于 Terrain 之外。" % [c], root.get_path_to(wall_node), c)


# ===== 辅助 =====

## 读一次 TileMapLayer.used_cells；节点非 TileMapLayer 或缺 TileSet 返回 null（跳过该层逻辑）。
func _read_layer_cells(node: Node) -> Variant:
	if node == null or not (node is TileMapLayer):
		return null
	var layer: TileMapLayer = node
	if layer.tile_set == null:
		return null
	return layer.get_used_cells()


## 将 used cells 数组转为集合用于成员查询；入参为 null 返回空集合。
func _to_set(cells: Variant) -> Dictionary:
	var s: Dictionary = {}
	if cells == null:
		return s
	for c in cells:
		s[c] = true
	return s


## 直属子节点按 String 名索引（键统一 String，避免 StringName/String 哈希错配）。
func _collect_direct_children(root: Node) -> Dictionary:
	var out: Dictionary = {}
	for c in root.get_children():
		out[String(c.name)] = c
	return out


## 全树后代（不含根）按 String 名分组，供 misplaced/duplicate 判定。
func _collect_descendants_by_name(root: Node) -> Dictionary:
	var out: Dictionary = {}
	_gather_descendants(root, out)
	return out


func _gather_descendants(node: Node, out: Dictionary) -> void:
	for c in node.get_children():
		var key: String = String(c.name)
		if not out.has(key):
			out[key] = []
		(out[key] as Array).append(c)
		_gather_descendants(c, out)


## 角色是否为直属节点正确类型：TileMapLayer 角色须 TileMapLayer，Node2D 角色须 Node2D。
func _is_correct_type(node: Node, role: String) -> bool:
	if _TILE_ROLES.has(role):
		return node is TileMapLayer
	return node is Node2D


## 逻辑 transform 是否为单位变换（零位移、零旋转、单位缩放），用 Godot 近似比较。
func _is_identity_transform(node: Node2D) -> bool:
	return (
		is_zero_approx(node.position.x) and is_zero_approx(node.position.y)
		and is_zero_approx(node.rotation)
		and is_equal_approx(node.scale.x, 1.0) and is_equal_approx(node.scale.y, 1.0)
	)


## 全部正式角色名（TileMapLayer + Node2D）。
func _all_roles() -> Array:
	return _TILE_ROLES + _NODE2D_ROLES


func _err() -> int:
	return _LevelValidationIssue.Severity.ERROR


func _warn() -> int:
	return _LevelValidationIssue.Severity.WARNING


## 追加结构级 issue（has_cell=false）。
func _add_struct(issues: Array, severity: int, code: StringName, message: String, node_path: NodePath) -> void:
	issues.append(_LevelValidationIssue.new(severity, code, message, node_path, false))


## 追加 cell 级 issue（has_cell=true，object_id 为空）。
func _add_cell(issues: Array, severity: int, code: StringName, message: String, node_path: NodePath, cell: Vector2i) -> void:
	issues.append(_LevelValidationIssue.new(severity, code, message, node_path, true, cell))
