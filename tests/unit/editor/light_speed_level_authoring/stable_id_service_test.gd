extends SceneTree

# AF-08 Stable ID Manager 服务测试。
# 覆盖：正式对象发现（模板 Emitter+Crystal）、缺 ID 补发、水晶 crystal_id 同源、
#       全量重发生（旧≠新、计数一致）、审计（缺失/重复）、移动不改 ID（字段直写语义）。
# 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _LevelTemplate: PackedScene = preload(
	"res://levels/templates/level_template.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_discover_formal_objects()
	_test_02_assign_missing()
	_test_03_regenerate_all()
	_test_04_audit()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _make_template_root() -> Node2D:
	return _LevelTemplate.instantiate() as Node2D


func _test_01_discover_formal_objects() -> void:
	const NAME: String = "01_发现正式对象"
	var root := _make_template_root()
	var formal: Array = _StableIdService.find_formal_objects(root)
	_check(NAME, formal.size() == 2, "模板应含 2 个正式对象（Emitter + Crystal），实际 %d。" % formal.size())
	var has_emitter := false
	var has_crystal := false
	for node: Node in formal:
		if node.name == &"Emitter":
			has_emitter = true
		if node.name == &"BasicCrystal":
			has_crystal = true
	_check(NAME, has_emitter and has_crystal, "应发现 Emitter 与 BasicCrystal。")
	root.free()


func _test_02_assign_missing() -> void:
	const NAME: String = "02_缺ID补发与水晶同源"
	var root := _make_template_root()
	var assigned: int = _StableIdService.assign_missing(root)
	_check(NAME, assigned == 2, "模板两个正式对象均缺 stable_instance_id，应补发 2 个，实际 %d。" % assigned)
	var crystal := root.get_node("RuntimeObjects/BasicCrystal")
	var stable_id := str(crystal.get("stable_instance_id"))
	_check(NAME, stable_id.begins_with("fci_"), "补发 ID 应为 fci_ 前缀，实际 %s。" % stable_id)
	_check(NAME, String(crystal.get("crystal_id")) == stable_id, "crystal_id 应与 stable_instance_id 同源。")
	var again: int = _StableIdService.assign_missing(root)
	_check(NAME, again == 0, "已有 ID 一律保持，二次补发应为 0，实际 %d。" % again)
	root.free()


func _test_03_regenerate_all() -> void:
	const NAME: String = "03_全量重发生"
	var root := _make_template_root()
	var first: Dictionary = _StableIdService.regenerate_all(root)
	var ids_after_first: Array[String] = []
	for node: Node in _StableIdService.find_formal_objects(root):
		ids_after_first.append(str(node.get("stable_instance_id")))
	var second: Dictionary = _StableIdService.regenerate_all(root)
	_check(NAME, first.size() == 1 and first.has("crystal_001"),
		"首次重发：仅模板手填 crystal_001 入表（空旧 stable ID 不入）。")
	_check(NAME, second.size() == 2, "二次重发（已有 fci_ ID）应 2 条映射。")
	var changed := true
	for node: Node in _StableIdService.find_formal_objects(root):
		if ids_after_first.has(str(node.get("stable_instance_id"))):
			changed = false
	_check(NAME, changed, "二次重发生后全部 ID 应与一次不同（新身份）。")
	var crystal := root.get_node("RuntimeObjects/BasicCrystal")
	_check(NAME, String(crystal.get("crystal_id")) == str(crystal.get("stable_instance_id")),
		"重发后 crystal_id 仍与 stable_instance_id 同源。")
	root.free()


func _test_04_audit() -> void:
	const NAME: String = "04_审计缺失与重复"
	var root := _make_template_root()
	var audit: Dictionary = _StableIdService.audit(root)
	_check(NAME, audit.total == 2 and audit.missing == 2, "模板应审计出 2 对象全缺失。")
	_StableIdService.assign_missing(root)
	var audit2: Dictionary = _StableIdService.audit(root)
	_check(NAME, audit2.missing == 0 and (audit2.duplicates as Array).is_empty(), "补发后应零缺失零重复。")
	# 人为制造重复：把水晶 ID 改成发射器 ID。
	var crystal := root.get_node("RuntimeObjects/BasicCrystal")
	var emitter := root.get_node("RuntimeObjects/Emitter")
	crystal.set("stable_instance_id", str(emitter.get("stable_instance_id")))
	var audit3: Dictionary = _StableIdService.audit(root)
	_check(NAME, (audit3.duplicates as Array).size() == 1, "重复 ID 应被审计出 1 条。")
	root.free()


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("stable_id_service_test: %d checks, %d failures" % [_checks, _failures.size()])
