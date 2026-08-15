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
## gameplay/diagnostics 下运行期快照序列化与落盘层（序列化属批次 3B，单次安全落盘属批次 3C-A，
## 数量与容量收敛清理属批次 3C-B）。
## 本批在 3C-A 单次安全落盘基础上，于成功保存后按修改时间从旧到新收敛受管理快照的数量与总容量；
## RuntimeLogger 接线、SelfCheckRunner、DiagnosticsController 与核心循环接线仍属后续批次。
##
## 主要依赖：
## 依赖 RuntimeSnapshotData（D7-R1 Snapshot v1 升级后数据契约）、CrystalSnapshotState、
## EmissionSnapshotState、ParticleSnapshotState、RuntimeSnapshotJsonResult（序列化结果契约）、
## RuntimeSnapshotWriteResult（落盘结果契约），以及 Godot 内建 JSON 序列化与 FileAccess/DirAccess 接口。
## 不依赖场景树、节点、Time、RuntimeLogger 或玩法对象；save() 仅通过 Godot 内建 FileAccess/DirAccess
## 写入 user://diagnostics/snapshots 目录树。
##
## 明确不负责：
## 采集快照数据（由调用方构造 RuntimeSnapshotData）、记录 RuntimeLogger 日志、轮转运行日志、
## 判断关卡完成、修复业务状态、聚合日志。这些属于后续批次或调用方的职责。
##
## 关键边界：
## - 序列化前必须调用 snapshot.validate()，校验失败时返回全部错误且不产出 JSON 文本。
## - 不修改 snapshot 及其子对象：只读取字段，不调用任何会变更状态的方法。
## - serialize() 不访问文件系统、不调用 Time、不调用 push_error、不抛异常、不写 RuntimeLogger、不读取场景树。
## - save() 仅写入 user://diagnostics/snapshots 目录树，不写 RuntimeLogger、不调用 Time、不 push_error、
##   不抛异常、不修改 snapshot 与玩法状态；落盘失败只以中文错误返回，不递归记录自身错误。
## - save() 成功落盘后调用 _converge_snapshot_retention 收敛历史快照数量与容量；清理只 push_warning，
##   不把已成功的 save() 改成失败，不删除刚保存的当前文件，不删除无关文件，不接入 RuntimeLogger。
## - StringName 转普通 String、Vector2i 转 {"x":int,"y":int}、
##   确保输出树中不含 Godot 专有或 RefCounted 对象。
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
## D7-R1 说明：接线前的占位契约从未在生产落盘（无任何 save() 调用方），v1 即首个真实采样 schema。
const SCHEMA_VERSION: int = 1


## 快照默认落盘目录（user:// 协议路径）。
## save() 未显式传入 directory_path 时使用此目录；只允许此目录本身或以其为前缀的合法子目录。
const DEFAULT_SNAPSHOT_DIRECTORY: String = "user://diagnostics/snapshots"

## 单个快照文件最大字节数（1 MiB）。
## 以序列化后 JSON 文本的 UTF-8 字节数为准，超过即拒绝写入且不触碰文件系统。
const MAX_SNAPSHOT_FILE_SIZE_BYTES: int = 1 * 1024 * 1024

## 受管理快照最多保留的文件数量。
## 同一目录下受管理快照超过此数量时，按修改时间从旧到新删除最旧文件，直到满足限制。
const MAX_SNAPSHOT_FILE_COUNT: int = 10

