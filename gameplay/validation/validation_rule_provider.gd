class_name ValidationRuleProvider
extends RefCounted

## 机制特有 Validator Extension / Rule Provider 基契约（AF-06 / Guide §35）。
## 冻结边界：只读、无玩法副作用、不修改关卡、只使用公开 Authoring / Placement 查询、
##   返回 machine-readable ValidationIssue（含最相关对象 / cell 定位，可被 Go To 使用）。
## Core 不维护机关类型 if-list / 白名单（Guide §5.2 / Q41）；机制约束经本类独立注册接入。
## Auto-fix 不属于本契约（只允许机械且安全的修复，另行阶段收口）。


## Provider 稳定身份 token；同一 Core 内不得重复注册（Core 拒绝重复并保持零副作用）。
func get_provider_id() -> StringName:
	return &""


## 本 Provider 覆盖的校验域 token（默认 extension；机制可返回自定义域 token）。
func get_rule_domain() -> StringName:
	return &"extension"


## 是否支持指定 Scope（project / current_level / change_set）；默认全支持，子类按需覆写。
func supports_scope(scope: StringName) -> bool:
	return true


## 校验入口：返回 ValidationIssue 数组（空数组 = 通过）。
## [br]context 为 Core 组装的只读上下文字典（键见 ValidatorCore.K_* 常量）；
## 实现必须保持只读（不改 Registry / 连接集 / 场景），只消费公开查询面。
func validate(scope: StringName, context: Dictionary) -> Array:
	return []
