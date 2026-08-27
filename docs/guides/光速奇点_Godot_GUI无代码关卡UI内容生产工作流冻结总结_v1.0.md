# 《光速奇点》Godot GUI 无代码关卡 / UI 内容生产工作流冻结总结 v1.0

> 日期：2026-08-17  
> 适用对象：关卡 / UI 内容制作人员（主要面向张梓涵）  
> 目标：在不要求内容人员写代码的前提下，基于 Godot 原生 2D、Inspector、TileMapLayer、Control、Theme 等编辑能力，配合少量项目级 EditorPlugin / InspectorPlugin / Dock / Overlay，完成正式关卡、地图、美术、UI、Objective、Inventory、控制连接、验证与运行测试。  
> 本文是本轮逐项讨论后的冻结方案。后续实现时应以本文为设计基线，不再回到“大而全自研关卡编辑器”的方向。

---

# 1. 总体结论

本轮关键问题已经讨论到足以冻结 **v1 内容生产工具链** 的程度。

后续不再继续为了细枝末节无限提问。仍未精确冻结的内容（例如某些最终 UI 尺寸、具体按钮文字、具体 Decoration Channel 名称、具体 Viewport 分辨率数字）属于实现期或视觉验收期参数，不影响总体架构。

最终方向：

1. **Godot 原生编辑器是主工作台。**
2. **插件只补 Godot 原生工作流中的项目语义、保护、预览、验证和高频缺口。**
3. **永久取消第二套“大而全 Light Speed Level Tools”式关卡编辑器。**
4. **玩法事实、视觉事实、关卡内容、运行时结构严格分离。**
5. **所有正式内容能力尽量来自统一声明，不允许每个工具维护自己的机关名单 / 条件名单 / 资源名单。**
6. **内容人员面对的是“机制、地图、目标、视觉、文本”等业务概念，而不是底层 Node / Resource / Tile ID / 技术绑定。**
7. **视觉改动不能偷偷改变玩法。**
8. **关卡场景保持纯内容；统一 RuntimeHost 提供运行时控制、HUD、Objective Runtime、Inventory Runtime 等。**
9. **Validator 只有一个规则核心，不允许 Workbench、运行预检、项目检查分别写三套判断。**
10. **所有正式编辑操作尽量可定位、可预览、可撤销、可回滚。**

---

# 2. 工具链总体分层

建议最终实现为以下五个插件 / 工具包，而不是一个巨型插件。

## 2.1 `light_speed_authoring_core` —— 内容生产基础设施

### 职责

这是所有编辑工具共享的底层能力，不承担大型 UI。

负责：

- 正式内容声明 / Formal Content Declaration；
- 机制能力元数据；
- Objective Condition 声明；
- Control Action / Output Event 声明；
- Interaction Profile 声明；
- Level-editable Field 声明；
- Map Theme 语义合同；
- Stable ID 生成与修复；
- 当前关卡正式对象发现；
- 场景 / level_id 发现；
- Shared Placement Query 接口；
- 编辑事务 / UndoRedo 协助；
- Validator Core；
- Usage 查询基础能力。

### 红线

- 不做全项目无差别反射扫描；
- 不制造 Blueprint 式大型元数据框架；
- 不承担内容编辑 UI；
- 不成为运行时玩法逻辑的第二份副本。

---

## 2.2 `light_speed_visual_workbench` —— Visual Asset Workbench

正式视觉资产的统一业务入口。

管理：

- 机关视觉；
- Map Visual Theme；
- Ray / Particle Visual；
- Formal Color Palette；
- Public Feedback Visual Style；
- Global UI Visual Theme；
- 其它正式视觉资源。

原 `addons/light_speed_art_profile/` 已按本方向完成迁移吸收（旧插件删除，有价值的底层 Resource / Resolver 能力并入 Workbench 后端）。禁止恢复“旧 Art Profile 插件 + 新 Workbench”两个互相竞争的正式入口。

---

## 2.3 `light_speed_level_authoring` —— 轻量级关卡内容辅助

不是第二套关卡编辑器。

提供多个小而明确的入口：

- Create New Level；
- Duplicate as New Level；
- Content Palette；
- Map Layer Editing Assist；
- 2D Occupancy / Placement Preview；
- 方向快捷旋转；
- Interaction Profile / Level-editable Fields Inspector 辅助；
- Inventory 小编辑器；
- Objective Condition Inspector + Objective Group 小编辑器；
- Control Connection Inspector + 2D Pick；
- Presentation / Text 模块编辑；
- Play Current Level。

标准地图绘制仍使用 Godot TileMapLayer；标准对象移动仍使用 Godot 2D；对象配置仍尽量使用 Inspector。

---

## 2.4 `light_speed_ui_authoring` —— UI 原生编辑辅助

不做 UI Layout Workbench。

正式入口仍然是 Godot 原生：

- Control；
- Container；
- Anchor；
- Layout；
- Theme。

本工具只补：

- Runtime Binding Slot 标记 / 保护；
- 假数据 Preview Presets；
- Ad-hoc Preview Data；
- Viewport Preview Presets；
- UI Test Matrix；
- 必要节点结构检查；
- 一键 UI 预览。

---

## 2.5 `light_speed_validator` —— Validator 面板

UI 上独立存在，但底层调用统一 Validator Core。

支持：

- Change Set Scope；
- Current Level Scope；
- Project Scope；
- Go To / 定位；
- Safe Auto-fix；
- Fix Preview；
- 结果分级；
- 自动修复事务回滚；
- 问题导航。

---

# 3. 正式内容声明：所有工具共同的数据源

每一种正式机制 / 内容能力只维护一份轻量级可编辑内容声明。

所有 GUI 工具共同消费它。

一个正式机制可声明：

- 显示名称；
- 内容分类；
- PackedScene；
- 是否可预放置；
- 是否可进入 Inventory；
- 全局默认内部状态；
- 全局 Inventory Spawn Interaction Profile；
- 默认 Preplaced Interaction Profile；
- 允许的 Interaction Profiles；
- 允许的方向集合与循环顺序；
- Logical Anchor；
- Rotation Pivot；
- Occupied Shape；
- Level-editable Fields；
- ObjectiveTarget 能力；
- 支持的 Objective Conditions；
- Control Source / Target 能力；
- Output Events；
- Control Actions；
- 视觉维度 / 视觉槽位；
- Required / Optional Visual Slots；
- 视觉方向行为；
- 动画槽位语义；
- 其它编辑能力。

## 原则

- 不允许 Content Palette 自己维护机关列表；
- 不允许 Inventory Editor 再维护一份名单；
- 不允许 Objective Editor 硬编码 Crystal；
- 不允许 Workbench 自己维护另一份视觉对象清单；
- 不允许 Validator 再写一套类型白名单。

**一个声明，多工具消费。**

---

# 4. 正式关卡场景与 Runtime 分离

## 4.1 具体关卡 Scene

只保存关卡内容，重点包括：

- Terrain；
- LegalArea；
- Wall；
- Decoration；
- 固定预放置机制；
- Main Emitter；
- Objective 内容；
- Inventory 配置；
- General Rules；
- Presentation / Text；
- Map Visual Theme 选择；
- 编辑器级辅助元数据。

## 4.2 具体关卡 Scene 不保存

- Runtime Controller；
- HUD；
- Inventory Runtime；
- Objective Runtime；
- 发射 / Reset 控制器；
- 通用诊断 Runtime；
- 通用运行时 UI。

## 4.3 统一 `LevelRuntimeHost`

运行时由统一 Host 负责：

- 加载当前关卡；
- 绑定 Runtime UI；
- 初始化 Inventory；
- 初始化 Objective；
- 运行发射 / Reset；
- 处理完成状态；
- 启动正式运行链。

---

# 5. Create New Level

提供轻量级 `Create New Level` 向导。

内容人员输入少量必要信息，例如：

- 面向人的关卡显示名称；
- Map Visual Theme；
- 初始地图方式 / 基础大小等。

工具自动生成：

- 合法的纯关卡 Scene；
- Terrain；
- LegalArea；
- Wall；
- Decoration；
- 必需 Level Content 模块；
- 隐藏稳定 `level_id`；
- 正式技术文件名；
- 正式保存路径。