## 受管理快照目录总容量上限（10 MiB）。
## 以受管理快照真实文件字节数累计为准，超过时按修改时间从旧到新删除最旧文件，直到满足限制。
const MAX_SNAPSHOT_DIRECTORY_SIZE_BYTES: int = 10 * 1024 * 1024

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
    # unavailable 政策：level_id 无正式来源时为空字符串，不得用 Node.name 顶替。
    root["level_id"] = String(snapshot.level_id)
    root["run_state"] = String(snapshot.run_state)
    root["is_completed"] = snapshot.is_completed
    root["runtime_generation"] = snapshot.runtime_generation
    root["runtime_move_count"] = snapshot.runtime_move_count
    root["runtime_moves_remaining"] = snapshot.runtime_moves_remaining
    root["runtime_move_limit"] = snapshot.runtime_move_limit
    root["emitter"] = _emitter_to_json(snapshot)
    root["fire_cooldown_ready"] = snapshot.fire_cooldown_ready
    root["active_emission_count"] = snapshot.active_emission_count
    root["emissions"] = _emissions_to_json(snapshot.emission_states)
    root["particles"] = _particles_to_json(snapshot.particle_states)
    root["particle_tick"] = snapshot.particle_tick
    root["particle_active_count"] = snapshot.particle_active_count
    root["ray_segment_count"] = snapshot.ray_segment_count
    root["inventory_remaining"] = snapshot.inventory_remaining
    root["inventory_total"] = snapshot.inventory_total
    root["placed_mechanism_count"] = snapshot.placed_mechanism_count
    root["crystals"] = _crystals_to_json(snapshot.crystal_states)
    root["snapshot_duration_usec"] = snapshot.snapshot_duration_usec
    return root


## 构建发射器子树。
## [br]p_cell 为发射器逻辑格坐标。
## [br]p_direction 为发射器朝向向量。
## [br]返回 Dictionary[String, Variant]：含 cell 与 direction 两个 {"x":int,"y":int} 子对象。
## [br]本函数无副作用：不修改输入，不访问文件或场景树。
static func _emitter_to_json(snapshot: RuntimeSnapshotData) -> Dictionary[String, Variant]:
    var emitter: Dictionary[String, Variant] = {}
    emitter["cell"] = _vector2i_to_json(snapshot.emitter_cell)
    emitter["direction"] = _vector2i_to_json(snapshot.emitter_direction)
    emitter["form"] = snapshot.emitter_form
    emitter["allow_form_switch"] = snapshot.allow_form_switch
    return emitter


## 将活动 emission 快照列表转换为 JSON 兼容数组，保持原顺序。
## [br]返回 Array[Variant]：每个元素含 emission_id、generation、form、runtime_ids 四字段，顺序与输入一致。
## [br]本函数无副作用：只读取输入，不修改原数组或 emission 对象。
static func _emissions_to_json(p_emissions: Array) -> Array[Variant]:
    var out: Array[Variant] = []
    for index: int in range(p_emissions.size()):
        var emission: Variant = p_emissions[index]
        var record: Dictionary[String, Variant] = {}
        record["emission_id"] = emission.emission_id
        record["generation"] = emission.generation
        record["form"] = emission.form
        var runtime_ids: Array[Variant] = []
        for runtime_id: int in emission.runtime_ids:
            runtime_ids.append(runtime_id)
        record["runtime_ids"] = runtime_ids
        out.append(record)
    return out


## 将活动光粒快照列表转换为 JSON 兼容数组，保持原顺序。
## [br]返回 Array[Variant]：每个元素含 runtime_id、emission_id、generation、cell、direction、speed_tier、
## step_started_tick、next_move_tick、active 九字段；Vector2i 转为 {"x":int,"y":int}。
## [br]本函数无副作用：只读取输入，不修改原数组或光粒对象。
static func _particles_to_json(p_particles: Array) -> Array[Variant]:
    var out: Array[Variant] = []
    for index: int in range(p_particles.size()):
        var particle: Variant = p_particles[index]
        var record: Dictionary[String, Variant] = {}
        record["runtime_id"] = particle.runtime_id
        record["emission_id"] = particle.emission_id
        record["generation"] = particle.generation
        record["cell"] = _vector2i_to_json(particle.cell)
        record["direction"] = _vector2i_to_json(particle.direction)
        record["speed_tier"] = particle.speed_tier
        record["step_started_tick"] = particle.step_started_tick
        record["next_move_tick"] = particle.next_move_tick
        record["active"] = particle.active
        out.append(record)
    return out


## 将 Vector2i 转换为 JSON 兼容对象。
## [br]p_value 为待转换的整数二维向量。
## [br]返回 Dictionary[String, Variant]：{"x": int, "y": int}，避免 JSON 树中残留 Vector2i。
## [br]本函数无副作用：不修改输入。
static func _vector2i_to_json(p_value: Vector2i) -> Dictionary[String, Variant]:
    var out: Dictionary[String, Variant] = {}
    out["x"] = p_value.x
    out["y"] = p_value.y
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


