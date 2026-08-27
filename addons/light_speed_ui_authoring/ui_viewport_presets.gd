@tool
class_name LightSpeedUIAuthoringViewportPresets
extends RefCounted

## UI Viewport Preview 预设（S3-04；冻结总结 v1.0 §85）。
## 职责：冻结四个正式 Viewport 预设像素（入口核验最小提案，本批明文冻结）：
##       Standard 16:9=1920x1080、Small 16:9=1280x720、Large 16:9=2560x1440、
##       Minimum Supported=1024x576；Ad-hoc 尺寸仅编辑器临时、不成为正式标准。
## 输入输出：get_presets() 返回 detached 预设数组（{id,label,size,formal}）；
##           build_adhoc_viewport(size) 返回 formal=false 的临时项。
## 副作用：无（纯内存）；切换仅作用于编辑器预览（§85），不改项目窗口设置、不落盘。

## 冻结四预设（像素为 S3-04 实现期冻结值，改此即改合同）。
const PRESET_STANDARD: String = "standard_16_9"
const PRESET_SMALL: String = "small_16_9"
const PRESET_LARGE: String = "large_16_9"
const PRESET_MINIMUM: String = "minimum_supported"
const PRESET_IDS: Array = [PRESET_STANDARD, PRESET_SMALL, PRESET_LARGE, PRESET_MINIMUM]

const _PRESETS: Dictionary = {
	PRESET_STANDARD: { id = PRESET_STANDARD, label = "标准 16:9", size = Vector2i(1920, 1080), formal = true },
	PRESET_SMALL: { id = PRESET_SMALL, label = "小 16:9", size = Vector2i(1280, 720), formal = true },
	PRESET_LARGE: { id = PRESET_LARGE, label = "大 16:9", size = Vector2i(2560, 1440), formal = true },
	PRESET_MINIMUM: { id = PRESET_MINIMUM, label = "最低支持窗口", size = Vector2i(1024, 576), formal = true },
}


## 取一个预设 detached 副本；未知 ID 返回空字典。
func build_preset(preset_id: String) -> Dictionary:
	if not _PRESETS.has(preset_id):
		return {}
	return (_PRESETS[preset_id] as Dictionary).duplicate(true)


## 全部正式预设 detached 列表（Dock 填充用）。
func get_presets() -> Array:
	var list: Array = []
	for preset_id: String in PRESET_IDS:
		list.append(build_preset(preset_id))
	return list


## Ad-hoc 临时 Viewport：仅编辑器预览用途，formal=false，不自动成为正式支持标准（§85）。
func build_adhoc_viewport(size: Vector2i) -> Dictionary:
	return { id = "adhoc_viewport", label = "临时视口（会话）", size = size, formal = false }
