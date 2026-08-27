@tool
class_name ObjectVisualView
extends Node2D

## 永久视觉显示组件：统一运行时视觉表现接口。
##
## 职责：
## 根据当前内容状态（state_id）与显示模式（正式世界 / 拖拽预览）从 ObjectVisualProfile 选取纹理显示在 Artwork 上，
## 并独立叠加合法 / 非法 / 禁用反馈；玩法对象只调用本组件的公共方法，不再直接操作纹理或颜色子节点。
##
## 在当前系统中的位置：
## gameplay/visuals 下视觉显示层（第三层），依赖第一批的 ObjectVisualProfile / VisualStateTexture；
## 后续 PlaceableToken、BasicCrystal、SingleCellMirror、FixedEmitter、WallCell、InventorySlotView 等对象将持有并驱动本组件。
## 本批只实现本组件自身，不接入任何现有水晶、镜面、放置系统或道具栏。
##
## 主要依赖：
## ObjectVisualProfile（提供 get_world_texture / get_drag_texture 查询与 state_id 回退）、Texture2D、StringName 稳定状态 ID，
## 以及本场景内 Shadow、Artwork、FeedbackOverlay、DebugMark 四个固定子节点。不依赖 GridMetrics、场景树查询、输入或玩法状态。
##
## 明确不负责：
## 镜面 orientation 与反射、水晶 is_activated 与点亮条件、放置合法性计算、OccupancyRegistry、库存数量、运行状态、
## 鼠标输入、实例化机关、关卡对象收集、GridPlacedObject、TileMapLayer、坐标换算、具体 PNG 的 preload 或文件名推断。
##
## 关键边界（对应永久接口设计 v1.0 §9 与 eng-review 决策）：
## - 内容状态与反馈是两条独立的视觉轴：纹理由 (content_state_id, display_mode) 决定，覆盖层 / 调制由 feedback_state 决定，
##   两者在 refresh_visual() 中合成，互不覆盖（CQ2）。
## - visual_profile 为空属于合法状态：不崩溃、Artwork 纹理置空、只输出一次受控警告（§9.5 / §23.1）。
## - 查询结果为空时 Artwork.texture 置为 null，不保留上一个状态的旧纹理（§6.3）。
## - 本组件不修改 visual_profile，不根据文件名推断状态，不 preload 任何 PNG（§6.5–§6.8）。
## - @tool 安全：可被 @tool 配置节点在 _ready 前后随时驱动；setter 早于 _ready 时只保存状态不访问子节点，_ready 后统一刷新（D3C-0.5）。


## 显示模式：决定 refresh_visual() 从 profile 取世界纹理还是拖拽纹理。
enum DisplayMode {
	## 正式放置在世界中，取 world_texture。
	WORLD,
	## 作为拖拽预览，取 drag_texture（缺失时由 profile 回退到同一状态的 world_texture）。
	DRAG_PREVIEW,
}

## 反馈状态：决定 Artwork 调制与 FeedbackOverlay 覆盖层表现，独立于内容状态与纹理。
enum FeedbackState {
	## 无反馈：Artwork 保持原色，覆盖层隐藏。
	NONE,
	## 合法放置反馈：Artwork 保持原色，覆盖层显示半透明绿色（不直接把 Artwork 染绿）。
	VALID,
	## 非法放置反馈：Artwork 保持原色，覆盖层显示半透明红色（不直接把 Artwork 染红）。
	INVALID,
	## 禁用反馈：覆盖层隐藏，Artwork 使用灰色半透明 self_modulate。
	DISABLED,
}


## 该对象的视觉资源集合。可为空；为空时 Artwork 纹理置空并只警告一次。
@export var visual_profile: ObjectVisualProfile

## 初始内容状态 ID；_ready() 时写入当前内容状态并刷新一次视觉。
@export var initial_state_id: StringName = &"default"


# 四个固定视觉子节点：_ready() 前保持 null，由 _ready() 用 get_node_or_null 统一缓存。
# setter 可早于 _ready 调用：此时只保存配置状态、不访问子节点，避免编辑器中空引用。
# 阴影 ColorRect 子节点，纯色阴影，本组件不动态修改其颜色。
var _shadow: ColorRect = null
# 美术 TextureRect 子节点，承载正式或拖拽纹理。
var _artwork: TextureRect = null
# 反馈覆盖 ColorRect 子节点，只负责合法 / 非法放置反馈；默认隐藏。
var _feedback_overlay: ColorRect = null
# 调试标记容器 Node2D 子节点，供后续镜面方向线等调试视觉使用；本批保持可见但内容为空。
var _debug_mark: Node2D = null

