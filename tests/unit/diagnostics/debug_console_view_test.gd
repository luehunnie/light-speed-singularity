extends SceneTree

## DebugConsoleView Debug-only 只读控制台测试（D7-R1）。
## 覆盖：打开/关闭（toggle/set_open/is_open，打开自动刷新）；显示摘要来自注入采样（run_state/generation/
##   emission/Particle 数/emitter form+direction）；允许的安全诊断触发（手动序列化成功 / 手动写盘成功且文件存在，
##   测试子目录并清理）；公开方法白名单（无越权能力）；源代码禁止令牌扫描（无任意 GDScript 执行 / 无玩法变更 API）；
##   触发不改玩法（采样 provider 数据为只读 detached 事实）。
## headless extends SceneTree，由 Godot --script 运行；通过 quit(0)，任一失败 quit(1)。

const _ConsoleView: GDScript = preload("res://gameplay/diagnostics/console/debug_console_view.gd")
const _Data: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_data.gd")
const _EmissionState: GDScript = preload("res://gameplay/diagnostics/snapshot/emission_snapshot_state.gd")
const _ParticleState: GDScript = preload("res://gameplay/diagnostics/snapshot/particle_snapshot_state.gd")
const _CrystalState: GDScript = preload("res://gameplay/diagnostics/snapshot/crystal_snapshot_state.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 6

## 公开方法白名单（冻结；出现白名单外公开方法即测试失败）。
const _ALLOWED_METHODS: PackedStringArray = [
	"setup", "set_open", "is_open", "toggle",
	"refresh_display", "trigger_serialize_snapshot", "trigger_write_snapshot",
	"get_display_text", "get_status_text", "get_recent_lines",
]

## 源代码禁止令牌（出现即测试失败：任意代码执行 / 玩法变更 / 场景编辑能力）。
const _FORBIDDEN_TOKENS: PackedStringArray = [
	"Expression", "eval(", "request_fire", "reset_runtime", "begin_pulse", "finish_pulse",
	"toggle_light_form", "on_fire_success", "advance_one_tick", "consume_runtime_move",
	"change_scene", "pack(", "instantiate",
]

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _written_files: Array[String] = []
## 保持采样桩 holder 引用（Callable 不保留 RefCounted，防回收致 provider 失效）。
var _holders: Array = []


func _initialize() -> void:
	_test_01_toggle_open_close()
	_test_02_display_from_sample_provider()
	_test_03_allowed_triggers()
	_test_04_method_allowlist()
	_test_05_forbidden_tokens_absent()
	_test_06_triggers_do_not_mutate_sample()
	_cleanup_written_files()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 采样 provider 桩：返回固定合法 RuntimeSnapshotData（无 Runtime 依赖；数据同构于真实采样产物）。
func _make_data() -> _Data:
	var emissions: Array[_EmissionState] = []
	var runtime_ids: Array[int] = [0]
	emissions.append(_EmissionState.new(1, 2, _LightEmissionTypes.LightForm.PARTICLE, runtime_ids))
	var particles: Array[_ParticleState] = []
	particles.append(_ParticleState.new(0, 1, 2, Vector2i(3, 3), Vector2i(1, 0), 1, 0, 4, true))
	var crystals: Array[_CrystalState] = []
	crystals.append(_CrystalState.new(&"c001", Vector2i(6, 3), true, &"lit"))
	return _Data.new(
		1700000000000, &"", &"PULSE_ACTIVE", false,
		2, 1, 0, 1,
		Vector2i(1, 3), Vector2i(1, 0), _LightEmissionTypes.LightForm.PARTICLE, true, false,
		1, emissions, particles,
		7, 1, 6,
		1, 3, 0,
		crystals, 42
	)


## 构造挂到临时 CanvasLayer 的控制台（sample 桩 provider；写盘指向测试子目录）。
func _make_console(directory: String) -> _ConsoleView:
	var holder: _SampleHolder = _SampleHolder.new()
	holder.data = _make_data()
	_holders.append(holder)
	var console: _ConsoleView = _ConsoleView.new(Callable(holder, "sample"), directory)
	var canvas: CanvasLayer = CanvasLayer.new()
	root.add_child(canvas)
	console.setup(canvas)
	return console


## 采样桩持有者（保持 RefCounted 引用，避免 Callable 不保留 RefCounted 坑）。
class _SampleHolder:
	extends RefCounted
	var data: Variant = null
	func sample() -> Variant:
		return data


## 释放控制台与其临时 CanvasLayer（同步 free；headless --script 不泵帧，不用 queue_free）。
func _free_console(console: _ConsoleView) -> void:
	var parent: Node = console.get_parent()
	console.free()
	if parent is CanvasLayer:
		parent.free()

## 1. 打开/关闭：默认关；toggle 开（自动刷新）；set_open(false) 关。
func _test_01_toggle_open_close() -> void:
	const G: String = "01_开关"
	var console: _ConsoleView = _make_console("user://diagnostics/snapshots/console_test")
	_check(G, not console.is_open(), "初始应关闭。")
	console.toggle()
	_check(G, console.is_open(), "toggle 后应打开。")
	_check(G, not console.get_display_text().is_empty(), "打开时应自动刷新显示。")
	console.set_open(false)
	_check(G, not console.is_open(), "set_open(false) 后应关闭。")
	_free_console(console)


## 2. 显示摘要来自注入采样：run_state / generation / emission / Particle / emitter form+direction / NOT IMPLEMENTED 行。
func _test_02_display_from_sample_provider() -> void:
	const G: String = "02_显示摘要"
	var console: _ConsoleView = _make_console("user://diagnostics/snapshots/console_test")
	console.set_open(true)
	var text: String = console.get_display_text()
	_check(G, text.contains("PULSE_ACTIVE"), "应显示 run_state=PULSE_ACTIVE。")
	_check(G, text.contains("generation：2"), "应显示 runtime_generation=2。")
	_check(G, text.contains("活动 emission：1") and text.contains("活动 Particle：1"), "应显示活动 emission 与 Particle 数。")
	_check(G, text.contains("form：PARTICLE") and text.contains("direction(1,0)"), "应显示发射器 form 与 direction。")
	_check(G, text.contains("NOT IMPLEMENTED"), "无法低侵入获得的指标应显示 NOT IMPLEMENTED。")
	_free_console(console)


## 3. 允许的安全诊断触发：手动序列化成功（仅内存）；手动写盘成功且文件存在。
func _test_03_allowed_triggers() -> void:
	const G: String = "03_安全诊断触发"
	var console: _ConsoleView = _make_console("user://diagnostics/snapshots/console_test")
	console.set_open(true)
	_check(G, console.trigger_serialize_snapshot(), "手动序列化应成功。")
	_check(G, console.get_status_text().contains("未写盘"), "序列化状态应注明未写盘。")
	var write_ok: bool = console.trigger_write_snapshot()
	_check(G, write_ok, "手动写盘应成功：%s" % console.get_status_text())
	var status: String = console.get_status_text()
	if write_ok:
		# 记录落盘路径供 _initialize 末尾统一清理。
		var path: String = status.substr(status.find("user://"))
		_written_files.append(path)
		_check(G, FileAccess.file_exists(path), "写盘文件应存在。")
	_check(G, console.get_recent_lines().size() > 0, "应有最近诊断行记录。")
	_free_console(console)


## 4. 公开方法白名单：脚本声明的非下划线方法必须全部在白名单内（无越权能力面）。
func _test_04_method_allowlist() -> void:
	const G: String = "04_方法白名单"
	var console: _ConsoleView = _ConsoleView.new(Callable())
	var declared: PackedStringArray = PackedStringArray()
	for method: Dictionary in console.get_script().get_script_method_list():
		var method_name: String = String(method["name"])
		if not method_name.begins_with("_"):
			declared.append(method_name)
	_check(G, declared.size() == _ALLOWED_METHODS.size(), "公开方法数量期望 %d，实际 %d：%s" % [_ALLOWED_METHODS.size(), declared.size(), ",".join(declared)])
	for method_name: String in declared:
		_check(G, _ALLOWED_METHODS.has(method_name), "公开方法 %s 不在白名单内（越权能力面）。" % method_name)
	_free_console(console)


## 5. 源代码禁止令牌：控制台脚本源码不得包含任意代码执行 / 玩法变更 API 令牌。
func _test_05_forbidden_tokens_absent() -> void:
	const G: String = "05_禁止令牌"
	var source: String = _ConsoleView.source_code
	_check(G, not source.is_empty(), "应能读取控制台源码。")
	for token: String in _FORBIDDEN_TOKENS:
		_check(G, not source.contains(token), "控制台源码不得包含禁止令牌 %s。" % token)


## 6. 触发不改采样数据：序列化 / 写盘前后 provider 数据字段一致（只读事实不被控制台修改）。
func _test_06_triggers_do_not_mutate_sample() -> void:
	const G: String = "06_触发零修改"
	var holder: _SampleHolder = _SampleHolder.new()
	holder.data = _make_data()
	var console: _ConsoleView = _ConsoleView.new(Callable(holder, "sample"), "user://diagnostics/snapshots/console_test")
	console.set_open(true)
	console.trigger_serialize_snapshot()
	var after: Variant = holder.data
	_check(G, after.run_state == &"PULSE_ACTIVE" and after.runtime_generation == 2, "触发后采样数据字段不变。")
	_check(G, after.emission_states.size() == 1 and after.emission_states[0].emission_id == 1, "触发不得修改 emission 事实。")
	_check(G, after.crystal_states[0].is_activated, "触发不得修改水晶事实。")
	_free_console(console)


## 清理本测试写盘的文件与子目录。
func _cleanup_written_files() -> void:
	for path: String in _written_files:
		var dir: DirAccess = DirAccess.open(path.get_base_dir())
		if dir != null:
			dir.remove(path.get_file())
	var snapshots_dir: DirAccess = DirAccess.open("user://diagnostics/snapshots")
	if snapshots_dir != null and snapshots_dir.dir_exists("console_test"):
		snapshots_dir.remove("console_test")


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
	print("==== DebugConsoleView 只读控制台测试摘要（D7-R1）====")
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
