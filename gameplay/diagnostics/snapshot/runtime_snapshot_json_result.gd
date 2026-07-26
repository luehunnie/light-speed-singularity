class_name RuntimeSnapshotJsonResult
extends RefCounted

## RuntimeSnapshot JSON 序列化结果公共数据契约。
##
## 职责：
## 封装 RuntimeSnapshot.serialize 的输出——一段稳定 JSON 文本与一组中文错误，
## 并提供统一的成功判定；把“序列化是否成功”这一事实从字符串内容中剥离，
## 避免调用方靠判断空字符串推断结果。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照序列化结果层（批次 3B 实现）。
## 供后续批次（快照落盘、轮转）判断序列化成败并取用 JSON 文本；
## 本批不实现文件写入、轮转与核心循环接线。
##
## 主要依赖：
## 仅依赖 Godot 内建类型（String、PackedStringArray、bool）。
## 不依赖 RuntimeLogger、文件系统、场景树或玩法对象。
##
## 明确不负责：
## 生成 JSON 文本（由 RuntimeSnapshot 负责）、解释 JSON 内容、写入文件、轮转、日志记录、玩法判定。
##
## 关键边界：
## - 本类只保存序列化结果事实：不生成 JSON、不写文件、不记录日志、不访问场景树。
## - 构造时复制 p_errors，调用方之后修改原数组不影响本结果。
## - is_success 要求 errors 为空且 json_text 非空，二者缺一即视为失败，
##   避免“无错误但空文本”被误判为成功。
## - 依据 Diagnostics 红线，本类不参与玩法决策，不读取业务私有字段。


## 序列化得到的 JSON 文本。
## 成功时为非空字符串；失败时为空字符串。
var json_text: String

## 序列化过程中收集的中文错误。
## 成功时为空数组；失败时包含全部错误，调用方据此处理或记录。
var errors: PackedStringArray


## 构造一个 JSON 序列化结果。
## [br]p_json_text 为 JSON 文本，成功时非空，失败时为空字符串，默认为空。
## [br]p_errors 为错误数组，默认为空；传入后会被复制，调用方之后修改原数组不影响本结果。
## [br]本函数仅赋值字段并复制错误数组，不做校验也不输出错误。
## [br]边界条件：即使 p_json_text 为空、p_errors 非空也不抛异常，成功与否统一由 is_success 判定。
## [br]副作用：复制 p_errors，不修改源数组。
func _init(
        p_json_text: String = "",
        p_errors: PackedStringArray = PackedStringArray()
) -> void:
    json_text = p_json_text
    # 复制错误数组：避免调用方之后修改原 PackedStringArray 影响本结果的数据完整性。
    errors = p_errors.duplicate()


## 判断本次序列化是否成功。
## [br]本函数无参数。
## [br]返回 bool：仅当 errors 为空且 json_text 非空时为 true，否则为 false。
## [br]本函数无副作用：不修改字段、不访问文件或场景树。
## [br]边界条件：errors 为空但 json_text 也为空时视为失败，避免空文本被误判为成功结果。
func is_success() -> bool:
    return errors.is_empty() and json_text != ""
