@tool
extends RefCounted

# AF-08 Create New Level / Duplicate as New Level 服务（Guide §5/§6）。
# 命名与身份（Guide §5 冻结）：内容人员只给显示名称；技术文件名、保存路径、稳定 level_id 全部系统管理，
#   显示名称改动不改 level_id，Node.name / 文件名 / 显示标题都不是 ID。
# Duplicate（Guide §6 冻结）：复制内容 + 全部正式对象重发生稳定 ID + 新 level_id + 新技术文件名；
#   文件系统直接复制 .tscn 不是标准复制（File Copy 不是标准复制）。
# Objective / Control 内部引用重建：v0 正式关卡尚无 Stable ID 引用（AF-04/AF-05 接线 FROZEN_DEFERRED），
#   重映射表已随结果返回，引用编辑器落地时（AF-09）消费。


const _StableIdService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/stable_id_service.gd"
)
const _LevelValidator: GDScript = preload(
	"res://gameplay/level/validation/level_validator.gd"
)

# 空白正式关卡模板（四层 + RuntimeObjects + LightPathLayer + 合法 Emitter/Crystal 起始内容）。
const TEMPLATE_PATH: String = "res://levels/templates/level_template.tscn"
# 正式关卡保存根目录；章节子目录即章节 token（v0 仅 ray_chapter）。
const CAMPAIGN_ROOT: String = "res://levels/campaign"
# 关卡根隐藏稳定 level_id 的 meta 键（纯关卡无脚本，meta 是唯一不破坏“无脚本”冻结的持久化载体）。
const LEVEL_ID_META: String = "level_id"
# 显示名称 meta 键（作者可改，不影响 level_id）。
const DISPLAY_NAME_META: String = "display_name"

const _LEVEL_ID_PREFIX: String = "lvl_"
const _FILE_PATTERN: String = "level_%s_%03d.tscn"


# Create New Level：模板实例 → 默认 16×16 地图初始化 → 新 level_id + 显示名 → 全部对象新稳定 ID → 保存 → 校验。
# [br]campaign_root 可注入（测试隔离；默认正式目录）。
# [br]返回 {ok, path, level_id, issues: Array, errors: PackedStringArray}；任一步失败 ok=false 且不落盘。
func create_new_level(display_name: String, chapter: String = "ray_chapter",
		campaign_root: String = CAMPAIGN_ROOT) -> Dictionary:
	var template := load(TEMPLATE_PATH) as PackedScene
	if template == null:
		return _fail("关卡模板缺失：%s" % TEMPLATE_PATH)
	var root := template.instantiate()
	_initialize_default_map(root)
	return _prepare_and_save(root, display_name, chapter, campaign_root)


# Duplicate as New Level：装载源关卡 → 新 level_id + 显示名 → 全部对象重发生稳定 ID → 保存为新文件。
func duplicate_level(source_path: String, display_name: String, chapter: String = "ray_chapter",
		campaign_root: String = CAMPAIGN_ROOT) -> Dictionary:
	var source := load(source_path) as PackedScene
	if source == null:
		return _fail("源关卡不可加载：%s" % source_path)
	return _prepare_and_save(source.instantiate(), display_name, chapter, campaign_root)


# 收集全部正式关卡已用 level_id（确定性分配依据；目录缺省返回空）。
func collect_used_level_ids(campaign_root: String = CAMPAIGN_ROOT) -> Array[String]:
	var used: Array[String] = []
	for scene_path: String in _collect_level_paths(campaign_root):
		var packed := load(scene_path) as PackedScene
		if packed == null:
			continue
		var instance: Node = packed.instantiate()
		var level_id := str(instance.get_meta(LEVEL_ID_META, ""))
		if not level_id.is_empty():
			used.append(level_id)
		instance.free()
	return used


