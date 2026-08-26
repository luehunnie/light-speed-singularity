extends SceneTree

## LevelRuntimeHost 集成测试（AF-07：RuntimeHost + 纯关卡 Scene + Play Current Level 基础）。
##
## 实例化真实 gameplay/runtime/level_runtime_host.tscn（装载 levels/campaign/ray_chapter/level_ray_001.tscn 纯关卡），
## 经公开入口 start_run() / fire_light() / reset_runtime() 与公开场景节点路径观测：
##   01 Host 装载与内容根解析（LevelRoot 六正式角色 / 发射器 / 水晶发现）；
##   02 Current Level Preflight（valid → READY；纯关卡内容 invalid → 拒绝启动仍 SETUP）；
##   03 发射 → 完成 → R 完整重置（水晶/完成标签/ID 稳定/重启再发射）；
##   04 R 重置库存退回与占用清理（放置后库存 0 → R 后库存恢复 / 占用清空 / 无残留节点）；
##   05 任意纯关卡动态装载（Host 脚本新实例装载 templates 编辑示例 → Preflight 通过）。
##
## 禁止白盒访问私有控制器；放置经 PlacementController 公开事务入口（与 drag_flow 同一提交链）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _HOST_SCENE_PATH: String = "res://gameplay/runtime/level_runtime_host.tscn"
const _HOST_SCRIPT_PATH: String = "res://gameplay/runtime/level_runtime_host.gd"
const _EXAMPLE_LEVEL_PATH: String = "res://levels/templates/examples/level_template_editing_example.tscn"
# 略大于生产脉冲视觉持续时间 1.0s，确保异步结束协程在释放前于活动控制器上恢复。
const _PULSE_SETTLE_MS: int = 1150
const _TOKEN_TYPE: StringName = &"basic_single_cell_mirror"

const _GridCoordinateRules: GDScript = preload("res://gameplay/grid/grid_coordinate_rules.gd")
const _SingleCellMirrorScript: GDScript = preload("res://gameplay/mechanisms/mirrors/single_cell_mirror.gd")

## 累积失败项（每项为“[组名] 原因”）。
var _failures: PackedStringArray = PackedStringArray()
## 已执行断言总数。
var _checks: int = 0


## SceneTree 初始化入口：逐用例独立实例化场景，最后统一报告并退出。
func _initialize() -> void:
	# --script 模式首帧前 root 可能未就绪，等待一帧确保 add_child 后 _ready 可触发。
	await process_frame
	var host_scene: PackedScene = load(_HOST_SCENE_PATH) as PackedScene
	_check("00_Host场景可加载", host_scene != null, "level_runtime_host.tscn 加载失败。")
	if host_scene == null:
		_report()
		quit(1)
		return
	await _test_01_host_load_and_content_root(host_scene)
	await _test_02_preflight_valid_and_invalid(host_scene)
	await _test_03_fire_complete_and_reset(host_scene)
	await _test_04_reset_inventory_restore(host_scene)
	await _test_05_dynamic_level_load()
	_check("末尾_root无残留", root.get_child_count() == 0, "测试结束 root 不应有子节点，实际 %d。" % [root.get_child_count()])
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 辅助 =====

## 实例化并挂入 root，泵一帧触发真实 _enter_tree 装载与 _ready 接线。
func _ready_instance(scene: PackedScene) -> Node2D:
	var node: Node2D = scene.instantiate() as Node2D
	root.add_child(node)
	await process_frame
	return node


## 纯关卡根（Host 装载实例，公开角色路径 LevelRoot）。
func _level_root(node: Node2D) -> Node2D:
	return node.get_node_or_null("LevelRoot") as Node2D


## 关卡光路层（纯关卡正式角色）。
func _lpl(node: Node2D) -> Node2D:
	var level: Node2D = _level_root(node)
	return level.get_node_or_null("LightPathLayer") as Node2D if level != null else null


## 库存剩余标签（公开 UI 路径）。
func _remaining_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/InventoryBar/MarginContainer/HBoxContainer/PrototypeTokenSlot/SlotMargin/SlotContent/SlotTexts/RemainingLabel") as Label


