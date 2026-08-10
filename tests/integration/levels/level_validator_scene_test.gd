extends SceneTree

## LevelValidator v0 真实场景集成测试（D6-C.1）。
##
## 目的：真实 load() + PackedScene.instantiate() 两个正式场景（空白作者模板 level_template.tscn /
##   编辑示例 level_template_editing_example.tscn），实例一律不加入 SceneTree，对
##   LevelValidator.validate(root) 做端到端集成、只读前后快照证明与“释放后重新加载仍保持资源原始状态”证明。
##
## 覆盖四组：
##   01 空白模板结构成立 + 空白作者模板内容预期（terrain_empty ERROR；无结构损坏类 issue；is_valid=false）。
##   02 空白模板只读证明（snapshot_before → validate → validate → snapshot_after 全等；
##      释放后重新 load+instantiate 的全新实例保持资源原始值事实）。
##   03 编辑示例 Case A 正例（原样不修改 validate；error_count==0；is_valid==true；四层真实数据被正常消费；
##      打印全部 issue 详单）。
##   04 编辑示例只读证明（同 02，针对真实绘制场景）。
##
## 约束：不修改任何场景/资源/既有测试；不调用 ResourceSaver / PackedScene.pack / FileAccess / DirAccess 写入；
##   实例不入树（_ready 不触发），各场景受控 free。Validator 不得改场景——由快照前后全等证明。
## headless extends SceneTree，由 Godot --script 运行；preload 引用模块避开全局 class_name 缓存坑。
## 全部失败项收集后统一退出（任一失败 quit(1)）。

const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _ObjectVisualView: GDScript = preload("res://gameplay/visuals/object_visuals/object_visual_view.gd")

const _BLANK_TEMPLATE_PATH: String = "res://levels/templates/level_template.tscn"
const _EDITING_EXAMPLE_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
const _GROUP_COUNT: int = 4

## 结构损坏类 code：两个正式场景实例化后均不应出现（结构本身应成立）。
const _STRUCTURE_DAMAGE_CODES: Array = [
	"required_node_missing",
	"required_node_type_invalid",
	"required_node_misplaced",
	"duplicate_role_node",
	"tileset_missing",
]

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：顺序运行四组后统一报告并退出。
func _initialize() -> void:
	_test_01_blank_template_structure_and_content()
	_test_02_blank_template_readonly_proof()
	_test_03_editing_example_case_a_positive()
	_test_04_editing_example_readonly_proof()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 01 空白模板结构与内容 =====

## 正式空白模板：六角色齐备、结构合法，但四层均空（空白作者模板）。必须成立结构、产生 terrain_empty ERROR、
## is_valid=false；不得产生任何结构损坏类 issue。不锁死完整 issue 数量。
func _test_01_blank_template_structure_and_content() -> void:
	const G: String = "01_空白模板结构与内容"
	var root: Node2D = _instantiate_scene(_BLANK_TEMPLATE_PATH, G)
	var result: _LevelValidationResult = _LevelValidator.new().validate(root)
	_print_inventory(G, result)
	# 1. 正式结构本身成立：无结构损坏类 issue。
	for code: String in _STRUCTURE_DAMAGE_CODES:
		_check(G, not _has_code(result, code), "空白模板不应出现结构损坏 issue：%s。" % code)
	# 2. 空白作者模板内容预期：terrain_empty ERROR 存在（空 Terrain 是真实内容错误，不是结构损坏）。
	_check(G, _has_code_at_severity(result, "terrain_empty", _LevelValidationIssue.Severity.ERROR),
		"空白模板期望 terrain_empty ERROR。")
	# 3. is_valid == false。
	_check(G, result.is_valid() == false, "空白模板（空 Terrain）期望 is_valid=false。")
	root.free()


# ===== 02 空白模板只读证明 =====

