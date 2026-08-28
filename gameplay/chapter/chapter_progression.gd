extends RefCounted

## S3-08A 章节推进纯数据模块：章节 = 有序关卡 Scene 路径列表（0/1/N 关）。
## 职责：持有唯一关卡序列事实——当前索引与章节完成终点；选择（越界原子拒绝）、
##   预读下一关路径（peek 不推进，装载前校验失败可安全保持现状）、
##   当前关完成后推进（advance；无下一关时落「章节完成」安全终点且索引停在最后一关）。
## 边界：不加载资源、不碰场景树/UI/运行状态机；下一关装载与 Host 换装由 LevelRuntimeHost 负责
##   （本模块只提供路径与终点事实）。未绑定到 Host 时不参与任何行为（单关现状兼容）。
## 0 关章节安全：无可选关、无当前路径、advance 直接落章节完成终点，调用方安全失败不猜默认关。


## 有序关卡 Scene 路径（res:// 绝对路径；空数组 = 0 关章节）。
var _level_paths: Array[String] = []

## 当前关卡索引（-1 = 无当前关；非空章节构造即选中第 0 关）。
var _current_index: int = -1

## 章节完成终点事实（advance 到无下一关时置 true；构造/选择不置，R 重置语义由调用方重建会话决定）。
var _chapter_complete: bool = false


## 构造章节推进；拷贝入参路径数组（调用方后续修改不影响章节事实），非空章节自动选中第 0 关。
func _init(level_paths: Array[String]) -> void:
	_level_paths = level_paths.duplicate()
	if not _level_paths.is_empty():
		_current_index = 0


## 关卡总数（0 关章节返回 0）。
func get_level_count() -> int:
	return _level_paths.size()


## 当前关卡索引（-1 = 无当前关：0 关章节或选择被拒后维持原状）。
func get_current_index() -> int:
	return _current_index


## 当前关卡 Scene 路径；无当前关返回 ""（调用方安全失败，不猜默认关）。
func get_current_level_path() -> String:
	if _current_index < 0 or _current_index >= _level_paths.size():
		return ""
	return _level_paths[_current_index]


## 选择指定索引的关卡；越界（含负数）原子拒绝返回 false，当前状态不变。
func select(index: int) -> bool:
	if index < 0 or index >= _level_paths.size():
		return false
	_current_index = index
	return true


## 预读下一关路径（不推进索引）；无下一关返回 ""。供装载前校验：加载失败可不推进、安全保持现状。
func peek_next_level_path() -> String:
	if _current_index < 0 or _current_index + 1 >= _level_paths.size():
		return ""
	return _level_paths[_current_index + 1]


## 当前关完成后推进到下一关：有下一关则推进返回 true；无下一关（含 0 关章节）不推进，
## 落章节完成终点并返回 false（索引停在最后一关，供 R 重玩语义）。
func advance_to_next_level() -> bool:
	if peek_next_level_path().is_empty():
		_chapter_complete = true
		return false
	_current_index += 1
	return true


## 章节完成终点事实（advance 到无下一关后为 true；0/1/N 章节初始均为 false）。
func is_chapter_complete() -> bool:
	return _chapter_complete
