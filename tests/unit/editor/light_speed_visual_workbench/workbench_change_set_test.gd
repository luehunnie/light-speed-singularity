extends SceneTree

## S3-03 Workbench 单对象 Change Set 测试（GUI 冻结总结 v1.0 §55/§57）。
## 覆盖：暂存与 Before/After 快照、范围守卫、Apply/Undo/Redo、Preflight 未过禁止、
##       单动作多项恢复、幂等跳过。
## 由 Godot --headless --script 运行；任一失败 quit(1)。
## 载体为内存构造 Profile + 既有正式纹理（不触碰任何 .tres 文件）。

const _ChangeSetScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/visual_change_set.gd"
)
const _EditServiceScript: GDScript = preload(
	"res://addons/light_speed_visual_workbench/backend/editing/visual_state_edit_service.gd"
)
const _ObjectVisualProfile: GDScript = preload(
	"res://gameplay/visuals/object_visuals/object_visual_profile.gd"
)
const _VisualStateTexture: GDScript = preload(
	"res://gameplay/visuals/visual_state_texture.gd"
)
const _NORMAL_UNLIT: String = "res://assets/art/crystal/crystal_normal_unlit.png"
const _NORMAL_LIT: String = "res://assets/art/crystal/crystal_normal_lit.png"
const _BLUE: String = "res://assets/art/crystal/blue_crystal_unactivate.png"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_stage_and_snapshot()
	_test_scope_guards()
	_test_apply_undo_redo()
	_test_preflight_gate()
	_test_single_action_multi_entries()
	_test_idempotent_skip()
	_report()
	quit(0 if _failures.is_empty() else 1)


## 构造测试 Profile：unlit/lit 两状态绑定既有正式纹理。
func _make_profile() -> ObjectVisualProfile:
	var profile: ObjectVisualProfile = _ObjectVisualProfile.new()
	profile.default_state_id = &"unlit"
	var unlit: VisualStateTexture = _VisualStateTexture.new()
	unlit.state_id = &"unlit"
	unlit.world_texture = load(_NORMAL_UNLIT)
	var lit: VisualStateTexture = _VisualStateTexture.new()
	lit.state_id = &"lit"
	lit.world_texture = load(_NORMAL_LIT)
	profile.states = [unlit, lit]
	return profile


## 取 Profile 指定状态的 world_texture。
func _world_texture(profile: ObjectVisualProfile, state_id: StringName) -> Texture2D:
	for state: VisualStateTexture in profile.states:
		if state.state_id == state_id:
			return state.world_texture
	return null


## G1 暂存与快照：entries 记录 old/new 正式路径；旧纹理路径可供 Impact 扫描。
func _test_stage_and_snapshot() -> void:
	const NAME: String = "G1_暂存与快照"
	var profile: ObjectVisualProfile = _make_profile()
	var cs = _ChangeSetScript.new(profile, "user://wb_cs/fake_profile.tres")
	var staged: Dictionary = cs.stage_state_texture(&"lit", load(_BLUE))
	_check(NAME, bool(staged["ok"]), "合法暂存应成功。")
	var entries: Array = cs.get_entries()
	_check(NAME, entries.size() == 1, "应产生 1 条目，实际 %d。" % entries.size())
	_check(NAME, String(entries[0]["old_path"]) == _NORMAL_LIT, "Before 应为 lit 旧纹理路径。")
	_check(NAME, String(entries[0]["new_path"]) == _BLUE, "After 应为 blue 新纹理路径。")
	_check(NAME, cs.get_old_texture_paths() == [_NORMAL_LIT], "旧纹理路径列表应供 Impact 使用。")


## G2 范围守卫：不存在的状态 / 空纹理拒绝；构造即单一 Profile（§55）。
func _test_scope_guards() -> void:
	const NAME: String = "G2_范围守卫"
	var cs = _ChangeSetScript.new(_make_profile(), "user://wb_cs/fake_profile.tres")
	_check(NAME, not bool(cs.stage_state_texture(&"missing", load(_BLUE))["ok"]), "不存在的状态应拒绝。")
	var denied_texture: Dictionary = cs.stage_state_texture(&"lit", null)
	_check(NAME, not bool(denied_texture["ok"]), "空纹理应拒绝。")


