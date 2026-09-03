extends SceneTree

## OBJ-C3 DoubleCellMirror 判定逻辑回归测试（48 条速查表 + 脚本接口）。
## 目标：证明 double_cell_mirror.gd 的判定纯函数 resolve_interaction 覆盖规则文档 §8 四朝向 × 12 条全部映射，
##   且脚本具备正式光交互契约面（interact_ray/interact_particle）、多格 footprint（get_occupied_offsets）与
##   默认朝向 RIGHT 等关键事实。本测试不依赖场景（.tscn 尚未创建），全部经静态函数与不入树实例验证；
##   生命周期（放置/移动/回收，需真实 .tscn + PlacementController）留待 .tscn 落地后补充。
## 判定依据：规则文档 v0.6 §8 四朝向速查表。resolve_interaction(orientation, cell_offset, incoming_direction) 返回 Resolution：
##   CONTINUE（端点穿越/平行）、BLOCK（正交折回/背面、斜向背面中心点）、REDIRECT_CROSS（斜向正面中心点，含反射/穿邻方向）。
## 由 Godot --script 运行，全部通过 quit(0)，任一失败 quit(1)。不修改任何生产代码。

const _DoubleCellMirror: GDScript = preload(
	"res://gameplay/mechanisms/mirrors/double_cell_mirror.gd"
)

# 判定结果枚举（int 值，供数据驱动断言比较）。
const OUT_CONTINUE: int = _DoubleCellMirror.Resolution.Outcome.CONTINUE
const OUT_BLOCK: int = _DoubleCellMirror.Resolution.Outcome.BLOCK
const OUT_CROSS: int = _DoubleCellMirror.Resolution.Outcome.REDIRECT_CROSS

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


## SceneTree 初始化入口：等待一帧后跑全部用例（与项目其余测试同款约定）。
func _initialize() -> void:
	await process_frame
	_test_A01_script_loadable_and_interface()
	_test_A02_default_orientation_right()
	_test_A03_get_occupied_offsets_four_orientations()
	_test_A04_get_light_interaction_forms()
	_test_C01_quicktable_48_cases()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== A 脚本与接口 =====

## A01. 脚本可实例化、具备正式交互契约面与多格 footprint 接口。
func _test_A01_script_loadable_and_interface() -> void:
	const NAME: String = "A01_脚本可实例化且接口完整"
	var m: Variant = _DoubleCellMirror.new()
	if _check(NAME, m != null, "double_cell_mirror.gd 实例化失败。"):
		_check(NAME, m is PlaceableToken, "应继承 PlaceableToken。")
		_check(NAME, m.has_method("interact_ray"), "应具备 RAY 交互入口 interact_ray。")
		_check(NAME, m.has_method("interact_particle"), "应具备 PARTICLE 交互入口 interact_particle。")
		_check(NAME, m.has_method("get_occupied_offsets"), "应具备多格 footprint 入口 get_occupied_offsets。")
		_check(NAME, m.has_method("set_orientation"), "应具备朝向接口 set_orientation。")
		_check(NAME, m.has_method("toggle_orientation"), "应具备旋转接口 toggle_orientation。")
		_check(NAME, m.has_method("apply_configuration"), "应具备 Typed 配置接口 apply_configuration。")
		_check(NAME, m.has_method("get_light_interaction_forms"), "应具备形态声明入口 get_light_interaction_forms。")
		_check(NAME, "orientation" in m, "应具备 orientation 事实字段。")
		m.free()


## A02. 默认朝向为 RIGHT（2026-09-03 由 BOTTOM 改，对齐规则文档 §2/§6/§7）。
func _test_A02_default_orientation_right() -> void:
	const NAME: String = "A02_默认朝向为RIGHT"
	var m: Variant = _DoubleCellMirror.new()
	_check(NAME, m.orientation == _DoubleCellMirror.MirrorOrientation.RIGHT, "默认 orientation 期望 RIGHT(1)，实际 %s。" % [m.orientation])
	_check(NAME, m.orientation != _DoubleCellMirror.MirrorOrientation.BOTTOM, "默认不应为 BOTTOM。")
	m.free()


