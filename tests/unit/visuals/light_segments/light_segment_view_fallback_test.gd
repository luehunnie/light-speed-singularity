extends SceneTree

## LightSegmentView fallback 16px 光束几何专项测试（D7-4 B4b-2）。
## 覆盖：fallback 水平/垂直/`\``/`/` 四方向可见厚度=16、不再出现 64×64 整块亮色方块、artwork profile 可覆盖 fallback、
##   八方向 rotation = Vector2(direction).angle()、斜向为角到角连续窄束（长度 CELL_SIZE*√2）、以及 View 源码不反向驱动玩法。
## 用真实 LightSegmentView 场景实例（手动 _ready 解析 @onready + set_direction 触发 refresh）验证实际 fallback 几何，
##   非仅场景文件存在性。通过 preload 引用避开全局 class_name 缓存问题；由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。


const _ViewScene: PackedScene = preload("res://gameplay/visuals/light_segments/light_segment_view.tscn")
const _ViewScript: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_view.gd")
const _Profile: GDScript = preload("res://gameplay/visuals/light_segments/light_segment_visual_profile.gd")
const _GridMetrics: GDScript = preload("res://gameplay/grid/grid_metrics.gd")


## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


func _initialize() -> void:
	await process_frame
	_test_01_horizontal_thickness_16()
	_test_02_vertical_thickness_16()
	_test_03_slash_diagonal_narrow_beam()
	_test_04_backslash_diagonal_narrow_beam()
	_test_05_no_64x64_block_any_direction()
	_test_06_eight_directions_rotation()
	_test_07_artwork_profile_overrides_fallback()
	_test_08_diagonal_length_corner_to_corner()
	_test_09_source_does_not_touch_ray_gameplay()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 实例化一个 LightSegmentView 并手动 _ready（解析 @onready + 首次 refresh）；调用方负责 free。
func _make_view() -> _ViewScript:
	var view: _ViewScript = _ViewScene.instantiate()
	view._ready()
	return view


## 取 PlaceholderBlock 的本地尺寸（offset_right-left, offset_bottom-top）。
func _placeholder_size(view: _ViewScript) -> Vector2:
	var pb: ColorRect = view.get_node_or_null("PlaceholderBlock")
	return Vector2(pb.offset_right - pb.offset_left, pb.offset_bottom - pb.offset_top)


## 取 PlaceholderBlock rotation。
func _placeholder_rotation(view: _ViewScript) -> float:
	var pb: ColorRect = view.get_node_or_null("PlaceholderBlock")
	return pb.rotation


# ===== 测试用例 =====

## 1.（spec 十三.1）水平 fallback 可见厚度=16：RIGHT 方向占位块本地高度=16（厚度），rotation=0。
func _test_01_horizontal_thickness_16() -> void:
	const NAME: String = "01_水平fallback厚度16"
	var view: _ViewScript = _make_view()
	view.set_direction(Vector2i.RIGHT)
	var size: Vector2 = _placeholder_size(view)
	_check(NAME, is_equal_approx(size.y, 16.0), "RIGHT fallback 厚度（本地 y）期望 16，实际 %f。" % [size.y])
	_check(NAME, is_equal_approx(size.x, 64.0), "RIGHT fallback 长度（本地 x）期望 64，实际 %f。" % [size.x])
	_check(NAME, is_zero_approx(_placeholder_rotation(view)), "RIGHT rotation 期望 0，实际 %f。" % [_placeholder_rotation(view)])
	view.free()


## 2.（spec 十三.2）垂直 fallback 厚度=16：DOWN 方向占位块本地高度=16、rotation=π/2（视觉为 16 宽×64 高竖束）。
func _test_02_vertical_thickness_16() -> void:
	const NAME: String = "02_垂直fallback厚度16"
	var view: _ViewScript = _make_view()
	view.set_direction(Vector2i.DOWN)
	var size: Vector2 = _placeholder_size(view)
	_check(NAME, is_equal_approx(size.y, 16.0), "DOWN fallback 厚度（本地 y）期望 16，实际 %f。" % [size.y])
	_check(NAME, is_equal_approx(_placeholder_rotation(view), PI / 2.0), "DOWN rotation 期望 π/2，实际 %f。" % [_placeholder_rotation(view)])
	view.free()


