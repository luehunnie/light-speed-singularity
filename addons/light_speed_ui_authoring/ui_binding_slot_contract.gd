@tool
class_name LightSpeedUIAuthoringSlotContract
extends RefCounted

## UI Binding Slot 受保护宿主合同与独立结构 Validator（S3-04；冻结总结 v1.0 §82/§83）。
## 职责：冻结五类关键 Slot 合同（Inventory/Objective/MoveCounter/Hint/Fire-Reset Host），
##       在任意 Control 树上识别 Slot 节点（节点 meta 标记）并做结构校验：
##       缺失必要 Slot / 重复 / 未知 ID / 禁 Script Binding / 无 Container 且无锚点。
## 输入输出：validate_ui_structure(root, required_ids) 返回 issue 数组
##           （{check, node_path, detail}），空数组=通过；只读不修改节点。
## 副作用：无（纯只读遍历）。
## 边界：只校验节点/容器/锚点/最小约束；不耦合 LevelValidator/D6-A fixture（§82
##       "Validator 检查绑定结构"由本独立器承担）；Objective/MoveCounter/Hint 宿主属
##       S3-07，本合同先冻结 ID，宿主到位即受保护；既有宿主事实见 EXISTING_HOST_FACTS。

## Slot 节点上的合同标记键（Binding ID 载体；Stable 于 Node.name/坐标/显示名之外）。
const META_KEY: String = "ui_binding_slot_id"

const SLOT_INVENTORY: String = "inventory_host"
const SLOT_OBJECTIVE: String = "objective_host"
const SLOT_MOVE_COUNTER: String = "move_counter_host"
const SLOT_HINT: String = "hint_host"
const SLOT_FIRE_RESET: String = "fire_reset_host"

## 冻结五类 Slot（§82）。
const SLOT_IDS: Array = [
	SLOT_INVENTORY, SLOT_OBJECTIVE, SLOT_MOVE_COUNTER, SLOT_HINT, SLOT_FIRE_RESET,
]
const SLOT_LABELS: Dictionary = {
	SLOT_INVENTORY: "库存宿主",
	SLOT_OBJECTIVE: "目标宿主",
	SLOT_MOVE_COUNTER: "步数计数宿主",
	SLOT_HINT: "提示宿主",
	SLOT_FIRE_RESET: "开火/重置宿主",
}
## 当前 main 已存在的宿主事实（S3-04 复用不改行为；Objective/MoveCounter/Hint 待 S3-07）。
## run_start_view 拥有「开始运行」按钮即 Fire 入口宿主雏形；inventory_card_bar 为 Inventory 宿主雏形。
const EXISTING_HOST_FACTS: Array = [
	{ slot_id = SLOT_INVENTORY, script_path = "res://gameplay/ui/inventory_card_bar.gd" },
	{ slot_id = SLOT_FIRE_RESET, script_path = "res://gameplay/ui/run_start_view.gd" },
]
## 结构校验的默认必要集合：仅当前真实存在的宿主；S3-07 五键 UI 到位后扩展。
const REQUIRED_DEFAULT: Array = [SLOT_INVENTORY, SLOT_FIRE_RESET]


## 节点是否为 Slot（读 meta 标记，不猜 Node.name/NodePath）。
func is_slot_node(node: Node) -> bool:
	return node != null and node.has_meta(META_KEY) and node.get_meta(META_KEY, "") != ""


## 发现 UI 检查域根（Node2D 关卡场景载体兼容，S3-04 修复）：
## ① root 自身为 Control → 域根=[root]（Control 根保持兼容）；
## ② 否则按节点类型收集：CanvasLayer 直接 Control 子节点（关卡 UI 挂载约定），
##    兼收含正式 ui_binding_slot_id 标记的 Control 子树根（meta 锚定的 UI 分支）；
## ③ 世界空间 Control（如墙体 ColorRect，非 CanvasLayer/非 Slot 分支）不入域。
## 红线：禁 Node.name 匹配、固定 NodePath、场景路径、坐标猜测；无任何 Control 子树返回 []。
func find_ui_domain_roots(root: Node) -> Array:
	var domain: Array = []
	if root == null:
		return domain
	if root is Control:
		domain.append(root)
		return domain
	for node: Node in _walk(root):
		if not (node is Control) or node.get_parent() is Control:
			continue
		if node.get_parent() is CanvasLayer or _subtree_has_slot(node):
			domain.append(node)
	return domain


