class_name RuntimeSnapshot
extends RefCounted

## 运行期快照 JSON 序列化器。
##
## 职责：
## 将一份 RuntimeSnapshotData 只读事实摘要转换为结构稳定的 JSON 文本，
## 并以 RuntimeSnapshotJsonResult 返回文本与中文错误（不写文件、不记录日志、不接入核心循环）；
## 并提供 save() 将序列化结果安全落盘到 user://diagnostics/snapshots 目录树，
## 以 RuntimeSnapshotWriteResult 返回最终文件路径与中文错误。
##
## 在当前系统中的位置：
## gameplay/diagnostics 下运行期快照序列化与落盘层（序列化属批次 3B，单次安全落盘属批次 3C-A）。
## 本批实现序列化边界与单次安全落盘；快照数量与容量清理、轮转、RuntimeLogger 接线、SelfCheckRunner、
## DiagnosticsController 与核心循环接线均属后续批次。
##
## 主要依赖：
## 依赖 RuntimeSnapshotData（批次 3A 数据契约）、CrystalSnapshotState（批次 3A）、
## SelfCheckResult（批次 1B）、RuntimeSnapshotJsonResult（批次 3B 序列化结果契约）、
## RuntimeSnapshotWriteResult（本批次落盘结果契约），以及 Godot 内建 JSON 序列化与 FileAccess/DirAccess 接口。
## 不依赖场景树、节点、Time、RuntimeLogger 或玩法对象；save() 仅通过 Godot 内建 FileAccess/DirAccess
## 写入 user://diagnostics/snapshots 目录树。
##
## 明确不负责：
## 采集快照数据（由调用方构造 RuntimeSnapshotData）、写入文件、轮转、记录日志、
## 判断关卡完成、修复业务状态、聚合日志。这些属于后续批次或调用方的职责。
##
## 关键边界：
## - 序列化前必须调用 snapshot.validate()，校验失败时返回全部错误且不产出 JSON 文本。
## - 不修改 snapshot 及其子对象：只读取字段，不调用任何会变更状态的方法。
## - serialize() 不访问文件系统、不调用 Time、不调用 push_error、不抛异常、不写 RuntimeLogger、不读取场景树。
## - save() 仅写入 user://diagnostics/snapshots 目录树，不写 RuntimeLogger、不调用 Time、不 push_error、
##   不抛异常、不修改 snapshot 与玩法状态；落盘失败只以中文错误返回，不递归记录自身错误。
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


## 快照默认落盘目录（user:// 协议路径）。
## save() 未显式传入 directory_path 时使用此目录；只允许此目录本身或以其为前缀的合法子目录。
const DEFAULT_SNAPSHOT_DIRECTORY: String = "user://diagnostics/snapshots"

## 单个快照文件最大字节数（1 MiB）。
## 以序列化后 JSON 文本的 UTF-8 字节数为准，超过即拒绝写入且不触碰文件系统。
const MAX_SNAPSHOT_FILE_SIZE_BYTES: int = 1 * 1024 * 1024

## 快照文件名前缀，固定为 "snapshot_"。
const SNAPSHOT_FILE_PREFIX: String = "snapshot_"

## 快照文件扩展名，固定为 ".json"。
const SNAPSHOT_FILE_EXTENSION: String = ".json"


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


