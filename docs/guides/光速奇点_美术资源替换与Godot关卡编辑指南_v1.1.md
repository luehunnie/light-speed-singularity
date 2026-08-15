# 《光速奇点》美术资源替换与 Godot 关卡编辑指南

> 版本：v1.1
> 更新日期：2026 年 7 月 29 日
> 适用角色：美术与关卡制作人员
> 适用环境：Godot 4.6.1 Standard
> 项目路径：`E:\godot_project\light-speed-singularity`
> 文档定位：本指南同时包含**当前可操作流程**和**未来目标流程**。当前可用能力包括：已实现的视觉接口（`VisualStateTexture`、`ObjectVisualProfile`、`ObjectVisualView`、`InventorySlotView`、`LightSegmentVisualProfile`、`LightSegmentView`）、`GridPlacedObject` 位置契约（`position` 为事实、`cell` 派生）、`EmitterConfigNode`/`EmissionPreview`，以及唯一的美术 Profile 编辑器插件 `addons/light_speed_art_profile/`。未实现的目标流程（方法 B 多格、`FixedEmitter` 独立预制场景与统一 `EmissionRequest`、一键创建独立 Profile 副本）**不得作为张梓涵当前的验收前置条件**。（~~方法 B 单格、`LevelValidator` v0、完整关卡模板、`READY_TO_FIRE` 与开始运行按钮、光粒运行时~~ 均已实现：D5/D6、D7-2/D7-3、D7-4。）

---

# 0. 实施状态说明

本指南区分两类内容：

- **当前可用**：基于已实现视觉接口（`VisualStateTexture`、`ObjectVisualProfile`、`ObjectVisualView`、`InventorySlotView`、`LightSegmentVisualProfile`、`LightSegmentView`）、`GridPlacedObject` 位置契约、`EmitterConfigNode`/`EmissionPreview`、现有原型场景，以及唯一的美术 Profile 编辑器插件 `addons/light_speed_art_profile/` 的流程，张梓涵现在就可以执行；
- **目标 / 未实现**：方法 B 多格编辑与父节点移动一致性完整流程、`FixedEmitter` 独立预制场景与统一 `EmissionRequest`、一键创建独立 Profile 副本等，属于未来目标，当前不具备可依赖的代码或字段。（方法 B 单格路径、`LevelValidator` v0 与 Runtime 自动 Validation Gate（D7-1/D7-3）、正式关卡模板、Godot 原生 GUI 关卡编辑基础、墙体方向编辑、`READY_TO_FIRE` 与正式“开始运行”入口（D7-2/D7-3）、光粒运行时与 Particle 八方向（D7-4）均已完成。）

契约存在不等于代码已经实现。已实现视觉接口的路径、`class_name`、基类和公开方法以真实代码为准（详见《永久视觉与关卡编辑接口设计 v1.1》§6、§7–§10、§14.4、§15）。

## 0.1 实施状态表

| 能力 | 当前状态 | 说明 |
|---|---|---|
| 美术 Profile 编辑器插件 | 当前可用 | 唯一正式插件 `addons/light_speed_art_profile/`：目标解析、Profile 识别、资产浏览、状态选择、查看/替换当前状态图片、Undo/Redo、保存确认、共享警告 |
| 已接入 Profile 的世界纹理替换 | 当前可用 | 通过插件或 `.tres` Profile 替换 `world_texture` / `drag_texture` |
| 视觉状态配置 | 当前可用 | 稳定 `state_id` + `default_state_id` 回退 |
| 世界纹理和机关栏图标分离 | 当前可用 | `inventory_icon` 独立于 `world_texture` |
| 现有原型场景与 `TileMapLayer` | 当前可用 | 在已有原型场景中验证 |
| 64×64、Nearest、透明背景、锚点检查 | 当前可用 | 素材规范 |
| 光线四类片段视觉 | 当前可用 | `LightSegmentVisualProfile` 四方向纹理 |
| `GridPlacedObject` 位置契约 | 当前已实现 | `position` 为场景编辑事实，`cell` 由 `world_to_cell` 派生，`set_cell` 用 `cell_to_world` |
| `EmitterConfigNode` / `EmissionPreview` | 当前已实现 | 发射器关卡配置唯一来源与编辑器预览；`EmissionPreview` 仅编辑器预览，不是正式运行光线 |
| 编辑器 64 格吸附 | 当前可用（Godot 原生） | 节点拖动、复制、64×64 网格吸附、position Undo/Redo 均由 Godot 原生负责 |
| 方法 B（2D 视图直接拖动编辑） | 单格已完成 / 多格为目标 | 单格拖动写回逻辑 cell 已完成（D5）；多格对象编辑、父节点移动一致性完整流程仍为目标 |
| `LevelObjectRegistry`（完整扫描） | 部分实现 | 水晶按 `crystal_id` 与 cell 双向索引已实现；扫描/多类型对象注册仍为目标 |
| `LevelValidator` | v0 已实现 / 自动门已实现 | v0 只读校验已实现（D6，PR #45–#48）；Runtime 自动 Validation Gate 已实现（D7-1 `RuntimeValidationGate` 经 D7-3 Start Run 正式调用）；编辑器保存时自动校验仍非必跑步骤 |
| 正式关卡模板 | 已实现（基础） | `levels/templates/level_template.tscn` 四层 `TileMapLayer`（D5，PR #35–#44）；多格对象完整编辑流程仍为目标 |
| `FixedEmitter` 独立预制场景与统一 `EmissionRequest` | 目标 / 未实现 | 运行期 cell/direction/form 与 `FireRequest` 已实现，光粒运行时已实现（D7-4）；`fixed_emitter.tscn`/统一 `EmissionRequest` 仍为目标 |
| `READY_TO_FIRE` | 已实现（D7-2/D7-3） | 五态 `READY_TO_FIRE=4` + `begin_runtime` 正式入口，不改变美术验收项 |
| 开始运行按钮 | 已实现（D7-3） | `gameplay/ui/run_start_view`，不改变美术验收项 |
| 光粒运行时编辑与验收 | 已实现（D7-4/M4-E4） | `ParticleDirection` 八方向 + `Q` 形态切换（`allow_form_switch`）；美术素材验收以真实代码为准 |
| 一键创建独立 Profile 副本 | 目标 / 未实现 | 共享 Profile 自动实例化尚未实现 |