# 当前内容状态 ID，由 set_content_state() 修改，是纹理选取的第一条轴。
var _content_state_id: StringName = &"default"
# 标记 _ready 前是否已显式设置过内容状态；为真时 _ready 不再用 initial_state_id 覆盖，保留早到 setter 的状态。
var _content_state_overridden: bool = false
# 当前显示模式，由 set_display_mode() 修改，是纹理选取的第二条轴。
var _display_mode: DisplayMode = DisplayMode.WORLD
# 当前反馈状态，由 set_feedback() 修改，独立于纹理，只影响覆盖层与 Artwork 调制。
var _feedback_state: FeedbackState = FeedbackState.NONE

# 缺纹理受控警告的去重表：键为 "state_id|display_mode"，值恒为 true。
# 仅用于 profile 存在但状态或纹理缺失的情况；set_profile() 会清空该表，使新 profile 重新具备警告能力。
var _missing_texture_warned: Dictionary = {}
# 空 visual_profile 受控警告的阶段标记；同一次空 profile 阶段只警告一次，不随状态或模式切换重置。
var _missing_profile_warned: bool = false

# 反馈与阴影相关常量，集中定义以便统一调整；数值贴近当前原型占位视觉。
# 合法放置覆盖色：半透明绿色（与 placeable_token 合法预览色系一致）。
const _VALID_OVERLAY_COLOR: Color = Color(0.2, 0.95, 0.35, 0.5)
# 非法放置覆盖色：半透明红色（与 placeable_token 非法预览色系一致）。
const _INVALID_OVERLAY_COLOR: Color = Color(1.0, 0.18, 0.18, 0.5)
# 禁用调制色：灰色半透明，用于 DISABLED 反馈下对 Artwork 整体压暗。
const _DISABLED_MODULATE: Color = Color(0.45, 0.45, 0.45, 0.6)
# Artwork 默认调制色：NONE / VALID / INVALID 下保持原色，不染色。
const _DEFAULT_ARTWORK_MODULATE: Color = Color.WHITE


## 缓存视觉子节点、应用初始内容状态并刷新一次视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：用 get_node_or_null 缓存四个子节点；仅在 _ready 前未显式设置内容状态时写入 _content_state_id = initial_state_id（显示模式与反馈状态不重置，保留早到 setter 值）；调用 refresh_visual()。
## [br]边界条件：visual_profile 为空时场景仍可正常加载，refresh_visual() 会安全置空纹理并只警告一次；
## [br]不在 _ready() 中扫描文件、加载具体 PNG 或读取玩法状态与输入；
## [br]Artwork 等子节点缺失属于场景结构错误，由下方断言明确暴露而非静默忽略。
func _ready() -> void:
	# 统一缓存四个固定子节点：@tool 下编辑器与运行时同一 _ready 入口，缓存后子节点方可安全访问。
	_shadow = get_node_or_null("Shadow")
	_artwork = get_node_or_null("Artwork")
	_feedback_overlay = get_node_or_null("FeedbackOverlay")
	_debug_mark = get_node_or_null("DebugMark")
	# 场景结构断言：四个固定子节点必须存在，缺失即场景配置错误，立即在 debug 下暴露。
	assert(_shadow != null, "ObjectVisualView: 场景缺少 Shadow 子节点。")
	assert(_artwork != null, "ObjectVisualView: 场景缺少 Artwork 子节点。")
	assert(_feedback_overlay != null, "ObjectVisualView: 场景缺少 FeedbackOverlay 子节点。")
	assert(_debug_mark != null, "ObjectVisualView: 场景缺少 DebugMark 子节点。")
	# 仅在 _ready 前未显式设置内容状态时采用 initial_state_id；早到 setter 的状态保留。
	# 显示模式与反馈状态不在此重置，_ready 前的 setter 值自然延续到统一刷新。
	if not _content_state_overridden:
		_content_state_id = initial_state_id
	refresh_visual()


## 替换当前视觉资源集合并立即刷新视觉。
## [br]next_profile 是新的 ObjectVisualProfile，可为空。
## [br]无返回值；副作用是写入 visual_profile、清空缺纹理警告去重表、重置空 profile 阶段警告标记并调用 refresh_visual()。
## [br]边界条件：本函数不校验 profile 内容（由 profile.validate_profile() 负责）；不修改 next_profile；
## [br]清空去重表是为了让新 profile 在缺纹理时重新具备一次警告能力；
## [br]重置空 profile 标记是为了让重新设置为空 profile 的新阶段可再次报告一次。
func set_profile(next_profile: ObjectVisualProfile) -> void:
	visual_profile = next_profile
	_missing_texture_warned.clear()
	_missing_profile_warned = false
	refresh_visual()


## 设置当前内容状态并立即刷新视觉。
## [br]state_id 是目标稳定状态 ID，可为空（profile 会回退到 default_state_id）。
## [br]无返回值；副作用是写入 _content_state_id 并调用 refresh_visual()。
## [br]边界条件：反复设置相同状态安全、不产生异常；本函数不改变显示模式、反馈状态或 visual_profile；
## [br]不校验 state_id 是否存在（由 profile 查询回退处理）。
func set_content_state(state_id: StringName) -> void:
	_content_state_id = state_id
	_content_state_overridden = true
	refresh_visual()


