extends SceneTree

## OBJ-C3 DoubleCellMirror 判定逻辑与生命周期回归测试。
## 目标：证明 double_cell_mirror.gd 的判定纯函数 resolve_interaction 覆盖规则文档 §8 四朝向 × 12 条全部映射，
##   脚本具备正式光交互契约面（interact_ray/interact_particle）与多格 footprint（get_occupied_offsets），
##   并经真实 PlacementController + 真实 .tscn 场景节点跑通"放置→移动→回收"多格占用生命周期。
## 三段覆盖：
##   A 脚本接口：可实例化、默认朝向 RIGHT、四朝向 footprint、RAY+PARTICLE 形态声明。
##   B 生命周期：真实 PlacementController + 真实 OccupancyRegistry + 真实 DoubleCellMirror 场景节点，
##     放置（2 格占用）→ 移动（旧 2 格释放/新 2 格登记）→ 回收（2 格注销/节点销毁/库存归还）。
##   C 判定：48 条速查表（resolve_interaction 静态纯函数，数据驱动断言）。
## 判定依据：规则文档 v0.6 §8 四朝向速查表。resolve_interaction(orientation, cell_offset, incoming_direction) 返回 Resolution：
##   CONTINUE（端点穿越/平行）、BLOCK（正交折回/背面、斜向背面中心点）、REDIRECT_CROSS（斜向正面中心点，含反射/穿邻方向）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。不修改任何生产代码。