## 真实实例只读证明：snapshot_before → validate → validate → snapshot_after。
## 必须证明：两次 Result 签名一致；快照前后全等；释放后全新实例保持资源原始值事实。
func _test_02_blank_template_readonly_proof() -> void:
	const G: String = "02_空白模板只读证明"
	var root: Node2D = _instantiate_scene(_BLANK_TEMPLATE_PATH, G)
	var snap_before: Dictionary = _capture(root)
	var validator: _LevelValidator = _LevelValidator.new()
	var r1: _LevelValidationResult = validator.validate(root)
	var r2: _LevelValidationResult = validator.validate(root)
	var snap_after: Dictionary = _capture(root)
	_check(G, _signature(r1) == _signature(r2), "两次 validate 结果签名应一致。")
	_check(G, str(snap_before) == str(snap_after), "validate 前后快照应全等（Validator 不应改场景）。")
	_check(G, _runtime_child_count(root) == int(snap_before["values"]["runtime"]["child_count"]),
		"validate 前后 RuntimeObjects 子节点数应不变。")
	root.free()
	# 释放后重新加载：全新实例保持资源原始状态（值事实一致；实例 id 预期不同故不参与比较）。
	var fresh: Node2D = _instantiate_scene(_BLANK_TEMPLATE_PATH, G)
	var snap_fresh: Dictionary = _capture(fresh)
	_check(G, str(snap_before["values"]) == str(snap_fresh["values"]),
		"重新加载的全新实例值事实应与首次一致（资源未被持久化修改）。")
	fresh.free()


# ===== 03 编辑示例 Case A 正例 =====

