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
## 边界：不持有第二套关卡事实；不做最终 HUD（AF-07 Non-goal）；R 重置语义与 generation/stale 保护由父类运行链保持。


## 要装载的纯关卡 Scene（Host Scene 中固定指向正式关卡；测试可在入树前替换以验证任意纯关卡装载）。
@export var level_scene: PackedScene = null

## Play Current Level 注入环境变量名（AF-08 / Guide A §89）：编辑器 Level Authoring 插件播放前
## 经 OS.set_environment 注入当前编辑关卡路径，子进程（被播放的游戏）继承读取；非编辑器直跑不受影响。
const PLAY_CURRENT_LEVEL_ENV: String = "LIGHT_SPEED_PLAY_CURRENT_LEVEL"


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


## 解析实际装载的关卡 Scene：Play Current Level 环境变量优先，其次 Host Scene 固定 level_scene；均无效返回 null。
func _resolve_level_scene() -> PackedScene:
	var play_current_path := OS.get_environment(PLAY_CURRENT_LEVEL_ENV)
	if not play_current_path.is_empty():
		var played := load(play_current_path) as PackedScene
		if played != null:
			return played
		push_error("LevelRuntimeHost：Play Current Level 路径加载失败：%s，回退 level_scene。" % [play_current_path])
	return level_scene