## 将一份运行期快照数据序列化并安全落盘到 user://diagnostics/snapshots 目录树。
## [br]snapshot 为待保存的只读快照数据，允许为 null（按失败处理，不触碰文件系统）。
## [br]directory_path 为目标目录，默认为 DEFAULT_SNAPSHOT_DIRECTORY；
## [br]只允许 DEFAULT_SNAPSHOT_DIRECTORY 本身或以其为前缀的合法子目录。
## [br]返回 RuntimeSnapshotWriteResult：成功时 file_path 为最终写入路径、errors 为空；
## [br]失败时 file_path 为空、errors 包含全部中文错误。
## [br]副作用：成功时在目标目录下创建新的 JSON 快照文件（不覆盖既有文件），
## [br]并在目录不存在时递归创建目录；成功落盘后按修改时间从旧到新收敛受管理快照的数量与总容量，
## [br]清理失败只 push_warning，不改变本次已成功的返回结果；不修改 snapshot 及其子对象，不写 RuntimeLogger，不修改玩法状态。
## [br]失败条件：snapshot 为 null 或序列化失败；directory_path 非法或越界；
## [br]JSON 字节数超过 1 MiB；user:// 无法打开；目录创建失败；文件打开、写入或 flush 失败。
## [br]清理时机：仅当 JSON 写入、flush、FileAccess 错误检查与文件关闭均成功后才执行收敛清理；
## [br]序列化失败、路径校验失败、单条超过 1 MiB、目录创建失败、文件打开或写入失败时均不清理。
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
    # 14. 仅在快照已成功落盘后执行数量与容量收敛清理；清理结果不影响本次 save() 的成功状态。
    _converge_snapshot_retention(safe_directory, full_path)
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


## 判断字符串是否完全由十进制数字组成。
## [br]p_text 为待判定的字符串。
## [br]返回 bool：非空且每个字符均为 0-9 时为 true，否则为 false。
## [br]本函数无副作用：不访问文件系统。
## [br]边界条件：空字符串返回 false；不接受符号、空白或非数字字符，因此可排除 "-1"、"+1" 等。
static func _is_decimal_digits(p_text: String) -> bool:
    if p_text.is_empty():
        return false
    for ch: String in p_text:
        # 单字符与 "0"/"9" 按 ASCII 序比较，等价于判断是否为十进制数字。
        if ch < "0" or ch > "9":
            return false
    return true


## 判断一个文件名是否为本模块管理的快照文件。
## [br]p_file_name 为目录枚举得到的纯文件名（不含目录路径）。
## [br]返回 bool：仅当形如 snapshot_<timestamp>.json 或 snapshot_<timestamp>_<collision_index>.json，
## [br]且 timestamp、collision_index 均完全由十进制数字组成、扩展名严格为 .json、前缀严格为 snapshot_ 时为 true。
## [br]本函数无副作用：纯字符串判定，不访问文件系统。
## [br]文件匹配边界：collision_index 只允许出现在 timestamp 后一个下划线段；
## [br]拒绝 snapshot_test.json、snapshot_1_old.json、snapshot_1_2_backup.json、snapshot_1.txt、
## [br]snapshot_1.JSON、snapshot-1.json、snapshot_1_2_3.json、snapshot_1.json.backup、runtime_1.json、notes.json 等。
static func _is_managed_snapshot_file(p_file_name: String) -> bool:
    # 扩展名必须严格为 .json（大小写敏感），排除 .JSON、.txt、.json.backup 等。
    if not p_file_name.ends_with(SNAPSHOT_FILE_EXTENSION):
        return false
    var body: String = p_file_name.substr(0, p_file_name.length() - SNAPSHOT_FILE_EXTENSION.length())
    # 前缀必须严格为 snapshot_，排除 snapshot-1.json、runtime_1.json、notes.json 等。
    if not body.begins_with(SNAPSHOT_FILE_PREFIX):
        return false
    var remainder: String = body.substr(SNAPSHOT_FILE_PREFIX.length())
    # allow_empty=true 以便识别多余下划线导致的空段（如 snapshot_1_.json、snapshot_1__2.json）。
    var parts: PackedStringArray = remainder.split("_", true)
    if parts.size() == 1:
        # snapshot_<timestamp>.json
        return _is_decimal_digits(parts[0])
    if parts.size() == 2:
        # snapshot_<timestamp>_<collision_index>.json
        return _is_decimal_digits(parts[0]) and _is_decimal_digits(parts[1])
    # 0 段（snapshot_.json）或 3 段及以上（snapshot_1_2_3.json）均不视为受管理快照。
    return false