## 编辑示例第一遍完全不修改实例直接 validate()。Case A（error_count==0 / is_valid==true）则作为真实已绘制
## 场景集成正例。打印全部 issue 详单作为记录；WARNING 允许存在但必须符合冻结规则（不锁数量）。
func _test_03_editing_example_case_a_positive() -> void:
	const G: String = "03_编辑示例Case_A正例"
	var root: Node2D = _instantiate_scene(_EDITING_EXAMPLE_PATH, G)
	var result: _LevelValidationResult = _LevelValidator.new().validate(root)
	_print_inventory(G, result)
	# Case A 锁定：原样不修改 validate → error_count==0 / is_valid==true。
	_check(G, result.get_error_count() == 0,
		"编辑示例原样 validate 期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, result.is_valid() == true, "编辑示例原样 validate 期望 is_valid=true。")
	# 结构成立：无结构损坏类 issue。
	for code: String in _STRUCTURE_DAMAGE_CODES:
		_check(G, not _has_code(result, code), "编辑示例不应出现结构损坏 issue：%s。" % code)
	# 四层真实数据被 Validator 正常消费：四层均非空（真实绘制）+ 对应内容规则均不报 ERROR。
	_check(G, not _used_cells(root, "TerrainLayer").is_empty(), "编辑示例 TerrainLayer 应有真实绘制格。")
	_check(G, not _used_cells(root, "WallLayer").is_empty(), "编辑示例 WallLayer 应有真实绘制格。")
	_check(G, not _used_cells(root, "LegalAreaLayer").is_empty(), "编辑示例 LegalAreaLayer 应有真实绘制格。")
	_check(G, not _used_cells(root, "DecorationLayer").is_empty(), "编辑示例 DecorationLayer 应有真实绘制格。")
	_check(G, not _has_code(result, "terrain_empty"), "编辑示例 Terrain 非空不应报 terrain_empty。")
	_check(G, not _has_code(result, "legal_area_empty"), "编辑示例 Legal 非空不应报 legal_area_empty。")
	_check(G, not _has_code(result, "legal_outside_terrain"), "编辑示例 Legal 全在 Terrain 内不应报 legal_outside_terrain。")
	_check(G, not _has_code(result, "wall_outside_terrain"), "编辑示例 Wall 全在 Terrain 内不应报 wall_outside_terrain。")
	_check(G, not _has_code(result, "fixed_object_outside_terrain"), "编辑示例固定对象均在 Terrain 内。")
	_check(G, not _has_code(result, "fixed_object_position_off_grid"), "编辑示例固定对象 position 均居中目标格。")
	_check(G, not _has_code(result, "fixed_object_on_wall"), "编辑示例固定对象均不在 Wall 上。")
	_check(G, not _has_code(result, "fixed_object_overlap"), "编辑示例固定对象不同格。")
	_check(G, not _has_code(result, "emitter_count_invalid"), "编辑示例应恰好 1 个 Emitter。")
	_check(G, not _has_code(result, "crystal_missing"), "编辑示例应含 Crystal。")
	_check(G, not _has_code(result, "crystal_visual_missing"), "编辑示例 Crystal 应有直属 VisualView。")
	root.free()


# ===== 04 编辑示例只读证明 =====

## 编辑示例真实实例只读证明：同 02 针对真实绘制场景。
func _test_04_editing_example_readonly_proof() -> void:
	const G: String = "04_编辑示例只读证明"
	var root: Node2D = _instantiate_scene(_EDITING_EXAMPLE_PATH, G)
	var snap_before: Dictionary = _capture(root)
	var validator: _LevelValidator = _LevelValidator.new()
	var r1: _LevelValidationResult = validator.validate(root)
	var r2: _LevelValidationResult = validator.validate(root)
	var snap_after: Dictionary = _capture(root)
	_check(G, _signature(r1) == _signature(r2), "两次 validate 结果签名应一致。")
	_check(G, str(snap_before) == str(snap_after), "validate 前后快照应全等（Validator 不应改场景）。")
	_check(G, _runtime_child_count(root) == int(snap_before["values"]["runtime"]["child_count"]),
		"validate 前后 RuntimeObjects 子节点数应不变。")
	root.free()
	# 释放后重新加载：全新实例保持资源原始状态。
	var fresh: Node2D = _instantiate_scene(_EDITING_EXAMPLE_PATH, G)
	var snap_fresh: Dictionary = _capture(fresh)
	_check(G, str(snap_before["values"]) == str(snap_fresh["values"]),
		"重新加载的全新实例值事实应与首次一致（资源未被持久化修改）。")
	fresh.free()


# ===== 场景加载 =====

## 真实 load + instantiate，实例不加入 SceneTree。加载失败立即累计失败并返回 null。
func _instantiate_scene(path: String, group: String) -> Node2D:
	var packed: PackedScene = load(path)
	if packed == null:
		_check(group, false, "无法 load 场景资源：%s。" % path)
		return null
	var node: Node = packed.instantiate()
	if node == null or not (node is Node2D):
		_check(group, false, "场景根不是 Node2D：%s。" % path)
		return null
	return node


# ===== 快照采集（只读） =====

## 采集真实实例独立事实快照：values 为值事实（释放后重载须一致），ids 为资源实例 id（同实例两次须一致）。
## 所有叶节点均为基元（String/int/bool），str(dict) 渲染确定性。
func _capture(root: Node2D) -> Dictionary:
	var values: Dictionary = {}
	var ids: Dictionary = {}
	# 根结构：根直属子节点（名:类型）。
	var root_children: Array = []
	for c in root.get_children():
		root_children.append("%s:%s" % [String(c.name), _node_type_name(c)])
	root_children.sort()
	values["root_name"] = String(root.name)
	values["root_direct_children"] = root_children
	# 四层。
	values["terrain"] = _capture_layer_values(root, "TerrainLayer")
	values["wall"] = _capture_layer_values(root, "WallLayer")
	values["legal"] = _capture_layer_values(root, "LegalAreaLayer")
	values["decoration"] = _capture_layer_values(root, "DecorationLayer")
	ids["terrain_tileset"] = _capture_layer_tileset_id(root, "TerrainLayer")
	ids["wall_tileset"] = _capture_layer_tileset_id(root, "WallLayer")
	ids["legal_tileset"] = _capture_layer_tileset_id(root, "LegalAreaLayer")
	ids["decoration_tileset"] = _capture_layer_tileset_id(root, "DecorationLayer")
	# RuntimeObjects。
	values["runtime"] = _capture_runtime_values(root)
	# Emitter / Crystal。
	values["emitter"] = _capture_emitter_values(root)
	values["crystal"] = _capture_crystal_values(root)
	ids["emitter_profile"] = _capture_emitter_profile_id(root)
	ids["crystal_profile"] = _capture_crystal_profile_id(root)
	return {"values": values, "ids": ids}


## 单层值事实：存在/类型/格数/排序后格集/position/rotation/scale。
func _capture_layer_values(root: Node2D, layer_name: String) -> Dictionary:
	var node: Node = root.get_node_or_null(NodePath(layer_name))
	if node == null or not (node is TileMapLayer):
		return {"exists": false}
	var layer: TileMapLayer = node
	var cells: Array = []
	for c in layer.get_used_cells():
		cells.append("%d,%d" % [c.x, c.y])
	cells.sort()
	return {
		"exists": true,
		"class": layer.get_class(),
		"used_count": cells.size(),
		"used_cells": cells,
		"position": "%.6f,%.6f" % [layer.position.x, layer.position.y],
		"rotation": "%.6f" % layer.rotation,
		"scale": "%.6f,%.6f" % [layer.scale.x, layer.scale.y],
	}


## 单层 TileSet 资源实例 id（缺层或无 TileSet 返回 -1）。同实例两次比较须一致。
func _capture_layer_tileset_id(root: Node2D, layer_name: String) -> int:
	var node: Node = root.get_node_or_null(NodePath(layer_name))
	if node == null or not (node is TileMapLayer):
		return -1
	var layer: TileMapLayer = node
	if layer.tile_set == null:
		return -1
	return layer.tile_set.get_instance_id()


## RuntimeObjects：存在/子节点数/子节点(名:类型)。
func _capture_runtime_values(root: Node2D) -> Dictionary:
	var node: Node = root.get_node_or_null(NodePath("RuntimeObjects"))
	if node == null:
		return {"exists": false, "child_count": 0, "children": []}
	var children: Array = []
	for c in node.get_children():
		children.append("%s:%s" % [String(c.name), _node_type_name(c)])
	children.sort()
	return {
		"exists": true,
		"child_count": node.get_child_count(),
		"children": children,
	}


## Emitter 值事实：存在/相对路径/Node.name/position/形态/光线方向/光粒方向/profile 是否非空。
func _capture_emitter_values(root: Node2D) -> Dictionary:
	var emitter: Node = _find_first_instance(root, _EmitterConfigNode)
	if emitter == null:
		return {"exists": false}
	var e: _EmitterConfigNode = emitter
	return {
		"exists": true,
		"path": str(root.get_path_to(e)),
		"name": String(e.name),
		"position": "%.6f,%.6f" % [e.position.x, e.position.y],
		"default_light_form": int(e.default_light_form),
		"ray_direction": int(e.ray_default_direction),
		"particle_direction": int(e.particle_default_direction),
		"profile_nonnull": e.visual_profile != null,
	}


## Crystal 值事实：存在/相对路径/Node.name/position/crystal_id/VisualView 路径+类型/profile 是否非空。
func _capture_crystal_values(root: Node2D) -> Dictionary:
	var crystal: Node = _find_first_instance(root, _BasicCrystal)
	if crystal == null:
		return {"exists": false}
	var c: _BasicCrystal = crystal
	var visual_node: Node = c.get_node_or_null(NodePath("VisualView"))
	var visual_type: String = "" if visual_node == null else _node_type_name(visual_node)
	var visual_profile_nonnull: bool = false
	if visual_node != null and is_instance_of(visual_node, _ObjectVisualView):
		visual_profile_nonnull = (visual_node as _ObjectVisualView).visual_profile != null
	return {
		"exists": true,
		"path": str(root.get_path_to(c)),
		"name": String(c.name),
		"position": "%.6f,%.6f" % [c.position.x, c.position.y],
		"crystal_id": String(c.crystal_id),
		"visual_path": str(c.get_path_to(visual_node)) if visual_node != null else "",
		"visual_type": visual_type,
		"visual_profile_nonnull": visual_profile_nonnull,
	}


## Emitter visual_profile 资源实例 id（缺 Emitter 或无 profile 返回 -1）。
func _capture_emitter_profile_id(root: Node2D) -> int:
	var emitter: Node = _find_first_instance(root, _EmitterConfigNode)
	if emitter == null:
		return -1
	var e: _EmitterConfigNode = emitter
	if e.visual_profile == null:
		return -1
	return e.visual_profile.get_instance_id()


## Crystal VisualView visual_profile 资源实例 id（缺 Crystal / VisualView / profile 返回 -1）。
func _capture_crystal_profile_id(root: Node2D) -> int:
	var crystal: Node = _find_first_instance(root, _BasicCrystal)
	if crystal == null:
		return -1
	var c: _BasicCrystal = crystal
	var visual_node: Node = c.get_node_or_null(NodePath("VisualView"))
	if visual_node == null or not is_instance_of(visual_node, _ObjectVisualView):
		return -1
	var profile = (visual_node as _ObjectVisualView).visual_profile
	if profile == null:
		return -1
	return profile.get_instance_id()


## RuntimeObjects 子节点数（缺层返回 -1）。
func _runtime_child_count(root: Node2D) -> int:
	var node: Node = root.get_node_or_null(NodePath("RuntimeObjects"))
	if node == null:
		return -1
	return node.get_child_count()


# ===== 事实读取辅助 =====

## 某层 used_cells（Array[Vector2i] 副本）；缺层返回空数组。
func _used_cells(root: Node2D, layer_name: String) -> Array:
	var node: Node = root.get_node_or_null(NodePath(layer_name))
	if node == null or not (node is TileMapLayer):
		return []
	return (node as TileMapLayer).get_used_cells()


## DFS 收集 level_root 子树中某脚本类型的首个实例（不含根）；未找到返回 null。
func _find_first_instance(root: Node, script_type: GDScript) -> Node:
	return _gather_first(root, script_type)


func _gather_first(node: Node, script_type: GDScript) -> Node:
	for c in node.get_children():
		if is_instance_of(c, script_type):
			return c
		var deeper: Node = _gather_first(c, script_type)
		if deeper != null:
			return deeper
	return null


## 节点类型名：有脚本取脚本资源文件名，否则取原生 get_class()。
func _node_type_name(n: Node) -> String:
	var s: Script = n.get_script()
	if s != null:
		return s.resource_path.get_file()
	return n.get_class()


# ===== 断言 / 记录辅助 =====

## 结果中是否存在指定 code 的 issue。
func _has_code(result: _LevelValidationResult, code: String) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code:
			return true
	return false


## 结果中是否存在指定 code 且 severity 匹配的 issue。
func _has_code_at_severity(result: _LevelValidationResult, code: String, severity: int) -> bool:
	for issue in result.get_issues():
		if str(issue.get_code()) == code and issue.get_severity() == severity:
			return true
	return false


## issue 全排序键签名（severity/code/node_path/has_cell/cell/object_id），用于比较两次结果是否逐项一致。
func _signature(result: _LevelValidationResult) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for issue in result.get_issues():
		parts.append("%d|%s|%s|%d|%d,%d|%s" % [
			issue.get_severity(), str(issue.get_code()), str(issue.get_node_path()),
			int(issue.has_cell()), issue.get_cell().x, issue.get_cell().y, str(issue.get_object_id())
		])
	return "\n".join(parts)


## 打印某次结果全部 issue 详单（severity/code/node_path/has_cell/cell/object_id/message）。
func _print_inventory(group: String, result: _LevelValidationResult) -> void:
	print("==== [%s] issue 详单（共 %d：ERROR %d / WARNING %d）====" % [
		group, result.get_issues().size(), result.get_error_count(), result.get_warning_count()])
	for issue in result.get_issues():
		var sev: String = "ERROR" if issue.get_severity() == _LevelValidationIssue.Severity.ERROR else "WARNING"
		var cell_part: String = "cell=%d,%d" % [issue.get_cell().x, issue.get_cell().y] if issue.has_cell() else "cell=-"
		print("  %s | code=%s | node=%s | %s | object_id=%s | %s" % [
			sev, str(issue.get_code()), str(issue.get_node_path()), cell_part, str(issue.get_object_id()), issue.get_message()])


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelValidator 真实场景集成 测试摘要 ====")
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
