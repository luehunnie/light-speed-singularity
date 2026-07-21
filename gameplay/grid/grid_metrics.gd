extends RefCounted

## 世界网格尺寸共享常量模块（CELL_SIZE_64_MIGRATION_PLAN.md §6.2）。
## 职责：集中保存世界逻辑格边长、半格偏移和单格世界机关默认占位尺寸三组最小常量，
## 供关卡控制器和世界机关视觉脚本通过 preload() 读取，避免 64 世界格尺寸分散手写形成新的技术债。
## 位置：位于 gameplay/grid 下，是 32→64 世界坐标迁移后唯一的"世界单格尺寸"事实来源；
## 后续张梓涵制作的 64×64 正式美术素材应以本模块的 SINGLE_CELL_WORLD_SIZE 作为 1:1 替换基准。
## 依赖：不 preload 任何游戏脚本，不引用 CoreLoopPrototype、PlaceableToken、SingleCellMirror 或 OccupancyRegistry，
## 因此不会形成循环依赖；其他脚本只单向 preload 本模块。
## 不负责：关卡数据、动态状态、坐标转换服务、场景树读取、Autoload、UI 尺寸或机关占用规则。
## 边界条件：本模块只保存静态配置常量，不做任何运行期计算；UI 图标尺寸必须和世界单格尺寸分离，
## 集中常量可防止误把机关栏 TokenIcon 等 UI 尺寸改成 64。本模块不加 class_name，使用方一律用 preload() 引用，
## 以避免 Godot MCP 运行期未重建全局 class 缓存导致的类型解析问题。


## 世界逻辑格边长，单位为 Godot 世界像素。
## 2026-07-21 起团队正式决定一个逻辑格统一为 64×64 世界像素，不再评估继续使用 32×32。
## 修改本常量会同时影响 cell_to_world() / world_to_cell() 的格中心间距与半格偏移。
const CELL_SIZE: int = 64

## 世界逻辑格半边长，用于格中心和以中心为锚点的占位视觉。
## CELL_SIZE=64 时半格为 32，即 cell_to_world(Vector2i.ZERO) == Vector2(32, 32)。
const HALF_CELL_SIZE: float = CELL_SIZE / 2.0

## 单格世界机关默认占位尺寸。正式 64×64 素材可 1:1 替换该尺寸。
## 本常量只描述世界空间单格机关视觉尺寸，不等于 CanvasLayer 机关栏 UI 图标尺寸。
const SINGLE_CELL_WORLD_SIZE: Vector2 = Vector2(CELL_SIZE, CELL_SIZE)