# 内部：统一“新关卡身份”收口——分配 level_id / 写显示名 / 重发生全部稳定 ID / 计算技术路径 / 保存 / 校验。
func _prepare_and_save(root: Node, display_name: String, chapter: String, campaign_root: String) -> Dictionary:
	if not (root is Node2D):
		root.free()
		return _fail("关卡根非 Node2D，拒绝生成。")
	var level_id := _allocate_level_id(campaign_root)
	var path := _next_level_path(chapter, campaign_root)
	(root as Node2D).set_meta(LEVEL_ID_META, level_id)
	(root as Node2D).set_meta(DISPLAY_NAME_META, display_name)
	var remap: Dictionary = _StableIdService.regenerate_all(root)
	var validation: Variant = _LevelValidator.new().validate(root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		root.free()
		return _fail("关卡场景打包失败。")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var save_error := ResourceSaver.save(packed, path)
	root.free()
	if save_error != OK:
		return _fail("关卡保存失败：%s（err=%d）" % [path, save_error])
	return {"ok": true, "path": path, "level_id": level_id, "id_remap": remap,
			"issues": validation.get_issues(), "errors": PackedStringArray()}


# 确定性 level_id 分配：已有最大序号 +1（无时间 / 随机源，与 AF-01 分配器口径一致）。
func _allocate_level_id(campaign_root: String) -> String:
	var max_serial := 0
	for level_id: String in collect_used_level_ids(campaign_root):
		if level_id.begins_with(_LEVEL_ID_PREFIX):
			max_serial = maxi(max_serial, level_id.get_slice("_", 1).to_int())
	return "%s%07d" % [_LEVEL_ID_PREFIX, max_serial + 1]


# 计算章节内下一个不冲突的技术文件名（ray_chapter 目录 → level_ray_%03d.tscn 前缀约定）。
func _next_level_path(chapter: String, campaign_root: String) -> String:
	var chapter_dir := campaign_root.path_join(chapter)
	var name_token := chapter.trim_suffix("_chapter")
	var existing := {}
	for scene_path: String in _collect_level_paths(chapter_dir):
		existing[scene_path.get_file()] = true
	var serial := 1
	while existing.has(_FILE_PATTERN % [name_token, serial]):
		serial += 1
	return chapter_dir.path_join(_FILE_PATTERN % [name_token, serial])


# 递归收集目录下全部 .tscn 路径（Godot 4.6 DirAccess.list_dir_begin 无参；隐藏项自行点前缀过滤）。
func _collect_level_paths(dir_path: String) -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return paths
	var sub_directories: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				sub_directories.append(full)
			elif entry.ends_with(".tscn"):
				paths.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	for sub: String in sub_directories:
		paths.append_array(_collect_level_paths(sub))
	paths.sort()
	return paths


func _fail(message: String) -> Dictionary:
	var errors := PackedStringArray()
	errors.append(message)
	return {"ok": false, "path": "", "level_id": "", "id_remap": {}, "issues": [], "errors": errors}


# 默认地图初始化（Guide §5“初始地图方式 / 基础大小”P0 口径）：Terrain 为空时填 16×16 矩形并同步 LegalArea。
# [br]tile 取各层 TileSet source 0 / atlas (0,0)（与 level_ray_001 序列化事实一致）；Terrain 已有格时不覆盖作者内容。
# [br]ponytail: 固定 16×16 默认尺寸；向导自定义尺寸留后续按需加参数。
func _initialize_default_map(root: Node, size: int = 16) -> void:
	var terrain: TileMapLayer = root.get_node_or_null("TerrainLayer")
	var legal: TileMapLayer = root.get_node_or_null("LegalAreaLayer")
	if terrain == null or legal == null or not terrain.get_used_cells().is_empty():
		return
	for y: int in range(size):
		for x: int in range(size):
			var cell := Vector2i(x, y)
			terrain.set_cell(cell, 0, Vector2i.ZERO)
			legal.set_cell(cell, 0, Vector2i.ZERO)