## 3.（spec 十三.3）`/` 斜向为窄束：UP_RIGHT(1,-1) 占位块厚度=16、rotation=-π/4、长度≈CELL_SIZE*√2。
func _test_03_slash_diagonal_narrow_beam() -> void:
	const NAME: String = "03_斜向slash窄束"
	var view: _ViewScript = _make_view()
	view.set_direction(Vector2i(1, -1))
	var size: Vector2 = _placeholder_size(view)
	_check(NAME, is_equal_approx(size.y, 16.0), "UP_RIGHT 斜向厚度期望 16，实际 %f。" % [size.y])
	_check(NAME, is_equal_approx(_placeholder_rotation(view), Vector2(Vector2i(1, -1)).angle()), "UP_RIGHT rotation 期望 angle((1,-1))。")
	_check(NAME, is_equal_approx(size.x, float(_GridMetrics.CELL_SIZE) * sqrt(2.0)), "UP_RIGHT 斜向长度期望 CELL_SIZE*√2，实际 %f。" % [size.x])
	view.free()


## 4.（spec 十三.4）`\` 斜向为窄束：DOWN_RIGHT(1,1) 占位块厚度=16、rotation=π/4、长度≈CELL_SIZE*√2。
func _test_04_backslash_diagonal_narrow_beam() -> void:
	const NAME: String = "04_斜向backslash窄束"
	var view: _ViewScript = _make_view()
	view.set_direction(Vector2i(1, 1))
	var size: Vector2 = _placeholder_size(view)
	_check(NAME, is_equal_approx(size.y, 16.0), "DOWN_RIGHT 斜向厚度期望 16，实际 %f。" % [size.y])
	_check(NAME, is_equal_approx(_placeholder_rotation(view), Vector2(Vector2i(1, 1)).angle()), "DOWN_RIGHT rotation 期望 angle((1,1))。")
	_check(NAME, is_equal_approx(size.x, float(_GridMetrics.CELL_SIZE) * sqrt(2.0)), "DOWN_RIGHT 斜向长度期望 CELL_SIZE*√2，实际 %f。" % [size.x])
	view.free()


## 5.（spec 十三.5）任一方向都不再出现 64×64 整块：厚度恒 16 ⇒ 本地 y 永不为 64。
func _test_05_no_64x64_block_any_direction() -> void:
	const NAME: String = "05_无64x64整块"
	var dirs: Array[Vector2i] = [
		Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN,
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	for d: Vector2i in dirs:
		var view: _ViewScript = _make_view()
		view.set_direction(d)
		var size: Vector2 = _placeholder_size(view)
		# 厚度（本地 y）恒 16 ⇒ 永不出现 64×64 方块（方块要求 y==64）。
		_check(NAME, not is_equal_approx(size.y, 64.0), "方向 %s fallback 厚度不应为 64（不得恢复 64×64 方块），实际 y=%f。" % [str(d), size.y])
		_check(NAME, is_equal_approx(size.y, 16.0), "方向 %s fallback 厚度期望 16，实际 y=%f。" % [str(d), size.y])
		view.free()


## 6.（spec 九）八方向 rotation = Vector2(direction).angle()：fallback 光束朝向与 ParticleView 同一角度来源。
func _test_06_eight_directions_rotation() -> void:
	const NAME: String = "06_八方向rotation"
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	]
	for d: Vector2i in dirs:
		var view: _ViewScript = _make_view()
		view.set_direction(d)
		_check(NAME, is_equal_approx(_placeholder_rotation(view), Vector2(d).angle()), "方向 %s rotation 期望 %f，实际 %f。" % [str(d), Vector2(d).angle(), _placeholder_rotation(view)])
		view.free()