## 命名与身份

内容人员不自己决定正式文件技术名。

系统自动管理：

- 文件路径；
- 技术文件名；
- 稳定 `level_id`。

玩家显示标题可以修改，但：

- 不改变 `level_id`；
- 不把 Scene Name 当 ID；
- 不把文件名当 ID；
- 不把显示标题当 ID。

---

# 6. Duplicate as New Level

不把 Godot FileSystem 直接复制 `.tscn` 作为标准内容生产流程。

正式入口：

`Duplicate as New Level`

复制内容：

- 地图；
- 机关；
- Objective；
- Inventory；
- Presentation；
- General Rules；
- 其它合法内容。

同时必须：

- 生成新的 `level_id`；
- 为所有正式对象重新生成 Stable Instance ID；
- 重建 Objective 内部引用；
- 重建 Control Connection 内部引用；
- 清除不应跨关复制的运行 / 临时编辑状态；
- 生成新技术文件名与保存路径。

目标：

**内容相似，技术身份完全独立。**

---

# 7. Stable ID

所有正式关卡对象在创建时立即获得系统生成、持久化的 Stable Instance ID。

## 7.1 用户不可见 / 不手填

Stable ID 不作为普通 Inspector 文本字段暴露给张梓涵。

## 7.2 保持 ID 的操作

以下操作不改变 ID：

- 移动；
- 旋转；
- 改 Editor Note；
- 改 Node.name；
- 保存 / 重开；
- 修改合法实例配置。

## 7.3 产生新 ID 的操作

- Content Palette 新建对象；
- Ctrl+D 复制实例；
- Duplicate as New Level；
- Inventory Runtime 重新 Spawn。

## 7.4 正式引用

Objective、Control 等跨对象引用使用 Stable ID。

禁止依赖：

- Node.name；
- 网格坐标；
- 手填 crystal_id；
- 手填 group_id；
- 显示名称。

## 7.5 TileMap

TileMap 格子不分配 Stable ID。

未来若必须引用格子，采用：

- Layer；
- Grid Coordinate。

---

# 8. Editor Note

每个正式关卡对象都允许有一个通用 `Editor Note`。

它：

- 只供关卡作者识别；
- 可修改；
- 不影响稳定 ID；
- 不影响玩法；
- 不是玩家显示名；
- 不是程序标识。

选择器 / Validator 可显示：

`Editor Note / 正式类型 / 坐标`

方便内容人员识别。

---

# 9. Content Palette

正式新增对象的标准入口是轻量级 Content Palette。

Palette 从 Formal Content Declaration 自动读取：

- 分类；
- 名称；
- 图标；
- PackedScene；
- 预放置能力。

操作：

1. 选择机制；
2. 点击 / 拖入 Godot 2D；
3. 自动实例化正确 PackedScene；
4. 立即分配 Stable ID；
5. 进入正常 Godot 2D 编辑。

FileSystem 仍然保留给技术人员，但不是标准内容生产入口。

---

# 10. 正式对象 Placement / Occupancy

程序为每个机制正式声明：

- Logical Anchor；
- Rotation Pivot；
- Occupied Shape；
- Supported Directions；
- Direction Cycle Order。

这些不是关卡作者逐实例配置的内容。

## 10.1 2D 预览

拖拽和选中时必须显示真实占格：

- 单格；
- 多格；
- 不规则占格。

同时显示：

- 合法；
- 非法；
- 失败原因。

## 10.2 统一 Placement Query

Editor、Runtime、Validator 共用同一个正式空间合法性规则源。

Query 不是只返回 Bool，而应返回机器可读原因，例如：

- OUTSIDE_TERRAIN；
- NOT_IN_LEGAL_AREA；
- WALL_BLOCKED；
- OBJECT_OCCUPIED；
- SHAPE_OUT_OF_BOUNDS；
- 其它正式原因。

Editor 给简短提示，Validator 给完整问题列表。

## 10.3 方向快捷操作

Direction 的数据源仍然只有 Inspector / 正式字段。

2D 提供轻量快捷旋转，修改同一 Direction 字段。

不做复杂八方向 gizmo。

单方向机制自动隐藏 / 禁用旋转入口。

---

# 11. Interaction Profile

一个机制类型声明：

- 允许哪些 Interaction Profiles；
- 默认 Preplaced Profile；
- Inventory Spawn Profile。

内容人员选择的是合法 Profile，不是任意勾选：

- Move；
- Recover；
- Change Direction；
- Change Internal State；
- 等底层能力。

## 11.1 Profile 是作者角色，不是 Runtime State

Profile 只回答：

**这个预放置对象允许玩家以什么方式交互。**

运行时锁定 / 解锁属于玩法系统，不属于 Profile。

## 11.2 Level-editable Fields

不是所有 `@export` 都自动暴露给内容人员。

正式声明明确指定：

- 显示名称；
- 类型；
- 范围；
- 枚举；
- 默认值；
- 校验；
- 是否可被不同 Profile 限制。

Profile 只能：

- 限制；
- 禁用；
- 隐藏一部分内容能力。

不能增加新的玩法能力。

受 Profile 限制的“内容字段”建议仍显示但只读，并说明原因。

纯技术 / Debug 字段完全隐藏。

---

# 12. Inventory

Inventory 属于关卡 Level Content 的嵌入式责任模块。

不要求每关单独管理额外 `.tres` 文件。

## 12.1 内容

每个条目只保存：

- 类型；
- 数量；
- 顺序。

## 12.2 候选

只显示正式声明 `inventory-eligible` 的内容。

## 12.3 同类型唯一

一关中同一机制只出现一个 Inventory 条目。

数量统一累加。

拖拽顺序 = Runtime Toolbar 顺序。

## 12.4 数量

- 删除条目表示不提供；
- GUI 正常条目数量 >= 1；
- 极端大数量 Validator WARNING；
- 不为每个机制做一套任意 Hard Max。

## 12.5 显示信息

名称 / 描述 / 图标来自机制全局正式定义。

普通关卡不能单独：

- 重命名；
- 改图标；
- 改说明。

特殊教学文字走 Presentation / Hint。

## 12.6 Spawn

Inventory Spawn 使用：

- 机制全局默认内部状态；
- 全局 Inventory Spawn Interaction Profile。

不允许关卡逐条改 Spawn 默认状态。

## 12.7 Recover

预放置可回收机制返回 Inventory 时：

- 进入公共“类型数量池”；
- 原实例生命周期结束；
- 原 Stable ID 不再保留；
- 重新 Spawn 获得新 Stable ID；
- 使用全局 Inventory 默认状态 / Profile。

Reset 恢复：

- 初始预放置对象；
- 初始 Stable ID；
- 初始配置；
- 初始 Inventory。

---

# 13. Objective

Objective 采用：

**Target Carrier + Composable Objective Conditions**

而不是继续通过大量 Crystal 子类表达每一种组合。

## 13.1 单目标条件

保留在目标对象 Inspector。

UI：

`+ Add Condition`

只显示：

- 当前目标支持；
- 尚未添加；

的 Conditions。

同一 Condition 类型在一个 Target 上最多一次。

不同 Conditions 默认 AND。

OR 必须由 Condition 自己的参数模型表达，不做通用逻辑表达式。

空 Condition 列表表示：

**目标自己的 Base Success 即可。**

## 13.2 Objective Condition

Condition 类型必须正式声明：

- 显示名；
- 参数；
- 枚举；
- 验证；
- 可作用目标类型。

Objective Editor / Validator 不硬编码具体 Condition 名单。

---

# 14. Objective Group Editor

跨目标关系进入独立的小型 Objective Editor。

不做大型节点图。

支持：

- Independent；
- Simultaneous Group；
- Sequence Group。

一个 Target：

- 可独立；
- 或加入一个 Simultaneous；
- 或加入一个 Sequence；
- 最多一个跨目标 Group。

Group 不允许嵌套。

每个 Composite Group 至少 2 个成员。

少于 2 个：

- Editor Error；
- Validator Blocking。

## 14.1 Required / Optional

是否 Required 属于：

