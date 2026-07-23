class_name CrystalSnapshotState
extends RefCounted

## 水晶快照状态公共数据契约。
##
## 职责：
## 保存单个水晶在某一运行时刻的只读事实摘要（水晶 ID、所在逻辑格、是否激活、状态标签），
## 并提供只读校验与独立复制；供 RuntimeSnapshotData 汇总到运行期快照中。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下水晶快照状态数据层（批次 3A 只实现水晶状态数据契约与校验）。
## 本批不实现 runtime_snapshot.gd、JSON 序列化、文件写入，也不接入核心循环。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（StringName、Vector2i、bool、PackedStringArray）。
## 不依赖水晶脚本、场景树、节点、视觉对象或文件系统。
##
## 明确不负责：
## 读取水晶节点字段、判断关卡是否完成、修改水晶状态、日志写入、JSON 序列化、文件轮转。
## 这些属于后续批次或调用方的职责。
##
## 关键边界：
## - 本类只保存调用方主动提供的只读摘要：不访问节点、不反射对象字段、不遍历场景树。
## - validate() 一次返回全部中文错误，不提前返回，不修改字段、不 push_error、不抛异常。
## - cell 不限制为正数：关卡逻辑格可以使用合法的任意 Vector2i（含负坐标），校验不以此为错误。
## - is_activated 不需要额外校验：布尔值本身只有真/假两种合法取值。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 水晶稳定 ID，使用稳定 StringName，例如 &"crystal_3"。
## 不得为空；用于在快照中定位具体水晶。
var crystal_id: StringName

## 水晶所在逻辑格坐标。
## 允许任意 Vector2i（含负值）：关卡逻辑格可能落在负坐标区域，本字段不做范围限制。
var cell: Vector2i

## 水晶是否处于激活状态。
## 布尔值无需额外校验；仅如实记录调用方提供的激活事实。
var is_activated: bool

## 水晶状态标签，使用稳定 StringName，例如 &"idle" 或 &"charged"。
## 不得为空；用于在快照中描述水晶的当前状态类别。
var state_label: StringName


## 构造一个水晶快照状态。
## [br]p_crystal_id 为水晶稳定 ID，不得为空。
## [br]p_cell 为所在逻辑格坐标，允许任意 Vector2i（含负值）。
## [br]p_is_activated 表示是否激活，如实记录。
## [br]p_state_label 为状态标签，不得为空。
## [br]本函数仅赋值字段，不做校验也不输出错误；校验统一由 validate() 负责。
## [br]边界条件：即使传入非法值也不抛异常，留给 validate() 一次报告全部问题。
func _init(
		p_crystal_id: StringName,
		p_cell: Vector2i,
		p_is_activated: bool,
		p_state_label: StringName
) -> void:
	crystal_id = p_crystal_id
	cell = p_cell
	is_activated = p_is_activated
	state_label = p_state_label


## 只读校验当前水晶状态的字段完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的中文错误；无问题时返回空数组。
## [br]本函数无副作用：不修改字段、不 push_error、不抛异常、不访问节点/场景树/文件系统。
## [br]边界条件：必须一次返回全部问题，不因第一项错误提前返回；
## [br]cell 允许任意 Vector2i（含负值），不以此为错误；is_activated 无需额外校验。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	# crystal_id 为空会导致快照无法定位具体水晶。
	if crystal_id == &"":
		problems.append("CrystalSnapshotState：crystal_id 为空，必须填写水晶稳定 ID。")
	# state_label 为空会导致快照无法描述水晶状态类别。
	if state_label == &"":
		problems.append("CrystalSnapshotState：state_label 为空，必须填写水晶状态标签。")
	# 刻意不校验 cell 的正负：关卡逻辑格允许任意 Vector2i。
	# 刻意不校验 is_activated：布尔值无额外非法取值。
	return problems


## 返回当前水晶状态的全新独立副本。
## [br]本函数无参数。
## [br]返回新的 CrystalSnapshotState，字段与本对象相等但是独立数据对象；修改副本不影响本对象。
## [br]本函数无副作用：不修改本对象、不 push_error、不抛异常、不访问节点或文件系统。
## [br]边界条件：StringName 与 Vector2i 为值语义，直接赋值即完成独立复制，无需进一步深复制。
func duplicate_state() -> CrystalSnapshotState:
	var copy: CrystalSnapshotState = CrystalSnapshotState.new(
		crystal_id,
		cell,
		is_activated,
		state_label
	)
	return copy