## 7.（spec 十三.6）artwork profile 可覆盖 fallback：设 horizontal_texture 后 Artwork 显示、PlaceholderBlock 隐藏。
func _test_07_artwork_profile_overrides_fallback() -> void:
	const NAME: String = "07_artwork覆盖fallback"
	var view: _ViewScript = _make_view()
	view.set_direction(Vector2i.RIGHT)
	# 先确认 fallback 状态：PlaceholderBlock 可见、Artwork 隐藏。
	var pb: ColorRect = view.get_node_or_null("PlaceholderBlock")
	var art: TextureRect = view.get_node_or_null("Artwork")
	if not _check(NAME, pb != null and art != null, "PlaceholderBlock 与 Artwork 子节点应存在。"):
		view.free()
		return
	_check(NAME, pb.visible == true, "前置：无 profile 时 PlaceholderBlock 应可见。")
	_check(NAME, art.visible == false, "前置：无 profile 时 Artwork 应隐藏。")
	# 注入 horizontal_texture → refresh 后 Artwork 显示、PlaceholderBlock 隐藏。
	var profile: _Profile = _Profile.new()
	var tex: PlaceholderTexture2D = PlaceholderTexture2D.new()
	tex.set_size(Vector2i(64, 64))
	profile.horizontal_texture = tex
	view.set_profile(profile)
	_check(NAME, art.visible == true, "设 horizontal_texture 后 Artwork 应可见。")
	_check(NAME, art.texture == tex, "Artwork.texture 应为注入的 horizontal_texture。")
	_check(NAME, pb.visible == false, "Artwork 显示后 PlaceholderBlock 应隐藏（fallback 被覆盖）。")
	# 移除 profile → 回到 fallback：Artwork 隐藏、PlaceholderBlock 可见（且无残留旧纹理）。
	view.set_profile(null)
	_check(NAME, art.visible == false, "移除 profile 后 Artwork 应隐藏。")
	_check(NAME, art.texture == null, "移除 profile 后 Artwork.texture 应清空（无残留旧图）。")
	_check(NAME, pb.visible == true, "移除 profile 后 PlaceholderBlock 应可见（回退 fallback）。")
	view.free()


## 8.（spec 十二）斜向 fallback 角到角连续：长度严格 = CELL_SIZE*√2（≈90.51），保证相邻斜格在共享角相接。
func _test_08_diagonal_length_corner_to_corner() -> void:
	const NAME: String = "08_斜向角到角连续"
	var expected_diag: float = float(_GridMetrics.CELL_SIZE) * sqrt(2.0)
	for d: Vector2i in [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		var view: _ViewScript = _make_view()
		view.set_direction(d)
		var size: Vector2 = _placeholder_size(view)
		_check(NAME, is_equal_approx(size.x, expected_diag), "斜向 %s 长度期望 CELL_SIZE*√2≈%f，实际 %f（角到角连续）。" % [str(d), expected_diag, size.x])
		view.free()
	# 正交长度仍 = CELL_SIZE（覆盖一格，相邻格在共享边中点相接）。
	for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN]:
		var view: _ViewScript = _make_view()
		view.set_direction(d)
		var size: Vector2 = _placeholder_size(view)
		_check(NAME, is_equal_approx(size.x, float(_GridMetrics.CELL_SIZE)), "正交 %s 长度期望 CELL_SIZE=64，实际 %f。" % [str(d), size.x])
		view.free()


## 9.（spec 二十）View 源码不触碰 Ray gameplay：无 RayExecutionModule / FireRequest / 传播逻辑 mutation 令牌；不改逻辑格 64×64。
func _test_09_source_does_not_touch_ray_gameplay() -> void:
	const NAME: String = "09_View源码不触Ray_gameplay"
	var src: String = FileAccess.get_file_as_string("res://gameplay/visuals/light_segments/light_segment_view.gd")
	var forbidden_tokens: Array = [
		"RayExecutionModule", "FireRequest", "execute_ray", "activate_crystal",
		"set_cell", "world_to_cell", "begin_pulse", "request_fire",
	]
	for token: String in forbidden_tokens:
		_check(NAME, src.find(token) == -1, "LightSegmentView 源码不应含 Ray gameplay 令牌：%s" % token)
	# FALLBACK_THICKNESS_PX 冻结 16（逻辑格仍由 GridMetrics.CELL_SIZE=64 决定，本视图不复制 64）。
	_check(NAME, _ViewScript.FALLBACK_THICKNESS_PX == 16, "FALLBACK_THICKNESS_PX 期望 16，实际 %d。" % [_ViewScript.FALLBACK_THICKNESS_PX])


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。返回 ok 供调用方决定后续依赖断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要并退出。
func _report() -> void:
	var group_count: int = 9
	var passed_checks: int = _checks - _failures.size()
	print("==== LightSegmentView fallback 16px 光束几何专项测试摘要（D7-4 B4b-2）====")
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
