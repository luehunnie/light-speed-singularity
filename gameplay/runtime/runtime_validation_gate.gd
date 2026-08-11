class_name RuntimeValidationGate
extends RefCounted

## 运行期校验门（D7-1 Runtime Validation Gate）。
##
## 职责：把“正式运行开始请求”转发为对既有 LevelValidator v0 的只读调用，原样返回结构化
##   LevelValidationResult，作为 runtime 层决定是否允许生命周期继续的唯一校验入口。
##
## 在当前系统中的位置：gameplay/runtime 层薄门，处于调度链
##   runtime → RuntimeValidationGate → LevelValidator → LevelValidationResult。
##   runtime 层（如未来的正式“开始运行”编排）在进入 READY_TO_FIRE 前调用本门取得结果；
##   本门不做任何状态切换，也不实现 READY_TO_FIRE。
##
## 主要依赖：LevelValidator（D6 v0 只读结构与跨层校验的唯一规则来源）与
##   LevelValidationResult（结构化结果聚合）。两者均以 preload 引用，避开全局 class_name
##   缓存坑，运行时代码不依赖 addons/。
##
## 明确不负责：
##   - 不持有长期业务状态：零字段、零缓存，不保存关卡根/RunState/场景节点引用，不跨调用记忆结果；
##   - 不复制 Validator 规则，不重新定义 valid/invalid 语义（沿用 LevelValidationResult.is_valid）；
##   - 不实现 READY_TO_FIRE、不实现“开始运行”按钮、不改变当前五态；
##   - 校验成功本批也不自动进入 READY_TO_FIRE 或任何状态转换；
##   - 不触发 Ray、不保存场景、不自动修复、不读写库存/占用/水晶。
##
## 关键状态生命周期：无；本门为无状态 RefCounted，每次调用独立构造 LevelValidator。
##
## 关键边界：零玩法副作用保证来自两层——LevelValidator 自身只读、不 push_error、不改场景；
##   本门除 level_root 外不接收也不引用 RunState/TileMap/固定对象/库存/占用/水晶/Ray/存档，
##   因此校验失败（或成功）均不可能产生玩法副作用。是否据此继续生命周期由调用方（未来批次）决定。

# preload 引用校验器与结果类型，避开全局 class_name 缓存坑（与 gameplay/interaction、
# gameplay/level/validation 既有模块引用方式一致）。
const _LevelValidator: GDScript = preload("res://gameplay/level/validation/level_validator.gd")
const _LevelValidationResult: GDScript = preload("res://gameplay/level/validation/level_validation_result.gd")


## 校验正式运行开始是否被允许。
## [br]职责：以传入关卡根构造一个无状态 LevelValidator 并调用其 validate，原样返回结构化结果。
## [br]输入：level_root 为当前关卡根 Node；合法为 Node2D 关卡根。可为 null——LevelValidator
##   自身会产出 level_root_invalid 的 ERROR，本门不替它做前置判空或自愈。
## [br]返回：LevelValidationResult。
## [br]语义：
## [br]  - valid（允许未来生命周期继续）= result.is_valid() == true，即不存在任何 ERROR；
## [br]  - invalid（拒绝开始且无玩法副作用）= result.has_errors() == true；
## [br]  - WARNING 遵循既有 LevelValidationResult.is_valid 语义：WARNING 数量不影响 valid 判定
## [br]    （仅 WARNING、无 ERROR 时 is_valid() 仍为 true）。
## [br]副作用：无；不改 RunState、TileMap、固定对象、库存、占用、水晶；不触发 Ray；不保存；不自动修复。
## [br]失败条件：本方法不会失败；level_root 异常由 LevelValidator 以结构化 ERROR 体现，不抛异常、不 push_error。
## [br]边界：本批成功也不自动进入 READY_TO_FIRE 或切换运行状态；本门只回答“是否允许继续”，
## [br]是否真正继续生命周期由调用方（未来批次）决定。
func validate_for_run_start(level_root: Node) -> _LevelValidationResult:
	# 无状态委托：每次调用独立构造 LevelValidator，本门零字段，故无任何跨调用状态可被污染。
	return _LevelValidator.new().validate(level_root)
