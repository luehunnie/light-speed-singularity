class_name StableInstanceIdAllocator
extends RefCounted

## 稳定实例 ID 分配器（AF-01 / P0-1，Guide 7）：会话内单调递增、不复用、确定性（无时间/随机源）。
## 生命周期语义由 FormalObjectRegistry 编排：移动/旋转/配置修改保 ID；新建/复制/Spawn 新 ID；
## Recover 后原 ID 失效；Reset 预置回关卡初始 ID、动态实例清除。本类只负责发号。


const _ID_FORMAT: String = "fci_%07d"

var _next_serial: int = 0


## 分配下一个稳定实例 ID。
func allocate() -> String:
	_next_serial += 1
	return _ID_FORMAT % _next_serial


## 已分配数量（只读观察口）。
func get_allocated_count() -> int:
	return _next_serial
