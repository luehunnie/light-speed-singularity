class_name FormalContentRegistry
extends RefCounted

## 正式内容类型索引（AF-01 / P0-1，Guide 5.1）：唯一 Formal Declaration 消费入口。
## 冻结原则：Registry = Index，不复制 Definition 能力元数据；构建后只读，无逐项注册 API。
## 消费方（Palette / Inventory / Objective / Validator / Runtime Spawn）一律经本类按 content_type_id 查询，
## 不自持定义清单、不旁路 Discovery（"不维护第二张人工 Catalog"，Guide 5.2）。


var _definitions_by_type_id: Dictionary[StringName, FormalContentDefinition] = {}
var _ordered_type_ids: Array[StringName] = []


## 从已发现定义数组构建索引；遇重复类型或非定义条目拒绝构建并返回 null。
static func build(definitions: Array) -> FormalContentRegistry:
	var registry := FormalContentRegistry.new()
	for entry: Variant in definitions:
		if not (entry is FormalContentDefinition):
			push_error("FormalContentRegistry: 拒绝非 FormalContentDefinition 条目。")
			return null
		var definition := entry as FormalContentDefinition
		if definition.content_type_id == &"":
			push_error("FormalContentRegistry: 拒绝空 content_type_id。")
			return null
		if registry._definitions_by_type_id.has(definition.content_type_id):
			push_error("FormalContentRegistry: 拒绝重复 content_type_id：%s" % definition.content_type_id)
			return null
		registry._definitions_by_type_id[definition.content_type_id] = definition
		registry._ordered_type_ids.append(definition.content_type_id)
	return registry


## 指定类型是否已登记。
func has_type(content_type_id: StringName) -> bool:
	return _definitions_by_type_id.has(content_type_id)


## 按类型取定义；未登记返回 null。
func get_definition(content_type_id: StringName) -> FormalContentDefinition:
	if not _definitions_by_type_id.has(content_type_id):
		return null
	return _definitions_by_type_id[content_type_id]


## 全部类型 token 副本（登记序）。
func get_type_ids() -> Array[StringName]:
	return _ordered_type_ids.duplicate()


## 已登记类型数。
func get_type_count() -> int:
	return _ordered_type_ids.size()


## 按内容域过滤的定义副本（mechanism / objective_target / emitter）。
func get_definitions_in_domain(domain: StringName) -> Array[FormalContentDefinition]:
	var matched: Array[FormalContentDefinition] = []
	for type_id: StringName in _ordered_type_ids:
		var definition: FormalContentDefinition = _definitions_by_type_id[type_id]
		if definition.get_content_domain() == domain:
			matched.append(definition)
	return matched
