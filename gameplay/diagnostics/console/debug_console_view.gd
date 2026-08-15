class_name DebugConsoleView
extends Control

## Debug-only 游戏内诊断控制台（D7-R1）。
##
## 职责：
## 只读诊断 UI——显示 Runtime 只读采样摘要（RunState / generation / 活动 emission 与光粒 / 发射器形态与方向 /
## 移动次数 / 库存 / 水晶 / Ray 段数 / 采样耗时），并提供两个安全诊断触发：手动生成 Snapshot JSON（仅内存文本）
## 与手动写盘（显式按钮，无每帧写盘）。打开/关闭经 F3。
##
## 在当前系统中的位置：
## gameplay/diagnostics/console 下 Debug-only UI；由 core_loop_prototype 仅在 OS.is_debug_build() 时构造接线；
## 采样经注入的 sample_provider Callable（RuntimeSnapshotSampler.sample），数据事实全部来自 RuntimeSnapshotData。
##
## 主要依赖：
## RuntimeSnapshotData / RuntimeSnapshot（同 Diagnostics 包 serialize/save）+ RuntimeInteractionTypes（形态/状态名）。
## 不持有任何玩法控制器 / Node 真值引用；不读取场景树业务节点。
##
## 明确不负责（冻结禁令，D7-R1 §6.5）：
## - 不执行任意 GDScript / 动态表达式 / 任意命令字符串（无代码执行入口）；
## - 不修改 RunState / emission / form / direction / cooldown / 库存 / 占用 / 水晶 / 快照内容；
## - 不 Save / Load、不 Spawn、不编辑场景、不发射、不重置、不成为万能开发命令入口；
## - 不写 RuntimeLogger（RuntimeLogger 生产事件接线 NOT IMPLEMENTED，控制台只显示自身诊断行）。
##
## 关键边界：
## - 只读 + 诊断触发：唯一会触碰文件系统的是显式「写盘」按钮，且仅写 user://diagnostics/snapshots 目录树；
## - 采样不改玩法：全部数据经 RuntimeSnapshotSampler 只读链路；
## - 公开方法白名单冻结（见测试 get_method_list 断言）：setup / set_open / is_open / toggle /
##   refresh_display / trigger_serialize_snapshot / trigger_write_snapshot / get_display_text /
##   get_status_text / get_recent_lines。


const _RuntimeSnapshot: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot.gd")
const _RuntimeSnapshotData: GDScript = preload("res://gameplay/diagnostics/snapshot/runtime_snapshot_data.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

## 控制台开关键（F3；不占用 Space/R/Q 等玩法键；无 echo 抖动）。
const TOGGLE_KEY: Key = KEY_F3
## 控制台保留的最近诊断行数上限（环形裁剪，仅内存）。
const MAX_RECENT_LINES: int = 8


## 采样提供方：() -> RuntimeSnapshotData（core_loop 注入 RuntimeSnapshotSampler.sample）。
var _sample_provider: Callable
## 手动写盘目标目录（默认 RuntimeSnapshot.DEFAULT_SNAPSHOT_DIRECTORY；测试可注入子目录）。
var _snapshot_directory: String
## 内容标签（多行摘要）。
var _display_label: Label = null
## 状态标签（最近一次触发结果）。
var _status_label: Label = null
## 按钮容器（控制台关闭时随根节点隐藏）。
var _button_row: HBoxContainer = null
## 最近一次采样数据（detached，仅用于序列化 / 写盘触发）。
var _last_data: _RuntimeSnapshotData = null
## 最近诊断行（打开/刷新/序列化/写盘结果）。
var _recent_lines: PackedStringArray = PackedStringArray()


## 构造控制台；sample_provider 为只读采样 Callable，snapshot_directory 为手动写盘目标目录。
## [br]边界：零副作用；不采样、不创建节点、不触碰文件系统。
func _init(
		sample_provider: Callable,
		snapshot_directory: String = _RuntimeSnapshot.DEFAULT_SNAPSHOT_DIRECTORY
) -> void:
	_sample_provider = sample_provider
	_snapshot_directory = snapshot_directory


## 一次性创建控制台 UI 并挂到传入 CanvasLayer；初始隐藏（关闭态）。
## [br]边界：只创建诊断 UI 节点；不接管既有玩法 UI。
func setup(canvas_layer: CanvasLayer) -> void:
	# 根 Control 铺满视口（面板锚点基准）且不拦截鼠标（点击由面板自身接收；关闭态零遮挡）。
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "DebugConsolePanel"
	# 面板锚定画面右上角（左右锚点=1.0，随任意窗口尺寸稳定贴右）；宽 464 / 高 568 保持内容容量，
	# 上/右各留 16px 边距；避开左上 HintLabel / RunStartView 与底部 InventoryBar。
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -480.0
	panel.offset_right = -16.0
	panel.offset_top = 16.0
	panel.offset_bottom = 584.0
	add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	panel.add_child(column)
	_display_label = Label.new()
	_display_label.name = "DebugConsoleDisplay"
	# 等宽多行文本，由 refresh_display 全量重写。
	_display_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_display_label)
	_button_row = HBoxContainer.new()
	column.add_child(_button_row)
	_add_trigger_button("刷新", _on_refresh_pressed)
	_add_trigger_button("生成快照", _on_serialize_pressed)
	_add_trigger_button("写盘", _on_write_pressed)
	_add_trigger_button("关闭", _on_close_pressed)
	_status_label = Label.new()
	_status_label.name = "DebugConsoleStatus"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status_label)
	visible = false
	canvas_layer.add_child(self)
	_record_line("Debug 控制台已就绪（F3 开关）。")


