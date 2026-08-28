extends SceneTree

## S3-08A 章节推进 Host 集成测试（0/1/N 关卡选择/装载/通关推进/安全终点全链）。
##
## 实例化真实 gameplay/runtime/level_runtime_host.tscn，入树前注入 ChapterProgression（S3-08A 合同）：
##   01 单关兼容回归（不绑章节）：Host 行为与既有单关现状一致（LevelRoot=ray_001，start_run valid）；
##   02 0 关章节安全：无 LevelRoot、无崩溃、start_run 安全返回 null（初始化中止不构造虚假开始）；
##   03 N 关选择装载：select(1) 后 Host 装载所选关卡（LevelRoot scene_file_path 事实）；
##   04 1 关完成→章节完成安全终点：通关后完成标签文本「章节完成」、不换装、is_chapter_complete；
##   05 N 关完成→换装下一关：通关后旧 Host 整体释放、新 Host 装载下一关并可重新 start_run（valid）；
##   06 无效下一关路径安全失败：通关后保持当前关不推进（索引不变、不换装、无崩溃）。
##
## 多关推进用专用 headless fixture（正式单关 ray_001 作重复序列事实，不伪造第二正式关卡）。
## 禁止白盒访问私有控制器；放置经 PlacementController 公开事务入口（与 drag_flow 同一提交链）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _HOST_SCENE_PATH: String = "res://gameplay/runtime/level_runtime_host.tscn"
const _RAY_LEVEL_PATH: String = "res://levels/campaign/ray_chapter/level_ray_001.tscn"
const _EXAMPLE_LEVEL_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
# 脉冲视觉 1.0s + 章节换装 settle 1.2s，留裕量确保换装协程完成。
const _PULSE_SETTLE_MS: int = 1150
const _SWAP_SETTLE_MS: int = 1500
const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"

const _ChapterProgression: GDScript = preload("res://gameplay/chapter/chapter_progression.gd")
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	var host_scene: PackedScene = load(_HOST_SCENE_PATH) as PackedScene
	_check("00_Host场景可加载", host_scene != null, "level_runtime_host.tscn 加载失败。")
	if host_scene == null:
		_report()
		quit(1)
		return
	await _test_01_single_level_compat(host_scene)
	await _test_02_zero_levels_safe(host_scene)
	await _test_03_select_load(host_scene)
	await _test_04_single_level_chapter_endpoint(host_scene)
	await _test_05_multi_level_advance_swap(host_scene)
	await _test_06_invalid_next_path_safe_failure(host_scene)
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====


func _check(group: String, condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, reason])


