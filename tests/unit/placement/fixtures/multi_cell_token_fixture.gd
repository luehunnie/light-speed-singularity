@tool
extends PlaceableToken

## C-08 多格 footprint 测试桩：可配置 footprint 的 PlaceableToken 派生机关。
## 覆写 get_occupied_offsets 声明相对锚格偏移（默认双格：锚格 + 右邻格）；默认视觉入口覆写为 no-op，
## 使测试环境（无 VisualView 子树 / 不入场景树）可安全 configure。
## 仅服务 tests/unit/placement 下多格收编 / footprint 事务测试，不进正式内容。


## 相对锚格的占用偏移列表；默认 [ZERO, (1,0)] 双格。
var _footprint_offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 0)]


## 覆写 footprint（测试用例按需构造 L 形 / 单格等形状）。
func set_footprint_offsets(offsets: Array[Vector2i]) -> void:
	_footprint_offsets = offsets


func get_occupied_offsets(_p_orientation: int = 0) -> Array[Vector2i]:
	return _footprint_offsets


func set_drag_preview(_is_preview: bool, _is_valid: bool) -> void:
	pass


func set_drag_preview_visible(_preview_is_visible: bool) -> void:
	pass


func set_placed_visible(_placed_is_visible: bool) -> void:
	pass
