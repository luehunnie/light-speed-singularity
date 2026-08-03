extends SceneTree

## OBJ-C3 SingleCellMirror 真实对象生命周期与反射回归测试。
## 目标：证明 SingleCellMirror.tscn → PlaceableToken 新位置契约 → 放置/移动/回收 → 光线反射 全链路稳定。
## 三段覆盖：
##   A 场景实例：PackedScene 可实例化、脚本正确、orientation 默认值、position↔cell 契约一致、无独立 cell 后备字段、
##     无 Node.name 身份依赖、真实 configure 在新位置契约下工作（含 @onready 视觉）。
##   B 生命周期：用真实 PlacementController + 真实 OccupancyRegistry + 真实 SingleCellMirror 场景节点，
##     跑“创建→配置到目标 cell→登记占用→移动（旧占用释放/新占用登记）→回收→再次放置”，校验 position/cell/OccupancyRegistry。
##   C 反射：真实镜面对象在 SLASH、BACKSLASH 两种朝向下对多个入射方向返回正确反射；非法入射返回 ZERO；
##     并经真实 RayExecutionModule 光路验证“位置契约变化不改变光线路径与反射结果”。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 不修改任何生产代码；若测试暴露生产缺陷，停止并报告。

const _SingleCellMirrorScript: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.gd"
)
const _SingleCellMirrorScene: PackedScene = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _PlacementController: GDScript = preload(
	"res://gameplay/placement/placement_controller.gd"
)
const _OccupancyRegistry: GDScript = preload(
	"res://gameplay/placement/occupancy_registry.gd"
)
const _InventoryController: GDScript = preload(
	"res://gameplay/placement/inventory_controller.gd"
)
const _LevelWorldQuery: GDScript = preload(
	"res://gameplay/world/level_world_query.gd"
)
const _LevelObjectRegistry: GDScript = preload(
	"res://gameplay/level/level_object_registry.gd"
)
const _LightWorldQuery: GDScript = preload(
	"res://gameplay/world/light_world_query.gd"
)
const _RayExecutionModule: GDScript = preload(
	"res://gameplay/light/ray_execution_module.gd"
)
const _RayExecutionResult: GDScript = preload(
	"res://gameplay/light/ray_execution_result.gd"
)

const _TOKEN_TYPE: StringName = &"single_cell_mirror"
const _TOTAL: int = 4
const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 持有真实镜面工厂：RefCounted 在 Callable 单引用下会被提前回收（见 Callable 不保留 RefCounted 坑），故由本 SceneTree 成员常驻持有。
var _factory: _MirrorFactory = null


## SceneTree 初始化入口：首帧前 root 可能未就绪，等待一帧后再跑全部用例（见真实光路测试同款约定）。
func _initialize() -> void:
	await process_frame
	_test_A01_scene_instantiable_and_script()
	_test_A02_default_orientation_is_slash()
	_test_A03_scene_position_cell_contract()
	_test_A04_scene_no_independent_cell_field()
	_test_A05_no_node_name_identity_dependency()
	await _test_A06_real_configure_with_new_contract()
	await _test_B01_lifecycle_place_move_recycle_replace()
	await _test_B02_two_mirrors_same_name_distinguished_by_id()
	_test_C01_reflect_direction_slash()
	_test_C02_reflect_direction_backslash()
	_test_C03_invalid_incoming_returns_zero()
	_test_C04_light_path_invariant_under_position_contract()
	# 清理所有挂到 root 的真实镜面节点，泵帧让 queue_free 落地，再断言 root 无残留后报告。
	# 注意：清理的 await 必须留在本顶层协程，否则不 await 的协程会在 _report/quit 前被跳过。
	_free_created_tokens()
	await process_frame
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有残留子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 装配 =====

## 构造已注入真实 LevelWorldQuery 的 PlacementController；占用/库存为真实对象，工厂产出真实 SingleCellMirror 场景节点。
## 不复用夹具 make_controller：其工厂形参为 _StubFactory 强类型，真实镜面工厂类型不匹配；故在此直接装配同款接线。
func _make_controller(
		occ: _OccupancyRegistry,
		inv: _InventoryController
) -> _PlacementController:
	if _factory == null:
		_factory = _MirrorFactory.new()
		_factory.scene = _SingleCellMirrorScene
	_factory.tree = self
	var pc: _PlacementController = _PlacementController.new(occ, inv, Callable(_factory, "create"))
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var walls: Array[Vector2i] = []
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, Vector2i(-1, -1), registry, occ, Callable(pc, "get_placed_node")
	)
	pc.set_level_world_query(lwq)
	return pc


