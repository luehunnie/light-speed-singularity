class_name ParticleView
extends Node2D

## 单颗光粒视觉实体（D7-4 B4a；B4b-2 加视觉传播 Tween helper）。
## 职责：按传播方向旋转一个 24×16 的主体色块（Body 为本场景 particle_view.tscn 内的静态 ColorRect 子节点）；
##   位置由外部（ParticleVisualController）传入逻辑 cell 后经 GridCoordinateRules.cell_to_world 唯一坐标入口换算写入；
##   并提供 begin_propagation_tween 创建绑定本节点的视觉传播 Tween（controller 据 authoritative timing 决定 duration 并登记/取消）。
##   本节点不实现 glow、trail（留后续）；FAST 与其它档位共用同一 24×16 主体，仅 Tween 时长更短。
## 位置：gameplay/visuals/particles 下；与 LightSegmentView 平行的独立光粒显示组件，由 ParticleVisualController 实例化并加入视觉父节点。
## 依赖：通过 preload 引用 GridCoordinateRules（cell→世界换算）；不引用 ParticleScheduler / ParticleRuntimeState / world query / Objective / controller。
## 不负责（硬边界）：cell 合法性校验、gameplay 状态、scheduler、Crystal 激活、RunState、Tick、drain、
##   维护 runtime_id→View 映射（由 controller）、速度档位玩法效果。
## 边界条件：主体逻辑尺寸 24×16（长 24px 沿传播方向 × 宽 16px）；本地默认朝 RIGHT（rotation=0）；
##   rotation = Vector2(direction).angle()——RIGHT(1,0)→0、DOWN(0,1)→π/2、LEFT(-1,0)→π、UP(0,-1)→-π/2，斜向为各象限角；
##   方向非法（如 ZERO）时 Vector2(direction).angle()==0，保持 RIGHT 朝向，不报错（与光粒方向始终合法八方向不冲突，仅视觉保守）。
##   本节点不持有 gameplay cell/speed truth——set_cell 只把 cell 经 cell_to_world 写入 position（视觉副本），不存 cell 成员；
##   外部改动 position/rotation 不反向影响 gameplay snapshot。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)


## 主体沿传播方向长度（本地 X 轴，默认朝 RIGHT）。冻结 24px（LightEmissionTypes.PARTICLE 注释：主体 24×16px）。
const BODY_LENGTH: int = 24
## 主体横向宽度（本地 Y 轴）。冻结 16px。
const BODY_WIDTH: int = 16


## 最近一段 Tween 的目标世界坐标（只读视觉副本；_tween_position_to 写入，get_tween_target_world 读取）。
var _last_tween_target_world: Vector2 = Vector2.ZERO


## 设置逻辑 cell：经 GridCoordinateRules.cell_to_world 唯一坐标入口换算为世界坐标写入 position（视觉副本）。
## [br]本方法不存 cell 成员（View 不拥有 gameplay cell truth），仅把换算结果写入 position。
## [br]副作用：写 self.position；不读 gameplay、不修改 cell。
func set_cell(cell: Vector2i) -> void:
	position = _GridCoordinateRules.cell_to_world(cell)


## 设置传播方向：rotation = Vector2(direction).angle()，RIGHT→0。
## [br]副作用：写 self.rotation；不读 gameplay。
func set_direction(direction: Vector2i) -> void:
	rotation = Vector2(direction).angle()


## 一次性配置逻辑 cell 与方向（精简统一入口；等价于 set_cell + set_direction）。
## [br]副作用：写 self.position 与 self.rotation。
func configure(cell: Vector2i, direction: Vector2i) -> void:
	set_cell(cell)
	set_direction(direction)


# ===== 视觉传播 Tween（D7-4 B4b-2） =====

## 启动一段从当前 position 到 target_cell 中心的视觉传播 Tween，返回绑定到本节点的 Tween（供控制器登记/取消）。
## [br]职责：纯视觉——把 target_cell 经 cell_to_world 换算为目标世界坐标，创建绑定本 Node2D 的 Tween 插值 self.position；
##   不读 gameplay、不决定 duration（duration_seconds 由控制器据 authoritative timing 换算后传入）、不持有 runtime_id/generation。
## [br]输入：target_cell 为视觉下一目标格（由控制器据 cell+direction 算出，纯视觉几何，非 gameplay truth）；
##   duration_seconds 为本段现实时长（== duration_ticks * ParticleTickTiming.TICK_SECONDS，由控制器算）。
## [br]返回：绑定本节点的 Tween（节点 queue_free 时自动失效）；duration_seconds<=0 时仍创建 Tween（即时到位，tween_property 零时长即 snap）。
## [br]副作用：创建 Tween 并写其插值目标到 self.position；不调 gameplay、不改 cell truth。
## [br]边界：本节点是否在场景树不影响 Tween 创建——在树时由 SceneTree 自动步进（正式视觉传播），脱树时不步进（单元测试仅 introspection）。
##   本节点不缓存 Tween 引用——所有权与取消由 ParticleVisualController 的 record（serial/token）统一管理；节点 free 时 Tween 自动失效。
func begin_propagation_tween(target_cell: Vector2i, duration_seconds: float) -> Tween:
	return _tween_position_to(_GridCoordinateRules.cell_to_world(target_cell), duration_seconds)


## 启动一段从当前 position 到 from_cell 与 from_cell+direction 两格边界中点的视觉 Tween（M4-E4 墙体边界消失）。
## [br]职责：纯视觉——目标为两格中心连线的中点（格边界面），供控制器在下一格为墙 / 越界时把传播插值截到边界，
##   使光粒在接触边界时即时消失、绝不插值到墙格中心；duration 由控制器按半步 authoritative timing 换算后传入。
## [br]边界：坐标换算仍唯一经 GridCoordinateRules.cell_to_world（本节点唯一坐标入口不变）；不读 gameplay、不判墙（墙信息由事件携带）。
func begin_boundary_tween(from_cell: Vector2i, direction: Vector2i, duration_seconds: float) -> Tween:
	var from_world: Vector2 = _GridCoordinateRules.cell_to_world(from_cell)
	var blocked_world: Vector2 = _GridCoordinateRules.cell_to_world(from_cell + direction)
	var boundary_world: Vector2 = (from_world + blocked_world) * 0.5
	return _tween_position_to(boundary_world, duration_seconds)


## 创建绑定本节点的 position 插值 Tween（上述两入口的共享实现；duration<=0 时即时到位）。
## 同时记录本段 Tween 目标世界坐标为只读视觉副本（get_tween_target_world 供测试 / 诊断；非 gameplay truth）。
func _tween_position_to(target_world: Vector2, duration_seconds: float) -> Tween:
	_last_tween_target_world = target_world
	var tween: Tween = create_tween()
	tween.tween_property(self, "position", target_world, maxf(duration_seconds, 0.0))
	return tween


## 最近一段 Tween 的目标世界坐标（只读视觉副本；供测试 / 诊断确认边界截断目标）。
func get_tween_target_world() -> Vector2:
	return _last_tween_target_world


## 主体逻辑尺寸（BODY_LENGTH × BODY_WIDTH）；只读，供测试与未来 visual 校准。
func get_body_size() -> Vector2:
	return Vector2(BODY_LENGTH, BODY_WIDTH)
