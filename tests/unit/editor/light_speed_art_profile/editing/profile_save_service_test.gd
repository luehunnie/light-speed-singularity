extends SceneTree

## ProfileSaveService D4.5-C1 定向测试。
## 覆盖：null profile、空 resource_path、非 visual_profiles 路径、validate 失败、合法路径校验、
##   保存失败错误传递、不修改 Profile 内容、不创建新路径、禁止 art/addons/.godot、测试不污染正式 Profile。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。
## 不写正式 .tres：保存路径用可注入后端拦截，合法路径校验仅调用 can_save（只读）。

const _SaveServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/profile_save_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
const _BASIC_CRYSTAL_TRES: String = "res://assets/visual_profiles/basic_crystal_visuals.tres"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service = _SaveServiceScript.new()
var _tres_baseline: String = ""


# 捕获后端：记录传入路径并返回指定 Error，用于验证只写入 profile.resource_path。
class _CapturingBackend extends RefCounted:
	var captured_path: String = ""
	var captured_profile: Resource = null
	var return_err: int = 0
	func save(profile: Resource, path: String) -> int:
		captured_path = path
		captured_profile = profile
		return return_err


func _initialize() -> void:
	_tres_baseline = FileAccess.get_file_as_string(_BASIC_CRYSTAL_TRES)
	_test_01_null_profile()
	_test_02_empty_resource_path()
	_test_03_non_visual_profiles_path()
	_test_04_validate_fails()
	_test_05_legal_path_validation()
	_test_06_save_failure_propagated()
	_test_07_does_not_modify_profile()
	_test_08_does_not_create_new_path()
	_test_09_forbidden_paths_denied()
	_test_10_no_formal_profile_pollution()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 1. null profile。
func _test_01_null_profile() -> void:
	const NAME: String = "01_null_profile"
	var r: Dictionary = _service.can_save(null)
	_check(NAME, r.ok == false, "null profile 应拒绝。")


## 2. 空 resource_path。
func _test_02_empty_resource_path() -> void:
	const NAME: String = "02_空resource_path"
	var profile: _ObjectVisualProfile = _make_valid_memory_profile()
	profile.resource_path = ""
	var r: Dictionary = _service.can_save(profile)
	_check(NAME, r.ok == false, "空 resource_path 应拒绝。")


## 3. 非 visual_profiles 路径。
func _test_03_non_visual_profiles_path() -> void:
	const NAME: String = "03_非visual_profiles路径"
	var profile: _ObjectVisualProfile = _make_valid_memory_profile()
	profile.resource_path = "res://gameplay/foo.tres"
	var r: Dictionary = _service.can_save(profile)
	_check(NAME, r.ok == false, "非 visual_profiles 路径应拒绝。")


## 4. validate 失败：profile 缺状态。
func _test_04_validate_fails() -> void:
	const NAME: String = "04_validate失败"
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"default"
	profile.states = []
	profile.resource_path = "res://assets/visual_profiles/__test__.tres"
	var r: Dictionary = _service.can_save(profile)
	_check(NAME, r.ok == false, "validate 失败应拒绝。")
	_check(NAME, r.reason.contains("校验失败"), "拒绝原因应说明校验失败。")


## 5. 合法路径校验：只读加载正式 .tres 并调用 can_save，不写盘。
func _test_05_legal_path_validation() -> void:
	const NAME: String = "05_合法路径校验"
	var profile: _ObjectVisualProfile = load(_BASIC_CRYSTAL_TRES) as _ObjectVisualProfile
	_check(NAME, profile != null, "应加载 basic_crystal_visuals.tres。")
	if profile == null:
		return
	var r: Dictionary = _service.can_save(profile)
	_check(NAME, r.ok == true, "合法路径且 validate 通过应 can_save ok。")
	_check(NAME, r.path == _BASIC_CRYSTAL_TRES, "path 应为正式 .tres 路径。")


