@tool
class_name LightSpeedUIAuthoringPreviewData
extends RefCounted

## UI Preview Data 服务（S3-04；冻结总结 v1.0 §84）。
## 职责：提供四个冻结只读 Preview 预设（Minimal/Typical/Long Content/Stress Test）
##       与 Ad-hoc 临时数据构建；全部为内存字典，只存在编辑器。
## 输入输出：build_preset(id) 返回 detached 字典；build_adhoc(base, overrides) 返回
##           全新字典且不修改 base；不落盘、不写关卡、不改 Validator 标准（§84）。
## 副作用：无（纯内存构造；本服务不 import/export、不 FileAccess 写）。

## 冻结四预设 ID（§84）。
const PRESET_MINIMAL: String = "minimal"
const PRESET_TYPICAL: String = "typical"
const PRESET_LONG_CONTENT: String = "long_content"
const PRESET_STRESS_TEST: String = "stress_test"
const PRESET_IDS: Array = [PRESET_MINIMAL, PRESET_TYPICAL, PRESET_LONG_CONTENT, PRESET_STRESS_TEST]

## Ad-hoc 覆盖白名单（未知键拒绝，防把假数据演变成第二套数据合同）。
const ADHOC_KEYS: Array = ["inventory_count", "objective_text", "hint_text", "counter_value"]

const _PRESETS: Dictionary = {
	PRESET_MINIMAL: {
		id = PRESET_MINIMAL, label = "最小",
		inventory_count = 0,
		objective_text = "点亮水晶",
		hint_text = "",
		counter_value = 0,
	},
	PRESET_TYPICAL: {
		id = PRESET_TYPICAL, label = "典型",
		inventory_count = 4,
		objective_text = "在 12 步内点亮全部水晶并抵达出口",
		hint_text = "镜面可以转折光路",
		counter_value = 12,
	},
	PRESET_LONG_CONTENT: {
		id = PRESET_LONG_CONTENT, label = "长内容",
		inventory_count = 8,
		objective_text = "在限定步数内依次激活三座加速机关，绕行减速区域，点亮全部水晶后从右下出口离开本关",
		hint_text = "长提示：光速粒子穿过分隔墙前会减速，利用镜面组合两次转折可以节省至少三步",
		counter_value = 99,
	},
	PRESET_STRESS_TEST: {
		id = PRESET_STRESS_TEST, label = "压力测试",
		inventory_count = 24,
		objective_text = "压力测试目标文本：这是一个明显超出常规展示宽度的超长目标描述，用于验证目标面板在极端内容下的裁切与换行行为是否可控",
		hint_text = "压力测试提示文本：同样明显超长的提示内容，用于验证提示面板在极端内容下是否溢出或遮挡其他必要模块",
		counter_value = 9999,
	},
}


## 取一个预设的 detached 副本（调用方修改不影响冻结源）。
func build_preset(preset_id: String) -> Dictionary:
	if not _PRESETS.has(preset_id):
		return {}
	return (_PRESETS[preset_id] as Dictionary).duplicate(true)


## 全部预设 detached 列表（Dock 填充用）。
func build_all_presets() -> Array:
	var list: Array = []
	for preset_id: String in PRESET_IDS:
		list.append(build_preset(preset_id))
	return list


## Ad-hoc 临时数据：基于 base 的覆盖副本，只存在当前编辑会话（§84 不改标准 Preset/不落盘）。
## 未知键拒绝（返回空字典并附 reason），base 一律不被修改。
func build_adhoc(base: Dictionary, overrides: Dictionary) -> Dictionary:
	if base.is_empty():
		return { error = "base 预设缺失。" }
	var merged: Dictionary = base.duplicate(true)
	for key: String in overrides.keys():
		if not (key in ADHOC_KEYS):
			return { error = "Ad-hoc 不允许键：%s（白名单 %s）。" % [key, ", ".join(PackedStringArray(ADHOC_KEYS))] }
		merged[key] = overrides[key]
	merged["id"] = "adhoc"
	merged["label"] = "临时（会话）"
	return merged
