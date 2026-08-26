extends SceneTree

## TileSet 图集整套替换服务测试（TileSet 美术工作流 v1）。
## 覆盖：
##   G01 解析目标：非 TileMapLayer / 无 TileSet / 内联 TileSet 拒绝；合法单图集解析。
##   G02 多图集源不猜测：analyze(-1) 拒绝；显式 source_id 通过；错误 source_id 拒绝。
##   G03 扫描器引用匹配：fixture 目录按路径命中、按 uid-only 命中、无关场景不命中、快照指纹结构；
##       真实 wall_tileset.tres 扫描无错误且包含全部 5 个已知引用场景（期望值仅在测试内）。
##   G04 纹理守卫：非 Texture2D / 非整数倍网格 / 尺寸不足拒绝；合法纹理给出 required_grid。
##   G05 analyze 守卫贯通：加载非纹理资源拒绝；坏路径拒绝；非 res:///user:// 路径拒绝。
##   G06 无确认拒绝：无 token / 错 token 拒绝；token 一次性；未注入 UndoRedo 拒绝。
##   G07 成功保持事实：纹理替换落盘；tile 坐标 / 动画 / alternative / custom data / source_id / 资源路径不变。
##   G08 undo/redo 双向保存：undo 恢复旧纹理并写盘；redo 恢复新纹理并写盘。
##   G09 失败回滚：保存后端失败 → 报错、内存回滚、磁盘保持旧内容；恢复后端后重试成功。
##   G10 无 tscn 写：fixture 场景文本 apply/undo/redo 前后逐字节一致。
##   G11 通知刷新：apply/undo/redo 每次成功写盘各触发一次刷新回调。
##   G12 相同纹理跳过：analyze 旧纹理路径 → apply skipped。
##   G13 面板最小装配：Dock 创建 Tileset 面板并转发 UndoRedo 与选择；面板端到端分析→确认→替换；
##       引用漂移与扫描错误在面板可见且不假确认；无管理器时明确失败。
##   G15 不可读场景阻断：scanner 结构化记录路径+原因；空场景/打不开的根令 ok=false；
##       analyze 拒绝且不发 token；分析成功后出现不可读场景令 apply 拒绝且 token 作废。
##   G16 引用漂移拒绝：分析后新增/删除引用场景 → apply 拒绝（引用已变化）、纹理不变、token 作废；
##       重新分析纳入新快照后恢复可替换。
##   G17 token 绑定：分析后图集源布局变化 → apply 拒绝并要求重新分析，token 作废。
##   G14 最终污染检查（末位执行）：真实 wall_tileset.tres 与 5 个引用场景内容全程未被修改。
## 由 Godot --headless --script 运行（UndoRedo.new()；真实 EditorUndoRedoManager 无法 headless 构造）。
## 任一失败 quit(1)。

const _ServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/tileset/tileset_atlas_replace_service.gd"
)
const _ScannerScript: GDScript = preload(
	"res://addons/light_speed_art_profile/tileset/tileset_reference_scanner.gd"
)
const _DockScene: PackedScene = preload(
	"res://addons/light_speed_art_profile/dock/art_profile_dock.tscn"
)

const _TEST_DIR: String = "user://tileset_replace_test"
const _SCENES_DIR: String = "user://tileset_replace_test/scenes"
const _BROKEN_DIR: String = "user://tileset_replace_test/broken"
const _WALL_TILES_PATH: String = "res://assets/art/tilesets/wall_tileset.tres"
const _WALL_UID: String = "uid://def2ipanaqi3u"
# 已知真实引用场景（期望值只存在于测试；服务运行期由扫描得出）。
const _WALL_SCENES: PackedStringArray = [
	"res://levels/campaign/mixed_chapter/level_mixed_001.tscn",
	"res://levels/campaign/ray_chapter/level_ray_001.tscn",
	"res://levels/prototypes/core_loop_prototype.tscn",
	"res://levels/templates/examples/level_template_editing_example.tscn",
	"res://levels/templates/level_template.tscn",
]

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _fixture_serial: int = 0
# 泄漏防护：全程创建的 fixture 层，收尾统一释放。
var _leak_guard_layers: Array = []
# G14 基线：真实资源内容指纹。
var _real_file_hashes: Dictionary = {}


func _initialize() -> void:
	_prepare_fixtures()
	_capture_real_file_hashes()
	_test_g01_resolve_target()
	_test_g02_multi_atlas_no_guessing()
	_test_g03_affected_scenes_scan()
	_test_g04_texture_guards()
	_test_g05_analyze_path_guards()
	_test_g06_confirmation_token_required()
	_test_g07_success_preserves_facts()
	_test_g08_undo_redo_both_persist()
	_test_g09_save_failure_rolls_back()
	_test_g10_no_tscn_writes()
	_test_g11_refresh_notifications()
	_test_g12_same_texture_skips()
	_test_g15_scan_errors_block()
	_test_g16_reference_drift_rejected()
	_test_g17_token_binding_guards()
	_test_g13_panel_minimal_assembly()
	_test_g14_real_files_untouched()
	_release_fixture_layers()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 释放全部 fixture TileMapLayer（及其引用链），保证退出零泄漏。无返回值。
