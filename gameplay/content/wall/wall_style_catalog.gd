@tool
extends RefCounted

## D-04 正式墙体内容：12 种官方 64×64 墙样式目录（视觉与样式 token 唯一事实来源）。
## 职责：冻结 12 样式的 token 序（四直墙 → 四外角 → 四内角）、中文标签与贴图路径；
##   提供 token ↔ 枚举序互查，供墙节点（wall_block / wall_structure）选贴图、
##   编辑器包裹规划（map_layer_service.resolve_boundary_style）产出 token 对接。
## 边界：不持节点、不加载纹理实例（调用方 load()）、不做合法性判定、不写场景；
##   墙体贴图语义沿用 D-03 冻结口径：straight_up=上边横条、large_bend_lu=左上两直边（外角）、
##   small_bend_tl=左上小角饰（内角）；样式仅视觉，所有墙格一律整格阻挡。
## 类型约束：调用方一律通过 preload() 引用，避开全局 class_name 缓存问题。


## 样式 token 序（冻结：与 Inspector 墙体样式枚举值序一致，四直 → 四外角 → 四内角）。
const STYLE_ORDER: Array[String] = [
	"straight_up", "straight_down", "straight_left", "straight_right",
	"large_bend_lu", "large_bend_ru", "large_bend_ld", "large_bend_rd",
	"small_bend_tl", "small_bend_tr", "small_bend_bl", "small_bend_br",
]

## token → 中文标签（Inspector 与日志显示用）。
const STYLE_LABELS: Dictionary = {
	"straight_up": "直墙·上",
	"straight_down": "直墙·下",
	"straight_left": "直墙·左",
	"straight_right": "直墙·右",
	"large_bend_lu": "外角·左上",
	"large_bend_ru": "外角·右上",
	"large_bend_ld": "外角·左下",
	"large_bend_rd": "外角·右下",
	"small_bend_tl": "内角·左上",
	"small_bend_tr": "内角·右上",
	"small_bend_bl": "内角·左下",
	"small_bend_br": "内角·右下",
}

## token → 64×64 贴图路径（assets/art/wall 冻结素材，与 D-03 图标同源）。
const STYLE_TEXTURE_PATHS: Dictionary = {
	"straight_up": "res://assets/art/wall/straight/wall_straight_up.png",
	"straight_down": "res://assets/art/wall/straight/wall_straight_down.png",
	"straight_left": "res://assets/art/wall/straight/wall_straight_left.png",
	"straight_right": "res://assets/art/wall/straight/wall_straight_right.png",
	"large_bend_lu": "res://assets/art/wall/large_bend/wall_large_bend_lu.png",
	"large_bend_ru": "res://assets/art/wall/large_bend/wall_large_bend_ru.png",
	"large_bend_ld": "res://assets/art/wall/large_bend/wall_large_bend_ld.png",
	"large_bend_rd": "res://assets/art/wall/large_bend/wall_large_bend_rd.png",
	"small_bend_tl": "res://assets/art/wall/small_bend/wall_bend_two.png",
	"small_bend_tr": "res://assets/art/wall/small_bend/wall_bend_three.png",
	"small_bend_bl": "res://assets/art/wall/small_bend/wall_bend_four.png",
	"small_bend_br": "res://assets/art/wall/small_bend/wall_bend_one.png",
}


## 枚举序（int）→ 样式 token；越界返回空串（调用方自行校验）。
static func token_at(style_index: int) -> String:
	if style_index < 0 or style_index >= STYLE_ORDER.size():
		return ""
	return STYLE_ORDER[style_index]


## 样式 token → 枚举序（int）；未登记返回 -1。
static func index_of(token: String) -> int:
	return STYLE_ORDER.find(token)


## 枚举序 → 贴图路径；越界返回空串。
static func texture_path_at(style_index: int) -> String:
	return STYLE_TEXTURE_PATHS.get(token_at(style_index), "")


## 扫描关卡树内全部正式墙体对象（get_wall_cells 契约节点）并汇总其绝对占格（逐项展开，可能重复）。
## [br]递归全树（与编辑期正式对象发现同口径）；非墙体对象静默跳过。
## [br]运行期墙格快照合并（LevelTileLayerSnapshot extra_wall_cells）唯一采集入口；
## 自包含递归不反向依赖编辑器插件层。
static func collect_wall_cells(node: Node) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if node == null:
		return cells
	if node.has_method("get_wall_cells"):
		cells.append_array(node.call("get_wall_cells"))
	for child: Node in node.get_children():
		cells.append_array(collect_wall_cells(child))
	return cells
