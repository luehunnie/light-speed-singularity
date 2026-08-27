@tool
class_name LightSpeedVisualWorkbenchImportService
extends RefCounted

## Workbench 正式资源导入服务（S3-03；GUI 冻结总结 v1.0 §36/§38/§39/§40）。
## 职责：执行冻结九步导入流水线：选外部图→检查格式→检查尺寸合同→自动规范命名→
##       复制到正式目录→应用 Import Preset→等待/触发 Godot Import→绑定正式视觉槽→
##       刷新 Effective Preview。
## 输入输出：输入请求字典（见 run_import 注释），返回 {ok, steps, formal_path, canonical_name}；
##       steps 恒为 9 项，每项 {id, index, status, detail}，status ∈ pass/fail/warning/skipped/not_run。
## 副作用：第 5 步复制源文件到正式目录（覆盖策略见请求）；第 6/7/8/9 步的副作用全部经
##       注入 Callable 钩子发生，未注入时该步记 skipped（首批降级：使用 Godot 默认导入）。
## 边界：不自动缩放/重采样用户图片（§39，尺寸不合法直接失败或警告）；Strict 不合法阻止导入；
##       历史版本交给 Git（§38），不生成 _old/_new 文件；不直接修改任何 .tres——
##       槽位绑定只经 slot_binder 钩子（由 Change Set 暂存，Apply All 时经 UndoRedo 落盘）。

const STEP_CHOOSE: String = "choose_external_image"
const STEP_FORMAT: String = "check_format"
const STEP_SIZE: String = "check_size_contract"
const STEP_NAME: String = "build_canonical_name"
const STEP_COPY: String = "copy_into_formal_dir"
const STEP_PRESET: String = "apply_import_preset"
const STEP_IMPORT: String = "trigger_editor_import"
const STEP_BIND: String = "bind_formal_slot"
const STEP_PREVIEW: String = "refresh_effective_preview"

## 冻结九步的固定顺序（§36 流程 1-9）。
const STEP_IDS: Array = [
	STEP_CHOOSE, STEP_FORMAT, STEP_SIZE, STEP_NAME, STEP_COPY,
	STEP_PRESET, STEP_IMPORT, STEP_BIND, STEP_PREVIEW,
]
## 首批允许的图片格式。
const ALLOWED_FORMATS: Array = ["png", "jpg", "jpeg", "webp"]

var _naming: LightSpeedVisualWorkbenchAssetNaming = LightSpeedVisualWorkbenchAssetNaming.new()


## 运行九步导入。请求字段：
##   source_path: String 外部图片绝对/带协议路径；formal_dir: String 正式目录（如 res://assets/art/crystal/）；
##   identity / slot / state / direction / usage: String 命名维度；extension 可省略（默认取源文件扩展名）；
##   size_mode: "strict"|"recommended"|"free"（默认 free）；expected_size: Vector2i（ZERO = 未声明合同）；
##   overwrite: bool 目标已存在时是否覆盖（Replace 流程传 true，§38）；
##   hooks: {preset_applier: Callable, import_trigger: Callable, slot_binder: Callable, preview_refresher: Callable}
##     —— 每个钩子收 formal_path（String），返回 {status, detail}（binder 用 {ok, detail}）。
## 返回 {ok, steps, formal_path, canonical_name}；ok = 无 fail 步（warning 允许）。
func run_import(request: Dictionary) -> Dictionary:
	var steps: Array = []
	var formal_path: String = ""
	var canonical_name: String = ""
	var failed: bool = false

	# 1. 选择项目外图片（调用方已选，此处校验存在性）。
	var source: String = String(request.get("source_path", ""))
	if source == "" or not FileAccess.file_exists(source):
		steps.append(_step(STEP_CHOOSE, "fail", "外部图片不存在：%s。" % source))
		failed = true
	else:
		steps.append(_step(STEP_CHOOSE, "pass", source))

	# 2. 检查格式。
	var extension: String = String(request.get("extension", source.get_extension())).to_lower()
	if not failed:
		if not (extension in ALLOWED_FORMATS):
			steps.append(_step(STEP_FORMAT, "fail", "不支持的图片格式：.%s（允许 %s）。" % [extension, ", ".join(PackedStringArray(ALLOWED_FORMATS))]))
			failed = true
		else:
			steps.append(_step(STEP_FORMAT, "pass", ".%s" % extension))

	# 3. 检查尺寸合同（§39：不缩放；Strict 阻止，Recommended 警告可继续）。
	if not failed:
		var size_result: Dictionary = _check_size(source, request)
		steps.append(_step(STEP_SIZE, size_result["status"], size_result["detail"]))
		# Strict 不合法必须立即阻止导入（§39），不得继续复制文件。
		if String(size_result["status"]) == "fail":
			failed = true

	# 4. 自动规范命名（§37）。
	if not failed:
		canonical_name = _naming.build_formal_name(
			String(request.get("identity", "")), String(request.get("slot", "")),
			String(request.get("state", "")), String(request.get("direction", "")),
			String(request.get("usage", "")), extension)
		var lint: PackedStringArray = _naming.lint_formal_name(canonical_name)
		if canonical_name == "" or not lint.is_empty():
			steps.append(_step(STEP_NAME, "fail", "规范命名生成失败：%s。" % ", ".join(lint)))
			failed = true
		else:
			formal_path = String(request.get("formal_dir", "")).path_join(canonical_name)
			steps.append(_step(STEP_NAME, "pass", canonical_name))

	# 5. 复制到正式目录。
	if not failed:
		var copy_result: Dictionary = _copy_into_formal_dir(source, String(request.get("formal_dir", "")), canonical_name, bool(request.get("overwrite", false)))
		if copy_result.ok:
			steps.append(_step(STEP_COPY, "pass", formal_path))
		else:
			steps.append(_step(STEP_COPY, "fail", copy_result.reason))
			failed = true

	# 6-9. Import Preset / Godot Import / 绑定正式槽 / 刷新 Preview（钩子驱动）。
	var hooks: Dictionary = request.get("hooks", {})
	if not failed:
		for pair: Dictionary in [
			{ id = STEP_PRESET, key = "preset_applier" },
			{ id = STEP_IMPORT, key = "import_trigger" },
			{ id = STEP_BIND, key = "slot_binder" },
			{ id = STEP_PREVIEW, key = "preview_refresher" },
		]:
			steps.append(_run_hook(pair["id"], hooks.get(pair["key"], Callable()), formal_path))

	steps = _pad_not_run(steps)
	var ok: bool = not failed and not _has_fail(steps)
	return { ok = ok, steps = steps, formal_path = formal_path, canonical_name = canonical_name }


