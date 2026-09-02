extends SceneTree

# D-04 正式墙体内容对象测试：
# 12 样式目录与 WallBlock 枚举同步（token↔序号↔贴图）、单格样式 Inspector 入口与 Typed
# apply_configuration 合同（合法/null/缺字段/越界）、单格与多格保存/重载等价（pack/instantiate），
# 多格结构 footprint（get_occupied_offsets / get_wall_cells）与 L 四旋向、三段视觉与占格同位置、
# 移动原子性、非机关边界（非 PlaceableToken、收编器静默跳过）、运行期墙真值合并（快照 + 查询门面）。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _WallBlockScene: PackedScene = preload("res://gameplay/content/wall/wall_block.tscn")
const _WallStructureHScene: PackedScene = preload("res://gameplay/content/wall/wall_structure_h.tscn")
const _WallStructureVScene: PackedScene = preload("res://gameplay/content/wall/wall_structure_v.tscn")
const _WallStructureLScene: PackedScene = preload("res://gameplay/content/wall/wall_structure_l.tscn")
const _WallBlockScript: GDScript = preload("res://gameplay/content/wall/wall_block.gd")
const _WallStructureScript: GDScript = preload("res://gameplay/content/wall/wall_structure.gd")
const _WallStyleCatalog: GDScript = preload(
	"res://gameplay/content/wall/wall_style_catalog.gd"
)
const _WallContentDefinition: GDScript = preload(
	"res://gameplay/content/wall_content_definition.gd"
)
const _MechanismConfiguration: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_configuration.gd"
)
const _MechanismFieldDefinition: GDScript = preload(
	"res://gameplay/content/configuration/mechanism_field_definition.gd"
)
const _GridCoordinateRules: GDScript = preload(
	"res://gameplay/grid/grid_coordinate_rules.gd"
)
const _PlaceableToken: GDScript = preload(
	"res://gameplay/placement/placeable_token.gd"
)
const _PreplacedAdopter: GDScript = preload(
	"res://gameplay/placement/preplaced_mechanism_adopter.gd"
)
const _OccupancyRegistry: GDScript = preload("res://gameplay/placement/occupancy_registry.gd")
const _LevelTileLayerSnapshot: GDScript = preload(
	"res://gameplay/world/level_tile_layer_snapshot.gd"
)
const _LevelWorldQuery: GDScript = preload("res://gameplay/world/level_world_query.gd")
const _LevelObjectRegistry: GDScript = preload("res://gameplay/level/level_object_registry.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_catalog_enum_sync()
	_test_02_wall_block_style_and_configuration()
	_test_03_wall_block_save_reload()
	_test_04_structure_footprint_and_atoms()
	await _test_05_structure_l_orientations_and_visuals()
	_test_06_structure_configuration_and_reload()
	_test_07_not_mechanism_and_snapshot_truth()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 1. 样式目录与枚举同步 =====

func _test_01_catalog_enum_sync() -> void:
	const NAME: String = "01_目录与枚举同步"
	_check(NAME, _WallBlockScript.WallStyle.size() == _WallStyleCatalog.STYLE_ORDER.size(),
		"WallBlock 枚举数应与目录 token 数一致（12）。")
	_check(NAME, _WallStructureScript.Structure.size() == 3, "结构枚举应恰 3（横/竖/L）。")
	_check(NAME, _WallStructureScript.CornerOrientation.size() == 4, "L 旋向枚举应恰 4。")
	for i: int in _WallStyleCatalog.STYLE_ORDER.size():
		var texture_path: String = _WallStyleCatalog.texture_path_at(i)
		_check(NAME, not texture_path.is_empty() and load(texture_path) != null,
			"样式 %d 贴图应可加载：%s。" % [i, texture_path])
	var definition: _WallContentDefinition = _WallContentDefinition.new()
	definition.content_type_id = &"wall_test"
	definition.display_name = "测试墙"
	definition.scene = _WallBlockScene
	_check(NAME, definition.get_content_domain() == StringName(&"wall"), "定义域应为 wall。")
	_check(NAME, definition.validate_definition().is_empty(), "默认单格足迹定义应合法。")
	definition.static_footprint_offsets = [Vector2i.ZERO, Vector2i.ZERO]
	_check(NAME, not definition.validate_definition().is_empty(), "重复足迹应校验失败。")


# ===== 2. 单格样式 Inspector 入口与 Typed 配置合同 =====

func _test_02_wall_block_style_and_configuration() -> void:
	const NAME: String = "02_单格样式与配置"
	var block: Node = _WallBlockScene.instantiate()
	_check(NAME, int(block.get("wall_style")) == 0, "默认样式应为直墙·上(0)。")
	for style_index: int in _WallStyleCatalog.STYLE_ORDER.size():
		block.set("wall_style", style_index)
		_check(NAME, int(block.get("wall_style")) == style_index, "样式 %d 应可写入。" % style_index)
	# 越界：拒绝并保持原值（报错允许，哨兵式验证状态不变）。
	block.set("wall_style", 3)
	block.set("wall_style", 99)
	_check(NAME, int(block.get("wall_style")) == 3, "越界样式应被拒绝并保持原值。")
	# Typed 配置：合法 / null / 缺字段 / 越界。
	var config: Object = _wall_style_config()
	_check(NAME, config.apply_override(_WallBlockScript.FIELD_WALL_STYLE, 5), "合法覆盖应成功。")
	_check(NAME, block.call("apply_configuration", config), "合法配置应应用成功。")
	_check(NAME, int(block.get("wall_style")) == 5, "应用后样式应为 5。")
	_check(NAME, block.call("apply_configuration", null), "null 配置应直接通过。")
	_check(NAME, int(block.get("wall_style")) == 5, "null 配置不得改写样式。")
	var missing: Object = _MechanismConfiguration.from_type_defaults([])
	_check(NAME, not block.call("apply_configuration", missing), "缺 wall_style 字段应拒绝。")
	var wide: Object = _wall_style_config(99)
	_check(NAME, wide.apply_override(_WallBlockScript.FIELD_WALL_STYLE, 99), "放宽 Schema 后越界值可进配置。")
	_check(NAME, not block.call("apply_configuration", wide), "越界样式应由本对象拒绝。")
	_check(NAME, int(block.get("wall_style")) == 5, "越界拒绝后样式应保持不变。")
	block.free()


# ===== 3. 单格保存/重载等价 =====

func _test_03_wall_block_save_reload() -> void:
	const NAME: String = "03_单格保存重载"
	var block: Node = _WallBlockScene.instantiate()
	block.set("wall_style", 7)
	block.set("position", _GridCoordinateRules.cell_to_world(Vector2i(3, 2)))
	block.set("stable_instance_id", "fci_0000009")
	var packed: PackedScene = PackedScene.new()
	_check(NAME, packed.pack(block) == OK, "单格墙应可打包保存。")
	var reloaded: Node = packed.instantiate()
	_check(NAME, int(reloaded.get("wall_style")) == 7, "保存/重载后样式应保持。")
	_check(NAME, reloaded.get("position") == block.get("position"), "保存/重载后位置应保持。")
	_check(NAME, str(reloaded.get("stable_instance_id")) == "fci_0000009", "保存/重载后稳定 ID 应保持。")
	_check(NAME, (reloaded.call("get_wall_cells") as Array) == [Vector2i(3, 2)],
		"重载后占格应由位置派生为 (3,2)。")
	reloaded.free()
	block.free()


# ===== 4. 多格 footprint 与移动原子性 =====

func _test_04_structure_footprint_and_atoms() -> void:
	const NAME: String = "04_多格footprint"
	var h: Node = _WallStructureHScene.instantiate()
	var v: Node = _WallStructureVScene.instantiate()
	var l: Node = _WallStructureLScene.instantiate()
	_check(NAME, int(h.get("structure")) == 0, "横墙场景应写定 structure=0。")
	_check(NAME, int(v.get("structure")) == 1, "竖墙场景应写定 structure=1。")
	_check(NAME, int(l.get("structure")) == 2, "L 墙场景应写定 structure=2。")
	_check(NAME, (h.call("get_occupied_offsets") as Array) ==
		[Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0)], "横墙 footprint 应为 ±x 三格。")
	_check(NAME, (v.call("get_occupied_offsets") as Array) ==
		[Vector2i(0, -1), Vector2i.ZERO, Vector2i(0, 1)], "竖墙 footprint 应为 ±y 三格。")
	_check(NAME, (l.call("get_occupied_offsets") as Array) ==
		[Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)], "L 墙默认（ES）应为拐角+右+下。")
	# 绝对占格随锚格派生。
	h.set("position", _GridCoordinateRules.cell_to_world(Vector2i(4, 3)))
	_check(NAME, (h.call("get_wall_cells") as Array) ==
		[Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3)], "横墙占格应为锚格 ±x。")
	# 移动原子：position 平移后全部占格整体移动。
	h.set("position", _GridCoordinateRules.cell_to_world(Vector2i(6, 3)))
	_check(NAME, (h.call("get_wall_cells") as Array) ==
		[Vector2i(5, 3), Vector2i(6, 3), Vector2i(7, 3)], "移动后占格应整体平移（原子语义）。")
	h.free()
	v.free()
	l.free()