func _release_fixture_layers() -> void:
	for layer in _leak_guard_layers:
		if is_instance_valid(layer):
			layer.free()
	_leak_guard_layers.clear()


## 清空并重建 user:// fixture 目录。无返回值。
func _prepare_fixtures() -> void:
	if DirAccess.dir_exists_absolute(_TEST_DIR):
		var files: PackedStringArray = PackedStringArray()
		_list_dir_recursive(_TEST_DIR, files)
		for file_path in files:
			DirAccess.remove_absolute(file_path)
		DirAccess.remove_absolute(_SCENES_DIR)
		DirAccess.remove_absolute(_TEST_DIR)
	DirAccess.make_dir_recursive_absolute(_SCENES_DIR)
	DirAccess.make_dir_recursive_absolute(_BROKEN_DIR)


## 递归列出 dir_path 下全部文件完整路径。无返回值。
func _list_dir_recursive(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				_list_dir_recursive(dir_path.path_join(entry), out)
			else:
				out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


## 记录真实 wall_tileset 与 5 个引用场景的内容哈希。无返回值。
func _capture_real_file_hashes() -> void:
	var paths: PackedStringArray = PackedStringArray([_WALL_TILES_PATH])
	paths.append_array(_WALL_SCENES)
	for path in paths:
		_real_file_hashes[path] = FileAccess.get_file_as_string(path).sha256_text()


## 生成带路径的 PNG 纹理 fixture（ResourceLoader 不识别 user://，经 Image 包装为
## 带 resource_path 的 ImageTexture，落盘 .tres 时仍写 ExtResource 路径）。返回 {ok, tex, path}。
func _make_png(name: String, width: int, height: int, color: Color) -> Dictionary:
	var path: String = _TEST_DIR + "/" + name
	var image: Image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	image.fill(color)
	if image.save_png(path) != OK:
		return {ok = false, tex = null, path = path}
	var loaded: Image = Image.load_from_file(path)
	if loaded == null:
		return {ok = false, tex = null, path = path}
	var texture: ImageTexture = ImageTexture.create_from_image(loaded)
	# take_over_path：同路径旧占用者存活时 resource_path 赋值会被静默忽略，强制接管注册。
	texture.take_over_path(path)
	return {ok = true, tex = texture, path = path}


## 构造外部 TileSet fixture：region 64×16，tiles (0,0)(1,0)(3,3) + 动画 tile (0,1)
## （columns 2 / frames 3）+ (0,0) alternative 1 + custom data 层。
## texture 为空时自动生成灰色 old_atlas.png（create_tile 需要有效纹理）。返回 {ts, atlas, path, layer}。
func _make_tileset(texture: Texture2D) -> Dictionary:
	if texture == null:
		var fallback: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
		texture = fallback.tex
	_fixture_serial += 1
	var tileset: TileSet = TileSet.new()
	tileset.tile_size = Vector2i(64, 16)
	var atlas: TileSetAtlasSource = TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(64, 16)
	tileset.add_source(atlas, 0)
	atlas.create_tile(Vector2i(0, 0))
	atlas.create_tile(Vector2i(1, 0))
	atlas.create_tile(Vector2i(3, 3))
	atlas.create_tile(Vector2i(0, 1))
	atlas.set_tile_animation_columns(Vector2i(0, 1), 2)
	atlas.set_tile_animation_frames_count(Vector2i(0, 1), 3)
	atlas.create_alternative_tile(Vector2i(0, 0), 1)
	tileset.add_custom_data_layer()
	tileset.set_custom_data_layer_name(0, "meta")
	atlas.get_tile_data(Vector2i(0, 0), 0).set_custom_data("meta", 7)
	var path: String = "%s/fixture_%d.tres" % [_TEST_DIR, _fixture_serial]
	tileset.resource_path = path
	ResourceSaver.save(tileset, path)
	var layer: TileMapLayer = TileMapLayer.new()
	layer.tile_set = tileset
	_leak_guard_layers.append(layer)
	return {ts = tileset, atlas = atlas, path = path, layer = layer}


## 在指定目录写一个假 .tscn 文本文件（content 可为空串，模拟空/不可读场景），返回其路径。
func _write_scene_in(dir_path: String, name: String, content: String) -> String:
	var path: String = dir_path + "/" + name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	return path


## 在 fixture scenes 目录写一个假 .tscn 文本文件，返回其路径。
func _write_fake_scene(name: String, content: String) -> String:
	return _write_scene_in(_SCENES_DIR, name, content)


func _check(group: String, condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("%s：%s" % [group, message])


func _report() -> void:
	# 期望断言总数守卫：任何组因 SCRIPT ERROR 中途跳过都会使实际数小于期望，杜绝假 PASS。
	const EXPECTED_ASSERTS: int = 115
	if _checks != EXPECTED_ASSERTS:
		_failures.append("SELF_断言计数：期望 %d，实际 %d（可能有组被脚本错误中断）。" % [EXPECTED_ASSERTS, _checks])
	print("tileset_atlas_replace_service_test：%d 断言" % _checks)
	if not _failures.is_empty():
		for failure in _failures:
			print("FAIL %s" % failure)
	else:
		print("全部 PASS")


## G01 解析目标边界。
func _test_g01_resolve_target() -> void:
	const NAME: String = "G01_解析目标"
	var service: RefCounted = _ServiceScript.new()
	var bad: Dictionary = service.resolve_target(Node2D.new())
	_check(NAME, not bad.ok, "非 TileMapLayer 应拒绝。")
	var empty_layer: TileMapLayer = TileMapLayer.new()
	bad = service.resolve_target(empty_layer)
	_check(NAME, not bad.ok and String(bad.reason).contains("TileSet"), "无 TileSet 应拒绝。")
	var made: Dictionary = _make_tileset(null)
	made.ts.resource_path = ""
	bad = service.resolve_target(made.layer)
	_check(NAME, not bad.ok and String(bad.reason).contains("内联"), "内联 TileSet 应拒绝并说明原因。")
	made.ts.resource_path = made.path
	var good: Dictionary = service.resolve_target(made.layer)
	_check(NAME, good.ok, "合法层应解析成功：%s" % String(good.reason))
	_check(
		NAME,
		good.atlas_sources.size() == 1 and int(good.atlas_sources[0].source_id) == 0,
		"应解析出唯一图集源 source_id=0。"
	)
	_check(NAME, String(good.tileset_path) == made.path, "解析应给出 TileSet 资源路径。")


## G02 多图集源必须明确选择，v1 不猜测。
func _test_g02_multi_atlas_no_guessing() -> void:
	const NAME: String = "G02_多图集不猜测"
	var service: RefCounted = _ServiceScript.new()
	var made: Dictionary = _make_tileset(null)
	var extra: TileSetAtlasSource = TileSetAtlasSource.new()
	made.ts.add_source(extra, 5)
	var png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	_check(NAME, png.ok, "old_atlas.png fixture 应生成成功。")
	made.atlas.texture = png.tex
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var deny: Dictionary = service.analyze(made.layer, -1, png.path)
	_check(NAME, not deny.ok and String(deny.reason).contains("明确选择"), "多图集源 analyze(-1) 应拒绝并要求明确选择。")
	var good: Dictionary = service.analyze(made.layer, 5, png.path)
	_check(NAME, good.ok, "显式 source_id=5 应通过：%s" % String(good.reason))
	_check(NAME, int(good.source_id) == 5, "计划应记录显式 source_id。")
	deny = service.analyze(made.layer, 77, png.path)
	_check(NAME, not deny.ok, "不存在的 source_id 应拒绝。")


## G03 扫描器引用匹配：结构化结果 / 路径命中 / uid-only 命中 / 无关不命中 / 真实 5 场景。
func _test_g03_affected_scenes_scan() -> void:
	const NAME: String = "G03_影响列表扫描"
	var scanner: RefCounted = _ScannerScript.new()
	var made: Dictionary = _make_tileset(null)
	var hit_path: String = _write_fake_scene(
		"hit_by_path.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	_write_fake_scene(
		"miss_other.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="user://tileset_replace_test/other.tres" id="1_w"]\n'
	)
	scanner.set_scan_roots(PackedStringArray([_SCENES_DIR]))
	var scanned: Dictionary = scanner.scan(made.path, "")
	_check(NAME, bool(scanned.ok), "全部场景可读时扫描 ok 应为 true。")
	_check(
		NAME,
		scanned.references.size() == 1 and scanned.references[0] == hit_path,
		"按路径应只命中引用场景，实际：%s" % str(scanned.references)
	)
	_check(NAME, scanned.errors.is_empty(), "可读场景不应产生错误。")
	_check(
		NAME,
		String(scanned.fingerprint) == "\n".join(PackedStringArray([hit_path])).sha256_text(),
		"指纹应为排序引用快照逐行拼接的哈希。"
	)
	# uid-only 命中：真实 wall_tileset 的 uid 写入假场景，不含其路径。
	var wall: TileSet = load(_WALL_TILES_PATH) as TileSet
	_check(NAME, wall != null, "真实 wall_tileset 应可加载。")
	var uid_only: String = _write_fake_scene(
		"hit_by_uid.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" uid="%s" path="" id="1_w"]\n' % _WALL_UID
	)
	scanned = scanner.scan(_WALL_TILES_PATH, _WALL_UID)
	_check(
		NAME,
		scanned.references.size() == 1 and scanned.references[0] == uid_only,
		"uid-only 引用应命中（路径为空）：%s" % str(scanned.references)
	)
	# 真实全仓扫描（默认根 res://）：无不可读场景 + 5 个已知场景全部出现。
	var real_scanner: RefCounted = _ScannerScript.new()
	var real_scan: Dictionary = real_scanner.scan(_WALL_TILES_PATH, _WALL_UID)
	_check(NAME, bool(real_scan.ok), "真实 res:// 扫描不应有不可读场景：%s" % str(real_scan.errors))
	for scene in _WALL_SCENES:
		_check(NAME, real_scan.references.has(scene), "真实扫描应包含 %s。" % scene)
	_check(NAME, real_scan.references.size() >= 5, "真实扫描结果应不少于 5 个场景，实际 %d。" % real_scan.references.size())


## G04 纹理守卫。
func _test_g04_texture_guards() -> void:
	const NAME: String = "G04_纹理守卫"
	var service: RefCounted = _ServiceScript.new()
	var made: Dictionary = _make_tileset(null)
	var bad: Dictionary = service.validate_texture(made.atlas, null)
	_check(NAME, not bad.ok and String(bad.reason).contains("Texture2D"), "null 纹理应拒绝。")
	var not_texture: Image = Image.create_empty(256, 64, false, Image.FORMAT_RGB8)
	bad = service.validate_texture(made.atlas, not_texture)
	_check(NAME, not bad.ok, "Image 非 Texture2D 应拒绝。")
	var odd: Dictionary = _make_png("odd_atlas.png", 100, 50, Color(0.5, 0.1, 0.1))
	_check(NAME, odd.ok, "odd_atlas.png fixture 应生成成功。")
	bad = service.validate_texture(made.atlas, odd.tex)
	_check(NAME, not bad.ok and String(bad.reason).contains("整数倍"), "非整数倍网格应拒绝并说明。")
	var small: Dictionary = _make_png("small_atlas.png", 192, 64, Color(0.1, 0.5, 0.1))
	_check(NAME, small.ok, "small_atlas.png fixture 应生成成功。")
	bad = service.validate_texture(made.atlas, small.tex)
	_check(NAME, not bad.ok and String(bad.reason).contains("不足以覆盖"), "尺寸不足应拒绝并说明。")
	var good: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	_check(NAME, good.ok, "new_atlas.png fixture 应生成成功。")
	var valid_result: Dictionary = service.validate_texture(made.atlas, good.tex)
	_check(NAME, valid_result.ok, "合法纹理应通过：%s" % String(valid_result.reason))
	_check(
		NAME,
		Vector2i(valid_result.required_grid) == Vector2i(4, 4),
		"已用范围应含 (3,3) 与动画帧，恰为 4×4，实际 %s。" % str(Vector2i(valid_result.required_grid))
	)


## G05 analyze 路径与加载守卫。
func _test_g05_analyze_path_guards() -> void:
	const NAME: String = "G05_analyze守卫"
	var service: RefCounted = _ServiceScript.new()
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var made: Dictionary = _make_tileset(null)
	var bad: Dictionary = service.analyze(made.layer, -1, _WALL_TILES_PATH)
	_check(NAME, not bad.ok and String(bad.reason).contains("Texture2D"), "加载到非纹理资源应拒绝。")
	bad = service.analyze(made.layer, -1, "res://assets/art/does_not_exist.png")
	_check(NAME, not bad.ok and String(bad.reason).contains("无法加载"), "坏路径应拒绝。")
	bad = service.analyze(made.layer, -1, "C:/absolute/nope.png")
	_check(NAME, not bad.ok, "非 res:///user:// 绝对路径应拒绝。")


## G06 无确认 token 拒绝 + token 一次性 + 未注入 UndoRedo 拒绝。
func _test_g06_confirmation_token_required() -> void:
	const NAME: String = "G06_确认token"
	var service: RefCounted = _ServiceScript.new()
	var made: Dictionary = _make_tileset(null)
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	made.atlas.texture = old_png.tex
	ResourceSaver.save(made.ts, made.path)
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var ur: UndoRedo = UndoRedo.new()
	var bad: Dictionary = service.apply(999, ur)
	_check(NAME, not bad.ok and String(bad.reason).contains("token"), "错误 token 应拒绝。")
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok, "分析应成功：%s" % String(plan.reason))
	bad = service.apply(int(plan.token), null)
	_check(NAME, not bad.ok and String(bad.reason).contains("UndoRedo"), "未注入管理器应拒绝。")
	bad = service.apply(int(plan.token), ur)
	_check(NAME, not bad.ok, "已消费 token 不得二次使用。")
	plan = service.analyze(made.layer, -1, new_png.path)
	var good: Dictionary = service.apply(int(plan.token), ur)
	_check(NAME, good.ok and not bool(good.skipped), "正常链路应真实替换：%s" % String(good.reason))
	bad = service.apply(int(plan.token), ur)
	_check(NAME, not bad.ok, "成功后 token 亦作废。")