- Independent Objective；
- 或 Group；

而不是每个 Group Member 自己决定。

每个正式可运行关卡至少存在一个 Required Objective。

0 Required = ERROR。

全部 Required 完成后立即 COMPLETED。

因此 Optional 必须在最终 Required 完成前完成。

---

# 15. Sequence Group

顺序 = 编辑器列表拖拽顺序。

不使用人工 sequence number。

## 规则

假设顺序：

A → B → C

A、B 已完成，等待 C。

若发生：

- 错误地触发未来成员；
- 超时；

则：

- 回滚一个成功步骤；
- 移除 B；
- 下一目标回到 B。

当前期望目标发生“条件错误 Hit”：

- 只算 Invalid Attempt；
- 不回滚；
- 当前计时继续。

重新 Hit 已完成的旧目标：

- Sequence Progress 忽略；
- 目标自身仍可展示 Hit Feedback。

每个相邻步骤有自己的完成 Window。

每成功一步：

- 为下一步重新开始完整 Window。

第一个目标没有等待计时。

Sequence 一旦完成：

- 锁定 COMPLETE；
- 直到 Reset。

---

# 16. Simultaneous Group

采用滑动完成窗口。

每个成员记录：

- 最近一次正确完成时间。

旧成员超时：

- 只让过期成员失效；
- 其它仍有效成员保留。

当所有成员最近完成时间落在同一 Window：

- Group COMPLETE。

正确重复触发成员：

- 刷新该成员最新有效时间。

错误条件 Hit：

- 不清掉已有有效记录；
- 不缩短剩余状态。

完成后：

- 锁定 COMPLETE；
- 直到 Reset。

Independent Objective 同样是：

**第一次完成后锁定完成，直到 Reset。**

持续维持型 Objective 如未来需要，应作为新的正式能力，而不是修改当前普通 Objective 语义。

---

# 17. Objective 目标选择

Objective Editor 自动发现当前关卡所有具有 `ObjectiveTarget` 能力的正式对象。

不硬编码 Crystal。

目标选择基础入口：

- 当前关卡合法目标列表；
- 隐藏 Stable ID；
- 显示 Editor Note / 类型 / 坐标。

2D 直接 Pick 可以作为辅助，但不是唯一入口。

---

# 18. Control Connection

普通跨对象控制关系保存于 Source。

Target 只声明：

- 能被控制；
- 支持哪些 Control Actions。

不保存反向 Controller 列表。

## 18.1 Source

一个 Source 可以有多个正式 Output Events。

每个 Event 下可有多条 Connection。

每条 Connection：

- Target Stable ID；
- Control Action；
- Action Params。

## 18.2 多目标 / 多来源

允许：

- 一个 Source 连多个 Target；
- 一个 Target 被多个 Source 控制。

不自动解释成 AND / OR。

统一语义：

**Event → Command**

复杂逻辑未来必须通过明确新机制 / 新能力表达。

## 18.3 广播

同一 Output Event 下多条 Connection：

- 无顺序；
- 同一逻辑时刻广播。

不支持普通 Connection 自带：

- Delay；
- Sequence；
- 自由脚本。

这些未来使用专门能力。

## 18.4 冲突

同一逻辑时刻：

- 相同命令重复 → 去重；
- OPEN + CLOSE 等互斥命令 → Target 保持原状态并输出明确 Conflict Diagnostic；
- 不允许隐式 Last Wins。

编辑器应尽量静态阻止明显冲突。

## 18.5 循环

普通控制图必须无环。

新建 Connection 若形成 Cycle：

- 直接拒绝；
- 明确解释。

反馈环未来必须作为专门能力，而不是普通 Connection 绕出来。

## 18.6 自连

Self-target 禁止。

对象自身逻辑属于自己的正式机制行为。

## 18.7 Dynamic Target

普通 Connection 只允许指向作者期已存在、具有 Stable ID 的预放置对象。

不直接连接：

- Inventory Runtime Spawn 对象；
- “所有某类型”；
- “区域内全部”；
- “最后放置对象”。

这些未来如需要，属于新的动态目标能力。

---

# 19. Control Action Params

Action 可以有少量：

- 强类型；
- 平坦；
- 有限；

参数。

例如：

`CONFIGURE_OUTPUT(direction, form, speed)`

允许多个原子参数，但禁止：

- 任意 JSON；
- Script；
- Expression；
- 嵌套任意对象树；
- 通用函数调用。

参数值是静态作者值。

不做 Event Data Binding / Dataflow。

---

# 20. Control Connection 编辑器

作为选中控制源 Inspector 中的小型编辑器。

按 Output Event 分组。

支持：

- Add Connection；
- Remove；
- Target List；
- Action List；
- Typed Params。

## 2D Pick

第一版支持一次性 2D Pick：

- 合法 Target 高亮；
- 非法对象变暗 / 不可选；
- 点选后返回 Inspector；
- 再选择 Action。

只有选中控制源 / 编辑连接时显示临时连线和 Action Label。

普通编辑状态隐藏。

不做永久 Blueprint Spaghetti。

---

# 21. Map 四层规则

正式地图只有：

1. Terrain
2. LegalArea
3. Wall
4. Decoration

---

# 22. Terrain

Terrain 表示：

**这个格子属于正式地图空间。**

有 Terrain：

- 地图存在。

无 Terrain：

- 地图外 / 洞。

不再维护另一套 Bounds / Shape 真相源。

Terrain Tile 的差异默认只影响视觉。

普通 Terrain 不偷偷承载特殊玩法。

特殊地板未来应成为正式机制 / 能力。

---

# 23. LegalArea

纯逻辑白名单。

玩家 Placement 需要：

- Terrain；
- LegalArea；
- 无 Wall；
- 无占用；
- 满足共享 Placement Rules。

LegalArea 原始 Tile 不作为玩家运行时直接可见的美术。

Runtime 的可放置区提示由统一 Placement Area Visual System 表现。

## 23.1 初始化

提供显式：

`Fill / Initialize LegalArea from Terrain`

用于新关快速初始化。

后续 Terrain 改动不自动偷偷同步 LegalArea。

## 23.2 LegalArea 超出 Terrain

Editor：

- 立即提示；
- 提供显式一键清理。

不静默修改。

Validator：

- ERROR。

---

# 24. Wall

Wall TileMapLayer 是正式 Static Wall 唯一事实来源。

旧 ColorRect / Sprite 临时墙不能继续进入正式生产链。

所有普通 Wall Tile：

- 玩法阻挡语义一致；
- 视觉可以不同。

特殊墙：

- 光屏障；
- 未来特殊材料；

必须作为正式对象 / 能力，不藏进 TileSet。

Wall 与 LegalArea 不应重叠。

若重叠：

- Editor 提示并提供显式清理；
- Validator 报问题；
- 不静默修。

---

# 25. Decoration

Decoration 永远是纯视觉。

不影响：

- Placement；
- Wall；
- Terrain；
- LegalArea；
- 光传播；
- Objective；
- Collision；
- 其它玩法。

允许画在 Terrain 外。

允许在宏观视觉层级规则允许时覆盖 Terrain / Wall。

---

# 26. Map Visual Theme

每关选择一个正式 Map Visual Theme。

Theme 统一提供：

- Terrain 视觉；
- Wall 视觉；
- Decoration 素材；
- Scatter Presets；
- 对应地图视觉规则资源。

不允许每关 Terrain 用 Theme A、Wall 用 Theme B 任意拼装。

## 26.1 语义合同

所有 Theme 遵守统一 Semantic Tile Contract。

例如：

Terrain：
- Center；
- Edge；
- Outer Corner；
- Inner Corner；
- 等。

Wall：
- Straight；
- Corner；
- End；
- T；
- Cross；
- 等。

具体视觉可变，玩法语义不变。

---

# 27. Map Visual Theme 制作

张梓涵不直接以 Godot TileSet 底层结构作为标准入口。

Visual Asset Workbench 提供语义槽位。

内容人员：

- 填图；
- 看最终预览。

Workbench：

- 生成 / 更新 TileSet；
- Terrain Connect；
- Atlas；
- Import；
- Naming；
- 语义绑定。