## 构造只读光线查询门面（10×10 边界、无墙、发射器格 (0,5)），供光路用例登记真实镜面后 execute。
func _new_light_world() -> Dictionary:
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var lookup: _PlacedLookup = _PlacedLookup.new()
	var walls: Array[Vector2i] = []
	var level_query: _LevelWorldQuery = _LevelWorldQuery.new(
		Rect2i(0, 0, 10, 10), walls, Vector2i(0, 5), registry, occ, Callable(lookup, "get_node")
	)
	var light_query: _LightWorldQuery = _LightWorldQuery.new(level_query)
	return { "query": light_query, "occupancy": occ, "lookup": lookup }


## 把一面真实镜面按指定定位方式放到 mirror_cell，登记占用并放入 placed 表，从 (0,5) 向右发射，返回结果。
## position_via_cell=true 用 set_cell（新位置契约的 setter），false 用直接写 position；两种方式 cell 都由 position 派生。
func _run_path(mirror_cell: Vector2i, orient: int, position_via_cell: bool) -> _RayExecutionResult:
	var world: Dictionary = _new_light_world()
	var mirror: Variant = _SingleCellMirrorScene.instantiate()
	if position_via_cell:
		mirror.set_cell(mirror_cell)
	else:
		mirror.position = _GridCoordinateRules.cell_to_world(mirror_cell)
	mirror.set_orientation(orient)
	var mid: StringName = &"mirror_path"
	# 占用格取自 mirror.cell（由 position 派生），证明镜面定位与光路命中都走同一 cell 事实。
	world["occupancy"].register_single_cell(mid, mirror.cell)
	world["lookup"].placed[mid] = mirror
	var result: _RayExecutionResult = _RayExecutionModule.execute(
		Vector2i(0, 5), Vector2i.RIGHT, 128, world["query"]
	)
	mirror.free()
	return result


# ===== A 场景实例 =====

## A01. PackedScene 可实例化、脚本正确、具备反射/朝向/方向事实接口。
func _test_A01_scene_instantiable_and_script() -> void:
	const NAME: String = "A01_场景可实例化且脚本正确"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	if _check(NAME, m != null, "SingleCellMirror.tscn 实例化失败。"):
		_check(NAME, m.get_script() == _SingleCellMirrorScript, "实例脚本应为 single_cell_mirror.gd。")
		_check(NAME, m.has_method("reflect_direction"), "实例应具备反射接口 reflect_direction。")
		_check(NAME, m.has_method("set_orientation"), "实例应具备朝向接口 set_orientation。")
		_check(NAME, "orientation" in m, "实例应具备 orientation 事实字段。")
		m.free()


## A02. 默认 orientation 为 SLASH（机关栏新拿出的镜面显示“/”）。
func _test_A02_default_orientation_is_slash() -> void:
	const NAME: String = "A02_默认orientation为SLASH"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	_check(NAME, m.orientation == _SingleCellMirrorScript.MirrorOrientation.SLASH, "默认 orientation 期望 SLASH(0)，实际 %s。" % [m.orientation])
	_check(NAME, m.orientation != _SingleCellMirrorScript.MirrorOrientation.BACKSLASH, "默认不应为 BACKSLASH。")
	m.free()


## A03. 场景实例的 position↔cell 契约一致：默认派生、set_cell 对齐格中心、改 position 后 cell 跟随、get_cell 同源。
func _test_A03_scene_position_cell_contract() -> void:
	const NAME: String = "A03_场景position与cell契约一致"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	_check(NAME, m.position == Vector2.ZERO, "默认 position 期望 (0,0)，实际 %s。" % [m.position])
	_check(NAME, m.cell == _GridCoordinateRules.world_to_cell(Vector2.ZERO), "默认 cell 期望 world_to_cell(0,0)，实际 %s。" % [m.cell])
	m.set_cell(Vector2i(3, 4))
	_check(NAME, m.position == _GridCoordinateRules.cell_to_world(Vector2i(3, 4)), "set_cell(3,4) 后 position 期望格中心，实际 %s。" % [m.position])
	_check(NAME, m.cell == Vector2i(3, 4), "set_cell 后 cell 期望 (3,4)，实际 %s。" % [m.cell])
	m.position = _GridCoordinateRules.cell_to_world(Vector2i(6, 2))
	_check(NAME, m.cell == Vector2i(6, 2), "改 position 后 cell 期望 (6,2)，实际 %s。" % [m.cell])
	_check(NAME, m.get_cell() == m.cell, "get_cell 应与 .cell 同源。")
	m.free()


