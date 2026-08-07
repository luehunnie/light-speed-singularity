extends SceneTree

## D5-C.1 正式模板与编辑示例结构契约测试。
## 覆盖 res://levels/templates/level_template.tscn（正式空白关卡模板）与
##   res://levels/templates/examples/level_template_editing_example.tscn（编辑示例）。
## 全部通过真实 PackedScene 实例化 + 节点属性/SceneState 读取验证；不把 .tscn 文本当作四层数据的唯一证据，
##   四层关系全部读取真实 get_used_cells()。TileSet 绑定按 resource_path 比对，不依赖 ext_resource id 与文件顺序。
## RuntimeObjects/Emitter、RuntimeObjects/BasicCrystal 的“完整路径 + PackedScene 身份”在同一 SceneState 节点 index
##   上原子验证（辅助 _find_node_by_path_and_instance），不依赖固定节点 index、ext_resource id 或文件顺序；
##   crystal_id 仅在该精确节点上确认显式保存，Node.name 独立性由行为级验证（改名 + 入树触发 _ready）证明，
##   不再用源码字符串扫描作为主要证据，也不通过 Node.name 生成预期值。
## 由 Godot --headless --script 运行，全部断言通过 quit(0)，任一失败 quit(1)。

const _FORMAL_SCENE_PATH: String = "res://levels/templates/level_template.tscn"
const _EXAMPLE_SCENE_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"

const _TERRAIN_TILESET_PATH: String = "res://assets/art/tilesets/terrain_tileset.tres"
const _WALL_TILESET_PATH: String = "res://assets/art/tilesets/wall_tileset.tres"
const _LEGAL_TILESET_PATH: String = "res://assets/art/tilesets/legal_area_tileset.tres"
const _DECORATION_TILESET_PATH: String = "res://assets/art/tilesets/decoration_tileset.tres"

const _EMITTER_SCENE_PATH: String = "res://gameplay/mechanisms/emitters/emitter_config_node.tscn"
const _CRYSTAL_SCENE_PATH: String = "res://gameplay/crystals/basic_crystal.tscn"

const _GROUP_COUNT: int = 15

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


## SceneTree 初始化入口：加载并实例化两份模板，依次跑正式模板、子场景行为与编辑示例契约用例，统一报告并退出。
func _initialize() -> void:
	# --script 模式下首帧前等待一帧，确保后续资源访问处于稳定帧。
	await process_frame

	var formal_scene: PackedScene = load(_FORMAL_SCENE_PATH) as PackedScene
	var example_scene: PackedScene = load(_EXAMPLE_SCENE_PATH) as PackedScene
	var formal_root: Node2D = _safe_instance(formal_scene)
	var example_root: Node2D = _safe_instance(example_scene)

	# ---- 正式模板契约（level_template.tscn）----
	_test_01_formal_scene_loadable(formal_scene, formal_root)
	_test_02_formal_four_tilemap_layers(formal_root)
	_test_03_formal_layers_bind_tilesets(formal_root)
	_test_04_formal_layers_empty(formal_root)
	_test_05_formal_runtime_exact_nodes(formal_scene, formal_root)
	_test_06_formal_crystal_id_exact_node(formal_scene, formal_root)
	_test_07_formal_decoration_no_logic(formal_root)

	# ---- BasicCrystal 子场景行为契约（直接实例化 basic_crystal.tscn）----
	await _test_08_crystal_id_independent_of_node_name()

	# ---- 编辑示例契约（level_template_editing_example.tscn）----
	_test_09_example_four_layers_bind_tilesets(example_root)
	_test_10_example_terrain_nonempty(example_root)
	_test_11_example_terrain_irregular(example_root)
	_test_12_example_legal_within_terrain(example_root)
	_test_13_example_wall_within_terrain(example_root)
	_test_14_example_decoration_present_independent(example_root)
	_test_15_example_editor_guide_contract(example_root)

	if formal_root != null:
		formal_root.free()
	if example_root != null:
		example_root.free()

	# 正式/示例实例从未挂入 SceneTree；行为用例的临时实例已 queue_free 释放，root 不应残留任何子节点。
	_check_residual_clean()

	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 通用辅助 =====

