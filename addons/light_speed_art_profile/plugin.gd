@tool
extends EditorPlugin

## 美术 Profile 只读插件入口。
## 职责：创建 Dock、监听编辑器选择、把选择快照交给 Dock 展示。
## 输入输出：由 Godot 插件生命周期调用，无返回值。
## 副作用：增删右侧 Dock 并连接/断开 EditorSelection.selection_changed。
## 边界：重复启停先清理旧连接；空选择、多选、释放节点交由 Dock 安全清空。

const _DOCK_SCENE: PackedScene = preload("res://addons/light_speed_art_profile/dock/art_profile_dock.tscn")

var _dock: Control = null
var _selection: EditorSelection = null
var _selection_changed_callable: Callable = Callable()


## 插件启用入口：创建 Dock 并开始监听当前场景树选择。
## 无参数无返回；副作用为注册 Dock 和信号连接。
func _enter_tree() -> void:
	_cleanup()
	_dock = _DOCK_SCENE.instantiate() as Control
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_selection = get_editor_interface().get_selection()
	_selection_changed_callable = Callable(self, "_on_selection_changed")
	if _selection != null and not _selection.selection_changed.is_connected(_selection_changed_callable):
		_selection.selection_changed.connect(_selection_changed_callable)
	_on_selection_changed()


## 插件禁用入口：断开信号、移除 Dock、释放节点。
## 无参数无返回；副作用为撤销 _enter_tree 的编辑器注册。
func _exit_tree() -> void:
	_cleanup()


## 选择变化回调：读取当前选择数组并交给 Dock 解析展示。
## 无参数无返回；只读访问 EditorSelection，不修改场景或资源。
func _on_selection_changed() -> void:
	if _dock == null or not is_instance_valid(_dock):
		return
	if _selection == null:
		_dock.show_selection([])
		return
	_dock.show_selection(_selection.get_selected_nodes())


## 统一清理插件资源，保证重复启停不残留连接或 Dock。
## 无参数无返回；可重复调用，已释放节点会被安全忽略。
func _cleanup() -> void:
	if _selection != null and _selection_changed_callable.is_valid():
		if _selection.selection_changed.is_connected(_selection_changed_callable):
			_selection.selection_changed.disconnect(_selection_changed_callable)
	_selection = null
	_selection_changed_callable = Callable()
	if _dock != null:
		if is_instance_valid(_dock):
			remove_control_from_docks(_dock)
			_dock.queue_free()
		_dock = null