## A04. 场景实例无独立 cell 后备字段：set_cell(A) 后只改 position 到 B，cell 必须跟随 B（与契约测试同源证明，针对真实场景）。
func _test_A04_scene_no_independent_cell_field() -> void:
	const NAME: String = "A04_场景无独立cell后备字段"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	m.set_cell(Vector2i(8, 8))
	_check(NAME, m.cell == Vector2i(8, 8), "set_cell(8,8) 后 cell 期望 (8,8)，实际 %s。" % [m.cell])
	m.position = _GridCoordinateRules.cell_to_world(Vector2i(1, 1))
	_check(NAME, m.cell == Vector2i(1, 1), "改 position 后 cell 应跟随 (1,1)，实际 %s，存在独立漂移后备。" % [m.cell])
	m.free()


## A05. 无 Node.name 身份依赖：改 Node.name 不影响 cell/position/orientation/反射任何事实。
func _test_A05_no_node_name_identity_dependency() -> void:
	const NAME: String = "A05_无Node.name身份依赖"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	m.set_cell(Vector2i(3, 4))
	m.set_orientation(_SingleCellMirrorScript.MirrorOrientation.BACKSLASH)
	var cell_before: Vector2i = m.cell
	var orient_before: int = m.orientation
	var reflect_before: Vector2i = m.reflect_direction(Vector2i.RIGHT)
	m.name = "ArbitraryRenamedNode_123"
	_check(NAME, m.cell == cell_before, "改名后 cell 不应变，实际 %s。" % [m.cell])
	_check(NAME, m.position == _GridCoordinateRules.cell_to_world(Vector2i(3, 4)), "改名后 position 不应变。")
	_check(NAME, m.orientation == orient_before, "改名后 orientation 不应变，实际 %s。" % [m.orientation])
	_check(NAME, m.reflect_direction(Vector2i.RIGHT) == reflect_before, "改名后反射方向不应变。")
	m.free()


## A06. 真实 configure 在新位置契约下工作：入树 + 泵帧触发 _ready 后调用 configure，校验 mechanism_id/cell/position/orientation。
## configure 末尾的 set_drag_preview 依赖 @onready _visual_view，必须先入树并泵帧；工厂同步调用内无法满足，故在此单独验证。
func _test_A06_real_configure_with_new_contract() -> void:
	const NAME: String = "A06_真实configure在新契约下工作"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	root.add_child(m as Node)
	await process_frame
	m.configure(&"mirror_configure_test", Vector2i(5, 7))
	_check(NAME, m.mechanism_id == &"mirror_configure_test", "configure 后 mechanism_id 期望写入，实际 %s。" % [m.mechanism_id])
	_check(NAME, m.cell == Vector2i(5, 7), "configure 后 cell 期望 (5,7)，实际 %s。" % [m.cell])
	_check(NAME, m.position == _GridCoordinateRules.cell_to_world(Vector2i(5, 7)), "configure 后 position 应对齐 (5,7) 格中心，实际 %s。" % [m.position])
	_check(NAME, m.get_cell() == Vector2i(5, 7), "configure 后 get_cell 期望 (5,7)。")
	_check(NAME, m.orientation == _SingleCellMirrorScript.MirrorOrientation.SLASH, "configure 不应改 orientation，期望仍为 SLASH。")
	(m as Node).free()
	await process_frame


# ===== B 生命周期 =====