# ===== 5. L 四旋向与三段视觉同位置 =====

func _test_05_structure_l_orientations_and_visuals() -> void:
	const NAME: String = "05_L旋向与视觉对齐"
	# 旋向 → 占格（拐角+两臂）与拐角外角 token（D-03 冻结映射）。
	var frozen: Dictionary = {
		0: {"arms": [Vector2i(1, 0), Vector2i(0, 1)], "corner_style": "large_bend_lu"},
		1: {"arms": [Vector2i(-1, 0), Vector2i(0, 1)], "corner_style": "large_bend_ru"},
		2: {"arms": [Vector2i(-1, 0), Vector2i(0, -1)], "corner_style": "large_bend_rd"},
		3: {"arms": [Vector2i(1, 0), Vector2i(0, -1)], "corner_style": "large_bend_ld"},
	}
	var l: Node = _WallStructureLScene.instantiate()
	# headless --script 下 _initialize 不泵帧、_ready 不触发：add_child 后 await 一帧
	# 等 @onready/_refresh_visual 完成再断言（repo 既有异步边界约定）。
	root.add_child(l)
	await process_frame
	for orientation: Variant in frozen:
		var spec: Dictionary = frozen[orientation]
		l.set("corner_orientation", orientation)
		var expected: Array = [Vector2i.ZERO] + (spec["arms"] as Array)
		_check(NAME, (l.call("get_occupied_offsets") as Array) == expected,
			"旋向 %d 占格应为 %s，实际 %s。" % [orientation, expected, l.call("get_occupied_offsets")])
		# 三段视觉：位置与占格同位置（offset*64），贴图按冻结组成约定。
		var segments: Array = l.get("_segments")
		_check(NAME, segments.size() == 3, "L 墙应恰三段贴图。")
		var corner_sprite: Sprite2D = segments[0]
		_check(NAME, corner_sprite.position == Vector2.ZERO, "拐角段应在锚格原点。")
		_check(NAME, _texture_token(corner_sprite) == spec["corner_style"],
			"旋向 %d 拐角应为外角 %s，实际 %s。" % [orientation, spec["corner_style"], _texture_token(corner_sprite)])
		var arm_a: Sprite2D = segments[1]
		var arm_b: Sprite2D = segments[2]
		_check(NAME, arm_a.position == Vector2(spec["arms"][0]) * 64.0
			and arm_b.position == Vector2(spec["arms"][1]) * 64.0,
			"旋向 %d 两臂段位置应与占格偏移一致。" % orientation)
		_check(NAME, _texture_token(arm_a) == "straight_up" and _texture_token(arm_b) == "straight_left",
			"旋向 %d 横臂应直墙上、竖臂应直墙左。" % orientation)
	# 移动：三段是子节点，随父节点整体移动（视觉/阻挡同位置）。
	l.set("position", _GridCoordinateRules.cell_to_world(Vector2i(7, 7)))
	_check(NAME, (l.call("get_wall_cells") as Array).size() == 3
		and (l.get("_segments") as Array)[0].get_parent() == l,
		"移动后三段仍属同一节点（整体选中/删除）。")
	root.remove_child(l)
	l.free()


