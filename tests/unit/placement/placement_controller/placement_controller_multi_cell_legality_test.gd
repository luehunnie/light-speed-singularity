extends SceneTree

## PlacementController 多格放置合法性格点定向测试（D7-R4）。
## 固化 is_valid_placement_cells 最小多格路径：非空/无重复/每格合法整体判定、ignored_id 忽略自身占用、
## LevelWorldQuery 未注入时 false；并与真实单格放置事务 coexistence（已放置单格机关对他机关多格格集非法）。
## 经 placement_flow_fixture 装配真实 PlacementController + LevelWorldQuery + OccupancyRegistry；
## 由 Godot --script 运行，任一失败 quit(1)。桩节点挂 SceneTree.root 由树统一释放。
## 注意：所有调用点使用静态类型接收者与 Array[Vector2i] 局部变量，避免 Variant 动态调用下
## 未类型化数组实参触发运行期 SCRIPT ERROR 中断当前函数造成假 PASS。

const _PlacementFlowFixture: GDScript = preload(
	"res://tests/unit/placement/fixtures/placement_flow_fixture.gd"
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

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0

## 每组测试持有的夹具实例，避免工厂 RefCounted 在 Callable 单引用下被提前回收。
var _fixture: _PlacementFlowFixture = null


func _initialize() -> void:
	_test_01_valid_cells_true()
	_test_02_invalid_inputs_false()
	_test_03_occupied_by_other_false()
	_test_04_ignored_id_allows_own_cells()
	_test_05_single_cell_transaction_coexistence()
	_test_06_query_not_injected_false()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试用例 =====

## 1. 全部格合法的两格集合通过格点。
func _test_01_valid_cells_true() -> void:
	const NAME: String = "01_合法多格格点"
	var ctx: _Env = _make_env()
	var cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3)]
	_check(NAME, ctx.controller.is_valid_placement_cells(cells) == true, "两格均合法的集合应通过格点。")


## 2. 非法输入拒绝：空集合、重复格、含出界格。
func _test_02_invalid_inputs_false() -> void:
	const NAME: String = "02_非法输入拒绝"
	var ctx: _Env = _make_env()
	var empty_cells: Array[Vector2i] = []
	_check(NAME, ctx.controller.is_valid_placement_cells(empty_cells) == false, "空集合应返回 false。")
	var dup_cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(3, 3)]
	_check(NAME, ctx.controller.is_valid_placement_cells(dup_cells) == false, "重复格应返回 false。")
	var oob_cells: Array[Vector2i] = [Vector2i(3, 3), Vector2i(99, 99)]
	_check(NAME, ctx.controller.is_valid_placement_cells(oob_cells) == false, "含出界格应返回 false。")


## 3. 任一格被其他机关占用（多格 register_cells 或单格事务）则整体非法。
func _test_03_occupied_by_other_false() -> void:
	const NAME: String = "03_他机关占用非法"
	var ctx: _Env = _make_env()
	var occupied: Array[Vector2i] = [Vector2i(4, 4), Vector2i(5, 4)]
	_check(NAME, ctx.occupancy.register_cells(&"w1", occupied) == true, "前置多格登记应成功。")
	var probe: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 4)]
	_check(NAME, ctx.controller.is_valid_placement_cells(probe) == false, "含多格机关占用格应非法。")
	_check(NAME, ctx.controller.is_valid_placement_cells(occupied, &"other") == false, "ignored_id 为其他 ID 仍应非法。")


