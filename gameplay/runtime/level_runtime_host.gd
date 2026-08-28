extends "res://levels/prototypes/core_loop_prototype.gd"

## 统一 LevelRuntimeHost（AF-07 / Guide A §4.2/§4.3/§89 冻结）：纯关卡 Scene 的装载宿主。
##
## 职责边界：
## - 本脚本与 Host Scene 只承载运行时（Runtime Controller / HUD / 运行 UI），绝不保存关卡内容；
## - 关卡内容全部来自 level_scene 指向的纯关卡 Scene（四层 TileMapLayer + RuntimeObjects + LightPathLayer 等正式角色，见 level_template.tscn 结构）；
## - _enter_tree 装载一次 level_scene（实例命名 LevelRoot，先于父类 @onready 内容解析），
##   父类内容路径即在其下解析——这是 Play Current Level 的基础装载链（Current Level Preflight 在 start_run 经 RuntimeValidationGate 执行）；
## - 五态 / 发射 / 完整重置 / 库存 / 目标 / 校验 Gate / 视觉链全部复用父类（core_loop 关卡控制器）既有接线，本类不复制任何第二套 Runtime。
##
## 边界：不持有第二套关卡内容事实；不做最终 HUD（AF-07 Non-goal）；R 重置语义与 generation/stale 保护由父类运行链保持。
## S3-08A 章节推进（0/1/N）：入树前可选注入 ChapterProgression（与 level_scene 同一注入时机契约）；
##   未注入时单关现状零行为差异。注入后：装载解析优先级 Play Current Level 环境变量 → 章节当前关 → 固定 level_scene；
##   COMPLETED 时按章节事实推进——有下一关则等脉冲视觉窗口结束后换装下一关 Host（旧 Host 整体释放，
##   新 Host 走完整 _ready 接线，不复制第二套 Runtime），无下一关则落「章节完成」安全终点。


## 要装载的纯关卡 Scene（Host Scene 中固定指向正式关卡；测试可在入树前替换以验证任意纯关卡装载）。
@export var level_scene: PackedScene = null

## Play Current Level 注入环境变量名（AF-08 / Guide A §89）：编辑器 Level Authoring 插件播放前
## 经 OS.set_environment 注入当前编辑关卡路径，子进程（被播放的游戏）继承读取；非编辑器直跑不受影响。
const PLAY_CURRENT_LEVEL_ENV: String = "LIGHT_SPEED_PLAY_CURRENT_LEVEL"

# preload 纯模块，避开全局 class_name 缓存问题（与项目惯例一致）。
# _RuntimeInteractionTypes 复用父类既有 preload 常量（core_loop_prototype.gd）。
const _ChapterProgression: GDScript = preload("res://gameplay/chapter/chapter_progression.gd")

# COMPLETED 后等待旧 Host 脉冲视觉窗口（1.0s）结束再换装，避免挂起协程跨实例释放；须大于 PULSE_VISUAL_DURATION_SECONDS。
const _CHAPTER_SWAP_SETTLE_SECONDS: float = 1.2

## 章节推进事实（null = 未绑定，单关现状；入树前经 set_chapter_progression 注入）。
var _chapter_progression: _ChapterProgression = null


## 装载纯关卡 Scene：入树早期（先于 @onready 内容解析）实例化 level_scene 并命名为 LevelRoot 加入自身。
## [br]level_scene 缺失或根非 Node2D 时 push_error 并跳过装载；父类内容解析因找不到内容角色而安全中止初始化（明确报错，不静默降级为空关卡）。
## [br]Play Current Level（Guide §89 流程 3→4）：编辑器注入环境变量优先于 Host Scene 固定 level_scene，
## [br]使同一 Host 可播放任意当前编辑关卡；两者均缺失时保持原报错路径。
func _enter_tree() -> void:
	var resolved := _resolve_level_scene()
	if resolved == null:
		push_error("LevelRuntimeHost：level_scene 未配置，无法装载纯关卡 Scene。")
		return
	var level_instance: Node = resolved.instantiate()
	if level_instance is not Node2D:
		push_error("LevelRuntimeHost：level_scene 根节点必须为 Node2D，实际 %s，拒绝装载。" % [level_instance.get_class()])
		level_instance.free()
		return
	level_instance.name = "LevelRoot"
	add_child(level_instance)


