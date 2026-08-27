@tool
extends EditorPlugin

## 界面编辑辅助插件入口（S3-04；GUI 冻结总结 v1.0 §2.4/§83）。
## 职责：注册唯一中文 Dock（界面编辑辅助）并注入稳定启停清理；禁用时完全移除。
## 输入输出：由 Godot 插件生命周期调用，无返回值。
## 副作用：增删右侧 Dock；不连接任何外部信号。
## 边界（红线）：不做拖拽式 UI Layout Workbench、不替代 Godot 原生 Control 编辑；
##       布局正式入口仍是 Godot 原生 Control/Container/Anchor/Theme（§2.4/§83）。

const _DockScript: GDScript = preload("./ui_authoring_dock.gd")
## Dock 页签中文标题（禁 @VBoxContainer@ 自动名与英文业务名）。
const DOCK_TITLE: String = "界面编辑辅助"

var _dock: Control = null


## 插件启用入口：创建唯一 Dock。无参数无返回；副作用为注册 Dock。
func _enter_tree() -> void:
	_cleanup()
	_dock = _DockScript.new() as Control
	_dock.name = DOCK_TITLE
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


## 插件禁用入口：移除并释放 Dock。可重复启停不残留。
func _exit_tree() -> void:
	_cleanup()


## 统一清理，保证重复启停不残留 Dock；可重复调用。
func _cleanup() -> void:
	if _dock != null:
		if is_instance_valid(_dock):
			remove_control_from_docks(_dock)
			_dock.queue_free()
		_dock = null