---

# 1. 工作目标

美术与关卡制作人员应当能够只通过 Godot 编辑器完成：

- 导入和替换世界美术；
- 替换机关栏、菜单和成就图标；
- 绘制地图、墙体、可放置区域和装饰；
- 放置、拖动、复制发射器、水晶和预置机关；
- 在 Inspector 中配置方向、光形态、状态视觉、关卡库存和目标；
- 制作单机关原型；
- 制作机关组合原型；
- 制作灰盒关卡；
- 制作正式章节关卡；
- 运行关卡校验；
- 记录解法、素材来源和已知问题。

当前可执行工作流（仅基于已实现接口）：

```text
打开 Godot
→ 准备 64×64 素材，检查透明背景 / Nearest / 锚点
→ 打开对应视觉 Profile（.tres）
→ 保持 state_id 不变，设置 world_texture / drag_texture / inventory_icon
→ 保存
→ 在已有原型场景和 TileMapLayer 中运行验证
→ 检查 Output 和 Debugger
→ 记录问题并反馈给陈俊贤或对应模块负责人
```

目标工作流（当前未实现，不得作为张梓涵当前验收前置条件）：

```text
复制完整关卡模板
→ 绘制 TileMapLayer
→ 拖入固定对象场景
→ 移动或复制对象（Godot 原生 64 格吸附：拖动/复制/Undo/Redo 由 Godot 原生负责）
→ 在 Inspector 中完成配置
→ 运行关卡校验（LevelValidator，D6）
→ 人工测试
→ 保存并提交
```

美术与关卡制作人员不需要修改核心玩法代码。

---

# 2. 最终编辑方式总览

> 本节描述的是**目标编辑方式**。其中 `TileMapLayer` 分层、关卡加载校验等部分当前未实现，仅 `TileMapLayer` 基础绘制与已实现视觉接口可当前使用。节点拖动、复制、64×64 网格吸附、position Undo/Redo 由 Godot 原生负责；项目不制作正式移动吸附插件。

项目中的内容分为两类。

## 2.1 使用 TileMapLayer 绘制的内容

适合连续、大量和重复绘制的内容：

- 地面；
- 普通墙体；
- 可放置区域；
- 禁止放置区域；
- 地图形状；
- 装饰图块。

最终关卡模板包含：

```text
TerrainLayer
WallLayer
LegalAreaLayer
DecorationLayer
```

## 2.2 使用独立场景对象放置的内容

适合需要逻辑配置、方向、状态和独立交互的内容：

- 固定发射器；
- 水晶；
- 预置镜面；
- 加速器；
- 减速器；
- 分光器；
- 滤光片；
- 光形式转换器；
- 光电二极管；
- 受控机关；
- 教学标记。

这些对象目标上统一支持：

- 拖动（Godot 原生）；
- 复制（Godot 原生）；
- 64 格吸附（Godot 原生，不制作移动吸附插件）；
- Inspector 配置；
- 关卡加载校验（`LevelValidator` v0 已实现 D6；Runtime 自动 Validation Gate 未实现）；
- 视觉 Profile 替换（当前可用）。

当前已有视觉 Profile 替换（含插件）、`GridPlacedObject` 位置契约（已实现）、`EmitterConfigNode`/`EmissionPreview` 与原型场景内的基础操作可用；Godot 原生 64 格吸附可用于节点拖动/复制，方法 B 单格路径（拖动写回逻辑 cell）已完成（D5）、`LevelValidator` v0 已实现（D6）；方法 B 多格编辑与父节点移动一致性完整流程仍为目标，Runtime 自动 Validation Gate（运行期自动调用校验器）未实现，关卡校验自动门不得列为当前必测项。

