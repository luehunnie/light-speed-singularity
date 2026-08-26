@tool
class_name LightSpeedArtProfileVisualTargetResolver
extends RefCounted

## 正式视觉目标通用解析器（D4.5-A2；AF-Artwork 扩展 PlaceableToken 组件边界）。
## 职责：把编辑器当前选中节点解析为只读 VisualTargetResult，覆盖组件边界定位、深层视觉收集与嵌套隔离。
## 输入输出：输入 Node 或 null，返回 VisualTargetResult（永不返回 null 表达“多目标”）。
## 副作用：无；不增删节点、不修改位置、不写 Profile、不读取节点名称作为身份。
## 边界：组件边界为最近 GridPlacedObject 或 PlaceableToken 祖先（含自身）——前者覆盖固定格对象，
##       后者覆盖可放置机关（加速器 / 减速器 / 镜面 token 等新机制无需逐类型接入即可被解析）；
##       遇到嵌套组件根（任一种）记录并停止其子树；
##       EmissionPreview 永不入 targets；直接选视觉节点只返回该节点，不扩大到同组件其他视觉；
##       不存在 EmitterConfigNode / Mirror / Crystal 等逐类型分支。


# 结果对象脚本：preload 引用，避开新 class_name 全局缓存未重建时的类型解析问题。
const _Result: GDScript = preload(
	"res://addons/light_speed_art_profile/target/visual_target_result.gd"
)


## 解析单个选中节点对应的正式视觉目标集合。
## selected 可为 null；返回只读 VisualTargetResult，多目标时返回 MULTIPLE_TARGETS 而非 null。
func resolve(selected: Node) -> RefCounted:
	# 1. null 或已释放：无选择。
	if selected == null or not is_instance_valid(selected):
		return _Result.for_no_selection()
	# 2. 直接选择 EmissionPreview：自动定位所属组件正式视觉集合，Preview 自身永不入 targets。
	if selected is EmissionPreview:
		return _resolve_from_preview(selected)
	# 3. 直接选择 ObjectVisualView：用户已明确指定编辑目标，只返回自身。
	if selected is ObjectVisualView:
		var visual: ObjectVisualView = selected as ObjectVisualView
		var ancestor: Node = _find_nearest_component(visual)
		return _Result.for_direct_visual(visual, visual, ancestor if ancestor != null else visual)
	# 4. 选择组件根或组件内部普通节点：向上找最近组件根（GridPlacedObject / PlaceableToken）作为组件边界。
	var component_root: Node = _find_nearest_component(selected)
	if component_root == null:
		return _Result.for_unsupported(selected, "no_component_boundary")
	return _collect_from_component(selected, component_root)


## 直接选择 EmissionPreview 的解析：定位最近组件根（GridPlacedObject / PlaceableToken）并收集其正式视觉。
## preview 为 EmissionPreview；返回组件集合结果；组件根缺失时返回 UNSUPPORTED。
# Preview 自身不是 ObjectVisualView，收集器天然排除，无需额外过滤。
func _resolve_from_preview(preview: Node) -> RefCounted:
	var component_root: Node = _find_nearest_component(preview)
	if component_root == null:
		return _Result.for_unsupported(preview, "no_component_boundary")
	return _collect_from_component(preview, component_root)


## 从组件根向下递归收集 ObjectVisualView，构造组件集合结果。
## selected 为触发节点；component_root 为最近 GridPlacedObject；返回只读结果。
func _collect_from_component(selected: Node, component_root: Node) -> RefCounted:
	var targets: Array = []
	var ignored_nodes: Array = []
	_collect_visuals(component_root, true, targets, ignored_nodes)
	return _Result.for_component(selected, component_root, targets, ignored_nodes)


## 深度优先递归收集 ObjectVisualView；遇到嵌套组件根（GridPlacedObject / PlaceableToken）记录并停止其子树。
## node 为当前节点；is_root 标识当前节点是否为组件根（组件根本身不作为嵌套组件跳过）；
## targets / ignored_nodes 由调用方持有并就地追加；顺序为稳定场景树深度优先，不按 Node.name 排序。
func _collect_visuals(
		node: Node,
		is_root: bool,
		targets: Array,
		ignored_nodes: Array
) -> void:
	# 非根节点遇到组件根（任一种）：记录为被忽略的嵌套子组件根，不进入其子树。
	if not is_root and _is_component_root(node):
		ignored_nodes.append(node)
		return
	# 收集正式视觉节点；EmissionPreview 非 ObjectVisualView，天然不入集合。
	if node is ObjectVisualView:
		targets.append(node)
	# 继续向子节点递归，允许视觉位于任意子层级。
	for child: Node in node.get_children():
		_collect_visuals(child, false, targets, ignored_nodes)


## 从 node 向上（含自身）寻找最近的组件根（GridPlacedObject 或 PlaceableToken）。
## node 为起点；返回最近组件根或 null；不跨到更外层组件，不依赖节点名称。
func _find_nearest_component(node: Node) -> Node:
	var current: Node = node
	while current != null:
		if _is_component_root(current):
			return current
		current = current.get_parent()
	return null


## 组件根判定：GridPlacedObject（固定格对象）或 PlaceableToken（可放置机关）。
## 新机制只要继承两者之一即被 Resolver 覆盖，无需在本文件逐类型登记。
func _is_component_root(node: Node) -> bool:
	return node is GridPlacedObject or node is PlaceableToken
