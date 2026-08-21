class_name ControlEventDefinition
extends Resource

## 控制事件稳定声明（Guide §26.2）：稳定 event_id + display_name。
## 事件本身无 gameplay payload（§26.3）；本类只是作者/校验可枚举元数据，不承载运行期事实。
## 内部代码方法名可自由重构，event_id 才是关卡数据身份（§26.2 冻结）。


## 稳定事件 ID（非空 StringName；作者期与运行期一致）。
@export var event_id: StringName = &""

## 作者展示名（非空）。
@export var display_name: String = ""


## 校验声明合法性：event_id / display_name 非空；返回问题清单（空 = 合法）。
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if event_id == &"":
		problems.append("event_id 不能为空。")
	if display_name.is_empty():
		problems.append("display_name 不能为空（事件 %s）。" % [event_id])
	return problems
