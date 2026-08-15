@tool
class_name LevelData
extends Resource

## 关卡静态数据资源契约（D7-R2 最小版）。
##
## 职责：
## 单一承载关卡静态配置的可序列化数据——四层逻辑格子（Terrain/Wall/LegalArea，Decoration 纯视觉不入契约）
## 与 v0 固定对象事实（恰好 1 个发射器 + 1 个水晶），提供纯数据自检 validate()。
## 字段全部来自现有正式事实来源（见各字段注释），不发明新事实。
##
## 在当前系统中的位置：
## 与场景表达并行的数据边界，不是场景的替代——现有 .tscn 关卡继续运行，Runtime 不要求只接受 LevelData；
## 由 LevelDataCapture 从合法关卡根只读提取，可经 ResourceSaver/ResourceLoader 保存加载 .tres。
##
## 明确不负责：
## 场景树校验（结构/transform/TileSet/VisualProfile 等仍由 LevelValidator 负责）、运行时行为、
## 选关/存档、WARNING 级规则（legal_wall_overlap / legal_area_empty 属场景校验域，见 validate 注释）。
##
## 关键边界：
## - level_id 无正式来源时保持空（unavailable 政策），绝不以 Node.name / instance_id 顶替；
## - 发射器/水晶方向与形态存储 EmitterConfigNode 同值域的枚举 int，合法性校验委派该公共枚举，不另立白名单；
## - 可变数据资源：保存/加载用原生 ResourceSaver/ResourceLoader，复制用原生 Resource.duplicate(true)，
##   不自建第二套 copy 语义；
## - 序列化演化策略 additive-only：Godot 原生按属性名序列化、缺省属性不写盘、加载时缺失属性回落脚本默认值
##   （见 level_data_test 组 16/17 证明）；新增字段必须带兼容默认值，重命名/删除/类型变化属 breaking，
##   真正发生时才引入显式 schema_version 元数据与迁移器。R2 无已发布持久化资产，故当前不引入 schema_version。

const _EmitterConfigNode: GDScript = preload("res://gameplay/mechanisms/emitters/emitter_config_node.gd")

@export_group("标识")
## 正式关卡 ID。当前无正式来源：默认空（unavailable 政策），非空时必须由显式配置填写且不得含空白字符。
@export var level_id: StringName = &""

@export_group("四层静态格子")
## Terrain 逻辑格（来源：TerrainLayer used cells；Terrain 空 = validate 报错）。
@export var terrain_cells: Array[Vector2i] = []
## Wall 逻辑格（来源：WallLayer used cells；可空；每格必须在 Terrain 内）。
@export var wall_cells: Array[Vector2i] = []
## LegalArea 逻辑格（来源：LegalAreaLayer used cells；可空；每格必须在 Terrain 内）。
## 注：Decoration 纯视觉不参与逻辑，不属于本契约。
@export var legal_area_cells: Array[Vector2i] = []

@export_group("发射器（v0 恰好 1 个）")
## 发射器所在格（来源：EmitterConfigNode.position 经 GridCoordinateRules.world_to_cell 派生）。
@export var emitter_cell: Vector2i = Vector2i.ZERO
## 默认发射形态；值域 = EmitterConfigNode.LightForm（RAY=0 / PARTICLE=1，冻结公共契约）。
@export var emitter_form: int = 0
## 是否允许 Q 运行期切换形态（来源：EmitterConfigNode.allow_form_switch）。
@export var emitter_allow_form_switch: bool = false
## RAY 形态默认方向；值域 = EmitterConfigNode.RayDirection。
@export var emitter_ray_direction: int = 0
## PARTICLE 形态默认方向；值域 = EmitterConfigNode.ParticleDirection。
@export var emitter_particle_direction: int = 0

