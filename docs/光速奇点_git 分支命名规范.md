# 《光速奇点》Git 分支命名规范



> 适用项目：光速奇点  

> 适用成员：陈俊贤、潘陈俣、张梓涵  

> 当前仓库：`light-speed-singularity`



---



## 1. 分支管理原则



本项目采用轻量化分支管理方式：



```text

main

└── 各成员的短期任务分支

```



### 1.1 长期分支



| 分支 | 用途 |

|---|---|

| `main` | 稳定主分支，只保存已经完成测试、审查并确认可以运行的代码 |



### 1.2 不再使用的长期分支



以下分支暂时不使用：



```text

dev

develop

release

```



三人小团队现阶段不需要维护复杂的多层长期分支。



---



## 2. 统一命名格式



所有任务分支统一使用：



```text

<分支类型>/<成员标识>-<任务名称>

```



示例：



```text

feat/kud-grid-service

feat/pan-light-splitter

content/zhang-level-03

```



---



## 3. 成员身份标识



| 姓名 | 主要职责 | 分支身份标识 |

|---|---|---|

| 陈俊贤 | 技术负责人、核心系统、工程管理 | `kud` |

| 潘陈俣 | 玩法系统、机关逻辑、光传播 | `pan` |

| 张梓涵 | 关卡、内容、美术配置、科学家宣传内容 | `zhang` |



### 3.1 身份标识使用示例



陈俊贤：



```text

feat/kud-grid-service

```



潘陈俣：



```text

feat/pan-light-splitter

```



张梓涵：



```text

content/zhang-level-03

```



---



## 4. 分支类型前缀



| 前缀 | 使用场景 | 示例 |

|---|---|---|

| `feat/` | 新功能、新系统、新玩法 | `feat/kud-save-system` |

| `fix/` | 修复错误 | `fix/pan-light-collision` |

| `content/` | 关卡、文案、美术资源、配置内容 | `content/zhang-level-04` |

| `docs/` | 文档 | `docs/zhang-level-design` |

| `test/` | 测试场景、测试脚本、调试工具 | `test/kud-grid-debug-view` |

| `chore/` | 工程整理、目录调整、配置修改 | `chore/kud-project-structure` |

| `refactor/` | 不改变功能的代码重构 | `refactor/kud-core-architecture` |

| `build/` | 构建、导出、发布配置 | `build/kud-windows-export` |



---



## 5. 命名书写标准



### 5.1 必须遵守



- 全部使用英文小写。

- 单词之间使用短横线 `-`。

- 不使用空格。

- 不使用中文。

- 不使用下划线 `_`。

- 每个分支只处理一个明确任务。

- 任务名称必须能看出功能内容。

- 每个成员必须带自己的身份标识。



正确示例：



```text

feat/kud-level-loader

feat/pan-emitter-direction

content/zhang-level-02

```



错误示例：



```text

Feature/Kud_Grid

feat/新网格系统

my-branch

feat/all-functions

feat/game-update

```



### 5.2 避免过于模糊的名称



不推荐：



```text

feat/kud-update

feat/pan-new-feature

content/zhang-change

fix/pan-bug

```



推荐：



```text

feat/kud-level-loader

feat/pan-particle-propagation

content/zhang-achievement-icons

fix/pan-light-split-direction

```



---



# 6. 陈俊贤分支命名



## 6.1 职责范围



陈俊贤主要负责：



- 核心技术底座；

- 网格与坐标系统；

- 关卡加载与流程；

- 存档与设置；

- 成就系统框架；

- 公共接口；

- 工程配置；

- 测试与构建。



陈俊贤不需要亲自完成所有机关的具体玩法逻辑。



---



## 6.2 项目基础与公共系统



| 模块 | 推荐分支名 |

|---|---|

| 项目目录整理 | `chore/kud-project-structure` |

| 公共类型定义 | `feat/kud-common-types` |

| 玩法公共接口 | `feat/kud-gameplay-interfaces` |

| 全局事件系统 | `feat/kud-event-system` |

| 配置数据系统 | `feat/kud-config-data` |

| 输入映射整理 | `chore/kud-input-map` |



---



## 6.3 网格与坐标系统



| 模块 | 推荐分支名 |

|---|---|

