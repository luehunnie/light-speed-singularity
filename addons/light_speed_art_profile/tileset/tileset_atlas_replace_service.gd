@tool
class_name LightSpeedArtProfileTilesetAtlasReplaceService
extends RefCounted

## TileSet 图集整套纹理替换服务（TileSet 美术工作流 v1）。
## 职责：解析外部 TileSet 与图集源（多 atlas 必须明确选择）；校验新纹理（Texture2D、网格整数倍、
##       覆盖已用坐标含动画帧）；经 TilesetReferenceScanner 扫描受影响场景（不可读场景即失败）；
##       签发与 {TileSet 路径, source_id, 新纹理路径, 引用指纹} 绑定的一次性 token；apply 前重扫比对，
##       新增/删除/变化一律拒绝并要求重新分析；经 UndoRedo 双向「改 texture → 写同一 .tres → 刷新」。
## 输入输出：analyze(layer, source_id, new_texture_path) -> {ok, reason, token, tileset_path, source_id,
##       region, required_grid, affected_scenes, fingerprint, current/new_texture_path, new_texture_size}；
##       apply(token, undo_redo) -> {ok, reason, path, skipped}。
## 副作用：apply 成功仅改 TileSetAtlasSource.texture 并写 TileSet 既有 resource_path；绝不改 tile cells、
##       source_id、atlas 坐标、alternative、碰撞、custom data、资源路径，也绝不写任何 .tscn。
## 边界：无 token / token 已用 / 绑定失效 / 快照漂移 / 不可读场景 / 未注入 UndoRedo 一律拒绝；
##       token 一次性（apply 即作废，成败皆然，拒绝后须重新分析）；user:// 纹理仅供 headless 测试；
##       扫描根默认 res://，测试注入 fixture 根；UndoRedo 分发沿用 visual_state_edit_service 约定。
## 已知天花板（ponytail: 覆盖范围按已用 atlas 坐标 + 动画帧列/行推算）：超过 1×1 region 的多格 tile
##       自身尺寸无公开查询 API，未计入覆盖下界；引入多格 tile 出现裁切时升级为逐格枚举。

const _ScannerScript: GDScript = preload(
	"res://addons/light_speed_art_profile/tileset/tileset_reference_scanner.gd"
)

# 可注入保存后端，签名为 (resource, path) -> int（Error 整数）；默认 ResourceSaver。
var _save_backend: Callable = Callable()
# 可注入刷新回调（无参）；写盘成功后调用，默认由面板注入 TileMapLayer.queue_redraw。
var _refresh_callable: Callable = Callable()
# 引用扫描器：枚举/读取/匹配/错误收集/指纹全部在 scanner，服务只消费结构化结果。
var _scanner: RefCounted = _ScannerScript.new()
# 分析计划表：token -> 计划（含绑定字段与引用指纹）；apply 一次性消费。
var _plans: Dictionary = {}
var _next_token: int = 0
# 最近一次 _persist_and_refresh 的写盘错误码；apply 在 commit 后检查并回滚。
var _last_persist_error: int = OK