@export_group("水晶（v0 恰好 1 个）")
## 水晶所在格（来源：BasicCrystal.position 经 world_to_cell 派生）。
@export var crystal_cell: Vector2i = Vector2i.ZERO
## 水晶稳定 ID（来源：BasicCrystal.crystal_id；可为空，validate 会报告）。
@export var crystal_id: StringName = &""


## 校验本资源静态数据一致性；返回全部问题的可读中文描述（PackedStringArray），无问题返回空。
## [br]校验域 = LevelValidator 对同源事实的 ERROR 级规则在纯数据上的等价镜像：
##   terrain 空、wall/legal 越界 Terrain、发射器/水晶越界 Terrain 或位于 Wall、二者同格重叠、
##   crystal_id 为空、形态/方向枚举越域、level_id 非空时含空白。
## [br]刻意不在本域：WARNING 级规则（legal_area_empty / legal_wall_overlap）与一切场景结构检查
##   （TileSet/transform/VisualProfile/路径/数量——数量由提取层保证，结构由 LevelValidator 保证）。
## [br]本函数无副作用，不修改字段，一次返回全部问题。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# level_id：空合法（unavailable 政策）；非空不得含空白字符。
	var id_str: String = String(level_id)
	if level_id != &"":
		for i: int in range(id_str.length()):
			if id_str.unicode_at(i) == 32 or id_str.unicode_at(i) == 9 or id_str.unicode_at(i) == 10 or id_str.unicode_at(i) == 13:
				problems.append("LevelData：level_id 非空时不得含空白字符：%s。" % id_str)
				break
	# Terrain 空。
	if terrain_cells.is_empty():
		problems.append("LevelData：terrain_cells 为空，关卡必须至少有一个 Terrain 格。")
	var terrain: Dictionary = {}
	for cell: Vector2i in terrain_cells:
		terrain[cell] = true
	var wall: Dictionary = {}
	for cell: Vector2i in wall_cells:
		wall[cell] = true
	# Wall / LegalArea 每格必须在 Terrain 内。
	for cell: Vector2i in wall_cells:
		if not terrain.has(cell):
			problems.append("LevelData：wall_cells 格 %s 位于 Terrain 之外。" % str(cell))
	for cell: Vector2i in legal_area_cells:
		if not terrain.has(cell):
			problems.append("LevelData：legal_area_cells 格 %s 位于 Terrain 之外。" % str(cell))
	# 发射器枚举域（委派公共枚举，不另立白名单）。
	if not (emitter_form in _EmitterConfigNode.LightForm.values()):
		problems.append("LevelData：emitter_form 枚举域非法：%d。" % emitter_form)
	if not (emitter_ray_direction in _EmitterConfigNode.RayDirection.values()):
		problems.append("LevelData：emitter_ray_direction 枚举域非法：%d。" % emitter_ray_direction)
	if not (emitter_particle_direction in _EmitterConfigNode.ParticleDirection.values()):
		problems.append("LevelData：emitter_particle_direction 枚举域非法：%d。" % emitter_particle_direction)
	# 固定对象位置：Terrain 内、不在 Wall、互不重叠（枚举域非法不影响位置检查）。
	if not terrain.has(emitter_cell):
		problems.append("LevelData：emitter_cell %s 位于 Terrain 之外。" % str(emitter_cell))
	if wall.has(emitter_cell):
		problems.append("LevelData：emitter_cell %s 位于 Wall 上。" % str(emitter_cell))
	if crystal_id == &"":
		problems.append("LevelData：crystal_id 为空，水晶必须有稳定 ID。")
	if not terrain.has(crystal_cell):
		problems.append("LevelData：crystal_cell %s 位于 Terrain 之外。" % str(crystal_cell))
	if wall.has(crystal_cell):
		problems.append("LevelData：crystal_cell %s 位于 Wall 上。" % str(crystal_cell))
	if emitter_cell == crystal_cell:
		problems.append("LevelData：emitter_cell 与 crystal_cell 占同一格 %s。" % str(emitter_cell))
	return problems
