class_name RuntimeSnapshot
extends RefCounted

## 运行期快照 JSON 序列化器。
##
## 职责：
## 将一份 RuntimeSnapshotData 只读事实摘要转换为结构稳定的 JSON 文本，
## 并以 RuntimeSnapshotJsonResult 返回文本与中文错误；不写文件、不记录日志、不接入核心循环。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照序列化层（批次 3B 实现）。
## 本批只实现序列化边界；快照落盘、轮转、RuntimeLogger 接线、SelfCheckRunner、
## DiagnosticsController 与核心循环接线均属后续批次。
##
## 主要依赖：
## 依赖 RuntimeSnapshotData（批次 3A 数据契约）、CrystalSnapshotState（批次 3A）、
## SelfCheckResult（批次 1B）、RuntimeSnapshotJsonResult（本批次结果契约），
## 以及 Godot 内建 JSON 序列化接口。
## 不依赖场景树、节点、文件系统、Time、RuntimeLogger 或玩法对象。
##
## 明确不负责：
## 采集快照数据（由调用方构造 RuntimeSnapshotData）、写入文件、轮转、记录日志、
## 判断关卡完成、修复业务状态、聚合日志。这些属于后续批次或调用方的职责。
##
## 关键边界：
## - 序列化前必须调用 snapshot.validate()，校验失败时返回全部错误且不产出 JSON 文本。
## - 不修改 snapshot 及其子对象：只读取字段，不调用任何会变更状态的方法。
## - 不访问文件系统、不调用 Time、不调用 push_error、不抛异常、不写 RuntimeLogger、不读取场景树。
## - StringName 转普通 String、Vector2i 转 {"x":int,"y":int}、Rect2i 拆为 position/size、
##   PackedStringArray 转普通字符串数组，确保输出树中不含 Godot 专有或 RefCounted 对象。
## - JSON 文本由 JSON.stringify 生成，不手工拼接，转义由序列化器负责。
## - 同一份快照重复序列化得到相同 JSON 文本：不引入当前时间或随机值，
##   数组顺序保持调用方快照中的原顺序。
##
## JSON Variant 边界（必要例外）：
## Godot JSON 接口要求输入为 JSON 兼容的 Variant 树，因此私有转换辅助函数内部使用
## Dictionary[String, Variant] 与 Array[Variant] 构建中间数据树。此 Variant 使用严格限定在
## 私有 JSON 转换边界内，不暴露为公开返回值，不替代 RuntimeSnapshotData 强类型契约，
## 也不接收任意 Variant 输入；公开数据契约与公开接口仍保持强类型。


## 快照 JSON 结构版本号。
## 当前冻结为 1；后续结构变更时递增，以便旧消费者识别版本。
const SCHEMA_VERSION: int = 1


## 将一份运行期快照数据序列化为稳定 JSON 文本。
## [br]snapshot 为待序列化的只读快照数据，允许为 null（按失败处理）。
## [br]返回 RuntimeSnapshotJsonResult：成功时 json_text 为非空 JSON、errors 为空；
## [br]失败时 json_text 为空、errors 包含全部中文错误。
## [br]本函数无副作用：不修改 snapshot 及其子对象，不访问文件系统、Time、RuntimeLogger 或场景树，
## [br]不 push_error、不抛异常。
## [br]失败条件：snapshot 为 null，或 snapshot.validate() 返回非空错误。
## [br]边界条件：校验通过后才构建 JSON 树；JSON 文本由 JSON.stringify 生成，不手工拼接；
## [br]同一份快照重复调用得到相同文本，数组顺序保持快照中的原顺序。
static func serialize(snapshot: RuntimeSnapshotData) -> RuntimeSnapshotJsonResult:
    # null 快照无法校验也无法序列化：返回中文错误与空 JSON，不抛异常。
    if snapshot == null:
        return RuntimeSnapshotJsonResult.new(
            "",
            PackedStringArray(["RuntimeSnapshot：snapshot 为 null，必须提供 RuntimeSnapshotData。"])
        )
    # 先只读校验：失败时一次返回全部错误且不产出 JSON，避免输出半成品快照。
    var problems: PackedStringArray = snapshot.validate()
    if not problems.is_empty():
        return RuntimeSnapshotJsonResult.new("", problems)
    # 校验通过后构建 JSON 兼容数据树并交给序列化器；构建过程只读 snapshot 字段，不修改原对象。
    var root: Dictionary[String, Variant] = _build_root(snapshot)
    # sort_keys 传 false 以保留冻结结构中声明的字段顺序，确保多次序列化文本一致。
    var json_text: String = JSON.stringify(root, "", false)
    return RuntimeSnapshotJsonResult.new(json_text, PackedStringArray())


## 构建快照顶层 JSON 数据树。
## [br]snapshot 为已通过校验的只读快照数据。
## [br]返回 Dictionary[String, Variant]：顶层字段顺序与冻结结构一致，
## [br]所有 Godot 专有类型已转换为 JSON 兼容形式。
## [br]本函数无副作用：只读取 snapshot 字段，不修改原对象，不访问文件或场景树。
static func _build_root(snapshot: RuntimeSnapshotData) -> Dictionary[String, Variant]:
    var root: Dictionary[String, Variant] = {}
    root["schema_version"] = SCHEMA_VERSION
    root["timestamp_unix_msec"] = snapshot.timestamp_unix_msec
    # StringName 必须转普通 String，否则 JSON 树中会残留 StringName 无法稳定序列化。
    root["run_state"] = String(snapshot.run_state)
    root["is_completed"] = snapshot.is_completed
    root["emitter"] = _emitter_to_json(snapshot.emitter_cell, snapshot.emitter_direction)
    root["map_bounds"] = _rect2i_to_json(snapshot.map_bounds)
    root["wall_cells"] = _vector2i_list_to_json(snapshot.wall_cells)
    root["light_path_count"] = snapshot.light_path_count
    root["inventory_remaining"] = snapshot.inventory_remaining
    root["placed_mechanism_count"] = snapshot.placed_mechanism_count
    root["runtime_move_count"] = snapshot.runtime_move_count
    root["crystals"] = _crystals_to_json(snapshot.crystal_states)
    root["occupancy_consistency"] = _self_check_to_json(snapshot.occupancy_consistency)
    return root


