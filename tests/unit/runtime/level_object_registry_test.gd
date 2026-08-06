extends SceneTree

## LevelObjectRegistry 定向自动测试（D3-C）：覆盖合法注册、按 ID/cell 查询、数量、空 ID/无效实例/重复 ID/重复 cell/同实例重复 拒绝、
## 集合返回副本、未登记查询、不读 Node.name、crystal_id 与 cell 相互独立、多水晶唯一性。
## 另含静态边界验证：get_placed_tokens_by_id_reference 已删除、LevelWorldQuery 不持可写机关映射或水晶容器、主原型场景水晶均有显式唯一 crystal_id 且数量一致。
## BasicCrystal 实例不加入场景树（避免 _ready 触发 VisualView 解析），仅设置 cell/crystal_id；测试结束统一 free。


const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")
const _BasicCrystalScript: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")

## 主原型场景 → basic_crystal.tscn 子场景 → basic_crystal.gd 根脚本 的真实资源链路径（测试 16 用）。
const _MAIN_SCENE_PATH: String = "res://levels/prototypes/core_loop_prototype.tscn"
const _CRYSTAL_SCENE_PATH: String = "res://gameplay/crystals/basic_crystal.tscn"
const _CRYSTAL_SCRIPT_PATH: String = "res://gameplay/crystals/basic_crystal.gd"


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0
## 本轮创建的水晶实例，统一释放避免 --script 模式泄漏。
var _crystals: Array[BasicCrystal] = []


## SceneTree 初始化入口：运行全部测试后统一报告、释放并退出。
func _initialize() -> void:
	_test_01_register_success()
	_test_02_get_by_id()
	_test_03_get_by_cell()
	_test_04_count()
	_test_05_empty_id_rejected_no_pollution()
	_test_06_invalid_instance_rejected()
	_test_07_duplicate_id_rejected_unchanged()
	_test_08_duplicate_cell_rejected_unchanged()
	_test_09_get_ids_returns_copy()
	_test_10_get_all_returns_copy()
	_test_11_unregistered_returns_null_false()
	_test_12_no_node_name_dependency()
	_test_13_id_cell_independent()
	_test_14_multiple_unique()
	_test_15_no_mutable_dict_exposed()
	_test_16_scene_crystal_ids_valid()
	_report()
	_cleanup()
	quit(0 if _failures.is_empty() else 1)


## 创建一颗不加入场景树的水晶并登记到统一释放列表。
func _make_crystal(crystal_id: StringName, cell: Vector2i) -> BasicCrystal:
	var crystal: BasicCrystal = _BasicCrystalScript.new()
	crystal.cell = cell
	crystal.crystal_id = crystal_id
	_crystals.append(crystal)
	return crystal


## 1. 合法水晶注册成功。
func _test_01_register_success() -> void:
	const NAME: String = "01_注册成功"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c001", Vector2i(1, 1))
	_check(NAME, r.register_crystal(&"c001", Vector2i(1, 1), c), "合法注册应返回 true。")
	_check(NAME, r.has_crystal(&"c001"), "has_crystal 应为 true。")
	_check(NAME, r.has_crystal_at(Vector2i(1, 1)), "has_crystal_at 应为 true。")


## 2. 按 ID 查询。
func _test_02_get_by_id() -> void:
	const NAME: String = "02_按ID查询"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c002", Vector2i(2, 2))
	r.register_crystal(&"c002", Vector2i(2, 2), c)
	_check(NAME, r.get_crystal(&"c002") == c, "get_crystal 应返回同一实例。")


## 3. 按 cell 查询。
func _test_03_get_by_cell() -> void:
	const NAME: String = "03_按cell查询"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c003", Vector2i(3, 3))
	r.register_crystal(&"c003", Vector2i(3, 3), c)
	_check(NAME, r.get_crystal_at(Vector2i(3, 3)) == c, "get_crystal_at 应返回同一实例。")


## 4. 数量正确。
func _test_04_count() -> void:
	const NAME: String = "04_数量正确"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	_check(NAME, r.get_crystal_count() == 0, "初始数量应为 0。")
	r.register_crystal(&"c004a", Vector2i(4, 4), _make_crystal(&"c004a", Vector2i(4, 4)))
	_check(NAME, r.get_crystal_count() == 1, "注册 1 颗后数量应为 1。")
	r.register_crystal(&"c004b", Vector2i(5, 5), _make_crystal(&"c004b", Vector2i(5, 5)))
	_check(NAME, r.get_crystal_count() == 2, "注册 2 颗后数量应为 2。")