## 收集指定目录下的全部受管理快照文件完整路径。
## [br]p_directory 为已规范化的目标目录路径（user:// 协议）。
## [br]p_out_paths 用于回填结果的数组，调用前会被清空；成功时包含全部受管理快照的完整路径。
## [br]返回 bool：目录成功打开并枚举完成时为 true；DirAccess.open 失败时为 false（p_out_paths 为空）。
## [br]副作用：通过 DirAccess 枚举目录条目，不创建、不写入、不删除文件。
## [br]文件匹配边界：只回填通过 _is_managed_snapshot_file 判定的文件；目录、隐藏文件、无关文件均跳过。
## [br]失败条件：DirAccess.open(p_directory) 返回 null。
static func _collect_managed_snapshot_files(p_directory: String, p_out_paths: Array[String]) -> bool:
    p_out_paths.clear()
    var dir: DirAccess = DirAccess.open(p_directory)
    if dir == null:
        return false
    # 默认排除 . / .. 导航条目与隐藏文件，只枚举普通条目。
    dir.list_dir_begin()
    var entry_name: String = dir.get_next()
    while entry_name != "":
        # current_is_dir 必须紧随 get_next 调用，反映当前条目是否为目录。
        if not dir.current_is_dir():
            if _is_managed_snapshot_file(entry_name):
                p_out_paths.append(p_directory + "/" + entry_name)
        entry_name = dir.get_next()
    dir.list_dir_end()
    return true


## 累计受管理快照的真实文件字节数。
## [br]p_paths 为受管理快照的完整路径列表。
## [br]返回 int：所有可正常打开读取的文件长度之和；无法打开的文件按 0 字节计入（不抛错）。
## [br]副作用：以只读方式逐个打开文件读取 get_length 后立即关闭，不修改文件内容。
## [br]失败条件：单个文件打开失败时跳过该文件，不影响整体统计。
## [br]容量限制：本函数只统计不判定，是否超限由调用方依据 MAX_SNAPSHOT_DIRECTORY_SIZE_BYTES 判断。
static func _compute_managed_snapshot_total_bytes(p_paths: Array[String]) -> int:
    var total: int = 0
    for path: String in p_paths:
        var file: FileAccess = FileAccess.open(path, FileAccess.READ)
        if file != null:
            total += file.get_length()
            file.close()
    return total


## 在候选快照中选择修改时间最旧的一个，修改时间相同时按文件名字典序取最小者。
## [br]p_candidates 为候选快照完整路径列表（已排除当前文件与失败文件），不应为空。
## [br]返回 String：最旧候选的完整路径；候选为空或无法读取修改时间时返回空字符串。
## [br]本函数无副作用：只读取修改时间，不删除文件。
## [br]文件匹配边界：以 FileAccess.get_modified_time 返回的真实文件修改时间为准，
## [br]不使用文件名中的 timestamp 判断新旧，也不依赖 collision_index。
## [br]循环终止条件：单次遍历候选列表，O(n) 完成。
static func _select_oldest_snapshot(p_candidates: Array[String]) -> String:
    if p_candidates.is_empty():
        return ""
    var best_path: String = p_candidates[0]
    var best_mtime: int = FileAccess.get_modified_time(best_path)
    var best_name: String = best_path.get_file()
    for index: int in range(1, p_candidates.size()):
        var path: String = p_candidates[index]
        var mtime: int = FileAccess.get_modified_time(path)
        var name: String = path.get_file()
        # 修改时间更旧者优先；相同时按文件名字典序稳定选择最小者作为删除目标。
        if mtime < best_mtime:
            best_path = path
            best_mtime = mtime
            best_name = name
        elif mtime == best_mtime and name < best_name:
            best_path = path
            best_name = name
    return best_path


