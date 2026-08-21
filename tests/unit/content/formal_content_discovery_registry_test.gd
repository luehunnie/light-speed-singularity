extends SceneTree

## AF-01 定向合同测试 2/3：Definition Discovery + Formal Content Registry（P0-1）。
## 覆盖：目录扫描发现三域定义、按文件名序、重复 content_type_id 拒绝、非法定义拒绝
## （空 type/空名/缺场景）、非定义资源混入拒绝、目录缺失 fail-fast、
## 新增类型零中心修改证明（同目录追加声明即被发现）、Registry 构建/查询/域过滤/
## 重复与杂项拒绝构建、Registry 无逐项注册 API（只读索引）。
## fixture：user:// 临时目录内程序化生成 .tres（PackedScene 经 Node2D.pack），用例后清理。


const _Discovery: GDScript = preload("res://gameplay/content/formal_content_discovery.gd")
const _Registry: GDScript = preload("res://gameplay/content/formal_content_registry.gd")
const _MechDef: GDScript = preload("res://gameplay/content/mechanism_definition.gd")
const _ObjDef: GDScript = preload("res://gameplay/content/objective_target_definition.gd")
const _EmitterDef: GDScript = preload("res://gameplay/content/emitter_definition.gd")

const _FIXTURE_ROOT: String = "user://af01_discovery_fixture"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_prepare_fixture_root()
	_test_01_discover_valid_three_domains()
	_test_02_duplicate_type_id_rejected()
	_test_03_illegal_definition_rejected()
	_test_04_non_definition_resource_rejected()
	_test_05_missing_directory_fails()
	_test_06_adding_type_requires_no_central_edit()
	_test_07_registry_build_and_query()
	_test_08_registry_rejects_bad_builds()
	_cleanup()
	_report()


func _prepare_fixture_root() -> void:
	var dir := DirAccess.open("user://")
	if dir.dir_exists(_FIXTURE_ROOT.replace("user://", "")):
		_remove_dir(_FIXTURE_ROOT)
	dir.make_dir_recursive(_FIXTURE_ROOT)


## 清空并重建一个场景目录。
func _fresh_dir(scenario: String) -> String:
	var path := "%s/%s" % [_FIXTURE_ROOT, scenario]
	_remove_dir(path)
	DirAccess.make_dir_recursive_absolute(path)
	return path


## 删除目录内全部文件与目录本身（仅本 fixture 范围，无嵌套子目录场景）。
func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var names: Array[String] = []
	var entry := dir.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for name: String in names:
		dir.remove(name)
	DirAccess.open("user://").remove(path.trim_prefix("user://"))


## 构造并保存一个定义 .tres；script 传具体域脚本，字段字典覆盖导出属性。
func _save_definition(path: String, def_script: GDScript, overrides: Dictionary) -> void:
	var definition: Resource = def_script.new()
	definition.content_type_id = overrides.get(&"content_type_id", &"")
	definition.display_name = overrides.get(&"display_name", "")
	var root := Node2D.new()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	if overrides.get(&"with_scene", true):
		definition.set(&"scene", packed)
	for key: Variant in overrides:
		if key == &"content_type_id" or key == &"display_name" or key == &"with_scene":
			continue
		definition.set(key, overrides[key])
	var save_error := ResourceSaver.save(definition, path)
	_check("fixture", save_error == OK, "保存 fixture 失败：%s（%d）" % [path, save_error])


## 聚合错误文本。
func _join_errors(errors: PackedStringArray) -> String:
	var joined := ""
	for error: String in errors:
		joined += error + "\n"
	return joined


func _test_01_discover_valid_three_domains() -> void:
	const NAME := "01_三域发现"
	var dir := _fresh_dir("s1")
	_save_definition(dir.path_join("a_mech.tres"), _MechDef, {&"content_type_id": &"mech_slope", &"display_name": "斜面镜"})
	_save_definition(dir.path_join("b_target.tres"), _ObjDef, {&"content_type_id": &"target_basic", &"display_name": "基础水晶"})
	_save_definition(dir.path_join("c_emitter.tres"), _EmitterDef, {&"content_type_id": &"emitter_main", &"display_name": "主发射器"})
	var result: Dictionary = _Discovery.discover(dir)
	_check(NAME, result.ok, "三域合法集应发现成功：%s" % _join_errors(result.errors))
	_check(NAME, result.definitions.size() == 3, "应发现 3 个定义，实际 %d。" % result.definitions.size())
	if result.definitions.size() == 3:
		var domains: Array[StringName] = []
		for definition: Variant in result.definitions:
			domains.append(definition.get_content_domain())
		_check(NAME, domains[0] == &"mechanism" and domains[1] == &"objective_target" and domains[2] == &"emitter", "应按文件名序输出三域。")


func _test_02_duplicate_type_id_rejected() -> void:
	const NAME := "02_重复类型拒绝"
	var dir := _fresh_dir("s2")
	_save_definition(dir.path_join("a.tres"), _MechDef, {&"content_type_id": &"dup_type", &"display_name": "A"})
	_save_definition(dir.path_join("b.tres"), _MechDef, {&"content_type_id": &"dup_type", &"display_name": "B"})
	var result: Dictionary = _Discovery.discover(dir)
	_check(NAME, not result.ok, "重复 content_type_id 应 fail-fast。")
	_check(NAME, _join_errors(result.errors).find("重复 content_type_id") >= 0, "错误应指明重复 content_type_id。")


