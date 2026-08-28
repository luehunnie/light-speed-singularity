class_name ControlConnectionsMetaReader
extends RefCounted

## Control 关卡 meta 只读解析器（S3-06 运行期接线，G5 边界收口）。
## 职责（唯一）：读关卡根 metadata 的 control_connections（严格镜像
##   addons/light_speed_level_authoring/authoring/business_data/control_data_service.gd 的冻结 schema
##   与 BusinessDataService.read_meta 的 detached 深拷贝读法；addons 只读不引），
##   在本边界把 String 键统一转 StringName（G5：作者期字典键 String，运行期 Typed 域 StringName，
##   AF-09 §5.1 deferred 在此批正式化），构造 ControlConnection / ControlConnectionSet 交运行期
##   ControlDispatcher 消费。对象存在性 / 事件与动作声明 / params schema 属作者期校验域
##   （validator_core → ControlConnectionPreflight），本类不复制第二套；运行期不存在对象由
##   Dispatcher 按 REASON_TARGET_NOT_FOUND 安全 no-op（§32）。
## Schema（Authoring 冻结）：control_connections = [{source_stable_id: String, event_id: String,
##   target_stable_id: String, action_id: String, params: {String → bool|int}}]。
## 安全失败：无 meta 或空数组 → 返回 null（调用方保持无 Control 链原型路径，静默）；
##   meta 存在但形状非法 / 任一条目结构非法 / 五元组重复 → push_error 明确原因并返回 null
##   （整体原子拒绝，不返回半套连接集合，与 ObjectiveMetaReader 同口径）。
## 纯只读：不写 meta、不触场景树结构、不解析实例（Target 解析唯一发生在 Dispatcher）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


const _ControlConnection: GDScript = preload(
	"res://gameplay/control/control_connection.gd"
)
const _ControlConnectionSet: GDScript = preload(
	"res://gameplay/control/control_connection_set.gd"
)

## meta 键（与 addons ControlDataService.META_CONNECTIONS 一致，不 preload addons）。
const META_CONNECTIONS: String = "control_connections"


## 读关卡根并构造连接集合（S3-06 唯一入口）。
## [br]返回：构造成功的 ControlConnectionSet；无 control_connections meta 或空数组返回 null
## [br]  （原型回退，静默）；meta 存在但非法时 push_error 并返回 null（安全失败，不返回半套集合）。
## [br]root 为承载 control_connections meta 的关卡根节点。
static func build_connection_set(root: Node) -> Variant:
	if root == null or not root.has_meta(META_CONNECTIONS):
		return null
	var raw: Variant = root.get_meta(META_CONNECTIONS).duplicate(true)
	if not (raw is Array):
		push_error("ControlConnectionsMetaReader：control_connections 必须是数组，实际 %s。" % [typeof(raw)])
		return null
	if (raw as Array).is_empty():
		return null
	var connection_set: _ControlConnectionSet = _ControlConnectionSet.new()
	for index: int in (raw as Array).size():
		var entry: Variant = (raw as Array)[index]
		if not (entry is Dictionary):
			push_error("ControlConnectionsMetaReader：连接 %d 必须是 Dictionary，实际 %s。" % [index, typeof(entry)])
			return null
		var connection: Variant = _build_connection(index, entry)
		if connection == null:
			return null
		if not connection_set.add_connection(connection):
			return null
	return connection_set


## 构造单条 Typed 连接（G5 String→StringName 边界转换的唯一发生点）。
## [br]结构域镜像 ControlDataService 冻结口径：四段 ID 非空 String；params 键为非空 String、
##   值只允许 bool / int（作者期 Dictionary 键为 String）；类型域校验委托 ControlConnection.create。
## [br]返回：合法 ControlConnection；非法 push_error 并返回 null。
static func _build_connection(index: int, entry: Dictionary) -> Variant:
	var source_id: String = str(entry.get("source_stable_id", ""))
	var event_id: String = str(entry.get("event_id", ""))
	var target_id: String = str(entry.get("target_stable_id", ""))
	var action_id: String = str(entry.get("action_id", ""))
	if source_id.is_empty() or event_id.is_empty() or target_id.is_empty() or action_id.is_empty():
		push_error("ControlConnectionsMetaReader：连接 %d 四段 ID（source/event/target/action）均不能为空。" % index)
		return null
	var raw_params: Variant = entry.get("params", {})
	if not (raw_params is Dictionary):
		push_error("ControlConnectionsMetaReader：连接 %d 的 params 必须是 Dictionary，实际 %s。" % [index, typeof(raw_params)])
		return null
	var params: Dictionary = {}
	for key_variant: Variant in (raw_params as Dictionary).keys():
		var key: String = str(key_variant)
		if key.is_empty():
			push_error("ControlConnectionsMetaReader：连接 %d 的 params 含空键。" % index)
			return null
		var value: Variant = (raw_params as Dictionary)[key_variant]
		if not (value is bool or value is int):
			push_error("ControlConnectionsMetaReader：连接 %d 的参数 %s 值只允许 bool / int，实际 %s。" % [index, key, typeof(value)])
			return null
		# G5 边界转换：作者期 String 键 → 运行期 Typed 域 StringName 键（值原样透传）。
		params[StringName(key)] = value
	return _ControlConnection.create(source_id, StringName(event_id), target_id, StringName(action_id), params)