## G07 成功替换保持全部格/坐标事实。
func _test_g07_success_preserves_facts() -> void:
	const NAME: String = "G07_成功保持事实"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok, "分析应成功：%s" % String(plan.reason))
	var ur: UndoRedo = UndoRedo.new()
	var result: Dictionary = service.apply(int(plan.token), ur)
	_check(NAME, result.ok, "替换应成功：%s" % String(result.reason))
	_check(NAME, made.atlas.texture.resource_path == new_png.path, "内存纹理应已替换。")
	# 事实保持：tiles / 动画 / alternative / custom data / source_id / 资源路径。
	_check(NAME, made.atlas.get_tiles_count() == 4, "tile 数应保持 4，实际 %d。" % made.atlas.get_tiles_count())
	_check(
		NAME,
		made.atlas.has_tile(Vector2i(0, 0)) and made.atlas.has_tile(Vector2i(1, 0)) and made.atlas.has_tile(Vector2i(3, 3)),
		"已用 atlas 坐标应原样保持。"
	)
	_check(
		NAME,
		made.atlas.get_tile_animation_columns(Vector2i(0, 1)) == 2
			and made.atlas.get_tile_animation_frames_count(Vector2i(0, 1)) == 3,
		"动画帧布局应保持。"
	)
	_check(NAME, made.atlas.get_alternative_tiles_count(Vector2i(0, 0)) == 2, "alternative 应保持（0 + 1）。")
	_check(
		NAME,
		int(made.atlas.get_tile_data(Vector2i(0, 0), 0).get_custom_data("meta")) == 7,
		"custom data 应保持。"
	)
	_check(NAME, made.ts.get_source_count() == 1 and made.ts.get_source_id(0) == 0, "source_id 应保持。")
	_check(NAME, made.ts.resource_path == made.path, "TileSet 资源路径应保持。")
	var on_disk: String = FileAccess.get_file_as_string(made.path)
	_check(NAME, on_disk.contains("new_atlas.png"), "落盘 .tres 应引用新纹理。")
	_check(NAME, not on_disk.contains("old_atlas.png"), "落盘 .tres 不应再引用旧纹理。")


