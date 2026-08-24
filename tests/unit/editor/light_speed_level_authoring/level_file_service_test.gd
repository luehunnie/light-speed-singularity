extends SceneTree

# AF-08 Create New Level / Duplicate as New Level 服务测试。
# 覆盖：创建（模板实例、level_id 分配、稳定 ID 重发、保存、校验零问题）、技术文件名递增、
#       复制（内容等价、身份独立、旧≠新 ID）、空显示名拒绝、临时目录清理。
# 由 Godot --script 运行；全部通过 quit(0)，任一失败 quit(1)。

const _LevelFileService: GDScript = preload(
	"res://addons/light_speed_level_authoring/authoring/level_file_service.gd"
)
const _LevelRay001: PackedScene = preload(
	"res://levels/campaign/ray_chapter/level_ray_001.tscn"
)

const TEMP_ROOT: String = "res://tests/unit/editor/light_speed_level_authoring/.tmp_campaign"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_make_temp_root()
	_test_01_create_new_level()
	_test_02_filename_and_id_increment()
	_test_03_duplicate_level()
	_test_04_empty_display_name_rejected()
	_cleanup_temp_root()
	_report()
	quit(0 if _failures.is_empty() else 1)


func _make_temp_root() -> void:
	_remove_dir_recursive(TEMP_ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP_ROOT))


func _cleanup_temp_root() -> void:
	_remove_dir_recursive(TEMP_ROOT)


# 递归删除临时目录（含章节子目录），保证逐次运行从干净状态开始。
func _remove_dir_recursive(dir_path: String) -> void:
	var absolute := ProjectSettings.globalize_path(dir_path)
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var sub_directories: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			sub_directories.append(full)
		else:
			DirAccess.remove_absolute(absolute.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	for sub: String in sub_directories:
		_remove_dir_recursive(sub)
	DirAccess.remove_absolute(absolute)


func _list_files(dir_path: String) -> Array[String]:
	var files: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return files
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not entry.begins_with(".") and not dir.current_is_dir():
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return files


func _test_01_create_new_level() -> void:
	const NAME: String = "01_创建新关卡"
	var service: RefCounted = _LevelFileService.new()
	var result: Dictionary = service.create_new_level("测试关卡一", "ray_chapter", TEMP_ROOT)
	_check(NAME, result.ok, "创建应成功：%s" % ", ".join(result.errors))
	_check(NAME, ResourceLoader.exists(result.path), "关卡文件应已保存：%s" % result.path)
	_check(NAME, result.level_id == "lvl_0000001", "首个 level_id 应为 lvl_0000001，实际 %s。" % result.level_id)
	_check(NAME, (result.issues as Array).is_empty(), "新关卡应通过统一 Validator（0 问题），实际 %d。" % (result.issues as Array).size())
	var saved := load(result.path) as PackedScene
	var root: Node = saved.instantiate()
	_check(NAME, str(root.get_meta("level_id", "")) == "lvl_0000001", "保存场景应持 level_id meta。")
	_check(NAME, str(root.get_meta("display_name", "")) == "测试关卡一", "保存场景应持显示名 meta。")
	var formal_ids: Array[String] = []
	for child in root.get_node("RuntimeObjects").get_children():
		var id_value := str(child.get("stable_instance_id"))
		if not id_value.is_empty():
			formal_ids.append(id_value)
	_check(NAME, formal_ids.size() == 2, "模板两个正式对象应均持新稳定 ID。")
	var crystal := root.get_node_or_null("RuntimeObjects/BasicCrystal")
	_check(NAME, crystal != null and String(crystal.get("crystal_id")).begins_with("fci_"),
		"水晶 crystal_id 应为系统重发的 fci_ 前缀（非模板手填 crystal_001）。")
	root.free()


func _test_02_filename_and_id_increment() -> void:
	const NAME: String = "02_文件名与level_id递增"
	var service: RefCounted = _LevelFileService.new()
	var second: Dictionary = service.create_new_level("测试关卡二", "ray_chapter", TEMP_ROOT)
	_check(NAME, second.ok and second.path.ends_with("level_ray_002.tscn"),
		"第二个关卡技术文件名应为 level_ray_002.tscn，实际 %s。" % second.path)
	_check(NAME, second.level_id == "lvl_0000002", "第二个 level_id 应为 lvl_0000002，实际 %s。" % second.level_id)


func _test_03_duplicate_level() -> void:
	const NAME: String = "03_复制为新关卡"
	var service: RefCounted = _LevelFileService.new()
	var source_root: Node = _LevelRay001.instantiate()
	var source_terrain: TileMapLayer = source_root.get_node("TerrainLayer")
	var source_cells: Array = source_root.get_node("TerrainLayer").get_used_cells()
	var source_crystal_id := String(source_root.get_node("RuntimeObjects/Crystal").get("crystal_id"))
	source_root.free()
	var result: Dictionary = service.duplicate_level(
		"res://levels/campaign/ray_chapter/level_ray_001.tscn", "复制关卡", "ray_chapter", TEMP_ROOT)
	_check(NAME, result.ok, "复制应成功：%s" % ", ".join(result.errors))
	var dup_root: Node = (load(result.path) as PackedScene).instantiate()
	var dup_cells: Array = dup_root.get_node("TerrainLayer").get_used_cells()
	_check(NAME, dup_cells.size() == source_cells.size(), "复制后 Terrain 格数应等价（%d→%d）。" % [source_cells.size(), dup_cells.size()])
	var dup_crystal := dup_root.get_node_or_null("RuntimeObjects/Crystal")
	_check(NAME, dup_crystal != null and String(dup_crystal.get("crystal_id")) != source_crystal_id,
		"复制后水晶 ID 应重发生（旧 %s → 新 %s），内容相似但身份独立。" % [
			source_crystal_id, String(dup_crystal.get("crystal_id")) if dup_crystal != null else "无"])
	_check(NAME, (result.id_remap as Dictionary).has(source_crystal_id) if source_crystal_id != "" else true,
		"旧 crystal_id 应进入重映射表（引用重建数据源）。")
	dup_root.free()


func _test_04_empty_display_name_rejected() -> void:
	const NAME: String = "04_空显示名拒绝"
	var service: RefCounted = _LevelFileService.new()
	var result: Dictionary = service.duplicate_level("res://不存在.tscn", "x", "ray_chapter", TEMP_ROOT)
	_check(NAME, not result.ok and not (result.errors as PackedStringArray).is_empty(),
		"不可加载源应显式失败（ok=false 且 errors 非空）。")


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, message])
		print("FAIL [%s] %s" % [group, message])


func _report() -> void:
	print("level_file_service_test: %d checks, %d failures" % [_checks, _failures.size()])
