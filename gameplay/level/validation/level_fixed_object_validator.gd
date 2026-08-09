class_name LevelFixedObjectValidator
extends RefCounted

## 固定对象校验器（D6-B v0）：只读 level_root 子树中的真实 EmitterConfigNode / BasicCrystal，
## 结合 LevelValidator 交来的 Terrain / Wall 局部事实，输出固定对象 Issue。
## 由 LevelValidator 在 validate() 末尾调用；返回的 Issue 未排序，由 LevelValidator 合并后统一在
##   LevelValidationResult 构造时确定性排序，故本类不自行排序。
## 无状态：不跨调用保存场景节点、used-cell 缓存或对象登记；不 push_error / push_warning；不修改场景；
##   不 round / snap / 改写 position。
## 原始事实来源：固定对象直接读取 level_root 子树（节点 position、crystal_id、default_light_form、
##   方向枚举、visual_profile、直属 VisualView），Terrain / Wall used cells 由 LevelValidator 读一次后传入。
##   不使用 OccupancyRegistry / LevelObjectRegistry / LevelWorldQuery / Snapshot 作为原始事实。
## 位置契约：position → cell 一律经正式 GridCoordinateRules.world_to_cell / cell_to_world 派生，
##   容差 0.001 px（与冻结规则一致）；非有限 position 不派生 cell。

const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")

## position 与目标格中心任一轴偏差上限（世界像素）；超过即 fixed_object_position_off_grid。
const _OFF_GRID_TOLERANCE: float = 0.001
## 正式 Emitter 在关卡中的预期相对路径（RuntimeObjects 直属、名为 Emitter）。
const _EMITTER_EXPECTED_PATH: NodePath = NodePath("RuntimeObjects/Emitter")
## RuntimeObjects 角色路径（与 LevelValidator 正式 Node2D 角色一致）；get_node_or_null 需 NodePath。
const _RUNTIME_OBJECTS_PATH: NodePath = NodePath("RuntimeObjects")
## Crystal 必需的直属视觉子节点路径（与 BasicCrystal 的 @onready $VisualView 契约一致）。
const _CRYSTAL_VISUAL_PATH: NodePath = NodePath("VisualView")


## 校验固定对象入口。terrain_cells / wall_cells 为 Variant：null 表示该层不可读（缺层 / 错型 / 缺 TileSet，
## 已由 D6-A 结构检查另行上报），对应检查跳过；Array 表示该层 used cells（可为空）。
## 返回未排序 Issue 数组（可能为空）；调用方负责合并与排序。无副作用：不改场景、不缓存。
func validate_fixed_objects(level_root: Node2D, terrain_cells: Variant, wall_cells: Variant) -> Array:
	var issues: Array = []
	var runtime_objects: Node = level_root.get_node_or_null(_RUNTIME_OBJECTS_PATH)
	var emitters: Array = _find_instances(level_root, _EmitterConfigNode)
	var crystals: Array = _find_instances(level_root, _BasicCrystal)
	_validate_emitter_count(emitters, issues)
	_validate_crystal_count(crystals, issues)
	# 仅唯一 Emitter 时做 per-emitter 检查；数量 != 1 已由 emitter_count_invalid 覆盖，避免对多余 Emitter 重复报位/形态。
	if emitters.size() == 1:
		_validate_single_emitter(emitters[0], level_root, runtime_objects, terrain_cells, wall_cells, issues)
	# Crystal：即使多水晶也继续逐个扫描（multiple_crystals_unsupported 已另行上报）。
	_validate_crystal_ids(crystals, level_root, issues)
	for crystal in crystals:
		_validate_crystal(crystal, level_root, runtime_objects, terrain_cells, wall_cells, issues)
	_validate_overlap(emitters, crystals, level_root, issues)
	return issues


# ===== Emitter =====

