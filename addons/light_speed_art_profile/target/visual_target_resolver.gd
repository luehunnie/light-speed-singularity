@tool
class_name LightSpeedArtProfileVisualTargetResolver
extends RefCounted

## 正式视觉目标解析器。
## 职责：把编辑器当前选中节点解析为正式 ObjectVisualView。
## 输入输出：输入 Node 或 null，返回 ObjectVisualView 或 null。
## 副作用：无；不增删节点、不修改位置、不写 Profile。
## 边界：只检查自身与直属子节点；EmissionPreview 永不作为正式视觉返回。


## 解析单个选中节点对应的正式视觉节点。
## selected 可为 null；返回唯一 ObjectVisualView，歧义或不支持时返回 null。
func resolve(selected: Node) -> ObjectVisualView:
	if selected == null or not is_instance_valid(selected):
		return null
	if selected is EmissionPreview:
		return null
	if selected is ObjectVisualView:
		return selected
	if selected is EmitterConfigNode:
		return _resolve_emitter_visual(selected as EmitterConfigNode)
	return _resolve_single_direct_visual(selected)


## 解析发射器配置节点的正式视觉。
## 输入 EmitterConfigNode；返回直属 ObjectVisualView 或 null，明确跳过 EmissionPreview。
func _resolve_emitter_visual(emitter: EmitterConfigNode) -> ObjectVisualView:
	var direct_visuals: Array[ObjectVisualView] = _collect_direct_visuals(emitter)
	if direct_visuals.size() != 1:
		return null
	return direct_visuals[0]


## 解析普通关卡对象的唯一直属正式视觉。
## 输入任意 Node；返回唯一直属 ObjectVisualView，多个或没有均返回 null。
func _resolve_single_direct_visual(parent: Node) -> ObjectVisualView:
	var direct_visuals: Array[ObjectVisualView] = _collect_direct_visuals(parent)
	if direct_visuals.size() != 1:
		return null
	return direct_visuals[0]


## 收集直属正式视觉子节点。
## 输入父节点；输出直属 ObjectVisualView 数组；不递归、不返回 EmissionPreview。
func _collect_direct_visuals(parent: Node) -> Array[ObjectVisualView]:
	var direct_visuals: Array[ObjectVisualView] = []
	for child: Node in parent.get_children():
		if child is EmissionPreview:
			continue
		if child is ObjectVisualView:
			direct_visuals.append(child)
	return direct_visuals
