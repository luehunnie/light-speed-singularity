class_name RuntimeSnapshotWriteResult
extends RefCounted

## RuntimeSnapshot 单次落盘结果公共数据契约。
##
## 职责：
## 封装 RuntimeSnapshot.save 的输出——最终写入文件路径与一组中文错误，
## 并提供统一的成功判定；把“落盘是否成功”这一事实从文件路径是否存在中剥离，
## 避免调用方靠判断空字符串推断结果。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照落盘结果层（批次 3C-A 实现）。
## 供后续批次（快照轮转、RuntimeLogger 接线、DiagnosticsController）判断落盘成败并取用文件路径；
## 本批不实现数量与容量清理、轮转、日志接线与核心循环接线。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（String、PackedStringArray、bool）。
## 不依赖 RuntimeLogger、文件系统、场景树或玩法对象。
##
## 明确不负责：
## 写入文件（由 RuntimeSnapshot.save 负责）、解释文件内容、轮转、删除旧快照、日志记录、玩法判定。
##
## 关键边界：
## - 本类只保存落盘结果事实：不写文件、不记录日志、不访问场景树、不访问文件系统。
## - 构造时复制 p_errors，调用方之后修改原数组不影响本结果。
## - is_success 要求 errors 为空且 file_path 非空，二者缺一即视为失败，
##   避免“无错误但空路径”被误判为成功。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 落盘成功时的最终文件路径（user:// 协议路径）。
## 成功时为非空字符串；失败时为空字符串。
var file_path: String

## 落盘过程中收集的中文错误。
## 成功时为空数组；失败时包含全部错误，调用方据此处理或记录。
var errors: PackedStringArray


## 构造一个落盘结果。
## [br]p_file_path 为最终文件路径，成功时非空，失败时为空字符串，默认为空。
## [br]p_errors 为错误数组，默认为空；传入后会被复制，调用方之后修改原数组不影响本结果。
## [br]本函数仅赋值字段并复制错误数组，不做校验也不输出错误。
## [br]边界条件：即使 p_file_path 为空、p_errors 非空也不抛异常，成功与否统一由 is_success 判定。
## [br]副作用：复制 p_errors，不修改源数组；不访问文件系统。
func _init(
        p_file_path: String = "",
        p_errors: PackedStringArray = PackedStringArray()
) -> void:
    file_path = p_file_path
    # 复制错误数组：避免调用方之后修改原 PackedStringArray 影响本结果的数据完整性。
    errors = p_errors.duplicate()


## 判断本次落盘是否成功。
## [br]本函数无参数。
## [br]返回 bool：仅当 errors 为空且 file_path 非空时为 true，否则为 false。
## [br]本函数无副作用：不修改字段、不访问文件或场景树。
## [br]边界条件：errors 为空但 file_path 也为空时视为失败，避免空路径被误判为成功结果。
func is_success() -> bool:
    return errors.is_empty() and file_path != ""
