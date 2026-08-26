extends RefCounted

## 关卡根 metadata move_limit 只读解析器（AF-10 第二批）。
## 职责：把关卡根节点持久化的 move_limit metadata（编辑器 Authoring Rules 面板写入）解析为运行期移动上限 int。
## 复用冻结 schema：条目形状与缺省语义镜像 BusinessDataService（Guide §87.1）的 read_move_limit——
## { enabled: bool, max_count: int }，缺省 enabled=false（禁用不落语义，不用 -1 哨兵）；
## 运行期不 preload 编辑器插件（同 MetadataInventoryReader 先例），schema 形状只读镜像不建第二套。
## 兼容语义：metadata 缺失 / 非 Dictionary / enabled=false → 返回 fallback_limit（现有场景 @export
## runtime_move_limit 默认值，即原型"未配置"既有行为）；enabled=true → 返回 max_count
## （编辑器侧 validate_move_limit 保证 ≥1；手写 metadata 绕过校验时此处 maxi 钳 1 防零上限卡死）。
## 不负责：写 metadata、编辑器侧读写（Authoring 插件负责）、运行期计次/拒绝/重置事务
## （RuntimeMoveRules + LevelRuntimeController 既有链负责，本模块只在装配期提供上限事实）。


## move_limit 在关卡根 metadata 上的持久化键（与编辑器 Authoring 写入侧一致）。
const METADATA_KEY: String = "move_limit"


## 读取关卡根 move_limit metadata 解析为运行期移动上限。
## [br]level_root 为关卡内容根节点（与 inventory_entries 同一读取目标）；fallback_limit 为
## metadata 缺失/禁用/整体非法时的兼容默认值（调用方传入场景导出的 runtime_move_limit 原值）。
static func read_runtime_move_limit(level_root: Node, fallback_limit: int) -> int:
	if level_root == null:
		push_error(
			"MetadataMoveLimitReader: 关卡根节点为空，运行期移动上限退回默认值 %d。" % [fallback_limit]
		)
		return fallback_limit
	if not level_root.has_meta(METADATA_KEY):
		return fallback_limit
	var raw: Variant = level_root.get_meta(METADATA_KEY)
	if typeof(raw) != TYPE_DICTIONARY:
		push_error(
			"MetadataMoveLimitReader: move_limit metadata 不是 Dictionary（类型 %d），运行期移动上限退回默认值 %d。"
			% [typeof(raw), fallback_limit]
		)
		return fallback_limit
	if not bool(raw.get("enabled", false)):
		return fallback_limit
	var max_count: int = int(raw.get("max_count", 1))
	return maxi(max_count, 1)