# ===== 6. 多格 Typed 配置与保存/重载 =====

func _test_06_structure_configuration_and_reload() -> void:
	const NAME: String = "06_多格配置与重载"
	var l: Node = _WallStructureLScene.instantiate()
	# 仅旋向字段（不携带 structure 默认值覆盖场景写定结构）。
	var config: Object = _MechanismConfiguration.from_type_defaults(
		[_int_field(_WallStructureScript.FIELD_CORNER_ORIENTATION, 3)])
	_check(NAME, config.apply_override(_WallStructureScript.FIELD_CORNER_ORIENTATION, 3), "覆盖旋向应成功。")
	_check(NAME, l.call("apply_configuration", config), "合法结构配置应应用成功。")
	_check(NAME, int(l.get("corner_orientation")) == 3, "应用后旋向应为 3(NE)。")
	_check(NAME, (l.call("get_occupied_offsets") as Array) ==
		[Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, -1)], "旋向 3 占格应为拐角+右+上。")
	var unknown: Object = _MechanismConfiguration.from_type_defaults([_int_field(&"wall_style", 11)])
	_check(NAME, not l.call("apply_configuration", unknown), "未知字段应拒绝。")
	_check(NAME, int(l.get("corner_orientation")) == 3, "拒绝后旋向应不变。")
	# 保存/重载：旋向持久化、结构事实来自场景。
	var packed: PackedScene = PackedScene.new()
	_check(NAME, packed.pack(l) == OK, "L 墙应可打包保存。")
	var reloaded: Node = packed.instantiate()
	_check(NAME, int(reloaded.get("corner_orientation")) == 3, "保存/重载后旋向应保持。")
	_check(NAME, int(reloaded.get("structure")) == 2, "保存/重载后结构应保持 L。")
	reloaded.free()
	l.free()
	# 横/竖墙场景实例化后结构写定（Palette 条目=场景声明）。
	var h: Node = _WallStructureHScene.instantiate()
	_check(NAME, int(h.get("structure")) == 0, "重载横墙场景结构应为 0。")
	h.free()