## 在一次成功保存后对受管理快照执行数量与容量收敛清理。
## [br]p_directory 为已规范化的目标目录路径（与本次保存路径一致）。
## [br]p_current_file_path 为刚刚成功保存的快照完整路径，整个清理过程中不得删除。
## [br]返回 void：清理结果不影响 save() 的成功状态；任何失败只 push_warning，不抛异常、不改业务状态。
## [br]副作用：当受管理快照数量超过 MAX_SNAPSHOT_FILE_COUNT 或总容量超过 MAX_SNAPSHOT_DIRECTORY_SIZE_BYTES 时，
## [br]按修改时间从旧到新删除最旧的历史快照，每次删除后重新枚举并重新统计，直到同时满足两条限制。
## [br]失败条件：目录枚举失败、删除失败或无可删除候选时分别 push_warning 后安全停止。
## [br]文件匹配边界：只识别并删除 _is_managed_snapshot_file 判定的快照；无关文件、相似前缀文件、
## [br]非数字 timestamp/collision_index 文件一律不删；当前文件永不作为删除目标。
## [br]容量限制：数量上限 MAX_SNAPSHOT_FILE_COUNT（10），总容量上限 MAX_SNAPSHOT_DIRECTORY_SIZE_BYTES（10 MiB）。
## [br]循环终止条件：无固定迭代上限；每轮重新枚举受管理快照、重新计算数量与总容量，两个限制同时满足即返回；
## [br]无可删除候选即返回；单文件删除失败加入 failed_paths 后续排除。终止由三条进度事实保证：
## [br]成功删除会减少受管理文件、删除失败会扩大 failed_paths、没有新删除目标时停止；
## [br]因此历史受管理文件超过 256 个也不会提前结束。异常并发修改目录不属于本模块事务保证。
static func _converge_snapshot_retention(p_directory: String, p_current_file_path: String) -> void:
    var failed_paths: Array[String] = []
    while true:
        var collected: Array[String] = []
        var enumerate_ok: bool = _collect_managed_snapshot_files(p_directory, collected)
        if not enumerate_ok:
            # 目录枚举失败：只警告，不把 save() 改成失败，不删除任何未知文件。
            push_warning("RuntimeSnapshot：枚举快照目录 %s 失败，跳过本次收敛清理。" % p_directory)
            return
        var count: int = collected.size()
        var total_bytes: int = _compute_managed_snapshot_total_bytes(collected)
        # 数量与容量均满足时无需清理；当前文件计入统计。
        if count <= MAX_SNAPSHOT_FILE_COUNT and total_bytes <= MAX_SNAPSHOT_DIRECTORY_SIZE_BYTES:
            return
        # 超限：构造删除候选，排除当前文件与本次已失败文件。
        var candidates: Array[String] = []
        for path: String in collected:
            if path == p_current_file_path:
                continue
            if failed_paths.has(path):
                continue
            candidates.append(path)
        if candidates.is_empty():
            # 仅剩当前文件或全部候选均已失败仍无法满足限制：不删除当前文件，安全停止。
            push_warning("RuntimeSnapshot：受管理快照仍超限但无除当前文件外的可删除候选，停止收敛清理，不删除刚保存的快照。")
            return
        var oldest: String = _select_oldest_snapshot(candidates)
        if oldest == "":
            push_warning("RuntimeSnapshot：无法确定最旧受管理快照，停止收敛清理。")
            return
        var dir: DirAccess = DirAccess.open(p_directory)
        if dir == null:
            push_warning("RuntimeSnapshot：打开目录 %s 用于删除失败，停止收敛清理。" % p_directory)
            return
        var remove_error: int = dir.remove(oldest.get_file())
        if remove_error != OK:
            # 删除失败只警告，把该文件加入失败集合后续排除，避免重试同一文件；
            # failed_paths 单调扩大使候选最终耗尽，保证循环终止。
            push_warning("RuntimeSnapshot：删除快照 %s 失败，错误码 %d，已跳过该文件。" % [oldest, remove_error])
            failed_paths.append(oldest)
            continue
        # 删除成功：受管理文件减少，回到循环顶部重新枚举并重新统计数量与总容量。