## 解析 TileMapLayer 的可替换目标：外部 TileSet + 全部 TileSetAtlasSource 条目。
## node 非 TileMapLayer 拒绝；返回 {ok, reason, tileset, tileset_path, atlas_sources, layer}；无副作用。
func resolve_target(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node is TileMapLayer:
		return _deny("请选择一个 TileMapLayer 节点（如 WallLayer）。")
	var layer: TileMapLayer = node as TileMapLayer
	var tileset: TileSet = layer.tile_set
	if tileset == null or not is_instance_valid(tileset):
		return _deny("该 TileMapLayer 未设置 TileSet。")
	if tileset.resource_path == "":
		return _deny("该 TileSet 是内联资源（无 .tres 路径）；v1 仅支持替换外部共享 .tres。")
	var entries: Array = []
	for index in tileset.get_source_count():
		var source_id: int = tileset.get_source_id(index)
		var source: TileSetSource = tileset.get_source(source_id)
		if source is TileSetAtlasSource:
			entries.append({source_id = source_id, atlas = source})
	return {
		ok = true, reason = "", layer = layer, tileset = tileset,
		tileset_path = tileset.resource_path, atlas_sources = entries,
	}


## 校验新纹理是否满足整套替换守卫；返回 {ok, reason, region, required_grid}。无副作用。
func validate_texture(atlas: TileSetAtlasSource, new_texture) -> Dictionary:
	if new_texture == null or not new_texture is Texture2D:
		return _deny("新纹理必须是 Texture2D 资源。")
	var region: Vector2i = atlas.texture_region_size
	if region.x <= 0 or region.y <= 0:
		return _deny("图集 texture_region_size 无效，拒绝替换。")
	var width: int = new_texture.get_width()
	var height: int = new_texture.get_height()
	if width <= 0 or height <= 0:
		return _deny("新纹理尺寸无效，拒绝替换。")
	if width % region.x != 0 or height % region.y != 0:
		return _deny("新纹理 %d×%d 不是图块 %d×%d 的整数倍网格，拒绝替换。" % [width, height, region.x, region.y])
	var required_grid: Vector2i = _required_grid(atlas)
	var need_px: Vector2i = required_grid * region
	if width < need_px.x or height < need_px.y:
		return _deny("新纹理 %d×%d 不足以覆盖已用图块范围（至少需 %d×%d），拒绝替换。" % [width, height, need_px.x, need_px.y])
	return {ok = true, reason = "", region = region, required_grid = required_grid}


## 分析一次替换计划：解析目标 + 校验新纹理 + 引用扫描（不可读场景即失败，不发 token）
## + 签发与引用指纹绑定的一次性 token；source_id < 0 表示要求唯一图集源自动定位；无写盘副作用。
func analyze(layer: Node, source_id: int, new_texture_path: String) -> Dictionary:
	var resolved: Dictionary = resolve_target(layer)
	if not resolved.ok:
		return resolved
	var tileset: TileSet = resolved.tileset
	var entries: Array = resolved.atlas_sources
	if entries.is_empty():
		return _deny("该 TileSet 不含任何 TileSetAtlasSource，无法整套替换纹理。")
	var chosen: Dictionary = {}
	if source_id < 0:
		if entries.size() > 1:
			return _deny("该 TileSet 含 %d 个图集源，必须在面板中明确选择一个（v1 不做猜测）。" % entries.size())
		chosen = entries[0]
	else:
		for entry in entries:
			if int(entry.source_id) == source_id:
				chosen = entry
				break
		if chosen.is_empty():
			return _deny("指定的图集源 source_id=%d 不存在或不是 TileSetAtlasSource。" % source_id)
	var atlas: TileSetAtlasSource = chosen.atlas
	if new_texture_path == "" or not (new_texture_path.begins_with("res://") or new_texture_path.begins_with("user://")):
		return _deny("请提供 res:// 下的新纹理路径。")
	var loaded = _load_resource_or_wrapper(new_texture_path)
	if loaded == null:
		return _deny("无法加载新纹理：%s" % new_texture_path)
	if not (loaded is Texture2D):
		return _deny("新纹理必须是 Texture2D 资源。")
	var new_texture: Texture2D = loaded
	var check: Dictionary = validate_texture(atlas, new_texture)
	if not check.ok:
		return check
	var scan_result: Dictionary = _scan_references(tileset)
	if not bool(scan_result.ok):
		return _deny("引用扫描失败，已拒绝分析（修复后重试）：\n" + _scan_errors_text(scan_result.errors))
	_next_token += 1
	_plans[_next_token] = {
		tileset = tileset, atlas = atlas, source_id = int(chosen.source_id),
		new_texture = new_texture, new_texture_path = new_texture_path,
		tileset_path = tileset.resource_path, fingerprint = scan_result.fingerprint,
	}
	var current_path: String = ""
	if atlas.texture != null:
		current_path = atlas.texture.resource_path
	return {
		ok = true, reason = "", token = _next_token,
		tileset_path = tileset.resource_path, source_id = int(chosen.source_id),
		region = check.region, required_grid = check.required_grid,
		affected_scenes = scan_result.references, fingerprint = scan_result.fingerprint,
		current_texture_path = current_path, new_texture_path = new_texture_path,
		new_texture_size = Vector2i(new_texture.get_width(), new_texture.get_height()),
	}


## 凭一次性 token 执行整套替换：先校验绑定（TileSet 路径 / 图集源 / 新纹理路径），再重扫比对引用
## 指纹；绑定失效、不可读场景或快照新增/删除/变化均拒绝并要求重新分析。成功时 do/undo 双向均为
## 「texture 赋值 → 写同一 .tres → emit_changed + 刷新」；写盘失败回滚内存，磁盘保持旧内容。
func apply(token: int, undo_redo) -> Dictionary:
	if not _plans.has(token):
		return _deny("缺少有效确认 token，已拒绝替换（须先分析并由用户明确确认）。")
	var plan: Dictionary = _plans[token]
	_plans.erase(token)
	if undo_redo == null:
		return _deny("未注入 UndoRedo 管理器，已拒绝替换。")
	var atlas: TileSetAtlasSource = plan.atlas
	var tileset: TileSet = plan.tileset
	var new_texture: Texture2D = plan.new_texture
	if not is_instance_valid(atlas) or not is_instance_valid(tileset) or not is_instance_valid(new_texture):
		return _deny("图集源、TileSet 或新纹理已失效，请重新分析。")
	if tileset.resource_path != String(plan.tileset_path) \
			or not tileset.has_source(int(plan.source_id)) \
			or tileset.get_source(int(plan.source_id)) != atlas \
			or new_texture.resource_path != String(plan.new_texture_path):
		return _deny("计划绑定已变化（TileSet 路径 / 图集源 / 新纹理），请重新分析确认。")
	var rescan: Dictionary = _scan_references(tileset)
	if not bool(rescan.ok):
		return _deny("引用重扫失败，已拒绝替换（修复后重新分析）：\n" + _scan_errors_text(rescan.errors))
	if String(rescan.fingerprint) != String(plan.fingerprint):
		return _deny("受影响场景引用已变化（新增/删除场景），请重新分析确认。")
	var old_texture: Texture2D = atlas.texture
	if new_texture == old_texture or (
		old_texture != null
		and new_texture.resource_path != ""
		and new_texture.resource_path == old_texture.resource_path
	):
		return {ok = true, reason = "纹理未变化，已跳过替换。", path = tileset.resource_path, skipped = true}
	_last_persist_error = OK
	undo_redo.create_action("替换共享 TileSet 图集纹理")
	undo_redo.add_do_property(atlas, "texture", new_texture)
	undo_redo.add_undo_property(atlas, "texture", old_texture)
	_add_persist_method(undo_redo, tileset, true)
	_add_persist_method(undo_redo, tileset, false)
	undo_redo.commit_action()
	if _last_persist_error != OK:
		# 写盘失败：内存回滚到旧纹理；磁盘从未写入新内容（ResourceSaver 失败即未落盘）。
		# 撤销栈中该动作保持可安全 undo/redo（属性幂等，redo 会重试写盘）。
		atlas.texture = old_texture
		tileset.emit_changed()
		return {
			ok = false, path = tileset.resource_path, skipped = false,
			reason = "写入 .tres 失败（错误码 %d），已回滚内存修改，磁盘未被修改。" % _last_persist_error,
		}
	return {
		ok = true, path = tileset.resource_path, skipped = false,
		reason = "已替换并写入 %s（do/undo 均写同一文件）。" % tileset.resource_path,
	}


## 注入影响列表扫描根（默认 res://；仅供测试传 user:// fixture 根）；转发给扫描器。无返回值。
func set_scene_scan_roots(roots: PackedStringArray) -> void:
	_scanner.set_scan_roots(roots)


## 注入保存后端，签名为 (resource, path) -> int；无返回值。
func set_save_backend(backend: Callable) -> void:
	_save_backend = backend


## 清除已注入的保存后端，恢复默认 ResourceSaver；无返回值。
func clear_save_backend() -> void:
	_save_backend = Callable()


## 注入写盘成功后的刷新回调（无参）；无返回值。
func set_refresh_callable(cb: Callable) -> void:
	_refresh_callable = cb


## do/undo 共用的持久化步骤：把 TileSet 写回其 resource_path，成功后 emit_changed 并调刷新回调。
## tileset 由动作参数携带（避免多 TileSet 连续替换后 undo 写错文件）；Error 存入 _last_persist_error。
func _persist_and_refresh(tileset: TileSet) -> void:
	if tileset == null or not is_instance_valid(tileset) or tileset.resource_path == "":
		_last_persist_error = ERR_FILE_CANT_OPEN
		return
	_last_persist_error = _invoke_save(tileset, tileset.resource_path)
	if _last_persist_error != OK:
		return
	tileset.emit_changed()
	if _refresh_callable.is_valid():
		_refresh_callable.call()


## 统一 UndoRedo 与 EditorUndoRedoManager 的 add_*_method 调用形式（带一个 TileSet 参数）：
## EditorUndoRedoManager 为 (object, method, args...) 旧式；UndoRedo 收单 Callable（bind 携带参数，
## Variant 持有 TileSet 引用；服务由面板在 Dock 生命周期内持有，与既有服务约定一致）。
func _add_persist_method(undo_redo, tileset: TileSet, is_do: bool) -> void:
	if undo_redo.get_class() == "EditorUndoRedoManager":
		if is_do:
			undo_redo.add_do_method(self, &"_persist_and_refresh", tileset)
		else:
			undo_redo.add_undo_method(self, &"_persist_and_refresh", tileset)
	else:
		var bound: Callable = Callable(self, &"_persist_and_refresh").bind(tileset)
		if is_do:
			undo_redo.add_do_method(bound)
		else:
			undo_redo.add_undo_method(bound)


## 扫描引用：解析 TileSet uid 文本后交扫描器；返回 scanner 结构化结果。
func _scan_references(tileset: TileSet) -> Dictionary:
	var uid_text: String = ""
	var uid: int = ResourceLoader.get_resource_uid(tileset.resource_path)
	if uid != -1:
		uid_text = ResourceUID.id_to_text(uid)
	return _scanner.scan(tileset.resource_path, uid_text)


## 汇总扫描错误为可显示文本（每行一条 路径：原因）。
func _scan_errors_text(errors: Array) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for error in errors:
		lines.append("· %s：%s" % [String(error.path), String(error.reason)])
	return "\n".join(lines)


## 加载纹理资源：res:// 走 ResourceLoader；user:// 为 headless 测试专用（ResourceLoader 不识别，
## 经 Image 包装；take_over_path 注册路径，规避同路径旧占用者使 resource_path 赋值被静默忽略）。
func _load_resource_or_wrapper(path: String):
	if ResourceLoader.exists(path):
		return load(path)
	if path.begins_with("user://") and FileAccess.file_exists(path):
		var image: Image = Image.load_from_file(path)
		if image == null:
			return null
		var wrapped: ImageTexture = ImageTexture.create_from_image(image)
		wrapped.take_over_path(path)
		return wrapped
	return null


## 调用保存后端；默认走 ResourceSaver.save。返回 Error 整数。
func _invoke_save(resource: Resource, path: String) -> int:
	if _save_backend.is_valid():
		var result = _save_backend.call(resource, path)
		if result is int:
			return result
		return OK
	return ResourceSaver.save(resource, path)


## 推算图集已用坐标下界（含动画帧占据的列/行范围）；返回最大已用坐标 + (1,1)。
func _required_grid(atlas: TileSetAtlasSource) -> Vector2i:
	var max_coord: Vector2i = Vector2i.ZERO
	for index in atlas.get_tiles_count():
		var coords: Vector2i = atlas.get_tile_id(index)
		var extent: Vector2i = coords
		var frames: int = atlas.get_tile_animation_frames_count(coords)
		if frames > 1:
			var columns: int = max(atlas.get_tile_animation_columns(coords), 1)
			var rows: int = ceili(float(frames) / float(columns))
			extent = Vector2i(coords.x + columns - 1, coords.y + rows - 1)
		max_coord = Vector2i(max(max_coord.x, extent.x), max(max_coord.y, extent.y))
	return max_coord + Vector2i.ONE


## 构造拒绝结果。reason 为中文原因；无副作用。
func _deny(reason: String) -> Dictionary:
	return {ok = false, reason = reason}
