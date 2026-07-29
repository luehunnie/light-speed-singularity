extends RefCounted

## core_loop 原型场景集成测试共享夹具（D4.6-T5）。
## 只负责实例化场景、定位 RuntimeObjects/Emitter 节点、基础入树与清理；不含断言、不含发射器/水晶业务规则、不隐藏 fire/reset/direction 等被测行为。
## tree 由调用方构造时传入（运行测试的 SceneTree），用于把场景根挂到 root 并推进 process_frame 触发真实 _ready。
## 与 tests/unit/placement/fixtures、tests/unit/runtime/fixtures 保持目录边界，互不引用。

const _EmitterConfigNode: GDScript = preload(
	"res://gameplay/mechanisms/emitters/emitter_config_node.gd"
)

var _tree: SceneTree = null


func _init(tree: SceneTree) -> void:
	_tree = tree


## 取 RuntimeObjects/Emitter；root_node 为空时返回 null。
func get_emitter(root_node: Node2D) -> _EmitterConfigNode:
	if root_node == null:
		return null
	return root_node.get_node_or_null("RuntimeObjects/Emitter") as _EmitterConfigNode


## 实例化场景并挂入 root，泵一帧触发真实 _ready；返回根节点（场景为空或实例化失败返回 null）。
func instantiate_and_ready(scene: PackedScene) -> Node2D:
	if scene == null:
		return null
	var node: Node2D = scene.instantiate() as Node2D
	if node == null:
		return null
	_tree.get_root().add_child(node)
	await _tree.process_frame
	return node


## 释放一个挂入过 root 的节点并泵一帧，让删除落地避免残留子节点影响后续用例。
func free_settled(node: Node2D) -> void:
	if node == null:
		return
	if is_instance_valid(node):
		node.free()
	await _tree.process_frame
