extends RefCounted

## 原型玩家机关库存事实所有者：保存总量与剩余量，提供扣除/归还/重置与一致性判断。
## 不持有 placed_tokens_by_id、不生成 mechanism_id、不创建或销毁节点、不登记占用、不访问拖拽/UI/RunState；调用方负责放置与回收事务时序。
## 核心以 PROTOTYPE_TOKEN_TOTAL 构造唯一实例，运行期库存数量事实仅存于此。


var _total: int = 0
var _remaining: int = 0
## 已锁定的归还预留数：回收在不可逆销毁前预留容量，提交后才真正归还，保证“机关已删但库存未还”不发生。
var _reserved_return_count: int = 0


## 构造库存：total 钳为非负，剩余初始化为满。
func _init(total: int) -> void:
	_total = maxi(0, total)
	_remaining = _total


## 库存总量（构造后不变）。
func get_total() -> int:
	return _total


## 当前剩余可放置数量。
func get_remaining() -> int:
	return _remaining


## 是否可再扣除一个（剩余 > 0）。
func can_consume_one() -> bool:
	return _remaining > 0


## 成功放置后扣除一个；剩余为 0 时返回 false 且不变更，防负数。
func try_consume_one() -> bool:
	if _remaining <= 0:
		return false
	_remaining -= 1
	return true


## 成功回收后归还一个；已达总量时返回 false 且不变更，钳制旧行为防超量。
func try_return_one() -> bool:
	if _remaining >= _total:
		return false
	_remaining += 1
	return true


## 已锁定的归还预留数（只读，供诊断与测试观察，不作为后门）。
func get_reserved_return_count() -> int:
	return _reserved_return_count


## 归还预留第一阶段：锁定一个归还容量，remaining 不立即变化。
## [br]仅当 remaining + reserved_return_count < total 时成功；成功时 reserved_return_count += 1。
## [br]失败时所有数据不变，返回 false。
func try_reserve_return_one() -> bool:
	if _remaining + _reserved_return_count >= _total:
		return false
	_reserved_return_count += 1
	return true


## 归还预留第二阶段：提交预留，把锁定的容量真正归还给 remaining。
## [br]存在预留时 reserved_return_count -= 1 且 remaining += 1（不超过 total）；预留已锁定容量，正常同步事务不应失败。
## [br]无预留时 push_error 并返回 false，不修改 remaining。
func commit_reserved_return() -> bool:
	if _reserved_return_count <= 0:
		push_error("InventoryController: 提交归还预留时不存在预留。")
		return false
	_reserved_return_count -= 1
	_remaining = mini(_remaining + 1, _total)
	return true


## 取消预留：释放已锁定的归还容量，remaining 不变。
## [br]存在预留时 reserved_return_count -= 1 返回 true；无预留时返回 false 且不修改数据。
func cancel_reserved_return() -> bool:
	if _reserved_return_count <= 0:
		return false
	_reserved_return_count -= 1
	return true


## R 完成玩家机关清理后恢复满库存；同时清除遗留归还预留。
func reset_to_total() -> void:
	_remaining = _total
	_reserved_return_count = 0


## 库存一致性标量判断：remaining + placed_count == total。
func is_consistent_with_placed_count(placed_count: int) -> bool:
	return _remaining + placed_count == _total


## 按残留机关数量重置剩余库存，保持 remaining + placed_count == total。
## [br]placed_count 为清理后仍占据场上的玩家机关数量（正常清理成功后为 0，部分失败时为残留数）。
## [br]副作用：remaining = clamp(total - max(placed_count, 0), 0, total)；全部清理恢复满库存，部分失败扣除残留数；同时清除遗留归还预留。
## [br]返回 placed_count 是否处于合法范围 [0, total]；越界输入仍按公式钳制 remaining，但返回 false 暴露异常。
## [br]边界：不静默把未清理机关对应库存归还给玩家；残留机关与库存严格满足 remaining + placed_count == total。
func reconcile_with_placed_count(placed_count: int) -> bool:
	var legal: bool = placed_count >= 0 and placed_count <= _total
	_remaining = clampi(_total - maxi(placed_count, 0), 0, _total)
	_reserved_return_count = 0
	return legal