## F3 开关（仅按键按下；echo / 释放忽略）。Debug-only：由 core_loop 仅 Debug 构造保证。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key: InputEventKey = event as InputEventKey
		if key.pressed and not key.echo and key.physical_keycode == TOGGLE_KEY:
			toggle()
			get_viewport().set_input_as_handled()


## 设置打开/关闭；打开时自动刷新一次显示。
func set_open(is_open: bool) -> void:
	visible = is_open
	if is_open:
		_record_line("打开。")
		refresh_display()


## 是否打开。
func is_open() -> bool:
	return visible


## 切换打开/关闭。
func toggle() -> void:
	set_open(not visible)


## 只读刷新：经 sample_provider 采样并重写显示摘要（不序列化、不写盘）。
## [br]边界：setup 前调用安全 no-op（无显示节点，仅更新 _last_data）。
func refresh_display() -> void:
	_last_data = _sample_provider.call()
	if _display_label != null:
		_display_label.text = _build_display_text(_last_data)


## 安全诊断触发：手动序列化最近采样为 JSON 文本（仅内存，不写盘）。
## [br]返回 bool：序列化成功为 true；无采样或校验失败为 false（状态标签显示原因）。
## [br]边界：setup 前调用仍可序列化（诊断行可见），状态标签为 null 时安全跳过。
func trigger_serialize_snapshot() -> bool:
	if _last_data == null:
		refresh_display()
	var result: Variant = _RuntimeSnapshot.serialize(_last_data)
	if result.is_success():
		_record_line("快照序列化成功（%d 字节）。" % result.json_text.to_utf8_buffer().size())
		if _status_label != null:
			_status_label.text = "快照序列化成功（仅内存，未写盘）。"
		return true
	_record_line("快照序列化失败。")
	if _status_label != null:
		_status_label.text = "快照序列化失败：%s" % ["；".join(result.errors)]
	return false


## 安全诊断触发：手动把最近采样写盘（显式触发；无每帧 / 高频写盘路径）。
## [br]返回 bool：写盘成功为 true；失败为 false（状态标签显示原因）。
## [br]边界：setup 前调用仍可写盘（诊断行可见），状态标签为 null 时安全跳过。
func trigger_write_snapshot() -> bool:
	if _last_data == null:
		refresh_display()
	var result: Variant = _RuntimeSnapshot.save(_last_data, _snapshot_directory)
	if result.errors.is_empty():
		_record_line("快照已写盘：%s" % result.file_path)
		if _status_label != null:
			_status_label.text = "快照已写盘：%s" % result.file_path
		return true
	_record_line("快照写盘失败。")
	if _status_label != null:
		_status_label.text = "快照写盘失败：%s" % ["；".join(result.errors)]
	return false