| 网格坐标转换 | `feat/kud-grid-coordinates` |

| 网格数据服务 | `feat/kud-grid-service` |

| 格子占用管理 | `feat/kud-grid-occupancy` |

| 网格占用修复 | `fix/kud-grid-occupancy` |

| 网格调试显示 | `test/kud-grid-debug-view` |



---



## 6.4 关卡流程系统



| 模块 | 推荐分支名 |

|---|---|

| 关卡加载 | `feat/kud-level-loader` |

| 关卡重置 | `feat/kud-level-reset` |

| 关卡切换 | `feat/kud-level-transition` |

| 关卡数据格式 | `feat/kud-level-data` |

| 关卡选择基础 | `feat/kud-level-selection` |

| 通关进度管理 | `feat/kud-level-progress` |



---



## 6.5 存档与设置



| 模块 | 推荐分支名 |

|---|---|

| 存档基础系统 | `feat/kud-save-system` |

| 关卡进度存档 | `feat/kud-progress-save` |

| 设置存档 | `feat/kud-settings-save` |

| 存档恢复 | `fix/kud-save-recovery` |



---



## 6.6 成就系统技术框架



| 模块 | 推荐分支名 |

|---|---|

| 成就框架 | `feat/kud-achievement-framework` |

| 成就存档 | `feat/kud-achievement-save` |

| 成就弹窗 | `feat/kud-achievement-popup` |

| 成就展示界面框架 | `feat/kud-achievement-gallery` |



---



## 6.7 构建、测试与重构



| 模块 | 推荐分支名 |

|---|---|

| Windows 导出 | `build/kud-windows-export` |

| 核心测试套件 | `test/kud-core-test-suite` |

| 性能调试工具 | `test/kud-performance-debug` |

| 核心架构重构 | `refactor/kud-core-architecture` |



---



# 7. 潘陈俣分支命名



## 7.1 职责范围



潘陈俣主要负责：



- 发射源；

- 光线与光粒传播；

- 玩家放置与编辑机关；

- 镜子、分光器、滤光片等机关；

- 水晶与目标检测；

- 玩法成就触发；

- 玩法测试。



---



## 7.2 发射源系统



| 模块 | 推荐分支名 |

|---|---|

| 发射源方向控制 | `feat/pan-emitter-direction` |

| 发射功能 | `feat/pan-emitter-fire` |

| 发射源状态显示 | `feat/pan-emitter-visual-state` |

| 光形式切换 | `feat/pan-light-mode-switch` |

| 发射源系统整合 | `feat/pan-emitter-system` |



---



## 7.3 光传播系统



| 模块 | 推荐分支名 |

|---|---|

| 瞬时光线传播 | `feat/pan-ray-propagation` |

| 光粒移动 | `feat/pan-particle-propagation` |

| 光传播碰撞 | `feat/pan-light-collision` |

| 光传播终止规则 | `feat/pan-light-termination` |

| 光路径调试 | `test/pan-light-path-debug` |

| 光传播系统整合 | `feat/pan-light-propagation-system` |



---



## 7.4 玩家放置与编辑系统



| 模块 | 推荐分支名 |

|---|---|

| 机关选择 | `feat/pan-device-selection` |

| 机关放置 | `feat/pan-device-placement` |

| 机关旋转 | `feat/pan-device-rotation` |

| 机关移除 | `feat/pan-device-removal` |

| 放置合法性反馈 | `feat/pan-placement-feedback` |

| 放置系统整合 | `feat/pan-placement-system` |



---



## 7.5 转向机关



| 模块 | 推荐分支名 |

|---|---|

| 45度斜面镜 | `feat/pan-diagonal-mirror` |

| 两格平面镜 | `feat/pan-plane-mirror` |

| 镜子系统整合 | `feat/pan-mirror-system` |



---



## 7.6 速度机关



| 模块 | 推荐分支名 |

|---|---|

| 加速机关 | `feat/pan-particle-accelerator` |

| 减速机关 | `feat/pan-particle-decelerator` |

| 速度机关整合 | `feat/pan-speed-modifier-system` |



---



## 7.7 墙体交互



| 模块 | 推荐分支名 |

|---|---|

| 普通阻挡墙 | `feat/pan-solid-wall` |

| 光粒可穿透墙 | `feat/pan-particle-pass-wall` |