## 6. 保存失败错误传递：注入返回错误的后端。
func _test_06_save_failure_propagated() -> void:
	const NAME: String = "06_保存失败错误传递"
	var profile: _ObjectVisualProfile = _make_valid_memory_profile()
	profile.resource_path = "res://assets/visual_profiles/__test__.tres"
	var backend := _CapturingBackend.new()
	backend.return_err = ERR_CANT_CREATE
	_service.set_save_backend(Callable(backend, "save"))
	var r: Dictionary = _service.save(profile)
	_service.clear_save_backend()
	_check(NAME, r.ok == false, "后端返回错误应保存失败。")
	_check(NAME, r.reason.contains("保存失败"), "失败原因应含“保存失败”。")


## 7. 不修改 Profile 内容：保存前后 state/default 不变。
func _test_07_does_not_modify_profile() -> void:
	const NAME: String = "07_不改Profile内容"
	var profile: _ObjectVisualProfile = _make_valid_memory_profile()
	profile.resource_path = "res://assets/visual_profiles/__test__.tres"
	var before_default: StringName = profile.default_state_id
	var before_state_id: StringName = profile.states[0].state_id
	var before_tex: Texture2D = profile.states[0].world_texture
	var backend := _CapturingBackend.new()
	backend.return_err = OK
	_service.set_save_backend(Callable(backend, "save"))
	_service.save(profile)
	_service.clear_save_backend()
	_check(NAME, profile.default_state_id == before_default, "保存不应改 default_state_id。")
	_check(NAME, profile.states[0].state_id == before_state_id, "保存不应改 state_id。")
	_check(NAME, profile.states[0].world_texture == before_tex, "保存不应改 world_texture。")


## 8. 不创建新路径：后端收到的路径等于 profile.resource_path。
func _test_08_does_not_create_new_path() -> void:
	const NAME: String = "08_不创建新路径"
	var profile: _ObjectVisualProfile = _make_valid_memory_profile()
	profile.resource_path = "res://assets/visual_profiles/__test__.tres"
	var backend := _CapturingBackend.new()
	backend.return_err = OK
	_service.set_save_backend(Callable(backend, "save"))
	_service.save(profile)
	_service.clear_save_backend()
	_check(NAME, backend.captured_path == profile.resource_path, "应只写入 profile.resource_path。")
	_check(NAME, backend.captured_profile == profile, "应保存原 profile 对象。")


## 9. 禁止 art/addons/.godot 路径。
func _test_09_forbidden_paths_denied() -> void:
	const NAME: String = "09_禁止art/addons/.godot"
	for path in ["res://assets/art/x.tres", "res://addons/x.tres", "res://.godot/x.tres", "C:/abs/x.tres", "user://x.tres"]:
		var profile: _ObjectVisualProfile = _make_valid_memory_profile()
		profile.resource_path = path
		var r: Dictionary = _service.can_save(profile)
		_check(NAME, r.ok == false, "禁止路径应拒绝：%s" % path)


## 10. 测试不污染正式 Profile：正式 .tres 测试前后内容一致。
func _test_10_no_formal_profile_pollution() -> void:
	const NAME: String = "10_不污染正式Profile"
	var now: String = FileAccess.get_file_as_string(_BASIC_CRYSTAL_TRES)
	_check(NAME, now == _tres_baseline, "basic_crystal_visuals.tres 测试前后内容应一致。")


# ===== 辅助 =====

## 创建合法内存 profile（单状态、validate 通过）。
func _make_valid_memory_profile() -> _ObjectVisualProfile:
	var profile: _ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"default"
	var state: _VisualStateTexture = _VisualStateTexture.new()
	state.state_id = &"default"
	state.world_texture = PlaceholderTexture2D.new()
	state.world_texture.size = Vector2i(32, 32)
	profile.states = [state]
	return profile


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	var group_count: int = 10
	var passed_checks: int = _checks - _failures.size()
	print("==== ProfileSaveService 测试摘要 ====")
	print("测试组数：%d" % group_count)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
