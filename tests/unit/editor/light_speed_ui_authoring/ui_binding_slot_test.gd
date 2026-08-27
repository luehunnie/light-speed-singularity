extends SceneTree

## S3-04 Binding Slot 合同与独立结构 Validator 测试（GUI 冻结总结 v1.0 §82/§83）。
## 覆盖：五类 Slot 冻结、meta 标记识别、既有宿主事实（复用不改行为）、
##       合格/缺失/重复/未知/脚本绑定/无锚点校验、只读性、与 D6-A fixture 零耦合、
##       UI 检查域发现三路（Node2D→CanvasLayer→Control / Control 根 / 无 Control）。
## 由 Godot --headless --script 运行；任一失败 quit(1)。fixture 全内存构造。

const _Contract: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_binding_slot_contract.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _contract


func _initialize() -> void:
	_contract = _Contract.new()
	_test_frozen_contract()
	_test_find_slots_and_existing_hosts()
	_test_valid_structure()
	_test_violations()
	_test_readonly()
	_test_domain_discovery()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造带 meta 标记的 Slot 节点。
func _make_slot(slot_id: String) -> Control:
	var control: Control = Control.new()
	control.set_meta(_contract.META_KEY, slot_id)
	return control


## 合格 UI fixture：根 Container + 两个 Container 子级各挂一个受保护 Slot（祖先为 Container 即满足布局约束）。
func _make_valid_ui() -> Control:
	var ui_root: VBoxContainer = VBoxContainer.new()
	ui_root.size = Vector2(1920, 1080)
	var inv_host: HBoxContainer = HBoxContainer.new()
	inv_host.size = Vector2(600, 80)
	inv_host.set_meta(_contract.META_KEY, _contract.SLOT_INVENTORY)
	ui_root.add_child(inv_host)
	var fire_host: HBoxContainer = HBoxContainer.new()
	fire_host.position = Vector2(0, 100)
	fire_host.size = Vector2(300, 60)
	fire_host.set_meta(_contract.META_KEY, _contract.SLOT_FIRE_RESET)
	ui_root.add_child(fire_host)
	return ui_root


## G1 冻结合同：五类 Slot ID、中文标签、默认必要集合、meta 键。
func _test_frozen_contract() -> void:
	const NAME: String = "G1_冻结合同"
	_check(NAME, _contract.SLOT_IDS.size() == 5, "应冻结五类 Slot，实际 %d。" % _contract.SLOT_IDS.size())
	_check(NAME, _contract.SLOT_IDS == ["inventory_host", "objective_host", "move_counter_host", "hint_host", "fire_reset_host"], "五类 Slot ID 应与 §82 一致。")
	_check(NAME, _contract.SLOT_LABELS.size() == 5, "五类 Slot 均应有中文标签。")
	_check(NAME, _contract.REQUIRED_DEFAULT == ["inventory_host", "fire_reset_host"], "默认必要集合应仅为当前真实宿主（S3-07 后扩展）。")


## G2 识别与既有宿主事实：meta 标记找 Slot；EXISTING_HOST_FACTS 指向真实脚本文件。
func _test_find_slots_and_existing_hosts() -> void:
	const NAME: String = "G2_识别与宿主事实"
	var ui_root: Control = _make_valid_ui()
	root.add_child(ui_root)
	var slots: Dictionary = _contract.find_slots(ui_root)
	_check(NAME, slots.size() == 2, "应识别 2 个 Slot，实际 %d。" % slots.size())
	_check(NAME, slots.has(_contract.SLOT_INVENTORY) and slots.has(_contract.SLOT_FIRE_RESET), "应按 meta 识别两类宿主。")
	for fact: Dictionary in _contract.EXISTING_HOST_FACTS:
		_check(NAME, FileAccess.file_exists(String(fact["script_path"])), "既有宿主事实应指向真实脚本：%s。" % String(fact["script_path"]))
	ui_root.free()


## G3 合格结构：Container 内 Slot、必要齐全 → 0 issue。
func _test_valid_structure() -> void:
	const NAME: String = "G3_合格结构"
	var ui_root: Control = _make_valid_ui()
	root.add_child(ui_root)
	var issues: Array = _contract.validate_ui_structure(ui_root)
	_check(NAME, issues.is_empty(), "合格 UI 应 0 issue，实际：%s。" % str(issues))
	ui_root.free()