## 当前显示摘要文本；供测试只读断言。
func get_display_text() -> String:
	if _display_label == null:
		return ""
	return _display_label.text


## 最近一次触发状态文本；供测试只读断言。
func get_status_text() -> String:
	if _status_label == null:
		return ""
	return _status_label.text


## 最近诊断行副本（最多 MAX_RECENT_LINES 条）；供测试只读断言。
func get_recent_lines() -> PackedStringArray:
	return _recent_lines.duplicate()


## 组装多行只读摘要（数据全部来自 RuntimeSnapshotData detached 事实）。
func _build_display_text(data: _RuntimeSnapshotData) -> String:
	var lit_count: int = 0
	for crystal: Variant in data.crystal_states:
		if crystal.is_activated:
			lit_count += 1
	return "\n".join([
		"[Runtime]",
		"run_state：%s    generation：%d    cooldown_ready：%s" % [String(data.run_state), data.runtime_generation, str(data.fire_cooldown_ready)],
		"移动次数：已用 %d / 剩余 %d / 上限 %d" % [data.runtime_move_count, data.runtime_moves_remaining, data.runtime_move_limit],
		"[Emitter]",
		"cell(%d,%d)  direction(%d,%d)  form：%s  allow_form_switch：%s" % [data.emitter_cell.x, data.emitter_cell.y, data.emitter_direction.x, data.emitter_direction.y, _form_name(data.emitter_form), str(data.allow_form_switch)],
		"[Emissions / Particles]",
		"活动 emission：%d    活动 Particle：%d    Particle tick：%d    Ray 段：%d" % [data.active_emission_count, data.particle_active_count, data.particle_tick, data.ray_segment_count],
		"[Placement / Inventory]",
		"已放置：%d    库存：%d / %d" % [data.placed_mechanism_count, data.inventory_remaining, data.inventory_total],
		"[Objective]",
		"crystals：%d/%d lit    completed：%s" % [lit_count, data.crystal_states.size(), str(data.is_completed)],
		"[Perf]",
		"采样耗时：%d usec" % data.snapshot_duration_usec,
		"累计 Particle step 数：NOT IMPLEMENTED",
		"最近一次 Runtime 执行耗时：NOT IMPLEMENTED",
		"[RuntimeLogger]",
		"生产事件接线 NOT IMPLEMENTED（仅显示控制台自身诊断行）",
	])


## LightForm 数值映射为可读名（RAY/PARTICLE；未知值原样显示数值）。
func _form_name(form: int) -> String:
	if form == _LightEmissionTypes.LightForm.RAY:
		return "RAY"
	if form == _LightEmissionTypes.LightForm.PARTICLE:
		return "PARTICLE"
	return "UNKNOWN(%d)" % form


## 创建一个触发按钮并挂到按钮行。
func _add_trigger_button(text: String, handler: Callable) -> void:
	var button: Button = Button.new()
	button.text = text
	button.pressed.connect(handler)
	_button_row.add_child(button)


## 按钮回调：刷新显示。
func _on_refresh_pressed() -> void:
	refresh_display()
	_record_line("手动刷新。")


## 按钮回调：手动序列化快照。
func _on_serialize_pressed() -> void:
	trigger_serialize_snapshot()


## 按钮回调：手动写盘快照。
func _on_write_pressed() -> void:
	trigger_write_snapshot()


## 按钮回调：关闭控制台（不改任何玩法状态）。
func _on_close_pressed() -> void:
	set_open(false)


## 记录一条诊断行（环形裁剪到 MAX_RECENT_LINES；仅内存）。
func _record_line(line: String) -> void:
	_recent_lines.append("[%d] %s" % [Time.get_ticks_msec(), line])
	while _recent_lines.size() > MAX_RECENT_LINES:
		_recent_lines.remove_at(0)