## G08 undo/redo 双向写盘。
func _test_g08_undo_redo_both_persist() -> void:
	const NAME: String = "G08_撤销重做双向保存"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	var ur: UndoRedo = UndoRedo.new()
	service.apply(int(plan.token), ur)
	ur.undo()
	_check(
		NAME,
		made.atlas.texture.resource_path == old_png.path,
		"undo 后内存应恢复旧纹理：实际 %s，期望 %s。" % [made.atlas.texture.resource_path, old_png.path]
	)
	var disk: String = FileAccess.get_file_as_string(made.path)
	_check(
		NAME,
		disk.contains("old_atlas.png") and not disk.contains("new_atlas.png"),
		"undo 应把旧纹理写回同一 .tres。"
	)
	ur.redo()
	_check(NAME, made.atlas.texture.resource_path == new_png.path, "redo 后内存应恢复新纹理。")
	disk = FileAccess.get_file_as_string(made.path)
	_check(
		NAME,
		disk.contains("new_atlas.png") and not disk.contains("old_atlas.png"),
		"redo 应把新纹理写回同一 .tres。"
	)


## G09 保存失败回滚。
func _test_g09_save_failure_rolls_back() -> void:
	const NAME: String = "G09_失败回滚"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var ur: UndoRedo = UndoRedo.new()
	# 先成功一次并 undo，保证磁盘当前为旧纹理。
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	service.apply(int(plan.token), ur)
	ur.undo()
	var before_disk: String = FileAccess.get_file_as_string(made.path)
	# 注入失败后端后再替换。
	service.set_save_backend(func(resource, path): return ERR_FILE_CANT_WRITE)
	plan = service.analyze(made.layer, -1, new_png.path)
	var bad: Dictionary = service.apply(int(plan.token), ur)
	_check(NAME, not bad.ok, "写盘失败必须报错，不得假成功。")
	_check(NAME, String(bad.reason).contains("回滚"), "失败原因应说明已回滚：%s" % String(bad.reason))
	_check(NAME, made.atlas.texture.resource_path == old_png.path, "失败后内存纹理应回滚为旧值。")
	_check(NAME, FileAccess.get_file_as_string(made.path) == before_disk, "失败后磁盘内容应保持写盘前状态。")
	# 恢复真实后端后同一操作应成功。
	service.clear_save_backend()
	plan = service.analyze(made.layer, -1, new_png.path)
	var good: Dictionary = service.apply(int(plan.token), ur)
	_check(NAME, good.ok, "恢复后端后重试应成功：%s" % String(good.reason))


