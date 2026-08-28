class_name ControlRuntimeTargetIndex
extends RefCounted

## Control 运行期目标索引（S3-06 运行期接线）。
## 职责（唯一）：按作者期正式对象口径（严格镜像 StableIdService.find_formal_objects 的发现规则：
##   子树内 PlaceableToken 或 GridPlacedObject 派生节点；addons 只读不引）扫描关卡内容子树，
##   以 stable_instance_id → 实例 建立只读索引，向 ControlDispatcher 提供 Target 解析契约面
##   （has_object / get_object_snapshot(stable_id)["instance"]，与 FormalObjectRegistry 快照键同构的
##   最小子集）与 Reset 遍历面（get_stable_ids_by_origin）。
## 身份边界：只认 stable_instance_id（作者期 Stable ID Manager 持久化），不从 Node.name / NodePath /
##   坐标推测；玩家 Spawn 的运行期放置 token 无作者期 stable_instance_id（空串），天然不在索引内
##   （作者期连接只可能引用场景内 authored 对象，见 ControlDataService.validate_connections）。
## 生命周期：构造时一次性快照（移动保 ID、预置对象会话内不销毁，快照不失效）；不做增删接口，
##   不是第二套可写 Registry（正式登记事务仍属 FormalObjectRegistry / Placement 域）。
## 安全失败：无 stable_instance_id 的正式对象静默跳过；重复 stable_instance_id push_error 保留首个
##   （作者期 StableIdService 保证唯一，重复 = 场景数据损坏，可诊断不中断）。
## 类型约束：调用方一律通过 preload() 引用以避开全局 class_name 缓存问题。


## stable_instance_id（String）→ 正式对象节点（Variant）。
var _instances_by_stable_id: Dictionary = {}


## 扫描关卡内容子树并建立只读索引；返回索引实例。
## [br]root 为承载正式对象的子树根（core_loop 传 _content_root）；root 为 null 返回空索引（可诊断）。
static func build_from(root: Node) -> ControlRuntimeTargetIndex:
	var index: ControlRuntimeTargetIndex = ControlRuntimeTargetIndex.new()
	if root != null:
		index._gather(root)
	return index


## 是否存在指定稳定 ID 的正式对象（Dispatcher Target 解析契约面）。
func has_object(stable_id: String) -> bool:
	return _instances_by_stable_id.has(stable_id)


## 按稳定 ID 取条目快照（detached；未登记返回空字典，与 FormalObjectRegistry 同口径）。
## [br]Dispatcher 只消费 "instance" 键；"stable_instance_id" 键供诊断输出。
func get_object_snapshot(stable_id: String) -> Dictionary:
	if not _instances_by_stable_id.has(stable_id):
		return {}
	var instance: Variant = _instances_by_stable_id[stable_id]
	return {
		"stable_instance_id": stable_id,
		"instance": instance,
	}


## 按来源域取全部稳定 ID 副本（Dispatcher Reset 遍历契约面）。
## [br]运行期索引内全部为作者期 authored 对象（preplaced 语义）；Dispatcher 会先后以
## [br]ORIGIN_PREPLACED 与 ORIGIN_SPAWNED 两次遍历，本索引对 preplaced 返回全量、
## [br]对其余 origin 返回空（运行期无 spawn 来源条目），保证每实例钩子恰好一次。
func get_stable_ids_by_origin(origin: StringName) -> Array[String]:
	var ids: Array[String] = []
	if origin != &"preplaced":
		return ids
	for stable_id: String in _instances_by_stable_id.keys():
		ids.append(stable_id)
	return ids


## 已索引正式对象总数。
func get_count() -> int:
	return _instances_by_stable_id.size()


## 递归收集子树内带非空 stable_instance_id 的正式对象（镜像 StableIdService._gather 类口径）。
func _gather(node: Node) -> void:
	for child: Node in node.get_children():
		var candidate: Node = child
		if candidate is PlaceableToken or candidate is GridPlacedObject:
			_index_one(candidate)
		_gather(candidate)


## 收录单个正式对象：空 stable_instance_id 静默跳过；重复 ID push_error 保留首个。
func _index_one(node: Node) -> void:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	var stable_id: String = str(node.get("stable_instance_id"))
	if stable_id.is_empty():
		return
	if _instances_by_stable_id.has(stable_id):
		push_error("ControlRuntimeTargetIndex：重复 stable_instance_id %s，保留首个（场景数据须唯一）。" % stable_id)
		return
	_instances_by_stable_id[stable_id] = node