## B01. 完整生命周期：放置→（cell/position/占用/库存）→移动（旧占用释放/新占用登记/position 更新）→回收（占用注销/映射删除/库存归还/节点销毁）→再次放置（新 ID/重登记/再扣库存）。
## 全程真实 PlacementController + 真实 OccupancyRegistry + 真实 SingleCellMirror 场景节点，不通过 mock 绕过。
func _test_B01_lifecycle_place_move_recycle_replace() -> void:
	const NAME: String = "B01_生命周期_放置移动回收再放置"
	const ORIENT: int = _SingleCellMirrorScript.MirrorOrientation.BACKSLASH
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv)

	# 创建镜子 + 配置到目标 cell + 登记占用：经真实 place_from_inventory 事务。
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 3), ORIENT)
	_check(NAME, placed.is_success(), "放置期望 SUCCESS，实际 %s（%s）。" % [placed.status, placed.error_message])
	_check(NAME, placed.mechanism_id != &"", "应分配非空 mechanism_id。")
	var mid: StringName = placed.mechanism_id
	var node: Variant = pc.get_placed_node(mid)
	_check(NAME, is_instance_valid(node), "应取得有效正式节点。")
	_check(NAME, node.cell == Vector2i(2, 3), "放置后节点 cell 期望 (2,3)，实际 %s。" % [node.cell])
	_check(NAME, node.position == _GridCoordinateRules.cell_to_world(Vector2i(2, 3)), "放置后 position 期望 (2,3) 格中心，实际 %s。" % [node.position])
	_check(NAME, node.orientation == ORIENT, "放置后 orientation 期望 BACKSLASH，实际 %s。" % [node.orientation])
	_check(NAME, occ.has_mechanism(mid), "占用表应登记该机关。")
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 3)) == mid, "(2,3) 应指向该机关。")
	_check(NAME, pc.get_placed_count() == 1, "已放置数期望 1。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存剩余期望 %d，实际 %d。" % [_TOTAL - 1, inv.get_remaining()])

	# 移动到新 cell：旧占用释放、新占用登记、节点 position/cell 更新、orientation 保持。
	var moved := pc.move_placed(mid, Vector2i(6, 9))
	_check(NAME, moved.is_success(), "移动期望 SUCCESS，实际 %s（%s）。" % [moved.status, moved.error_message])
	_check(NAME, moved.consumes_runtime_move == true, "跨格移动应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 3)) == &"", "旧占用 (2,3) 应已释放。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 9)) == mid, "新占用 (6,9) 应已登记。")
	_check(NAME, node.cell == Vector2i(6, 9), "移动后节点 cell 期望 (6,9)，实际 %s。" % [node.cell])
	_check(NAME, node.position == _GridCoordinateRules.cell_to_world(Vector2i(6, 9)), "移动后 position 期望 (6,9) 格中心，实际 %s。" % [node.position])
	_check(NAME, node.orientation == ORIENT, "移动不应改 orientation，期望 BACKSLASH。")
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")

	# 回收：占用注销、映射删除、库存归还、节点销毁。
	var recycled := pc.recycle_placed(mid)
	_check(NAME, recycled.is_success(), "回收期望 SUCCESS，实际 %s（%s）。" % [recycled.status, recycled.error_message])
	_check(NAME, not occ.has_mechanism(mid), "回收后占用应注销。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 9)) == &"", "回收后 (6,9) 应无机关。")
	_check(NAME, not pc.has_placed(mid), "回收后映射应删除。")
	_check(NAME, pc.get_placed_count() == 0, "回收后已放置数期望 0。")
	_check(NAME, inv.get_remaining() == _TOTAL, "回收后库存应归还满，实际 %d。" % [inv.get_remaining()])
	await process_frame
	_check(NAME, not is_instance_valid(node), "回收后正式节点应已销毁。")

	# 再次放置：新 ID（不复用旧 ID）、占用重登记、库存再扣。
	var replaced := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(4, 5), _SingleCellMirrorScript.MirrorOrientation.SLASH)
	_check(NAME, replaced.is_success(), "再次放置期望 SUCCESS，实际 %s（%s）。" % [replaced.status, replaced.error_message])
	_check(NAME, replaced.mechanism_id != mid, "再次放置应分配新 ID，不复用旧 ID。")
	_check(NAME, occ.get_mechanism_at(Vector2i(4, 5)) == replaced.mechanism_id, "(4,5) 应指向新机关。")
	var node2: Variant = pc.get_placed_node(replaced.mechanism_id)
	_check(NAME, node2.cell == Vector2i(4, 5), "再次放置节点 cell 期望 (4,5)，实际 %s。" % [node2.cell])
	_check(NAME, node2.orientation == _SingleCellMirrorScript.MirrorOrientation.SLASH, "再次放置 orientation 期望 SLASH。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "再次放置后库存剩余期望 %d。" % [_TOTAL - 1])


## B02. 两面真实镜面：Godot 强制兄弟节点名唯一（自动改名），PlacementController 仍按 mechanism_id 而非 Node.name 区分、取回与回收。
func _test_B02_two_mirrors_same_name_distinguished_by_id() -> void:
	const NAME: String = "B02_按mechanism_id而非Node.name区分"
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv)
	var pa := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(1, 1), _SingleCellMirrorScript.MirrorOrientation.SLASH)
	var pb := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 2), _SingleCellMirrorScript.MirrorOrientation.BACKSLASH)
	_check(NAME, pa.is_success() and pb.is_success(), "两面镜子应都放置成功。")
	var na: Variant = pc.get_placed_node(pa.mechanism_id)
	var nb: Variant = pc.get_placed_node(pb.mechanism_id)
	_check(NAME, pa.mechanism_id != pb.mechanism_id, "两面镜子应分配不同 mechanism_id。")
	# Godot 自动令兄弟节点名唯一（第二个被改名为 @...@N 之类），节点名本就不可作为身份。
	_check(NAME, (na as Node).name != (nb as Node).name, "Godot 应令两面镜子兄弟名不同，实际 %s vs %s。" % [(na as Node).name, (nb as Node).name])
	_check(NAME, na.cell == Vector2i(1, 1) and nb.cell == Vector2i(2, 2), "按 ID 取回的节点应各自落在自己的格。")
	_check(NAME, na.orientation != nb.orientation, "两面镜子朝向应不同。")
	# 按 mechanism_id 精确取回：与节点 name 无关。
	_check(NAME, pc.get_placed_node(pa.mechanism_id) == na, "按 A 的 ID 应取回 A 节点。")
	_check(NAME, pc.get_placed_node(pb.mechanism_id) == nb, "按 B 的 ID 应取回 B 节点。")
	# 改名后仍按同一 ID 取回同一节点，证明 name 不参与身份解析。
	(na as Node).name = &"RenamedA_456"
	_check(NAME, pc.get_placed_node(pa.mechanism_id) == na, "改名后按 A 的 ID 仍应取回 A 节点。")
	# 只回收 A：B 不受影响，证明按 ID 而非 name 操作。
	var ra := pc.recycle_placed(pa.mechanism_id)
	_check(NAME, ra.is_success(), "回收 A 应成功。")
	_check(NAME, not pc.has_placed(pa.mechanism_id) and pc.has_placed(pb.mechanism_id), "回收 A 后只剩 B。")
	_check(NAME, is_instance_valid(nb), "回收 A 不应影响 B 节点。")
	_check(NAME, nb.cell == Vector2i(2, 2), "B 仍应在 (2,2)。")


