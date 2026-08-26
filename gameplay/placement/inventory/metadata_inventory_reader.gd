extends RefCounted

## 关卡根 metadata inventory_entries 只读解析器（AF-10 第一批）。
## 职责：把关卡根节点持久化的 inventory_entries metadata（编辑器 Authoring 写入的三字段条目）解析为
## LevelInventoryEntry 冻结 schema（content_type_id / initial_quantity / order），并按类型读取初始库存数量。
## 不建第二套 schema：条目字段形状与合法性校验全部复用 LevelInventoryEntry；order 本批仅解析保留
## （原型单槽位 UI 不消费，多类型排序留后续批次）。
## 兼容语义：metadata 缺失或整体不是 Array 时返回调用方默认值（原型默认 PROTOTYPE_TOKEN_TOTAL）；
## metadata 存在但无匹配类型条目返回 0（LevelInventoryEntry 冻结语义：0 = 本关不提供该类型）；
## 非法条目 push_error 后跳过，不中断其余条目解析。
## 不负责：写 metadata、编辑器侧读写（Authoring 插件负责）、库存运行期事务、Definition 加载。


const _LevelInventoryEntry: GDScript = preload(
	"res://gameplay/placement/inventory/level_inventory_entry.gd"
)

## inventory_entries 在关卡根 metadata 上的持久化键（与编辑器 Authoring 写入侧一致）。
const METADATA_KEY: String = "inventory_entries"


## 读取关卡根 inventory_entries metadata 中指定类型的初始数量。
## [br]level_root 为关卡内容根节点（原型场景根或 Host 模式 LevelRoot 纯关卡根）；
## type_id 为要查询的机关 content_type_id；fallback_total 为 metadata 缺失/整体非法时的兼容默认值。
## [br]同类型出现多个条目属作者数据错误：push_error 诊断并以首个条目数量为准（确定性结果，不静默）。
static func read_initial_total_for_type(
		level_root: Node,
		type_id: StringName,
		fallback_total: int
) -> int:
	if level_root == null:
		push_error(
			"MetadataInventoryReader: 关卡根节点为空，库存初始化退回默认值 %d。" % [fallback_total]
		)
		return fallback_total
	if not level_root.has_meta(METADATA_KEY):
		return fallback_total
	var raw_entries: Variant = level_root.get_meta(METADATA_KEY)
	if typeof(raw_entries) != TYPE_ARRAY:
		push_error(
			"MetadataInventoryReader: inventory_entries metadata 不是 Array（类型 %d），库存初始化退回默认值 %d。"
			% [typeof(raw_entries), fallback_total]
		)
		return fallback_total
	var result_total: int = -1
	for raw_entry: Variant in raw_entries:
		var entry: _LevelInventoryEntry = _parse_entry(raw_entry)
		if entry == null:
			continue
		if entry.content_type_id != type_id:
			continue
		if result_total >= 0:
			push_error(
				"MetadataInventoryReader: inventory_entries 存在 %s 的重复条目，以首个数量 %d 为准。"
				% [type_id, result_total]
			)
			continue
		result_total = entry.initial_quantity
	if result_total < 0:
		return 0
	return result_total


## 读取关卡根 inventory_entries 的全部条目，按 order 升序返回多类型库存计划（AF-10 第三批）。
## [br]level_root 为关卡内容根节点；返回 Array[Dictionary]，每项 {content_type_id: StringName,
## initial_quantity: int, order: int}；metadata 缺失、整体不是 Array 或无合法条目时返回空数组
## （调用方决定兼容回退：原型单类型路径不在本函数内复制）。
## [br]排序稳定：order 相同保持 metadata 书写序（sort_custom 稳定排序保证）。
## [br]同类型重复条目与 read_initial_total_for_type 同语义：push_error 诊断并以首个条目为准。
## [br]条目形状与合法性复用 _parse_entry（LevelInventoryEntry 冻结 schema），本函数不建第二套校验。
static func read_ordered_entries(level_root: Node) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	if level_root == null:
		return plan
	if not level_root.has_meta(METADATA_KEY):
		return plan
	var raw_entries: Variant = level_root.get_meta(METADATA_KEY)
	if typeof(raw_entries) != TYPE_ARRAY:
		push_error(
			"MetadataInventoryReader: inventory_entries metadata 不是 Array（类型 %d），多类型库存计划返回空。"
			% typeof(raw_entries)
		)
		return plan
	var seen_types: Dictionary = {}
	var indexed: Array = []
	for raw_entry: Variant in raw_entries:
		var entry: _LevelInventoryEntry = _parse_entry(raw_entry)
		if entry == null:
			continue
		if seen_types.has(entry.content_type_id):
			push_error(
				"MetadataInventoryReader: inventory_entries 存在 %s 的重复条目，多类型库存计划以首个为准。"
				% entry.content_type_id
			)
			continue
		seen_types[entry.content_type_id] = true
		indexed.append(entry)
	indexed.sort_custom(func(a, b): return a.order < b.order)
	for entry: _LevelInventoryEntry in indexed:
		plan.append({
			"content_type_id": entry.content_type_id,
			"initial_quantity": entry.initial_quantity,
			"order": entry.order,
		})
	return plan


## 解析单个 metadata 条目为 LevelInventoryEntry；非 Dictionary、字段缺失或类型不符返回 null 并 push_error。
## [br]数量为负时由 LevelInventoryEntry 构造钳为 0（冻结 schema 语义），不视为非法条目。
static func _parse_entry(raw_entry: Variant) -> _LevelInventoryEntry:
	if typeof(raw_entry) != TYPE_DICTIONARY:
		push_error("MetadataInventoryReader: inventory_entries 条目不是 Dictionary，已跳过。")
		return null
	var raw_type_id: Variant = raw_entry.get("content_type_id", null)
	var raw_quantity: Variant = raw_entry.get("initial_quantity", null)
	var raw_order: Variant = raw_entry.get("order", 0)
	if typeof(raw_type_id) != TYPE_STRING and typeof(raw_type_id) != TYPE_STRING_NAME:
		push_error("MetadataInventoryReader: 条目 content_type_id 缺失或类型不符，已跳过。")
		return null
	if typeof(raw_quantity) != TYPE_INT:
		push_error("MetadataInventoryReader: 条目 initial_quantity 缺失或不是 int，已跳过。")
		return null
	var order_value: int = raw_order if typeof(raw_order) == TYPE_INT else 0
	var entry: _LevelInventoryEntry = _LevelInventoryEntry.new(
		StringName(raw_type_id), raw_quantity, order_value
	)
	var errors: PackedStringArray = entry.validate()
	if not errors.is_empty():
		push_error(
			"MetadataInventoryReader: 条目校验失败（%s），已跳过。" % ["；".join(errors)]
		)
		return null
	return entry