## 完成标签（公开 UI 路径）。
func _complete_label(node: Node2D) -> Label:
	return node.get_node_or_null("CanvasLayer/CompleteLabel") as Label


## 「开始运行」按钮（RunStartView 创建的公开场景角色路径）。
func _start_run_button(node: Node2D) -> Button:
	return node.get_node_or_null("CanvasLayer/StartRunButton") as Button


## 等待脉冲视觉持续时间（不复用释放，供后续仍使用实例的用例）。
func _settle_pulse() -> void:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < _PULSE_SETTLE_MS:
		await process_frame


## 释放实例前等待异步结束协程在活动控制器上恢复；fired=false 无脉冲直接释放。
func _settle_and_free(node: Node2D, fired: bool) -> void:
	if fired:
		await _settle_pulse()
	if is_instance_valid(node):
		node.free()
	await process_frame


# ===== 用例 =====

## 1. Host 装载与内容根解析：LevelRoot 为 Node2D，六正式角色为其直接子节点；发射器配置存在；
##    水晶经内容根发现恰好 1 颗且稳定 ID 保留；RuntimeObjects 初始仅 Emitter + Crystal（无运行残留）。
func _test_01_host_load_and_content_root(scene: PackedScene) -> void:
	const NAME: String = "01_Host装载与内容根"
	var node: Node2D = await _ready_instance(scene)
	var level: Node2D = _level_root(node)
	_check(NAME, level != null, "Host 应装载 LevelRoot 纯关卡实例。")
	if level == null:
		await _settle_and_free(node, false)
		return
	for role: String in ["TerrainLayer", "WallLayer", "LegalAreaLayer", "DecorationLayer"]:
		var layer: TileMapLayer = level.get_node_or_null(role) as TileMapLayer
		_check(NAME, layer != null, "纯关卡根下 %s 应存在且为 TileMapLayer。" % role)
	var runtime_objects: Node2D = level.get_node_or_null("RuntimeObjects") as Node2D
	_check(NAME, runtime_objects != null, "纯关卡根下 RuntimeObjects 应存在。")
	_check(NAME, level.get_node_or_null("LightPathLayer") != null, "纯关卡根下 LightPathLayer 应存在。")
	_check(NAME, level.get_node_or_null("RuntimeObjects/Emitter") != null, "发射器配置节点应位于 LevelRoot/RuntimeObjects/Emitter。")
	# 水晶经 Host 内容根发现（crystals 公开数组）。
	var crystals: Array = node.get("crystals") as Array
	_check(NAME, crystals != null and crystals.size() == 1, "Host 应发现纯关卡内恰好 1 颗水晶，实际 %s。" % [str(crystals.size()) if crystals != null else "null"])
	if crystals != null and crystals.size() == 1:
		_check(NAME, crystals[0].get_crystal_id() == &"crystal_001", "水晶稳定 ID 应为 crystal_001，实际 %s。" % [crystals[0].get_crystal_id()])
	_check(NAME, runtime_objects != null and runtime_objects.get_child_count() == 2, "初始 RuntimeObjects 应仅 Emitter+Crystal 2 个子节点，实际 %d。" % [runtime_objects.get_child_count() if runtime_objects != null else -1])
	await _settle_and_free(node, false)


## 2. Current Level Preflight：合法纯关卡 start_run → valid 结果且进 READY（提示恢复 Space）；
##    同 Host 新实例清空 LevelRoot Terrain → Gate 报 terrain_empty → 拒绝启动仍 SETUP（按钮仍可见）。
func _test_02_preflight_valid_and_invalid(scene: PackedScene) -> void:
	const NAME: String = "02_Preflight前置"
	var node: Node2D = await _ready_instance(scene)
	var result_valid: Variant = node.start_run()
	_check(NAME, result_valid != null and result_valid.is_valid(), "合法纯关卡 start_run 应返回 valid 结果并进 READY。")
	var hint: Label = node.get_node_or_null("CanvasLayer/HintLabel") as Label
	if hint != null:
		_check(NAME, hint.text.find("Space：发射") != -1, "valid 后提示应恢复 Space 发射，实际：%s。" % [hint.text])
	await _settle_and_free(node, false)
	# invalid：清空 LevelRoot Terrain（内存可逆，不写资源），Preflight 应拒绝启动。
	var node_invalid: Node2D = await _ready_instance(scene)
	var terrain: TileMapLayer = node_invalid.get_node_or_null("LevelRoot/TerrainLayer") as TileMapLayer
	_check(NAME, terrain != null, "invalid 前置：LevelRoot/TerrainLayer 应存在。")
	if terrain != null:
		terrain.clear()
	var result_invalid: Variant = node_invalid.start_run()
	_check(NAME, result_invalid != null and not result_invalid.is_valid(), "terrain_empty 纯关卡 start_run 应返回 invalid 结果。")
	var button: Button = _start_run_button(node_invalid)
	if button != null:
		_check(NAME, button.visible and not button.disabled, "invalid 后仍 SETUP，「开始运行」应仍可见可用。")
	await _settle_and_free(node_invalid, false)


