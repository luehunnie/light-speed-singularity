@tool
extends RefCounted

# AF-08 Stable ID Manager 服务（Guide §7）：正式关卡对象稳定实例 ID 的发现 / 补发 / 重建 / 审计。
# 身份唯一性：stable_instance_id 是唯一实例身份；移动 / 旋转 / 改 Editor Note / 改 Node.name 不改 ID；
# 新建（Palette）/ Ctrl+D / Duplicate as New Level / Spawn 产生新 ID（Guide §7.3）。
# 分配复用 AF-01 StableInstanceIdAllocator（会话内单调、不复用、确定性）。
# 水晶实例身份：BasicCrystal.crystal_id 与 stable_instance_id 同源（补发 / 重建时同一 token 写入两字段），
#   不建立第二套编号；既有手填 crystal_id 的已合并场景不由本服务改写（回归保护）。
# 本服务只写场景节点上的被动字段，不触碰运行时 Registry / Occupancy。


const _StableInstanceIdAllocator: GDScript = preload(
	"res://gameplay/content/stable_instance_id_allocator.gd"
)
const _PlaceableToken: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _GridPlacedObject: GDScript = preload(
	"res://gameplay/grid/grid_placed_object.gd"
)
const _BasicCrystal: GDScript = preload(
	"res://gameplay/crystals/basic_crystal.gd"
)


# 发现 level_root 子树内全部正式对象节点。
# [br]正式对象 = PlaceableToken（玩家工具类机关基类）或 GridPlacedObject（固定格对象基类，
# [br]含 BasicCrystal 与 EmitterConfigNode 派生链）及其派生；深度优先、子节点序稳定返回；
# [br]level_root 自身不计（关卡根不是正式对象）。
static func find_formal_objects(level_root: Node) -> Array[Node]:
	var out: Array[Node] = []
	_gather(level_root, out)
	return out


static func _gather(node: Node, out: Array[Node]) -> void:
	for child in node.get_children():
		var candidate: Node = child
		if candidate is _PlaceableToken or candidate is _GridPlacedObject:
			out.append(candidate)
		_gather(candidate, out)


# 为缺 ID 的正式对象补发稳定 ID（Guide §7.2 语义：已有 ID 一律保持）。
# [br]发号器按关卡内既有最大序号播种（新 ID 不与已持久化 ID 冲突）；返回补发条目数。
static func assign_missing(level_root: Node) -> int:
	var assigned := 0
	var allocator := _seeded_allocator(level_root)
	for node: Node in find_formal_objects(level_root):
		if node.get("stable_instance_id") == null or str(node.get("stable_instance_id")).is_empty():
			_assign(node, allocator.allocate())
			assigned += 1
	return assigned


# 为全部正式对象重发生稳定 ID（Create New Level / Duplicate as New Level 专用，Guide §7.3）。
# [br]返回 重映射表 old_id → new_id（供后续 Objective / Control 引用重建；空旧 ID 无引用语义不入表；
# [br]  BasicCrystal 旧 crystal_id 是历史引用事实，同样入表以保引用重建数据完整）。
static func regenerate_all(level_root: Node) -> Dictionary:
	var remap: Dictionary = {}
	var allocator := _seeded_allocator(level_root)
	for node: Node in find_formal_objects(level_root):
		var old_id := str(node.get("stable_instance_id"))
		var old_crystal_id := String(node.get("crystal_id")) if node is _BasicCrystal else ""
		var new_id := allocator.allocate()
		_assign(node, new_id)
		if not old_id.is_empty():
			remap[old_id] = new_id
		if not old_crystal_id.is_empty() and old_crystal_id != old_id:
			remap[old_crystal_id] = new_id
	return remap


# 单发一个稳定 ID（Palette 放置用）：按关卡既有序号播种后取下一号，不写任何节点。
static func next_stable_instance_id(level_root: Node) -> String:
	return _seeded_allocator(level_root).allocate()


# 审计稳定 ID：缺失数与重复 ID 清单（供 Validator 展示与 Stable ID 修复入口）。
static func audit(level_root: Node) -> Dictionary:
	var total := 0
	var missing := 0
	var seen: Dictionary = {}
	var duplicate_ids: Array[String] = []
	for node: Node in find_formal_objects(level_root):
		total += 1
		var id_value := str(node.get("stable_instance_id"))
		if id_value.is_empty():
			missing += 1
			continue
		if seen.has(id_value) and not duplicate_ids.has(id_value):
			duplicate_ids.append(id_value)
		seen[id_value] = node
	return {"total": total, "missing": missing, "duplicates": duplicate_ids}


# 写入一个稳定 ID：写 stable_instance_id；BasicCrystal 同源写 crystal_id（同一 token，不建第二编号）。
static func _assign(node: Node, stable_id: String) -> void:
	node.set("stable_instance_id", stable_id)
	if node is _BasicCrystal:
		node.set("crystal_id", StringName(stable_id))


# 构造按关卡既有 fci_ 序号播种的发号器（解析子树内全部 stable_instance_id 的最大序号）。
static func _seeded_allocator(level_root: Node) -> _StableInstanceIdAllocator:
	var max_serial := 0
	for node: Node in find_formal_objects(level_root):
		var id_value := str(node.get("stable_instance_id"))
		if id_value.begins_with("fci_"):
			max_serial = maxi(max_serial, id_value.get_slice("_", 1).to_int())
	return _StableInstanceIdAllocator.new(max_serial)