## 将一份运行期快照数据序列化并安全落盘到 user://diagnostics/snapshots 目录树。
## [br]snapshot 为待保存的只读快照数据，允许为 null（按失败处理，不触碰文件系统）。
## [br]directory_path 为目标目录，默认为 DEFAULT_SNAPSHOT_DIRECTORY；
## [br]只允许 DEFAULT_SNAPSHOT_DIRECTORY 本身或以其为前缀的合法子目录。
## [br]返回 RuntimeSnapshotWriteResult：成功时 file_path 为最终写入路径、errors 为空；
## [br]失败时 file_path 为空、errors 包含全部中文错误。
## [br]副作用：成功时在目标目录下创建新的 JSON 快照文件（不覆盖既有文件），
## [br]并在目录不存在时递归创建目录；不修改 snapshot 及其子对象，不写 RuntimeLogger，不修改玩法状态。
## [br]失败条件：snapshot 为 null 或序列化失败；directory_path 非法或越界；
## [br]JSON 字节数超过 1 MiB；user:// 无法打开；目录创建失败；文件打开、写入或 flush 失败。
## [br]路径边界：只允许 user://diagnostics/snapshots 及其合法子目录；
## [br]拒绝 res://、原生绝对路径、相对路径、空路径、反斜杠逃逸、.. 逃逸与同级仿冒目录。
## [br]大小边界：以 json_text 的 UTF-8 字节数为准，超过 1 MiB 立即拒绝且在此之前不创建目录、不打开文件、不查询已有快照。
static func save(
        snapshot: RuntimeSnapshotData,
        directory_path: String = DEFAULT_SNAPSHOT_DIRECTORY
) -> RuntimeSnapshotWriteResult:
    # 1-2. 先序列化：失败时直接返回全部错误，不触碰文件系统。
    var json_result: RuntimeSnapshotJsonResult = serialize(snapshot)
    if not json_result.is_success():
        return RuntimeSnapshotWriteResult.new("", json_result.errors)
    var json_text: String = json_result.json_text
    # 3. 校验并规范化目录路径：纯字符串操作，不访问文件系统。
    var path_errors: PackedStringArray = _validate_snapshot_directory(directory_path)
    if not path_errors.is_empty():
        return RuntimeSnapshotWriteResult.new("", path_errors)
    var safe_directory: String = _normalize_directory_path(directory_path)
    # 4. 以 UTF-8 字节数为真实大小，避免按字符数误判多字节中文内容。
    var byte_size: int = json_text.to_utf8_buffer().size()
    # 5-6. 超过 1 MiB 立即拒绝：此时尚未创建目录、打开文件或查询已有快照。
    if byte_size > MAX_SNAPSHOT_FILE_SIZE_BYTES:
        return RuntimeSnapshotWriteResult.new("", PackedStringArray([
            "RuntimeSnapshot：快照大小 %d 字节超过上限 %d 字节（1 MiB），已拒绝写入。" % [byte_size, MAX_SNAPSHOT_FILE_SIZE_BYTES]
        ]))
    # 7. 大小合法后才创建目录：以 user:// 为根递归创建目标目录。
    var dir: DirAccess = DirAccess.open("user://")
    if dir == null:
        return RuntimeSnapshotWriteResult.new("", PackedStringArray([
            "RuntimeSnapshot：无法打开 user:// 目录，快照落盘失败。"
        ]))
    var relative_dir: String = safe_directory.substr("user://".length())
    if not dir.dir_exists(relative_dir):
        var make_error: int = dir.make_dir_recursive(relative_dir)
        if make_error != OK:
            return RuntimeSnapshotWriteResult.new("", PackedStringArray([
                "RuntimeSnapshot：创建快照目录 %s 失败，错误码 %d。" % [safe_directory, make_error]
            ]))
    # 8-9. 根据快照自身时间戳生成文件名，避免覆盖既有快照文件。
    var file_name: String = _generate_snapshot_file_name(snapshot, safe_directory)
    var full_path: String = safe_directory + "/" + file_name
    # 10-11. 写入完整 JSON：不在末尾追加换行，flush 后在关闭前检查 FileAccess 错误。
    var file: FileAccess = FileAccess.open(full_path, FileAccess.WRITE)
    if file == null:
        return RuntimeSnapshotWriteResult.new("", PackedStringArray([
            "RuntimeSnapshot：无法打开快照文件 %s 写入，错误码 %d。" % [full_path, FileAccess.get_open_error()]
        ]))
    file.store_string(json_text)
    file.flush()
    var write_error: int = file.get_error()
    file.close()
    if write_error != OK:
        return RuntimeSnapshotWriteResult.new("", PackedStringArray([
            "RuntimeSnapshot：写入快照文件 %s 失败，错误码 %d。" % [full_path, write_error]
        ]))
    # 12-13. 成功返回最终文件路径；失败已在前置分支以中文错误返回。
    return RuntimeSnapshotWriteResult.new(full_path, PackedStringArray())


