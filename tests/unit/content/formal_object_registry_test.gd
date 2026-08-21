extends SceneTree

## AF-01 定向合同测试 3/3：Formal Object Registry（P0-2）。
## 覆盖：预置注册（显式关卡初始 ID + 自动补发）、Spawn 总新 ID（复制语义）、
## 按稳定 ID / 格 / 类型 / 来源域查询、移动保 ID 与已占格拒绝、
## 注销（Recover）后原 ID 失效、Reset（预置保 ID 回初始格、动态清除）、
## 类型已知性校验（注入 Content Registry 时拒绝未声明类型）、
## 空 type / 重复 ID / 已占格零污染拒绝、快照 detached 只读边界。
## 身份卫生：全部断言不读节点名/节点路径；身份仅来自 stable_instance_id。


const _ObjectRegistry: GDScript = preload("res://gameplay/content/formal_object_registry.gd")
const _ContentRegistry: GDScript = preload("res://gameplay/content/formal_content_registry.gd")
const _MechDef: GDScript = preload("res://gameplay/content/mechanism_definition.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_preplaced_register()
	_test_02_spawn_always_new_id()
	_test_03_query_paths()
	_test_04_move_keeps_identity()
	_test_05_unregister_recover()
	_test_06_reset_semantics()
	_test_07_type_gating()
	_test_08_rejection_zero_pollution()
	_test_09_snapshot_detached()
	_report()


## 构造带单个类型的类型索引（类型已知性校验用）。
func _make_content_registry() -> Variant:
	var definition: Resource = _MechDef.new()
	definition.content_type_id = &"mech_known"
	definition.display_name = "已知机关"
	var root := Node2D.new()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	definition.set(&"scene", packed)
	return _ContentRegistry.build([definition])


func _test_01_preplaced_register() -> void:
	const NAME := "01_预置注册"
	var registry: Variant = _ObjectRegistry.new()
	var explicit: String = registry.register_preplaced(&"mech_a", Vector2i(3, 4), null, "level_initial_1")
	_check(NAME, explicit == "level_initial_1", "显式初始 ID 应原样采用。")
	var auto: String = registry.register_preplaced(&"mech_a", Vector2i(5, 6))
	_check(NAME, auto.begins_with("fci_"), "空 ID 时应自动补发（%s）。" % auto)
	var snapshot: Dictionary = registry.get_object_snapshot("level_initial_1")
	_check(NAME, snapshot.size() == 6, "快照应含 6 字段。")
	_check(NAME, snapshot.content_type_id == &"mech_a", "快照应含类型。")
	_check(NAME, snapshot.origin == &"preplaced", "来源应为 preplaced。")
	_check(NAME, snapshot.cell == Vector2i(3, 4), "快照应含当前格。")
	_check(NAME, snapshot.initial_cell == Vector2i(3, 4), "预置应记录初始格。")
	_check(NAME, registry.get_object_snapshot("nope") == {}, "未登记应返回空字典。")


func _test_02_spawn_always_new_id() -> void:
	const NAME := "02_Spawn总新ID"
	var registry: Variant = _ObjectRegistry.new()
	var first: String = registry.register_spawn(&"mech_b", Vector2i(1, 1))
	var second: String = registry.register_spawn(&"mech_b", Vector2i(2, 2))
	_check(NAME, first != "" and second != "", "两次 Spawn 均应成功。")
	_check(NAME, first != second, "两次 Spawn 必得不同新 ID。")
	var duplicate: String = registry.register_spawn(&"mech_b", Vector2i(3, 3))
	_check(NAME, duplicate != first and duplicate != second, "复制语义同样获新 ID。")
	var snapshot: Dictionary = registry.get_object_snapshot(second)
	_check(NAME, snapshot.origin == &"spawned", "Spawn 来源应为 spawned。")


func _test_03_query_paths() -> void:
	const NAME := "03_查询路径"
	var registry: Variant = _ObjectRegistry.new()
	registry.register_preplaced(&"mech_c", Vector2i(0, 0), null, "p1")
	registry.register_spawn(&"mech_c", Vector2i(1, 0))
	registry.register_spawn(&"mech_d", Vector2i(2, 0))
	_check(NAME, registry.get_count() == 3, "总数应为 3。")
	_check(NAME, registry.get_stable_id_at(Vector2i(1, 0)) != "", "按格应查到 Spawn 实例。")
	_check(NAME, registry.has_object_at(Vector2i(2, 0)), "占格查询应为真。")
	_check(NAME, not registry.has_object_at(Vector2i(9, 9)), "空格应为假。")
	_check(NAME, registry.get_stable_id_at(Vector2i(9, 9)) == "", "空格 ID 应为空串。")
	var of_c: Array = registry.get_stable_ids_of_type(&"mech_c")
	_check(NAME, of_c.size() == 2, "按类型应查到 2 个。")
	_check(NAME, registry.get_stable_ids_of_type(&"mech_none").is_empty(), "未知类型应为空集。")
	var spawned_ids: Array = registry.get_stable_ids_by_origin(&"spawned")
	_check(NAME, spawned_ids.size() == 2, "动态来源应为 2 个。")
	_check(NAME, registry.get_stable_ids_by_origin(&"preplaced").size() == 1, "预置来源应为 1 个。")
	_check(NAME, registry.has_object("p1"), "稳定 ID 存在性查询。")


func _test_04_move_keeps_identity() -> void:
	const NAME := "04_移动保ID"
	var registry: Variant = _ObjectRegistry.new()
	var id_a: String = registry.register_preplaced(&"mech_e", Vector2i(4, 4), null, "m1")
	var id_b: String = registry.register_preplaced(&"mech_e", Vector2i(6, 6), null, "m2")
	_check(NAME, registry.move_object(id_a, Vector2i(5, 5)), "合法移动应成功。")
	_check(NAME, registry.get_object_snapshot(id_a).cell == Vector2i(5, 5), "移动后应在新格。")
	_check(NAME, registry.get_stable_id_at(Vector2i(5, 5)) == id_a, "新格索引应指向原 ID。")
	_check(NAME, registry.get_stable_id_at(Vector2i(4, 4)) == "", "旧格索引应释放。")
	_check(NAME, registry.get_object_snapshot(id_a).stable_instance_id == "m1", "移动后 ID 应保持。")
	_check(NAME, not registry.move_object(id_a, Vector2i(6, 6)), "移动到已占格应拒绝。")
	_check(NAME, not registry.move_object("ghost", Vector2i(0, 0)), "未知 ID 移动应拒绝。")
	_check(NAME, registry.move_object(id_b, Vector2i(6, 6)), "同格移动应为幂等成功。")
	_check(NAME, registry.get_count() == 2, "移动不改变实例数。")


func _test_05_unregister_recover() -> void:
	const NAME := "05_注销失效"
	var registry: Variant = _ObjectRegistry.new()
	var id_a: String = registry.register_spawn(&"mech_f", Vector2i(2, 2))
	_check(NAME, registry.unregister(id_a), "注销登记实例应成功。")
	_check(NAME, not registry.has_object(id_a), "注销后原 ID 应失效。")
	_check(NAME, not registry.has_object_at(Vector2i(2, 2)), "注销后格子应释放。")
	_check(NAME, not registry.unregister(id_a), "重复注销应失败。")
	var respawn: String = registry.register_spawn(&"mech_f", Vector2i(2, 2))
	_check(NAME, respawn != id_a, "再次 Spawn 必得新 ID（原 ID 不复用）。")


func _test_06_reset_semantics() -> void:
	const NAME := "06_Reset语义"
	var registry: Variant = _ObjectRegistry.new()
	var pre_id: String = registry.register_preplaced(&"mech_g", Vector2i(1, 1), null, "pre_keep")
	var spawn_id: String = registry.register_spawn(&"mech_g", Vector2i(2, 2))
	registry.move_object(pre_id, Vector2i(7, 7))
	var removed: int = registry.reset_level()
	_check(NAME, removed == 1, "Reset 应清除 1 个动态实例。")
	_check(NAME, not registry.has_object(spawn_id), "动态实例应被清除。")
	_check(NAME, registry.has_object(pre_id), "预置实例应保留。")
	var snapshot: Dictionary = registry.get_object_snapshot(pre_id)
	_check(NAME, snapshot.stable_instance_id == "pre_keep", "预置应保持关卡初始 ID。")
	_check(NAME, snapshot.cell == Vector2i(1, 1), "预置应回到初始格。")
	_check(NAME, registry.get_stable_id_at(Vector2i(7, 7)) == "", "移动格索引应清理。")
	_check(NAME, registry.get_stable_id_at(Vector2i(1, 1)) == pre_id, "初始格索引应恢复。")


func _test_07_type_gating() -> void:
	const NAME := "07_类型已知性"
	var content: Variant = _make_content_registry()
	var registry: Variant = _ObjectRegistry.new(content)
	_check(NAME, registry.register_preplaced(&"mech_known", Vector2i(0, 0), null, "g1") != "", "已声明类型应可注册。")
	_check(NAME, registry.register_preplaced(&"mech_unknown", Vector2i(1, 0)) == "", "未声明类型应拒绝。")
	_check(NAME, registry.register_spawn(&"mech_unknown", Vector2i(2, 0)) == "", "未声明类型 Spawn 应拒绝。")
	_check(NAME, registry.get_count() == 1, "拒绝项不得污染索引。")
	var ungated: Variant = _ObjectRegistry.new()
	_check(NAME, ungated.register_spawn(&"mech_any", Vector2i(0, 0)) != "", "未注入索引时不做类型门禁（接线方自行决定）。")


func _test_08_rejection_zero_pollution() -> void:
	const NAME := "08_零污染拒绝"
	var registry: Variant = _ObjectRegistry.new()
	registry.register_preplaced(&"mech_h", Vector2i(0, 0), null, "keep")
	_check(NAME, registry.register_preplaced(&"", Vector2i(1, 0)) == "", "空类型应拒绝。")
	_check(NAME, registry.register_preplaced(&"mech_h", Vector2i(1, 0), null, "keep") == "", "重复 ID 应拒绝。")
	_check(NAME, registry.register_preplaced(&"mech_h2", Vector2i(0, 0)) == "", "已占格应拒绝。")
	_check(NAME, registry.get_count() == 1, "全部拒绝后索引仍为 1。")
	_check(NAME, registry.get_stable_id_at(Vector2i(1, 0)) == "", "被拒格索引不得写入。")


func _test_09_snapshot_detached() -> void:
	const NAME := "09_快照只读"
	var registry: Variant = _ObjectRegistry.new()
	var marker := RefCounted.new()
	var id_a: String = registry.register_preplaced(&"mech_i", Vector2i(3, 3), marker, "s1")
	var snapshot: Dictionary = registry.get_object_snapshot(id_a)
	snapshot.cell = Vector2i(99, 99)
	snapshot.content_type_id = &"tampered"
	_check(NAME, registry.get_object_snapshot(id_a).cell == Vector2i(3, 3), "篡改快照不得影响真值。")
	_check(NAME, registry.get_object_snapshot(id_a).content_type_id == &"mech_i", "快照类型不得被篡改。")
	_check(NAME, registry.get_object_snapshot(id_a).instance == marker, "快照应携带实例引用。")
	var ids: Array = registry.get_stable_ids_of_type(&"mech_i")
	ids.append("fake")
	_check(NAME, registry.get_stable_ids_of_type(&"mech_i").size() == 1, "返回集合应为副本。")


func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


func _report() -> void:
	print("==== AF-01 FormalObjectRegistry 合同测试摘要 ====")
	print("测试组数：9")
	print("断言总数：%d" % _checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
	quit(1 if not _failures.is_empty() else 0)