# ===== 7. 非机关边界与运行期墙真值 =====

func _test_07_not_mechanism_and_snapshot_truth() -> void:
	const NAME: String = "07_非机关边界与墙真值"
	var block: Node = _WallBlockScene.instantiate()
	var h: Node = _WallStructureHScene.instantiate()
	_check(NAME, not (block is _PlaceableToken) and not (h is _PlaceableToken),
		"墙对象不得是 PlaceableToken（不进机关收编与光交互契约）。")
	var container: Node2D = Node2D.new()
	container.name = &"RuntimeObjects"
	container.add_child(block)
	container.add_child(h)
	var adopted: int = _PreplacedAdopter.new(_OccupancyRegistry.new()).adopt_all(container)
	_check(NAME, adopted == 0, "收编器应静默跳过墙对象（0 收编）。")
	block.free()
	h.free()
	container.free()
	# 运行期墙真值：墙对象 footprint 并入快照 → 查询门面统一墙事实（Ray/Particle 同源）。
	var runtime: Node2D = Node2D.new()
	runtime.name = &"RuntimeObjects"
	var placed_block: Node = _WallBlockScene.instantiate()
	placed_block.set("position", _GridCoordinateRules.cell_to_world(Vector2i(4, 4)))
	runtime.add_child(placed_block)
	var placed_h: Node = _WallStructureHScene.instantiate()
	placed_h.set("position", _GridCoordinateRules.cell_to_world(Vector2i(6, 5)))
	runtime.add_child(placed_h)
	var fixture := _make_snapshot_world(runtime, [Vector2i(2, 2)])
	var query: _LevelWorldQuery = fixture["query"]
	_check(NAME, query.is_wall_cell(Vector2i(4, 4)), "墙对象锚格应查询为墙。")
	_check(NAME, query.is_wall_cell(Vector2i(5, 5)), "多格墙臂格应查询为墙（多格占用原子展开）。")
	_check(NAME, query.is_wall_cell(Vector2i(2, 2)), "旧 WallLayer 格应保持墙事实（兼容输入）。")
	_check(NAME, query.is_static_blocked_for_placement(Vector2i(4, 4)), "墙对象格应静态阻挡放置。")
	_check(NAME, query.is_valid_placement_cell(Vector2i(4, 4)) == false, "墙格不应为合法放置格。")
	_check(NAME, query.is_valid_placement_cell(Vector2i(0, 0)) == true, "空 LegalArea 格应可放置。")
	runtime.free()
	fixture["layers"].free()