## G10 替换绝不写 .tscn。
func _test_g10_no_tscn_writes() -> void:
	const NAME: String = "G10_无tscn写"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	var scene_path: String = _write_fake_scene(
		"watched.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n[node name="Wall" type="TileMapLayer"]\ntile_set = ExtResource("1_w")\n' % made.path
	)
	var before: String = FileAccess.get_file_as_string(scene_path)
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	var ur: UndoRedo = UndoRedo.new()
	service.apply(int(plan.token), ur)
	ur.undo()
	ur.redo()
	_check(
		NAME,
		FileAccess.get_file_as_string(scene_path) == before,
		"apply/undo/redo 后引用场景必须逐字节不变。"
	)


## G11 通知刷新：每次成功写盘触发一次。
func _test_g11_refresh_notifications() -> void:
	const NAME: String = "G11_通知刷新"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var counter: Dictionary = {count = 0}
	service.set_refresh_callable(func() -> void: counter.count += 1)
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	var ur: UndoRedo = UndoRedo.new()
	service.apply(int(plan.token), ur)
	_check(NAME, int(counter.count) == 1, "apply 成功应触发一次刷新，实际 %d。" % int(counter.count))
	ur.undo()
	_check(NAME, int(counter.count) == 2, "undo 成功应再触发一次刷新，实际 %d。" % int(counter.count))
	ur.redo()
	_check(NAME, int(counter.count) == 3, "redo 成功应再触发一次刷新，实际 %d。" % int(counter.count))