# ===== C 反射 =====

## C01. SLASH 反射：(x,y)->(-y,-x)。RIGHT→UP、UP→RIGHT、LEFT→DOWN、DOWN→LEFT、DOWN_RIGHT→UP_LEFT。
func _test_C01_reflect_direction_slash() -> void:
	const NAME: String = "C01_SLASH反射方向"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	m.set_orientation(_SingleCellMirrorScript.MirrorOrientation.SLASH)
	_check(NAME, m.reflect_direction(Vector2i.RIGHT) == Vector2i.UP, "RIGHT 期望 UP，实际 %s。" % [m.reflect_direction(Vector2i.RIGHT)])
	_check(NAME, m.reflect_direction(Vector2i.UP) == Vector2i.RIGHT, "UP 期望 RIGHT，实际 %s。" % [m.reflect_direction(Vector2i.UP)])
	_check(NAME, m.reflect_direction(Vector2i.LEFT) == Vector2i.DOWN, "LEFT 期望 DOWN，实际 %s。" % [m.reflect_direction(Vector2i.LEFT)])
	_check(NAME, m.reflect_direction(Vector2i.DOWN) == Vector2i.LEFT, "DOWN 期望 LEFT，实际 %s。" % [m.reflect_direction(Vector2i.DOWN)])
	# DOWN_RIGHT(1,1)→UP_LEFT(-1,-1)：Vector2i 无对角线常量，用字面量。
	_check(NAME, m.reflect_direction(Vector2i(1, 1)) == Vector2i(-1, -1), "DOWN_RIGHT 期望 UP_LEFT，实际 %s。" % [m.reflect_direction(Vector2i(1, 1))])
	m.free()