# ===== fixture 与断言辅助 =====

## wall_style 字段 Schema 配置（默认放宽到 11 以便越界用例自定注入）。
func _wall_style_config(enum_max: int = 11) -> Object:
	return _MechanismConfiguration.from_type_defaults([_int_field(_WallBlockScript.FIELD_WALL_STYLE, enum_max)])


## INT 枚举字段 Schema（min 0 / max enum_max / default 0）。
func _int_field(field_id: StringName, enum_max: int) -> Object:
	var field: Object = _MechanismFieldDefinition.new()
	field.field_id = field_id
	field.display_name = "测试字段"
	field.value_type = _MechanismFieldDefinition.ValueType.INT
	field.enum_min = 0
	field.enum_max = enum_max
	field.default_value = 0
	return field


## 贴图 → 样式 token（按目录反查；用于断言三段贴图符合冻结组成约定）。
func _texture_token(sprite: Sprite2D) -> String:
	var path: String = (sprite.texture as Resource).resource_path
	for token: String in _WallStyleCatalog.STYLE_TEXTURE_PATHS:
		if _WallStyleCatalog.STYLE_TEXTURE_PATHS[token] == path:
			return token
	return ""


## 最小快照世界：Terrain 8×8 + LegalArea 8×8 + 空 WallLayer，extra 墙事实来自 runtime 内墙对象
## footprint（collect_wall_cells）；返回 { query, layers }（layers 为 4 层容器，调用方负责释放）。
func _make_snapshot_world(runtime: Node2D, wall_layer_cells: Array) -> Dictionary:
	var tile_set: TileSet = TileSet.new()
	tile_set.tile_size = Vector2i(64, 64)
	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(64, 64)
	tile_set.add_source(source)
	var layers: Node = Node.new()
	var terrain: TileMapLayer = _make_layer(tile_set)
	terrain.name = &"TerrainLayer"
	var wall: TileMapLayer = _make_layer(tile_set)
	wall.name = &"WallLayer"
	var legal: TileMapLayer = _make_layer(tile_set)
	legal.name = &"LegalAreaLayer"
	var deco: TileMapLayer = _make_layer(tile_set)
	deco.name = &"DecorationLayer"
	for x: int in range(0, 8):
		for y: int in range(0, 8):
			terrain.set_cell(Vector2i(x, y), 0, Vector2i.ZERO)
			legal.set_cell(Vector2i(x, y), 0, Vector2i.ZERO)
	for cell: Variant in wall_layer_cells:
		wall.set_cell(cell, 0, Vector2i.ZERO)
	layers.add_child(terrain)
	layers.add_child(wall)
	layers.add_child(legal)
	layers.add_child(deco)
	# extra 墙事实 = runtime 内墙对象 footprint（collect_wall_cells 唯一采集入口）。
	var snapshot: _LevelTileLayerSnapshot = _LevelTileLayerSnapshot.new(
		terrain, wall, legal, deco, _WallStyleCatalog.collect_wall_cells(runtime))
	var lookup := _PlacedLookup.new()
	var walls_arg: Array[Vector2i] = []
	var query: _LevelWorldQuery = _LevelWorldQuery.new(
		snapshot.get_terrain_bounds(), walls_arg, Vector2i(-9, -9),
		_LevelObjectRegistry.new(), _OccupancyRegistry.new(),
		Callable(lookup, "get_node"), snapshot)
	return {"query": query, "layers": layers}


## 无纹理 TileMapLayer。
func _make_layer(tile_set: TileSet) -> TileMapLayer:
	var layer: TileMapLayer = TileMapLayer.new()
	layer.tile_set = tile_set
	return layer


## 机关节点查表桩（查询门面 Callable 目标）。
class _PlacedLookup:
	func get_node(_mechanism_id: StringName) -> Variant:
		return null


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("wall_content_test: %d checks, %d failures" % [_checks, _failures.size()])