## 规范化快照目录路径：strip_edges、统一反斜杠为正斜杠、规约 . 与 .. 段。
## [br]p_path 为调用方传入的原始目录字符串。
## [br]返回 String：结构合法时返回以 "user://" 开头的规范化路径（无尾斜杠、无空段）；
## [br]结构非法时返回空字符串——涵盖非 user:// 协议、空路径、.. 逃逸到 user:// 之上等情况。
## [br]本函数无副作用：纯字符串操作，不访问文件系统、不 push_error、不抛异常。
## [br]边界条件：不做 snapshots 前缀检查（由 _validate_snapshot_directory 负责），
## [br]仅保证路径结构合法且不逃逸出 user:// 根。
static func _normalize_directory_path(p_path: String) -> String:
    # strip_edges 去除首尾空白，避免空白干扰前缀判断。
    var trimmed: String = p_path.strip_edges()
    if trimmed == "":
        return ""
    # 统一反斜杠为正斜杠：防止 Windows 风格路径绕过分段检查。
    var unified: String = trimmed.replace("\\", "/")
    var prefix: String = "user://"
    # 非 user:// 协议（res://、原生绝对路径、相对路径等）一律拒绝。
    if not unified.begins_with(prefix):
        return ""
    var relative: String = unified.substr(prefix.length())
    # split 第二参数 false 表示丢弃空段，自动处理双斜杠与尾斜杠。
    var raw_segments: PackedStringArray = relative.split("/", false)
    var segments: PackedStringArray = PackedStringArray()
    for seg: String in raw_segments:
        if seg == ".":
            # 当前目录段：直接忽略，不改变段栈。
            continue
        elif seg == "..":
            # 上级目录段：段栈为空表示逃逸到 user:// 之上，判非法。
            if segments.is_empty():
                return ""
            segments.remove_at(segments.size() - 1)
        else:
            segments.append(seg)
    if segments.is_empty():
        return prefix
    return prefix + "/".join(segments)


## 校验快照目录路径是否落在允许的边界内。
## [br]p_path 为调用方传入的原始目录字符串。
## [br]返回 PackedStringArray：合法时为空；非法或越界时包含中文错误。
## [br]本函数无副作用：纯字符串操作，不访问文件系统、不 push_error、不抛异常。
## [br]边界条件：只允许 DEFAULT_SNAPSHOT_DIRECTORY 本身或以其加 "/" 为前缀的合法子目录；
## [br]以 / 边界做前缀检查，拒绝 snapshots_evil、snapshots2 等同级仿冒目录。
static func _validate_snapshot_directory(p_path: String) -> PackedStringArray:
    var normalized: String = _normalize_directory_path(p_path)
    if normalized == "":
        return PackedStringArray([
            "RuntimeSnapshot：directory_path 非法，必须为 user://diagnostics/snapshots 或其合法子目录。"
        ])
    if normalized == DEFAULT_SNAPSHOT_DIRECTORY:
        return PackedStringArray()
    # 以 "/" 为明确边界检查子目录前缀，避免 snapshots_evil/snapshots2 等仿冒目录命中。
    if normalized.begins_with(DEFAULT_SNAPSHOT_DIRECTORY + "/"):
        return PackedStringArray()
    return PackedStringArray([
        "RuntimeSnapshot：directory_path 越界，只允许 user://diagnostics/snapshots 或其合法子目录。"
    ])


## 根据快照自身时间戳生成不覆盖既有文件的快照文件名。
## [br]p_snapshot 为已通过序列化的只读快照数据，文件名取自其 timestamp_unix_msec。
## [br]p_directory 为已规范化的目标目录路径，用于查询同名文件是否存在。
## [br]返回 String：首选 "snapshot_<timestamp>.json"；若已存在则依次返回 "snapshot_<timestamp>_1.json"、
## [br]"snapshot_<timestamp>_2.json"……直到命中不存在的文件名。
## [br]副作用：通过 FileAccess.file_exists 查询目标目录下已有文件，不创建、不写入、不删除文件。
## [br]边界条件：后缀只能是非负十进制整数（1、2、3……）；不使用随机数；不使用系统当前时间替代快照自身时间；
## [br]相同快照重复保存可生成不同文件名，但 JSON 内容保持相同；文件名由模块生成，不接受调用方任意文件名。
static func _generate_snapshot_file_name(
        p_snapshot: RuntimeSnapshotData,
        p_directory: String
) -> String:
    var timestamp_text: String = String.num_int64(p_snapshot.timestamp_unix_msec)
    var base_name: String = SNAPSHOT_FILE_PREFIX + timestamp_text + SNAPSHOT_FILE_EXTENSION
    # 首选文件名不存在时直接采用，不附加后缀。
    if not FileAccess.file_exists(p_directory + "/" + base_name):
        return base_name
    # 同名文件已存在：依次追加 _1、_2 … 后缀，直到命中不存在的文件名；后缀为非负十进制整数。
    var suffix: int = 1
    while suffix > 0:
        var candidate: String = (
            SNAPSHOT_FILE_PREFIX + timestamp_text + "_" + String.num_int64(suffix) + SNAPSHOT_FILE_EXTENSION
        )
        if not FileAccess.file_exists(p_directory + "/" + candidate):
            return candidate
        suffix += 1
    # 不可达：suffix 溢出才会落到此处，保留返回以满足返回类型检查。
    return base_name