## 5. 空 ID 拒绝且无污染。
func _test_05_empty_id_rejected_no_pollution() -> void:
	const NAME: String = "05_空ID拒绝无污染"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"", Vector2i(5, 5))
	_check(NAME, not r.register_crystal(&"", Vector2i(5, 5), c), "空 ID 应拒绝。")
	_check(NAME, r.get_crystal_count() == 0, "拒绝后数量应为 0。")
	_check(NAME, not r.has_crystal_at(Vector2i(5, 5)), "拒绝后 cell 不应被占用。")


## 6. 无效实例拒绝。
func _test_06_invalid_instance_rejected() -> void:
	const NAME: String = "06_无效实例拒绝"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c006", Vector2i(6, 6))
	c.free()
	_check(NAME, not r.register_crystal(&"c006", Vector2i(6, 6), c), "无效实例应拒绝。")
	_check(NAME, r.get_crystal_count() == 0, "拒绝后数量应为 0。")


## 7. 重复 ID 拒绝且原记录不变。
func _test_07_duplicate_id_rejected_unchanged() -> void:
	const NAME: String = "07_重复ID拒绝原记录不变"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var a: BasicCrystal = _make_crystal(&"c007", Vector2i(7, 7))
	r.register_crystal(&"c007", Vector2i(7, 7), a)
	var b: BasicCrystal = _make_crystal(&"c007", Vector2i(8, 8))
	_check(NAME, not r.register_crystal(&"c007", Vector2i(8, 8), b), "重复 ID 应拒绝。")
	_check(NAME, r.get_crystal_count() == 1, "拒绝后数量应仍为 1。")
	_check(NAME, r.get_crystal(&"c007") == a, "原记录应保持为 a。")
	_check(NAME, r.get_crystal_at(Vector2i(7, 7)) == a, "原 cell 反查应仍为 a。")
	_check(NAME, not r.has_crystal_at(Vector2i(8, 8)), "被拒 cell 不应被占用。")


## 8. 重复 cell 拒绝且原记录不变。
func _test_08_duplicate_cell_rejected_unchanged() -> void:
	const NAME: String = "08_重复cell拒绝原记录不变"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var a: BasicCrystal = _make_crystal(&"c008a", Vector2i(9, 9))
	r.register_crystal(&"c008a", Vector2i(9, 9), a)
	var b: BasicCrystal = _make_crystal(&"c008b", Vector2i(9, 9))
	_check(NAME, not r.register_crystal(&"c008b", Vector2i(9, 9), b), "重复 cell 应拒绝。")
	_check(NAME, r.get_crystal_count() == 1, "拒绝后数量应仍为 1。")
	_check(NAME, r.get_crystal_at(Vector2i(9, 9)) == a, "原 cell 反查应仍为 a。")
	_check(NAME, not r.has_crystal(&"c008b"), "被拒 ID 不应登记。")


## 9. get_crystal_ids 返回副本。
func _test_09_get_ids_returns_copy() -> void:
	const NAME: String = "09_get_crystal_ids返回副本"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	r.register_crystal(&"c009", Vector2i(10, 10), _make_crystal(&"c009", Vector2i(10, 10)))
	var ids: Array[StringName] = r.get_crystal_ids()
	ids.append(&"injected")
	var ids2: Array[StringName] = r.get_crystal_ids()
	_check(NAME, not ids2.has(&"injected"), "外部修改返回数组不应污染内部索引。")
	_check(NAME, ids2.size() == 1, "内部 ID 数应仍为 1。")


## 10. get_all_crystals 返回副本。
func _test_10_get_all_returns_copy() -> void:
	const NAME: String = "10_get_all_crystals返回副本"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	r.register_crystal(&"c010", Vector2i(11, 11), _make_crystal(&"c010", Vector2i(11, 11)))
	var all: Array[BasicCrystal] = r.get_all_crystals()
	all.clear()
	var all2: Array[BasicCrystal] = r.get_all_crystals()
	_check(NAME, all2.size() == 1, "外部 clear 返回数组不应影响内部索引。")


