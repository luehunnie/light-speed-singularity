class_name FormalContentBinding
extends RefCounted

## 正式内容实例身份组件（AF-01 / P0-1，Guide 6.4）：薄、组合式，仅持两层身份。
## 不负责玩法、放置、目标、控制、视觉或运行状态；实现不强制可见子节点。
## 光域身份（runtime_generation / emission_id / particle_runtime_id）不进入本组件（Guide 6.2）。


## 类型身份（指向 FormalContentRegistry 中的 Definition）。
var content_type_id: StringName = &""
## 实例身份；由 StableInstanceIdAllocator 分配，全局唯一。
var stable_instance_id: String = ""


## 构造薄绑定；两个 token 均不可为空才是合法身份。
static func make(in_content_type_id: StringName, in_stable_instance_id: String) -> FormalContentBinding:
	var binding := FormalContentBinding.new()
	binding.content_type_id = in_content_type_id
	binding.stable_instance_id = in_stable_instance_id
	return binding


## 两层身份是否齐备。
func is_valid() -> bool:
	return content_type_id != &"" and not stable_instance_id.is_empty()