## 4. ignored_id 忽略自身既有占用：旋转保持锚点的多格机关在新朝向格集上通过格点。
func _test_04_ignored_id_allows_own_cells() -> void:
	const NAME: String = "04_忽略自身占用"
	var ctx: _Env = _make_env()
	# 双格平面镜 v0.6 §2.1：TOP 占 (x-1,y),(x,y)，BOTTOM 占 (x,y),(x+1,y)，旋转锚点不变。
	var top_cells: Array[Vector2i] = [Vector2i(4, 5), Vector2i(5, 5)]
	var bottom_cells: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	_check(NAME, ctx.occupancy.register_cells(&"w1", top_cells) == true, "前置 TOP 朝向登记应成功。")
	_check(NAME, ctx.controller.is_valid_placement_cells(bottom_cells, &"w1") == true, "旋转目标格集（忽略自身）应通过格点。")
	_check(NAME, ctx.controller.is_valid_placement_cells(bottom_cells) == false, "不忽略自身时锚点格被自身占用应非法。")


## 5. 与单格放置事务 coexistence：真实放置的单格机关使他机关多格格集非法，忽略自身时合法。
func _test_05_single_cell_transaction_coexistence() -> void:
	const NAME: String = "05_单格事务共存"
	var ctx: _Env = _make_env()
	var result: Variant = ctx.controller.place_from_inventory(&"mirror", Vector2i(2, 2), 0)
	_check(NAME, result.is_success() == true, "前置单格放置事务应成功（%s）。" % [result.error_message])
	var probe: Array[Vector2i] = [Vector2i(2, 2), Vector2i(2, 3)]
	var free_cells: Array[Vector2i] = [Vector2i(6, 6), Vector2i(7, 6)]
	_check(NAME, ctx.controller.is_valid_placement_cells(probe) == false, "含已放置单格机关的格集应非法。")
	_check(NAME, ctx.controller.is_valid_placement_cells(probe, result.mechanism_id) == true, "忽略该机关自身时格集应合法。")
	_check(NAME, ctx.controller.is_valid_placement_cells(free_cells) == true, "无关空闲格集应保持合法。")


## 6. LevelWorldQuery 未注入时返回 false（与单格 _is_valid_placement_cell 同语义）。
func _test_06_query_not_injected_false() -> void:
	const NAME: String = "06_未注入查询拒绝"
	var fixture: _PlacementFlowFixture = _PlacementFlowFixture.new()
	_fixture = fixture
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var inventory: _InventoryController = _InventoryController.new(3)
	var factory: Variant = fixture._StubFactory.new()
	var controller: _PlacementController = _PlacementController.new(occupancy, inventory, Callable(factory, "create"))
	var cells: Array[Vector2i] = [Vector2i(3, 3)]
	_check(NAME, controller.is_valid_placement_cells(cells) == false, "未注入 LevelWorldQuery 应返回 false。")


# ===== 装配 =====

## 测试环境：经 placement_flow_fixture 构造的真实控制器、占用表与共享夹具持有者。
class _Env:
	var controller: _PlacementController = null
	var occupancy: _OccupancyRegistry = null
	var fixture: _PlacementFlowFixture = null


## 经 placement_flow_fixture 构造真实控制器环境，返回静态类型 _Env。
## 夹具实例存入 _Env.fixture 与 _fixture 成员双重持有，防止工厂 RefCounted 提前回收。
func _make_env() -> _Env:
	var fixture: _PlacementFlowFixture = _PlacementFlowFixture.new()
	_fixture = fixture
	var occupancy: _OccupancyRegistry = _OccupancyRegistry.new()
	var inventory: _InventoryController = _InventoryController.new(3)
	var factory: Variant = fixture._StubFactory.new()
	var env: _Env = _Env.new()
	env.fixture = fixture
	env.controller = fixture.make_controller(self, occupancy, inventory, factory)
	env.occupancy = occupancy
	return env


# ===== 支撑 =====

## 记录断言：失败项收集到 _failures，全部通过时 _checks 递增。
func _check(group_name: String, condition: bool, reason: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append("[%s] %s" % [group_name, reason])


## 统一报告：输出通过/失败统计与全部失败项。
func _report() -> void:
	print("placement_controller_multi_cell_legality_test: %d checks, %d failures" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  FAIL " + failure)
