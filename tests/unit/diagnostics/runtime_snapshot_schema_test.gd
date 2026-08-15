extends SceneTree

## RuntimeSnapshotData / RuntimeSnapshot v1 schema 测试（D7-R1）。
## 覆盖：冻结字段表（validate 全量错误 / serialize 成功后顶层键集合与类型 / schema_version=1）、
##   unavailable 政策（level_id 空合法、序列化为空字符串）、emission/particle/crystal 子契约结构、
##   重复序列化确定性、duplicate_data 独立性、null 快照拒绝、手动单次写盘成功且文件可读（测试子目录，含清理）。
## headless extends SceneTree，由 Godot --script 运行；通过 quit(0)，任一失败 quit(1)。

const _Data: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_data.gd")
const _Snapshot: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot.gd")
const _EmissionState: GDScript = preload("res://gameplay/diagnostics/snapshot/emission_snapshot_state.gd")
const _ParticleState: GDScript = preload("res://gameplay/diagnostics/snapshot/particle_snapshot_state.gd")
const _CrystalState: GDScript = preload("res://gameplay/diagnostics/snapshot/crystal_snapshot_state.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 8

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_validate_ok_and_frozen_fields()
	_test_02_validate_reports_all_problems()
	_test_03_serialize_success_and_frozen_keys()
	_test_04_unavailable_level_id_policy()
	_test_05_deterministic_and_duplicate()
	_test_06_null_snapshot_rejected()
	_test_07_emission_particle_contracts()
	_test_08_manual_write_once()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造一份合法样例数据（RAY emission + PARTICLE emission 各一、两颗光粒、一颗水晶）。
func _make_valid_data() -> _Data:
	var emissions: Array[_EmissionState] = []
	var empty_runtime_ids: Array[int] = []
	emissions.append(_EmissionState.new(1, 3, _LightEmissionTypes.LightForm.RAY, empty_runtime_ids))
	var particle_runtime_ids: Array[int] = [0, 1]
	emissions.append(_EmissionState.new(2, 3, _LightEmissionTypes.LightForm.PARTICLE, particle_runtime_ids))
	var particles: Array[_ParticleState] = []
	particles.append(_ParticleState.new(0, 2, 3, Vector2i(1, 3), Vector2i(1, 0), 1, 0, 4, true))
	particles.append(_ParticleState.new(1, 2, 3, Vector2i(2, 3), Vector2i(1, 0), 1, 0, 4, true))
	var crystals: Array[_CrystalState] = []
	crystals.append(_CrystalState.new(&"c001", Vector2i(5, 5), true, &"lit"))
	return _Data.new(
		1700000000000, &"", &"PULSE_ACTIVE", false,
		3, 0, 1, 1,
		Vector2i(1, 3), Vector2i(1, 0), _LightEmissionTypes.LightForm.PARTICLE, true, false,
		2, emissions, particles,
		7, 2, 6,
		1, 3, 0,
		crystals, 42
	)


## 1. 合法样例 validate 通过 + 冻结字段读写一致。
func _test_01_validate_ok_and_frozen_fields() -> void:
	const G: String = "01_合法样例"
	var data: _Data = _make_valid_data()
	_check(G, data.validate().is_empty(), "合法样例 validate 应无错误：%s" % ["；".join(data.validate())])
	_check(G, data.runtime_generation == 3 and data.emitter_form == _LightEmissionTypes.LightForm.PARTICLE, "runtime_generation/emitter_form 读写应一致。")
	_check(G, data.active_emission_count == 2 and data.emission_states.size() == 2, "emission 数量应一致。")


## 2. validate 一次报告全部问题（负计数 / 零方向 / 非法 form / 计数不一致）。
func _test_02_validate_reports_all_problems() -> void:
	const G: String = "02_validate全量错误"
	var emissions: Array[_EmissionState] = []
	var particles: Array[_ParticleState] = []
	var crystals: Array[_CrystalState] = []
	var bad: _Data = _Data.new(
		-1, &"", &"", true,
		-2, -1, -1, -1,
		Vector2i.ZERO, Vector2i.ZERO, 9, false, true,
		5, emissions, particles,
		-1, -1, -1,
		-1, -1, -1,
		crystals, -1
	)
	var problems: PackedStringArray = bad.validate()
	_check(G, problems.size() >= 10, "应一次报告 >=10 个问题，实际 %d。" % problems.size())
	_check(G, _has_substring(problems, "run_state 为空"), "应报告 run_state 为空。")
	_check(G, _has_substring(problems, "emitter_direction 为零向量"), "应报告零方向。")
	_check(G, _has_substring(problems, "emitter_form 数值 9"), "应报告非法 emitter_form。")
	_check(G, _has_substring(problems, "active_emission_count（5）与 emission_states.size()（0）不一致"), "应报告 emission 计数不一致。")


## 3. serialize 成功 + 顶层冻结键集合（多不缺）+ 子结构类型。
func _test_03_serialize_success_and_frozen_keys() -> void:
	const G: String = "03_冻结键集合"
	var result: Variant = _Snapshot.serialize(_make_valid_data())
	_check(G, result.is_success(), "合法样例应序列化成功：%s" % ["；".join(result.errors)])
	var parsed: Dictionary = JSON.parse_string(result.json_text) as Dictionary
	var expected_keys: Array[String] = [
		"schema_version", "timestamp_unix_msec", "level_id", "run_state", "is_completed",
		"runtime_generation", "runtime_move_count", "runtime_moves_remaining", "runtime_move_limit",
		"emitter", "fire_cooldown_ready", "active_emission_count", "emissions", "particles",
		"particle_tick", "particle_active_count", "ray_segment_count",
		"inventory_remaining", "inventory_total", "placed_mechanism_count",
		"crystals", "snapshot_duration_usec",
	]
	_check(G, parsed.size() == expected_keys.size(), "顶层键数量期望 %d，实际 %d。" % [expected_keys.size(), parsed.size()])
	for key: String in expected_keys:
		_check(G, parsed.has(key), "顶层缺少冻结键 %s。" % key)
	_check(G, int(parsed["schema_version"]) == 1, "schema_version 应为 1。")
	var emitter: Dictionary = parsed["emitter"]
	_check(G, emitter.has("cell") and emitter.has("direction") and emitter.has("form") and emitter.has("allow_form_switch"), "emitter 子树应有 cell/direction/form/allow_form_switch 四键。")
	var emissions: Array = parsed["emissions"]
	_check(G, emissions.size() == 2 and emissions[0].has("runtime_ids") and int(emissions[1]["runtime_ids"].size()) == 2, "emissions 子结构应含 runtime_ids 列表。")
	var particles_json: Array = parsed["particles"]
	_check(G, particles_json.size() == 2 and int(particles_json[0]["emission_id"]) == 2 and bool(particles_json[0]["active"]), "particles 子结构应含 emission_id 关联与 active。")


## 4. unavailable 政策：level_id 空合法（validate 不报错），序列化为空字符串。
func _test_04_unavailable_level_id_policy() -> void:
	const G: String = "04_level_id_unavailable"
	var data: _Data = _make_valid_data()
	_check(G, data.level_id == &"", "无正式来源时 level_id 应为空。")
	var problems: PackedStringArray = data.validate()
	_check(G, not _has_substring(problems, "level_id"), "level_id 为空不应被 validate 报为错误（unavailable 政策）。")
	var result: Variant = _Snapshot.serialize(data)
	var parsed: Dictionary = JSON.parse_string(result.json_text) as Dictionary
	_check(G, String(parsed["level_id"]) == "", "level_id 应序列化为空字符串。")


## 5. 同一份数据重复序列化文本一致；duplicate_data 与原对象独立。
func _test_05_deterministic_and_duplicate() -> void:
	const G: String = "05_确定性与深复制"
	var data: _Data = _make_valid_data()
	var first: String = _Snapshot.serialize(data).json_text
	var second: String = _Snapshot.serialize(data).json_text
	_check(G, first == second, "重复序列化文本应一致。")
	var copy: _Data = data.duplicate_data()
	copy.emission_states[0].emission_id = 999
	copy.particle_states[0].cell = Vector2i(-9, -9)
	copy.crystal_states[0].is_activated = false
	_check(G, data.emission_states[0].emission_id == 1, "修改副本 emission 不应影响原对象。")
	_check(G, data.particle_states[0].cell == Vector2i(1, 3), "修改副本光粒 cell 不应影响原对象。")
	_check(G, data.crystal_states[0].is_activated, "修改副本水晶不应影响原对象。")


## 6. null 快照拒绝（空 JSON + 中文错误）。
func _test_06_null_snapshot_rejected() -> void:
	const G: String = "06_null拒绝"
	var result: Variant = _Snapshot.serialize(null)
	_check(G, not result.is_success() and result.json_text == "" and not result.errors.is_empty(), "null 快照应拒绝并返回中文错误。")


## 7. EmissionSnapshotState / ParticleSnapshotState 子契约校验与深复制。
func _test_07_emission_particle_contracts() -> void:
	const G: String = "07_子契约"
	var bad_empty: Array[int] = []
	var bad_emission: _EmissionState = _EmissionState.new(0, -1, 9, bad_empty)
	var emission_problems: PackedStringArray = bad_emission.validate()
	_check(G, emission_problems.size() == 3, "emission 三类非法（id<1/generation<0/form 非法）应全报，实际 %d。" % emission_problems.size())
	var source_ids: Array[int] = [7, 8]
	var emission: _EmissionState = _EmissionState.new(3, 2, _LightEmissionTypes.LightForm.PARTICLE, source_ids)
	source_ids.append(9)
	_check(G, emission.runtime_ids.size() == 2, "构造后修改源数组不应影响快照 runtime_ids。")
	var bad_particle: _ParticleState = _ParticleState.new(-1, 0, -1, Vector2i.ZERO, Vector2i(2, 2), 0, -1, -1, false)
	var particle_problems: PackedStringArray = bad_particle.validate()
	_check(G, particle_problems.size() >= 6, "particle 六类非法应全报，实际 %d。" % particle_problems.size())


## 8. 手动单次写盘成功（测试子目录）、文件存在且可解析；随后删除测试文件与目录。
func _test_08_manual_write_once() -> void:
	const G: String = "08_手动单次写盘"
	var data: _Data = _make_valid_data()
	var directory: String = "user://diagnostics/snapshots/schema_test"
	var result: Variant = _Snapshot.save(data, directory)
	_check(G, result.is_success(), "save 应成功：%s" % ["；".join(result.errors)])
	_check(G, FileAccess.file_exists(result.file_path), "快照文件应存在：%s" % result.file_path)
	var text: String = FileAccess.open(result.file_path, FileAccess.READ).get_as_text()
	_check(G, (JSON.parse_string(text) as Dictionary).has("schema_version"), "落盘文件应可解析回 JSON 对象。")
	# 清理测试文件与子目录，不留测试残留。
	var dir: DirAccess = DirAccess.open(directory)
	if dir != null:
		dir.remove(result.file_path.get_file())
		DirAccess.open("user://diagnostics/snapshots").remove("schema_test")


## 辅助：问题列表是否含子串。
func _has_substring(p_problems: PackedStringArray, p_fragment: String) -> bool:
	for problem: String in p_problems:
		if problem.contains(p_fragment):
			return true
	return false


# ===== 断言与报告 =====

## 单项断言。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== RuntimeSnapshot v1 schema 测试摘要（D7-R1）====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
