extends SceneTree

## RuntimeValidationGate 集成测试（D7-1 Runtime Validation Gate）。
##
## 目的：证明运行期校验门在 runtime → RuntimeValidationGate → LevelValidator → LevelValidationResult
##   链路上的边界契约，不重测 D6 Validator 全量规则。
##
## 覆盖九组：
##   01 valid 允许（编辑示例原样 → is_valid=true / error_count=0 / 返回 LevelValidationResult）。
##   02 ERROR 拒绝（空白模板 → has_errors=true / is_valid=false）。
##   03 WARNING 遵循既有 is_valid 语义（编辑示例清空 Legal → legal_area_empty WARNING / 0 ERROR / is_valid=true）。
##   04 校验前后只读（空白+编辑示例场景结构快照前后全等）。
##   05 连续两次结果稳定（同一 root 两次签名一致）。
##   06 成功/失败均不改 RunState（SETUP 与 PULSE_ACTIVE 两态：状态不变 + state_changed 信号 0 次）。
##   07 不触发 Ray（LightVisualController 观测段数前后均 0 + Gate 源码无光/Ray/发射器/视觉依赖）。
##   08 不改库存/占用/水晶（Inventory/Occupancy 观测不变 + 场景内水晶事实不变）。
##   09 不依赖 addons（Gate preload 路径无 res://addons + 正向证明只依赖 gameplay/level/validation）。
##   10 合法 PARTICLE 不阻断（编辑示例 Emitter 翻为 PARTICLE → is_valid=true / 0 ERROR / 无 emitter_runtime_form_unsupported；
##      证明 B3b-1 起 Gate 经纯委托链对 PARTICLE 与 RAY 一致放行）。
##
## 约束：不修改/不保存任何场景/资源/既有测试；实例不入树；各场景与观测器受控释放。
##   运行方式：直调控制台 exe --headless --script（不经 MCP run_project，避开 .tres 自动归一化）。
##   preload 引用模块避开全局 class_name 缓存坑。全部失败项收集后统一 quit(0/1)。

const _Gate: GDScript = preload("res://gameplay/runtime/runtime_validation_gate.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")
const _LevelValidationIssue: GDScript = preload("res://gameplay/level/validation/level_validation_issue.gd")
const _RunStateController: GDScript = preload("res://gameplay/interaction/run_state_controller.gd")
const _RuntimeInteractionTypes: GDScript = preload("res://gameplay/interaction/runtime_interaction_types.gd")
const _InventoryController: GDScript = preload("res://gameplay/placement/inventory_controller.gd")
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LightVisualController: GDScript = preload("res://gameplay/visuals/light_visual_controller.gd")
const _BasicCrystal: GDScript = preload("res://gameplay/crystals/basic_crystal.gd")
const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")

const _BLANK_TEMPLATE_PATH: String = "res://levels/templates/level_template.tscn"
const _EDITING_EXAMPLE_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
const _GATE_SCRIPT_PATH: String = "res://gameplay/runtime/runtime_validation_gate.gd"
const _GROUP_COUNT: int = 10

# Gate preload 路径中禁止出现的“光/Ray/发射器/视觉”命名空间（仅扫 preload 语句，不扫注释）。
const _RAY_NS: Array = [
	"res://gameplay/light",
	"res://gameplay/world/light",
	"res://gameplay/visuals",
	"res://gameplay/mechanisms/emitters",
]

# 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
# 已执行断言总数。
var _checks: int = 0
# 持有观测器父节点统一释放（LightVisualController 的 parent，不入树）。
var _observer_parents: Array[Node] = []


## SceneTree 初始化入口：顺序运行九组后统一报告、释放并退出。本测试无异步操作，不需 await。
func _initialize() -> void:
	_test_01_valid_allows()
	_test_02_error_rejects()
	_test_03_warning_keeps_valid()
	_test_04_readonly_proof()
	_test_05_stable_two_calls()
	_test_06_no_runstate_change()
	_test_07_no_ray_triggered()
	_test_08_no_inventory_occupancy_crystal_change()
	_test_09_no_addons_dependency()
	_test_10_legal_particle_not_blocked()
	_report()
	_cleanup_observers()
	quit(0 if _failures.is_empty() else 1)


# ===== 01 valid 允许 =====

