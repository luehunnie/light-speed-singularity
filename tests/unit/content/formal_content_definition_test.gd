extends SceneTree

## AF-01 定向合同测试 1/3：三域 Definition、content_type_id、Definition 校验、
## FormalContentBinding 薄身份、StableInstanceIdAllocator 生命周期发号。
## 覆盖：基类默认与域 token、三子域层级与 get_content_domain、validate_definition 全校验域
## （空 type/空名/缺场景/发射器 token 越界）、Binding 两层身份与 make/is_valid、
## 分配器单调递增/不复用/确定性格式/独立实例互不串号。
## 约束：不修改场景/资源；PackedScene 经 Node2D.pack 程序化构造；headless --script 运行。


const _BaseDef: GDScript = preload("res://gameplay/content/formal_content_definition.gd")
const _MechDef: GDScript = preload("res://gameplay/content/mechanism_definition.gd")
const _ObjDef: GDScript = preload("res://gameplay/content/objective_target_definition.gd")
const _EmitterDef: GDScript = preload("res://gameplay/content/emitter_definition.gd")
const _Binding: GDScript = preload("res://gameplay/content/formal_content_binding.gd")
const _Allocator: GDScript = preload("res://gameplay/content/stable_instance_id_allocator.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_base_defaults()
	_test_02_domain_hierarchy()
	_test_03_validate_base_rules()
	_test_04_emitter_domain_validation()
	_test_05_binding_thin_identity()
	_test_06_allocator_lifecycle()
	_test_07_mechanism_light_forms()
	_report()


## 构造程序化合法场景（无文件资源依赖）。
func _make_scene() -> PackedScene:
	var root := Node2D.new()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _make_valid_base(def_script: GDScript) -> Resource:
	var definition: Resource = def_script.new()
	definition.content_type_id = &"test_type"
	definition.display_name = "测试类型"
	definition.scene = _make_scene()
	return definition


func _test_01_base_defaults() -> void:
	const NAME := "01_基类默认"
	var definition: Resource = _BaseDef.new()
	_check(NAME, definition.content_type_id == &"", "默认 content_type_id 应为空。")
	_check(NAME, definition.display_name.is_empty(), "默认 display_name 应为空。")
	_check(NAME, definition.scene == null, "默认 scene 应为 null。")
	_check(NAME, definition.preplaceable, "默认应允许预放置。")
	_check(NAME, definition.supports_stable_instance, "默认应支持稳定实例。")
	_check(NAME, definition.supports_editor_note, "默认应支持作者备注。")
	_check(NAME, definition.get_content_domain() == &"", "基类域 token 应为空。")
	_check(NAME, definition is Resource, "Definition 应为 Resource（可作 .tres 声明）。")


func _test_02_domain_hierarchy() -> void:
	const NAME := "02_三域分域"
	var mechanism: Resource = _make_valid_base(_MechDef)
	var objective: Resource = _make_valid_base(_ObjDef)
	var emitter: Resource = _make_valid_base(_EmitterDef)
	_check(NAME, mechanism is _BaseDef, "MechanismDefinition 应继承 FormalContentDefinition。")
	_check(NAME, objective is _BaseDef, "ObjectiveTargetDefinition 应继承 FormalContentDefinition。")
	_check(NAME, emitter is _BaseDef, "EmitterDefinition 应继承 FormalContentDefinition。")
	_check(NAME, mechanism.get_content_domain() == &"mechanism", "机关域 token 应为 mechanism。")
	_check(NAME, objective.get_content_domain() == &"objective_target", "目标域 token 应为 objective_target。")
	_check(NAME, emitter.get_content_domain() == &"emitter", "发射器域 token 应为 emitter。")
	_check(NAME, not mechanism.get(&"inventory_eligible"), "机关默认不可入库存。")
	_check(NAME, objective.get(&"base_success_on_hit"), "目标默认基础成功。")
	_check(NAME, emitter.get(&"initial_form") == &"RAY", "发射器默认初始形态应为 RAY。")
	_check(NAME, emitter.get(&"initial_direction") == &"E", "发射器默认初始朝向应为 E。")


func _test_03_validate_base_rules() -> void:
	const NAME := "03_基类校验域"
	var definition: Resource = _BaseDef.new()
	var errors: PackedStringArray = definition.validate_definition()
	_check(NAME, errors.size() == 3, "空定义应报 3 项错误（type/名/场景），实际 %d。" % errors.size())
	definition.content_type_id = &"a"
	definition.display_name = "A"
	errors = definition.validate_definition()
	_check(NAME, errors.size() == 1, "仅缺场景应报 1 项错误，实际 %d。" % errors.size())
	_check(NAME, errors[0].find("PackedScene") >= 0, "缺场景错误应含 PackedScene 字样。")
	definition.scene = _make_scene()
	errors = definition.validate_definition()
	_check(NAME, errors.is_empty(), "补齐后应无错误。")


func _test_04_emitter_domain_validation() -> void:
	const NAME := "04_发射器域校验"
	var emitter: Resource = _make_valid_base(_EmitterDef)
	emitter.initial_form = &"BOGUS"
	var errors: PackedStringArray = emitter.validate_definition()
	_check(NAME, errors.size() == 1 and errors[0].find("initial_form") >= 0, "越界 initial_form 应报错。")
	emitter.initial_form = &"PARTICLE"
	emitter.initial_direction = &"UP_INVALID"
	errors = emitter.validate_definition()
	_check(NAME, errors.size() == 1 and errors[0].find("initial_direction") >= 0, "越界 initial_direction 应报错。")
	emitter.initial_direction = &"SW"
	errors = emitter.validate_definition()
	_check(NAME, errors.is_empty(), "合法 token 组合应无错误。")


func _test_05_binding_thin_identity() -> void:
	const NAME := "05_薄身份组件"
	var empty_binding: RefCounted = _Binding.new()
	_check(NAME, not empty_binding.is_valid(), "空 Binding 应不合法。")
	var binding: RefCounted = _Binding.make(&"mech_mirror", "fci_0000001")
	_check(NAME, binding.is_valid(), "make 构造应合法。")
	_check(NAME, binding.get(&"content_type_id") == &"mech_mirror", "Binding 应持类型身份。")
	_check(NAME, binding.get(&"stable_instance_id") == "fci_0000001", "Binding 应持实例身份。")
	var script: Script = binding.get_script()
	var prop_names: Array[String] = []
	for prop: Dictionary in script.get_script_property_list():
		if String(prop["name"]).ends_with(".gd"):
			continue
		prop_names.append(String(prop["name"]))
	_check(NAME, prop_names.size() == 2, "Binding 应只持两层身份属性（实际 %d 个）。" % prop_names.size())
	_check(NAME, prop_names.has("content_type_id") and prop_names.has("stable_instance_id"), "Binding 属性应恰为两层身份。")


func _test_06_allocator_lifecycle() -> void:
	const NAME := "06_稳定ID分配器"
	var allocator: RefCounted = _Allocator.new()
	var first: String = allocator.allocate()
	var second: String = allocator.allocate()
	var third: String = allocator.allocate()
	_check(NAME, first == "fci_0000001", "首号应为 fci_0000001，实际 %s。" % first)
	_check(NAME, second == "fci_0000002", "次号应为 fci_0000002，实际 %s。" % second)
	_check(NAME, third == "fci_0000003", "三号应为 fci_0000003，实际 %s。" % third)
	_check(NAME, allocator.get_allocated_count() == 3, "已分配数应为 3。")
	var allocator_b: RefCounted = _Allocator.new()
	_check(NAME, allocator_b.allocate() == "fci_0000001", "新分配器会话独立应从 1 起。")
	var ids: Dictionary = {}
	for i: int in range(50):
		ids[allocator.allocate()] = true
	_check(NAME, ids.size() == 50, "50 次分配应全不重复。")


## 7. 机关光照交互形态声明（AF-02 / P0-3 additive）：默认空 = 全透明；合法子集通过；非法 token / 重复声明拒绝。
func _test_07_mechanism_light_forms() -> void:
	const NAME := "07_机关光形态声明"
	var definition: Resource = _make_valid_base(_MechDef)
	_check(NAME, definition.get(&"light_interaction_forms") == [], "默认光形态声明应为空（全透明）。")
	_check(NAME, definition.validate_definition().is_empty(), "默认（空声明）应合法。")
	var both: Array[StringName] = [&"RAY", &"PARTICLE"]
	definition.light_interaction_forms = both
	_check(NAME, definition.validate_definition().is_empty(), "声明 RAY+PARTICLE 应合法。")
	var particle_only: Array[StringName] = [&"PARTICLE"]
	definition.light_interaction_forms = particle_only
	_check(NAME, definition.validate_definition().is_empty(), "仅声明 PARTICLE 应合法（加速器语义）。")
	var with_bogus: Array[StringName] = [&"RAY", &"BEAM"]
	definition.light_interaction_forms = with_bogus
	var errors: PackedStringArray = definition.validate_definition()
	_check(NAME, not errors.is_empty(), "非法形态 BEAM 应被拒绝。")
	var duplicated: Array[StringName] = [&"RAY", &"RAY"]
	definition.light_interaction_forms = duplicated
	_check(NAME, not definition.validate_definition().is_empty(), "重复声明应被拒绝。")
	definition.light_interaction_forms = both
	_check(NAME, definition.validate_definition().is_empty(), "恢复合法声明后应再次合法（无残留状态）。")


func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


func _report() -> void:
	print("==== AF-01 Definition/Binding/Allocator 合同测试摘要 ====")
	print("测试组数：7")
	print("断言总数：%d" % _checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
	quit(1 if not _failures.is_empty() else 0)