## Emitter 数量：全场 EmitterConfigNode 总数必须为 1，否则 emitter_count_invalid。
func _validate_emitter_count(emitters: Array, issues: Array) -> void:
	if emitters.size() != 1:
		issues.append(_issue_struct(_err(), &"emitter_count_invalid",
			"全场 EmitterConfigNode 数量必须为 1，实际 %d。" % emitters.size(), NodePath()))


## 唯一 Emitter 的路径 / 直属父 / 共同位置 / 形态 / 方向 / 运行支持 / 视觉资源检查。
func _validate_single_emitter(
		emitter: _EmitterConfigNode,
		root: Node2D,
		runtime_objects: Node,
		terrain_cells: Variant,
		wall_cells: Variant,
		issues: Array
) -> void:
	# Emitter 无 stable ID：object_id 一律为空，不使用 Node.name。
	var path: NodePath = root.get_path_to(emitter)
	# 路径：唯一正式 Emitter 必须位于 RuntimeObjects/Emitter。
	if path != _EMITTER_EXPECTED_PATH:
		issues.append(_issue_struct(_err(), &"emitter_path_invalid",
			"唯一正式 Emitter 必须位于 RuntimeObjects/Emitter，实际路径 %s。" % str(path), path))
	# 直属父：必须为 RuntimeObjects 直属子节点。
	if not _is_direct_child_of(emitter, runtime_objects):
		issues.append(_issue_struct(_err(), &"fixed_object_parent_invalid",
			"Emitter 必须为 RuntimeObjects 直属子节点。", path))
	# 共同位置规则（object_id 空）。
	_check_object_position(emitter, path, &"", terrain_cells, wall_cells, issues)
	# default_light_form 枚举域（防御：真实 setter 拒绝非法值，正常运行不会命中）。
	var form: int = emitter.default_light_form
	if not _is_valid_light_form(form):
		issues.append(_issue_struct(_err(), &"emitter_light_form_invalid",
			"default_light_form 枚举域非法：%d。" % form, path))
	# 方向枚举域（按当前形态取对应方向枚举；防御：真实 setter 拒绝非法值）。
	if form == _EmitterConfigNode.LightForm.RAY:
		if not _is_valid_ray_direction(emitter.ray_default_direction):
			issues.append(_issue_struct(_err(), &"emitter_direction_invalid",
				"RAY 方向枚举域非法：%d。" % emitter.ray_default_direction, path))
	elif form == _EmitterConfigNode.LightForm.PARTICLE:
		if not _is_valid_particle_direction(emitter.particle_default_direction):
			issues.append(_issue_struct(_err(), &"emitter_direction_invalid",
				"PARTICLE 方向枚举域非法：%d。" % emitter.particle_default_direction, path))
	# 默认形态运行支持：PARTICLE 虽为合法枚举，但当前运行未正式支持。
	if not emitter.is_runtime_form_supported():
		issues.append(_issue_struct(_err(), &"emitter_runtime_form_unsupported",
			"默认形态 PARTICLE 当前运行未正式支持（仅 RAY 接正式运行时）。", path))
	# visual_profile 缺失仅 WARNING。
	if emitter.visual_profile == null:
		issues.append(_issue_struct(_warn(), &"emitter_visual_profile_missing",
			"Emitter 未配置 visual_profile。", path))


# ===== Crystal =====

## Crystal 数量：v0 运行合同为恰好 1 个；0 → crystal_missing，>=2 → multiple_crystals_unsupported。
func _validate_crystal_count(crystals: Array, issues: Array) -> void:
	if crystals.is_empty():
		issues.append(_issue_struct(_err(), &"crystal_missing",
			"关卡缺少 Crystal（v0 必须恰好 1 个）。", NodePath()))
	elif crystals.size() >= 2:
		issues.append(_issue_struct(_err(), &"multiple_crystals_unsupported",
			"当前 v0 仅支持单个 Crystal，实际 %d；仍继续扫描全部 Crystal。" % crystals.size(), NodePath()))