## 3. 发射 → 完成 → R 完整重置：SETUP 在 (3,3) 放置 SLASH 镜面把光路反射到水晶 (3,1)；
##    start_run → fire → 结算 COMPLETED（水晶激活 / 完成标签 / 4 段光路）；
##    R 后水晶熄灭、镜面退回库存、完成标签隐藏、ID 稳定、direct fire 拒绝；重新 start_run → fire 产生 3 段直射光路（墙 (5,3) 截断）。
func _test_03_fire_complete_and_reset(scene: PackedScene) -> void:
	const NAME: String = "03_发射完成与R重置"
	var node: Node2D = await _ready_instance(scene)
	var crystals: Array = node.get("crystals") as Array
	var complete: Label = _complete_label(node)
	var lpl: Node2D = _lpl(node)
	# SETUP 放置镜面 (3,3)：入射 RIGHT 反射 UP，光路 (2,3)(3,3)(3,2)(3,1) 命中水晶。
	var placement: Variant = node.get("_placement_controller")
	_check(NAME, placement != null and placement.place_from_inventory(_TOKEN_TYPE, Vector2i(3, 3), _SingleCellMirrorScript.MirrorOrientation.SLASH).is_success(), "SETUP 放置 (3,3) SLASH 镜面应成功。")
	node.start_run()
	node.fire_light()
	# 光段在发射当帧同步创建（与 core_loop_start_run_test 同口径）；脉冲结束后会被清理，故先计数再等待结算。
	# 反射格 (3,3) 由 show_reflection_step 画入射+出射两段半光束（D7-R5）；水晶不截断光路，继续 (3,0) 至 Terrain 边界。
	_check(NAME, lpl != null and lpl.get_child_count() == 6, "反射光路应产生 6 段（(2,3)1+(3,3)反射2+(3,2)(3,1)(3,0)），实际 %d。" % [lpl.get_child_count() if lpl != null else -1])
	await _settle_pulse()
	_check(NAME, crystals != null and crystals.size() == 1 and crystals[0].is_activated, "镜面反射光路命中后水晶应激活。")
	_check(NAME, complete != null and complete.visible, "完成后关卡完成标签应可见。")
	# R 完整重置：水晶熄灭、标签隐藏、ID 稳定、镜面退回（占用清空）、回 SETUP、direct fire 拒绝。
	node.reset_runtime()
	await process_frame
	_check(NAME, crystals != null and crystals.size() == 1 and not crystals[0].is_activated, "R 后水晶应熄灭。")
	_check(NAME, crystals != null and crystals.size() == 1 and crystals[0].get_crystal_id() == &"crystal_001", "R 后水晶稳定 ID 应保持 crystal_001。")
	_check(NAME, node.get_mechanism_at(Vector2i(3, 3)) == &"", "R 后镜面占用应退回清空。")
	_check(NAME, complete != null and not complete.visible, "R 后完成标签应隐藏。")
	var lpl_after_reset: Node2D = _lpl(node)
	node.fire_light()
	_check(NAME, lpl_after_reset != null and lpl_after_reset.get_child_count() == 0, "R 后未重新 start_run，direct fire 应被拒绝（光段 0），实际 %d。" % [lpl_after_reset.get_child_count() if lpl_after_reset != null else -1])
	# 重新 start_run → fire：镜面已退回，直射光路 (2,3)(3,3)(4,3) 被墙 (5,3) 截断 = 3 段。
	node.start_run()
	node.fire_light()
	_check(NAME, lpl_after_reset != null and lpl_after_reset.get_child_count() == 3, "重新 start_run 后直射 fire 应产生 3 段光路，实际 %d。" % [lpl_after_reset.get_child_count() if lpl_after_reset != null else -1])
	await _settle_and_free(node, true)