高级技术人员仍可检查底层 TileSet。

---

# 28. Terrain / Wall 视觉槽位

采用：

**必填基础槽位 + 自动派生 + 可选独立覆盖。**

Workbench 必须显示：

- Requested Slot；
- Source；
- 自动派生来源；
- Override；
- Effective Visual。

---

# 29. Terrain / Wall Variants

同一语义可有：

- Primary；
- Variant 01；
- Variant 02；
- ...

这些 Variant：

- 玩法语义完全相同；
- 仅解决重复感。

## 分配

默认自动分配，但必须：

- 稳定；
- 可复现。

可根据：

- level_id；
- Layer；
- Grid Coordinate；
- Theme；

等稳定数据得到选择。

不允许运行时重新随机。

## 手工 Override

允许个别格子指定纯视觉 Variant Override。

如果地图拓扑变化导致当前格语义改变：

- 优先保证正确新语义；
- 若存在兼容 Variant 可迁移；
- 否则回退新语义 Primary / Auto；
- 明确提示 Override 失效。

不能为了保住旧外观破坏连接语义。

---

# 30. Decoration 素材模型

Decoration 不是 Terrain / Wall 式拓扑槽位。

它是 Theme 内纯视觉素材库。

按项目标准 Channel 分类，例如未来可整理为：

- Ground Details；
- Structure Details；
- Edge / Exterior；
- Foreground Accent。

具体名称可后续视觉收口。

## Channel

Channel 由项目固定。

Theme 只能：

- 提供素材；
- 提供 Scatter Preset；
- 留空。

Theme 不允许发明新的底层 Channel。

## 绘制层级

Channel 之间以及：

- Terrain；
- Wall；
- 正式机关；
- 前景；

的基础宏观 Z 合同由项目统一定义。

Theme 只能换素材，不能重排项目基础可读层级。

---

# 31. Decoration Scatter

支持纯视觉 Decoration Brush / Scatter Preset。

Preset 可包含：

- 一组装饰素材；
- 空白权重；
- 默认密度；
- 素材权重；
- 合法调整范围；
- Editor Placement Mask。

## 31.1 Placement Mask

例如：

- Terrain 内；
- Terrain 外；
- Wall 邻近；
- 无限制。

只是编辑器候选过滤。

不是 Gameplay Rule。

## 31.2 Density / Weight

每次刷之前可在正式范围内临时调整。

只影响本次编辑生成结果。

不成为 Runtime 参数。

## 31.3 Reroll

提供显式 Reroll。

随机只发生在编辑动作时。

保存后结果稳定。

不允许运行时重新随机。

## 31.4 Scatter Region Metadata

可保留纯编辑器元数据：

- Region；
- Preset；
- Density；
- Weights；
- Seed。

支持：

- Rebuild；
- Reroll；
- 调整参数后重生成；
- Bake / 解除关联。

这些数据不进入 Runtime Gameplay。

## 31.5 Manual Override

Scatter Region 内允许局部手工锁定：

`Locked / Manual Override`

重生成：

- 只更新未锁定部分。

支持：

`Clear Manual Override`

## 31.6 Region 重叠

不同 Decoration Channel：

- 可以重叠。

同一 Channel：

- 不允许模糊争夺同一格生成所有权；
- 应阻止或要求显式解决。

---

# 32. Theme 切换

Theme 切换采用：

**Preview → Compatibility → Apply**

不是直接写入。

## 32.1 Preview

非破坏性。

- 整关即时换皮；
- 查看 Compatibility；
- 查看 fallback；
- 查看 Decoration / Scatter 解析；
- 不改正式 Theme。

## 32.2 Apply

显式 Apply 后才正式修改。

作为一次编辑事务。

尽量可一次 Undo。

---

# 33. Theme Requested Intent / Effective Visual

关卡不保存 Theme A 的具体 PNG 作为业务事实。

应尽量保存：

**Requested Semantic Intent**

例如：

`Structure Details / Warning Sign / Variant 02`

当前 Theme 负责解析：

**Effective Visual**

若 Theme 缺对应素材：

- 用正式 fallback；
- Requested Intent 保留；
- Effective 标记 Fallback。

以后 Theme 补齐：

- 自动重新解析；
- 自动恢复目标视觉。

不能把 fallback 反写成新的内容意图。

---

# 34. Theme Compatibility

允许不完整 Theme 进行 Preview / Apply，但问题必须透明。

分级：

- Required 且无合法 fallback → ERROR；
- 有合法 fallback → WARNING；
- Optional 缺失 → INFO / WARNING。

禁止：

- 静默猜一个“最像的资源”；
- 静默残留旧 Theme 资源。

Theme 更新后，使用它的关卡在打开 / 刷新时自动重新解析 Effective Visual。

---

# 35. Visual Asset Workbench 总体模型

Workbench 按业务概念分类，而不是让内容人员先理解 Resource 类型。

主要入口可包括：

- Mechanisms；
- Map Themes；
- Ray；
- Particle；
- Formal Colors；
- Public Feedback；
- UI Theme。

后台可使用不同 Resource，但前台统一体验。

---

# 36. Workbench 正式资源导入

选择视觉槽位后：

`Import / Replace Image`

流程：

1. 选择项目外图片；
2. 检查格式；
3. 检查尺寸合同；
4. 自动规范命名；
5. 自动复制到正式目录；
6. 自动应用 Import Preset；
7. 等待 / 触发 Godot Import；
8. 自动绑定正式视觉槽；
9. 刷新 Effective Preview。

同时保留：

`Choose Existing Project Resource`

Workbench 只管理正式视觉资产，不做通用文件管理器。

---

# 37. 正式资源命名

外部文件原名不进入项目正式命名体系。

Workbench 按：

- 内容身份；
- 槽位；
- 状态；
- 方向；
- 用途；

自动生成规范技术名。

禁止长期产生：

- final；
- final2；
- 新最终版；
- _v2；
- _v3；
- _old。

---

# 38. 视觉槽位稳定路径

正式视觉槽对应稳定规范路径。

Replace：

- 更新当前正式文件；
- 触发 Reimport；
- 所有引用自动获得新视觉。

历史版本交给 Git。

Workbench 替换前必须显示：

- 正式对象；
- 正式槽位；
- Usage Impact。

---

# 39. 尺寸规则

Workbench 不自动缩放 / 重采样用户图片。

正式视觉槽可声明：

- Strict Size；
- Recommended Size；
- Free Size。

Strict 不合法：

- 阻止导入 / Apply。

Recommended：

- WARNING；
- 可继续。

不能通过静默缩放掩盖错误。

---

# 40. Import Preset

每类正式视觉槽声明 Import Preset。

例如：

- Pixel Mechanism；
- Tile Pixel；
- UI Icon；
- Background；
- Animation Frame。

Workbench 自动应用。

内容人员不逐张去 Godot Import 面板手调：

- Filter；
- Mipmap；
- Compression；
- Repeat；
- 等。

---

# 41. Visual Correction

允许受控：

- Visual Offset；
- Visual Scale；
- 等少量纯视觉校正。

只影响绘制。

绝不能改变：

- Logical Anchor；
- Occupied Shape；
- Grid Position；
- Collision；
- Optical；
- Objective；
- Placement；
- Runtime Timing。

## 继承

机制主体有默认 Visual Correction。

具体状态 / 槽位：

- 默认继承；
- 真正使用独立视觉资产时，才允许可选 Correction Override。

不下放到关卡实例。

---

# 42. 多视觉维度

视觉状态不是笛卡尔积 final_state_id。

采用独立维度。

例如：

- Body State；
- Direction；
- Speed；
- Public Feedback。

每个维度声明自己的表现类型：

- Body Replace；
- Auto Rotation；
- Direction Override；
- Overlay；
- Public Feedback；
- Animation；
- 等。

最终视觉由多层组合。

---

# 43. 视觉层级

每个机制正式声明：

- 有哪些视觉层；
- 顺序。

例如：

1. Body
2. Speed Overlay
3. Activation Overlay
4. Public Feedback

内容人员：

- 填资源；
- 看预览。

不能按关卡 / 实例：

