extends RefCounted

## 运行期 Definition 索引（AF-10 第三批）：core_loop 的 registry 驱动装配辅助。
## 首次使用时经 FormalContentDiscovery 扫描定义目录构建 FormalContentRegistry（Definition = Truth，
## Registry = Index，AF-01 冻结口径；运行期不 preload 编辑器插件）并缓存；发现失败返回 null 且
## push_error 一次，调用方按未知类型安全降级。
## mechanism_id → 类型前缀解析：复用 PlacementController._make_next_mechanism_id 的 `<type_id>_<serial>`
## 书写约定与 DragFlow `preview_<type_id>` 预览命名；只做前缀还原，不反向生成 ID（唯一书写方仍是控制器）。
## 不负责：库存、UI、节点创建（工厂 Callable 由 core_loop 持有）。


const _FormalContentDiscovery: GDScript = preload(
	"res://gameplay/content/formal_content_discovery.gd"
)

## 缓存的正式 Registry；null = 未构建或构建失败。
var _registry: Variant = null
## 是否已尝试过构建（失败不重试，避免每帧扫描）。
var _attempted: bool = false


## 取正式 Registry（未构建时先尝试构建）；构建失败返回 null。
func get_registry() -> Variant:
	if not _attempted:
		_attempted = true
		var result: Dictionary = _FormalContentDiscovery.discover()
		if bool(result.get("ok", false)):
			var registry_script: GDScript = load(
				"res://gameplay/content/formal_content_registry.gd"
			)
			_registry = registry_script.build(result.get("definitions", []))
		else:
			var errors: PackedStringArray = result.get("errors", PackedStringArray())
			push_error("RuntimeDefinitionIndex: 定义发现失败，多类型工厂与道具卡按未知类型降级：%s" % [
				"；".join(errors) if errors != null else "未知错误"])
	return _registry


## 是否已在 Registry 声明指定类型。
func has_type(type_id: StringName) -> bool:
	var registry: Variant = get_registry()
	return registry != null and registry.has_type(type_id)


## 取类型定义；未知/未构建返回 null。
func get_definition(type_id: StringName) -> Variant:
	var registry: Variant = get_registry()
	return registry.get_definition(type_id) if registry != null else null


## 解析 mechanism_id / 预览 ID 的类型前缀：先剥 `preview_`，再剥结尾 `_<纯数字序号>`；
## 无数字后缀时视整个 ID 为类型（如游离测试 ID）；解析不出非空串返回空 StringName。
static func type_prefix_of(mechanism_id: StringName) -> StringName:
	var text: String = String(mechanism_id)
	if text.is_empty():
		return &""
	if text.begins_with("preview_"):
		text = text.substr("preview_".length())
	var parts: PackedStringArray = text.rsplit("_", false, 1)
	if parts.size() == 2 and parts[1].is_valid_int():
		return StringName(parts[0])
	return StringName(text)


## 取类型正式场景；解析规则：
## [br]- 类型前缀为空 → 返回 legacy_scene（旧路径兼容，如非生成规则 ID）；
## [br]- 类型 = legacy_type_id 且 Registry 不可用/未声明 → 返回 legacy_scene（无 metadata 原型路径不依赖发现）；
## [br]- 其余：Registry 已声明该类型且 definition.scene 有效 → 返回该场景；否则返回 null（调用方失败回滚，不错放机关）。
func resolve_scene_for_mechanism_id(mechanism_id: StringName, legacy_type_id: StringName, legacy_scene: PackedScene) -> PackedScene:
	var type_id: StringName = type_prefix_of(mechanism_id)
	if type_id == &"":
		return legacy_scene
	if type_id == legacy_type_id and (get_registry() == null or not get_registry().has_type(type_id)):
		return legacy_scene
	var definition: Variant = get_definition(type_id)
	if definition == null:
		return null
	var scene: Variant = definition.get("scene")
	if scene == null or not scene is PackedScene:
		push_error("RuntimeDefinitionIndex: 类型 %s 的 definition.scene 缺失，拒绝实例化。" % [type_id])
		return null
	return scene