## G12 新旧纹理相同跳过。
func _test_g12_same_texture_skips() -> void:
	const NAME: String = "G12_相同纹理跳过"
	var service: RefCounted = _ServiceScript.new()
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	var plan: Dictionary = service.analyze(made.layer, -1, old_png.path)
	_check(NAME, plan.ok, "用旧纹理路径分析应成功。")
	var result: Dictionary = service.apply(int(plan.token), UndoRedo.new())
	_check(
		NAME,
		result.ok and bool(result.skipped),
		"相同纹理应跳过且不算失败：%s（old=%s new=%s）" % [
			String(result.reason),
			made.atlas.texture.resource_path,
			old_png.path,
		]
	)


## G15 不可读场景可观察且阻断：scanner 结构化错误 → analyze 拒绝不发 token → apply 前重扫拦截。
func _test_g15_scan_errors_block() -> void:
	const NAME: String = "G15_不可读场景阻断"
	var scanner: RefCounted = _ScannerScript.new()
	scanner.set_scan_roots(PackedStringArray([_BROKEN_DIR]))
	var empty_scene: String = _write_scene_in(_BROKEN_DIR, "broken.tscn", "")
	var made: Dictionary = _make_tileset(null)
	var scanned: Dictionary = scanner.scan(made.path, "")
	_check(NAME, not bool(scanned.ok), "空场景文件应令扫描 ok=false。")
	_check(
		NAME,
		scanned.errors.size() == 1 and String(scanned.errors[0].path) == empty_scene,
		"错误应记录场景路径，实际：%s" % str(scanned.errors)
	)
	_check(NAME, String(scanned.errors[0].reason) != "", "错误应记录原因。")
	_check(NAME, scanned.references.is_empty(), "不可读场景不得计入引用。")
	# 打不开的扫描根同样可观察（记录根路径与原因）。
	scanner.set_scan_roots(PackedStringArray([_TEST_DIR + "/nonexistent_root"]))
	var root_scan: Dictionary = scanner.scan(made.path, "")
	_check(
		NAME,
		not bool(root_scan.ok) and String(root_scan.errors[0].path).contains("nonexistent_root"),
		"不可打开的扫描根应记错误与路径。"
	)
	# 服务贯通：analyze 拒绝、不发 token、原因含场景路径（不可静默跳过）。
	var service: RefCounted = _ServiceScript.new()
	service.set_scene_scan_roots(PackedStringArray([_BROKEN_DIR]))
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var denied: Dictionary = service.analyze(made.layer, -1, new_png.path)
	_check(
		NAME,
		not denied.ok and String(denied.reason).contains("broken.tscn"),
		"analyze 应拒绝并指明不可读场景：%s" % String(denied.reason)
	)
	_check(NAME, not denied.has("token"), "扫描失败不得发放 token。")
	# apply 侧拦截：分析成功后出现不可读场景 → 拒绝且 token 作废；清理后重新分析恢复。
	var service2: RefCounted = _ServiceScript.new()
	service2.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	_write_scene_in(
		_SCENES_DIR,
		"g15_watch.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	var plan: Dictionary = service2.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok, "干净根下分析应成功：%s" % String(plan.reason))
	var late_empty: String = _write_scene_in(_SCENES_DIR, "late_empty.tscn", "")
	var blocked: Dictionary = service2.apply(int(plan.token), UndoRedo.new())
	_check(
		NAME,
		not blocked.ok and String(blocked.reason).contains("late_empty.tscn"),
		"apply 前重扫失败应拒绝并指明场景：%s" % String(blocked.reason)
	)
	_check(NAME, not service2.apply(int(plan.token), UndoRedo.new()).ok, "被阻断的 token 亦已作废。")
	DirAccess.remove_absolute(late_empty)
	plan = service2.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok, "清理不可读场景后重新分析应成功：%s" % String(plan.reason))


