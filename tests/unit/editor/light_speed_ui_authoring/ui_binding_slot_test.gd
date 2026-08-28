extends SceneTree

## S3-04 Binding Slot 合同与独立结构 Validator 测试（GUI 冻结总结 v1.0 §82/§83；S3-07 五宿主同步）。
## 覆盖：五类 Slot 冻结、meta 标记识别、五宿主事实（S3-07 全量落地）、
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


## 合格 UI fixture：根 Container + 五类 Container 子级各挂一个受保护 Slot（祖先为 Container 即满足布局约束）。
func _make_valid_ui() -> Control:
	var ui_root: VBoxContainer = VBoxContainer.new()
	ui_root.size = Vector2(1920, 1080)
	for slot_id: String in _contract.SLOT_IDS:
		var host: HBoxContainer = HBoxContainer.new()
		host.size = Vector2(300, 60)
		host.set_meta(_contract.META_KEY, slot_id)
		ui_root.add_child(host)
	return ui_root


## G1 冻结合同：五类 Slot ID、中文标签、默认必要集合（S3-07 五宿主全量）、meta 键。
func _test_frozen_contract() -> void:
	const NAME: String = "G1_冻结合同"
	_check(NAME, _contract.SLOT_IDS.size() == 5, "应冻结五类 Slot，实际 %d。" % _contract.SLOT_IDS.size())
	_check(NAME, _contract.SLOT_IDS == ["inventory_host", "objective_host", "move_counter_host", "hint_host", "fire_reset_host"], "五类 Slot ID 应与 §82 一致。")
	_check(NAME, _contract.SLOT_LABELS.size() == 5, "五类 Slot 均应有中文标签。")
	_check(NAME, _contract.REQUIRED_DEFAULT == _contract.SLOT_IDS, "默认必要集合应为五宿主全量（S3-07 落地）。")


## G2 识别与五宿主事实：meta 标记找 Slot；EXISTING_HOST_FACTS 覆盖五类且指向真实脚本文件。
func _test_find_slots_and_existing_hosts() -> void:
	const NAME: String = "G2_识别与宿主事实"
	var ui_root: Control = _make_valid_ui()
	root.add_child(ui_root)
	var slots: Dictionary = _contract.find_slots(ui_root)
	_check(NAME, slots.size() == 5, "应识别 5 个 Slot，实际 %d。" % slots.size())
	for slot_id: String in _contract.SLOT_IDS:
		_check(NAME, slots.has(slot_id), "应按 meta 识别宿主 %s。" % slot_id)
	var fact_ids: Array = []
	for fact: Dictionary in _contract.EXISTING_HOST_FACTS:
		fact_ids.append(String(fact["slot_id"]))
		_check(NAME, FileAccess.file_exists(String(fact["script_path"])), "宿主事实应指向真实脚本：%s。" % String(fact["script_path"]))
	for slot_id: String in _contract.SLOT_IDS:
		_check(NAME, fact_ids.has(slot_id), "五类宿主事实应覆盖 %s，实际：%s。" % [slot_id, str(fact_ids)])
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
	# 缺失必要：只有 inventory（默认必要五宿主缺四应全部检出）。
	var only_inv: Control = Control.new()
	only_inv.add_child(_make_slot(_contract.SLOT_INVENTORY))
	root.add_child(only_inv)
	var missing: Array = _contract.validate_ui_structure(only_inv)
	_check(NAME, missing.any(func(i): return String(i["check"]) == "missing_required_slot"), "缺失必要 Slot 应检出。")
	var missing_count: int = 0
	for issue: Dictionary in missing:
		if String(issue["check"]) == "missing_required_slot":
			missing_count += 1
	_check(NAME, missing_count == 4, "默认五必要缺四应逐项检出，实际 %d。" % missing_count)
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
	for slot_id: String in _contract.SLOT_IDS:
		var host: HBoxContainer = HBoxContainer.new()
		host.set_meta(_contract.META_KEY, slot_id)
		host.anchor_left = 0.5
		canvas.add_child(host)
	var world_rect: ColorRect = ColorRect.new()
	level.add_child(world_rect)
	root.add_child(level)
	var domain: Array = _contract.find_ui_domain_roots(level)
	_check(NAME, domain.size() == 5, "CanvasLayer 五直接 Control 子树应入域，实际 %d。" % domain.size())
	_check(NAME, not domain.has(world_rect), "世界空间 Control（无 CanvasLayer/无 Slot）不应入域。")
	_check(NAME, _contract.validate_ui_structure(level).is_empty(), "Node2D+CanvasLayer 五宿主合格结构应 0 issue（禁 Node.name/NodePath/坐标猜测）。")
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
