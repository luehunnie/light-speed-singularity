@tool
extends EditorPlugin

## 外观编辑器插件入口（S3-03；GUI 冻结总结 v1.0 §2.2/§35）。
## 职责：注册唯一外观编辑器 Dock（中文标题）并注入编辑器 UndoRedo；禁用时完全移除。
## 输入输出：由 Godot 插件生命周期调用，无返回值。
## 副作用：增删右侧 Dock；不连接任何外部信号。
## 边界：本插件是正式视觉资产的唯一可见业务入口（旧 light_speed_art_profile 插件已删除，
##       其仍被需要的最小后端服务迁至本插件 backend/ 子目录），本文件不承载业务逻辑。

const _DockScript: GDScript = preload("./workbench_dock.gd")
## Dock 页签中文标题（禁 @VBoxContainer@ 自动名与英文业务名）。
const DOCK_TITLE: String = "外观编辑器"

var _dock: Control = null


## 插件启用入口：创建唯一外观编辑器 Dock 并注入真实 UndoRedo 管理器。
## 无参数无返回；副作用为注册 Dock。
func _enter_tree() -> void:
	_cleanup()
	_dock = _DockScript.new() as Control
	_dock.name = DOCK_TITLE
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_dock.set_editor_undo_redo(get_undo_redo())


## 插件禁用入口：移除并释放 Dock。
## 无参数无返回；副作用为撤销 _enter_tree 的注册。
func _exit_tree() -> void:
	_cleanup()


## 统一清理，保证重复启停不残留 Dock；可重复调用。
func _cleanup() -> void:
	if _dock != null:
		if is_instance_valid(_dock):
			_dock.set_editor_undo_redo(null)
			remove_control_from_docks(_dock)
			_dock.queue_free()
		_dock = null
