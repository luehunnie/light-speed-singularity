@tool
class_name LightSpeedArtProfileVisualTargetResult
extends RefCounted

## 视觉目标解析只读结果对象（D4.5-A2）。
## 职责：承载一次解析的全部事实——状态、选中节点、组件根、目标集合、主目标、被忽略节点、稳定原因码。
## 输入输出：由 Resolver 静态工厂构造；Dock 只读访问 getter；本对象不持有可变对外引用。
## 副作用：无；不修改节点树、不修改资源、不复制 Profile。
## 边界：所有数组在构造时复制，getter 返回 duplicate()，外部无法穿透到内部可变数组；
##       NO_TARGET / UNSUPPORTED 不得伪造目标；reason_code 为稳定英文枚举式字符串，不含中文 UI 文案。


## 解析状态。Dock 据此决定展示分支；Resolver 不直接返回 null 表达“多目标”。
enum Status {
	## 无可编辑目标（空选择或组件无正式视觉）。
	NO_TARGET,
	## 唯一目标，primary_target 已确定。
	SINGLE_TARGET,
	## 多个目标，primary_target 为 null，由 Dock 让用户选择。
	MULTIPLE_TARGETS,
	## 当前选择不属于可编辑组件边界。
	UNSUPPORTED,
}


# 解析状态。默认 NO_TARGET，保证空构造结果安全。
var _status: int = Status.NO_TARGET
# 触发本次解析的选中节点；可能为 null（空选择）。
var _selected_node: Node = null
# 所属组件根（最近的 GridPlacedObject）；直接选无组件祖先的视觉时可为视觉自身。
var _component_root: Node = null
# 目标 ObjectVisualView 集合，稳定场景树深度优先顺序；构造时复制。
var _targets: Array = []
# 主目标；SINGLE_TARGET 时为唯一目标，MULTIPLE_TARGETS / NO_TARGET / UNSUPPORTED 时为 null。
var _primary_target: Node = null
# 因嵌套组件边界而跳过的子组件根集合；构造时复制。
var _ignored_nodes: Array = []
# 稳定英文原因码，供 Dock 映射中文文案；不直接保存 UI 文案。
var _reason_code: String = "no_selection"


## 空选择结果：NO_TARGET + no_selection。
## 无参数；返回只读结果；不伪造任何目标。
static func for_no_selection() -> LightSpeedArtProfileVisualTargetResult:
	var r: LightSpeedArtProfileVisualTargetResult = new()
	r._status = Status.NO_TARGET
	r._selected_node = null
	r._component_root = null
	r._primary_target = null
	r._reason_code = "no_selection"
	return r


## 不支持结果：UNSUPPORTED + 指定原因码。
## selected 为当前选中节点；reason_code 为稳定英文串；不伪造目标。
static func for_unsupported(selected: Node, reason_code: String) -> LightSpeedArtProfileVisualTargetResult:
	var r: LightSpeedArtProfileVisualTargetResult = new()
	r._status = Status.UNSUPPORTED
	r._selected_node = selected
	r._component_root = null
	r._primary_target = null
	r._reason_code = reason_code
	return r


## 直接选择视觉节点结果：SINGLE_TARGET + direct_visual。
## 用户已明确指定编辑目标，不因所属组件含其他视觉而扩大集合。
## component_root 为最近 GridPlacedObject 祖先，没有则由调用方传入视觉自身。
static func for_direct_visual(
		selected: Node,
		visual: ObjectVisualView,
		component_root: Node
) -> LightSpeedArtProfileVisualTargetResult:
	var r: LightSpeedArtProfileVisualTargetResult = new()
	r._status = Status.SINGLE_TARGET
	r._selected_node = selected
	r._component_root = component_root
	r._targets = [visual]
	r._primary_target = visual
	r._reason_code = "direct_visual"
	return r


## 组件集合结果：依据目标数量派生状态与原因码。
## selected 为触发节点；component_root 为最近 GridPlacedObject；
## targets 为组件内 ObjectVisualView 集合；ignored_nodes 为被跳过的嵌套子组件根；
## 两个数组均在此复制；0→NO_TARGET，1→SINGLE_TARGET，多→MULTIPLE_TARGETS。
static func for_component(
		selected: Node,
		component_root: Node,
		targets: Array,
		ignored_nodes: Array
) -> LightSpeedArtProfileVisualTargetResult:
	var r: LightSpeedArtProfileVisualTargetResult = new()
	r._selected_node = selected
	r._component_root = component_root
	r._targets = targets.duplicate()
	r._ignored_nodes = ignored_nodes.duplicate()
	match targets.size():
		0:
			r._status = Status.NO_TARGET
			r._primary_target = null
			r._reason_code = "component_has_no_visual"
		1:
			r._status = Status.SINGLE_TARGET
			r._primary_target = targets[0]
			r._reason_code = "component_single_visual"
		_:
			r._status = Status.MULTIPLE_TARGETS
			r._primary_target = null
			r._reason_code = "component_multiple_visuals"
	return r


## 取状态。无副作用。
func get_status() -> int:
	return _status


## 取选中节点。无副作用；可能返回 null。
func get_selected_node() -> Node:
	return _selected_node


## 取组件根。无副作用；可能返回 null。
func get_component_root() -> Node:
	return _component_root


## 取主目标。无副作用；SINGLE_TARGET 返回唯一目标，其余返回 null。
func get_primary_target() -> Node:
	return _primary_target


## 取目标集合副本。无副作用；修改返回值不影响内部数组。
func get_targets() -> Array:
	return _targets.duplicate()


## 取被忽略节点集合副本。无副作用；修改返回值不影响内部数组。
func get_ignored_nodes() -> Array:
	return _ignored_nodes.duplicate()


## 取稳定原因码。无副作用；Dock 据此映射中文文案。
func get_reason_code() -> String:
	return _reason_code
