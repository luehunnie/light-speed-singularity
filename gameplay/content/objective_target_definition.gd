class_name ObjectiveTargetDefinition
extends FormalContentDefinition

## 目标域声明（Guide 4.1）：目标类型级能力与作者元数据。
## 允许的目标条件类型等目标域能力按 P0-6 阶段 additive 扩展。


## 命中即基础成功（Base Success）。
@export var base_success_on_hit: bool = true


func get_content_domain() -> StringName:
	return &"objective_target"