## Crystal 的 crystal_id 检查：空 ID → crystal_id_empty；任意重复 ID → crystal_id_duplicate（按扫描序，首个不报）。
func _validate_crystal_ids(crystals: Array, root: Node2D, issues: Array) -> void:
	var seen: Dictionary = {}
	for crystal in crystals:
		var c: _BasicCrystal = crystal
		var cid: StringName = c.crystal_id
		var path: NodePath = root.get_path_to(c)
		if cid == &"":
			# ID 为空：object_id 保持空。
			issues.append(_issue_struct(_err(), &"crystal_id_empty",
				"Crystal 的 crystal_id 为空。", path, &""))
			continue
		if seen.has(cid):
			issues.append(_issue_struct(_err(), &"crystal_id_duplicate",
				"Crystal 的 crystal_id=%s 重复。" % str(cid), path, cid))
		else:
			seen[cid] = true


## 单个 Crystal 的直属父 / 共同位置 / 直属 VisualView 检查。
func _validate_crystal(
		crystal: _BasicCrystal,
		root: Node2D,
		runtime_objects: Node,
		terrain_cells: Variant,
		wall_cells: Variant,
		issues: Array
) -> void:
	# Crystal Issue 能稳定对应对象时 object_id = crystal_id；ID 为空则 object_id 保持空。
	var cid: StringName = crystal.crystal_id
	var path: NodePath = root.get_path_to(crystal)
	# 直属父：必须为 RuntimeObjects 直属子节点。
	if not _is_direct_child_of(crystal, runtime_objects):
		issues.append(_issue_struct(_err(), &"fixed_object_parent_invalid",
			"Crystal 必须为 RuntimeObjects 直属子节点。", path, cid))
	# 共同位置规则（object_id = crystal_id，可能为空）。
	_check_object_position(crystal, path, cid, terrain_cells, wall_cells, issues)
	# 必需直属 VisualView：缺失或错型 → crystal_visual_missing；存在但未配置 Profile → WARNING。
	var visual_node: Node = crystal.get_node_or_null(_CRYSTAL_VISUAL_PATH)
	if visual_node == null or not is_instance_of(visual_node, _ObjectVisualView):
		issues.append(_issue_struct(_err(), &"crystal_visual_missing",
			"Crystal 缺少直属 VisualView 或类型不正确。", path, cid))
		return
	var view: _ObjectVisualView = visual_node
	if view.visual_profile == null:
		issues.append(_issue_struct(_warn(), &"crystal_visual_profile_missing",
			"Crystal 的 VisualView 未配置 Profile。", path, cid))


# ===== 共同位置规则 =====

## 对单个固定对象执行共同位置检查：非有限 → off_grid → outside_terrain → on_wall。
## 非有限 position 不派生 cell，直接返回；其余检查用经 world_to_cell 派生的 cell。
## terrain_cells / wall_cells 为 null 时跳过对应检查（层不可读，已由结构检查上报）。
func _check_object_position(
		obj: Node2D,
		path: NodePath,
		object_id: StringName,
		terrain_cells: Variant,
		wall_cells: Variant,
		issues: Array
) -> void:
	var pos: Vector2 = obj.position
	if not _is_finite_position(pos):
		issues.append(_issue_struct(_err(), &"fixed_object_position_non_finite",
			"固定对象 position 含非有限值（x=%s, y=%s）。" % [pos.x, pos.y], path, object_id))
		return
	var cell: Vector2i = _GridCoordinateRules.world_to_cell(pos)
	var center: Vector2 = _GridCoordinateRules.cell_to_world(cell)
	if abs(pos.x - center.x) > _OFF_GRID_TOLERANCE or abs(pos.y - center.y) > _OFF_GRID_TOLERANCE:
		issues.append(_issue_cell(_err(), &"fixed_object_position_off_grid",
			"固定对象 position 偏离目标格中心 %s（容差 %s px）。" % [str(cell), _OFF_GRID_TOLERANCE],
			path, cell, object_id))
		# off-grid 不中断：派生 cell 仍有效，继续判断 terrain / wall。
	if terrain_cells != null and not (cell in terrain_cells):
		issues.append(_issue_cell(_err(), &"fixed_object_outside_terrain",
			"固定对象位于 Terrain 之外 %s。" % str(cell), path, cell, object_id))
	if wall_cells != null and (cell in wall_cells):
		issues.append(_issue_cell(_err(), &"fixed_object_on_wall",
			"固定对象位于 Wall %s。" % str(cell), path, cell, object_id))


