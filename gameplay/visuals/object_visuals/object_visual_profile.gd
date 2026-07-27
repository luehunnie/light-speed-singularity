# @tool：使本数据资源可在编辑器中实例化与调用，供 @tool 视图在编辑器内直接解析纹理。
# 仅数据资源，不承担视图显示或玩法行为；现有 state_id→default_state_id→null 回退边界不变。
@tool
class_name ObjectVisualProfile
extends Resource

## 永久视觉资源数据接口：一个对象全部内容状态的视觉资源集合。
##
## 职责：
## 集中保存一个对象的道具栏图标、默认状态 ID 和全部 VisualStateTexture 状态列表，
## 提供 state_id 查找、world/drag 纹理获取与配置校验，使美术只需通过 .tres 即可配置全部画面，
## 玩法代码不再写死 PNG 路径或直接访问视觉子节点。
##
## 在当前系统中的位置：
## gameplay/visuals 下视觉资源数据的第二层，依赖 VisualStateTexture；被后续 ObjectVisualView、
## PlaceableToken、BasicCrystal、SingleCellMirror、InventorySlotView 等组件读取。本批不实现这些组件。
##
## 主要依赖：
## VisualStateTexture 状态资源、Texture2D 纹理、StringName 稳定状态 ID。
##
## 明确不负责：
## 场景树查询、节点显示、输入处理、镜面反射、水晶点亮、库存数量、放置合法性、运行状态、
## 资源路径自动扫描、具体 PNG 的 preload、纹理缓存。
##
## 关键边界：
## - inventory_icon 可为空（固定物件无道具栏图标）。
## - drag_texture 缺失时回退到同一最终状态的 world_texture，不跨状态回退。
## - states 顺序不固定，查找按 state_id 匹配。
## - 查找时传入 state_id 为空或不存在时回退到 default_state_id，再失败返回 null，不崩溃、不刷屏警告。
## - 不缓存查询结果，不读取文件系统。


## 道具栏使用的独立 UI 图标。固定物件可以留空。
@export var inventory_icon: Texture2D

## 默认内容状态 ID。查找状态时若传入 ID 为空或不存在，回退到该 ID。
@export var default_state_id: StringName = &"default"

## 该对象全部内容状态的纹理定义。顺序不固定，查找按 state_id 匹配。
@export var states: Array[VisualStateTexture] = []


## 查询指定 state_id 是否存在于 states 中。
## [br]state_id 是要查找的稳定状态 ID。
## [br]返回 true 表示存在匹配的状态且该元素非 null；返回 false 表示未找到、传入空 ID 或元素为 null。
## [br]本函数无副作用，不修改资源内容，不输出错误，不使用 default_state_id 回退。
## [br]边界条件：忽略 states 中的 null 元素；空 state_id 直接返回 false。
func has_state(state_id: StringName) -> bool:
	if state_id == &"":
		return false
	for state: VisualStateTexture in states:
		if state == null:
			continue
		if state.state_id == state_id:
			return true
	return false


## 取得指定状态的正式世界纹理。
## [br]state_id 是要查找的稳定状态 ID。
## [br]返回目标状态的 world_texture；找不到合法状态或 world_texture 为空时返回 null。
## [br]本函数无副作用，不修改资源内容，不刷屏警告。
## [br]边界条件：查找顺序为传入 state_id 非空且存在 → 否则 default_state_id → 再失败返回 null；
## [br]找到状态但 world_texture 为空也返回 null；不自动修改 state_id 或 default_state_id。
func get_world_texture(state_id: StringName) -> Texture2D:
	var state: VisualStateTexture = _resolve_state(state_id)
	if state == null:
		return null
	return state.world_texture


