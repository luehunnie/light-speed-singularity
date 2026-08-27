extends SceneTree

## VisualTargetResolver PlaceableToken 组件边界测试（AF-Artwork P0-2）。
## 覆盖：PlaceableToken 根解析、Token 内深层视觉收集、直接选 VisualView 定位 Token 组件根、
##   GridPlacedObject 内嵌套 Token 的隔离、多视觉 MULTIPLE_TARGETS、无边界 UNSUPPORTED（兼容不变）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _ResolverScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_resolver.gd"
)
const _ResultScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/target/visual_target_result.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _ViewScene: PackedScene = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.tscn"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _resolver: RefCounted = _ResolverScript.new()


func _initialize() -> void:
	_test_01_token_root_single_target()
	_test_02_token_inner_node_resolves()
	_test_03_direct_visual_component_is_token()
	_test_04_nested_token_under_grid_ignored()
	_test_05_token_multiple_visuals()
	_test_06_plain_node_unsupported()
	_test_07_grid_root_still_supported()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. 选择 PlaceableToken 根：SINGLE_TARGET，主目标为 Token 内 VisualView。
func _test_01_token_root_single_target() -> void:
	const NAME: String = "01_Token根单目标"
	var token: PlaceableToken = _make_token("Token")
	root.add_child(token)
	var result: RefCounted = _resolver.resolve(token)
	_check(NAME, result.get_status() == _ResultScript.Status.SINGLE_TARGET, "Token 根应解析为单目标。")
	_check(NAME, result.get_component_root() == token, "组件根应为 Token 自身。")
	var view: Node = result.get_primary_target()
	_check(NAME, view != null and view.name == "VisualView", "主目标应为 Token 的 VisualView。")
	_free_tree(token)


## 2. 选择 Token 内部普通子节点（非视觉）：向上定位 Token 边界并收集全部视觉（含深层）。
func _test_02_token_inner_node_resolves() -> void:
	const NAME: String = "02_Token内部节点"
	var token: PlaceableToken = _make_token("Token")
	root.add_child(token)
	var inner: Node2D = Node2D.new()
	inner.name = "InnerHolder"
	var deep_view: Node = _make_view("DeepView")
	inner.add_child(deep_view)
	token.add_child(inner)
	var result: RefCounted = _resolver.resolve(inner)
	_check(NAME, result.get_status() == _ResultScript.Status.MULTIPLE_TARGETS, "内部节点应定位 Token 组件并收集全部视觉。")
	_check(NAME, result.get_component_root() == token, "组件根应为 Token。")
	var targets: Array = result.get_targets()
	_check(NAME, targets.has(deep_view), "应收集到深层 VisualView。")
	_check(NAME, targets.has(token.get_node("VisualView")), "应同时收集 Token 直接视觉。")
	_free_tree(token)


## 3. 直接选择 Token 的 VisualView：SINGLE_TARGET 且组件根定位到 Token。
func _test_03_direct_visual_component_is_token() -> void:
	const NAME: String = "03_直接选Token视觉"
	var token: PlaceableToken = _make_token("Token")
	root.add_child(token)
	var view: Node = token.get_node("VisualView")
	var result: RefCounted = _resolver.resolve(view)
	_check(NAME, result.get_status() == _ResultScript.Status.SINGLE_TARGET, "直接选视觉应为单目标。")
	_check(NAME, result.get_primary_target() == view, "主目标应为所选拦截视觉自身。")
	_check(NAME, result.get_component_root() == token, "组件根应向上定位到 Token。")
	_free_tree(token)


## 4. GridPlacedObject 内嵌套 Token：Token 记入 ignored 且子树不进入。
func _test_04_nested_token_under_grid_ignored() -> void:
	const NAME: String = "04_嵌套Token隔离"
	var grid: Node = _GridPlacedObject.new()
	grid.name = "GridRoot"
	var grid_view: Node = _make_view("GridView")
	grid.add_child(grid_view)
	var token: PlaceableToken = _make_token("NestedToken")
	grid.add_child(token)
	root.add_child(grid)
	var result: RefCounted = _resolver.resolve(grid)
	_check(NAME, result.get_status() == _ResultScript.Status.SINGLE_TARGET, "Grid 根应保持单目标语义。")
	_check(NAME, result.get_primary_target() == grid_view, "主目标应为 Grid 自身视觉，不吞并嵌套 Token 视觉。")
	_check(NAME, result.get_ignored_nodes().has(token), "嵌套 Token 应记入 ignored_nodes。")
	_free_tree(grid)


## 5. Token 含多个 VisualView：MULTIPLE_TARGETS，不静默选第一个。
func _test_05_token_multiple_visuals() -> void:
	const NAME: String = "05_Token多视觉"
	var token: PlaceableToken = _make_token("Token")
	root.add_child(token)
	var extra: Node = _make_view("ExtraView")
	token.add_child(extra)
	var result: RefCounted = _resolver.resolve(token)
	_check(NAME, result.get_status() == _ResultScript.Status.MULTIPLE_TARGETS, "多视觉应为 MULTIPLE_TARGETS。")
	_check(NAME, result.get_targets().size() == 2, "应收集两个视觉目标。")
	_check(NAME, result.get_primary_target() == null, "多目标时 primary 应为 null。")
	_free_tree(token)


## 6. 无组件边界的普通节点：UNSUPPORTED（兼容不变）。
func _test_06_plain_node_unsupported() -> void:
	const NAME: String = "06_普通节点不支持"
	var plain: Node2D = Node2D.new()
	plain.name = "Plain"
	root.add_child(plain)
	var result: RefCounted = _resolver.resolve(plain)
	_check(NAME, result.get_status() == _ResultScript.Status.UNSUPPORTED, "无边界节点应为 UNSUPPORTED。")
	plain.free()


## 7. GridPlacedObject 根仍按原语义解析（兼容回归）。
func _test_07_grid_root_still_supported() -> void:
	const NAME: String = "07_Grid兼容"
	var grid: Node = _GridPlacedObject.new()
	grid.name = "GridRoot"
	var grid_view: Node = _make_view("GridView")
	grid.add_child(grid_view)
	root.add_child(grid)
	var result: RefCounted = _resolver.resolve(grid)
	_check(NAME, result.get_status() == _ResultScript.Status.SINGLE_TARGET, "Grid 根应仍为单目标。")
	_check(NAME, result.get_component_root() == grid, "Grid 组件根不变。")
	_free_tree(grid)


# ===== 辅助 =====

## 构造带 VisualView 子节点的 PlaceableToken；不入树，由调用方决定挂载位置。
func _make_token(node_name: String) -> PlaceableToken:
	var token: PlaceableToken = PlaceableToken.new()
	token.name = node_name
	var view: Node = _make_view("VisualView")
	token.add_child(view)
	return token


## 实例化真实 ObjectVisualView；显式 _ready 缓存子节点（沿用既有测试惯例）。
func _make_view(node_name: String) -> ObjectVisualView:
	var view: ObjectVisualView = _ViewScene.instantiate() as ObjectVisualView
	view.name = node_name
	return view


## 释放以 node 为根的测试子树。无返回。
func _free_tree(node: Node) -> void:
	node.free()


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 7
	var passed_checks: int = _checks - _failures.size()
	print("==== VisualTargetResolver PlaceableToken 测试摘要 ====")
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