---

# 3. 世界网格规则

## 3.1 逻辑格

```text
一个逻辑格 = 64×64 世界像素
半格 = 32 世界像素
```

格子中心位置：

```text
X = 32 + 64 × cell.x
Y = 32 + 64 × cell.y
```

例如：

| 逻辑格 `cell` | 世界中心位置 |
|---|---|
| `(0, 0)` | `(32, 32)` |
| `(1, 0)` | `(96, 32)` |
| `(0, 1)` | `(32, 96)` |
| `(3, 2)` | `(224, 160)` |

## 3.2 GridPlacedObject 位置契约

> **状态：当前已实现。** `position` 是场景编辑事实，`cell` 由 `position` 派生。

每个固定对象具有：

```text
position : Vector2   # 场景编辑事实
cell     : Vector2i  # 由 position 派生
```

规则：

- `position` 是场景编辑事实，由 Godot 原生编辑（拖动/复制/Undo/Redo）；
- `cell` 由 `position` 经 `world_to_cell` 派生，不再是独立输入；
- `set_cell` 内部通过 `cell_to_world` 写回 `position`；
- 不手动维护第二套逻辑坐标。

单格对象位置约定（区分局部原点与格中心偏移）：

1. `GridPlacedObject` 根节点自身的局部原点为 `(0, 0)`；
2. 根节点在场景中的 `position` 对齐目标格中心——`cell_to_world(Vector2i.ZERO)` 在 64 格下返回 `(32, 32)`，这是从 64×64 格子左上角计算的格中心偏移（半格），用于把根 `position` 放到格中心，而非根节点局部原点；
3. visual、collision、hint 子节点使用相对根节点的局部坐标，不得把子节点统一放到 `(32, 32)` 来二次补偿根节点位置；
4. 多格对象根 `position` 对齐明确锚点格中心，占用偏移由 `get_occupied_offsets(p_orientation: int = 0)` 表达，全部占用格由 `get_occupied_cells(anchor_cell: Vector2i, p_orientation: int = 0)` 叠加计算。

不得把根节点局部原点直接写为 `(32, 32)`，避免混淆局部坐标与格内偏移。

> 注：方法 B 单格路径（2D 视图直接拖动后把最终位置写回逻辑 cell）已完成（D5）；多格对象编辑与父节点移动时视觉/碰撞/方向/光路配置一致性完整流程仍为目标。当前可使用 Godot 原生拖动 `position`，但多格场景下不要假定拖动后所有派生配置已自动完整写回。

## 3.3 编辑器吸附（Godot 原生）

> **状态：当前可用（Godot 原生）。** 节点拖动、复制、64×64 网格吸附、position Undo/Redo 由 Godot 原生负责；项目不制作正式移动吸附插件。

操作方式：

```text
在 2D 视图拖动/复制对象（Godot 原生吸附到 64×64 网格）
→ position 由 Godot 原生记录并可 Undo/Redo
→ 运行时 cell 由 world_to_cell 从 position 派生
```

Godot 编辑器顶部的移动吸附开关只影响 Godot 原生吸附行为；项目不再制作独立移动吸附插件。

---

# 4. 美术资源目录

```text
assets/
└─ art/
   ├─ world/
   │  ├─ backgrounds/
   │  ├─ emitters/
   │  ├─ walls/
   │  ├─ crystals/
   │  └─ mechanisms/
   │     ├─ mirrors/
   │     ├─ speed/
   │     ├─ splitters/
   │     ├─ filters/
   │     ├─ converters/
   │     ├─ detectors/
   │     └─ controlled/
   ├─ tilesets/
   ├─ ui/
   │  ├─ items/
   │  ├─ achievements/
   │  └─ menus/
   └─ levels/
      ├─ particle_chapter/
      ├─ ray_chapter/
      └─ mixed_chapter/
```

## 4.1 存放原则

- 多个关卡共用的素材放通用目录；
- 某章节独占装饰放 `assets/art/levels/<章节>/`；
- 世界纹理和 UI 图标分开；
- 机关脚本和场景不放进 `assets/art/`；
- 通用机关图片不要复制到每个关卡目录；
- 不使用临时混乱命名。

---

# 5. 素材尺寸与导入

## 5.1 世界对象

单格世界对象推荐：

- 64×64 画布；
- 透明背景；
- 内容居中；
- 同类对象锚点一致；
- 不保留不必要的大面积透明边；
- 不依靠缩放修正错误画布。

多格机关按照占用范围设计，但逻辑锚点仍位于一个明确的基准格。

## 5.2 UI 图标

UI 图标与世界格尺寸分离。

建议同一界面使用统一规格，例如：

- 32×32；
- 48×48；
- 64×64。

## 5.3 Godot 导入

操作步骤：

1. 将 PNG 放入正确目录；
2. 返回 Godot；
3. 等待自动导入；
4. 在 FileSystem 中选中资源；
5. 检查 Import；
6. 使用 Nearest 过滤；
7. 点击 Reimport；
8. 在实际场景中检查。

