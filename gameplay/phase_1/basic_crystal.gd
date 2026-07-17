class_name BasicCrystal
extends Node2D

## 第一阶段基础水晶占位脚本（plan §4.3 / §8）。
## 只保存格子坐标与激活状态，提供 activate() / reset_runtime() 和占位视觉反馈。
## 本脚本不自行判断光是否经过，也不判断通关；这些由关卡控制器 phase_1_prototype.gd 完成。
## 注意：激活判定通过 Vector2i 格子坐标比较完成，不依赖物理碰撞。

@export var cell: Vector2i = Vector2i(7, 3)

var is_activated: bool = false

@onready var _visual: ColorRect = $CrystalVisual

const _COLOR_INACTIVE: Color = Color(0.35, 0.45, 0.7, 1.0)
const _COLOR_ACTIVE: Color = Color(1.0, 0.85, 0.2, 1.0)


func activate() -> void:
	if is_activated:
		return
	is_activated = true
	_update_visual()


func reset_runtime() -> void:
	is_activated = false
	_update_visual()


func _update_visual() -> void:
	if _visual == null:
		return
	_visual.color = _COLOR_ACTIVE if is_activated else _COLOR_INACTIVE


func _ready() -> void:
	_update_visual()
