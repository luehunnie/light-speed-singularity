@tool
class_name LightSpeedVisualWorkbenchChangeSetPreflight
extends RefCounted

## Workbench Change Set Preflight（S3-03；GUI 冻结总结 v1.0 §57/§39）。
## 职责：Apply All 前运行当前 Change Set 的最小相关 Preflight，输出逐项检查结果，
##       任一 fail 即整体不通过（§57：Apply 前自动运行；§39：Strict 尺寸阻止）。
## 输入输出：输入 Change Set 与尺寸合同 {mode: "strict"|"recommended"|"free",
##           expected_size: Vector2i}，返回 {passed: bool, checks: Array[{id, status, detail}]}，
##           status ∈ pass/fail/warning/skipped；warning 不阻断。
## 副作用：无（纯读取 Change Set 暂存与 Profile 内存状态，不改资源不改文件）。
## 边界：§57 “例如”清单中的 animation / successor cycle / theme required semantics /
##       legal fallback 首批降级为 skipped 并注明；required_slot 以 Profile 自身声明的
##       状态集为视觉合同（零 MechanismDefinition 扩张）：Apply 后每个声明状态都必须
##       有 world_texture 且 default_state_id 可解析。

const CHECK_IMPORT_COMPLETE: String = "import_complete"
const CHECK_REQUIRED_SLOT: String = "required_slot"
const CHECK_SIZE_CONTRACT: String = "size_contract"
const CHECK_ANIMATION: String = "animation_assets"
const CHECK_SUCCESSOR: String = "successor_cycle"
const CHECK_THEME_SEMANTICS: String = "theme_required_semantics"
const CHECK_LEGAL_FALLBACK: String = "legal_fallback"

## §57 清单的固定呈现顺序（首批后四项降级）。
const CHECK_IDS: Array = [
	CHECK_IMPORT_COMPLETE, CHECK_REQUIRED_SLOT, CHECK_SIZE_CONTRACT,
	CHECK_ANIMATION, CHECK_SUCCESSOR, CHECK_THEME_SEMANTICS, CHECK_LEGAL_FALLBACK,
]


## 运行 Preflight。change_set 为 LightSpeedVisualWorkbenchChangeSet；
## size_contract 为空字典时按 free 处理。返回 {passed, checks}。
func run(change_set, size_contract: Dictionary = {}) -> Dictionary:
	var checks: Array = []
	checks.append(_check_import_complete(change_set))
	checks.append(_check_required_slot(change_set))
	checks.append(_check_size_contract(change_set, size_contract))
	var degraded: String = "首批未开通（降级，§57 例如清单子集）。"
	for id: String in [CHECK_ANIMATION, CHECK_SUCCESSOR, CHECK_THEME_SEMANTICS, CHECK_LEGAL_FALLBACK]:
		checks.append({ id = id, status = "skipped", detail = degraded })
	var passed: bool = true
	for check: Dictionary in checks:
		if String(check["status"]) == "fail":
			passed = false
	return { passed = passed, checks = checks }


## import_complete：每项暂存新纹理必须非空且已落盘正式路径（resource_path 非空）。
func _check_import_complete(change_set) -> Dictionary:
	var problems: PackedStringArray = PackedStringArray()
	for entry: Dictionary in change_set.get_entries():
		var texture: Texture2D = null
		if String(entry["kind"]) == "state":
			texture = change_set.get_staged_new_texture(entry["state_id"])
		else:
			texture = change_set.get_staged_icon_texture()
		if texture == null:
			problems.append("%s 项新纹理缺失。" % String(entry["kind"]))
		elif texture.resource_path == "":
			problems.append("新纹理未落盘正式路径（%s 项）。" % String(entry["kind"]))
	if problems.is_empty():
		return { id = CHECK_IMPORT_COMPLETE, status = "pass", detail = "全部暂存纹理已就绪。" }
	return { id = CHECK_IMPORT_COMPLETE, status = "fail", detail = "，".join(problems) }


## required_slot：模拟 Apply 后逐状态校验——每个声明状态的生效纹理
## （暂存新纹理优先，否则当前 world_texture）非空；default_state_id 可解析。
func _check_required_slot(change_set) -> Dictionary:
	var profile: ObjectVisualProfile = change_set.get_profile()
	if profile == null:
		return { id = CHECK_REQUIRED_SLOT, status = "fail", detail = "Profile 未绑定。" }
	var missing: PackedStringArray = PackedStringArray()
	var checked: int = 0
	for state: VisualStateTexture in profile.states:
		if state == null:
			continue
		checked += 1
		var effective: Texture2D = change_set.get_staged_new_texture(state.state_id)
		if effective == null:
			effective = state.world_texture
		if effective == null:
			missing.append("状态 %s 在 Apply 后仍无正式纹理。" % state.state_id)
	if profile.default_state_id == &"":
		missing.append("default_state_id 为空。")
	elif not profile.has_state(profile.default_state_id):
		missing.append("default_state_id=%s 在状态集中不存在。" % profile.default_state_id)
	if missing.is_empty():
		return { id = CHECK_REQUIRED_SLOT, status = "pass", detail = "已校验 %d 个声明状态，Required Slot 全部落位。" % checked }
	return { id = CHECK_REQUIRED_SLOT, status = "fail", detail = "；".join(missing) }


## size_contract：逐暂存纹理比对声明尺寸（§39：Strict 阻止 / Recommended 警告 / Free 跳过）。
func _check_size_contract(change_set, size_contract: Dictionary) -> Dictionary:
	var mode: String = String(size_contract.get("mode", "free"))
	var expected: Vector2i = size_contract.get("expected_size", Vector2i.ZERO)
	if mode == "free" or expected == Vector2i.ZERO:
		return { id = CHECK_SIZE_CONTRACT, status = "skipped", detail = "未声明尺寸合同。" }
	var problems: PackedStringArray = PackedStringArray()
	var warnings: PackedStringArray = PackedStringArray()
	var textures: Array = []
	for entry: Dictionary in change_set.get_entries():
		if String(entry["kind"]) == "state":
			textures.append(change_set.get_staged_new_texture(entry["state_id"]))
	for texture: Texture2D in textures:
		if texture == null:
			continue
		var actual: Vector2i = Vector2i(texture.get_size())
		if actual == expected:
			continue
		var text: String = "纹理 %s 尺寸 %s 不符合同 %s。" % [texture.resource_path, actual, expected]
		if mode == "strict":
			problems.append(text)
		else:
			warnings.append(text)
	if not problems.is_empty():
		return { id = CHECK_SIZE_CONTRACT, status = "fail", detail = "Strict 合同不合法：" + "，".join(problems) }
	if not warnings.is_empty():
		return { id = CHECK_SIZE_CONTRACT, status = "warning", detail = "，".join(warnings) }
	return { id = CHECK_SIZE_CONTRACT, status = "pass", detail = "尺寸全部符合合同。" }
