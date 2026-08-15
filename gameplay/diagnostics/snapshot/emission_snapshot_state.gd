class_name EmissionSnapshotState
extends RefCounted

## 活动 emission 快照契约（D7-R1 Snapshot v1）。
##
## 职责：
## 保存一次采样时刻某条活动 emission 的只读身份事实——emission_id（成功发射唯一身份，跨 R 单调不复用）、
## generation（allocate 时所属 Runtime epoch token 快照）、form（RAY/PARTICLE）、绑定的光粒 runtime_id 列表；
## 并提供只读校验与独立深复制。身份语义与 ActiveEmissionRegistry 三身份区别一致，不使用 Node.name / instance_id。
##
## 在当前系统中的位置：
## gameplay/diagnostics/snapshot 下快照数据契约，由 RuntimeSnapshotSampler 从 registry detached 事实构造，
## 随 RuntimeSnapshotData 一并序列化。
##
## 主要依赖：
## LightEmissionTypes（光形态枚举唯一公共来源，preload 引用）与 Godot 内建类型；
## 不依赖节点、场景树、玩法对象或文件系统。
##
## 明确不负责：
## 采集数据、判断 emission 是否应结束、修改 registry、序列化 JSON。


const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")


## 本次成功发射的唯一身份（ActiveEmissionRegistry allocate 分配，>=1，跨 R 不复用）。
var emission_id: int
## allocate 时所属 Runtime epoch token 快照（真值唯一来源 LRC._runtime_generation；本字段仅记录，不解释）。
var generation: int
## 光形态（LightEmissionTypes.LightForm 数值：RAY=0 / PARTICLE=1）。
var form: int
## 该 emission 当前绑定的光粒 runtime_id 列表（RAY emission 恒为空；构造时复制为独立副本）。
var runtime_ids: Array[int]


## 构造一份活动 emission 快照；仅赋值并复制 runtime_ids，校验统一由 validate() 负责。
func _init(p_emission_id: int, p_generation: int, p_form: int, p_runtime_ids: Array[int]) -> void:
	emission_id = p_emission_id
	generation = p_generation
	form = p_form
	# 复制 runtime_id 列表：调用方之后修改原数组不影响本快照。
	runtime_ids.assign(p_runtime_ids)


## 只读校验；返回全部中文错误，无问题时为空数组。不修改数据、不 push_error、不抛异常。
## [br]边界：一次返回全部问题；emission_id 必须 >=1；generation 必须 >=0；form 只允许 RAY/PARTICLE 数值。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = []
	if emission_id < 1:
		problems.append("EmissionSnapshotState：emission_id 必须 >=1（ActiveEmissionRegistry 从 1 起单调分配）。")
	if generation < 0:
		problems.append("EmissionSnapshotState：generation 为负，必须为非负 Runtime epoch token。")
	if form != _LightEmissionTypes.LightForm.RAY and form != _LightEmissionTypes.LightForm.PARTICLE:
		problems.append("EmissionSnapshotState：form 数值 %d 不在 RAY/PARTICLE 合法集合内。" % form)
	return problems


## 返回全新独立深副本（runtime_ids 为独立数组副本）。
func duplicate_state() -> EmissionSnapshotState:
	return EmissionSnapshotState.new(emission_id, generation, form, runtime_ids)