## 绑定章节推进（S3-08A 0/1/N 关卡链）：入树前注入，与 level_scene 替换同一时机契约。
## [br]只在 COMPLETED 时驱动章节推进；null 不接受（解绑不是章节会话语义，重建 Host 即回单关现状）。
## [br]重复绑定同一 progression 幂等（不重复连接状态信号）。
func set_chapter_progression(progression: _ChapterProgression) -> void:
	_chapter_progression = progression
	var handler := Callable(self, "_on_chapter_run_state_changed")
	if not _run_state_controller.state_changed.is_connected(handler):
		_run_state_controller.state_changed.connect(handler)


## 解析实际装载的关卡 Scene：Play Current Level 环境变量优先，其次章节当前关，最后 Host Scene 固定 level_scene。
## [br]章节绑定下当前关路径为空（0 关章节）或加载失败时显式返回 null（安全中止初始化，不静默回退固定单关装错关）。
func _resolve_level_scene() -> PackedScene:
	var play_current_path := OS.get_environment(PLAY_CURRENT_LEVEL_ENV)
	if not play_current_path.is_empty():
		var played := load(play_current_path) as PackedScene
		if played != null:
			return played
		push_error("LevelRuntimeHost：Play Current Level 路径加载失败：%s，回退 level_scene。" % [play_current_path])
	if _chapter_progression != null:
		var chapter_path := _chapter_progression.get_current_level_path()
		if chapter_path.is_empty():
			push_error("LevelRuntimeHost：章节推进无当前关（0 关章节或未选择），拒绝装载。")
			return null
		var chapter_level := load(chapter_path) as PackedScene
		if chapter_level != null:
			return chapter_level
		push_error("LevelRuntimeHost：章节当前关路径加载失败：%s，拒绝装载。" % [chapter_path])
		return null
	return level_scene


## 章节推进状态回调（S3-08A）：COMPLETED 时按章节事实推进——预读并预载下一关，
## [br]等待旧脉冲视觉窗口结束后换装（期间 R 离开 COMPLETED 则中止，重玩后重新推进）；
## [br]无下一关则落「章节完成」安全终点；下一关路径加载失败保持当前关不推进（安全失败）。
func _on_chapter_run_state_changed(_previous_state: int, new_state: int) -> void:
	if _chapter_progression == null or new_state != _RuntimeInteractionTypes.RunState.COMPLETED:
		return
	var next_path := _chapter_progression.peek_next_level_path()
	if next_path.is_empty():
		_chapter_progression.advance_to_next_level()
		_mark_chapter_complete()
		return
	var next_level := load(next_path) as PackedScene
	if next_level == null:
		push_error("LevelRuntimeHost：下一关路径加载失败：%s，保持当前关（章节推进中止）。" % [next_path])
		return
	await get_tree().create_timer(_CHAPTER_SWAP_SETTLE_SECONDS).timeout
	if _get_current_run_state() != _RuntimeInteractionTypes.RunState.COMPLETED:
		return
	_chapter_progression.advance_to_next_level()
	_swap_to_chapter_host(next_level)


## 章节完成安全终点：复用父类完成标签承载「章节完成」（无下一关时到此停止，不再换装）。
func _mark_chapter_complete() -> void:
	if complete_label != null:
		complete_label.text = "章节完成"


## 换装下一关 Host：重载自身 Host Scene 实例化新 Host（完整 UI 子树 + _ready 接线），
## [br]移交章节事实后挂入父节点并整体释放旧 Host（换装失败保持当前关安全失败，不半换装）。
func _swap_to_chapter_host(next_level: PackedScene) -> void:
	var host_scene := load(scene_file_path) as PackedScene
	if host_scene == null:
		push_error("LevelRuntimeHost：章节推进需要 Host Scene 可重载（scene_file_path=%s），保持当前关。" % [scene_file_path])
		return
	var tree := get_tree()
	var parent_node := get_parent()
	if tree == null or parent_node == null:
		push_error("LevelRuntimeHost：章节推进换装需要 Host 已在场景树内，保持当前关。")
		return
	var next_host: Node2D = host_scene.instantiate() as Node2D
	next_host.set_chapter_progression(_chapter_progression)
	if tree.current_scene == self:
		tree.current_scene = next_host
	parent_node.add_child(next_host)
	queue_free()