func _report() -> void:
	print("chapter_progression_host_test：%d 断言，失败 %d。" % [_checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % [failure])


## 实例化 Host（可选入树前注入章节推进），挂入 root 泵一帧触发真实 _enter_tree 装载与 _ready 接线。
func _ready_instance(scene: PackedScene, progression: Variant = null) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	if progression != null:
		node.set_chapter_progression(progression)
	root.add_child(node)
	await process_frame
	return node


## 等待指定毫秒（泵帧推进异步协程与 SceneTree 定时器）。
func _settle_ms(duration_ms: int) -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < duration_ms:
		await process_frame


## 纯关卡根（Host 装载实例，公开角色路径 LevelRoot）。
func _level_root(node: Node2D) -> Node2D:
	return node.get_node_or_null("LevelRoot") as Node2D


## 完成标签（Host 公开场景角色路径）。
func _complete_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/CompleteLabel") as Label


## SETUP 在 (3,3) 放置 SLASH 镜面（入射 RIGHT 反射 UP 命中水晶 (3,1)）→ start_run → fire。
func _place_start_and_fire(node: Node2D, group: String) -> void:
	var placement: Variant = node.get("_placement_controller")
	_check(group, placement != null and placement.place_from_inventory(
		_TOKEN_TYPE, Vector2i(3, 3),
		_SingleCellMirrorScript.MirrorOrientation.SLASH).is_success(),
		"SETUP 放置 (3,3) SLASH 镜面应成功。")
	node.start_run()
	node.fire_light()


## 释放实例前等待异步协程恢复；fired=true 时等脉冲视觉窗口。
func _settle_and_free(node: Node2D, fired: bool) -> void:
	if fired:
		await _settle_ms(_PULSE_SETTLE_MS)
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====


## 1. 单关兼容回归：不绑章节时 Host 行为与现状一致（装载 ray_001、start_run valid 进 READY）。
func _test_01_single_level_compat(scene: PackedScene) -> void:
	const NAME: String = "01_单关兼容回归"
	var node: Node2D = await _ready_instance(scene)
	var level: Node2D = _level_root(node)
	_check(NAME, level != null and level.scene_file_path == _RAY_LEVEL_PATH,
		"未绑章节 Host 应装载固定 level_scene=ray_001，实际 %s。" % [level.scene_file_path if level != null else "无LevelRoot"])
	var result: Variant = node.start_run()
	_check(NAME, result != null and result.is_valid(), "未绑章节 start_run 应 valid 进 READY（现状回归）。")
	await _settle_and_free(node, false)


## 2. 0 关章节安全：无 LevelRoot、Host 存活、start_run 安全返回 null（初始化中止不构造虚假开始）。
func _test_02_zero_levels_safe(scene: PackedScene) -> void:
	const NAME: String = "02_0关章节安全"
	var empty_paths: Array[String] = []
	var node: Node2D = await _ready_instance(scene, _ChapterProgression.new(empty_paths))
	_check(NAME, _level_root(node) == null, "0 关章节 Host 不应装载任何关卡。")
	_check(NAME, is_instance_valid(node) and node.is_inside_tree(), "0 关章节 Host 应存活在场景树（安全不崩溃）。")
	_check(NAME, node.start_run() == null, "0 关章节 start_run 应安全返回 null（初始化中止）。")
	await _settle_and_free(node, false)


## 3. N 关选择装载：select(1) 后 Host 装载所选关卡（LevelRoot scene_file_path 事实）。
func _test_03_select_load(scene: PackedScene) -> void:
	const NAME: String = "03_N关选择装载"
	var paths: Array[String] = [_EXAMPLE_LEVEL_PATH, _RAY_LEVEL_PATH]
	var progression: Variant = _ChapterProgression.new(paths)
	_check(NAME, progression.select(1), "select(1) 应合法。")
	var node: Node2D = await _ready_instance(scene, progression)
	var level: Node2D = _level_root(node)
	_check(NAME, level != null and level.scene_file_path == _RAY_LEVEL_PATH,
		"选择第 1 关后 Host 应装载 ray_001，实际 %s。" % [level.scene_file_path if level != null else "无LevelRoot"])
	await _settle_and_free(node, false)


## 4. 1 关完成→章节完成安全终点：通关后标签文本「章节完成」、不换装、章节完成事实成立。
func _test_04_single_level_chapter_endpoint(scene: PackedScene) -> void:
	const NAME: String = "04_单关章节完成终点"
	var paths: Array[String] = [_RAY_LEVEL_PATH]
	var progression: Variant = _ChapterProgression.new(paths)
	var node: Node2D = await _ready_instance(scene, progression)
	_place_start_and_fire(node, NAME)
	await _settle_ms(_PULSE_SETTLE_MS)
	var complete: Label = _complete_label(node)
	_check(NAME, complete != null and complete.visible, "通关后完成标签应可见。")
	_check(NAME, complete != null and complete.text == "章节完成",
		"1 关章节通关后标签文本应为「章节完成」，实际：%s。" % [complete.text if complete != null else "null"])
	_check(NAME, is_instance_valid(node) and node.is_inside_tree(), "章节完成终点应保持当前 Host（不换装）。")
	_check(NAME, root.get_child_count() == 1, "章节完成终点不应产生新 Host，实际 root 子节点 %d。" % [root.get_child_count()])
	_check(NAME, progression.is_chapter_complete(), "章节完成事实应成立。")
	await _settle_and_free(node, false)


## 5. N 关完成→换装下一关：通关后旧 Host 整体释放、新 Host 装载下一关并可重新 start_run（valid）。
func _test_05_multi_level_advance_swap(scene: PackedScene) -> void:
	const NAME: String = "05_N关换装下一关"
	var paths: Array[String] = [_RAY_LEVEL_PATH, _RAY_LEVEL_PATH]
	var progression: Variant = _ChapterProgression.new(paths)
	var node: Node2D = await _ready_instance(scene, progression)
	_place_start_and_fire(node, NAME)
	await _settle_ms(_PULSE_SETTLE_MS + _SWAP_SETTLE_MS)
	_check(NAME, not is_instance_valid(node), "换装后旧 Host 应已整体释放。")
	_check(NAME, root.get_child_count() == 1, "换装后 root 应恰有 1 个新 Host，实际 %d。" % [root.get_child_count()])
	var next_host: Node2D = root.get_child(0) as Node2D
	var level: Node2D = _level_root(next_host)
	_check(NAME, level != null and level.scene_file_path == _RAY_LEVEL_PATH,
		"新 Host 应装载下一关 ray_001，实际 %s。" % [level.scene_file_path if level != null else "无LevelRoot"])
	_check(NAME, progression.get_current_index() == 1, "换装后章节索引应推进到 1，实际 %d。" % [progression.get_current_index()])
	_check(NAME, not progression.is_chapter_complete(), "中间关完成后不应标记章节完成。")
	var result: Variant = next_host.start_run()
	_check(NAME, result != null and result.is_valid(), "新 Host start_run 应 valid（换装后完整 _ready 接线可运行）。")
	await _settle_and_free(next_host, false)


## 6. 无效下一关路径安全失败：通关后保持当前关不推进（索引不变、不换装、无崩溃）。
func _test_06_invalid_next_path_safe_failure(scene: PackedScene) -> void:
	const NAME: String = "06_无效下一关路径安全失败"
	var paths: Array[String] = [_RAY_LEVEL_PATH, "res://levels/campaign/ray_chapter/level_ray_missing_404.tscn"]
	var progression: Variant = _ChapterProgression.new(paths)
	var node: Node2D = await _ready_instance(scene, progression)
	_place_start_and_fire(node, NAME)
	await _settle_ms(_PULSE_SETTLE_MS + _SWAP_SETTLE_MS)
	_check(NAME, is_instance_valid(node) and node.is_inside_tree(), "下一关路径无效时应保持当前 Host 存活（安全失败）。")
	_check(NAME, root.get_child_count() == 1, "下一关路径无效时不应换装，实际 root 子节点 %d。" % [root.get_child_count()])
	_check(NAME, progression.get_current_index() == 0, "下一关路径无效时索引不应被消耗，实际 %d。" % [progression.get_current_index()])
	_check(NAME, not progression.is_chapter_complete(), "路径无效是安全失败，不应误标章节完成。")
	var complete: Label = _complete_label(node)
	_check(NAME, complete != null and complete.visible and complete.text != "章节完成",
		"安全失败应保持「关卡完成」通关事实，不误报章节完成，实际：%s。" % [complete.text if complete != null else "null"])
	await _settle_and_free(node, false)
