@tool
class_name ColorCrystal
extends "res://gameplay/crystals/basic_crystal.gd"

## 光颜色水晶（阶段B / 机关规则 光颜色水晶 v0.1）：单一正式 authoring 项"光颜色水晶"的场景根脚本。
## 职责：在 BasicCrystal 之上只增加一个作者颜色事实 crystal_color（RayColor.ColorValue 值，
## 仅红/绿/蓝，默认红），并按颜色切换 ObjectVisualView 的视觉 profile；点亮/重置/目标条件/
## 命中事实全部沿用 BasicCrystal 与既有 objective 链，不另造枚举或兼容层。
## 颜色是作者期事实：Inspector 枚举下拉（默认红）或 Content Palette"切换颜色"入口修改，
## 随场景保存序列化；运行期只读（get_crystal_color），不参与光线传播或条件判定本身。
## 位置契约 / 稳定 ID：与 BasicCrystal 完全一致（position 唯一位置事实；stable_instance_id 与
## crystal_id 同源写入）。场景根脚本独立于 basic_crystal.gd，保证 resolve_content_type_id
## 按脚本路径解析为 color_crystal 类型，不与基础水晶归并。


# 颜色域唯一来源（preload 引用以避开全局 class_name 缓存问题）。
const _RayColor: GDScript = preload("res://gameplay/light/ray_color.gd")


## 颜色 → 视觉 profile（红/绿/蓝各一套 unlit/lit 双状态；纹理资产已就绪）。
const COLOR_PROFILES: Dictionary = {
	_RayColor.ColorValue.RED: preload("res://assets/visual_profiles/red_crystal_visuals.tres"),
	_RayColor.ColorValue.GREEN: preload("res://assets/visual_profiles/green_crystal_visuals.tres"),
	_RayColor.ColorValue.BLUE: preload("res://assets/visual_profiles/blue_crystal_visuals.tres"),
}


## 光颜色水晶颜色（RayColor.ColorValue 值：红=1/绿=2/蓝=3；默认红）。
## [br]作者期经 Inspector 枚举下拉或 Palette"切换颜色"修改；越界值拒绝并大声报告（不静默钳制）。
@export_enum("红 RED:1", "绿 GREEN:2", "蓝 BLUE:3") var crystal_color: int = _RayColor.ColorValue.RED:
	set(next_color):
		if not COLOR_PROFILES.has(next_color):
			push_error("ColorCrystal: 非法颜色值 %d（仅红/绿/蓝），保持 %d。" % [next_color, crystal_color])
			return
		crystal_color = next_color
		_apply_color_profile()


## 初始化：先走 BasicCrystal 视觉初始化，再按当前颜色应用 profile（编辑器与运行期同一入口）。
func _ready() -> void:
	super()
	_apply_color_profile()


## 读取颜色（RayColor.ColorValue 值；供编辑器工具与运行期只读 API / 测试调用）。
func get_crystal_color() -> int:
	return crystal_color


## 作者入口：循环切换颜色 红→绿→蓝→红（Content Palette"切换颜色"按钮调用，配合撤销事务）。
func cycle_color() -> void:
	var colors: Array = COLOR_PROFILES.keys()
	colors.sort()
	var next_color: int = colors[0]
	for color_value: int in colors:
		if color_value > crystal_color:
			next_color = color_value
			break
	crystal_color = next_color


## 按当前颜色切换视觉 profile 并重放点亮状态（profile 切换后状态显示按新 profile 重建）。
## [br]边界条件：setter 早于 _ready（Inspector 在节点入树前改值）时 _visual 尚未缓存，
## 只保留字段值，_ready 后统一应用（与 ObjectVisualView 的早到 setter 约定一致）。
func _apply_color_profile() -> void:
	if _visual == null:
		return
	var profile: Variant = COLOR_PROFILES.get(crystal_color)
	if profile == null:
		return
	_visual.set_profile(profile)
	_apply_state()