## 取得当前内容状态 ID。
## [br]本函数无参数。
## [br]返回当前 _content_state_id；本函数无副作用。
func get_content_state() -> StringName:
	return _content_state_id


## 设置显示模式并立即刷新视觉。
## [br]mode 是目标 DisplayMode（WORLD 或 DRAG_PREVIEW）。
## [br]无返回值；副作用是写入 _display_mode 并调用 refresh_visual()。
## [br]边界条件：切换显示模式不改变内容状态、反馈状态或 visual_profile；反复设置相同模式安全。
func set_display_mode(mode: DisplayMode) -> void:
	_display_mode = mode
	refresh_visual()


## 取得当前显示模式。
## [br]本函数无参数。
## [br]返回当前 _display_mode；本函数无副作用。
func get_display_mode() -> DisplayMode:
	return _display_mode


## 设置反馈状态，只更新覆盖层与 Artwork 调制，不触碰纹理。
## [br]feedback 是目标 FeedbackState（NONE / VALID / INVALID / DISABLED）。
## [br]无返回值；副作用是写入 _feedback_state 并调用 _apply_feedback_visual()。
## [br]边界条件：切换反馈不改变纹理状态、内容状态、显示模式或 visual_profile；反复设置相同反馈安全。
func set_feedback(feedback: FeedbackState) -> void:
	_feedback_state = feedback
	_apply_feedback_visual()


## 取得当前反馈状态。
## [br]本函数无参数。
## [br]返回当前 _feedback_state；本函数无副作用。
func get_feedback() -> FeedbackState:
	return _feedback_state


## 设置本组件根节点是否可见。
## [br]next_visible 为 true 时显示本组件，为 false 时隐藏。
## [br]无返回值；副作用仅设置根节点 visible。
## [br]边界条件：只控制根节点 visible，不修改内容状态、显示模式、反馈状态或 visual_profile；
## [br]因 visible 与上述状态相互独立，再次显示时之前的状态自然保留，不会丢失。
## [br]注：参数不使用 is_visible，以免遮蔽基类 CanvasItem.is_visible() 方法触发 GDScript 遮蔽警告（开发规范 §4.1 处理重要警告）。
func set_visual_visible(next_visible: bool) -> void:
	visible = next_visible


## 设置 Artwork 纹理的显示旋转（弧度，绕纹理中心；供单张贴图承载多方向语义的机关按方向事实派生）。
## [br]angle 是目标旋转角（弧度）。
## [br]无返回值；副作用：把 Artwork 的 pivot_offset 设为自身尺寸中心并写入 rotation。
## [br]边界条件：_artwork 未就绪（_ready 前）时安全返回、不抛错；本函数不触碰纹理、内容状态、
## 显示模式与反馈——refresh_visual() 只换 texture 不重置 rotation，旋转在状态/模式切换间自然保留。
func set_artwork_rotation(angle: float) -> void:
	if _artwork == null:
		return
	_artwork.pivot_offset = _artwork.size / 2.0
	_artwork.rotation = angle


## 查询当前内容状态在当前显示模式下是否解析到非空纹理。
## [br]本函数无参数。
## [br]返回是否存在可显示纹理；无副作用。
## [br]边界条件：_artwork 未就绪（_ready 前）、visual_profile 为空或状态回退失败时返回 false；
## 编辑器中 profile 脚本不可调用时同样返回 false（与 refresh_visual 的纹理解析口径一致）。
func has_resolved_texture() -> bool:
	if _artwork == null:
		return false
	return _resolve_texture() != null


## 按当前内容状态、显示模式与反馈状态合成并刷新全部视觉。
## [br]本函数无参数、无返回值。
## [br]副作用：按显示模式从 visual_profile 取纹理写入 Artwork.texture（取空则置 null），
## [br]并调用 _apply_feedback_visual() 重放覆盖层与调制，保证反馈在纹理切换后仍然一致。
## [br]边界条件：visual_profile 为空时纹理置 null 并只警告一次；查询结果为空时不保留旧纹理；
## [br]本函数不修改 visual_profile，不在每帧调用（仅由状态变化或 set_profile 触发）。
func refresh_visual() -> void:
	# 子节点未就绪（_ready 前或场景结构异常）时只保存状态、安全返回，不触碰子节点。
	if _artwork == null:
		return
	var texture: Texture2D = _resolve_texture()
	# 查询为空时直接置 null，不保留上一个状态的旧纹理。
	_artwork.texture = texture
	if texture == null:
		_report_missing_texture_once()
	# 反馈是独立视觉轴：纹理刷新后必须重放反馈，避免拖拽预览切换纹理时丢失合法 / 非法覆盖层。
	_apply_feedback_visual()