## G4 违规五类：缺失必要 / 重复 / 未知 ID / 脚本绑定 / 无 Container 且无锚点。
func _test_violations() -> void:
	const NAME: String = "G4_违规检出"
	# 缺失必要：只有 inventory。
	var only_inv: Control = Control.new()
	only_inv.add_child(_make_slot(_contract.SLOT_INVENTORY))
	root.add_child(only_inv)
	var missing: Array = _contract.validate_ui_structure(only_inv)
	_check(NAME, missing.any(func(i): return String(i["check"]) == "missing_required_slot"), "缺失必要 Slot 应检出。")
	only_inv.free()
	# 重复 + 未知：同 ID 两个 + 合同外 ID 一个。
	var dup_root: Control = Control.new()
	dup_root.add_child(_make_slot(_contract.SLOT_INVENTORY))
	dup_root.add_child(_make_slot(_contract.SLOT_INVENTORY))
	dup_root.add_child(_make_slot("custom_slot"))
	root.add_child(dup_root)
	var dup_issues: Array = _contract.validate_ui_structure(dup_root, [])
	var checks_found: Dictionary = {}
	for issue: Dictionary in dup_issues:
		checks_found[String(issue["check"])] = true
	_check(NAME, checks_found.has("duplicate_slot"), "重复 Slot 应检出。")
	_check(NAME, checks_found.has("unknown_slot"), "未知 Binding ID 应检出。")
	dup_root.free()
	# 脚本绑定：Slot 挂 Control 基脚本应检出（禁 Script Binding，§82）。
	# set_script 要求脚本基类为宿主类或其祖先，VBoxContainer 系真实脚本反而不兼容，用内存 Control 脚本。
	var control_script: GDScript = GDScript.new()
	control_script.source_code = "extends Control"
	control_script.reload()
	var scripted: Control = Control.new()
	var slot_with_script: Control = _make_slot(_contract.SLOT_INVENTORY)
	slot_with_script.set_script(control_script)
	scripted.add_child(slot_with_script)
	root.add_child(scripted)
	_check(NAME, _contract.validate_ui_structure(scripted, []).any(func(i): return String(i["check"]) == "script_binding_forbidden"), "Slot 挂脚本应检出。")
	scripted.free()
	# 无布局约束：裸 Slot 无 Container 祖级且零锚点。
	var anchored_root: Node = Node.new()
	var bare: Control = _make_slot(_contract.SLOT_INVENTORY)
	anchored_root.add_child(bare)
	root.add_child(anchored_root)
	_check(NAME, _contract.validate_ui_structure(anchored_root, []).any(func(i): return String(i["check"]) == "no_layout_constraint"), "无 Container 且无锚点应检出。")
	anchored_root.free()


## G5 只读性：校验后节点 meta/子节点数不变（Validator 不修改任何节点）。
func _test_readonly() -> void:
	const NAME: String = "G5_只读"
	var ui_root: Control = _make_valid_ui()
	ui_root.add_child(_make_slot("custom_slot"))
	root.add_child(ui_root)
	var before_children: int = ui_root.get_child_count()
	var before_meta: String = String(ui_root.get_child(0).get_meta(_contract.META_KEY, ""))
	_contract.validate_ui_structure(ui_root, [])
	_check(NAME, ui_root.get_child_count() == before_children, "校验不得增删节点。")
	_check(NAME, String(ui_root.get_child(0).get_meta(_contract.META_KEY, "")) == before_meta, "校验不得改 Binding ID。")
	ui_root.free()


## G6 UI 检查域发现（Node2D 载体兼容）：CanvasLayer 直接 Control 子树入域；
## 世界空间 Control 不入域；Node2D 关卡根可跑结构校验；Control 根域=自身；无 Control → root_missing。
func _test_domain_discovery() -> void:
	const NAME: String = "G6_载体域发现"
	var level: Node2D = Node2D.new()
	var canvas: CanvasLayer = CanvasLayer.new()
	level.add_child(canvas)
	var inv_host: HBoxContainer = HBoxContainer.new()
	inv_host.set_meta(_contract.META_KEY, _contract.SLOT_INVENTORY)
	inv_host.anchor_left = 0.5
	canvas.add_child(inv_host)
	var fire_host: HBoxContainer = HBoxContainer.new()
	fire_host.set_meta(_contract.META_KEY, _contract.SLOT_FIRE_RESET)
	fire_host.anchor_left = 0.5
	canvas.add_child(fire_host)
	var world_rect: ColorRect = ColorRect.new()
	level.add_child(world_rect)
	root.add_child(level)
	var domain: Array = _contract.find_ui_domain_roots(level)
	_check(NAME, domain.size() == 2, "CanvasLayer 两直接 Control 子树应入域，实际 %d。" % domain.size())
	_check(NAME, not domain.has(world_rect), "世界空间 Control（无 CanvasLayer/无 Slot）不应入域。")
	_check(NAME, _contract.validate_ui_structure(level).is_empty(), "Node2D+CanvasLayer 合格结构应 0 issue（禁 Node.name/NodePath/坐标猜测）。")
	level.free()
	# Control 根保持兼容：域根即自身。
	var ui_root: Control = _make_valid_ui()
	root.add_child(ui_root)
	_check(NAME, _contract.find_ui_domain_roots(ui_root) == [ui_root], "Control 根的检查域应为自身。")
	ui_root.free()
	# 无任何 Control 子树 → 空域 + root_missing。
	var empty_level: Node = Node.new()
	empty_level.add_child(Node.new())
	root.add_child(empty_level)
	_check(NAME, _contract.find_ui_domain_roots(empty_level).is_empty(), "无 Control 子树应返回空域。")
	_check(NAME, _contract.validate_ui_structure(empty_level, []).any(func(i): return String(i["check"]) == "root_missing"), "无任何 Control 子树才应 root_missing。")
	empty_level.free()


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Binding Slot 合同与 Validator 测试摘要 ====")
	print("测试组数：6")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
