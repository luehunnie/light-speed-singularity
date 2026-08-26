extends SceneTree

## VisualProfileBindService 创建并绑定测试（AF-Artwork P0-3）。
## 覆盖：确定性路径推导、未保存场景拒绝、真实加速器场景成功创建并绑定（P0 案例）、
##   已存在文件拒绝覆盖、已绑定拒绝、owner 不符可操作错误、Undo/Redo、保存失败无副作用。
## 保存后端注入避免磁盘写入；真实加速器 / 镜面场景仅实例化不落盘不改文件。
## 存量视觉接入第一批起真实机关场景均自带 profile 且磁盘已有同名 visuals 文件：
## 成功路径用例改用合成"未绑定已保存场景"夹具（_make_unbound_scene），拒绝类用例沿用真实场景。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。

const _BindServiceScript: GDScript = preload(
	"res://addons/light_speed_art_profile/editing/visual_profile_bind_service.gd"
)
const _AcceleratorScene: PackedScene = preload(
	"res://gameplay/mechanisms/speed/particle_accelerator.tscn"
)
const _MirrorScene: PackedScene = preload(
	"res://gameplay/mechanisms/mirrors/single_cell_mirror.tscn"
)
# 真实素材路径（与既有 dock 测试同源）。
const _REAL_ART_PATH: String = "res://assets/art/crystal/crystal_normal_unlit.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _service: RefCounted = _BindServiceScript.new()
# 注入的保存后端：捕获 (profile, path)，返回指定 Error。
var _backend: RefCounted = _CapturingBackend.new()


class _CapturingBackend extends RefCounted:
	var captured_path: String = ""
	var captured_profile: Resource = null
	var return_err: int = 0
	func save(profile: Resource, path: String) -> int:
		captured_path = path
		captured_profile = profile
		return return_err


func _initialize() -> void:
	_service.set_save_backend(Callable(_backend, "save"))
	_test_01_derive_path_from_scene_stem()
	_test_02_unsaved_scene_denied()
	_test_03_create_and_bind_success()
	_test_04_existing_file_refuses_overwrite()
	_test_05_already_bound_denied()
	_test_06_owner_mismatch_denied()
	_test_07_undo_unbinds_redo_rebinds()
	_test_08_null_texture_denied()
	_test_09_null_undo_redo_denied()
	_test_10_save_error_no_side_effect()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== BindService 测试 =====

## 1. 路径推导：场景文件名 → res://assets/visual_profiles/<stem>_visuals.tres。
func _test_01_derive_path_from_scene_stem() -> void:
	const NAME: String = "01_路径推导"
	var accel: Node = _AcceleratorScene.instantiate()
	var r: Dictionary = _service.derive_profile_path(accel)
	_check(NAME, r.ok == true, "已保存场景应推导成功。")
	_check(NAME, r.path == "res://assets/visual_profiles/particle_accelerator_visuals.tres", "路径应为 <场景名>_visuals.tres。")
	accel.free()


## 2. 未保存场景拒绝：无法确定路径，可操作错误。
func _test_02_unsaved_scene_denied() -> void:
	const NAME: String = "02_未保存场景拒绝"
	var orphan: Node = Node2D.new()
	var r: Dictionary = _service.derive_profile_path(orphan)
	_check(NAME, r.ok == false, "未保存场景应拒绝。")
	_check(NAME, String(r.reason).find("保存") != -1, "拒绝原因应可操作（提示先保存场景）。")
	orphan.free()


## 3. 成功创建并绑定（合成"未绑定已保存场景"夹具：真实机关场景本批起磁盘已有同名 visuals 文件）。
func _test_03_create_and_bind_success() -> void:
	const NAME: String = "03_成功创建绑定"
	var fixture: Array = _make_unbound_scene()
	var scene_root: Node = fixture[0]
	var view: ObjectVisualView = fixture[1]
	_check(NAME, view.visual_profile == null, "前置：合成场景视觉未绑 profile。")
	_check(NAME, view.owner == scene_root, "前置：合成场景内节点 owner 为场景根。")
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.create_and_bind(
		UndoRedo.new(), view, scene_root, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == true, "合法输入应创建成功：%s" % String(r.get("reason", "")))
	_check(NAME, view.visual_profile != null, "创建后 View 应绑定新 profile。")
	var profile: ObjectVisualProfile = view.visual_profile
	_check(NAME, profile.resource_path == "res://assets/visual_profiles/unbound_stub_scene_visuals.tres", "新 profile 应指向确定性路径。")
	_check(NAME, profile.default_state_id == &"default", "默认状态应为 default。")
	_check(NAME, profile.states.size() == 1 and profile.get_world_texture(&"default") == tex, "default 状态应承载所选素材。")
	_check(NAME, profile.validate_profile().is_empty(), "新 profile 应一次通过校验。")
	_check(NAME, _backend.captured_path == profile.resource_path, "保存后端应收到确定性路径。")
	scene_root.free()


## 4. 已存在文件拒绝覆盖：镜像场景 stem 命中既有 single_cell_mirror_visuals.tres。
func _test_04_existing_file_refuses_overwrite() -> void:
	const NAME: String = "04_拒绝覆盖"
	var mirror: Node = _MirrorScene.instantiate()
	root.add_child(mirror)
	var view: ObjectVisualView = mirror.get_node("VisualView") as ObjectVisualView
	view._ready()
	# 仅内存置空以进入创建分支；不触碰磁盘文件。
	view.visual_profile = null
	_backend.captured_path = ""
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.create_and_bind(UndoRedo.new(), view, mirror, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "目标文件已存在应拒绝。")
	_check(NAME, String(r.reason).find("拒绝覆盖") != -1, "拒绝原因应明确拒绝覆盖。")
	_check(NAME, view.visual_profile == null, "拒绝后 View 不应被绑定。")
	_check(NAME, _backend.captured_path == "", "拒绝路径不应触发保存。")
	mirror.free()