## C02. BACKSLASH 反射：(x,y)->(y,x)。RIGHT→DOWN、DOWN→RIGHT、LEFT→UP、UP→LEFT。
func _test_C02_reflect_direction_backslash() -> void:
	const NAME: String = "C02_BACKSLASH反射方向"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	m.set_orientation(_SingleCellMirrorScript.MirrorOrientation.BACKSLASH)
	_check(NAME, m.reflect_direction(Vector2i.RIGHT) == Vector2i.DOWN, "RIGHT 期望 DOWN，实际 %s。" % [m.reflect_direction(Vector2i.RIGHT)])
	_check(NAME, m.reflect_direction(Vector2i.DOWN) == Vector2i.RIGHT, "DOWN 期望 RIGHT，实际 %s。" % [m.reflect_direction(Vector2i.DOWN)])
	_check(NAME, m.reflect_direction(Vector2i.LEFT) == Vector2i.UP, "LEFT 期望 UP，实际 %s。" % [m.reflect_direction(Vector2i.LEFT)])
	_check(NAME, m.reflect_direction(Vector2i.UP) == Vector2i.LEFT, "UP 期望 LEFT，实际 %s。" % [m.reflect_direction(Vector2i.UP)])
	m.free()


## C03. 非法入射返回 ZERO；合法入射在两种朝向下都不返回 ZERO。
func _test_C03_invalid_incoming_returns_zero() -> void:
	const NAME: String = "C03_非法入射返回ZERO"
	var m: Variant = _SingleCellMirrorScene.instantiate()
	_check(NAME, m.reflect_direction(Vector2i.ZERO) == Vector2i.ZERO, "ZERO 入射应返回 ZERO。")
	_check(NAME, m.reflect_direction(Vector2i(2, 0)) == Vector2i.ZERO, "分量超 1 的 (2,0) 应返回 ZERO。")
	_check(NAME, m.reflect_direction(Vector2i(0, -3)) == Vector2i.ZERO, "分量超 1 的 (0,-3) 应返回 ZERO。")
	m.set_orientation(_SingleCellMirrorScript.MirrorOrientation.SLASH)
	_check(NAME, m.reflect_direction(Vector2i.RIGHT) != Vector2i.ZERO, "SLASH 合法入射不应返回 ZERO。")
	m.set_orientation(_SingleCellMirrorScript.MirrorOrientation.BACKSLASH)
	_check(NAME, m.reflect_direction(Vector2i.RIGHT) != Vector2i.ZERO, "BACKSLASH 合法入射不应返回 ZERO。")
	m.free()