## Control 子树内（含自身）是否存在正式 Slot 标记。
func _subtree_has_slot(control: Control) -> bool:
	for node: Node in _walk(control):
		if is_slot_node(node):
			return true
	return false


## 遍历 Control 树收集 Slot：返回 {slot_id: Array[Control]}；未知 ID 也收录待校验报告。
func find_slots(root: Node) -> Dictionary:
	var slots: Dictionary = {}
	if root == null:
		return slots
	for node: Node in _walk(root):
		if is_slot_node(node):
			var slot_id: String = String(node.get_meta(META_KEY, ""))
			if not slots.has(slot_id):
				slots[slot_id] = []
			slots[slot_id].append(node)
	return slots


## 独立结构校验（§82：可移动排版，禁删必要/改义/破坏 Binding ID/写脚本绑定）。
## required_ids 可注入（默认 REQUIRED_DEFAULT）；返回 issue 数组，无任何修改副作用。
func validate_ui_structure(root: Node, required_ids: Array = REQUIRED_DEFAULT) -> Array:
	var issues: Array = []
	if root == null:
		return [{ check = "root_missing", node_path = "", detail = "UI 根节点缺失，无法校验。" }]
	if find_ui_domain_roots(root).is_empty():
		return [{ check = "root_missing", node_path = "", detail = "场景无任何 Control 子树（非 UI 载体），无法校验。" }]
	var slots: Dictionary = find_slots(root)
	for slot_id: String in slots.keys():
		if not (slot_id in SLOT_IDS):
			issues.append({ check = "unknown_slot", node_path = slot_id, detail = "未知 Binding ID：%s（合同外 Slot）。" % slot_id })
		var owners: Array = slots[slot_id]
		if owners.size() > 1:
			issues.append({ check = "duplicate_slot", node_path = slot_id, detail = "Slot %s 出现 %d 次，Binding ID 必须唯一。" % [slot_id, owners.size()] })
		for node: Node in owners:
			if not (node is Control):
				issues.append({ check = "slot_not_control", node_path = String(node.get_path()), detail = "Slot %s 宿主必须是 Control。" % slot_id })
				continue
			var control: Control = node
			if control.get_script() != null:
				issues.append({ check = "script_binding_forbidden", node_path = String(control.get_path()), detail = "Slot %s 禁止挂脚本绑定（业务接线走正式回调合同）。" % slot_id })
			elif not _has_container_ancestor_or_anchors(control):
				issues.append({ check = "no_layout_constraint", node_path = String(control.get_path()), detail = "Slot %s 无 Container 父级且未设非零锚点，父级缩放时不会跟随。" % slot_id })
	for slot_id: String in required_ids:
		if not slots.has(slot_id):
			issues.append({ check = "missing_required_slot", node_path = root.get_path(), detail = "缺少必要 Slot：%s（%s）。" % [slot_id, String(SLOT_LABELS.get(slot_id, slot_id))] })
	return issues


## 深度遍历（root 自身含入）。
func _walk(node: Node) -> Array:
	var all: Array = [node]
	for child: Node in node.get_children():
		all.append_array(_walk(child))
	return all


## 最小布局约束：任一父级为 Container，或自身锚点非全零（固定像素之外的任意锚定均算）。
func _has_container_ancestor_or_anchors(control: Control) -> bool:
	var parent: Node = control.get_parent()
	while parent != null:
		if parent is Container:
			return true
		parent = parent.get_parent()
	return not (control.anchor_left == 0.0 and control.anchor_top == 0.0
			and control.anchor_right == 0.0 and control.anchor_bottom == 0.0)
