extends SceneTree

## S3-08A ChapterProgression 纯数据模块单元测试（0/1/N 关卡选择/推进/终点合同）。
## 覆盖：①0 关章节安全——无可选关/无当前路径/advance 直接落章节完成终点/选择拒绝；
##   ②1 关章节——构造自动选中第 0 关、无下一关、完成即章节完成终点且索引停在最后一关（R 重玩事实）；
##   ③N 关章节——peek 预读不推进、advance 推进、合法选择跳关、越界选择原子拒绝状态不变；
##   ④入参数组拷贝独立（调用方后续修改不影响章节事实）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ChapterProgression: GDScript = preload(
	"res://gameplay/chapter/chapter_progression.gd"
)

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_zero_levels_safe()
	_test_02_single_level_endpoint()
	_test_03_multi_levels_select_and_advance()
	_test_04_input_array_independence()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====


func _check(group: String, condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[%s] %s" % [group, reason])


func _report() -> void:
	print("chapter_progression_test：%d 组断言 %d，失败 %d。" % [_checks, _checks, _failures.size()])
	for failure: String in _failures:
		print("  失败：%s" % [failure])


# ===== 用例 =====


## 1. 0 关章节安全：无当前关、路径为空、peek 无下一关、advance 落章节完成终点、任何选择拒绝。
func _test_01_zero_levels_safe() -> void:
	const NAME: String = "01_0关安全"
	var empty_paths: Array[String] = []
	var progression: Variant = _ChapterProgression.new(empty_paths)
	_check(NAME, progression.get_level_count() == 0, "0 关章节数量应为 0。")
	_check(NAME, progression.get_current_index() == -1, "0 关章节当前索引应为 -1。")
	_check(NAME, progression.get_current_level_path() == "", "0 关章节当前路径应为空串。")
	_check(NAME, progression.peek_next_level_path() == "", "0 关章节预读下一关应为空串。")
	_check(NAME, not progression.is_chapter_complete(), "0 关章节初始不应标记完成。")
	_check(NAME, progression.advance_to_next_level() == false, "0 关章节 advance 应返回 false。")
	_check(NAME, progression.is_chapter_complete(), "0 关章节 advance 后应落章节完成终点。")
	_check(NAME, not progression.select(0), "0 关章节 select(0) 应越界拒绝。")
	_check(NAME, not progression.select(-1), "0 关章节 select(-1) 应越界拒绝。")


## 2. 1 关章节：构造自动选中第 0 关；无下一关；完成即章节完成终点且索引停在最后一关（保持重玩事实）。
func _test_02_single_level_endpoint() -> void:
	const NAME: String = "02_单关终点"
	var paths: Array[String] = ["res://levels/campaign/ray_chapter/level_ray_001.tscn"]
	var progression: Variant = _ChapterProgression.new(paths)
	_check(NAME, progression.get_level_count() == 1, "1 关章节数量应为 1。")
	_check(NAME, progression.get_current_index() == 0, "1 关章节构造应自动选中第 0 关。")
	_check(NAME, progression.get_current_level_path() == "res://levels/campaign/ray_chapter/level_ray_001.tscn", "1 关章节当前路径应为唯一关卡路径。")
	_check(NAME, progression.select(0), "1 关章节 select(0) 应合法。")
	_check(NAME, not progression.select(1), "1 关章节 select(1) 应越界拒绝。")
	_check(NAME, progression.peek_next_level_path() == "", "1 关章节预读下一关应为空串。")
	_check(NAME, not progression.is_chapter_complete(), "完成前不应标记章节完成。")
	_check(NAME, progression.advance_to_next_level() == false, "1 关章节完成推进应返回 false（无下一关）。")
	_check(NAME, progression.is_chapter_complete(), "1 关章节完成后应落章节完成终点。")
	_check(NAME, progression.get_current_index() == 0, "章节完成后索引应停在第 0 关（最后一关，保持重玩事实）。")
	_check(NAME, progression.get_current_level_path() == "res://levels/campaign/ray_chapter/level_ray_001.tscn", "章节完成后当前路径应保持最后一关。")


## 3. N 关章节：peek 预读不推进、advance 推进到下一关、合法选择跳关、越界/负数选择原子拒绝状态不变。
func _test_03_multi_levels_select_and_advance() -> void:
	const NAME: String = "03_N关选择与推进"
	var paths: Array[String] = [
		"res://levels/campaign/ray_chapter/level_ray_001.tscn",
		"res://levels/templates/examples/level_template_editing_example.tscn",
		"res://levels/templates/level_template.tscn",
	]
	var progression: Variant = _ChapterProgression.new(paths)
	_check(NAME, progression.get_level_count() == 3, "N 关章节数量应为 3。")
	_check(NAME, progression.get_current_index() == 0, "N 关章节构造应自动选中第 0 关。")
	_check(NAME, progression.peek_next_level_path() == paths[1], "预读下一关应为第 1 关路径。")
	_check(NAME, progression.get_current_index() == 0, "预读不应推进索引。")
	_check(NAME, progression.advance_to_next_level() == true, "完成第 0 关推进应返回 true。")
	_check(NAME, progression.get_current_index() == 1, "推进后索引应为 1。")
	_check(NAME, progression.get_current_level_path() == paths[1], "推进后当前路径应为第 1 关。")
	_check(NAME, not progression.is_chapter_complete(), "中间关完成不应标记章节完成。")
	_check(NAME, progression.select(2), "select(2) 应合法跳关。")
	_check(NAME, progression.get_current_index() == 2, "跳关后索引应为 2。")
	_check(NAME, progression.get_current_level_path() == paths[2], "跳关后当前路径应为第 2 关。")
	_check(NAME, not progression.select(3), "select(3) 应越界拒绝。")
	_check(NAME, not progression.select(-1), "select(-1) 应越界拒绝。")
	_check(NAME, progression.get_current_index() == 2, "被拒选择应原子保持索引不变。")
	_check(NAME, progression.get_current_level_path() == paths[2], "被拒选择应原子保持当前路径不变。")
	_check(NAME, progression.peek_next_level_path() == "", "最后一关预读下一关应为空串。")
	_check(NAME, progression.advance_to_next_level() == false, "最后一关完成推进应返回 false。")
	_check(NAME, progression.is_chapter_complete(), "最后一关完成后应落章节完成终点。")
	_check(NAME, progression.get_current_index() == 2, "章节完成后索引应停在最后一关。")


## 4. 入参数组拷贝独立：构造后修改调用方数组不影响章节事实。
func _test_04_input_array_independence() -> void:
	const NAME: String = "04_入参拷贝独立"
	var paths: Array[String] = [
		"res://levels/campaign/ray_chapter/level_ray_001.tscn",
		"res://levels/templates/level_template.tscn",
	]
	var progression: Variant = _ChapterProgression.new(paths)
	paths.append("res://fake/should_not_appear.tscn")
	paths.remove_at(0)
	_check(NAME, progression.get_level_count() == 2, "构造后修改入参数组不应影响章节数量。")
	_check(NAME, progression.get_current_level_path() == "res://levels/campaign/ray_chapter/level_ray_001.tscn", "构造后修改入参数组不应影响当前路径。")
	_check(NAME, progression.peek_next_level_path() == "res://levels/templates/level_template.tscn", "构造后修改入参数组不应影响预读路径。")