## C04. 位置契约不改变光路与反射：真实镜面经新位置契约定位后，SLASH 转 UP、BACKSLASH 转 DOWN；
## 且 set_cell 与直接写 position 两种定位方式逐格光路完全相同，证明 cell 由 position 派生不改变光线结果。
func _test_C04_light_path_invariant_under_position_contract() -> void:
	const NAME: String = "C04_位置契约不改变光路与反射"
	const MIRROR_CELL: Vector2i = Vector2i(3, 5)
	# SLASH（经 set_cell 定位）：RIGHT 命中 (3,5) 后转 UP，转向后首步 (3,4)。
	var slash := _run_path(MIRROR_CELL, _SingleCellMirrorScript.MirrorOrientation.SLASH, true)
	_check(NAME, slash.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "SLASH 期望 OUT_OF_BOUNDS，实际 %s。" % [slash.stop_reason])
	if _check(NAME, slash.steps.size() >= 4, "SLASH 路径步数足以检验镜面格与转向。"):
		_check(NAME, slash.steps[2].cell == MIRROR_CELL, "SLASH 镜面格期望 (3,5)，实际 %s。" % [slash.steps[2].cell])
		_check(NAME, slash.steps[2].incoming_direction == Vector2i.RIGHT, "SLASH 镜面入射期望 RIGHT。")
		_check(NAME, slash.steps[3].cell == Vector2i(3, 4), "SLASH 转向后首步期望 (3,4) 向上，实际 %s。" % [slash.steps[3].cell])
		_check(NAME, slash.steps[3].incoming_direction == Vector2i.UP, "SLASH 转向后方向期望 UP。")
	# BACKSLASH（经 set_cell 定位）：RIGHT 命中 (3,5) 后转 DOWN，转向后首步 (3,6)。
	var back := _run_path(MIRROR_CELL, _SingleCellMirrorScript.MirrorOrientation.BACKSLASH, true)
	_check(NAME, back.stop_reason == _RayExecutionResult.StopReason.OUT_OF_BOUNDS, "BACKSLASH 期望 OUT_OF_BOUNDS，实际 %s。" % [back.stop_reason])
	if _check(NAME, back.steps.size() >= 4, "BACKSLASH 路径步数足以检验转向。"):
		_check(NAME, back.steps[3].cell == Vector2i(3, 6), "BACKSLASH 转向后首步期望 (3,6) 向下，实际 %s。" % [back.steps[3].cell])
		_check(NAME, back.steps[3].incoming_direction == Vector2i.DOWN, "BACKSLASH 转向后方向期望 DOWN。")
	# 位置契约不变性：set_cell 与直接写 position 两种定位方式，逐格光路完全一致。
	var via_cell := _run_path(MIRROR_CELL, _SingleCellMirrorScript.MirrorOrientation.SLASH, true)
	var via_pos := _run_path(MIRROR_CELL, _SingleCellMirrorScript.MirrorOrientation.SLASH, false)
	_check(NAME, via_cell.stop_reason == via_pos.stop_reason, "两种定位方式停止原因应一致。")
	_check(NAME, via_cell.steps.size() == via_pos.steps.size(), "两种定位方式步数应一致，%d vs %d。" % [via_cell.steps.size(), via_pos.steps.size()])
	var path_same: bool = true
	for i: int in range(via_cell.steps.size()):
		if i >= via_pos.steps.size() or via_cell.steps[i].cell != via_pos.steps[i].cell:
			path_same = false
			break
	_check(NAME, path_same, "两种定位方式逐格路径应完全相同，证明位置契约变化不改变光路。")


# ===== 内部类 =====

## 真实 SingleCellMirror 节点工厂：满足 PlacementController 的 Callable(mechanism_id, cell, orientation)->Variant 契约。
## 直接写 mechanism_id + set_cell + set_orientation（configure 的全部非视觉事实）；不调用 configure：
## configure 末尾 set_drag_preview 依赖 @onready _visual_view，而工厂在控制器事务内同步调用、无法泵帧触发 _ready。
## 视觉显示模式由 A06 单独验证；此处 position/cell/orientation/Node 身份均走真实 PlaceableToken/SingleCellMirror 代码路径。
class _MirrorFactory extends RefCounted:
	var scene: PackedScene = null
	var tree: SceneTree = null
	var created_tokens: Array[Node] = []

	func create(mechanism_id: StringName, cell: Vector2i, orientation: Variant) -> Variant:
		var mirror: Variant = scene.instantiate()
		mirror.mechanism_id = mechanism_id
		mirror.set_cell(cell)
		if orientation != null:
			mirror.set_orientation(orientation)
		if tree != null and tree.root != null:
			tree.root.add_child(mirror as Node)
		created_tokens.append(mirror as Node)
		return mirror


## 机关节点只读查表桩：供 LevelWorldQuery 的 get_placed_node_by_id Callable 解析 placed 字典，不暴露可写引用（与 RayExecution 测试同款）。
class _PlacedLookup extends RefCounted:
	var placed: Dictionary = {}

	func get_node(mechanism_id: StringName) -> Variant:
		return placed.get(mechanism_id, null)


# ===== 断言、清理与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表；返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 清理工厂创建并挂到 root 的真实镜面节点：对仍有效者 queue_free，交由调用方后续泵帧落地。
## 用提前返回守卫 _factory 为空，避免在 _initialize 顶层再叠一层 if 嵌套（清理段嵌套 ≤3）。
func _free_created_tokens() -> void:
	if _factory == null:
		return
	for node: Node in _factory.created_tokens:
		if is_instance_valid(node):
			node.queue_free()


## 输出测试摘要：测试组数、断言数、通过/失败与全部失败明细。
func _report() -> void:
	var group_count: int = 12
	var passed_checks: int = _checks - _failures.size()
	print("==== SingleCellMirror 生命周期与反射回归测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