func _test_03_illegal_definition_rejected() -> void:
	const NAME := "03_非法定义拒绝"
	var dir := _fresh_dir("s3")
	_save_definition(dir.path_join("a_bad.tres"), _MechDef, {&"content_type_id": &"", &"display_name": "", &"with_scene": false})
	_save_definition(dir.path_join("b_ok.tres"), _ObjDef, {&"content_type_id": &"ok_type", &"display_name": "OK"})
	var result: Dictionary = _Discovery.discover(dir)
	_check(NAME, not result.ok, "含非法定义应 fail-fast。")
	var joined := _join_errors(result.errors)
	_check(NAME, joined.find("content_type_id 为空") >= 0, "应报空 type。")
	_check(NAME, joined.find("display_name 为空") >= 0, "应报空名。")
	_check(NAME, joined.find("PackedScene 缺失") >= 0, "应报缺场景。")


func _test_04_non_definition_resource_rejected() -> void:
	const NAME := "04_杂项资源拒绝"
	var dir := _fresh_dir("s4")
	_save_definition(dir.path_join("a_ok.tres"), _ObjDef, {&"content_type_id": &"ok_type", &"display_name": "OK"})
	var plain := Resource.new()
	ResourceSaver.save(plain, dir.path_join("b_plain.tres"))
	var result: Dictionary = _Discovery.discover(dir)
	_check(NAME, not result.ok, "非定义资源应 fail-fast。")
	_check(NAME, _join_errors(result.errors).find("非 FormalContentDefinition") >= 0, "应指明混入非定义资源。")


func _test_05_missing_directory_fails() -> void:
	const NAME := "05_目录缺失"
	var result: Dictionary = _Discovery.discover("user://af01_discovery_fixture/no_such_dir")
	_check(NAME, not result.ok, "目录缺失应 fail-fast。")
	_check(NAME, result.definitions.is_empty(), "目录缺失不得产出定义。")


func _test_06_adding_type_requires_no_central_edit() -> void:
	const NAME := "06_零中心修改"
	var dir := _fresh_dir("s6")
	_save_definition(dir.path_join("a.tres"), _MechDef, {&"content_type_id": &"t_one", &"display_name": "一"})
	var result_before: Dictionary = _Discovery.discover(dir)
	_check(NAME, result_before.ok and result_before.definitions.size() == 1, "初始应发现 1 个。")
	_save_definition(dir.path_join("b_new_type.tres"), _MechDef, {&"content_type_id": &"t_two", &"display_name": "二"})
	var result_after: Dictionary = _Discovery.discover(dir)
	_check(NAME, result_after.ok and result_after.definitions.size() == 2, "仅追加声明文件即被发现为 2 个，零中心修改。")


func _test_07_registry_build_and_query() -> void:
	const NAME := "07_索引构建查询"
	var dir := _fresh_dir("s7")
	_save_definition(dir.path_join("a.tres"), _MechDef, {&"content_type_id": &"q_mech", &"display_name": "机关"})
	_save_definition(dir.path_join("b.tres"), _ObjDef, {&"content_type_id": &"q_target", &"display_name": "目标"})
	_save_definition(dir.path_join("c.tres"), _EmitterDef, {&"content_type_id": &"q_emitter", &"display_name": "发射器"})
	var result: Dictionary = _Discovery.discover(dir)
	var registry: Variant = _Registry.build(result.definitions)
	if registry == null:
		_check(NAME, false, "合法集应可构建索引。")
		return
	_check(NAME, true, "合法集应可构建索引。")
	_check(NAME, registry.get_type_count() == 3, "索引应含 3 类型。")
	_check(NAME, registry.has_type(&"q_mech") and registry.has_type(&"q_target") and registry.has_type(&"q_emitter"), "三类型均可查询。")
	_check(NAME, registry.get_definition(&"q_mech").display_name == "机关", "按类型应取回定义元数据。")
	_check(NAME, registry.get_definition(&"nope") == null, "未登记类型应返回 null。")
	_check(NAME, registry.get_type_ids() == [&"q_mech", &"q_target", &"q_emitter"], "类型序应为发现序。")
	var mechs: Array = registry.get_definitions_in_domain(&"mechanism")
	_check(NAME, mechs.size() == 1 and mechs[0].content_type_id == &"q_mech", "域过滤应只含机关。")
	_check(NAME, registry.get_definitions_in_domain(&"emitter").size() == 1, "发射器域过滤为 1。")


func _test_08_registry_rejects_bad_builds() -> void:
	const NAME := "08_构建防御"
	var good: Resource = _MechDef.new()
	good.content_type_id = &"r_a"
	good.display_name = "A"
	good.set(&"scene", _make_packed())
	var good_b: Resource = _MechDef.new()
	good_b.content_type_id = &"r_a"
	good_b.display_name = "A2"
	good_b.set(&"scene", _make_packed())
	_check(NAME, _Registry.build([good, good_b]) == null, "重复类型应拒绝构建。")
	_check(NAME, _Registry.build([RefCounted.new()]) == null, "非定义条目应拒绝构建。")
	var empty_id: Resource = _MechDef.new()
	empty_id.content_type_id = &""
	_check(NAME, _Registry.build([empty_id]) == null, "空类型应拒绝构建。")
	_check(NAME, _Registry.build([good]) != null, "单合法定义应构建成功。")


func _make_packed() -> PackedScene:
	var root := Node2D.new()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 清理 fixture 根目录。
func _cleanup() -> void:
	_remove_dir(_FIXTURE_ROOT)


func _report() -> void:
	print("==== AF-01 Discovery/ContentRegistry 合同测试摘要 ====")
	print("测试组数：8")
	print("断言总数：%d" % _checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
	quit(1 if not _failures.is_empty() else 0)
