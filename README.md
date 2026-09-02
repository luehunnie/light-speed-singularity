# 光速奇点 / Light Speed Singularity

> Light Speed Singularity is a grid-based optics puzzle game built with Godot 4.6, currently in development.

《光速奇点》是一款使用 Godot 4.6 开发的固定网格光学解谜游戏（开发中）。

玩家不能移动角色，也不能自由移动关卡中的主发射器。每个关卡预先限定可用机关的种类、数量、可放置区域、运行期移动次数和目标；玩家从画面下方的机关栏拿取机关，在网格上放置、移动、回收并配置，然后发射光线或光粒完成目标。

游戏包含两种光形态，可用 `Q` 键切换：

- **光线（RAY）**：按当前稳定布局同步计算完整路径，路径显示约 1 秒后消失；
- **光粒（PARTICLE）**：作为持续存在的逻辑实体，按整数 Tick 逐格移动。

## 当前状态

- 项目**开发中**，暂无可玩发布版；
- 默认主场景为 `levels/prototypes/core_loop_prototype.tscn`（核心循环原型关卡）；
- 玩法规则冻结稿见[《玩法设计》](docs/光速奇点_玩法设计_v1.0.md)，实现状态以真实代码与测试为准。

## 已实现能力（保守摘要）

- 光线/光粒双形态与统一发射入口（`Space` 发射、`Q` 切换形态、`R` 重置）；
- 五状态运行时（SETUP → READY_TO_FIRE → PULSE_ACTIVE → MOVE_WINDOW → COMPLETED）与开始运行门；
- 镜面、光屏障、光形式转换等机关与水晶目标判定；
- 机关的放置、移动（含运行期移动次数）、回收与库存管理；
- 关卡校验（Validator）与核心循环端到端集成测试；
- 面向关卡、界面与外观作者的编辑器插件（见下）。

## 环境要求

- [Godot](https://godotengine.org) **4.6.1**（项目以 Godot 4.6 特性集创建）。

## 克隆与运行

1. 克隆本仓库；
2. 用 Godot 4.6.1 打开根目录下的 `project.godot`，等待资源导入完成；
3. 按 `F5`（或编辑器右上角「运行项目」）运行，默认主场景为 `levels/prototypes/core_loop_prototype.tscn`。

## 关卡作者插件

以下编辑器插件位于 `addons/`，已在 `project.godot` 中启用，可在 Godot 编辑器「项目 → 项目设置 → 插件」中管理：

| 插件 | 用途 |
|---|---|
| [`light_speed_level_authoring`](addons/light_speed_level_authoring/) | 关卡编辑器：Create/Duplicate Level、Content Palette、Map Layer Assist、Placement Preview、Play Current Level |
| [`light_speed_ui_authoring`](addons/light_speed_ui_authoring/) | 界面编辑辅助：Binding Slot 守卫、Preview Data、Viewport Preview、UI Test Matrix |
| [`light_speed_visual_workbench`](addons/light_speed_visual_workbench/) | 外观编辑器：正式视觉资产统一业务入口（导入流程、自动命名、Change Set、Usage Impact、Preflight） |

## 测试

测试为独立的 SceneTree 脚本，位于 `tests/unit/` 与 `tests/integration/`，不接入正式启动链，可逐个运行：

```sh
godot --headless --script tests/unit/<路径>/<测试名>_test.gd
```

每个测试成功以 `quit(0)` 退出、失败以 `quit(1)` 退出（见[《开发规范》](docs/光速奇点_开发规范_v0.9.md)第 9 节）。

## 文档

- [文档索引](docs/README_文档索引.md)（正式文档总入口）
- [玩法设计](docs/光速奇点_玩法设计_v1.0.md)
- [开发规范](docs/光速奇点_开发规范_v0.9.md)
- [美术资源替换与 Godot 关卡编辑指南](docs/guides/光速奇点_美术资源替换与Godot关卡编辑指南_v1.1.md)

## 贡献者

- [luehunnie](https://github.com/luehunnie)
- [youki-creat](https://github.com/youki-creat)
- [qingfengdengying](https://github.com/qingfengdengying)

## 许可证

本仓库暂未添加 LICENSE 文件，许可证待定。