## 4. R 重置库存退回与占用清理：SETUP 经 PlacementController 公开事务放置 1 面镜面（库存 0 / 占用登记 / 节点入树）；
##    运行并 R 后：库存恢复（剩余：1）、占用清空（get_mechanism_at 空）、RuntimeObjects 无残留节点。
func _test_04_reset_inventory_restore(scene: PackedScene) -> void:
	const NAME: String = "04_R库存退回与占用清理"
	var node: Node2D = await _ready_instance(scene)
	var remaining: Label = _remaining_label(node)
	_check(NAME, remaining != null and remaining.text == "剩余：1", "初始库存剩余应为 1，实际：%s。" % [remaining.text if remaining != null else "null"])
	# 经与 drag_flow 同一提交链的公开事务入口放置镜面。
	var placement: Variant = node.get("_placement_controller")
	_check(NAME, placement != null, "PlacementController 应已接线。")
	if placement != null:
		var placed: Variant = placement.place_from_inventory(_TOKEN_TYPE, Vector2i(2, 1), _SingleCellMirrorScript.MirrorOrientation.SLASH)
		_check(NAME, placed != null and placed.is_success(), "合法格 (2,1) 放置镜面事务应成功。")
		_check(NAME, node.get_mechanism_at(Vector2i(2, 1)) != &"", "放置后占用表应登记该格机关。")
	# 运行（状态切换驱动机关栏刷新）并 R 重置；直调事务不触发拖拽 UI 回调，库存 0 由本状态刷新体现。
	node.start_run()
	if remaining != null:
		_check(NAME, remaining.text == "剩余：0", "放置并进入运行后库存剩余应显示 0，实际：%s。" % [remaining.text])
	node.fire_light()
	await _settle_pulse()
	node.reset_runtime()
	await process_frame
	_check(NAME, node.get_mechanism_at(Vector2i(2, 1)) == &"", "R 后占用表应清空 (2,1)。")
	if remaining != null:
		_check(NAME, remaining.text == "剩余：1", "R 后库存应退回恢复为 1，实际：%s。" % [remaining.text])
	var runtime_objects: Node2D = node.get_node_or_null("LevelRoot/RuntimeObjects") as Node2D
	_check(NAME, runtime_objects != null and runtime_objects.get_child_count() == 2, "R 后 RuntimeObjects 应无镜面残留（仅 Emitter+Crystal），实际 %d。" % [runtime_objects.get_child_count() if runtime_objects != null else -1])
	await _settle_and_free(node, false)


## 5. 任意纯关卡动态装载：Host 脚本新实例（非预置 Scene）装载 templates 编辑示例 →
##    LevelRoot 装载成功且 Preflight 通过（valid），证明装载链不与特定关卡硬绑。
func _test_05_dynamic_level_load() -> void:
	const NAME: String = "05_任意纯关卡动态装载"
	var host_script: GDScript = load(_HOST_SCRIPT_PATH) as GDScript
	var example_scene: PackedScene = load(_EXAMPLE_LEVEL_PATH) as PackedScene
	_check(NAME, host_script != null and example_scene != null, "Host 脚本与编辑示例场景应可加载。")
	if host_script == null or example_scene == null:
		return
	var host: Node2D = host_script.new() as Node2D
	host.set("level_scene", example_scene)
	root.add_child(host)
	await process_frame
	var level: Node2D = _level_root(host)
	_check(NAME, level != null, "动态装载 Host 应实例化 LevelRoot 编辑示例。")
	var result: Variant = host.start_run()
	_check(NAME, result != null and result.is_valid(), "编辑示例 Preflight 应通过并进 READY。")
	await _settle_and_free(host, false)


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加“[组名] 原因”到失败列表。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 5
	var passed_checks: int = _checks - _failures.size()
	print("==== LevelRuntimeHost 集成测试摘要（AF-07）====")
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
