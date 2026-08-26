extends RefCounted

## 多类型道具栏 Presenter（AF-10 第三批）：从 metadata inventory_entries 计划动态构造/刷新道具卡，
## 持有选中类型事实，供 core_loop 装配拿取命中与 DragFlow type_id 路由；core_loop 不再堆卡级 UI 职责。
## 卡数据（build_card_models）：Registry 正式定义 → display_name + ObjectVisualProfile（图标唯一来源，
## 永久视觉接口 v1.0 §12；经 definition.scene 实例化读取 VisualView.visual_profile，用后立即释放，
## 不复制/不缓存第二份图标路径）；未知类型安全降级（type_id 作显示名 + 占位符图标，数量照常显示）。
## 空 entries 不建卡（调用方保持旧单类型槽位路径）；本类不读 metadata、不访问库存事实——
## 刷新数量/可用性经注入的 Callable 只读查询，不修改任何事实。
## 选中语义：set_selected_type 由核心在未拖拽的拿取按下时写入；get_card_type_id_at 供指针命中解析。


const _CardView: GDScript = preload(
	"res://gameplay/ui/inventory_card_view.gd"
)
const _ObjectVisualViewScript: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_view.gd"
)

## 卡容器（原型 HBoxContainer；卡按展示顺序追加）。
var _cards_container: Control = null
## 旧单类型槽位（多类型模式隐藏，保持原场景节点不改动）。
var _legacy_slot: Control = null
## 展示顺序的卡记录：{type_id: StringName, node: InventoryCardView}。
var _cards: Array[Dictionary] = []
## 当前选中类型；无卡时为空。
var _selected_type_id: StringName = &""


## 装配：cards_container 为卡挂载容器；legacy_slot 为旧 PrototypeTokenSlot（建卡后隐藏，空计划时保持原状）。
func setup(cards_container: Control, legacy_slot: Control) -> void:
	_cards_container = cards_container
	_legacy_slot = legacy_slot


## 由卡数据计划重建全部卡；重复调用安全（旧卡先释放）。
## [br]models 为 build_card_models 输出（{type_id, display_name, quantity, visual_profile}，展示顺序）；
## [br]空数组清除全部卡并恢复旧槽位可见（调用方语义：metadata 无条目走旧单类型路径）。
func build_cards(models: Array) -> void:
	for record: Dictionary in _cards:
		var node: Control = record.get("node", null)
		if is_instance_valid(node):
			node.queue_free()
	_cards.clear()
	_selected_type_id = &""
	if models.is_empty():
		if _legacy_slot != null:
			_legacy_slot.visible = true
		return
	for model_variant: Variant in models:
		if typeof(model_variant) != TYPE_DICTIONARY:
			continue
		var model: Dictionary = model_variant
		var type_id: StringName = StringName(str(model.get("type_id", "")))
		if type_id == &"":
			continue
		var card: PanelContainer = _CardView.new()
		card.setup(
			type_id,
			str(model.get("display_name", type_id)),
			model.get("visual_profile", null)
		)
		_cards_container.add_child(card)
		_cards.append({"type_id": type_id, "node": card})
	if _legacy_slot != null:
		_legacy_slot.visible = false
	if not _cards.is_empty():
		_selected_type_id = _cards[0]["type_id"]


## 刷新全部卡显示；remaining_for/available_for 为 (type_id: StringName) -> int / bool 只读 Callable。
func refresh(remaining_for: Callable, available_for: Callable) -> void:
	for record: Dictionary in _cards:
		var type_id: StringName = record["type_id"]
		var node: Control = record["node"]
		if not is_instance_valid(node):
			continue
		node.refresh(
			int(remaining_for.call(type_id)),
			bool(available_for.call(type_id)),
			type_id == _selected_type_id
		)


## 写入选中类型（核心在未拖拽的拿取按下时调用）；未知类型安全忽略并返回 false。
func set_selected_type(type_id: StringName) -> bool:
	for record: Dictionary in _cards:
		if record["type_id"] == type_id:
			_selected_type_id = type_id
			return true
	return false


## 当前选中类型；无卡为空。
func get_selected_type_id() -> StringName:
	return _selected_type_id


## 视口坐标命中的卡类型；未命中任何卡返回空 StringName（&""）。
## [br]依赖卡布局完成（加入树后至少一帧布局）；headless 集成测试泵帧后调用。
func get_card_type_id_at(viewport_position: Vector2) -> StringName:
	for record: Dictionary in _cards:
		var node: Control = record["node"]
		if not is_instance_valid(node):
			continue
		if node.get_global_rect().has_point(viewport_position):
			return record["type_id"]
	return &""


## 卡数量（展示顺序）。
func get_card_count() -> int:
	return _cards.size()


## 由 Registry 定义与 metadata 计划构建卡数据（静态工厂，无实例状态）。
## [br]registry 为 FormalContentRegistry（null 时全部按未知类型降级）；entries 为
## MetadataInventoryReader.read_ordered_entries 输出；返回展示顺序
## [{type_id, display_name, quantity, visual_profile}]。
## [br]图标解析链：definition.scene 实例化（不入树）→ 递归找首个 ObjectVisualView → 读其
## visual_profile → 立即 free 实例；不落任何路径字符串。未知类型 visual_profile 为 null。
static func build_card_models(registry: Variant, entries: Array) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	for entry_variant: Variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		var type_id: StringName = StringName(str(entry.get("content_type_id", "")))
		if type_id == &"":
			continue
		var display_name: String = str(type_id)
		var profile = null
		var definition: Variant = registry.get_definition(type_id) if registry != null else null
		if definition != null:
			display_name = str(definition.display_name)
			profile = _resolve_profile_from_definition(definition)
		models.append({
			"type_id": type_id,
			"display_name": display_name,
			"quantity": maxi(0, int(entry.get("initial_quantity", 0))),
			"visual_profile": profile,
		})
	return models


## 从定义场景解析 ObjectVisualProfile：实例化（不入树，_init 级副作用可控）→ 递归找首个
## ObjectVisualView → 读取其 visual_profile → 立即 free；任何一步失败返回 null（占位符降级）。
static func _resolve_profile_from_definition(definition: Variant):
	var scene: Variant = definition.get("scene") if definition != null else null
	if scene == null or not scene is PackedScene:
		return null
	var instance: Node = (scene as PackedScene).instantiate()
	if instance == null:
		return null
	var profile = null
	var view = _find_first_visual_view(instance)
	if view != null:
		profile = view.visual_profile
	instance.free()
	return profile


## 递归查找首个 ObjectVisualView（含根；不依赖场景树成员关系，游离实例亦可）。
static func _find_first_visual_view(node: Node):
	if node is _ObjectVisualViewScript:
		return node
	for child: Node in node.get_children():
		var found = _find_first_visual_view(child)
		if found != null:
			return found
	return null