## 按当前显示模式从 visual_profile 解析应显示的纹理。
## [br]本函数无参数。
## [br]返回目标 Texture2D；visual_profile 为空、state_id 不存在或对应纹理缺失时返回 null。
## [br]本函数无副作用，不修改 visual_profile；边界条件：WORLD 取 get_world_texture，DRAG_PREVIEW 取 get_drag_texture，
## [br]profile 内部已处理 state_id 为空 / 不存在时回退到 default_state_id 再到 null 的链路。
func _resolve_texture() -> Texture2D:
	if visual_profile == null:
		return null
	# 编辑器中 profile 脚本若非 @tool，其实例为占位、方法不可调用（Godot 限制）；
	# 此时安全跳过纹理取用，反馈覆盖层仍正常刷新；运行时与脚本就绪后正常取纹理，不吞掉运行时刷新。
	if Engine.is_editor_hint() and not _is_profile_callable():
		return null
	if _display_mode == DisplayMode.DRAG_PREVIEW:
		return visual_profile.get_drag_texture(_content_state_id)
	return visual_profile.get_world_texture(_content_state_id)


## 判断 visual_profile 的脚本在当前上下文是否可调用（非 @tool 脚本在编辑器中不可实例化、方法为占位）。
func _is_profile_callable() -> bool:
	var profile_script: Script = visual_profile.get_script()
	return profile_script != null and profile_script.can_instantiate()


## 按当前反馈状态设置 Artwork 调制与 FeedbackOverlay 覆盖层。
## [br]本函数无参数、无返回值。
## [br]副作用：设置 _artwork.self_modulate、_feedback_overlay.color 与 _feedback_overlay.visible。
## [br]边界条件：VALID / INVALID 不直接染色 Artwork，而是通过半透明覆盖层表达；DISABLED 隐藏覆盖层并对 Artwork 灰调；
## [br]NONE 恢复 Artwork 原色并隐藏覆盖层；本函数不改变纹理、内容状态、显示模式或反馈状态本身。
func _apply_feedback_visual() -> void:
	# 子节点未就绪时只保存反馈状态、安全返回；_ready 后由 refresh_visual 统一重放。
	if _artwork == null or _feedback_overlay == null:
		return
	match _feedback_state:
		FeedbackState.VALID:
			_artwork.self_modulate = _DEFAULT_ARTWORK_MODULATE
			_feedback_overlay.color = _VALID_OVERLAY_COLOR
			_feedback_overlay.visible = true
		FeedbackState.INVALID:
			_artwork.self_modulate = _DEFAULT_ARTWORK_MODULATE
			_feedback_overlay.color = _INVALID_OVERLAY_COLOR
			_feedback_overlay.visible = true
		FeedbackState.DISABLED:
			_artwork.self_modulate = _DISABLED_MODULATE
			_feedback_overlay.visible = false
		FeedbackState.NONE, _:
			_artwork.self_modulate = _DEFAULT_ARTWORK_MODULATE
			_feedback_overlay.visible = false


## 对当前缺失情况输出一次受控警告。
## [br]本函数无参数、无返回值。
## [br]副作用：visual_profile 为空时首次命中当前空 profile 阶段会调用 push_warning，并写入 _missing_profile_warned；
## [br]profile 存在但纹理查询失败时，首次命中该 (内容状态, 显示模式) 组合会调用 push_warning，并写入 _missing_texture_warned 去重表。
## [br]边界条件：空 profile 警告不随状态或模式切换重复；profile 缺状态或缺纹理仍按组合保留诊断粒度；
## [br]本函数不修改 visual_profile，不抛出异常，不影响场景加载。
func _report_missing_texture_once() -> void:
	if visual_profile == null:
		if _missing_profile_warned:
			return
		_missing_profile_warned = true
		push_warning("ObjectVisualView: 未配置 visual_profile，Artwork 纹理为空。")
		return

	var key: String = "%s|%d" % [_content_state_id, _display_mode]
	if _missing_texture_warned.has(key):
		return
	_missing_texture_warned[key] = true
	push_warning("ObjectVisualView: 在 %s 模式下未取到 state_id=%s 的纹理（profile 缺失该状态或对应纹理）。" % [_display_mode_label(), _content_state_id])


## 取得当前显示模式的中文标签，仅用于警告文本可读性。
## [br]本函数无参数。
## [br]返回对应 DisplayMode 的中文名字符串；本函数无副作用。
func _display_mode_label() -> String:
	match _display_mode:
		DisplayMode.WORLD:
			return "正式世界(WORLD)"
		DisplayMode.DRAG_PREVIEW:
			return "拖拽预览(DRAG_PREVIEW)"
		_:
			return "未知模式"