const _DoubleCellMirror: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/double_cell_mirror.gd"
)
const _DoubleCellMirrorScene: PackedScene = preload(
	"res://gameplay/mechanisms/mirrors/double_cell_mirror.tscn"
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

# 判定结果枚举（int 值，供数据驱动断言比较）。
const OUT_CONTINUE: int = _DoubleCellMirror.Resolution.Outcome.CONTINUE
const OUT_BLOCK: int = _DoubleCellMirror.Resolution.Outcome.BLOCK
const OUT_CROSS: int = _DoubleCellMirror.Resolution.Outcome.REDIRECT_CROSS

const _TOKEN_TYPE: StringName = &"double_cell_mirror"
const _TOTAL: int = 4
const _MAP_BOUNDS: Rect2i = Rect2i(0, 0, 16, 16)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
# 持有真实双格镜工厂：RefCounted 在 Callable 单引用下会被提前回收，故由本 SceneTree 成员常驻持有。
var _factory = null


## SceneTree 初始化入口：等待一帧后跑全部用例，末尾清理挂到 root 的节点并报告。
func _initialize() -> void:
	await process_frame
	_test_A01_script_loadable_and_interface()
	_test_A02_default_orientation_right()
	_test_A03_get_occupied_offsets_four_orientations()
	_test_A04_get_light_interaction_forms()
	_test_B01_lifecycle_place_move_recycle()
	_test_C01_quicktable_48_cases()
	_free_created_tokens()
	await process_frame
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有残留子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 装配 =====

## 构造已注入真实 LevelWorldQuery 的 PlacementController；占用/库存为真实对象，工厂产出真实 DoubleCellMirror 场景节点。
func _make_controller(
		occ: _OccupancyRegistry,
		inv: _InventoryController
) -> _PlacementController:
	if _factory == null:
		_factory = _DoubleMirrorFactory.new()
		_factory.scene = _DoubleCellMirrorScene
	_factory.tree = self
	var pc: _PlacementController = _PlacementController.new(occ, inv, Callable(_factory, "create"))
	var registry: _LevelObjectRegistry = _LevelObjectRegistry.new()
	var walls: Array[Vector2i] = []
	var lwq: _LevelWorldQuery = _LevelWorldQuery.new(
		_MAP_BOUNDS, walls, Vector2i(-1, -1), registry, occ, Callable(pc, "get_placed_node")
	)
	pc.set_level_world_query(lwq)
	return pc


# ===== A 脚本与接口 =====

## A01. 脚本可实例化、具备正式交互契约面与多格 footprint 接口。
func _test_A01_script_loadable_and_interface() -> void:
	const NAME: String = "A01_脚本可实例化且接口完整"
	var m: Variant = _DoubleCellMirror.new()
	if _check(NAME, m != null, "double_cell_mirror.gd 实例化失败。"):
		_check(NAME, m is PlaceableToken, "应继承 PlaceableToken。")
		_check(NAME, m.has_method("interact_ray"), "应具备 RAY 交互入口 interact_ray。")
		_check(NAME, m.has_method("interact_particle"), "应具备 PARTICLE 交互入口 interact_particle。")
		_check(NAME, m.has_method("get_occupied_offsets"), "应具备多格 footprint 入口 get_occupied_offsets。")
		_check(NAME, m.has_method("set_orientation"), "应具备朝向接口 set_orientation。")
		_check(NAME, m.has_method("toggle_orientation"), "应具备旋转接口 toggle_orientation。")
		_check(NAME, m.has_method("apply_configuration"), "应具备 Typed 配置接口 apply_configuration。")
		_check(NAME, m.has_method("get_light_interaction_forms"), "应具备形态声明入口 get_light_interaction_forms。")
		_check(NAME, "orientation" in m, "应具备 orientation 事实字段。")
		m.free()


## A02. 默认朝向为 RIGHT（2026-09-03 由 BOTTOM 改，对齐规则文档 §2/§6/§7）。
func _test_A02_default_orientation_right() -> void:
	const NAME: String = "A02_默认朝向为RIGHT"
	var m: Variant = _DoubleCellMirror.new()
	_check(NAME, m.orientation == _DoubleCellMirror.MirrorOrientation.RIGHT, "默认 orientation 期望 RIGHT(1)，实际 %s。" % [m.orientation])
	_check(NAME, m.orientation != _DoubleCellMirror.MirrorOrientation.BOTTOM, "默认不应为 BOTTOM。")
	m.free()


## A03. get_occupied_offsets 随朝向返回正确两格偏移（anchor 恒为自身 cell，读自身 orientation）。
func _test_A03_get_occupied_offsets_four_orientations() -> void:
	const NAME: String = "A03_get_occupied_offsets四朝向"
	var m: Variant = _DoubleCellMirror.new()
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.BOTTOM)
	_check(NAME, m.get_occupied_offsets() == [Vector2i.ZERO, Vector2i(1, 0)], "BOTTOM 期望 [ZERO,(1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.RIGHT)
	_check(NAME, m.get_occupied_offsets() == [Vector2i.ZERO, Vector2i(0, 1)], "RIGHT 期望 [ZERO,(0,1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.TOP)
	_check(NAME, m.get_occupied_offsets() == [Vector2i(-1, 0), Vector2i.ZERO], "TOP 期望 [(-1,0),ZERO]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.LEFT)
	_check(NAME, m.get_occupied_offsets() == [Vector2i(0, -1), Vector2i.ZERO], "LEFT 期望 [(0,-1),ZERO]，实际 %s。" % [m.get_occupied_offsets()])
	m.free()


## A04. 声明 RAY + PARTICLE 两形态（对齐单格镜）。
func _test_A04_get_light_interaction_forms() -> void:
	const NAME: String = "A04_声明RAY与PARTICLE"
	var m: Variant = _DoubleCellMirror.new()
	var forms: Array = m.get_light_interaction_forms()
	_check(NAME, &"RAY" in forms and &"PARTICLE" in forms, "应声明 RAY 与 PARTICLE，实际 %s。" % [forms])
	m.free()


# ===== B 生命周期 =====

## B01. 完整生命周期：放置（2 格占用）→ 移动（旧 2 格释放/新 2 格登记）→ 回收（2 格注销/节点销毁/库存归还）。
## 全程真实 PlacementController + 真实 OccupancyRegistry + 真实 DoubleCellMirror 场景节点，覆盖多格 footprint。
func _test_B01_lifecycle_place_move_recycle() -> void:
	const NAME: String = "B01_生命周期_放置移动回收"
	const ORIENT: int = _DoubleCellMirror.MirrorOrientation.RIGHT
	var occ: _OccupancyRegistry = _OccupancyRegistry.new()
	var inv: _InventoryController = _InventoryController.new(_TOTAL)
	var pc: _PlacementController = _make_controller(occ, inv)

	# 放置 RIGHT 在 (2,3)：占用 anchor (2,3) + second (2,4)。
	var placed := pc.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 3), ORIENT)
	_check(NAME, placed.is_success(), "放置期望 SUCCESS，实际 %s（%s）。" % [placed.status, placed.error_message])
	_check(NAME, placed.mechanism_id != &"", "应分配非空 mechanism_id。")
	var mid: StringName = placed.mechanism_id
	var node: Variant = pc.get_placed_node(mid)
	_check(NAME, is_instance_valid(node), "应取得有效正式节点。")
	_check(NAME, node.cell == Vector2i(2, 3), "放置后 anchor cell 期望 (2,3)，实际 %s。" % [node.cell])
	_check(NAME, node.orientation == ORIENT, "放置后 orientation 期望 RIGHT，实际 %s。" % [node.orientation])
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 3)) == mid, "anchor 格 (2,3) 应登记该机关。")
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 4)) == mid, "second 格 (2,4) 应登记该机关（RIGHT 向下延伸）。")
	_check(NAME, occ.get_cells_of(mid).size() == 2, "应占用 2 格，实际 %d。" % [occ.get_cells_of(mid).size()])
	_check(NAME, pc.get_placed_count() == 1, "已放置数期望 1。")
	_check(NAME, inv.get_remaining() == _TOTAL - 1, "库存剩余期望 %d，实际 %d。" % [_TOTAL - 1, inv.get_remaining()])

	# 移动到 (6,9)：旧 2 格释放，新 2 格登记，orientation 保持。
	var moved := pc.move_placed(mid, Vector2i(6, 9))
	_check(NAME, moved.is_success(), "移动期望 SUCCESS，实际 %s（%s）。" % [moved.status, moved.error_message])
	_check(NAME, moved.consumes_runtime_move == true, "跨格移动应消耗运行期移动次数。")
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 3)) == &"", "旧 anchor (2,3) 应释放。")
	_check(NAME, occ.get_mechanism_at(Vector2i(2, 4)) == &"", "旧 second (2,4) 应释放。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 9)) == mid, "新 anchor (6,9) 应登记。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 10)) == mid, "新 second (6,10) 应登记（RIGHT 向下延伸）。")
	_check(NAME, node.cell == Vector2i(6, 9), "移动后 anchor cell 期望 (6,9)，实际 %s。" % [node.cell])
	_check(NAME, node.orientation == ORIENT, "移动不应改 orientation，期望 RIGHT。")
	_check(NAME, occ.is_consistent(), "占用表应保持一致。")

	# 回收：2 格注销，节点销毁，库存归还。
	var recycled := pc.recycle_placed(mid)
	_check(NAME, recycled.is_success(), "回收期望 SUCCESS，实际 %s（%s）。" % [recycled.status, recycled.error_message])
	_check(NAME, not occ.has_mechanism(mid), "回收后占用应注销。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 9)) == &"", "回收后 (6,9) 应无机关。")
	_check(NAME, occ.get_mechanism_at(Vector2i(6, 10)) == &"", "回收后 (6,10) 应无机关。")
	_check(NAME, pc.get_placed_count() == 0, "回收后已放置数期望 0。")
	_check(NAME, inv.get_remaining() == _TOTAL, "回收后库存应归还满，实际 %d。" % [inv.get_remaining()])
	await process_frame
	_check(NAME, not is_instance_valid(node), "回收后正式节点应已销毁。")


# ===== C 判定（48 条速查表） =====

## C01. 规则文档 §8 四朝向 × 12 条速查表全部映射正确。
## 数据驱动：每例 [朝向, 入格偏移(相对 anchor), 入射方向, 期望 outcome, 期望反射方向, 期望穿邻方向]。
func _test_C01_quicktable_48_cases() -> void:
	const NAME: String = "C01_四朝向48条速查表"
	var cases: Array = []

	# ---- BOTTOM（anchor=(x,y), second=(x+1,y), tangent=(1,0), normal=(0,-1)） ----
	var b: int = _DoubleCellMirror.MirrorOrientation.BOTTOM
	var b_second: Vector2i = Vector2i(1, 0)
	cases.append([b, Vector2i.ZERO, Vector2i(0, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # B1 折回
	cases.append([b, Vector2i.ZERO, Vector2i(0, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # B2 背面
	cases.append([b, Vector2i.ZERO, Vector2i(1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # B3 平行
	cases.append([b, Vector2i.ZERO, Vector2i(-1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B4 平行
	cases.append([b, Vector2i.ZERO, Vector2i(1, 1), OUT_CROSS, Vector2i(1, -1), Vector2i(1, 0)])    # B5 中心反射↗
	cases.append([b, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B6 左端点
	cases.append([b, b_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # B7 右端点
	cases.append([b, b_second, Vector2i(-1, 1), OUT_CROSS, Vector2i(-1, -1), Vector2i(-1, 0)])      # B8 中心反射↖
	cases.append([b, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B9 左端点
	cases.append([b, Vector2i.ZERO, Vector2i(-1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])     # B10 背面
	cases.append([b, b_second, Vector2i(1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # B11 背面
	cases.append([b, b_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # B12 右端点

	# ---- RIGHT（anchor=(x,y), second=(x,y+1), tangent=(0,1), normal=(-1,0)） ----
	var r: int = _DoubleCellMirror.MirrorOrientation.RIGHT
	var r_second: Vector2i = Vector2i(0, 1)
	cases.append([r, Vector2i.ZERO, Vector2i(1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # R1 折回
	cases.append([r, Vector2i.ZERO, Vector2i(-1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # R2 背面
	cases.append([r, Vector2i.ZERO, Vector2i(0, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R3 平行
	cases.append([r, Vector2i.ZERO, Vector2i(0, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # R4 平行
	cases.append([r, Vector2i.ZERO, Vector2i(1, 1), OUT_CROSS, Vector2i(-1, 1), Vector2i(0, 1)])    # R5 中心反射↙
	cases.append([r, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R6 上端点
	cases.append([r, r_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # R7 下端点
	cases.append([r, r_second, Vector2i(1, -1), OUT_CROSS, Vector2i(-1, -1), Vector2i(0, -1)])      # R8 中心反射↖
	cases.append([r, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R9 上端点
	cases.append([r, Vector2i.ZERO, Vector2i(-1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])     # R10 背面
	cases.append([r, r_second, Vector2i(-1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # R11 背面
	cases.append([r, r_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # R12 下端点

	# ---- TOP（anchor=(x,y), second=(x-1,y), tangent=(-1,0), normal=(0,1)） ----
	var t: int = _DoubleCellMirror.MirrorOrientation.TOP
	var t_second: Vector2i = Vector2i(-1, 0)
	cases.append([t, Vector2i.ZERO, Vector2i(0, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # T1 折回
	cases.append([t, Vector2i.ZERO, Vector2i(0, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # T2 背面
	cases.append([t, Vector2i.ZERO, Vector2i(1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # T3 平行
	cases.append([t, Vector2i.ZERO, Vector2i(-1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T4 平行
	cases.append([t, t_second, Vector2i(1, -1), OUT_CROSS, Vector2i(1, 1), Vector2i(1, 0)])         # T5 中心反射↘
	cases.append([t, t_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # T6 左端点
	cases.append([t, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T7 右端点
	cases.append([t, Vector2i.ZERO, Vector2i(-1, -1), OUT_CROSS, Vector2i(-1, 1), Vector2i(-1, 0)]) # T8 中心反射↙
	cases.append([t, t_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # T9 左端点
	cases.append([t, t_second, Vector2i(-1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # T10 背面
	cases.append([t, Vector2i.ZERO, Vector2i(1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # T11 背面
	cases.append([t, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T12 右端点

	# ---- LEFT（anchor=(x,y), second=(x,y-1), tangent=(0,-1), normal=(1,0)） ----
	var l: int = _DoubleCellMirror.MirrorOrientation.LEFT
	var l_second: Vector2i = Vector2i(0, -1)
	cases.append([l, Vector2i.ZERO, Vector2i(-1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # L1 折回
	cases.append([l, Vector2i.ZERO, Vector2i(1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # L2 背面
	cases.append([l, Vector2i.ZERO, Vector2i(0, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L3 平行
	cases.append([l, Vector2i.ZERO, Vector2i(0, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # L4 平行
	cases.append([l, Vector2i.ZERO, Vector2i(-1, -1), OUT_CROSS, Vector2i(1, -1), Vector2i(0, -1)]) # L5 中心反射↗
	cases.append([l, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L6 下端点
	cases.append([l, l_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # L7 上端点
	cases.append([l, l_second, Vector2i(-1, 1), OUT_CROSS, Vector2i(1, 1), Vector2i(0, 1)])         # L8 中心反射↘
	cases.append([l, l_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # L9 上端点
	cases.append([l, Vector2i.ZERO, Vector2i(1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # L10 背面
	cases.append([l, l_second, Vector2i(1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # L11 背面
	cases.append([l, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L12 下端点

	for c: Array in cases:
		var res = _DoubleCellMirror.resolve_interaction(c[0], c[1], c[2])
		var ok: bool = res.outcome == c[3]
		if res.outcome == OUT_CROSS:
			ok = ok and res.reflect_direction == c[4] and res.cross_direction == c[5]
		_check(NAME, ok,
			"用例：orientation=%d offset=%s dir=%s => outcome=%d reflect=%s cross=%s（期望 outcome=%d reflect=%s cross=%s）"
			% [c[0], c[1], c[2], res.outcome, res.reflect_direction, res.cross_direction, c[3], c[4], c[5]])


# ===== 内部类 =====

## 真实 DoubleCellMirror 节点工厂：满足 PlacementController 的 Callable(mechanism_id, cell, orientation)->Variant 契约。
## 直接写 mechanism_id + set_cell + set_orientation（configure 的全部非视觉事实）；不调用 configure：
## configure 末尾 set_drag_preview 依赖 @onready _visual_view，而工厂在控制器事务内同步调用、无法泵帧触发 _ready。
class _DoubleMirrorFactory extends RefCounted:
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


# ===== 断言、清理与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 清理工厂创建并挂到 root 的真实镜面节点：对仍有效者 queue_free，交由调用方后续泵帧落地。
func _free_created_tokens() -> void:
	if _factory == null:
		return
	for node: Node in _factory.created_tokens:
		if is_instance_valid(node):
			node.queue_free()


## 输出测试摘要。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== DoubleCellMirror 判定逻辑与生命周期回归测试摘要 ====")
	print("测试组数：6")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