## 编辑示例原样经 Gate 校验：返回 LevelValidationResult、0 ERROR、is_valid=true。
func _test_01_valid_allows() -> void:
	const G: String = "01_valid允许"
	var root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	if root == null:
		return
	var gate: _Gate = _Gate.new()
	var result: _LevelValidationResult = gate.validate_for_run_start(root)
	_check(G, is_instance_of(result, _LevelValidationResult), "应返回 LevelValidationResult 实例。")
	_check(G, result.get_error_count() == 0, "编辑示例期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, result.is_valid() == true, "编辑示例期望 is_valid=true。")
	root.free()


# ===== 02 ERROR 拒绝 =====

## 空白模板经 Gate 校验：has_errors=true、is_valid=false（空 Terrain 是真实内容错误）。
func _test_02_error_rejects() -> void:
	const G: String = "02_ERROR拒绝"
	var root: Node2D = _instantiate(_BLANK_TEMPLATE_PATH, G)
	if root == null:
		return
	var result: _LevelValidationResult = _Gate.new().validate_for_run_start(root)
	_check(G, result.has_errors() == true, "空白模板期望 has_errors=true。")
	_check(G, result.is_valid() == false, "空白模板期望 is_valid=false。")
	_check(G, result.get_error_count() >= 1, "空白模板期望至少 1 个 ERROR。")
	root.free()


# ===== 03 WARNING 遵循既有 is_valid 语义 =====

## 编辑示例内存清空 LegalAreaLayer（不写回资源）→ 仅 legal_area_empty WARNING、0 ERROR；is_valid 仍 true。
## 证明 WARNING 数量不影响 valid 判定（沿用 LevelValidationResult.is_valid 既有语义）。
func _test_03_warning_keeps_valid() -> void:
	const G: String = "03_WARNING遵循is_valid"
	var root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	if root == null:
		return
	var legal: Node = root.get_node_or_null(NodePath("LegalAreaLayer"))
	if legal != null and legal is TileMapLayer:
		(legal as TileMapLayer).clear()
	var result: _LevelValidationResult = _Gate.new().validate_for_run_start(root)
	_check(G, _has_code_at(result, "legal_area_empty", _LevelValidationIssue.Severity.WARNING),
		"清空 Legal 后期望 legal_area_empty WARNING。")
	_check(G, result.get_error_count() == 0, "清空 Legal 后期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, result.get_warning_count() >= 1, "清空 Legal 后期望 WARNING >=1。")
	_check(G, result.is_valid() == true, "仅 WARNING 无 ERROR 时 is_valid 应为 true（沿用既有语义）。")
	root.free()


# ===== 04 校验前后只读 =====

## 空白模板与编辑示例：snapshot_before → Gate 校验两次 → snapshot_after，场景结构全等。
func _test_04_readonly_proof() -> void:
	const G: String = "04_校验前后只读"
	for path: String in [_BLANK_TEMPLATE_PATH, _EDITING_EXAMPLE_PATH]:
		var root: Node2D = _instantiate(path, G)
		if root == null:
			continue
		var before: Dictionary = _capture_scene(root)
		var gate: _Gate = _Gate.new()
		var _r1: _LevelValidationResult = gate.validate_for_run_start(root)
		var _r2: _LevelValidationResult = gate.validate_for_run_start(root)
		var after: Dictionary = _capture_scene(root)
		_check(G, str(before) == str(after), "Gate 校验前后场景结构应全等：%s。" % path)
		root.free()


# ===== 05 连续两次结果稳定 =====

## 同一 root 经同一 Gate 连续两次校验，issue 全排序键签名逐项一致。
func _test_05_stable_two_calls() -> void:
	const G: String = "05_连续两次稳定"
	for path: String in [_BLANK_TEMPLATE_PATH, _EDITING_EXAMPLE_PATH]:
		var root: Node2D = _instantiate(path, G)
		if root == null:
			continue
		var gate: _Gate = _Gate.new()
		var r1: _LevelValidationResult = gate.validate_for_run_start(root)
		var r2: _LevelValidationResult = gate.validate_for_run_start(root)
		_check(G, _signature(r1) == _signature(r2), "两次调用结果签名应一致：%s。" % path)
		root.free()


# ===== 06 成功/失败均不改 RunState =====

## Gate 不引用 RunStateController：SETUP 态经成功(valid)+失败(invalid)两次调用后状态与信号均不变；
## PULSE_ACTIVE 态经失败调用后同样不被复位。证明 Gate 永不切换四态、不发 state_changed。
func _test_06_no_runstate_change() -> void:
	const G: String = "06_不改RunState"
	var valid_root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	var invalid_root: Node2D = _instantiate(_BLANK_TEMPLATE_PATH, G)
	var gate: _Gate = _Gate.new()
	# SETUP 态：成功与失败两次调用后状态与信号不变。
	var rsc: _RunStateController = _RunStateController.new()
	var sink: _SignalSink = _SignalSink.new()
	rsc.state_changed.connect(Callable(sink, "on_changed"))
	_check(G, rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "前置应 SETUP。")
	if valid_root != null:
		gate.validate_for_run_start(valid_root)
	if invalid_root != null:
		gate.validate_for_run_start(invalid_root)
	_check(G, rsc.get_current_state() == _RuntimeInteractionTypes.RunState.SETUP, "Gate 调用后应仍 SETUP。")
	_check(G, sink.count == 0, "Gate 调用不应触发 state_changed，实际 %d 次。" % sink.count)
	# PULSE_ACTIVE 态：失败调用后不被复位（证明不会把非 SETUP 态悄悄改回）。
	var rsc2: _RunStateController = _RunStateController.new()
	rsc2.begin_runtime()  # D7-2 适配：SETUP→PULSE_ACTIVE 已禁止，经 READY_TO_FIRE 进入（仅改既有用例前置，未追加测试组）。
	rsc2.begin_pulse()
	_check(G, rsc2.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE, "前置应 PULSE_ACTIVE。")
	if invalid_root != null:
		gate.validate_for_run_start(invalid_root)
	_check(G, rsc2.get_current_state() == _RuntimeInteractionTypes.RunState.PULSE_ACTIVE,
		"PULSE_ACTIVE 经 Gate 后应不变。")
	if valid_root != null:
		valid_root.free()
	if invalid_root != null:
		invalid_root.free()


# ===== 07 不触发 Ray =====

## 行为证明：LightVisualController 观测段数在 Gate 调用前后均为 0（Gate 未触发任何光路）。
## 源码证明：Gate preload 路径不含光/Ray/发射器/视觉命名空间。
func _test_07_no_ray_triggered() -> void:
	const G: String = "07_不触发Ray"
	var parent: Node2D = Node2D.new()
	_observer_parents.append(parent)
	var lvc: _LightVisualController = _LightVisualController.new(parent)
	_check(G, lvc.get_segment_count() == 0, "前置光路段数应为 0。")
	var root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	if root != null:
		_Gate.new().validate_for_run_start(root)
		_check(G, lvc.get_segment_count() == 0, "Gate 调用后光路段数应仍为 0（未触发 Ray）。")
		root.free()
	var paths: Array[String] = _gate_preloads()
	_check(G, not _any_path_under(paths, _RAY_NS),
		"Gate 不应 preload 任何光/Ray/发射器/视觉模块，实际 %s。" % str(paths))


# ===== 08 不改库存/占用/水晶 =====

## Gate 不引用 Inventory/Occupancy：观测 remaining 与占用条目数前后不变；
## 场景内 BasicCrystal 事实（crystal_id/position/子节点数）前后不变。
func _test_08_no_inventory_occupancy_crystal_change() -> void:
	const G: String = "08_不改库存占用水晶"
	var inv: _InventoryController = _InventoryController.new(3)
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv_before: int = inv.get_remaining()
	var occ_before: int = occ.mechanism_at.size()
	var occ_consistent: bool = occ.is_consistent()
	var root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	var crystal_before: Dictionary = _capture_crystal(root) if root != null else {}
	if root != null:
		_Gate.new().validate_for_run_start(root)
	_check(G, inv.get_remaining() == inv_before, "库存 remaining 应不变，实际 %d。" % inv.get_remaining())
	_check(G, occ.mechanism_at.size() == occ_before, "占用表条目数应不变。")
	_check(G, occ.is_consistent() == occ_consistent, "占用表一致性应不变。")
	if root != null:
		var crystal_after: Dictionary = _capture_crystal(root)
		_check(G, str(crystal_before) == str(crystal_after), "场景内水晶事实应不变。")
		root.free()


# ===== 09 不依赖 addons =====

## 源码证明：Gate preload 路径无 res://addons；正向证明所有 preload 落在 gameplay/level/validation/，
## 且包含 level_validator.gd（即唯一运行期依赖为既有只读 Validator 包，不依赖编辑器插件）。
func _test_09_no_addons_dependency() -> void:
	const G: String = "09_不依赖addons"
	var paths: Array[String] = _gate_preloads()
	_check(G, not _any_path_under(paths, ["res://addons"]),
		"Gate 不应 preload 任何 addons 模块，实际 %s。" % str(paths))
	var all_validation: bool = true
	for p: String in paths:
		if not p.begins_with("res://gameplay/level/validation/"):
			all_validation = false
	_check(G, all_validation, "Gate 所有 preload 应落在 gameplay/level/validation/，实际 %s。" % str(paths))
	var has_validator: bool = false
	for p: String in paths:
		if p.ends_with("level_validator.gd"):
			has_validator = true
	_check(G, has_validator, "Gate 应 preload level_validator.gd（复用既有 Validator）。")


# ===== 10 合法 PARTICLE 不阻断 =====

## 编辑示例（RAY 合法）原样加载后，把唯一 Emitter 的 default_light_form 内存翻为 PARTICLE（不写回资源），
## 经 Gate 校验：is_valid=true、0 ERROR、无 emitter_runtime_form_unsupported。
## 证明 B3b-1 起 PARTICLE 已接 Runtime，Gate 经纯委托链对 PARTICLE 与 RAY 一致放行（不阻断正式开始）。
func _test_10_legal_particle_not_blocked() -> void:
	const G: String = "10_合法PARTICLE不阻断"
	var root: Node2D = _instantiate(_EDITING_EXAMPLE_PATH, G)
	if root == null:
		return
	var emitter_node: Node = root.get_node_or_null(NodePath("RuntimeObjects/Emitter"))
	if emitter_node == null or not is_instance_of(emitter_node, _EmitterConfigNode):
		_check(G, false, "编辑示例应有 RuntimeObjects/Emitter（EmitterConfigNode）。")
		root.free()
		return
	var emitter: _EmitterConfigNode = emitter_node
	emitter.default_light_form = _EmitterConfigNode.LightForm.PARTICLE
	var result: _LevelValidationResult = _Gate.new().validate_for_run_start(root)
	_check(G, is_instance_of(result, _LevelValidationResult), "应返回 LevelValidationResult 实例。")
	_check(G, result.is_valid() == true, "合法 PARTICLE 经 Gate 期望 is_valid=true。")
	_check(G, result.get_error_count() == 0, "合法 PARTICLE 经 Gate 期望 0 ERROR，实际 %d。" % result.get_error_count())
	_check(G, not _has_code_at(result, "emitter_runtime_form_unsupported", _LevelValidationIssue.Severity.ERROR),
		"合法 PARTICLE 经 Gate 不应报 emitter_runtime_form_unsupported。")
	root.free()


# ===== 场景加载 =====

## 真实 load + instantiate，实例不加入 SceneTree；加载失败累计失败并返回 null。
func _instantiate(path: String, group: String) -> Node2D:
	var packed: PackedScene = load(path)
	if packed == null:
		_check(group, false, "无法 load 场景：%s。" % path)
		return null
	var node: Node = packed.instantiate()
	if node == null or not (node is Node2D):
		_check(group, false, "场景根非 Node2D：%s。" % path)
		return null
	return node


# ===== 快照采集（只读） =====

## 采集场景结构事实：根直属子节点(名:类型)、四层 used cells(数量+排序格串)、RuntimeObjects 子节点。
func _capture_scene(root: Node2D) -> Dictionary:
	var d: Dictionary = {}
	d["children"] = _sorted_children(root)
	for layer_name: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		d[layer_name] = _layer_cells_string(root, layer_name)
	var runtime: Node = root.get_node_or_null(NodePath("RuntimeObjects"))
	d["runtime_children"] = _sorted_children(runtime) if runtime != null else "none"
	return d


## 采集场景内首个 BasicCrystal 事实：存在/crystal_id/position/子节点数。
func _capture_crystal(root: Node2D) -> Dictionary:
	var c: Node = _find_first(root, _BasicCrystal)
	if c == null:
		return {"exists": false}
	var bc: _BasicCrystal = c as _BasicCrystal
	return {
		"exists": true,
		"crystal_id": String(bc.crystal_id),
		"position": "%.4f,%.4f" % [bc.position.x, bc.position.y],
		"child_count": bc.get_child_count(),
	}


# ===== 事实读取辅助 =====

## 节点直属子节点排序后的“名:类型”逗号串。
func _sorted_children(node: Node) -> String:
	if node == null:
		return ""
	var arr: Array = []
	for c: Node in node.get_children():
		arr.append("%s:%s" % [String(c.name), _type_name(c)])
	arr.sort()
	return ",".join(arr)


## 单层 used cells 的“数量|排序格串”；缺层返回 "absent"。
func _layer_cells_string(root: Node2D, layer_name: String) -> String:
	var node: Node = root.get_node_or_null(NodePath(layer_name))
	if node == null or not (node is TileMapLayer):
		return "absent"
	var arr: Array = []
	for c: Vector2i in (node as TileMapLayer).get_used_cells():
		arr.append("%d,%d" % [c.x, c.y])
	arr.sort()
	return "%d|%s" % [arr.size(), ",".join(arr)]


## DFS 收集子树中某脚本类型的首个实例（不含根）。
func _find_first(root: Node, script_type: GDScript) -> Node:
	return _gather_first(root, script_type)


func _gather_first(node: Node, script_type: GDScript) -> Node:
	for c: Node in node.get_children():
		if is_instance_of(c, script_type):
			return c
		var deeper: Node = _gather_first(c, script_type)
		if deeper != null:
			return deeper
	return null


## 节点类型名：有脚本取脚本文件名，否则取原生 get_class()。
func _type_name(n: Node) -> String:
	var s: Script = n.get_script()
	if s != null:
		return s.resource_path.get_file()
	return n.get_class()


## 结果中是否存在指定 code 且 severity 匹配的 issue。
func _has_code_at(result: _LevelValidationResult, code: String, severity: int) -> bool:
	for issue: _LevelValidationIssue in result.get_issues():
		if str(issue.get_code()) == code and issue.get_severity() == severity:
			return true
	return false


## issue 全排序键签名（severity/code/node_path/has_cell/cell/object_id），用于逐项比较两次结果。
func _signature(result: _LevelValidationResult) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for issue: _LevelValidationIssue in result.get_issues():
		parts.append("%d|%s|%s|%d|%d,%d|%s" % [issue.get_severity(), str(issue.get_code()),
			str(issue.get_node_path()), int(issue.has_cell()), issue.get_cell().x,
			issue.get_cell().y, str(issue.get_object_id())])
	return "\n".join(parts)


# ===== Gate 源码依赖面分析 =====

## 从 Gate 源码提取所有 preload("...") 路径；只匹配 preload 语句，不受注释文字影响。
func _gate_preloads() -> Array[String]:
	var script: GDScript = load(_GATE_SCRIPT_PATH) as GDScript
	var paths: Array[String] = []
	if script == null:
		return paths
	var re: RegEx = RegEx.new()
	re.compile('preload\\s*\\(\\s*"([^"]+)"\\s*\\)')
	for m: RegExMatch in re.search_all(script.source_code):
		paths.append(m.get_string(1))
	return paths


## paths 中是否存在任一路径以 prefixes 中任一项为前缀。
func _any_path_under(paths: Array, prefixes: Array) -> bool:
	for p: String in paths:
		for pre: String in prefixes:
			if p.begins_with(pre):
				return true
	return false


# ===== 断言 / 报告 / 清理 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 释放观测器父节点（跳过已释放实例）。
func _cleanup_observers() -> void:
	for n: Node in _observer_parents:
		if is_instance_valid(n):
			n.free()
	_observer_parents.clear()


## 输出测试摘要。
func _report() -> void:
	var passed: int = _checks - _failures.size()
	print("==== RuntimeValidationGate 集成测试摘要（D7-1）====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for f: String in _failures:
			print(f)


# ===== 信号计数桩 =====

## RunStateController.state_changed 计数桩（RefCounted，由 Callable 与本地变量共同持有，避免单引用回收）。
class _SignalSink:
	var count: int = 0
	## state_changed(previous_state, new_state) 回调：仅累加计数，不读取参数。
	func on_changed(_previous, _new) -> void:
		count += 1
