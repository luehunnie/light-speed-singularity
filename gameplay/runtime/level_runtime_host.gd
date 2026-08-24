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


## 装载纯关卡 Scene：入树早期（先于 @onready 内容解析）实例化 level_scene 并命名为 LevelRoot 加入自身。
## [br]level_scene 缺失或根非 Node2D 时 push_error 并跳过装载；父类内容解析因找不到内容角色而安全中止初始化（明确报错，不静默降级为空关卡）。
func _enter_tree() -> void:
	if level_scene == null:
		push_error("LevelRuntimeHost：level_scene 未配置，无法装载纯关卡 Scene。")
		return
	var level_instance: Node = level_scene.instantiate()
	if level_instance is not Node2D:
		push_error("LevelRuntimeHost：level_scene 根节点必须为 Node2D，实际 %s，拒绝装载。" % [level_instance.get_class()])
		level_instance.free()
		return
	level_instance.name = "LevelRoot"
	add_child(level_instance)