## G3 Apply/Undo/Redo：单条目经 UndoRedo 提交，Undo 恢复旧纹理，Redo 重放新纹理；
## Apply 成功后批次清空。
func _test_apply_undo_redo() -> void:
	const NAME: String = "G3_ApplyUndoRedo"
	var profile: ObjectVisualProfile = _make_profile()
	var cs = _ChangeSetScript.new(profile, "user://wb_cs/fake_profile.tres")
	cs.stage_state_texture(&"lit", load(_BLUE))
	var ur := UndoRedo.new()
	var result: Dictionary = cs.apply_all(ur, _EditServiceScript.new(), { passed = true }, "WB Apply")
	_check(NAME, bool(result["ok"]), "Preflight 通过时 Apply 应成功：%s。" % String(result["reason"]))
	_check(NAME, _world_texture(profile, &"lit") == load(_BLUE), "Apply 后 lit 应为 blue。")
	_check(NAME, cs.is_empty(), "Apply 成功后批次应清空。")
	ur.undo()
	_check(NAME, _world_texture(profile, &"lit") == load(_NORMAL_LIT), "Undo 后应恢复 normal_lit。")
	ur.redo()
	_check(NAME, _world_texture(profile, &"lit") == load(_BLUE), "Redo 后应重放 blue。")


## G4 Preflight 门：未通过 / 空批次 / 无效管理器时拒绝且资源不变。
func _test_preflight_gate() -> void:
	const NAME: String = "G4_Preflight门"
	var profile: ObjectVisualProfile = _make_profile()
	var cs = _ChangeSetScript.new(profile, "user://wb_cs/fake_profile.tres")
	_check(NAME, not bool(cs.apply_all(UndoRedo.new(), _EditServiceScript.new(), { passed = false }, "WB")["ok"]), "Preflight 未过应拒绝 Apply。")
	cs.stage_state_texture(&"lit", load(_BLUE))
	_check(NAME, not bool(cs.apply_all(null, _EditServiceScript.new(), { passed = true }, "WB")["ok"]), "无 UndoRedo 应拒绝。")
	_check(NAME, _world_texture(profile, &"lit") == load(_NORMAL_LIT), "被拒绝的资源应保持不变。")


## G5 单动作多项：状态 ×2 + 库存图标一次提交，一次 Undo 全部恢复（Apply All = 一步 Undo）。
func _test_single_action_multi_entries() -> void:
	const NAME: String = "G5_单动作多项"
	var profile: ObjectVisualProfile = _make_profile()
	var cs = _ChangeSetScript.new(profile, "user://wb_cs/fake_profile.tres")
	cs.stage_state_texture(&"unlit", load(_BLUE))
	cs.stage_state_texture(&"lit", load(_BLUE))
	cs.stage_inventory_icon(load(_BLUE))
	var ur := UndoRedo.new()
	var result: Dictionary = cs.apply_all(ur, _EditServiceScript.new(), { passed = true }, "WB Apply All")
	_check(NAME, int(result["applied"]) == 3, "应一次应用 3 项，实际 %d。" % int(result["applied"]))
	_check(NAME, profile.inventory_icon == load(_BLUE), "Apply 后库存图标应为 blue。")
	ur.undo()
	_check(NAME, _world_texture(profile, &"unlit") == load(_NORMAL_UNLIT), "单次 Undo 应同时恢复 unlit。")
	_check(NAME, _world_texture(profile, &"lit") == load(_NORMAL_LIT), "单次 Undo 应同时恢复 lit。")
	_check(NAME, profile.inventory_icon == null, "单次 Undo 应同时恢复库存图标为空。")


## G6 幂等跳过：新旧相同的暂存在 Apply 时跳过、不改资源、批次照常清空。
func _test_idempotent_skip() -> void:
	const NAME: String = "G6_幂等跳过"
	var profile: ObjectVisualProfile = _make_profile()
	var cs = _ChangeSetScript.new(profile, "user://wb_cs/fake_profile.tres")
	cs.stage_state_texture(&"lit", load(_NORMAL_LIT))
	var result: Dictionary = cs.apply_all(UndoRedo.new(), _EditServiceScript.new(), { passed = true }, "WB")
	_check(NAME, bool(result["ok"]) and int(result["applied"]) == 0 and int(result["skipped"]) == 1, "相同纹理应跳过：applied=0 skipped=1。")
	_check(NAME, _world_texture(profile, &"lit") == load(_NORMAL_LIT), "幂等跳过后资源不变。")


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== Workbench Change Set 测试摘要 ====")
	print("测试组数：6")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