## 11. 未登记 ID/cell 返回 null 或 false。
func _test_11_unregistered_returns_null_false() -> void:
	const NAME: String = "11_未登记返回null或false"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	_check(NAME, r.get_crystal(&"nope") == null, "未登记 ID 应返回 null。")
	_check(NAME, r.get_crystal_at(Vector2i(99, 99)) == null, "未登记 cell 应返回 null。")
	_check(NAME, not r.has_crystal(&"nope"), "未登记 ID 应 has=false。")
	_check(NAME, not r.has_crystal_at(Vector2i(99, 99)), "未登记 cell 应 has=false。")


## 12. 不读取 Node.name。
func _test_12_no_node_name_dependency() -> void:
	const NAME: String = "12_不读Node.name"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c012", Vector2i(12, 12))
	c.name = "SomeNodeName"
	_check(NAME, r.register_crystal(&"c012", Vector2i(12, 12), c), "应以 crystal_id 注册而非 Node.name。")
	_check(NAME, r.get_crystal(&"c012") == c, "按 crystal_id 应查到实例。")
	_check(NAME, r.get_crystal(&"SomeNodeName") == null, "按 Node.name 不应查到实例。")
	_check(NAME, not r.has_crystal(&"SomeNodeName"), "Node.name 不应作为 ID。")


## 13. crystal_id 与 cell 相互独立。
func _test_13_id_cell_independent() -> void:
	const NAME: String = "13_crystal_id与cell相互独立"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var c: BasicCrystal = _make_crystal(&"c013", Vector2i(13, 13))
	r.register_crystal(&"c013", Vector2i(13, 13), c)
	c.cell = Vector2i(99, 99)
	_check(NAME, c.get_crystal_id() == &"c013", "cell 变化后 crystal_id 应保持不变。")
	_check(NAME, r.get_crystal(&"c013") == c, "cell 变化后按 ID 仍应查到原实例。")


## 14. 多水晶注册保持唯一性。
func _test_14_multiple_unique() -> void:
	const NAME: String = "14_多水晶唯一性"
	var r: _LevelObjectRegistry = _LevelObjectRegistry.new()
	r.register_crystal(&"c014a", Vector2i(14, 1), _make_crystal(&"c014a", Vector2i(14, 1)))
	r.register_crystal(&"c014b", Vector2i(14, 2), _make_crystal(&"c014b", Vector2i(14, 2)))
	r.register_crystal(&"c014c", Vector2i(14, 3), _make_crystal(&"c014c", Vector2i(14, 3)))
	_check(NAME, r.get_crystal_count() == 3, "三颗注册后数量应为 3。")
	var ids: Array[StringName] = r.get_crystal_ids()
	_check(NAME, ids.size() == 3, "ID 数应为 3。")
	var seen: Dictionary = {}
	for id: StringName in ids:
		_check(NAME, not seen.has(id), "ID 不应重复：%s" % [id])
		seen[id] = true
		_check(NAME, r.has_crystal(id), "每个 ID 应可查。")


## 15. 可变 Dictionary 暴露收紧：get_placed_tokens_by_id_reference 已删除，LevelWorldQuery 不持可写机关映射或水晶容器。
func _test_15_no_mutable_dict_exposed() -> void:
	const NAME: String = "15_可写字典暴露收紧"
	var pc_src: String = FileAccess.get_file_as_string("res://gameplay/placement/placement_controller.gd")
	_check(NAME, pc_src.find("get_placed_tokens_by_id_reference") == -1, "PlacementController 不应再暴露 get_placed_tokens_by_id_reference。")
	var lwq_src: String = FileAccess.get_file_as_string("res://gameplay/world/level_world_query.gd")
	_check(NAME, lwq_src.find("placed_tokens_by_id") == -1, "LevelWorldQuery 不应持有 placed_tokens_by_id。")
	_check(NAME, lwq_src.find("_crystals") == -1, "LevelWorldQuery 不应持有可写 crystals 数组。")