## G16 分析后引用新增/删除 → apply 拒绝（引用已变化）；重新分析纳入新快照后恢复。
func _test_g16_reference_drift_rejected() -> void:
	const NAME: String = "G16_引用漂移拒绝"
	var service: RefCounted = _ServiceScript.new()
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var scene_a: String = _write_fake_scene(
		"g16_a.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok and plan.affected_scenes.has(scene_a), "分析应成功并命中引用场景。")
	# 新增引用：apply 拒绝、提示重新分析、不改纹理、token 作废。
	var scene_b: String = _write_fake_scene(
		"g16_b.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	var denied: Dictionary = service.apply(int(plan.token), UndoRedo.new())
	_check(
		NAME,
		not denied.ok and String(denied.reason).contains("引用已变化"),
		"新增引用应拒绝并要求重新分析：%s" % String(denied.reason)
	)
	_check(NAME, made.atlas.texture == old_png.tex, "拒绝时不得改动纹理。")
	_check(NAME, not service.apply(int(plan.token), UndoRedo.new()).ok, "漂移拒绝后 token 作废。")
	# 重新分析纳入新引用后恢复可替换。
	plan = service.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok and plan.affected_scenes.has(scene_b), "重新分析应纳入新增引用。")
	var good: Dictionary = service.apply(int(plan.token), UndoRedo.new())
	_check(NAME, good.ok, "重新分析后替换应成功：%s" % String(good.reason))
	# 删除引用：同样拒绝并要求重新分析。
	plan = service.analyze(made.layer, -1, old_png.path)
	DirAccess.remove_absolute(scene_b)
	var gone: Dictionary = service.apply(int(plan.token), UndoRedo.new())
	_check(
		NAME,
		not gone.ok and String(gone.reason).contains("引用已变化"),
		"删除引用应拒绝并要求重新分析。"
	)


## G17 token 绑定：分析后图集源布局变化 → apply 拒绝并要求重新分析，token 作废。
func _test_g17_token_binding_guards() -> void:
	const NAME: String = "G17_token绑定"
	var service: RefCounted = _ServiceScript.new()
	service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	var made: Dictionary = _make_tileset(old_png.tex)
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var plan: Dictionary = service.analyze(made.layer, -1, new_png.path)
	_check(NAME, plan.ok, "分析应成功：%s" % String(plan.reason))
	made.ts.remove_source(0)
	var denied: Dictionary = service.apply(int(plan.token), UndoRedo.new())
	_check(
		NAME,
		not denied.ok and String(denied.reason).contains("重新分析"),
		"图集源变化应拒绝并要求重新分析：%s" % String(denied.reason)
	)
	_check(NAME, not service.apply(int(plan.token), UndoRedo.new()).ok, "绑定拒绝后 token 作废。")


## G13 面板最小装配与端到端。
func _test_g13_panel_minimal_assembly() -> void:
	const NAME: String = "G13_面板装配"
	var dock: VBoxContainer = _DockScene.instantiate() as VBoxContainer
	root.add_child(dock)
	dock._ready()
	_check(
		NAME,
		dock._tileset_panel != null and is_instance_valid(dock._tileset_panel),
		"Dock 应创建 TileSet 替换子面板。"
	)
	var ur: UndoRedo = UndoRedo.new()
	dock.set_editor_undo_redo(ur)
	_check(NAME, dock._tileset_panel._editor_undo_redo == ur, "Dock 应把 UndoRedo 转交给 TileSet 面板。")
	# 选择转发：TileMapLayer 生效，普通节点清空。
	var made: Dictionary = _make_tileset(null)
	root.add_child(made.layer)
	dock.show_selection([made.layer])
	_check(NAME, dock._tileset_panel._layer == made.layer, "选中 TileMapLayer 应转发到面板。")
	var probe: Node2D = Node2D.new()
	dock.show_selection([probe])
	_check(NAME, dock._tileset_panel._layer == null, "非 TileMapLayer 选择应清空面板目标。")
	probe.free()
	dock.show_selection([made.layer])
	# 端到端：分析 → 确认 → 替换。
	var old_png: Dictionary = _make_png("old_atlas.png", 256, 64, Color(0.2, 0.2, 0.2))
	made.atlas.texture = old_png.tex
	ResourceSaver.save(made.ts, made.path)
	var watch_scene: String = _write_fake_scene(
		"g13_watch.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	var new_png: Dictionary = _make_png("new_atlas.png", 256, 64, Color(0.1, 0.1, 0.5))
	var panel: VBoxContainer = dock._tileset_panel
	# 面板服务默认扫描 res://；测试注入 fixture 场景目录以获得非空影响列表。
	panel._service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	panel._path_edit.text = new_png.path
	panel._on_analyze_pressed()
	_check(NAME, panel._result_label.text.contains(made.path), "分析结果应展示共享 .tres 路径。")
	_check(NAME, panel._result_label.text.contains(watch_scene), "分析结果应列出受影响场景。")
	_check(NAME, not panel._confirm_box.disabled, "分析成功后应启用知情确认勾选。")
	_check(NAME, panel._apply_button.disabled, "未勾选确认前替换按钮应禁用。")
	panel._on_confirm_toggled(true)
	_check(NAME, not panel._apply_button.disabled, "勾选确认后替换按钮应可用。")
	panel._on_apply_pressed()
	_check(NAME, made.atlas.texture.resource_path == new_png.path, "面板端到端替换应成功写内存。")
	_check(NAME, FileAccess.get_file_as_string(made.path).contains("new_atlas.png"), "面板端到端替换应写盘。")
	_check(NAME, panel._token == -1 and panel._apply_button.disabled, "替换后 token 应失效且按钮回禁用。")
	# 引用漂移显示：分析→新增引用场景→面板替换被拒并提示重新分析，纹理不变。
	panel._service.set_scene_scan_roots(PackedStringArray([_SCENES_DIR]))
	panel._path_edit.text = old_png.path
	panel._on_analyze_pressed()
	_write_fake_scene(
		"g13_drift.tscn",
		'[gd_scene format=3]\n[ext_resource type="TileSet" path="%s" id="1_w"]\n' % made.path
	)
	panel._on_confirm_toggled(true)
	panel._on_apply_pressed()
	_check(NAME, panel._status_label.text.contains("引用已变化"), "面板应显示「引用已变化，请重新分析」。")
	_check(NAME, made.atlas.texture.resource_path == new_png.path, "漂移拒绝时面板不得改动纹理。")
	# 无管理器：清空注入后明确失败。
	dock.set_editor_undo_redo(null)
	var plan: Dictionary = panel._service.analyze(made.layer, -1, old_png.path)
	panel._token = int(plan.token)
	panel._confirm_box.disabled = false
	panel._on_confirm_toggled(true)
	panel._on_apply_pressed()
	_check(NAME, panel._status_label.text.contains("UndoRedo"), "无管理器时状态应明确失败原因。")
	_check(NAME, made.atlas.texture.resource_path == new_png.path, "无管理器时不得改动纹理。")
	# 扫描错误显示：不可读场景路径上屏；确认框与替换按钮保持禁用，不得假确认。
	panel._service.set_scene_scan_roots(PackedStringArray([_BROKEN_DIR]))
	panel._path_edit.text = old_png.path
	panel._on_analyze_pressed()
	_check(NAME, panel._status_label.text.contains("broken.tscn"), "面板应显示扫描错误场景路径。")
	_check(NAME, panel._confirm_box.disabled, "扫描失败后确认框必须保持禁用。")
	_check(NAME, panel._apply_button.disabled, "扫描失败后替换按钮必须保持禁用。")
	made.layer.free()
	dock.free()


## G14 真实资源零污染。
func _test_g14_real_files_untouched() -> void:
	const NAME: String = "G14_真实资源零污染"
	for path in _real_file_hashes:
		var current: String = FileAccess.get_file_as_string(path)
		_check(
			NAME,
			current.sha256_text() == String(_real_file_hashes[path]),
			"%s 内容在测试全程不得被修改。" % path
		)