检查：

- 透明背景；
- 内容居中；
- 像素边缘清晰；
- 无多余白边；
- 状态图片方向一致；
- 图像未被错误压缩或拉伸。

---

# 6. 视觉 Profile 的最终使用方式

项目不在脚本中写死图片路径。

所有可替换视觉通过 `.tres` Profile 配置。

主要资源目录：

```text
assets/visual_profiles/
```

## 6.1 通用对象视觉

对象场景内部使用：

```text
ObjectVisualView
```

它根据稳定状态 ID 读取 Profile 中的图片。

美术替换人员只需要：

1. 打开对应 `.tres`；
2. 找到状态；
3. 设置 `world_texture`；
4. 按需要设置 `drag_texture`；
5. 设置 `inventory_icon`；
6. 保存；
7. 运行验证。

不要修改状态 ID。

## 6.2 使用美术 Profile 编辑器插件（当前可用）

项目当前唯一的正式编辑器插件是 `addons/light_speed_art_profile/`（右侧 Dock“光速奇点：美术资源”）。张梓涵替换美术的正式操作：

1. 在场景树中选择一个支持 `ObjectVisualProfile` 的目标对象（如水晶、镜面、发射器等继承 `GridPlacedObject` 的组件，或其内部 `ObjectVisualView`）；
2. 打开唯一的美术 Profile 插件 Dock（插件已在 `project.godot` 启用）；
3. 在“视觉状态”列表中选择一个状态（如 `unlit` / `lit` / `slash` / `backslash`）；若组件有多个可替换视觉，先在上方目标选择器中选一个正式视觉；
4. 在下方美术资产浏览器中选择图片（可按目录树或文件名/路径搜索）；
5. 点击“应用到当前状态”；
6. 使用 `Ctrl+Z` / `Ctrl+Y` 撤销重做；
7. 点击“保存视觉配置”，并在二次确认中点击“确认保存”；
8. 理解共享 Profile 会影响所有引用者——保存前请阅读共享资源提示。

要点：

- **单击资产只选择与预览，不会自动替换**；双击不作为正式应用操作；
- “应用到当前状态”和“保存视觉配置”是**两步**：前者改内存纹理并走 Undo/Redo，后者把当前内存状态写回 `.tres`；
- 保存**不会**自动创建独立副本；共享 Profile 保存后所有引用者都会使用新图片，共享警告不可忽略；
- 素材必须位于 `res://assets/art/`，保存只允许写入 `res://assets/visual_profiles/`；
- 一键创建独立 Profile 副本、自动将共享 Profile 转为实例独立资源、批量替换等功能**尚未实现**，不要假定存在相关按钮或菜单。

张梓涵**不应**被要求：编写 GDScript；手动维护复杂 Dictionary；修改底层 Registry；手写 UID；直接编辑资源文本；用 `Node.name` 管理对象身份。

---

# 7. 水晶美术替换

普通水晶 Profile 至少包含：

```text
unlit
lit
```

替换步骤：

1. 打开普通水晶视觉 Profile；
2. 给 `unlit` 设置未点亮图；
3. 给 `lit` 设置点亮图；
4. 保存；
5. 运行；
6. 验证点亮；
7. 按 R；
8. 验证恢复。

完整版本的其他水晶也沿用同一方式，通过状态 ID 或专用 Profile 管理（以下为未来美术需求，**不在当前必测清单**）：

- 光线水晶；
- 光粒水晶；
- 红色水晶；
- 绿色水晶；
- 蓝色水晶；
- 同时组成员；
- 顺序组成员。

禁止通过修改图片文件名改变水晶逻辑。

---

# 8. 镜面美术替换

基础单格镜面状态：

```text
slash      = /
backslash  = \
```

Profile 包含：