## 构造单步结果记录。
func _step(id: String, status: String, detail: String) -> Dictionary:
	return { id = id, index = STEP_IDS.find(id) + 1, status = status, detail = detail }


## 尺寸合同检查：读取源图尺寸并与 expected_size 比较。
## 返回 {status, detail}；未声明合同（ZERO）或 free 模式记 skipped。
func _check_size(source: String, request: Dictionary) -> Dictionary:
	var expected: Vector2i = request.get("expected_size", Vector2i.ZERO)
	var mode: String = String(request.get("size_mode", "free"))
	if mode == "free" or expected == Vector2i.ZERO:
		return { status = "skipped", detail = "未声明尺寸合同（Free Size）。" }
	var image: Image = Image.load_from_file(source)
	if image == null:
		return { status = "fail", detail = "无法读取源图片尺寸。" }
	var actual: Vector2i = Vector2i(image.get_width(), image.get_height())
	if actual == expected:
		return { status = "pass", detail = "尺寸 %s 符合合同。" % [actual] }
	var text: String = "尺寸 %s 不符合同 %s（§39 不自动缩放）。" % [actual, expected]
	if mode == "strict":
		return { status = "fail", detail = text + "Strict 合同已阻止导入。" }
	return { status = "warning", detail = text + "Recommended 合同仅警告，可继续。" }


## 复制源文件到正式目录（字节级复制，保持源文件不动）。
## 目标已存在且不允许覆盖时失败；目录不存在时自动创建。
func _copy_into_formal_dir(source: String, formal_dir: String, canonical_name: String, overwrite: bool) -> Dictionary:
	if formal_dir == "" or canonical_name == "":
		return { ok = false, reason = "正式目录或规范名缺失。" }
	var target: String = formal_dir.path_join(canonical_name)
	if FileAccess.file_exists(target) and not overwrite:
		return { ok = false, reason = "正式文件已存在且未允许覆盖：%s（§38 Replace 需显式覆盖）。" % target }
	var error: int = DirAccess.make_dir_recursive_absolute(formal_dir)
	if error != OK and not DirAccess.dir_exists_absolute(formal_dir):
		return { ok = false, reason = "正式目录创建失败：%s（%d）。" % [formal_dir, error] }
	var reader: FileAccess = FileAccess.open(source, FileAccess.READ)
	var writer: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	if reader == null or writer == null:
		return { ok = false, reason = "复制打开文件失败（源或目标不可读写）。" }
	writer.store_buffer(reader.get_buffer(reader.get_length()))
	return { ok = true, reason = "" }


## 运行一个钩子步：未注入或非法 → skipped；返回 {status, detail} 的钩子结果原样采信；
## slot_binder 用 {ok, detail} 协议（ok=false 记 fail，阻止后续）。
func _run_hook(id: String, hook: Callable, formal_path: String) -> Dictionary:
	if not hook.is_valid():
		return _step(id, "skipped", "未注入钩子（首批降级）。")
	var result: Dictionary = hook.call(formal_path)
	if id == STEP_BIND:
		if bool(result.get("ok", false)):
			return _step(id, "pass", String(result.get("detail", "")))
		return _step(id, "fail", String(result.get("detail", "槽位绑定失败。")))
	var status: String = String(result.get("status", "skipped"))
	if not (status in ["pass", "warning", "skipped"]):
		status = "fail"
	return _step(id, status, String(result.get("detail", "")))


## 把未执行到的步骤补齐为 not_run，保证 steps 恒为 9 项。
func _pad_not_run(steps: Array) -> Array:
	for id: String in STEP_IDS:
		var found: bool = false
		for step: Dictionary in steps:
			if String(step["id"]) == id:
				found = true
				break
		if not found:
			steps.append(_step(id, "not_run", "前序步骤失败，本步未执行。"))
	return steps


## steps 中是否存在 fail 步。
func _has_fail(steps: Array) -> bool:
	for step: Dictionary in steps:
		if String(step["status"]) == "fail":
			return true
	return false