| 光与墙体交互规则 | `feat/pan-light-wall-rules` |



---



## 7.8 分光、光强与颜色



| 模块 | 推荐分支名 |

|---|---|

| 分光器 | `feat/pan-light-splitter` |

| 光强处理 | `feat/pan-light-intensity` |

| 单色滤光片 | `feat/pan-color-filter` |

| 光颜色混合 | `feat/pan-light-color-mixing` |

| 光属性系统 | `feat/pan-light-properties` |



---



## 7.9 水晶与通关目标



| 模块 | 推荐分支名 |

|---|---|

| 基础水晶 | `feat/pan-basic-crystal` |

| 颜色水晶 | `feat/pan-color-crystal` |

| 光强检测器 | `feat/pan-intensity-detector` |

| 多目标检测 | `feat/pan-multi-target-check` |

| 胜利判定 | `feat/pan-victory-condition` |

| 目标系统整合 | `feat/pan-level-objectives` |



---



## 7.10 玩法成就触发



| 模块 | 推荐分支名 |

|---|---|

| 首次通关触发 | `feat/pan-achievement-first-clear` |

| 特殊解法触发 | `feat/pan-achievement-solution-triggers` |

| 光学行为触发 | `feat/pan-achievement-light-triggers` |

| 成就触发整合 | `feat/pan-achievement-triggers` |



---



# 8. 张梓涵分支命名



## 8.1 职责范围



张梓涵主要负责：



- 关卡地图；

- 教学顺序；

- 难度曲线；

- 关卡提示；

- 美术资源整理；

- UI内容；

- 成就文案与图标；

- 科学家宣传资料；

- 内容来源记录。



---



## 8.2 关卡模板与基础地图



| 模块 | 推荐分支名 |

|---|---|

| 关卡模板 | `content/zhang-level-template` |

| TileMap基础地图 | `content/zhang-tilemap-base` |

| 教学测试关 | `content/zhang-tutorial-level` |

| 关卡布局规范 | `docs/zhang-level-guidelines` |



---



## 8.3 正式关卡



正式关卡推荐每关一个独立分支：



```text

content/zhang-level-01

content/zhang-level-02

content/zhang-level-03

content/zhang-level-04

content/zhang-level-05

content/zhang-level-06

content/zhang-level-07

content/zhang-level-08

content/zhang-level-09

content/zhang-level-10

```



每个关卡分支只包含该关相关内容：



- 地图布局；

- 默认机关；

- 可用机关；

- 水晶与目标位置；

- 教学文字；

- 关卡名称；

- 关卡说明；

- 关卡测试调整。



不推荐：



```text

content/zhang-all-levels

```



---



## 8.4 教学与难度



| 模块 | 推荐分支名 |

|---|---|

| 教学顺序设计 | `content/zhang-tutorial-sequence` |

| 关卡难度曲线 | `content/zhang-difficulty-curve` |

| 关卡提示文本 | `content/zhang-level-hints` |

| 关卡平衡调整 | `content/zhang-level-balance` |

| 关卡设计文档 | `docs/zhang-level-design` |



---



## 8.5 美术与视觉内容



| 模块 | 推荐分支名 |

|---|---|

| 美术资源整理 | `content/zhang-art-assets` |

| TileSet视觉配置 | `content/zhang-tileset-visuals` |

| 机关图标 | `content/zhang-device-icons` |

| 水晶视觉状态 | `content/zhang-crystal-visuals` |

| 像素风统一 | `content/zhang-pixel-art-style` |

| 素材来源与许可证 | `docs/zhang-asset-credits` |



---



## 8.6 UI与文字内容



| 模块 | 推荐分支名 |

|---|---|

| 主界面设计 | `content/zhang-main-menu-design` |

| 主界面UI场景 | `feat/zhang-main-menu-ui` |

| 游戏内提示文字 | `content/zhang-ui-copy` |

| 关卡选择界面内容 | `content/zhang-level-selection-content` |

| 制作人员页面 | `content/zhang-credits-content` |



---



## 8.7 科学家宣传与成就内容



| 模块 | 推荐分支名 |

|---|---|

| 成就内容规划 | `content/zhang-achievement-content` |

| 科学家资料 | `content/zhang-scientist-profiles` |

