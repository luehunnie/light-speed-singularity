@tool
extends RefCounted

# AF-08 Content Palette 服务（Guide §9）：正式新增对象的标准入口。
# Palette 不自持机关清单：条目全部来自 FormalContentRegistry（一个声明，多工具消费）。
# 放置流程（Guide §9 操作 1-5）：选类型 → 实例化声明 PackedScene → 经统一 Placement Query 找首个
#   合法空格 → 立即分配 Stable ID → 加入 RuntimeObjects 正式角色 → 进入正常 Godot 2D 编辑。
# FileSystem 保留给技术人员，不是标准内容生产入口。


const _FormalContentDiscovery: GDScript = preload(
	"res://gameplay/content/formal_content_discovery.gd"
)
const _FormalContentRegistry: GDScript = preload(
	"res://gameplay/content/formal_content_registry.gd"
)
const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _EditorPlacementQuery: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/editor_placement_query.gd"
)

# RuntimeObjects 角色名（与 LevelValidator 冻结角色一致；正式对象唯一容器）。
const RUNTIME_OBJECTS_ROLE: String = "RuntimeObjects"

# D-04 墙体内容域 token（WallContentDefinition.get_content_domain）。
const WALL_CONTENT_DOMAIN: StringName = &"wall"


# 发现并构建内容 Registry（失败返回 null；错误已由 Discovery fail-fast 输出）。
static func build_registry() -> _FormalContentRegistry:
	var result: Dictionary = _FormalContentDiscovery.discover()
	if not result.ok:
		return null
	return _FormalContentRegistry.build(result.definitions)


# 生成 Palette 条目：{type_id, display_name, category, domain}；仅含可预放置定义，按登记序。
static func build_palette_entries(registry, only_type_ids: Array = []) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if registry == null:
		return entries
	for type_id: StringName in registry.get_type_ids():
		if not only_type_ids.is_empty() and not only_type_ids.has(type_id):
			continue
		var definition: Variant = registry.get_definition(type_id)
		if not definition.preplaceable:
			continue
		entries.append({
			"type_id": type_id,
			"display_name": definition.display_name,
			"category": definition.category,
			"domain": definition.get_content_domain(),
		})
	return entries


# 从 Palette 放置一个正式对象（Guide §9 点击放置口径；拖入 2D 属 GUI 增强，验证见 Human Gate）。
# [br]add_to_tree=true：立即 add_child + 设 owner（headless 服务口径）；
# [br]add_to_tree=false：只构建节点 / 定位 / 分配 ID，不入树（调用方把 add_child+owner 包进编辑事务，
# [br]  commit 时由事务 do 段执行；result.container 为目标容器）。
# [br]返回 {ok, node, cell, stable_instance_id, container, reason}；失败时已实例化节点被释放，零残留。
# [br]稳定 ID 发号器按关卡既有序号播种（经 StableIdService 口径，不与已持久化 ID 冲突）；
# [br]写入走 StableIdService 同源口径（BasicCrystal 同 token 补写 crystal_id，不建第二套编号）。
# [br]D-04 墙体域（wall）：合法性走墙体专用规则（Terrain 内 + 非 WallLayer 墙格 + 无对象占用，
# [br]  不要求 LegalArea），首个合法空格扫描经 _find_first_wall_free_cell。
func place(registry, content_type_id: StringName, level_root: Node2D,
		add_to_tree: bool = true) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		return {"ok": false, "node": null, "cell": Vector2i.ZERO, "container": null,
				"stable_instance_id": "", "reason": reason}
	if registry == null or level_root == null:
		return fail.call("Registry 或关卡根缺失。")
	var definition: Variant = registry.get_definition(content_type_id)
	if definition == null:
		return fail.call("未声明的正式类型：%s" % content_type_id)
	if not definition.preplaceable:
		return fail.call("类型 %s 不可预放置。" % content_type_id)
	var container := _find_runtime_objects(level_root)
	if container == null:
		return fail.call("关卡缺少 RuntimeObjects 正式角色。")
	var query := _EditorPlacementQuery.new()
	if not query.build(level_root):
		return fail.call("关卡四层结构不完整，无法评估放置合法性。")
	var offsets: Array[Vector2i] = [Vector2i.ZERO]
	if definition.get("static_footprint_offsets") != null:
		var declared: Array[Vector2i] = definition.static_footprint_offsets
		if not declared.is_empty():
			offsets = declared
	var is_wall_content: bool = definition.get_content_domain() == WALL_CONTENT_DOMAIN
	var cell := Vector2i.MAX
	if is_wall_content:
		cell = _find_first_wall_free_cell(level_root, query, offsets)
	else:
		cell = _find_first_free_cell(query, offsets)
	if cell == Vector2i.MAX:
		return fail.call("无合法空格（墙体：Terrain 内且无 WallLayer 格与对象占用；其余：Terrain/LegalArea 内且无 Wall/占用）。")
	return _place_definition_instance(definition, level_root, cell, container, add_to_tree, fail)