## 实例化场景为 Node2D，失败返回 null（不挂入 SceneTree，不触发 _ready）。
func _safe_instance(scene: PackedScene) -> Node2D:
	if scene == null:
		return null
	var n: Node = scene.instantiate()
	if n == null:
		return null
	if not (n is Node2D):
		n.free()
		return null
	return n as Node2D


## 收集 root 直属子节点中的 TileMapLayer，返回 {String 节点名: TileMapLayer}（键统一为 String，避免 StringName/String 哈希错配）。
func _collect_direct_tilemap_layers(root: Node) -> Dictionary:
	var out: Dictionary = {}
	if root == null:
		return out
	for c in root.get_children():
		if c is TileMapLayer:
			var nm: String = c.name
			out[nm] = c
	return out


## 读取 TileMapLayer 绑定的 TileSet resource_path；未绑定返回空串。
func _tileset_path_of(layer: TileMapLayer) -> String:
	if layer == null or layer.tile_set == null:
		return ""
	return layer.tile_set.resource_path


## 校验某层绑定到预期 TileSet 路径（按 resource_path，不依赖 ext_resource id，不依赖文件顺序）。
func _check_layer_tileset(group: String, layers: Dictionary, layer_name: String, expected_path: String) -> void:
	var layer: TileMapLayer = layers.get(layer_name) as TileMapLayer
	_check(group, layer != null, "%s 节点缺失。" % layer_name)
	if layer == null:
		return
	var ts: TileSet = layer.tile_set
	_check(group, ts != null, "%s 的 tile_set 未绑定（tile_set 为空）。" % layer_name)
	var actual: String = _tileset_path_of(layer)
	_check(group, actual == expected_path, "%s 的 TileSet 应为 %s，实际 %s。" % [layer_name, expected_path, actual])


## 取 SceneState 节点相对场景根的完整路径字符串（已归一化），用于精确路径匹配。
## SceneState.get_node_path(idx) 以 "./" 前缀给出相对路径（根节点为 "."）；去掉前缀归一化为 "RuntimeObjects/Emitter" 形式。
func _scene_state_node_path(state: SceneState, idx: int) -> String:
	var p: String = str(state.get_node_path(idx))
	if p == ".":
		return ""
	if p.begins_with("./"):
		return p.substr(2)
	return p


## 在 SceneState 中查找“完整路径 + 目标 PackedScene 身份”同时匹配的节点 index，找不到返回 -1。
## 同一 index 原子满足“路径 + 实例身份”，避免二者由不同节点分别满足；不依赖固定节点 index、ext_resource id 或文件顺序。
func _find_node_by_path_and_instance(state: SceneState, expected_path: String, target_scene: PackedScene) -> int:
	if state == null or target_scene == null:
		return -1
	for i: int in range(state.get_node_count()):
		if _scene_state_node_path(state, i) != expected_path:
			continue
		var inst: PackedScene = state.get_node_instance(i)
		if inst != null and inst == target_scene:
			return i
	return -1


## 校验子层 get_used_cells() 全部位于父层 get_used_cells() 内（读取真实格子，互相独立）。
func _subset_check(group: String, root: Node2D, subset_layer: String, superset_layer: String) -> void:
	var layers: Dictionary = _collect_direct_tilemap_layers(root)
	var sub: TileMapLayer = layers.get(subset_layer) as TileMapLayer
	var sup: TileMapLayer = layers.get(superset_layer) as TileMapLayer
	_check(group, sub != null, "%s 缺失。" % subset_layer)
	_check(group, sup != null, "%s 缺失。" % superset_layer)
	if sub == null or sup == null:
		return
	# superset 集合仅由 superset 层构造，不引入其它图层（含 Decoration）的格子。
	var sup_set: Dictionary = {}
	for c in sup.get_used_cells():
		sup_set[c] = true
	var offenders: Array = []
	for c in sub.get_used_cells():
		if not sup_set.has(c):
			offenders.append(c)
	_check(group, offenders.is_empty(), "%s 的所有格应位于 %s 内，越界格：%s。" % [subset_layer, superset_layer, offenders])