- 新建任意层；
- 随意调整顺序。

---

# 44. 视觉层方向行为

每层正式声明如何响应 Direction，例如：

- Follow Direction；
- Screen Aligned；
- Direction Independent。

内容人员不逐实例配置。

---

# 45. 动画视觉槽

正式视觉槽可以是：

- Static；
- Loop；
- One-shot；
- Transition。

Workbench 不成为通用 AnimationPlayer 编辑器。

不提供：

- 通用曲线；
- 任意属性轨；
- Script Call；
- Event Track；
- 任意时间轴逻辑。

---

# 46. 动画输入格式

动画槽同时支持：

- Sprite Sheet；
- Independent Frame Sequence。

Workbench 负责：

- 规范命名；
- 顺序；
- 尺寸；
- Import；
- 正式动画资源组装；
- 预览。

---

# 47. 动画帧整理

允许受限基础操作：

- 拖动顺序；
- 删除帧；
- 复制帧；
- 替换单帧；
- 重新导入序列。

不扩展为动画制作软件。

---

# 48. 动画参数

动画槽正式声明：

- 哪些纯视觉参数可编辑；
- 默认 / 推荐值；
- 合法范围。

例如：

- FPS；
- 视觉 Fade；
- 纯表现持续时间。

动画语义类型本身由正式声明固定。

---

# 49. 动画与玩法

硬规则：

**玩法时钟与玩法状态永远由玩法系统决定。**

动画不能通过：

- 播放完成；
- 帧数；
- FPS；

驱动：

- Collision；
- Optical；
- Objective；
- Control；
- Gameplay State。

若玩法本身有“0.5 秒后生效”：

- 0.5 秒必须写在玩法规则；
- 不是动画时长。

---

# 50. Visual Successor

One-shot 等可声明纯视觉后继。

例如：

`ACTIVATE → ACTIVE`

只改变显示。

不能触发玩法。

Successor 必须无环。

持续循环使用 Loop，而不是：

A → B → C → A。

Workbench 创建关系时立即检测 Cycle。

---

# 51. 动画中断策略

动画槽可正式声明：

- Immediate Interrupt；
- Finish Visual Only；
- 等少量策略。

无论视觉是否继续播：

- 都不得阻塞真实玩法状态。

涉及真实功能状态的视觉默认优先跟随权威玩法状态。

---

# 52. Public Feedback Visual

项目统一提供：

- Selected；
- Legal；
- Illegal；
- Disabled；
- Hit；
- Activate；
- Blocked；
- Success；
- 等。

绝大多数机制继承统一样式。

少数机制可做 **类型级** Public Feedback Override。

禁止：

- 关卡级；
- 实例级。

只能改表现，不改变反馈玩法语义。

---

# 53. Public Feedback Style

Workbench 管理项目级 Visual Style Profile。

可受控编辑：

- Outline；
- Glow；
- Pulse；
- Tint；
- Visual Duration；
- 等纯表现参数。

不能：

- 改触发条件；
- 新增 Gameplay State；
- 写 Shader；
- 任意拼效果栈；
- 改系统优先级。

---

# 54. Public Feedback 并发

项目规则固定：

- 优先级；
- 兼容关系；
- 压制关系。

例如：

- Illegal 压制 Legal；
- Success 可压过普通 Hit；
- Disabled 与 Selected 的规则由项目固定。

张梓涵不能改这些系统级语义。

Workbench 提供常见组合预览：

- Selected + Illegal；
- Disabled + Hit；
- Success + Selected。

---

# 55. Visual Asset Change Set

Workbench 支持轻量 Staging / Change Set。

相关视觉可以先组成一个批次：

- 修改；
- Preview；
- Before / After；
- Usage Impact；
- Preflight；
- Apply All。

## Scope

一个 Change Set 默认只围绕：

- 一个逻辑视觉对象；
- 或一个视觉主题 / 系统。

例如：

- 单格镜完整视觉；
- 一个 Map Visual Theme；
- 一个 UI Theme。

不把无关系统混成一个超级 Change Set。

---

# 56. Usage Impact

修改已被引用的全局视觉资源前显示：

- 受影响关卡数；
- 实际使用当前槽位的关卡；
- Variant Override；
- fallback；
- 相关 Validator 问题。

不要求逐关卡确认。

## Impact Preview

支持轻量批量预览：

- 优先显示真正使用；
- 有 Override；
- 有 fallback；
- 有已有问题；

的关卡。

支持 Before / After。

旧版只是当前编辑事务临时快照。

不生成 `_old` / `_new` 文件。

---

# 57. Workbench Preflight

Apply All 前自动运行当前 Change Set 的最小相关 Preflight。

例如：

- Import 完成；
- Required Slot；
- Size；
- Animation；
- Successor Cycle；
- Theme Required Semantics；
- 合法 fallback。

分级：

- ERROR → 阻止 Apply；
- WARNING → 确认后 Apply；
- INFO → 提示。

不每次全项目扫描。

---

# 58. Safe Auto-fix

允许只修机械一致性问题。

可以修：

- 资源归位；
- Import Preset 恢复；
- 正式继承关系恢复；
- 失效临时引用刷新。

不能修：

- 缺美术；
- 猜替代资源；
- 尺寸错误自动缩放；
- 动画冲突自己删关系；
- Theme 设计选择。

## Fix Preview

点击 Fix 前先汇总：

- 将修改什么；
- 不会修改什么。

一次确认后批量执行。

## 事务

Apply All / Safe Fix 尽量原子化：

- 全部成功 → 正式生效；
- 中途失败 → 回滚到操作前。

确实无法恢复：

`RECOVERY REQUIRED`

必须列出受影响资源与恢复指引。

---

# 59. Ray Visual

Ray / Particle 纳入 Visual Asset Workbench。

玩法系统仍负责：

- 传播；
- 路径；
- 方向；
- 碰撞；
- 机关交互；
- 速度。

Workbench 只负责：

**真实语义最终怎么画。**

---

# 60. Ray 四种基础段

正式必填：