# 在指定锚格放置一个墙体域正式对象（D-04 一键包裹等定点放置入口；点击 Palette 自动扫描走 place）。
# [br]墙体专用合法性（同 place 的 wall 分支）：Terrain 内 + 非 WallLayer 墙格 + 整组 footprint 无对象占用。
# [br]返回形状与 place 一致；失败时零残留。
func place_wall_at(registry, content_type_id: StringName, level_root: Node2D, cell: Vector2i,
		add_to_tree: bool = true) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		return {"ok": false, "node": null, "cell": cell, "container": null,
				"stable_instance_id": "", "reason": reason}
	if registry == null or level_root == null:
		return fail.call("Registry 或关卡根缺失。")
	var definition: Variant = registry.get_definition(content_type_id)
	if definition == null:
		return fail.call("未声明的正式类型：%s" % content_type_id)
	if not definition.preplaceable:
		return fail.call("类型 %s 不可预放置。" % content_type_id)
	if definition.get_content_domain() != WALL_CONTENT_DOMAIN:
		return fail.call("类型 %s 非墙体域，拒绝定点墙体放置。" % content_type_id)
	var container := _find_runtime_objects(level_root)
	if container == null:
		return fail.call("关卡缺少 RuntimeObjects 正式角色。")
	var offsets: Array[Vector2i] = [Vector2i.ZERO]
	if definition.get("static_footprint_offsets") != null:
		var declared: Array[Vector2i] = definition.static_footprint_offsets
		if not declared.is_empty():
			offsets = declared
	var occupied: Array[Vector2i] = _EditorPlacementQuery.collect_occupied_cells(level_root)
	for offset: Vector2i in offsets:
		var rejection := _wall_cell_rejection(level_root, cell + offset, occupied)
		if not rejection.is_empty():
			return fail.call(rejection)
	return _place_definition_instance(definition, level_root, cell, container, add_to_tree, fail)


# 共享放置尾部：实例化 → Node2D 校验 → 稳定 ID → 定位 → 入树（place / place_wall_at 同源）。
func _place_definition_instance(definition: Variant, level_root: Node2D, cell: Vector2i,
		container: Node2D, add_to_tree: bool, fail: Callable) -> Dictionary:
	var instance: Node = definition.scene.instantiate()
	if not (instance is Node2D):
		instance.free()
		return fail.call("类型 %s 场景根非 Node2D。" % definition.content_type_id)
	var stable_id: String = _StableIdService.next_stable_instance_id(level_root)
	_StableIdService.assign_stable_id(instance, stable_id)
	(instance as Node2D).position = _GridCoordinateRules.cell_to_world(cell)
	if add_to_tree:
		container.add_child(instance)
		instance.owner = level_root
	return {"ok": true, "node": instance, "cell": cell, "container": container,
			"stable_instance_id": stable_id, "reason": "已放置。"}


# 行主序扫描 Terrain 外包内首个对整组占格合法的锚点；找不到返回 Vector2i.MAX。
func _find_first_free_cell(query, offsets: Array[Vector2i]) -> Vector2i:
	var bounds: Rect2i = query.get_terrain_bounds()
	for y: int in range(bounds.position.y, bounds.position.y + bounds.size.y):
		for x: int in range(bounds.position.x, bounds.position.x + bounds.size.x):
			var anchor := Vector2i(x, y)
			var cells: Array[Vector2i] = []
			for offset: Vector2i in offsets:
				cells.append(anchor + offset)
			if query.evaluate(cells).is_allowed():
				return anchor
	return Vector2i.MAX


# D-04 墙体域首个合法空格扫描：行主序，整组占格均满足墙体专用规则（不要求 LegalArea）。
# [br]对象占用集合整次扫描只采集一次；找不到返回 Vector2i.MAX。
func _find_first_wall_free_cell(level_root: Node2D, query, offsets: Array[Vector2i]) -> Vector2i:
	var occupied: Array[Vector2i] = _EditorPlacementQuery.collect_occupied_cells(level_root)
	var bounds: Rect2i = query.get_terrain_bounds()
	for y: int in range(bounds.position.y, bounds.position.y + bounds.size.y):
		for x: int in range(bounds.position.x, bounds.position.x + bounds.size.x):
			var anchor := Vector2i(x, y)
			var group_free := true
			for offset: Vector2i in offsets:
				if not _wall_cell_rejection(level_root, anchor + offset, occupied).is_empty():
					group_free = false
					break
			if group_free:
				return anchor
	return Vector2i.MAX


# 墙体专用单格合法性（D-04）：Terrain 内、非 WallLayer 墙格（旧墙兼容输入不重叠成双真值）、
# 无正式对象占用（含其他墙对象 footprint）。合法返回空串，否则返回拒绝原因。
static func _wall_cell_rejection(level_root: Node2D, cell: Vector2i, occupied: Array[Vector2i]) -> String:
	var terrain: TileMapLayer = _EditorPlacementQuery.find_layer(
		level_root, _EditorPlacementQuery.ROLE_TERRAIN)
	var wall: TileMapLayer = _EditorPlacementQuery.find_layer(
		level_root, _EditorPlacementQuery.ROLE_WALL)
	if terrain == null or terrain.get_cell_source_id(cell) == -1:
		return "格 %s 越界/非 Terrain。" % [cell]
	if wall != null and wall.get_cell_source_id(cell) != -1:
		return "格 %s 已有 WallLayer 墙格（旧墙兼容输入，拒绝重复墙体数据）。" % [cell]
	if occupied.has(cell):
		return "格 %s 被正式对象占用。" % [cell]
	return ""


# 找 RuntimeObjects 正式角色容器（关卡根直接子 Node2D）。
static func _find_runtime_objects(level_root: Node2D) -> Node2D:
	for child in level_root.get_children():
		var candidate: Node = child
		if candidate is Node2D and candidate.name == StringName(RUNTIME_OBJECTS_ROLE):
			return candidate
	return null