## 16. 主原型场景水晶资源链契约：主场景引用 basic_crystal.tscn PackedScene 并实例化 Crystal 节点，
## 子场景根节点挂载 basic_crystal.gd；每个 Crystal 实例显式覆盖非空唯一 crystal_id，且不依赖 Node.name。
## 通过 PackedScene.get_state() 的 SceneState 稳定读取资源链（与 crystal_contract_test 同源做法），
## 既不实例化整个原型场景（避免 _ready/VisualView 副作用），也不做脆弱的单点文本子串匹配。
## 注：Godot 4.6 SceneState 不暴露 ext_resource 枚举，故“主场景引用 basic_crystal.tscn”由发现实例化该资源的
## Crystal 节点直接证明（引用而未实例化的 PackedScene 对契约无意义，且 Godot 会警告未用 ext_resource）。
func _test_16_scene_crystal_ids_valid() -> void:
	const NAME: String = "16_场景水晶显式唯一crystal_id"
	var main_scene: PackedScene = load(_MAIN_SCENE_PATH) as PackedScene
	_check(NAME, main_scene != null, "主原型场景应能加载为 PackedScene。")
	if main_scene == null:
		return
	var main_state: SceneState = main_scene.get_state()

	# 契约3：basic_crystal.tscn 根节点（非 instance 子节点）挂载 basic_crystal.gd。
	var sub_scene: PackedScene = load(_CRYSTAL_SCENE_PATH) as PackedScene
	_check(NAME, sub_scene != null, "basic_crystal.tscn 应能加载为 PackedScene。")
	var root_mounts_script: bool = false
	if sub_scene != null:
		var sub_state: SceneState = sub_scene.get_state()
		for i: int in range(sub_state.get_node_count()):
			if sub_state.get_node_instance(i) != null:
				continue
			for j: int in range(sub_state.get_node_property_count(i)):
				if sub_state.get_node_property_name(i, j) != &"script":
					continue
				var scr: Script = sub_state.get_node_property_value(i, j) as Script
				if scr != null and scr.resource_path == _CRYSTAL_SCRIPT_PATH:
					root_mounts_script = true
	_check(NAME, root_mounts_script, "basic_crystal.tscn 根节点应挂载 basic_crystal.gd。")

	# 契约1+2：按 instance 资源识别 Crystal 实例（不读 Node.name）。发现实例化 basic_crystal.tscn 的节点即
	# 证明主场景引用该 PackedScene；节点数 >= 1 即实例化至少一个 Crystal。逐节点校验显式、非空 crystal_id。
	var crystal_ids: Array[StringName] = []
	var crystal_node_count: int = 0
	for i: int in range(main_state.get_node_count()):
		var inst: PackedScene = main_state.get_node_instance(i)
		if inst == null:
			continue
		if inst != sub_scene and inst.resource_path != _CRYSTAL_SCENE_PATH:
			continue
		crystal_node_count += 1
		var cid: StringName = &""
		var has_cid_override: bool = false
		for j: int in range(main_state.get_node_property_count(i)):
			if main_state.get_node_property_name(i, j) == &"crystal_id":
				cid = main_state.get_node_property_value(i, j)
				has_cid_override = true
		_check(NAME, has_cid_override, "每个 Crystal 实例应显式覆盖 crystal_id 属性，不得依赖 Node.name 或默认空值。")
		_check(NAME, cid != &"", "Crystal 实例 crystal_id 不应为空。")
		crystal_ids.append(cid)
	_check(NAME, crystal_node_count >= 1, "主场景应引用 basic_crystal.tscn 并实例化至少一个 Crystal 节点，实际 %d。" % [crystal_node_count])
	_check(NAME, crystal_ids.size() == crystal_node_count, "crystal_id 数量应等于 Crystal 实例数：%d vs %d。" % [crystal_ids.size(), crystal_node_count])

	# 契约5：crystal_id 全局唯一。
	var seen: Dictionary = {}
	for cid: StringName in crystal_ids:
		_check(NAME, not seen.has(cid), "Crystal crystal_id 不应重复：%s。" % [cid])
		seen[cid] = true


## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 释放本轮创建的水晶实例（跳过已释放的）。
func _cleanup() -> void:
	for i: int in range(_crystals.size()):
		var crystal: BasicCrystal = _crystals[i]
		if is_instance_valid(crystal):
			crystal.free()
	_crystals.clear()


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 16
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelObjectRegistry D3-C 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