## A03. get_occupied_offsets 随朝向返回正确两格偏移（anchor 恒为自身 cell，读自身 orientation）。
func _test_A03_get_occupied_offsets_four_orientations() -> void:
	const NAME: String = "A03_get_occupied_offsets四朝向"
	var m: Variant = _DoubleCellMirror.new()
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.BOTTOM)
	_check(NAME, m.get_occupied_offsets() == [Vector2i.ZERO, Vector2i(1, 0)], "BOTTOM 期望 [ZERO,(1,0)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.RIGHT)
	_check(NAME, m.get_occupied_offsets() == [Vector2i.ZERO, Vector2i(0, 1)], "RIGHT 期望 [ZERO,(0,1)]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.TOP)
	_check(NAME, m.get_occupied_offsets() == [Vector2i(-1, 0), Vector2i.ZERO], "TOP 期望 [(-1,0),ZERO]，实际 %s。" % [m.get_occupied_offsets()])
	m.set_orientation(_DoubleCellMirror.MirrorOrientation.LEFT)
	_check(NAME, m.get_occupied_offsets() == [Vector2i(0, -1), Vector2i.ZERO], "LEFT 期望 [(0,-1),ZERO]，实际 %s。" % [m.get_occupied_offsets()])
	m.free()


## A04. 声明 RAY + PARTICLE 两形态（对齐单格镜）。
func _test_A04_get_light_interaction_forms() -> void:
	const NAME: String = "A04_声明RAY与PARTICLE"
	var m: Variant = _DoubleCellMirror.new()
	var forms: Array = m.get_light_interaction_forms()
	_check(NAME, &"RAY" in forms and &"PARTICLE" in forms, "应声明 RAY 与 PARTICLE，实际 %s。" % [forms])
	m.free()


# ===== C 判定（48 条速查表） =====

## C01. 规则文档 §8 四朝向 × 12 条速查表全部映射正确。
## 数据驱动：每例 [朝向, 入格偏移(相对 anchor), 入射方向, 期望 outcome, 期望反射方向, 期望穿邻方向]。
func _test_C01_quicktable_48_cases() -> void:
	const NAME: String = "C01_四朝向48条速查表"
	var cases: Array = []

	# ---- BOTTOM（anchor=(x,y), second=(x+1,y), tangent=(1,0), normal=(0,-1)） ----
	var b: int = _DoubleCellMirror.MirrorOrientation.BOTTOM
	var b_second: Vector2i = Vector2i(1, 0)
	cases.append([b, Vector2i.ZERO, Vector2i(0, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # B1 折回
	cases.append([b, Vector2i.ZERO, Vector2i(0, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # B2 背面
	cases.append([b, Vector2i.ZERO, Vector2i(1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # B3 平行
	cases.append([b, Vector2i.ZERO, Vector2i(-1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B4 平行
	cases.append([b, Vector2i.ZERO, Vector2i(1, 1), OUT_CROSS, Vector2i(1, -1), Vector2i(1, 0)])    # B5 中心反射↗
	cases.append([b, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B6 左端点
	cases.append([b, b_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # B7 右端点
	cases.append([b, b_second, Vector2i(-1, 1), OUT_CROSS, Vector2i(-1, -1), Vector2i(-1, 0)])      # B8 中心反射↖
	cases.append([b, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # B9 左端点
	cases.append([b, Vector2i.ZERO, Vector2i(-1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])     # B10 背面
	cases.append([b, b_second, Vector2i(1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # B11 背面
	cases.append([b, b_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # B12 右端点

	# ---- RIGHT（anchor=(x,y), second=(x,y+1), tangent=(0,1), normal=(-1,0)） ----
	var r: int = _DoubleCellMirror.MirrorOrientation.RIGHT
	var r_second: Vector2i = Vector2i(0, 1)
	cases.append([r, Vector2i.ZERO, Vector2i(1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # R1 折回
	cases.append([r, Vector2i.ZERO, Vector2i(-1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # R2 背面
	cases.append([r, Vector2i.ZERO, Vector2i(0, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R3 平行
	cases.append([r, Vector2i.ZERO, Vector2i(0, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # R4 平行
	cases.append([r, Vector2i.ZERO, Vector2i(1, 1), OUT_CROSS, Vector2i(-1, 1), Vector2i(0, 1)])    # R5 中心反射↙
	cases.append([r, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R6 上端点
	cases.append([r, r_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # R7 下端点
	cases.append([r, r_second, Vector2i(1, -1), OUT_CROSS, Vector2i(-1, -1), Vector2i(0, -1)])      # R8 中心反射↖
	cases.append([r, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # R9 上端点
	cases.append([r, Vector2i.ZERO, Vector2i(-1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])     # R10 背面
	cases.append([r, r_second, Vector2i(-1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # R11 背面
	cases.append([r, r_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # R12 下端点

	# ---- TOP（anchor=(x,y), second=(x-1,y), tangent=(-1,0), normal=(0,1)） ----
	var t: int = _DoubleCellMirror.MirrorOrientation.TOP
	var t_second: Vector2i = Vector2i(-1, 0)
	cases.append([t, Vector2i.ZERO, Vector2i(0, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # T1 折回
	cases.append([t, Vector2i.ZERO, Vector2i(0, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # T2 背面
	cases.append([t, Vector2i.ZERO, Vector2i(1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # T3 平行
	cases.append([t, Vector2i.ZERO, Vector2i(-1, 0), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T4 平行
	cases.append([t, t_second, Vector2i(1, -1), OUT_CROSS, Vector2i(1, 1), Vector2i(1, 0)])         # T5 中心反射↘
	cases.append([t, t_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # T6 左端点
	cases.append([t, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T7 右端点
	cases.append([t, Vector2i.ZERO, Vector2i(-1, -1), OUT_CROSS, Vector2i(-1, 1), Vector2i(-1, 0)]) # T8 中心反射↙
	cases.append([t, t_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # T9 左端点
	cases.append([t, t_second, Vector2i(-1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # T10 背面
	cases.append([t, Vector2i.ZERO, Vector2i(1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # T11 背面
	cases.append([t, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # T12 右端点

	# ---- LEFT（anchor=(x,y), second=(x,y-1), tangent=(0,-1), normal=(1,0)） ----
	var l: int = _DoubleCellMirror.MirrorOrientation.LEFT
	var l_second: Vector2i = Vector2i(0, -1)
	cases.append([l, Vector2i.ZERO, Vector2i(-1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])      # L1 折回
	cases.append([l, Vector2i.ZERO, Vector2i(1, 0), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # L2 背面
	cases.append([l, Vector2i.ZERO, Vector2i(0, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L3 平行
	cases.append([l, Vector2i.ZERO, Vector2i(0, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])    # L4 平行
	cases.append([l, Vector2i.ZERO, Vector2i(-1, -1), OUT_CROSS, Vector2i(1, -1), Vector2i(0, -1)]) # L5 中心反射↗
	cases.append([l, Vector2i.ZERO, Vector2i(-1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L6 下端点
	cases.append([l, l_second, Vector2i(-1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])       # L7 上端点
	cases.append([l, l_second, Vector2i(-1, 1), OUT_CROSS, Vector2i(1, 1), Vector2i(0, 1)])         # L8 中心反射↘
	cases.append([l, l_second, Vector2i(1, 1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])         # L9 上端点
	cases.append([l, Vector2i.ZERO, Vector2i(1, 1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])       # L10 背面
	cases.append([l, l_second, Vector2i(1, -1), OUT_BLOCK, Vector2i.ZERO, Vector2i.ZERO])           # L11 背面
	cases.append([l, Vector2i.ZERO, Vector2i(1, -1), OUT_CONTINUE, Vector2i.ZERO, Vector2i.ZERO])   # L12 下端点

	for c: Array in cases:
		var res = _DoubleCellMirror.resolve_interaction(c[0], c[1], c[2])
		var ok: bool = res.outcome == c[3]
		if res.outcome == OUT_CROSS:
			ok = ok and res.reflect_direction == c[4] and res.cross_direction == c[5]
		_check(NAME, ok,
			"用例：orientation=%d offset=%s dir=%s => outcome=%d reflect=%s cross=%s（期望 outcome=%d reflect=%s cross=%s）"
			% [c[0], c[1], c[2], res.outcome, res.reflect_direction, res.cross_direction, c[3], c[4], c[5]])


# ===== 断言与报告 =====

## 单项断言：累计计数，失败时追加"[组名] 原因"到失败列表。
func _check(name: String, ok: bool, detail: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [name, detail])
	return ok


## 输出测试摘要。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== DoubleCellMirror 判定逻辑回归测试摘要 ====")
	print("测试组数：5")
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