## 取得指定状态的拖拽纹理，缺失时回退到同一最终状态的 world_texture。
## [br]state_id 是要查找的稳定状态 ID。
## [br]返回目标状态的 drag_texture；drag_texture 为空时返回同一状态的 world_texture；找不到合法状态返回 null。
## [br]本函数无副作用，不修改资源内容。
## [br]边界条件：状态查找与 get_world_texture 使用相同的 state_id → default_state_id 回退规则；
## [br]不允许在状态 A 的 drag_texture 缺失时错误回退到状态 B 的 world_texture。
func get_drag_texture(state_id: StringName) -> Texture2D:
	var state: VisualStateTexture = _resolve_state(state_id)
	if state == null:
		return null
	# drag_texture 优先；为空时回退到同一最终状态的 world_texture，不跨状态回退。
	if state.drag_texture != null:
		return state.drag_texture
	return state.world_texture


## 校验当前视觉资源集合的配置完整性。
## [br]本函数无参数。
## [br]返回 PackedStringArray，包含全部发现的问题；无问题时返回空数组。
## [br]本函数无副作用，不修改资源内容。
## [br]边界条件：必须一次返回全部问题，不得遇到第一项错误就提前返回；
## [br]问题字符串为中文并带状态数组索引、state_id 等上下文；
## [br]inventory_icon 为空不视为错误；drag_texture 为空不视为错误；states 顺序不固定不视为错误。
func validate_profile() -> PackedStringArray:
	var problems: PackedStringArray = []

	# 1. default_state_id 为空。
	if default_state_id == &"":
		problems.append("ObjectVisualProfile：default_state_id 为空，必须填写默认状态 ID。")

	# 记录非空 state_id 的首次出现索引，用于查重；空 ID 不参与查重（已由 validate_state 报告）。
	var seen_ids: Dictionary[StringName, int] = {}
	for index: int in range(states.size()):
		var state: VisualStateTexture = states[index]
		# 2. states 数组中存在 null 元素。
		if state == null:
			problems.append("ObjectVisualProfile：states[%d] 为 null，必须填写 VisualStateTexture。" % [index])
			continue
		# 7. 调用每个非 null 状态的 validate_state()，并把其问题加入总结果。
		# validate_state() 内部已覆盖该状态 state_id 为空（检查项 #3）和 world_texture 为空（检查项 #6）。
		var state_problems: PackedStringArray = state.validate_state()
		for state_problem: String in state_problems:
			problems.append("ObjectVisualProfile：states[%d] state_id=%s → %s" % [index, state.state_id, state_problem])
		# 4. 存在重复 state_id（仅对非空 ID 查重）。
		if state.state_id != &"":
			if seen_ids.has(state.state_id):
				problems.append("ObjectVisualProfile：states[%d] 的 state_id=%s 与 states[%d] 重复。" % [index, state.state_id, seen_ids[state.state_id]])
			else:
				seen_ids[state.state_id] = index

	# 5. default_state_id 在 states 中不存在（仅当 default_state_id 非空时检查）。
	if default_state_id != &"" and not has_state(default_state_id):
		problems.append("ObjectVisualProfile：default_state_id=%s 在 states 中不存在。" % [default_state_id])

	return problems


## 内部状态解析：按 state_id → default_state_id 顺序查找最终状态。
## [br]state_id 是调用方传入的状态 ID。
## [br]返回最终匹配的 VisualStateTexture；传入 ID 非空且存在时优先使用，否则尝试 default_state_id，再失败返回 null。
## [br]本函数无副作用；边界条件：忽略 null 元素；default_state_id 为空时跳过回退直接返回 null。
func _resolve_state(state_id: StringName) -> VisualStateTexture:
	if state_id != &"":
		var direct: VisualStateTexture = _find_state_by_id(state_id)
		if direct != null:
			return direct
	if default_state_id != &"":
		return _find_state_by_id(default_state_id)
	return null


## 内部按 state_id 线性查找状态元素。
## [br]target_id 是要匹配的稳定状态 ID。
## [br]返回首个 state_id 匹配且非 null 的 VisualStateTexture；未找到返回 null。
## [br]本函数无副作用；边界条件：忽略 null 元素；不缓存结果。
func _find_state_by_id(target_id: StringName) -> VisualStateTexture:
	for state: VisualStateTexture in states:
		if state == null:
			continue
		if state.state_id == target_id:
			return state
	return null
