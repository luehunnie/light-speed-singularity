class_name PlacementCandidate
extends RefCounted

## Placement Candidate State（AF-03 / P0-4，Guide §14）：一切改变 位置 / Configuration / Footprint /
## Occupancy 的玩家操作在原子提交前的唯一候选事实载体。
## Candidate 不提前污染 authoritative state：不登记占用、不注册 Registry、不扣库存、不改节点；
## 非法候选被拒绝时 Configuration / Occupancy / Registry / Visual 全部不变（由调用方保证零提交）。
## 本类为不可变快照：构造后字段不再变化；footprint 由 FootprintContract 在构造时确定性展开。


const _FootprintContract: GDScript = preload(
	"res://gameplay/placement/contracts/footprint_contract.gd"
)
const _MechanismDefinition: GDScript = preload(
	"res://gameplay/content/mechanism_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)

## 候选目标：新 Spawn（stable_instance_id 为空）或既有实例（携带其稳定 ID）。
var stable_instance_id: String = ""
## 候选内容类型。
var content_type_id: StringName = &""
## 候选 anchor 格（Registry / 节点位置事实的格锚）。
var anchor_cell: Vector2i = Vector2i.ZERO
## 候选配置快照（detached；调用方持有的配置对象不受后续修改影响）。
var configuration: _MechanismConfiguration = null
## 候选绝对占格（构造时经 FootprintContract 展开的副本）。
var footprint_cells: Array[Vector2i] = []


## 构造候选快照：按 Definition 声明展开 footprint（纯计算，无世界查询）。
## [br]configuration 允许为 null（无配置声明的类型）；快照持有 configuration 的 duplicate 副本。
func _init(
	p_stable_instance_id: String,
	p_content_type_id: StringName,
	p_anchor_cell: Vector2i,
	definition: _MechanismDefinition,
	p_configuration: _MechanismConfiguration
) -> void:
	stable_instance_id = p_stable_instance_id
	content_type_id = p_content_type_id
	anchor_cell = p_anchor_cell
	configuration = p_configuration.duplicate_configuration() if p_configuration != null else null
	footprint_cells = _FootprintContract.footprint_cells(definition, p_configuration, p_anchor_cell)
