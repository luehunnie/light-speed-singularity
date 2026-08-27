extends SceneTree

## S3-04 界面编辑辅助插件/Dock/红线测试（GUI 冻结总结 v1.0 §2.4/§83）。
## 覆盖：中文插件名与 Dock 标题、唯一 Dock 注册与稳定启停（源令牌）、Dock headless
##       可构造（四 Preview/四 Viewport 预设）、无 Layout Workbench 红线令牌、
##       编辑器外安全降级与 Ad-hoc 会话行为。
## 由 Godot --headless --script 运行；任一失败 quit(1)。

const _DockScript: GDScript = preload(
	"res://addons/light_speed_ui_authoring/ui_authoring_dock.gd"
)
const _PLUGIN_PATH: String = "res://addons/light_speed_ui_authoring/plugin.gd"

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_chinese_names_and_registration()
	_test_dock_constructs()
	_test_no_layout_workbench_redline()
	_test_editor_fallback_and_adhoc()
	_report()
	quit(0 if _failures.is_empty() else 1)


## G1 中文名与唯一注册：cfg 中文插件名、DOCK_TITLE 中文、恰一次 Dock 注册、稳定启停清理。
func _test_chinese_names_and_registration() -> void:
	const NAME: String = "G1_中文名与唯一注册"
	var cfg: String = FileAccess.get_file_as_string("res://addons/light_speed_ui_authoring/plugin.cfg")
	_check(NAME, cfg.contains('name="界面编辑辅助"'), "plugin.cfg 应为中文插件名「界面编辑辅助」。")
	var source: String = FileAccess.get_file_as_string(_PLUGIN_PATH)
	_check(NAME, source.contains('DOCK_TITLE: String = "界面编辑辅助"'), "Dock 标题应为「界面编辑辅助」。")
	_check(NAME, source.contains("_dock.name = DOCK_TITLE"), "注册前应赋中文标题（禁 @VBoxContainer@）。")
	_check(NAME, source.count("add_control_to_dock") == 1, "应恰一次 Dock 注册，实际 %d。" % source.count("add_control_to_dock"))
	_check(NAME, source.contains("func _exit_tree") and source.contains("_cleanup()"), "禁用入口应清理 Dock 保证稳定启停。")
	# GUI FAIL 教训：编辑器对 plugin.gd 编译更严（--script 宽松），启用但编译失败=Dock 不出现。
	var plugin_script: GDScript = load(_PLUGIN_PATH)
	_check(NAME, plugin_script != null and plugin_script.can_instantiate(), "plugin.gd 必须可编译实例化（GUI FAIL 根因守卫）。")
	_check(NAME, source.contains("DOCK_SLOT_RIGHT_UL"), "Dock 应注册 DOCK_SLOT_RIGHT_UL（与外观编辑器同组可切换）。")
	_check(NAME, not source.contains("DOCK_SLOT_RIGHT_BL"), "不应再使用失败的 RIGHT_BL 方案。")


## G2 Dock headless 构造：四 Preview 预设、四 Viewport 预设、注入接口可见。
func _test_dock_constructs() -> void:
	const NAME: String = "G2_Dock可构造"
	var dock: Control = _DockScript.new()
	root.add_child(dock)
	dock._ready()
	_check(NAME, dock._preview_list.item_count == 4, "Preview 应 4 预设，实际 %d。" % dock._preview_list.item_count)
	_check(NAME, dock._viewport_list.item_count == 4, "Viewport 应 4 预设，实际 %d。" % dock._viewport_list.item_count)
	_check(NAME, dock._selected_viewport.has("size"), "构造后应已选中视口预设。")
	dock.free()


## G3 红线令牌：插件与 Dock 源码无 Layout Workbench 画布/拖拽编辑令牌（§83）。
func _test_no_layout_workbench_redline() -> void:
	const NAME: String = "G3_无Layout工作台红线"
	for path: String in [_PLUGIN_PATH, "res://addons/light_speed_ui_authoring/ui_authoring_dock.gd"]:
		var source: String = FileAccess.get_file_as_string(path)
		for token: String in ["GraphEdit", "GraphNode", "add_drag", "Drag"]:
			if token == "Drag":
				_check(NAME, not source.contains(token), "%s 不应含拖拽编辑令牌 %s。" % [path.get_file(), token])
			else:
				_check(NAME, not source.contains(token), "%s 不应含画布编辑令牌 %s。" % [path.get_file(), token])


## G4 编辑器外降级 + Ad-hoc 会话：守卫在 headless 提示仅编辑器可用；Ad-hoc 仅存会话成员。
func _test_editor_fallback_and_adhoc() -> void:
	const NAME: String = "G4_降级与Adhoc会话"
	var dock: Control = _DockScript.new()
	root.add_child(dock)
	dock._ready()
	dock._on_guard_pressed()
	_check(NAME, dock._status_label.text.contains("仅编辑器内可用"), "headless 守卫应安全降级（实际：%s）。" % dock._status_label.text)
	dock._adhoc_count.value = 12
	dock._on_adhoc_pressed()
	_check(NAME, dock._adhoc_preview.get("id", "") == "adhoc", "Ad-hoc 应生成为会话临时数据。")
	_check(NAME, int(dock._adhoc_preview.get("inventory_count", -1)) == 12, "Ad-hoc 库存数应为 12。")
	dock._on_preview_selected(0)
	_check(NAME, dock._adhoc_preview.is_empty(), "切换标准预设应清空 Ad-hoc 会话态。")
	dock.free()


## 单项断言：累计计数，失败时记录原因。
func _check(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])


## 输出测试摘要。
func _report() -> void:
	print("==== 界面编辑辅助插件测试摘要 ====")
	print("测试组数：4")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % (_checks - _failures.size()))
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