- `/` 世界图；
- `\` 世界图；
- 拖拽图；
- 机关栏图标。

替换后必须验证：

- 初始朝向；
- 右键切换；
- 图像方向；
- 反射方向；
- 拖拽预览；
- 机关栏图标；
- R 后状态。

不要将 `/` 和 `\` 接反。

---

# 9. 光线路段美术替换

光线路段 Profile 使用四种图片：

```text
horizontal_texture
vertical_texture
slash_texture
backslash_texture
```

对应：

```text
水平        -
垂直        |
左下到右上  /
左上到右下  \
```

替换后测试：

- 水平传播；
- 垂直传播；
- 两种斜向；
- 镜面转向；
- 连续路径；
- 格内居中；
- 路径显示和清理。

---

# 10. 发射器美术和配置

> **状态：部分实现。** `FixedEmitter`（`gameplay/mechanisms/emitters/fixed_emitter.gd`）为运行期 cell/direction/光形态唯一所有者，由核心 `_ready` 从 `EmitterConfigNode` 启动快照构造，`build_fire_request` 构建 `FireRequest`。`EmitterConfigNode`（`@tool`，`extends GridPlacedObject`）已实现，是发射器关卡配置唯一来源：`default_light_form`、`allow_form_switch`（M4-E4）、`ray_default_direction`（光线八方向）、`particle_default_direction`（光粒八方向，已实现）、`visual_profile: ObjectVisualProfile`、`editor_preview_visible`。`EmissionPreview` 已实现，跟随 Emitter 移动和方向变化，仅编辑器预览，不参与玩法判定，不复制完整传播算法。`LightPathLayer` 独立、固定原点，只承载运行时真实光路，已在核心原型场景存在。结构 `RuntimeObjects/Emitter/{EmitterVisual, EmissionPreview}` 已落地。`CoreLoopPrototype.emitter_cell`/`emitter_direction` 双事实已删除。发射器视觉复用通用 `ObjectVisualProfile`（`assets/visual_profiles/emitter_visuals.tres`）。仍为目标：`fixed_emitter.tscn` 独立预制场景、统一 `EmissionRequest`。光粒运行时与 Particle 八方向已实现（B3b 起 `PARTICLE` 经 `ParticleScheduler` 接正式运行时，八方向）。`EmissionPreview` 不是正式运行光线。

固定发射器目标上包含：

- `cell`；
- 八方向（RAY/PARTICLE 均已八方向且已接正式运行时）；
- 光形态；
- 发射器视觉 Profile；
- 视觉子节点。

## 10.1 两种形态

Profile 至少包含：

```text
ray_texture
particle_texture
```

## 10.2 一张图片旋转

每种光形态使用一张基础方向图。RAY/PARTICLE 均已八方向且已接正式运行时。

建议原图朝右：

| 逻辑方向 | 视觉旋转 |
|---|---:|
| 右（RIGHT） | 0° |
| 右下（DOWN_RIGHT） | 45° |
| 下（DOWN） | 90° |
| 左下（DOWN_LEFT） | 135° |
| 左（LEFT） | 180° |
| 左上（UP_LEFT） | 225° |
| 上（UP） | 270° |
| 右上（UP_RIGHT） | 315° |

只旋转视觉子节点，不旋转发射器逻辑根节点。

## 10.3 Inspector 配置

发射器节点（`EmitterConfigNode`，`extends GridPlacedObject`）在 Inspector 中配置：

- `position`（场景编辑事实，`cell` 由其派生，不需手填 `cell`）；
- `default_light_form`（`RAY` / `PARTICLE`，当前仅 `RAY` 接运行时）；
- `ray_default_direction`（光线八方向）；
- `particle_default_direction`（光粒四方向；当前实现，PARTICLE 八方向为最终目标尚未实现）；
- `visual_profile`（`ObjectVisualProfile`）；
- `editor_preview_visible`。

移动和复制后无需修改核心脚本。

---

# 11. 墙体与 TileSet

## 11.1 普通墙体

大量普通墙体通过：

```text
WallLayer
```

绘制。

墙体规则来自 Tile 自定义数据，例如：

```text
blocks_ray
blocks_particle
is_destructible
```

具体字段由项目最终接口统一提供，美术和关卡人员只在 TileSet 中配置，不在关卡脚本中写判断。

## 11.2 装饰

装饰放在：

```text
DecorationLayer
```

装饰不得承担隐藏阻挡或目标规则。

---

# 12. 可放置区域

玩家允许放置机关的区域通过：

```text
LegalAreaLayer
```

绘制。

最终操作：

1. 选择合法区域 Tile；
2. 在需要允许放置的格子上绘制；
3. 擦除不允许区域；
4. 运行关卡；
5. 测试预览和放置反馈。

合法区域与普通地面不是同一概念。地面存在不代表一定允许放置。

---

# 13. 固定对象的移动

> **状态：当前可用（Godot 原生）+ 方法 B 单格已完成。** 节点拖动、复制、64×64 网格吸附、position Undo/Redo 由 Godot 原生负责；`GridPlacedObject` 位置契约已实现（`position` 为事实、`cell` 派生），方法 B 单格路径（拖动后把最终位置写回逻辑 cell）已完成（D5）。多格对象编辑与父节点移动时视觉/碰撞/方向/光路配置一致性完整流程仍为目标，多格场景下不要假定拖动后所有派生配置已自动完整写回。

目标操作：

1. 在场景树选中发射器、水晶或预置机关根节点；
2. 在 2D 视图拖动；
3. 松开（Godot 原生 64 格吸附）；
4. 检查 Inspector 的 `position` 与 `cell`；
5. 保存；
6. 运行校验（D6 落地后）。

禁止：

- 只移动 `Artwork`；
- 只移动阴影；
- 只移动碰撞或反馈层；
- 修改内部子节点位置代替移动根节点；
- 输入任意小数世界坐标；
- 缩放根节点修正错位。

---

# 14. 固定对象的复制

> **状态：当前可用（Godot 原生）+ 目标校验未实现。** 复制与 64 格吸附由 Godot 原生负责；运行时注册器校验依赖 `LevelObjectRegistry` 完整扫描（`LevelValidator` v0 已实现 D6，但 `LevelObjectRegistry` 仅实现水晶双向索引、完整扫描仍为目标）。张梓涵当前可复制对象节点，但不得依赖注册器自动校验。复制生成稳定 ID 的自动化能力尚未实现，需按显式字段（如 `crystal_id`）手工配置，不用 `Node.name` 作为正式 ID。

目标操作：

1. 在场景树选中对象根节点；
2. 使用 `Ctrl + D`；
3. 重命名副本；
4. 拖动到目标格（Godot 原生 64 格吸附）；
5. 检查 `position` 与 `cell`；
6. 检查方向、形态和目标配置；
7. 保存；
8. 运行关卡校验（D6 落地后）。

复制后检查：

- 节点名；
- `cell`；
- 方向；
- 光形态；
- Profile；
- 是否必需目标；
- 组 ID；
- 顺序编号；
- 其他 Inspector 参数。

运行时注册器会检查（目标 / 未实现，`LevelObjectRegistry` + `LevelValidator`（D6）落地后生效）：

- 越界；
- 重复占用；
- 缺少主发射器；
- 多个主发射器；
- 固定对象冲突；
- 缺少资源；
- 无效配置。

---

# 15. 多格机关

> **状态：公共占用接口已冻结并落地；正式多格机关子类与方法 B 多格编辑尚未实现。** `get_occupied_offsets(p_orientation: int = 0)` 与 `get_occupied_cells(anchor_cell: Vector2i, p_orientation: int = 0)` 已冻结并落地于 `GridPlacedObject` 基类（单格默认 `[Vector2i.ZERO]`）；`anchor_cell` 是查询参数或由根 `position` 派生，不是持久化的第二位置事实。正式多格机关子类、多格旋转占用，以及关卡编辑方法 B 多格编辑尚未完整实现（方法 B 单格已完成）。

多格机关目标上使用：

```text
anchor_cell
occupied_offsets
```

例如横向两格机关：

```text
anchor_cell = (4, 3)
occupied_offsets = [(0, 0), (1, 0)]
```

移动时只拖动根节点，系统根据锚点计算全部占用格。

关卡人员不得手工维护每一个占用格坐标。

---

# 16. 关卡目录

```text
levels/
├─ templates/
│  └─ level_template.tscn
├─ prototypes/
│  ├─ mechanics/
│  ├─ combinations/
│  └─ graybox/
└─ campaign/
   ├─ particle_chapter/
   ├─ ray_chapter/
   └─ mixed_chapter/
