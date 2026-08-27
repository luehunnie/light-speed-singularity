@tool
class_name LightSpeedVisualWorkbenchAssetNaming
extends RefCounted

## Workbench 正式资源命名服务（S3-03；GUI 冻结总结 v1.0 §37）。
## 职责：按内容身份/槽位/状态/方向/用途生成规范技术名，并拦截禁用命名段。
## 输入输出：输入各命名维度字符串与扩展名，输出规范名（String）或问题列表；纯计算无副作用。
## 边界：外部文件原名不进入正式命名体系（本服务只消费结构化维度）；不读文件系统；
##       非 ASCII 字符折叠丢弃（中文身份请提供英文 Stable ID）；不做磁盘唯一性检查（由导入服务覆盖策略处理）。

## §37 禁止长期出现的命名段（final / final2 / _old / _v2 / _v3 等）。
const FORBIDDEN_SEGMENTS: Array = ["final", "final2", "old", "v2", "v3"]
## §37 禁止出现的命名子串（无法按段切分的中文片段）。
const FORBIDDEN_SUBSTRINGS: Array = ["新最终版"]


## 生成规范技术名：各维度折叠为小写蛇形段，空维度跳过，扩展名归一化为无点小写。
## identity 与 slot 为必填维度；任一折叠后为空或扩展名为空时返回 ""（调用方拒绝导入）。
func build_formal_name(identity: String, slot: String, state: String, direction: String, usage: String, extension: String) -> String:
	if _sanitize(identity) == "" or _sanitize(slot) == "":
		return ""
	var ext: String = extension.strip_edges().to_lower().trim_prefix(".")
	if ext == "":
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for part: String in [identity, slot, state, direction, usage]:
		var cleaned: String = _sanitize(part)
		if cleaned != "":
			parts.append(cleaned)
	return "%s.%s" % ["_".join(parts), ext]


## 校验正式名合法性：返回问题列表（空数组 = 合法）。
## 检查 §37 禁用段与禁用子串；空名直接报问题。无副作用。
func lint_formal_name(formal_name: String) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if formal_name == "":
		problems.append("正式名为空。")
		return problems
	for segment: String in formal_name.get_basename().split("_", false):
		if segment.to_lower() in FORBIDDEN_SEGMENTS:
			problems.append("命名段 %s 属于禁用命名（§37）。" % segment)
	for substring: String in FORBIDDEN_SUBSTRINGS:
		if formal_name.contains(substring):
			problems.append("命名包含禁用片段 %s（§37）。" % substring)
	return problems


## 折叠单个维度：小写、仅保留 [a-z0-9]，非法字符折叠为单个下划线，首尾下划线去除。
func _sanitize(part: String) -> String:
	var lowered: String = part.strip_edges().to_lower()
	var out: String = ""
	var last_underscore: bool = false
	for i: int in range(lowered.length()):
		var c: String = lowered[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
			last_underscore = false
		elif not last_underscore and out != "":
			out += "_"
			last_underscore = true
	return out.trim_suffix("_")