## 构建发射器子树。
## [br]p_cell 为发射器逻辑格坐标。
## [br]p_direction 为发射器朝向向量。
## [br]返回 Dictionary[String, Variant]：含 cell 与 direction 两个 {"x":int,"y":int} 子对象。
## [br]本函数无副作用：不修改输入，不访问文件或场景树。
static func _emitter_to_json(p_cell: Vector2i, p_direction: Vector2i) -> Dictionary[String, Variant]:
    var emitter: Dictionary[String, Variant] = {}
    emitter["cell"] = _vector2i_to_json(p_cell)
    emitter["direction"] = _vector2i_to_json(p_direction)
    return emitter


## 将 Vector2i 转换为 JSON 兼容对象。
## [br]p_value 为待转换的整数二维向量。
## [br]返回 Dictionary[String, Variant]：{"x": int, "y": int}，避免 JSON 树中残留 Vector2i。
## [br]本函数无副作用：不修改输入。
static func _vector2i_to_json(p_value: Vector2i) -> Dictionary[String, Variant]:
    var out: Dictionary[String, Variant] = {}
    out["x"] = p_value.x
    out["y"] = p_value.y
    return out


## 将 Rect2i 拆分为 JSON 兼容对象。
## [br]p_value 为待转换的整数矩形。
## [br]返回 Dictionary[String, Variant]：含 position 与 size 两个 {"x":int,"y":int} 子对象，
## [br]避免 JSON 树中残留 Rect2i。
## [br]本函数无副作用：不修改输入。
static func _rect2i_to_json(p_value: Rect2i) -> Dictionary[String, Variant]:
    var out: Dictionary[String, Variant] = {}
    out["position"] = _vector2i_to_json(p_value.position)
    out["size"] = _vector2i_to_json(p_value.size)
    return out


## 将 Vector2i 列表转换为 JSON 兼容数组，保持原顺序。
## [br]p_values 为待转换的墙体格列表。
## [br]返回 Array[Variant]：每个元素为 {"x":int,"y":int}，顺序与输入一致。
## [br]本函数无副作用：只读取输入，不修改原数组。
static func _vector2i_list_to_json(p_values: Array[Vector2i]) -> Array[Variant]:
    var out: Array[Variant] = []
    for index: int in range(p_values.size()):
        # 保持调用方快照中的原顺序，确保重复序列化文本一致。
        out.append(_vector2i_to_json(p_values[index]))
    return out


## 将水晶状态列表转换为 JSON 兼容数组，保持原顺序。
## [br]p_crystals 为待转换的水晶状态列表（已通过校验，元素非空）。
## [br]返回 Array[Variant]：每个元素为水晶子对象，顺序与输入一致。
## [br]本函数无副作用：只读取输入，不修改原数组或水晶对象。
static func _crystals_to_json(p_crystals: Array[CrystalSnapshotState]) -> Array[Variant]:
    var out: Array[Variant] = []
    for index: int in range(p_crystals.size()):
        out.append(_crystal_to_json(p_crystals[index]))
    return out


## 将单个水晶状态转换为 JSON 兼容对象。
## [br]p_crystal 为待转换的水晶状态（已通过校验）。
## [br]返回 Dictionary[String, Variant]：含 crystal_id、cell、is_activated、state_label 四个字段，
## [br]StringName 字段转为普通 String，cell 转为 {"x":int,"y":int}。
## [br]本函数无副作用：只读取输入，不修改原对象。
static func _crystal_to_json(p_crystal: CrystalSnapshotState) -> Dictionary[String, Variant]:
    var out: Dictionary[String, Variant] = {}
    # StringName 转 String：避免 JSON 树残留 StringName。
    out["crystal_id"] = String(p_crystal.crystal_id)
    out["cell"] = _vector2i_to_json(p_crystal.cell)
    out["is_activated"] = p_crystal.is_activated
    out["state_label"] = String(p_crystal.state_label)
    return out


## 将占用一致性自检结果转换为 JSON 兼容对象。
## [br]p_result 为待转换的自检结果（已通过校验，非空）。
## [br]返回 Dictionary[String, Variant]：含 check_id、passed、summary、details、duration_usec 五个字段，
## [br]StringName 转 String，PackedStringArray 转普通字符串数组。
## [br]本函数无副作用：只读取输入，不修改原对象。
static func _self_check_to_json(p_result: SelfCheckResult) -> Dictionary[String, Variant]:
    var out: Dictionary[String, Variant] = {}
    out["check_id"] = String(p_result.check_id)
    out["passed"] = p_result.passed
    out["summary"] = p_result.summary
    out["details"] = _packed_strings_to_json(p_result.details)
    out["duration_usec"] = p_result.duration_usec
    return out


## 将 PackedStringArray 转换为 JSON 兼容字符串数组，保持原顺序。
## [br]p_values 为待转换的字符串数组。
## [br]返回 Array[Variant]：元素为普通 String，顺序与输入一致。
## [br]本函数无副作用：只读取输入，不修改原数组。
static func _packed_strings_to_json(p_values: PackedStringArray) -> Array[Variant]:
    var out: Array[Variant] = []
    for index: int in range(p_values.size()):
        out.append(p_values[index])
    return out