```

---

# 17. 关卡模板

> **状态：目标 / 未实现。** `levels/templates/level_template.tscn` 当前不存在，完整正式关卡模板未实现，仅存在核心原型场景。以下结构为目标契约，**不得把示例节点名写成当前已冻结实现**；当前不能从完整模板复制正式关卡。

新关卡目标上从：

```text
levels/templates/level_template.tscn
```

复制。

模板包含：

- `TerrainLayer`；
- `WallLayer`；
- `LegalAreaLayer`；
- `DecorationLayer`；
- 固定对象容器；
- 玩家运行时对象容器；
- 光视觉容器；
- 关卡对象注册器；
- 关卡校验器；
- 目标控制器；
- UI 和开始运行按钮；
- 关卡库存配置；
- 运行期移动配置。

不要直接修改模板制作某一正式关卡。

---

# 18. 单机关原型

保存：

```text
levels/prototypes/mechanics/
```

用途：

- 验证一个机关的完整规则；
- 检查视觉；
- 检查方向；
- 检查合法和非法入射；
- 检查重置；
- 供玩法和技术人员共同验收。

命名：

```text
mirror_basic_prototype.tscn
particle_accelerator_prototype.tscn
particle_decelerator_prototype.tscn
```

---

# 19. 机关组合原型

保存：

```text
levels/prototypes/combinations/
```

用途：

- 验证多个机关组合；
- 判断是否有解谜价值；
- 发现规则歧义；
- 测试视觉反馈；
- 为正式关卡积累组合。

命名：

```text
particle_speed_wall_combo.tscn
ray_mirror_crystal_combo.tscn
splitter_filter_combo.tscn
```

组合原型应记录：

- 使用机关；
- 目标；
- 预期解；
- 替代解；
- 已知问题；
- 是否进入正式关卡。

---

# 20. 灰盒关卡

保存：

```text
levels/prototypes/graybox/
```

灰盒关卡要求：

- 有明确目标；
- 有基本解法；
- 能运行；
- 能重置；
- 使用当前稳定机关；
- 已配置库存和移动次数。

可以暂时缺少：

- 正式美术；
- 章节装饰；
- 完整教学；
- 声音；
- 成就内容。

---

# 21. 正式关卡

保存：

```text
levels/campaign/
├─ particle_chapter/
├─ ray_chapter/
└─ mixed_chapter/
```

章节结构固定：

1. 光粒章节；
2. 光线章节；
3. 光粒与光线混合章节。

命名示例：

```text
particle_level_01.tscn
ray_level_01.tscn
mixed_level_01.tscn
```

正式关卡必须：

- 使用稳定模块；
- 通过关卡校验；
- 可完成；
- 可重置；
- 有预期解；
- 无明显死局；
- 无明显越权捷径；
- 有教学或提示；
- 使用正式或可接受视觉；
- 不修改核心脚本。

---

# 22. 标准关卡制作流程

> **状态：基础已完成，多格/自动校验为目标。** 正式关卡模板（D5）、`LevelValidator` v0（D6）、方法 B 单格路径（2D 视图直接拖动编辑与位置写回）均已完成。多格对象完整编辑流程、Runtime 自动 Validation Gate（运行期自动调用 `LevelValidator`）仍为目标。节点拖动/复制/64 格吸附由 Godot 原生负责。张梓涵当前可在已实现模板与原型场景内进行美术替换与基础配置验证；以下为完整目标流程，待方法 B 多格编辑、Runtime 自动 Validation Gate 等落地后方可完整执行。

```text
确定章节和机制
→ 复制关卡模板
→ 保存到正确目录
→ 绘制TerrainLayer
→ 绘制WallLayer
→ 绘制LegalAreaLayer
→ 绘制DecorationLayer
→ 放置发射器
→ 放置水晶
→ 放置预置机关
→ 配置发射器方向和光形态
→ 配置机关栏
→ 配置运行期移动次数
→ 配置目标
→ 运行LevelValidator
→ 人工测试
→ 记录解法和问题
→ 保存并提交
```

---

# 23. Inspector 中会使用的主要配置

关卡根节点：

- 关卡 ID；
- 章节；
- 标题；
- 运行期移动次数；
- 机关栏配置；
- 是否启用光形态切换；
- 教学提示；
- 成就绑定。

发射器：

- `cell`；
- `facing`；
- `light_form`；
- Profile。

水晶：

- `cell`；
- 所需光形态；
- 所需颜色；
- 是否必需；
- 组 ID；
- 顺序编号；
- Profile。

机关：

- `cell`；
- 方向；
- 占用范围；
- 状态；
- 是否允许运行期移动；
- Profile。

---

# 24. 关卡运行校验

> **状态：v0 已实现 / 自动门未实现。** `LevelValidator` v0（D6，PR #45–#48）只读结构化校验已实现，可经测试/headless 运行；Runtime 自动 Validation Gate（保存或运行期自动调用）未实现，**不能作为当前保存或验收的自动必跑步骤**。以下校验内容为长期设计，最终以真实实现为准。

保存关卡前目标上运行校验器。

校验内容：

- 地图边界；
- 合法区域；
- 发射器数量；
- 对象越界；
- 固定对象重复占用；
- 多格占用冲突；
- 水晶配置；
- 组 ID；
- 顺序编号；
- 机关栏定义；
- 缺失视觉 Profile；
- 缺失纹理；
- 无效方向；
- 必需目标数量。

校验器只报告问题，不自动修改关卡。

---

# 25. 美术替换检查清单

> 本清单中"发射器图片基础方向一致""光线和光粒外观不同"两项依赖发射器正式接口；`EmitterConfigNode` 已实现，但 `PARTICLE` 光粒运行时与统一 `EmissionRequest` 仍为目标，故光粒外观项属目标项；其余 64×64、Nearest、透明背景、锚点、世界/UI 图标分离、Profile 状态 ID、镜面 `/\\`、光线路段四方向、拖拽图、机关栏图标、R 后视觉恢复等为当前可用项。

- [ ] 素材放在正确目录；
- [ ] 文件名规范；
- [ ] 画布正确；
- [ ] 内容居中；
- [ ] 背景透明；
- [ ] 使用 Nearest；
- [ ] 世界纹理和 UI 图标分开；
- [ ] Profile 状态 ID 未修改；
- [ ] 镜面 `/` 和 `\` 未接反；
- [ ] 光线路段四方向未接反；
- [ ] 发射器图片基础方向一致；
- [ ] 光线和光粒外观不同；
- [ ] 水晶点亮状态清楚；
- [ ] 拖拽图正常；
- [ ] 机关栏图标正常；
- [ ] R 后视觉恢复；
- [ ] 未修改核心脚本。

---

# 26. 关卡检查清单

## 地图

- [ ] 三个玩法层和装饰层使用正确；
- [ ] 地图形状正确；
- [ ] 墙体正确；
- [ ] 可放置区域正确；
- [ ] 装饰不影响逻辑；
- [ ] 无越界；
- [ ] 无重复占用。

## 发射器

- [ ] 位置；
- [ ] 方向；
- [ ] 光形态；
- [ ] 视觉；
- [ ] 不可由玩家移动。

## 水晶与目标

- [ ] 位置；
- [ ] 条件；
- [ ] 是否必需；
- [ ] 组和顺序；
- [ ] 点亮；
- [ ] R 恢复；
- [ ] 通关。

## 机关栏

- [ ] 种类；
- [ ] 数量；
- [ ] 图标；
- [ ] 放置；
- [ ] 移动；
- [ ] 回收；
- [ ] 重置。

## 运行（目标 / 未实现，不在当前验收项）

> `READY_TO_FIRE`、开始运行按钮与光粒运行时均已实现（D7-2/D7-3、D7-4），相关运行行为已可验证，但仍**不作为张梓涵当前验收项**（美术验收范围以已实现视觉接口的素材替换为准）。`EmitterConfigNode`/`EmissionPreview` 已实现。

- [ ] 初始 Space 无效；
- [ ] 点击“开始运行”；
- [ ] 进入 `READY_TO_FIRE`；
- [ ] Space 发射；
- [ ] 配置锁定；
- [ ] 布局仍可编辑；
- [ ] 移动次数正确；
- [ ] 完成后冻结；
- [ ] R 返回 `SETUP`。

---

# 27. 关卡记录

每个灰盒或正式关卡至少记录：

```text
关卡名称
所属章节
主要机制
使用机关
发射器配置
关卡目标
玩家库存
运行期移动次数
预期解法
允许的替代解法
已知问题
所需美术
测试日期
测试人员
```

记录可以集中在章节说明文档中，也可以在关卡复杂后采用一关一份 Markdown。

---

# 28. 可修改范围

> 注：`levels/templates/` 的授权副本依赖完整关卡模板，当前未实现；其余目录当前可按已实现接口使用。

正常情况下可以修改：

```text
assets/art/
assets/visual_profiles/
assets/level_data/
levels/templates/的授权副本
levels/prototypes/
levels/campaign/
关卡相关.tres
章节独占资源
```

修改公共模板、TileSet、通用 Profile 前需要通知团队。

---

# 29. 禁止修改范围

未经技术负责人明确授权，不修改：

```text
gameplay/core/
gameplay/grid/的核心换算
gameplay/light/common/
gameplay/light/ray/
gameplay/light/particle/
gameplay/placement/
gameplay/inventory/
gameplay/interaction/
gameplay/diagnostics/
gameplay/save/
project.godot中的核心输入、主场景和Autoload
```

不要在正式关卡中修改通用机关场景的内部结构来制造关卡专属规则。

---

# 30. Git 工作方式

开始任务前：

```powershell
git switch main
git pull --ff-only origin main
git switch -c <规范分支名>
```

分支类型：

```text
art/<个人标识>-<任务>
level/<个人标识>-<任务>
```

提交前：

- 运行 Godot；
- 运行目标关卡；
- 查看 Output 和 Debugger；
- 运行关卡校验；
- 查看 `git diff`；
- 确认没有日志和临时导出包；
- 确认没有无关核心代码修改。

AI 不执行 Git 写操作。

---

# 31. 发生问题时的反馈格式

必须提供：

```text
场景路径
对象名称
操作步骤
预期行为
实际行为
是否可重复
Godot Output
Debugger错误
截图
当前分支
当前提交
```

示例：

```text
场景：levels/prototypes/graybox/graybox_particle_001.tscn
对象：ParticleAccelerator
操作：复制后拖动到(5,3)
预期：Godot 原生吸附到 64 格，cell 由 position 派生为(5,3)
实际：视觉正确，但 cell 仍为(4,3)
是否可重复：每次都能复现
```

---

# 32. 最终完成标准

> 本节描述的是接口完成后的**目标最终标准**，其中方法 B 多格编辑、三章节正式关卡制作等当前未实现（方法 B 单格、`LevelValidator` v0、Runtime 自动 Validation Gate（D7-1/D7-3）、`READY_TO_FIRE`/开始运行入口（D7-2/D7-3）、光粒运行时（D7-4）已完成）。`GridPlacedObject` 位置契约、`EmitterConfigNode`/`EmissionPreview`、美术 Profile 插件已实现。节点拖动/复制/64 格吸附由 Godot 原生负责。张梓涵当前可执行的部分为已实现视觉接口的美术替换（含插件）、发射器配置与原型场景验证。

最终编辑方式目标上必须达到：

```text
不修改核心脚本
→ 可以导入和替换美术
→ 可以配置视觉Profile
→ 可以绘制地图、墙体和合法区域
→ 可以拖动、复制和配置固定对象（Godot 原生 64 格吸附）
→ 可以配置库存、目标和运行期移动
→ 可以制作机关原型和组合原型
→ 可以制作三章节灰盒和正式关卡
→ 可以运行校验（D6 LevelValidator）和人工测试
→ 可以独立提交关卡与美术任务
```

本指南描述的是项目完成编辑器接口后的正式工作流。开发过程中若最终 Inspector 字段名或少量目录名发生调整，应同步更新本指南，但不得改变“GUI 编辑、`GridPlacedObject` 位置契约（`position` 为事实、`cell` 派生，已实现）、Godot 原生 64 格吸附、Profile 替换、关卡校验、无须修改核心脚本”这组固定原则。运行时代码不依赖 `addons/`，唯一正式插件 `addons/light_speed_art_profile/` 关闭后游戏正常运行。