## 递归收集 node 子树中的 editor_description 与 Label.text，用于中文说明覆盖检查（真实节点属性读取）。
func _gather_text(node: Node, parts: Array) -> void:
	if node == null:
		return
	var ed: String = node.editor_description
	if ed.length() > 0:
		parts.append(ed)
	if node is Label:
		parts.append(node.text)
	for c in node.get_children():
		_gather_text(c, parts)


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 实例从未入树（行为用例的临时实例已受控释放），root 不应有残留子节点；单独记为清理检查，不计入契约组。
func _check_residual_clean() -> void:
	_check("R_清理检查_无SceneTree残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % root.get_child_count())


## 输出测试摘要：契约组数、清理检查、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var passed: int = _checks - _failures.size()
	print("==== 正式模板与编辑示例结构契约 测试摘要 ====")
	print("契约组数：%d" % _GROUP_COUNT)
	print("清理检查：1")
	print("断言总数（含清理）：%d" % _checks)
	print("通过断言：%d" % passed)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for f: String in _failures:
			print(f)


# ===== 正式模板契约用例 =====

## 1. 正式模板可加载并实例化为 Node2D（亦即正式模板 headless smoke）。
func _test_01_formal_scene_loadable(scene: PackedScene, root_node: Node2D) -> void:
	const G: String = "01_正式模板可加载实例化"
	_check(G, scene != null, "level_template.tscn 加载失败。")
	_check(G, root_node != null, "正式模板实例化返回 null。")


## 2. 根直属存在且仅存在四个 TileMapLayer，名称恰为四层。
func _test_02_formal_four_tilemap_layers(root_node: Node2D) -> void:
	const G: String = "02_正式模板根直属四TileMapLayer"
	_check(G, root_node != null, "根节点缺失，无法枚举直属 TileMapLayer。")
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	_check(G, layers.size() == 4, "根直属 TileMapLayer 应为 4 个，实际 %d 个：%s。" % [layers.size(), layers.keys()])
	for n: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		var layer: TileMapLayer = layers.get(n) as TileMapLayer
		_check(G, layer != null, "缺少根直属 TileMapLayer：%s。" % n)
		_check(G, layer == null or layer.get_parent() == root_node, "%s 应为根节点直属子节点。" % n)


## 3. 四层分别绑定正确 TileSet（terrain/wall/legal_area/decoration）。
func _test_03_formal_layers_bind_tilesets(root_node: Node2D) -> void:
	const G: String = "03_正式模板四层绑定正确TileSet"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	_check_layer_tileset(G, layers, "TerrainLayer", _TERRAIN_TILESET_PATH)
	_check_layer_tileset(G, layers, "WallLayer", _WALL_TILESET_PATH)
	_check_layer_tileset(G, layers, "LegalAreaLayer", _LEGAL_TILESET_PATH)
	_check_layer_tileset(G, layers, "DecorationLayer", _DECORATION_TILESET_PATH)


## 4. 四层 get_used_cells() 均为空（正式空白模板不应预置任何格子）。
func _test_04_formal_layers_empty(root_node: Node2D) -> void:
	const G: String = "04_正式模板四层get_used_cells为空"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	for n: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		var layer: TileMapLayer = layers.get(n) as TileMapLayer
		if layer == null:
			_check(G, false, "%s 缺失，无法校验 used_cells。" % n)
			continue
		var used: Array = layer.get_used_cells()
		_check(G, used.is_empty(), "%s 的 get_used_cells() 应为空，实际 %d 格：%s。" % [n, used.size(), used])


## 5. RuntimeObjects / RuntimeObjects/Emitter / RuntimeObjects/BasicCrystal / LightPathLayer 存在；Emitter、BasicCrystal 的
##    “完整路径 + PackedScene 身份”在同一 SceneState 节点 index 上原子匹配，运行实例与该 SceneState 契约一致。
func _test_05_formal_runtime_exact_nodes(scene: PackedScene, root_node: Node2D) -> void:
	const G: String = "05_正式模板Runtime精确节点契约"
	_check(G, root_node != null, "根节点缺失。")
	_check(G, scene != null, "正式 PackedScene 缺失。")
	if root_node == null or scene == null:
		return

	var runtime: Node = root_node.get_node_or_null("RuntimeObjects")
	_check(G, runtime != null, "RuntimeObjects 节点不存在。")
	_check(G, runtime != null and runtime is Node2D, "RuntimeObjects 应为 Node2D。")
	_check(G, runtime != null and runtime.get_parent() == root_node, "RuntimeObjects 应为根直属子节点。")

	var state: SceneState = scene.get_state()

	# Emitter：同一 index 上 路径 == RuntimeObjects/Emitter 且 实例身份 == emitter_config_node.tscn。
	var emitter_scene: PackedScene = load(_EMITTER_SCENE_PATH) as PackedScene
	_check(G, emitter_scene != null, "emitter_config_node.tscn 加载失败，无法做身份比对。")
	var em_idx: int = _find_node_by_path_and_instance(state, "RuntimeObjects/Emitter", emitter_scene)
	_check(G, em_idx != -1, "RuntimeObjects/Emitter 应在 SceneState 同一节点上精确匹配 emitter_config_node.tscn 实例（路径+身份原子）。")
	# 运行实例一致性：SceneState 契约实例化到运行树后，该路径节点必须存在。
	var em_runtime: Node = root_node.get_node_or_null("RuntimeObjects/Emitter")
	_check(G, em_runtime != null, "运行实例 RuntimeObjects/Emitter 不存在（SceneState 契约与运行树不一致）。")

	# BasicCrystal：同一 index 上 路径 == RuntimeObjects/BasicCrystal 且 实例身份 == basic_crystal.tscn。
	var crystal_scene: PackedScene = load(_CRYSTAL_SCENE_PATH) as PackedScene
	_check(G, crystal_scene != null, "basic_crystal.tscn 加载失败，无法做身份比对。")
	var cr_idx: int = _find_node_by_path_and_instance(state, "RuntimeObjects/BasicCrystal", crystal_scene)
	_check(G, cr_idx != -1, "RuntimeObjects/BasicCrystal 应在 SceneState 同一节点上精确匹配 basic_crystal.tscn 实例（路径+身份原子）。")
	var cr_runtime: Node = root_node.get_node_or_null("RuntimeObjects/BasicCrystal")
	_check(G, cr_runtime != null, "运行实例 RuntimeObjects/BasicCrystal 不存在（SceneState 契约与运行树不一致）。")

	var lpl: Node = root_node.get_node_or_null("LightPathLayer")
	_check(G, lpl != null, "LightPathLayer 节点不存在。")
	_check(G, lpl != null and lpl is Node2D, "LightPathLayer 应为 Node2D。")
	_check(G, lpl != null and lpl.get_parent() == root_node, "LightPathLayer 应为根直属子节点。")


## 6. RuntimeObjects/BasicCrystal 精确节点上显式保存非空 crystal_id，且与运行实例实际 crystal_id 一致。
##    仅读取该精确节点，不通过其他同名节点提供属性。
func _test_06_formal_crystal_id_exact_node(scene: PackedScene, root_node: Node2D) -> void:
	const G: String = "06_正式模板BasicCrystal显式crystal_id精确节点"
	_check(G, scene != null, "正式 PackedScene 缺失。")
	if scene == null:
		return
	var state: SceneState = scene.get_state()
	var crystal_scene: PackedScene = load(_CRYSTAL_SCENE_PATH) as PackedScene
	_check(G, crystal_scene != null, "basic_crystal.tscn 加载失败。")
	if crystal_scene == null:
		return
	# 精确节点：路径 + 实例身份 原子匹配。
	var idx: int = _find_node_by_path_and_instance(state, "RuntimeObjects/BasicCrystal", crystal_scene)
	_check(G, idx != -1, "未在 SceneState 精确节点 RuntimeObjects/BasicCrystal 上找到 basic_crystal.tscn 实例。")
	if idx == -1:
		return
	# 该精确节点显式保存 crystal_id（不得由其他同名节点提供）。
	var has_explicit: bool = false
	var explicit_val: StringName = &""
	for j: int in range(state.get_node_property_count(idx)):
		if state.get_node_property_name(idx, j) == &"crystal_id":
			has_explicit = true
			explicit_val = state.get_node_property_value(idx, j)
	_check(G, has_explicit, "精确节点 RuntimeObjects/BasicCrystal 应显式保存 crystal_id（不得仅依赖脚本默认）。")
	if has_explicit:
		_check(G, str(explicit_val) != "", "显式 crystal_id 应非空，实际 '%s'。" % explicit_val)
	# 运行实例值一致。
	var crystal: Node = root_node.get_node_or_null("RuntimeObjects/BasicCrystal") if root_node != null else null
	_check(G, crystal != null, "运行实例 RuntimeObjects/BasicCrystal 不存在。")
	var runtime_id: StringName = &""
	if crystal != null and "crystal_id" in crystal:
		runtime_id = crystal.get("crystal_id")
	_check(G, runtime_id != null and str(runtime_id) != "", "运行期 crystal_id 应为非空，实际 '%s'。" % [runtime_id])
	_check(G, not has_explicit or explicit_val == runtime_id, "运行期 crystal_id 应与场景显式值一致，场景 '%s' 运行期 '%s'。" % [explicit_val, runtime_id])


## 7. DecorationLayer 不挂逻辑脚本，且非 RuntimeObjects 子树节点（纯视觉层）。
func _test_07_formal_decoration_no_logic(root_node: Node2D) -> void:
	const G: String = "07_正式模板DecorationLayer无逻辑非运行节点"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	var deco: TileMapLayer = layers.get("DecorationLayer") as TileMapLayer
	_check(G, deco != null, "DecorationLayer 节点缺失。")
	if deco == null:
		return
	_check(G, deco.get_script() == null, "DecorationLayer 不应挂载逻辑脚本，实际脚本：%s。" % [deco.get_script()])
	_check(G, deco.get_parent() == root_node, "DecorationLayer 应为根直属子节点。")
	var runtime: Node = root_node.get_node_or_null("RuntimeObjects")
	_check(G, runtime == null or not runtime.is_ancestor_of(deco), "DecorationLayer 不应位于 RuntimeObjects 子树内。")


# ===== BasicCrystal 子场景行为契约用例 =====

## 8. 行为级证明：Node.name 变化不会改变 BasicCrystal.crystal_id。
##    直接实例化 basic_crystal.tscn，写入已知 crystal_id（不通过 Node.name 生成预期值），分别于
##    未入树改名、入树触发 _ready、入树改名后确认 crystal_id 全程不变；测试结束受控释放实例。
func _test_08_crystal_id_independent_of_node_name() -> void:
	const G: String = "08_BasicCrystal的crystal_id独立于Node.name"
	var crystal_scene: PackedScene = load(_CRYSTAL_SCENE_PATH) as PackedScene
	_check(G, crystal_scene != null, "basic_crystal.tscn 加载失败。")
	if crystal_scene == null:
		return
	var crystal: Node = crystal_scene.instantiate()
	_check(G, crystal != null, "basic_crystal.tscn 实例化返回 null。")
	if crystal == null:
		return

	const known_id: StringName = &"contract_crystal"
	# 写入已知值，记录基线。
	crystal.set("crystal_id", known_id)
	var after_set: StringName = crystal.get("crystal_id")
	_check(G, after_set == known_id, "写入后 crystal_id 应为 contract_crystal，实际 '%s'。" % [after_set])

	# 未入树改名：crystal_id 不变。
	crystal.name = &"RenamedOffTree"
	var after_rename_offtree: StringName = crystal.get("crystal_id")
	_check(G, after_rename_offtree == known_id, "未入树改名后 crystal_id 应不变，实际 '%s'。" % [after_rename_offtree])

	# 入树触发 _ready（BasicCrystal._ready 存在初始化逻辑）后再确认；crystal_id 不变。
	root.add_child(crystal)
	await process_frame
	var after_ready: StringName = crystal.get("crystal_id")
	_check(G, after_ready == known_id, "入树触发 _ready 后 crystal_id 应不变，实际 '%s'。" % [after_ready])

	# 入树后再改名：crystal_id 仍不变。
	crystal.name = &"RenamedInTree"
	var after_rename_intree: StringName = crystal.get("crystal_id")
	_check(G, after_rename_intree == known_id, "入树改名后 crystal_id 应不变，实际 '%s'。" % [after_rename_intree])

	# 受控释放：摘树 + 延迟释放并泵一帧，确保不残留于 root（影响清理检查）。
	root.remove_child(crystal)
	crystal.queue_free()
	await process_frame


# ===== 编辑示例契约用例 =====

## 9. 编辑示例四层存在且绑定正确 TileSet（亦即编辑示例 headless smoke）。
func _test_09_example_four_layers_bind_tilesets(root_node: Node2D) -> void:
	const G: String = "09_编辑示例四层存在且绑定正确TileSet"
	_check(G, root_node != null, "编辑示例根节点缺失。")
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	_check(G, layers.size() == 4, "编辑示例根直属 TileMapLayer 应为 4 个，实际 %d 个。" % layers.size())
	for n: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		_check(G, layers.has(n), "编辑示例缺少 TileMapLayer：%s。" % n)
	_check_layer_tileset(G, layers, "TerrainLayer", _TERRAIN_TILESET_PATH)
	_check_layer_tileset(G, layers, "WallLayer", _WALL_TILESET_PATH)
	_check_layer_tileset(G, layers, "LegalAreaLayer", _LEGAL_TILESET_PATH)
	_check_layer_tileset(G, layers, "DecorationLayer", _DECORATION_TILESET_PATH)


## 10. 编辑示例 Terrain 非空。
func _test_10_example_terrain_nonempty(root_node: Node2D) -> void:
	const G: String = "10_编辑示例Terrain非空"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	var terrain: TileMapLayer = layers.get("TerrainLayer") as TileMapLayer
	_check(G, terrain != null, "TerrainLayer 缺失。")
	var used: Array = []
	if terrain != null:
		used = terrain.get_used_cells()
	_check(G, not used.is_empty(), "编辑示例 TerrainLayer 的 get_used_cells() 应非空，实际 0 格。")


## 11. 编辑示例 Terrain 至少满足一种不规则特征：外包矩形内存在空洞或 used < 外包矩形面积（二者等价于 used < rect_area）。
func _test_11_example_terrain_irregular(root_node: Node2D) -> void:
	const G: String = "11_编辑示例Terrain不规则"
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	var terrain: TileMapLayer = layers.get("TerrainLayer") as TileMapLayer
	if terrain == null:
		_check(G, false, "TerrainLayer 缺失，无法校验不规则。")
		return
	var used: Array = terrain.get_used_cells()
	if used.is_empty():
		_check(G, false, "Terrain 为空，无法判定不规则。")
		return
	var minx: int = 0
	var maxx: int = 0
	var miny: int = 0
	var maxy: int = 0
	var first: bool = true
	for c in used:
		var v: Vector2i = c
		if first:
			minx = v.x
			maxx = v.x
			miny = v.y
			maxy = v.y
			first = false
		else:
			minx = min(minx, v.x)
			maxx = max(maxx, v.x)
			miny = min(miny, v.y)
			maxy = max(maxy, v.y)
	var rw: int = maxx - minx + 1
	var rh: int = maxy - miny + 1
	var rect_area: int = rw * rh
	_check(G, used.size() < rect_area, "Terrain 应不规则（used < 外包矩形面积），实际 used=%d 外包矩形=%dx%d=%d。" % [used.size(), rw, rh, rect_area])


## 12. 编辑示例 LegalArea 所有格均属于 Terrain。
func _test_12_example_legal_within_terrain(root_node: Node2D) -> void:
	const G: String = "12_编辑示例Legal全在Terrain内"
	_subset_check(G, root_node, "LegalAreaLayer", "TerrainLayer")


## 13. 编辑示例 Wall 所有格均属于 Terrain。
func _test_13_example_wall_within_terrain(root_node: Node2D) -> void:
	const G: String = "13_编辑示例Wall全在Terrain内"
	_subset_check(G, root_node, "WallLayer", "TerrainLayer")


## 14. 编辑示例 Decoration 存在且有示例格；Terrain/Legal/Wall 事实集合仅由各自图层独立构造，Decoration 不参与。
func _test_14_example_decoration_present_independent(root_node: Node2D) -> void:
	const G: String = "14_编辑示例Decoration存在且独立"
	# 独立性：terrain_set/legal_set/wall_set 分别在 10/11/12/13 中仅由各自 TileMapLayer 的 get_used_cells() 构造，
	# Decoration 格从不并入任一事实集合；本用例仅断言 Decoration 自身存在示例格。
	var layers: Dictionary = _collect_direct_tilemap_layers(root_node)
	var deco: TileMapLayer = layers.get("DecorationLayer") as TileMapLayer
	_check(G, deco != null, "DecorationLayer 缺失。")
	var used: Array = []
	if deco != null:
		used = deco.get_used_cells()
	_check(G, used.size() >= 1, "DecorationLayer 应至少有 1 个示例格，实际 %d 格。" % used.size())


## 15. 编辑示例 EditorGuide 自身承担中文职责说明：节点存在，且其子树文本覆盖
##     Terrain / LegalArea / Wall / Decoration / 绘制顺序 / 复制正式模板提示。
##     关键字必须来自 EditorGuide 子树；其他节点的 editor_description 不可单独令本契约通过。
##     只检查关键语义词，不绑定整段文案、精确换行或具体 Label 节点索引。
func _test_15_example_editor_guide_contract(root_node: Node2D) -> void:
	const G: String = "15_编辑示例EditorGuide说明契约"
	_check(G, root_node != null, "编辑示例根节点缺失。")
	if root_node == null:
		return
	# EditorGuide 必须承担主要人类编辑说明职责。
	var guide: Node = root_node.get_node_or_null("EditorGuide")
	_check(G, guide != null, "EditorGuide 节点不存在。")
	if guide == null:
		return
	# 关键字优先（且必须）从 EditorGuide 子树收集。
	var parts: Array = []
	_gather_text(guide, parts)
	var text: String = ""
	for p in parts:
		text += str(p) + " "
	_check(G, text.length() > 0, "EditorGuide 子树未收集到任何说明文本。")
	_check(G, text.contains("Terrain"), "EditorGuide 说明应覆盖 Terrain 关键词。")
	_check(G, text.contains("LegalArea"), "EditorGuide 说明应覆盖 LegalArea 关键词。")
	_check(G, text.contains("Wall"), "EditorGuide 说明应覆盖 Wall 关键词。")
	_check(G, text.contains("Decoration"), "EditorGuide 说明应覆盖 Decoration 关键词。")
	_check(G, text.contains("绘制顺序"), "EditorGuide 说明应覆盖绘制/编辑顺序。")
	_check(G, text.contains("复制") and text.contains("level_template"), "EditorGuide 说明应包含复制正式模板的提示。")