| 成就图标 | `content/zhang-achievement-icons` |

| 科学精神文案 | `content/zhang-scientist-copy` |

| 成就展示页内容 | `content/zhang-achievement-gallery` |

| 科学家资料来源 | `docs/zhang-scientist-sources` |



---



# 9. 三人协作示例



## 9.1 成就系统



```text

feat/kud-achievement-framework

feat/pan-achievement-triggers

content/zhang-achievement-content

```



| 成员 | 负责内容 |

|---|---|

| 陈俊贤 | 成就数据、存档、弹窗和展示框架 |

| 潘陈俣 | 在玩法中判断何时解锁成就 |

| 张梓涵 | 成就名称、图标、文案和科学家内容 |



---



## 9.2 正式关卡



```text

feat/kud-level-loader

feat/pan-level-objectives

content/zhang-level-03

```



| 成员 | 负责内容 |

|---|---|

| 陈俊贤 | 关卡加载、重置和切换 |

| 潘陈俣 | 水晶、检测器和胜利判定 |

| 张梓涵 | 第三关地图、机关位置和提示文字 |



---



## 9.3 分光器



```text

feat/kud-gameplay-interfaces

feat/pan-light-splitter

content/zhang-device-icons

```



| 成员 | 负责内容 |

|---|---|

| 陈俊贤 | 提供统一的机关输入输出接口 |

| 潘陈俣 | 实现分光方向和光强计算 |

| 张梓涵 | 制作分光器图标和关卡中的视觉配置 |



---



# 10. 当前分支重命名



当前旧分支：



```text

feat/prototype-light-loop

```



陈俊贤的身份标识为 `kud`，因此应改为：



```text

feat/kud-prototype-light-loop

```



本地重命名并推送：



```bash

git branch -m feat/kud-prototype-light-loop

git push -u origin feat/kud-prototype-light-loop

git push origin --delete feat/prototype-light-loop

```



如果已经创建 Pull Request，优先在 GitHub 网页的分支页面中重命名，再同步本地分支。



---



# 11. 创建新分支的标准流程



所有成员都必须先同步最新的 `main`：



```bash

git switch main

git pull origin main

```



然后创建自己的任务分支。



陈俊贤示例：



```bash

git switch -c feat/kud-grid-service

```



潘陈俣示例：



```bash

git switch -c feat/pan-emitter-direction

```



张梓涵示例：



```bash

git switch -c content/zhang-level-template

```



---



# 12. 提交与合并标准



## 12.1 开发前



1. 确认任务归属。

2. 确认分支名称。

3. 从最新 `main` 创建分支。

4. 不从其他成员未合并的功能分支创建新分支。



## 12.2 开发中



1. 每个分支只完成一个明确任务。

2. 不顺手修改无关模块。

3. 需要修改别人负责的公共接口时，先沟通。

4. 保持每次提交内容集中。

5. 最终代码的每个模块和函数应有对应的中文注释。

6. 注释应说明职责、输入输出、关键副作用或边界条件。

7. 避免无意义的逐行复述式注释。



## 12.3 合并前



必须完成：



- 功能测试；

- 人工检查；

- 代码审查；

- 确认无明显报错；

- 确认未提交临时文件；

- 确认没有误改其他模块。



## 12.4 合并后



1. 删除已完成的任务分支。

2. 切回 `main`。

3. 拉取最新代码。

4. 再创建下一个任务分支。



示例：



```bash

git switch main

git pull origin main

git branch -d feat/kud-grid-service

```



远程分支未自动删除时：



```bash

git push origin --delete feat/kud-grid-service

```



---



# 13. 推荐的下一批分支



第一阶段原型完成并合并后，推荐三人分别创建：



陈俊贤：



```text

feat/kud-grid-service

```



潘陈俣：



```text

feat/pan-emitter-direction

```



张梓涵：



```text

content/zhang-level-template

```



三个人都从最新的 `main` 创建，不要从彼此尚未完成的分支创建。



---



# 14. 核心分工总结



> 陈俊贤搭建核心技术底座，潘陈俣实现玩法和机关逻辑，张梓涵制作关卡、视觉和科学家宣传内容。



> 每个分支必须带成员身份标识，每个分支只处理一个可以独立测试、审查和合并的任务。