- Horizontal `-`
- Vertical `|`
- Diagonal `\`
- Diagonal `/`

四个都独立提供基础素材。

不默认拿 Horizontal 自动旋转得到其它三种。

原因：

- 光宽固定 16px；
- 斜向像素质量重要；
- 路径可读性重要。

---

# 61. Ray Seam Contract

每种 Ray Segment 声明正式连接方向：

- Horizontal：LEFT ↔ RIGHT；
- Vertical：UP ↔ DOWN；
- `\`：UP_LEFT ↔ DOWN_RIGHT；
- `/`：DOWN_LEFT ↔ UP_RIGHT。

Workbench 自动提供：

- 多格 Seam Preview；
- 连续 3～5 格；
- 斜向拼接；
- 中心线检查；
- 边界检查；
- 16px 宽度检查。

违反明确几何合同可 ERROR。

---

# 62. Ray Start / End Cap

支持可选：

- Start Cap；
- End Cap。

普通 Segment 仍然必填。

无 Cap：

- 直接普通 Segment。

Cap 只能改善：

- 发射口；
- 撞墙；
- 终点视觉。

不能改变真实光线路径或碰撞。

---

# 63. Ray Joint

不设置独立 Ray Joint / Corner Visual。

反射 / 转向由：

- 入射 Segment；
- 实际机制本体；
- 出射 Segment；

共同表达。

---

# 64. Ray Impact

项目级提供统一 Ray Impact Visual，例如：

- Normal Block；
- Absorb；
- 等。

特殊机关可类型级覆盖。

只在真实碰撞点表现。

不能修改：

- 路径长度；
- Collision Position；
- Objective；
- Control；
- Gameplay Result。

---

# 65. Formal Color Palette

玩法颜色身份例如：

- RED；
- BLUE；
- YELLOW；

由玩法系统定义。

Workbench 只能编辑视觉映射。

不允许：

- 新增玩法颜色；
- 删除；
- 重命名；
- 修改颜色 Objective；
- 修改颜色转换；
- 修改机关接受关系。

---

# 66. Color Style

每个正式玩法颜色不是只有一个 HEX。

采用受控 Visual Channels，例如：

- Core Color；
- Glow Color；
- Trail Color；
- UI Accent Color。

所有 Channel 仍属于同一个玩法颜色身份。

不同视觉系统按用途读取。

---

# 67. Ray / Particle Color

默认：

**Base Visual + Formal Color Style Tint**

不为每种玩法颜色复制整套：

颜色 × 方向 × 状态。

特殊颜色确实无法通过 Tint 达成时：

- 允许类型级独立视觉覆盖。

---

# 68. Color Readability

Workbench 提供 Color Readability Check。

支持：

- 理论颜色区分；
- Ray；
- Particle；
- Trail；
- UI Accent；
- 基础色盲模拟；
- 灰度预览。

默认问题：

- WARNING。

只有违反项目事先正式冻结的最低可读性硬标准时：

- ERROR。

Workbench 不可自己临时决定“我觉得太像，所以不让保存”。

---

# 69. Context-aware Readability

颜色检查必须放进真实背景。

项目定义少量正式关键场景，例如：

- Ray on Terrain；
- Ray crossing Wall edge；
- Particle on Terrain；
- Particle near bright Decoration；
- UI Accent on Standard Panel；
- Inventory Icon on Toolbar Slot。

当前 Map Theme 资源代入这些场景。

不做全项目穷举。

特殊机制可正式声明少量额外测试场景。

## Ad-hoc Preview

允许临时：

- 从当前关卡取样；
- 选择 Theme 素材；
- 作为背景测试。

只用于探索。

不自动变 Validator 合同。

---

# 70. Particle Body

光粒正式玩法主体：

- 宽 16px；
- 长 24px；
- 8 方向。

视觉采用：

- 一个必填基准方向；
- 自动派生到其它方向；
- 需要时方向级独立覆盖。

Trail 默认沿真实运动方向向后。

---

# 71. Particle Pivot

自动方向派生必须围绕正式：

- Logical Anchor；
- Rotation Pivot；

而不是图片几何中心。

Workbench 预览：

- Anchor；
- Pivot；
- 16×24 判定框；
- 最终视觉。

Visual Offset 不得改变逻辑 Pivot。

---

# 72. 斜向 Particle Visual

斜向旋转后视觉 Bounding Box 允许自然超过 16×24。

逻辑判定仍固定 16×24。

超出区域：

- 只视觉；
- 不 Collision；
- 不 Optical；
- 不改变到达时机；
- 不影响交互。

若某方向视觉太夸张，做方向级独立覆盖。

不强制缩放回 16×24。

---

# 73. Particle Speed Preview

Workbench 读取项目真实：

- SLOW；
- STANDARD；
- FAST；

速度规则。

按真实运动节奏预览。

Workbench 不允许修改玩法速度数值。

原则：

**可读取玩法参数用于视觉预览，不可反向编辑玩法。**

---

# 74. Particle Trail

每个正式速度档可拥有自己的 Trail Visual Style。

例如：

- 长度；
- Alpha Falloff；
- Glow；
- Texture；
- Animation。

Trail 永远不参与：

- 判定；
- 碰撞；
- 到达时间；
- 占用；
- 机关交互。

## Trail Length

内容人员直接编辑：

- px；
- 或逻辑视觉格长度。

Workbench 自动根据真实速度换算底层 Lifetime / Sampling。

不让内容人员直接填写技术时间参数。

---

# 75. Particle Interaction Visual

项目级统一定义，例如：

- Pass Through；
- Speed Change；
- Blocked；
- Absorbed；
- Target Success。

特殊机关可类型级覆盖。

这些只表现玩法系统已经决定的结果。

动画播放完成不能反向决定：

- 减速；
- 吸收；
- 命中；
- Objective；
- Control。

---

# 76. Global UI Runtime Structure

标准 Runtime UI 由项目统一维护，例如：

- Inventory Bar；
- Move Counter；
- Fire / Reset；
- Objective Display；
- Tutorial / Hint Area。

普通关卡不复制一整套 Control Tree。

---

# 77. 功能 UI 显示

默认由正式关卡能力自动推导。

例如：

Inventory 非空：
- Inventory Bar 默认显示。

Move Limit 启用：
- Move Counter 默认显示。

存在 Objective：
- Objective Display 默认显示。

只有正式声明允许 Presentation Override 的模块，才可：

- 隐藏；
- 简化；
- 切标准样式。

不能通过 Presentation 隐藏项目规定必须提供的关键玩法信息。

---

# 78. Presentation / Text

关卡级集中模块管理玩家可见文字。

例如：

- Level Title；
- Intro / Description；
- Objective Display Text；
- Hint / Tutorial；
- Completion Text。

对象自身 Editor Note 不进入 Presentation。

---

# 79. Objective 玩家文案

Objective 系统根据真实结构自动产生基础摘要。

例如：

- Target；
- Form；
- Speed；
- Color；
- Group；
- 等。

Presentation 允许张梓涵覆盖成自然玩家文案。

Validator / Editor 始终显示：

- 真实 Objective；
- 玩家文案。

可可靠判断出明显冲突时：

- WARNING。

玩家文案不能反向决定玩法。

---

# 80. Tutorial / Hint Trigger

提示不允许自由脚本 / Expression。

使用正式 Presentation Trigger。

例如：

- Level Start；
- First Fire；
- First Move；
- First Recover；
- Objective Completed；
- 正式 Runtime Event。

内容人员配置：

- 文本；
- Trigger；
- Display Style；
- 纯视觉持续时间。

新增触发类型必须由程序正式声明。

---

# 81. Global UI Visual Theme

标准 UI 基础风格由项目统一 Global UI Theme。

纳入 Visual Asset Workbench。

可包括：

- Panel；
- Button Normal / Hover / Pressed / Disabled；
- Inventory Slot；
- Objective Panel；
- Hint Panel；
- Icons；
- Typography；
- Spacing；
- 等正式视觉参数。

普通关卡不单独换基础皮肤。

未来特殊 UI 风格：

- 正式 UI Theme Variant / Presentation Theme。

不是单关随便改 Control Style。

---

# 82. Global UI Layout

标准布局允许张梓涵通过 Godot 原生 Control / Container 编辑器维护。

可以调整：

- Anchor；
- Container；
- Size；
- Margin；
- Padding；
- 模块位置；
- 标准间距。

## Runtime Binding Slot

关键 Slot 是受保护正式合同，例如：

- Inventory Host；
- Objective Host；
- Move Counter Host；
- Hint Host；
- Fire / Reset Host。

张梓涵可以移动 / 排版，但不能：

- 删除必要 Slot；
- 改业务含义；
- 破坏 Binding ID；
- 写 Script Binding；
- 每关复制 UI。

Validator 检查绑定结构。

---

# 83. 不做 UI Layout Workbench

Global UI Layout 的正式编辑入口就是 Godot 原生 Control 编辑器。

只补：

- Binding 标记；
- 保护；
- 预览；
- Validator；
- 快捷入口。

不重新实现一套拖拽 UI 编辑器。

---

# 84. UI Preview Data

提供标准只读 Preview Presets：

- Minimal；
- Typical；
- Long Content；
- Stress Test。

可模拟：

- Inventory 数量；
- 长 Objective；
- 长 Hint；
- 极端 Counter。

只存在编辑器。

## Ad-hoc Preview Data

允许当前编辑会话临时修改假数据。

不：

- 改标准 Preset；
- 写关卡；
- 改 Validator 标准。

---

# 85. Viewport Preview

项目定义少量正式标准 Viewport Presets，例如：

- Standard 16:9；
- Small 16:9；
- Large 16:9；
- Minimum Supported Window。

具体像素尺寸后续实现期冻结。

允许临时 Ad-hoc Viewport。

不自动成为正式支持标准。

---

# 86. UI Test Matrix

不做全部笛卡尔积。

项目定义少量有代表性的：

Preview Data × Viewport

例如：

- Typical × Standard；
- Long Content × Small；
- Stress Test × Minimum Supported；
- Minimal × Large。

自动检查机械问题：

- Control 越界；
- 文本裁切；
- 必需模块不可见；
- 明显重叠；
- Container 溢出。

审美仍由人判断。

---

# 87. General Rules

General Rules 属于 Level Content 的一个责任模块。

不做一个包含所有对象字段的巨型 Inspector。

## 87.1 Move Limit

采用：

- Enable；
- Maximum Count。

禁用时 Count 只读。

不使用 `-1` Sentinel。

## 87.2 Move Budget

全关共享。

成功空间布局变化都消耗 1：

- Inventory → Field；
- Field A → Field B；
- Field → Inventory。

不消耗：

- 方向切换；
- 状态切换；
- 原地拿起放回；
- 失败 Placement。

一次 Drag 无论距离：

- 1 次。

Move Budget 不因一次发射 / 运行周期重置。

只有 Reset 恢复。

到 0 后：

- 禁止 Place；
- 禁止 Move；
- 禁止 Recover；

其它合法非空间操作继续按 Profile / Rule。

---

# 88. Main Emitter Level Rules

普通正式关卡恰好一个 Main Emitter。

未来多光源：

- 使用新的辅助 / 固定 Source 机制；
- 不复制 Main Emitter。

## 88.1 Allowed Forms

非空集合。

集合本身就是玩家可选范围。

一个值：

- 没有 Form Switch。

多个值：

- 可以 Cycle。

不再设置额外 `can_switch_form`。

Initial Form 必须属于 Allowed Forms。

## 88.2 Allowed Directions

非空子集。

只能从 Main Emitter 全球支持方向中缩小。

Initial Direction 必须属于集合。

Cycle Order 使用 Main Emitter 全局顺序，跳过不允许方向。

关卡不能自定义顺序。

## 88.3 Particle Initial Speed

Main Emitter 实例允许选择一个正式全局速度档。

每次新发射 PARTICLE：

- 使用该初始档位。

旧粒子的变速不反馈给 Emitter。

## 88.4 Fire Interval

属于 Main Emitter 全局玩法规则。

普通关卡不修改。

## 88.5 输入

项目级固定：

- R = Reset；
- Space = Fire；
- W = Direction Cycle；
- Q = Form Cycle。

关卡不重映射。

教学 / 特殊锁定通过正式 Runtime / Tutorial 能力，而不是关卡 Input Mapping。

---

# 89. Play Current Level

纯内容关卡 Scene 不直接承担完整运行。

提供：

`Play Current Level`

流程：

1. 正在编辑当前 Level；
2. 保存 / 准备当前 Scene；
3. Current Level Preflight；
4. 通过后交给统一 LevelRuntimeHost；
5. 加载正式 Runtime UI；
6. 按真实玩法运行；
7. 退出后返回原关卡编辑上下文。

不是第二套 Runtime。

---

# 90. Validator Core

所有验证入口共用统一 Validator Core。

## Scope

### Change Set Scope

Visual Workbench Apply 前。

只检查当前视觉批次相关规则。

### Current Level Scope

Play Current Level 前或手动检查当前关卡。

覆盖：

- Map；
- Inventory；
- Objective；
- Stable ID；
- Connections；
- Presentation；
- UI；
- Visual Dependencies；
- Level Rules。

### Project Scope

主动执行完整项目一致性检查。

不在每次 Play / Apply 时默认全项目扫描。

---

# 91. Validator Severity

- ERROR：阻止正式 Apply / 默认阻止 Play；
- WARNING：明确确认后可继续；
- INFO：提示。

严重级别来自正式规则，不允许工具临时主观升级。

---

# 92. Validator Go To

每个可定位问题提供：

`Go To / 定位`

例如：

LegalArea：
- 切对应 Layer；
- 2D 高亮问题格。

Stable Object：
- 选中对象；
- 定位 Inspector 字段。

Objective：
- 打开目标 / Objective Editor。

Control：
- 选中 Source；
- 打开 Connection 区域。

Presentation：
- 打开对应 Text Item。

一个问题涉及多个对象：

- 提供成员列表；
- 支持逐个定位。

Validator 是内容生产导航工具，不只是日志。

---

# 93. Validator Safe Auto-fix

与 Workbench 相同原则：

只修不会改变设计意图的机械问题。

修复前：

- Fix Preview。

修复：

- 批量；
- 原子事务优先；
- 失败尽量回滚。

---

# 94. Map Layer Editing Assist

标准地图绘制仍然使用 Godot TileMap 编辑。

提供轻量 toolbar / 小 Dock：

- 当前 Layer 切换；
- Visibility；
- Lock；
- Initialize LegalArea；
- 常用检查；
- Decoration Scatter；
- 当前 Layer 编辑视觉 preset。

不做第二个地图编辑器。

## 当前 Layer Mode

默认：

- 当前 Layer 高亮；
- 其它 Layer dim / outline / hide 适当处理；
- 其它三个 Layer 默认 Lock。

内容人员可临时解锁 / 改 visibility。

这些只影响 Editor，不修改 Runtime Visual。

---

# 95. Tool 使用顺序：新关卡从 0 到完成

## 阶段 1：创建

`Create New Level`

得到合法纯内容骨架。

## 阶段 2：地图

Godot TileMap：

1. Terrain；
2. Fill LegalArea from Terrain；
3. 修 LegalArea；
4. Wall；
5. Decoration；
6. Scatter；
7. 手工视觉精修。

Map Layer Assist 负责高频切层和检查。

## 阶段 3：预放置正式机制

Content Palette：

- Emitter；
- Crystal / Objective Target；
- Barrier；
- Detector；
- 其它正式机制。

2D Preview：

- Occupied Shape；
- Direction；
- Placement Reason。

Inspector：

- Interaction Profile；
- Level-editable Fields；
- Editor Note。

## 阶段 4：Inventory

Level Content → Inventory。

配置：

- 类型；
- 数量；
- 顺序。

## 阶段 5：Objective

单对象：

- Add Conditions。

跨对象：

- Objective Group Editor。

配置：

- Independent；
- Simultaneous；
- Sequence；
- Required / Optional；
- Group Window；
- Sequence Order。

## 阶段 6：Control Connections

选中 Source：

- Output Event；
- Add Connection；
- Target；
- Action；
- Params；
- 2D Pick。

## 阶段 7：General Rules

设置：

- Move Limit；
- Emitter Allowed Forms；
- Allowed Directions；
- Initial Speed；
- 其它正式 Level Rules。

## 阶段 8：Presentation

配置：

- Title；
- Intro；
- Objective 玩家文案；
- Hint；
- Tutorial Trigger；
- Completion Text。

## 阶段 9：视觉

若需要新资源：

Visual Asset Workbench：

- Mechanism；
- Map Theme；
- Ray；
- Particle；
- Public Feedback；
- Colors；
- UI Theme。

Change Set：

- Import；
- Preview；
- Usage Impact；
- Before / After；
- Preflight；
- Apply。

## 阶段 10：验证

Current Level Validator：

- Map；
- ID；
- Objective；
- Inventory；
- Control；
- UI；
- Presentation；
- Visual；
- Rules。

使用 Go To 修复。

## 阶段 11：运行

`Play Current Level`

自动 Preflight。

通过后：

- 统一 RuntimeHost；
- 正式 UI；
- 实际玩法体验。

## 阶段 12：人工验收

人工重点检查：

- 关卡是否好玩；
- 玩法信息是否可读；
- Objective 是否表达清楚；
- UI 是否遮挡；
- 光线 / 光粒视觉；
- 地图构图；
- 教学节奏。

---

# 96. Tool 使用顺序：全局视觉修改

1. 打开 Visual Asset Workbench；
2. 选择一个逻辑视觉对象 / Theme；
3. 开始 Change Set；
4. Import / Replace；
5. 自动命名；
6. 自动 Import Preset；
7. Effective Preview；
8. 必要时 Visual Correction；
9. Before / After；
10. Usage Impact；
11. 批量 Impact Preview；
12. Change Set Preflight；
13. Safe Fix（若有）；
14. Apply All；
15. 原子事务落地；
16. 使用 Validator Project Scope 做阶段性全局检查；
17. 对重点关卡人工运行抽查。

---

# 97. Tool 使用顺序：Global UI 修改

1. Workbench 修改 Global UI Visual Theme；
2. 打开正式 Global Runtime UI Scene；
3. Godot 原生 Control / Container 排版；
4. Runtime Binding Slot 保护；
5. 切换 Preview Data；
6. 切换 Viewport Preset；
7. 跑 UI Test Matrix；
8. 自动发现机械布局错误；
9. 人工检查审美 / 可读性；
10. Validator；
11. 在真实关卡 RuntimeHost 中抽查。

---

# 98. 明确不做的东西

为了防止工具链再次膨胀，v1 明确不做：

- 第二套巨型关卡编辑器；
- 第二套 TileMap 编辑器；
- UI Layout Workbench；
- Blueprint / Visual Scripting；
- Objective 逻辑图；
- Control Graph 大型节点图；
- 任意脚本表达式；
- 任意 JSON Action Params；
- Event Dataflow；
- 普通 Connection Delay / Sequence；
- 运行时随机 Decoration；
- 每关任意 UI 皮肤；
- 每关任意机制美术皮肤；
- 每实例 Visual Offset；
- Visual Animation 驱动 Gameplay；
- Node.name 作为技术身份；
- File Copy 作为标准关卡复制方式；
- 多套 Validator Rule；
- Workbench 自己做 Git 版本管理；
- Workbench 做通用文件管理器；
- 自动缩放错误美术；
- 静默 fallback；
- 静默 Safe Fix；
- 无法解释的 Last Wins；
- 运行时动态对象作为普通 Control Target。

---

# 99. 最终插件 / 工具清单

下面是 v1 建议真正需要实现或升级的完整清单。

## A. EditorPlugin / Tool Package

### 1. Light Speed Authoring Core

**位置：** 所有编辑工具底层  
**职责：** Formal Declaration、Stable ID、Shared Placement、Validator Core、Usage Discovery、编辑事务。  
**边界：** 不做大型 UI，不承担玩法运行逻辑。

### 2. Visual Asset Workbench

**位置：** 全局视觉制作阶段  
**职责：** 机关、地图主题、Ray、Particle、颜色、公共反馈、UI Theme。  
**边界：** 只改视觉，不改 Gameplay。

### 3. Level Authoring Assist

**位置：** 日常关卡制作  
**职责：** 创建、复制、Content Palette、Map Assist、Placement Overlay、Objective/Inventory/Connection/Presentation 小编辑器、Play Current Level。  
**边界：** 不替代 Godot 2D / Inspector / TileMap。

### 4. UI Authoring Assist

**位置：** Global UI 制作  
**职责：** Binding Slot 保护、Preview Data、Viewport Preview、UI Test Matrix。  
**边界：** 不替代 Godot Control 编辑器。

### 5. Validator Panel

**位置：** 日常检查 / 阶段收口  
**职责：** Change Set / Level / Project Scope、Go To、Safe Fix。  
**边界：** 底层必须复用统一 Validator Core。

---

## B. 具体小工具 / Editor Assist

这些不一定每个都做成独立插件，可作为上述包里的独立组件。

1. `Create New Level`
2. `Duplicate as New Level`
3. `Play Current Level`
4. `Content Palette`
5. `Map Layer Toolbar`
6. `LegalArea Initialize / Cleanup Assist`
7. `Decoration Scatter Editor`
8. `2D Occupancy Preview`
9. `2D Placement Failure Reason`
10. `Direction Cycle Shortcut`
11. `Stable ID Manager`
12. `Interaction Profile Inspector`
13. `Level-editable Field Inspector`
14. `Editor Note`
15. `Inventory Editor`
16. `Objective Condition Editor`
17. `Objective Group Editor`
18. `Control Connection Editor`
19. `Control 2D Pick Mode`
20. `Presentation / Text Editor`
21. `Tutorial Trigger Selector`
22. `Visual Asset Importer`
23. `Visual Change Set`
24. `Usage Impact Viewer`
25. `Before / After Impact Preview`
26. `Animation Frame Organizer`
27. `Map Theme Semantic Slot Editor`
28. `Map Theme Compatibility Preview`
29. `Ray Seam Preview`
30. `Particle Motion Preview`
31. `Formal Color Palette Editor`
32. `Color Readability Preview`
33. `Public Feedback Style Editor`
34. `UI Binding Slot Guard`
35. `UI Preview Presets`
36. `Viewport Preview Presets`
37. `UI Test Matrix`
38. `Validator Go To`
39. `Safe Auto-fix`
40. `Recovery Required Report`

---

# 100. 实现优先级建议

## P0：先让“正式关卡无代码可做”

优先：

1. Authoring Core；
2. Stable ID；
3. Formal Content Declaration；
4. LevelRuntimeHost / Pure Level Scene 接线；
5. Create New Level；
6. Content Palette；
7. Map Layer Assist；
8. Shared Placement Preview；
9. Inventory Editor；
10. Objective Condition / Group Editor；
11. Control Connection Editor；
12. Presentation / Text；
13. Validator Core + Go To；
14. Play Current Level。

## P1：补齐正式美术生产

1. Visual Asset Workbench；
2. 机关视觉；
3. Map Visual Theme；
4. 正式导入 / 命名 / Import Preset；
5. Change Set；
6. Usage Impact；
7. Theme Preview；
8. Ray / Particle；
9. Formal Color Palette；
10. Public Feedback；
11. Animation Asset Support。

## P2：UI 内容生产

1. Global UI Visual Theme；
2. Binding Slot Guard；
3. Preview Data；
4. Viewport Preview；
5. UI Test Matrix。

## P3：体验增强

1. 更好的批量 Impact Preview；
2. 更丰富 Ad-hoc Preview；
3. 更多 Safe Fix；
4. 2D Objective Pick 增强；
5. 更成熟 Scatter Region 操作；
6. 更丰富可读性检查。

---

# 101. 最终设计原则清单

实现阶段必须持续用下面这些原则做审查：

1. **Gameplay Truth ≠ Visual Truth。**
2. **视觉可以围绕逻辑调整，逻辑不能跟着图片跑。**
3. **动画只能表现玩法，不能成为玩法时钟。**
4. **Formal Content Declaration 是内容能力唯一事实来源。**
5. **Stable ID 是跨系统身份，Node.name / 坐标 / 显示名都不是。**
6. **Godot 原生编辑能力优先。**
7. **插件只补项目语义和高频缺口。**
8. **不做第二套巨型关卡编辑器。**
9. **Scene 保存空间内容；Resource / Module 保存非空间规则。**
10. **关卡 Scene 保持纯内容。**
11. **RuntimeHost 统一运行链。**
12. **玩法能力决定 UI 是否存在，Presentation 决定允许范围内怎么呈现。**
13. **Global Visual 一处修改，全项目传播。**
14. **关卡保存 Requested Intent，不保存视觉副本。**
15. **Fallback 必须透明。**
16. **随机只用于编辑器，不用于运行时装饰。**
17. **Validator 规则只有一份。**
18. **能 Go To 的问题不要只打印日志。**
19. **Auto-fix 只修机械一致性，不替人做设计选择。**
20. **批量编辑尽量原子化，要么完整生效，要么回滚。**
21. **内容人员面对业务语义，不面对技术 ID、Tile ID、脚本表达式。**
22. **新增机制尽量只新增声明和自身实现，不要求同步修改五六个工具名单。**

---

# 102. 当前结论

到这里，本轮“张梓涵如何通过 Godot GUI 完成关卡 / UI / 美术 / Objective / Inventory / Connection / Validation / Run Test”的关键架构问题已经基本问完。

后续最合理的下一步不是继续无限讨论，而是：

1. 以本文作为 v1 冻结设计；
2. 让 GLM-5.3 对当前仓库做一次**定向差距审计**；
3. 只回答：
   - 当前已有能力；
   - 与本文的差距；
   - 哪些旧工具需要保留 / 迁移 / 删除；
   - P0 实现批次如何拆；
4. 再由 GPT-5.6 Sol 基于 Evidence Packet 做最终阶段拆解；
5. GLM 按小批次实现；
6. 每批都走 Godot GUI 人工验收。

---

**状态：v1 设计冻结，可进入差距审计与实现拆解阶段。**