## 5. 已有 profile 拒绝：不重复创建。
func _test_05_already_bound_denied() -> void:
	const NAME: String = "05_已绑定拒绝"
	var mirror: Node = _MirrorScene.instantiate()
	root.add_child(mirror)
	var view: ObjectVisualView = mirror.get_node("VisualView") as ObjectVisualView
	view._ready()
	_check(NAME, view.visual_profile != null, "前置：镜面视觉已有 profile。")
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.create_and_bind(UndoRedo.new(), view, mirror, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "已有 profile 应拒绝创建。")
	mirror.free()


## 6. owner 不符拒绝：View 不属于当前编辑场景（实例化子场景语义）时给可操作错误。
func _test_06_owner_mismatch_denied() -> void:
	const NAME: String = "06_owner不符拒绝"
	var accel: Node = _AcceleratorScene.instantiate()
	root.add_child(accel)
	var foreign: ObjectVisualView = preload(
		"res://gameplay/visuals/object_visuals/object_visual_view.tscn").instantiate() as ObjectVisualView
	root.add_child(foreign)
	foreign._ready()
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.create_and_bind(UndoRedo.new(), foreign, accel, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "owner 不符应拒绝。")
	_check(NAME, String(r.reason).find("实例化子场景") != -1, "拒绝原因应指向可操作场景。")
	foreign.free()
	accel.free()


## 7. Undo 解绑 / Redo 重新绑定。
func _test_07_undo_unbinds_redo_rebinds() -> void:
	const NAME: String = "07_UndoRedo"
	var fixture: Array = _make_unbound_scene()
	var scene_root: Node = fixture[0]
	var view: ObjectVisualView = fixture[1]
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var ur := UndoRedo.new()
	var r: Dictionary = _service.create_and_bind(ur, view, scene_root, tex, "创建并绑定视觉配置")
	var bound_profile: ObjectVisualProfile = view.visual_profile
	_check(NAME, r.ok == true, "合成场景应创建成功。")
	ur.undo()
	_check(NAME, view.visual_profile == null, "Undo 后应解绑。")
	ur.redo()
	_check(NAME, view.visual_profile == bound_profile, "Redo 后应重新绑定同一 profile。")
	scene_root.free()


## 8. 未选素材（null 纹理）拒绝。
func _test_08_null_texture_denied() -> void:
	const NAME: String = "08_无纹理拒绝"
	var fixture: Array = _make_unbound_scene()
	var scene_root: Node = fixture[0]
	var view: ObjectVisualView = fixture[1]
	var r: Dictionary = _service.create_and_bind(UndoRedo.new(), view, scene_root, null, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "null 默认纹理应拒绝。")
	_check(NAME, view.visual_profile == null, "拒绝后不应绑定。")
	scene_root.free()


## 9. 未提供 UndoRedo 拒绝。
func _test_09_null_undo_redo_denied() -> void:
	const NAME: String = "09_无UndoRedo拒绝"
	var accel: Node = _AcceleratorScene.instantiate()
	root.add_child(accel)
	var view: ObjectVisualView = accel.get_node("VisualView") as ObjectVisualView
	view._ready()
	view.visual_profile = null
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var r: Dictionary = _service.create_and_bind(null, view, accel, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "null undo_redo 应拒绝。")
	accel.free()


## 10. 保存失败无副作用：View 未绑定、动作未创建。
func _test_10_save_error_no_side_effect() -> void:
	const NAME: String = "10_保存失败无副作用"
	var fixture: Array = _make_unbound_scene()
	var scene_root: Node = fixture[0]
	var view: ObjectVisualView = fixture[1]
	_backend.return_err = ERR_CANT_CREATE
	var tex: Texture2D = ResourceLoader.load(_REAL_ART_PATH)
	var ur := UndoRedo.new()
	var r: Dictionary = _service.create_and_bind(ur, view, scene_root, tex, "创建并绑定视觉配置")
	_check(NAME, r.ok == false, "保存失败应返回失败。")
	_check(NAME, view.visual_profile == null, "保存失败后 View 不应绑定。")
	_backend.return_err = 0
	scene_root.free()


# ===== 辅助 =====

## 合成"未绑定已保存场景"夹具：holder 持伪 scene_file_path（派生路径磁盘必然不存在）、
## view 的 owner 指向 holder；存量视觉接入第一批后真实机关场景均已自带 profile 且磁盘已有
## 同名 visuals 文件，不再具备"缺 profile 且可创建"语义，成功路径用例改用本夹具。
func _make_unbound_scene() -> Array:
	var holder: Node2D = Node2D.new()
	holder.name = "UnboundStubScene"
	holder.scene_file_path = "res://gameplay/mechanisms/speed/unbound_stub_scene.tscn"
	root.add_child(holder)
	var view: ObjectVisualView = preload(
		"res://gameplay/visuals/object_visuals/object_visual_view.tscn").instantiate() as ObjectVisualView
	view.name = "VisualView"
	holder.add_child(view)
	view.owner = holder
	view._ready()
	return [holder, view]


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
	print("==== VisualProfileBindService 测试摘要 ====")
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