# ===== 占用重叠 =====

## Emitter / Crystal 彼此或 Crystal 间占同一 cell → fixed_object_overlap。
## 仅对 position 有限的对象参与；每对同 cell 对象报一条，归属扫描序在前者（Emitter 先于 Crystal）。
func _validate_overlap(emitters: Array, crystals: Array, root: Node2D, issues: Array) -> void:
	# 每项为 [cell: Vector2i, object_id: StringName, path: NodePath]。
	var placed: Array = []
	for emitter in emitters:
		var e: _EmitterConfigNode = emitter
		if _is_finite_position(e.position):
			placed.append([_GridCoordinateRules.world_to_cell(e.position), &"", root.get_path_to(e)])
	for crystal in crystals:
		var c: _BasicCrystal = crystal
		if _is_finite_position(c.position):
			placed.append([_GridCoordinateRules.world_to_cell(c.position), c.crystal_id, root.get_path_to(c)])
	for i in range(placed.size()):
		for j in range(i + 1, placed.size()):
			if placed[i][0] == placed[j][0]:
				var cell: Vector2i = placed[i][0]
				issues.append(_issue_cell(_err(), &"fixed_object_overlap",
					"固定对象占同一格 %s。" % str(cell), placed[i][2], cell, placed[i][1]))


# ===== 枚举域（防御性，镜像 EmitterConfigNode 公开枚举；不调用其私有 _is_valid_*） =====

func _is_valid_light_form(value: int) -> bool:
	return value in _EmitterConfigNode.LightForm.values()


func _is_valid_ray_direction(value: int) -> bool:
	return value in _EmitterConfigNode.RayDirection.values()


func _is_valid_particle_direction(value: int) -> bool:
	return value in _EmitterConfigNode.ParticleDirection.values()


# ===== 辅助 =====

## DFS 收集 level_root 子树中某脚本类型的全部实例（不含根）；顺序由 get_children 稳定给出。
func _find_instances(root: Node, script_type: GDScript) -> Array:
	var out: Array = []
	_gather_instances(root, script_type, out)
	return out


func _gather_instances(node: Node, script_type: GDScript, out: Array) -> void:
	for child in node.get_children():
		if is_instance_of(child, script_type):
			out.append(child)
		_gather_instances(child, script_type, out)


## node 是否为 parent 的直属子节点；parent 为 null 时返回 false。
func _is_direct_child_of(node: Node, parent: Node) -> bool:
	return parent != null and node.get_parent() == parent


## position 两轴是否均为有限值（NaN / Infinity 视为非有限）。
func _is_finite_position(pos: Vector2) -> bool:
	return is_finite(pos.x) and is_finite(pos.y)


func _err() -> int:
	return _LevelValidationIssue.Severity.ERROR


func _warn() -> int:
	return _LevelValidationIssue.Severity.WARNING


## 构造结构级 Issue（has_cell=false）。
func _issue_struct(
		severity: int,
		code: StringName,
		message: String,
		path: NodePath,
		object_id: StringName = &""
) -> _LevelValidationIssue:
	return _LevelValidationIssue.new(severity, code, message, path, false, Vector2i.ZERO, object_id)


## 构造 cell 级 Issue（has_cell=true）。
func _issue_cell(
		severity: int,
		code: StringName,
		message: String,
		path: NodePath,
		cell: Vector2i,
		object_id: StringName = &""
) -> _LevelValidationIssue:
	return _LevelValidationIssue.new(severity, code, message, path, true, cell, object_id)
