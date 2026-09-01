extends RefCounted

## 预置机关收编器（AF-10 第一批）。
## 职责：启动时扫描 RuntimeObjects 直属子节点中符合正式机关契约（PlaceableToken 派生且 mechanism_id 为空，
## 即场景作者预置、未被运行期配置）的机关节点，按 position 派生格注册进 OccupancyRegistry 并纳入自身只读映射，
## 供运行期占用查询与光线/光粒层节点解析。
## 边界：不写玩家库存、不进 PlacementController 玩家放置映射（R 清理 clear_all_placed 与库存一致性断言
## 均不涉及预置机关）；不写死具体机关类型（镜面/加/减速器等 PlaceableToken 派生机关走同一契约面）；
## 重复收编、非法格、占用冲突均安全失败并 push_error 可诊断，失败节点不进入映射、mechanism_id 复位、
## position 恢复原值。
## 不负责：拖拽/移动/回收预置机关（玩家交互留后续批次）、视觉创建、光传播、库存数量、RunState、UI。


const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")

## 预置机关 ID 前缀；与玩家机关 ID（<content_type_id>_<序号>）命名空间隔离，不冲突不复用。
const _ID_PREFIX: String = "preplaced_"

var _occupancy: _OccupancyRegistry
## 预置格合法性只读判定 Callable（Vector2i -> bool）；未注入时只依赖 OccupancyRegistry 冲突拒绝。
var _is_cell_adoptable: Callable
## 预置机关 ID → 节点；本收编器是唯一修改者，外部经 get_preplaced_node 只读解析。
var _preplaced_by_id: Dictionary[StringName, Variant] = {}
var _next_serial: int = 1


## 构造收编器；occupancy 必须非空，is_cell_adoptable 可缺省（仅占用冲突防护）。
func _init(
		occupancy: _OccupancyRegistry,
		is_cell_adoptable: Callable = Callable()
) -> void:
	_occupancy = occupancy
	_is_cell_adoptable = is_cell_adoptable


## 扫描容器直属子节点并收编全部合格预置机关；返回成功收编数量。
## [br]只处理直属子节点（与场景作者放置层级一致）；非机关节点（水晶/发射器配置/普通 Node2D 等
## 非 PlaceableToken 契约节点）静默跳过，不算失败。
func adopt_all(container: Node) -> int:
	if container == null:
		push_error("PreplacedMechanismAdopter: 收编容器为空，无法扫描预置机关。")
		return 0
	var adopted: int = 0
	for child: Node in container.get_children():
		if _adopt_one(child):
			adopted += 1
	return adopted


## 收编单个节点；返回是否成功。
## [br]合格条件：有效且未排队删除的 PlaceableToken、mechanism_id 为空（未被运行期配置过）。
## [br]失败路径全部 push_error 可诊断：已配置机关（重复收编/玩家机关误传）拒绝、格非法拒绝、占用冲突回滚。
func _adopt_one(node: Node) -> bool:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return false
	if node is not PlaceableToken:
		return false
	var token: PlaceableToken = node as PlaceableToken
	if token.mechanism_id != &"":
		push_error(
			"PreplacedMechanismAdopter: 拒绝收编已配置机关（mechanism_id=%s node=%s），保持原状。"
			% [token.mechanism_id, token.name]
		)
		return false
	var cell: Vector2i = token.cell
	# C-08 多格最小接线：按实例 footprint（get_occupied_offsets，冻结裁决 2）自锚格展开全部占格；
	# 单格机关仍展开为 1 格、行为不变；每个占格都必须通过单格收编合法性判定。
	var cells: Array[Vector2i] = []
	for offset: Vector2i in token.get_occupied_offsets():
		cells.append(cell + offset)
	for occupied_cell: Vector2i in cells:
		if _is_cell_adoptable.is_valid() and not bool(_is_cell_adoptable.call(occupied_cell)):
			push_error(
				"PreplacedMechanismAdopter: 预置机关格非法（cell=%s node=%s），拒绝收编。"
				% [occupied_cell, token.name]
			)
			return false
	var mechanism_id: StringName = _make_next_mechanism_id()
	var original_position: Vector2 = token.position
	token.configure(mechanism_id, cell)
	if not _occupancy.register_cells(mechanism_id, cells):
		var occupant_id: StringName = _occupancy.get_mechanism_at(cell)
		push_error(
			"PreplacedMechanismAdopter: 预置机关占用登记失败（cell=%s 已被机关 %s 占用），回滚收编。"
			% [cell, occupant_id]
		)
		token.mechanism_id = &""
		token.position = original_position
		return false
	_preplaced_by_id[mechanism_id] = token
	return true


## 取得预置机关节点；ID 未登记返回 null，调用方需自行 is_instance_valid 校验。
func get_preplaced_node(mechanism_id: StringName) -> Variant:
	if not _preplaced_by_id.has(mechanism_id):
		return null
	return _preplaced_by_id[mechanism_id]


## 是否存在指定预置机关映射。
func has_preplaced(mechanism_id: StringName) -> bool:
	return _preplaced_by_id.has(mechanism_id)


## 当前预置机关数量。
func get_preplaced_count() -> int:
	return _preplaced_by_id.size()


## 预置机关 ID 快照（按映射当前迭代顺序）；返回后映射增删不影响快照。
func get_preplaced_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for key: Variant in _preplaced_by_id.keys():
		ids.append(StringName(key))
	return ids


## 生成下一个预置机关唯一 ID；序号递增不复用，与玩家机关 ID 命名空间隔离。
func _make_next_mechanism_id() -> StringName:
	var mechanism_id: StringName = StringName("%s%d" % [_ID_PREFIX, _next_serial])
	_next_serial += 1
	return mechanism_id
