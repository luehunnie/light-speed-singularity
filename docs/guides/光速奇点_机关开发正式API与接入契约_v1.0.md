# 《光速奇点》机关开发正式 API 与接入契约 v1.0

> 状态：**设计冻结 / Implementation Baseline**  
> 日期：2026-08-17  
> 代码调查基线：`main@2a9bc02`  
> 适用范围：机关开发、Objective Target、Main Emitter、Inventory、Placement、Control、Validator、Visual、Testing 与 Godot GUI 无代码内容生产工具链  
> 性质：本文件冻结“下一阶段需要实现什么 API、边界是什么、谁可以依赖什么”。**不是代码实现文档，也不要求当前仓库已经具备全部能力。**

---

## 0. 文档地位

本文件由以下三部分共同收口：

1. `《光速奇点》机关开发 API / 公共接口底审 Evidence Packet v1.0`；
2. `《光速奇点》Godot GUI 无代码关卡 / UI 内容生产工作流冻结总结 v1.0`；
3. 本轮 Q01～Q38 的逐题人工冻结，以及用户授权后对 Q39 之后剩余问题按推荐方案进行的统一收口。

后续机关 API、关卡作者工具、Runtime 接入和相关正式文档若与本文冲突，原则上应先回到本文重新裁决，而不是在实现中自行形成第二套规则。

---

# 1. 总目标

最终希望潘陈俣开发一个普通新机关时，只需要：

```text
拿到正式机关规则
↓
实现自己的 Typed Configuration / Runtime Behavior
↓
提供 PackedScene
↓
提供 Formal Content Definition
↓
提供必要 Visual / Validator Extension
↓
编写 Contract Test + Mechanism Test
↓
完成
```

理想情况下**不需要修改**：

- `LevelRuntimeController`；
- Ray / Particle Executor；
- CoreLoop 类型分支；
- Inventory 类型名单；
- Content Palette 类型名单；
- Objective Editor 类型名单；
- Validator 类型名单；
- DragFlow 机关白名单；
- Runtime Factory 白名单；
- OccupancyRegistry 内部逻辑；
- RunStateController；
- Scheduler；
- SceneTree 固定层级。

核心评价指标：

> **新增普通机关应尽量接近“新增声明 + 自身实现 + 自身测试”，而不是同步修改五六个共享系统。**

---

# 2. 非目标与禁止事项

本轮明确不建设：

- 万能 `BaseMechanism`；
- 万能 `UniversalContext`；
- 万能 `UniversalResult`；
- 全局自由 Event Bus；
- Blueprint / Visual Scripting；
- 任意 JSON / Dictionary 数据流；
- 自由脚本条件；
- ECS；
- 复杂依赖注入框架；
- 反射式“扫描全部 @export 自动成为 Designer API”；
- 机关直接扫描 SceneTree；
- 机关直接访问 Scheduler / RuntimeController；
- Content Palette / Inventory / Objective / Validator 各维护一份机关名单；
- Visual Geometry 反向决定 Gameplay Occupancy；
- 为尚未冻结的 Split / Color / Form Converter 玩法提前制造大型通用解释器。

---

# 3. 总体架构

正式 API 分成三大域：

```text
A. Authoring Declaration API
   → 这个正式内容是什么、工具可以怎样使用它

B. Runtime Interaction API
   → 光 / Objective / Control 与内容怎样发生局部交互

C. Runtime Infrastructure API
   → 身份、发现、Registry、Inventory、Placement、Reset、Validator、Testing
```

并继续服从 Godot GUI 工具链的五包架构：

```text
light_speed_authoring_core
light_speed_visual_workbench
light_speed_level_authoring
light_speed_ui_authoring
light_speed_validator
```

其中 `Formal Content Declaration` 是所有作者工具共享的唯一类型能力事实源。

---

# 4. Formal Content Definition

## 4.1 类型层级

冻结为：

```text
FormalContentDefinition
├─ MechanismDefinition
├─ ObjectiveTargetDefinition
└─ EmitterDefinition
```

这是**职责层级**，不强制最终 GDScript 必须采用深继承。

### `FormalContentDefinition` 只承载真正共享的类型级事实

至少包括概念上的：

- Stable `content_type_id`；
- `display_name`；
- `category`；
- `PackedScene`；
- 预放置能力；
- Visual Definition / Slot 声明；
- Stable Instance 支持；
- Editor Note 支持；
- 共享作者工具元数据。

### `MechanismDefinition`

可进一步声明：

- 是否 `inventory_eligible`；
- Inventory Spawn Default Configuration；
- Inventory Spawn Interaction Profile；
- Preplaced Default Interaction Profile；
- Allowed Interaction Profiles；
- Light Interaction Capability；
- 支持的 Light Forms；
- Placement / Footprint 能力；
- Player Interaction Actions；
- Level-editable Fields；
- Output Events；
- Control Actions；
- Runtime State Capability；
- Validator Extension；
- Visual semantic slots / states。

### `ObjectiveTargetDefinition`

声明：

- Objective Target Capability；
- Base Success；
- Allowed Objective Condition Types；
- Level-editable target configuration；
- visual / authoring 信息。

### `EmitterDefinition`

声明：

- Main Emitter 类型；
- Allowed Forms；
- Allowed Directions；
- Initial Form；
- Initial Direction；
- Particle Initial Speed；
- 其它已经冻结的发射器作者能力。

---

## 4.2 Definition 的边界

Definition 可以声明：

> **“我有什么能力。”**

但不能保存：

> **“这个能力具体怎样算。”**

例如速度监测器可以声明：

```text
Light Interaction: RAY + PARTICLE
Control Source: true
Output Event: speed_matched
```

但以下具体算法仍属于机关脚本：

```text
是否沿通道轴进入
当前速度是否匹配
不匹配时是否继续
```

因此正式分层为：

```text
Definition
→ 类型能力与作者元数据

Mechanism Script
→ 具体玩法算法

Level Instance Configuration
→ 本关该实例的作者配置

Runtime State
→ 当前一轮的动态事实
```

---

# 5. Formal Content Discovery

## 5.1 单一 Discovery Pipeline

Formal Definitions 自动进入统一 Discovery Pipeline：

```text
Definitions
↓
Discovery + Contract Validation
↓
Formal Content Registry
↓
Palette / Inventory / Objective / Control / Validator / Runtime Spawn / Visual Workbench
```

冻结原则：

```text
Definition = Truth
Registry   = Index
```

Registry 不得复制 Definition 中的能力元数据。

## 5.2 不维护第二张人工 Catalog

新增正式类型时不得要求同时修改：

- 中央手写类型数组；
- Inventory 白名单；
- Palette 白名单；
- Validator 白名单；
- Runtime Factory 白名单。

实现阶段可以使用 Editor 扫描、自动生成 Manifest / Cache 或其它 Godot 合理方案，但**发现结果不能依赖第二份人工类型名单**。

## 5.3 Discovery 必须检测

至少：

- 重复 `content_type_id`；
- Definition 非法；
- PackedScene 缺失；
- Definition 与实现 Contract 不一致；
- 声明支持某能力但实现缺失；
- 稳定 Field / Event / Action ID 冲突。

---

# 6. 身份体系

## 6.1 两层正式对象身份

正式内容对象只保留两层：

```text
Content Type ID
→ “这是什么类型？”

Stable Instance ID
→ “这个具体实例是谁？”
```

不增加第三个通用 Runtime Object ID。

## 6.2 Light Runtime 身份独立

光传播域独立使用：

```text
runtime_generation
emission_id
particle_runtime_id
```

它们不得代替 Stable Instance ID。

## 6.3 禁止作为正式身份

- `Node.name`；
- `NodePath`；
- 网格坐标；
- 显示名称；
- 数组索引；
- SceneTree 固定层级；
- 手写 `crystal_id`。

## 6.4 Formal Content Instance Binding

每个正式空间实例使用一个**薄、组合式**的 Formal Content Instance Binding / Identity Component：

```text
content_type_id
stable_instance_id
```

该 Binding 不负责玩法、Placement、Objective、Control、Visual 或 Runtime State。

实现可以是薄组件、内嵌 Resource 或其它低污染方案；不强制可见 Child Node。

---

# 7. Stable Instance ID 生命周期

### 保持 ID

- 移动；
- 旋转；
- 修改 Editor Note；
- 改 Node.name；
- 修改合法实例配置；
- 保存 / 重新打开。

### 产生新 ID

- Content Palette 新建；
- Ctrl+D 复制；
- Duplicate as New Level；
- Inventory Runtime Spawn。

### Inventory Recover

```text
Recover 成功
→ 原实例生命周期结束
→ 原 Stable ID 失效
→ 数量归还 type_id pool
```

再次 Spawn：

```text
→ 新 Formal Instance
→ 新 Stable Instance ID
```

### Reset

预置对象恢复其**关卡初始 Stable ID**；玩家动态 Spawn 实例清除。

---

# 8. Formal Object Registry

## 8.1 统一正式世界对象索引

所有正式空间对象进入统一 Formal Object Registry：

- 预置 Mechanism；
- 玩家 Spawn Mechanism；
- Objective Target；
- Main Emitter；
- 其它正式空间内容。

Registry 负责：

> “现在世界里有哪些正式对象、它们是谁、属于什么类型、在哪里。”

## 8.2 Placement / Occupancy 不是 Registry

职责严格分开：

```text
Formal Object Registry
= 对象身份 / 类型 / 位置索引

Placement / Occupancy
= 空间合法性与玩家放置事务

WorldQuery
= Runtime Infrastructure 的只读世界查询
```

不得把 OccupancyRegistry 扩展成万物 Registry。

## 8.3 Light propagation 的统一发现

预置机关和玩家机关一旦进入 Runtime World，对光传播层没有“来源特权”。

传播系统：

```text
WorldQuery
→ 找到当前格正式对象
→ 查询 Definition Capability
→ 调正式 Interaction Contract
```

不能只通过 PlacementController 找机关。

---

# 9. Interaction Profile 与运行期权限

## 9.1 一个 Definition，多种实例角色

同一种机关不因为：

- Fixed；
- Movable；
- Recoverable；
- Inventory Spawn；
- Preplaced；

而复制 Definition / Scene。

使用：

```text
Mechanism Capability
↓
Interaction Profile
↓
Runtime Interaction Permission
```

## 9.2 Interaction Profile

回答：

> “作者允许玩家对这个实例使用哪些已有能力？”

Profile 只能缩权限，不能创造 Definition 没有的能力。

例如可表达：

- `FIXED`；
- `MOVABLE_PREPLACED`；
- `PLAYER_TOOL`；

最终具体命名可实现期确定。

## 9.3 Profile ≠ Runtime State

Profile 不随 `SETUP / PULSE_ACTIVE / MOVE_WINDOW` 自动切换。

运行时“此刻是否允许操作”由统一 Runtime Interaction Permission 判断。

---

# 10. Runtime Interaction Permission

普通机关不得自行读取 `RunStateController` 决定玩家权限。

统一入口根据：

- Definition capability；
- Interaction Profile；
- RunState；
- Level General Rules；
- Move Budget；
- 当前实例状态；

返回：

```text
PermissionResult
- allowed
- machine-readable reason
```

典型拒绝原因可包括：

```text
COMPLETED_LOCKED
PROFILE_FORBIDS_ACTION
CONFIGURATION_LOCKED
MOVE_BUDGET_EXHAUSTED
INVALID_TARGET
```

Runtime UI、Input、测试统一消费该结果。

---

# 11. Typed Configuration

## 11.1 每种机关拥有自己的 Typed Configuration

示意：

```text
SingleCellMirrorConfiguration
- orientation

AcceleratorConfiguration
- direction

SpeedDetectorConfiguration
- direction
- target_speed
```

公共系统不得把配置退化成自由 `Dictionary`。

## 11.2 配置三层

```text
Type Default
↓
Preplaced Instance Override
↓
Runtime State（若有）
```

Inventory Spawn 使用全局类型 / Inventory Spawn 默认配置；关卡 Inventory Entry 不允许私自覆盖 Spawn 初始配置。

## 11.3 Stable Configuration Field ID

正式作者字段分成：

```text
Internal Member Name
→ 实现细节

Stable Field ID
→ 内容 Schema 身份

Display Name
→ 作者界面名称
```

Definition 引用 Stable Field ID，不直接把内部 GDScript property path 当长期契约。

## 11.4 Level-editable Fields

只有 Definition 显式声明的字段才能成为正式 Designer API。

每个字段至少具备：

- Stable Field ID；
- display name；
- typed value；
- enum / range（需要时）；
- default；
- validation；
- profile visibility / restriction（需要时）。

`@export` 本身不等于“正式作者字段”。

---

# 12. Player Interaction Action

玩家修改机关内部状态采用有限、Typed 的 Player Interaction Action。

当前核心语义可包括：

```text
CYCLE_DIRECTION
CYCLE_INTERNAL_STATE
```

`MOVE / RECOVER` 主要属于 Placement / Inventory Infrastructure。

Runtime UI：

```text
Input
→ Action Request(target Stable ID, action)
→ Permission
→ Mechanism proposes Candidate Configuration
→ Placement validation（若 footprint 变化）
→ Atomic Commit
```

禁止：

- Runtime UI `if target is SingleCellMirror`；
- 任意字符串方法名；
- `call(method_name)`；
- 任意参数 `Dictionary`。

Player Interaction Action 与 Control Action 是两个不同 API 域。

---

# 13. Placement Footprint Contract

## 13.1 Gameplay Occupancy 不从 Visual 推导

禁止使用：

- Sprite 尺寸；
- CollisionShape；
- 美术节点位置；

推导逻辑占格。

## 13.2 统一 Footprint Contract

简单机关：

```text
Static Footprint
→ [(0,0)]
```

动态占格机关：

```text
Typed Configuration
→ Pure Footprint Provider
→ occupied_offsets
```

Footprint 计算必须：

- 纯函数；
- 无 WorldQuery；
- 无 SceneTree；
- 无 Runtime State；
- 无副作用。

## 13.3 Anchor / Pivot

Definition 仍可以声明：

- Logical Anchor；
- Rotation Pivot；
- Supported Directions；
- 静态 shape 信息。

动态具体 offsets 由 Footprint Contract 计算。

---

# 14. Candidate State → Validation → Atomic Commit

所有会改变：

- 位置；
- Configuration；
- Footprint；
- Occupancy；

的玩家操作都统一使用：

```text
Request
→ Permission
→ Candidate State
→ Candidate Footprint
→ Shared Placement Query
→ Atomic Commit / Reject
```

禁止常规路径：

```text
先修改真实 Node
→ 再检测
→ 失败后 Rollback
```

非法操作：

- Configuration 不变；
- Occupancy 不变；
- Registry 不变；
- Visual gameplay state 不变；
- 返回 machine-readable reason。

这套事务同时覆盖：

- Existing instance move；
- 双格镜旋转；
- 单格机关改方向；
- Inventory Spawn placement；
- Recover。

---

# 15. Inventory API

## 15.1 Authoring Entry

每关 Inventory Entry 只保存：

```text
content_type_id
initial_quantity
order
```

显示名、图标、描述、默认状态来自 Definition。

## 15.2 Runtime 数量池

关卡只有一个 `LevelInventoryRuntime`：

```text
content_type_id → remaining_quantity
```

Inventory 不保存 Stable ID 列表，不保存隐藏实例对象池。

## 15.3 Spawn

统一链：

```text
type_id
→ Formal Content Registry
→ MechanismDefinition
→ PackedScene
→ Type Default Configuration
→ Inventory Spawn Interaction Profile
→ Generic Spawn / Placement
```

## 15.4 Recover

Recover 成功后：

```text
Occupancy 注销
Formal Object Registry 注销
正式实例结束
Stable ID 生命周期结束
type_id 数量 + 1
```

失败则什么都不改变。

---

# 16. Inventory Drag Reservation（自动冻结 Q39）

> 本项在用户授权“后续全部按推荐方案”后自动冻结。

Inventory Drag Start **不立即创建正式机关**。

正式流程：

```text
Drag Start
→ Reserve 1 unit
→ Candidate Preview
→ Placement Query
```

Preview：

- 没有 Stable Instance ID；
- 不是 Formal Object；
- 不进入 Formal Object Registry；
- 不进入正式 Occupancy；
- 只拥有 Definition、Candidate Configuration、Footprint 与 Preview Visual。

取消 / 非法：

```text
Release reservation
→ 不产生正式实例
→ 不消费 Stable ID
```

合法 Placement Commit：

```text
确认 reservation
→ instantiate PackedScene
→ 生成 Stable ID
→ 应用 default config/profile
→ 注册 Registry
→ 提交 Occupancy
→ 正式消耗 quantity
```

Existing Instance Drag 不使用新 ID，整个 Move Transaction 保持原 Stable ID。

---

# 17. Shared Placement Query

Editor、Runtime、Validator 共用同一个正式空间规则源。

结果不能只返回 Bool，应返回：

```text
PlacementQueryResult
- allowed
- issues / reason codes
```

典型 reason：

```text
OUTSIDE_TERRAIN
NOT_IN_LEGAL_AREA
WALL_BLOCKED
OBJECT_OCCUPIED
SHAPE_OUT_OF_BOUNDS
```

同一规则只实现一次。

---

# 18. 八方向公共 API

建立唯一八方向 Domain：

```text
RIGHT
DOWN_RIGHT
DOWN
DOWN_LEFT
LEFT
UP_LEFT
UP
UP_RIGHT
```

公共纯函数至少包括：

```text
is_valid()
to_vector()
from_vector()
rotate_clockwise()
rotate_counterclockwise()
opposite()
is_orthogonal()
is_diagonal()
same_axis()
```

全局顺时针顺序只有一份。

若 Allowed Directions 是子集，循环按照全局顺序跳过禁止方向。

具体镜面反射、双格镜几何等仍属于机关自身规则，不进入全局 Direction API。

---

# 19. Light Interaction Context

## 19.1 分层

```text
LightInteractionContext
├─ RayInteractionContext
└─ ParticleInteractionContext
```

不采用一个塞满 nullable 字段的万能 Context。

## 19.2 Shared Facts

当前冻结最小字段：

```text
cell
incoming_direction
light_form
emission_id
runtime_generation
```

## 19.3 Particle-only Facts

```text
speed_tier
particle_runtime_id
```

## 19.4 暂不公开

- WorldQuery；
- SceneTree；
- LevelRuntimeController；
- ObjectiveController；
- Stable Instance ID（target 本身已拥有）；
- previous_cell；
- absolute Scheduler Tick。

---

# 20. 普通机关不得直接访问 WorldQuery

普通机关的运行行为保持局部：

```text
Interaction Context
→ Mechanism
→ Interaction Result
```

WorldQuery 属于 Runtime Infrastructure。

如未来真实冻结机关确需跨格 / 跨对象读取，新增受限 Extension Capability，而不是给全部机关 unrestricted WorldQuery。

---

# 21. Ray / Particle 正式交互入口

正式采用两个对称入口：

```text
interact_ray(ray_context)
interact_particle(particle_context)
```

Definition 声明实际支持的 Light Forms。

正式禁止：

```text
if mechanism is SingleCellMirror
```

作为机关发现逻辑，也不把 `has_method()` 本身当正式 API 契约。

### 未声明某形态

冻结语义：

```text
未声明该 Light Form
= 对该形态透明
= Runtime 不调用对应入口
= 保持传播状态继续
```

例如 Accelerator 可以只声明 PARTICLE interaction；RAY 自动透明通过。

---

# 22. Light Interaction Result

正式结果：

```text
LightInteractionResult
=
1 个 Propagation Decision
+
0..N 个有限 Typed Effects
```

## 22.1 当前 Propagation Decision

```text
CONTINUE
BLOCK
REDIRECT(direction)
```

## 22.2 当前 Typed Effects

```text
PARTICLE_SPEED_DELTA(delta)
OUTPUT_EVENT(event_id)
```

机关只“请求结果”，不直接改 Runtime。

不允许开放任意 Effect 字典或自由命令数组。

---

# 23. Interaction Commit Pipeline

统一时序：

```text
光到达当前格
→ 构造不可变 Context
→ 机关一次计算 Result
→ Runtime 校验 Result
→ 一次提交 Typed Effects
→ 更新后续传播状态
→ 执行 Propagation Decision
→ 调度下一传播步
```

原则：

1. Context 是进入机关时的不可变事实快照；
2. 同一次交互不因中间副作用重新求值；
3. SpeedDelta 从下一传播步影响调度；
4. Output Event 在本次 Commit 中产生；
5. Control 的后续变化不得反向改写已经完成的当前 Interaction Result。

---

# 24. Particle Speed API

机关公开的速度语义只有：

```text
SpeedTier:
SLOW
STANDARD
FAST
```

速度修改当前只允许：

```text
PARTICLE_SPEED_DELTA(+1)
PARTICLE_SPEED_DELTA(-1)
```

机关不得读取或修改：

- raw movement tick；
- Scheduler interval；
- ParticleRuntimeState；
- 正交 / 斜向 Tick 表。

速度实际单一真相继续在 `ParticleMotionRules`：

```text
正交：8 / 4 / 2
斜向：11 / 6 / 3
```

饱和变化继续由 Runtime 应用。

本轮不提前正式化 `SET_SPEED(FAST)`；真实玩法出现后再扩展。

---

# 25. Objective Runtime API

## 25.1 独立 ObjectiveHitContext

Objective 不直接复用 `LightInteractionContext`。

当前最小事实：

```text
cell
light_form
incoming_direction
emission_id
runtime_generation
```

Particle 命中：

```text
speed_tier
```

暂不加入 `particle_runtime_id`。

## 25.2 Target Carrier + Composable Conditions

技术模型：

```text
Objective Target Carrier
+
0..N Objective Conditions
```

空条件：

```text
Base Success
```

因此 Basic Crystal 可以是：

```text
Target Carrier
conditions = []
```

Ray Form Crystal：

```text
Target Carrier
+ FormCondition(RAY)
```

Particle Form Crystal：

```text
Target Carrier
+ FormCondition(PARTICLE)
```

## 25.3 Condition Contract

每种条件具备：

```text
ObjectiveConditionDefinition
ObjectiveConditionConfiguration
Pure ObjectiveConditionEvaluator
```

Evaluator：

```text
configuration + ObjectiveHitContext
→ SATISFIED / NOT_SATISFIED
```

不得：

- 查询 Ray / Particle Runtime；
- 扫 World；
- 修改其它目标；
- 自己完成关卡。

## 25.4 组合语义

单 Target：

```text
不同 Condition → AND
同 Condition Type 最多一次
Condition 内多值由该 Condition 自己定义
空 Conditions → Base Success
```

跨 Target：

```text
Independent
Simultaneous
Sequence
```

由 ObjectiveController 统一管理，不支持任意嵌套布尔表达式。

---

# 26. Control Source / Target API

## 26.1 Runtime 链

```text
Source
→ Typed Output Event
→ Control Dispatcher
→ Source Instance Connections
→ Target Stable ID
→ Typed Control Action
→ Target
```

Source 不解析 Target；Target 不扫描 Source / Connection Graph。

## 26.2 Stable Event / Action ID

Event / Action 必须具有：

```text
Stable event_id / action_id
display_name
typed parameter schema（Action 需要时）
```

内部代码方法名可自由重构，不作为关卡数据身份。

## 26.3 Output Event 无 Gameplay Payload

普通 Output Event 只表达：

> “发生了什么。”

Runtime 最小：

```text
source_stable_id
event_id
runtime_generation
```

Action 参数完全由 Connection 作者期固定配置。

禁止：

- Event payload → Action param mapping；
- 数据转换；
- Dataflow Graph；
- 任意 runtime JSON。

---

# 27. Control Action 与 Runtime State

普通 Control Action 只修改**本轮 Typed Runtime State**。

不能直接修改：

- Typed Configuration；
- Stable ID；
- type_id；
- Inventory；
- Connection；
- Objective Authoring Data；
- 位置 / Occupancy；
- Spawn / Recover。

未来若存在“控制后移动”等已冻结玩法，单独增加受限 Spatial / Configuration Extension，并继续走正式事务。

---

# 28. Typed Runtime State

只有真正有状态的正式内容才拥有自己的 Typed Runtime State。

例如：

```text
GateConfiguration
- initial_open

GateRuntimeState
- current_open
```

无状态机关：

```text
SingleCellMirror
Accelerator
Decelerator
LightBarrier
```

不需要创建空 State 对象。

正式状态转换：

```text
Current Typed Runtime State
+ Typed Control Action
→ Candidate Runtime State
+ Output Events
```

Infrastructure 只搬运与提交，不理解机关内部字段。

---

# 29. Control Dispatch Batch

同一逻辑批次的命令先完整收集，再处理：

```text
Events
→ resolve Connections
→ Commands
→ group by Target Stable ID
→ dedupe
→ conflict resolution
→ Target Resolution
→ atomic commit
```

### 重复

```text
OPEN + OPEN
→ OPEN 一次
```

### 冲突

```text
OPEN + CLOSE
→ CONFLICT
→ 都不执行
→ Target 保持批次开始前状态
→ Diagnostic
```

结果不得依赖 SceneTree / 遍历顺序。

---

# 30. Control Action Conflict Semantics

冲突关系不是 Dispatcher 硬编码，也不是 Target 临时猜。

`Control Action Definition` 声明有限、结构化的 Conflict Semantics。

至少：

```text
相同 Action ID + 相同 Typed Params
→ duplicate

明确互斥 Action
→ conflict

同一“状态设置型”Action + 不同参数
→ 默认 conflict
```

不开放任意冲突脚本 / 表达式。

---

# 31. ControlActionResult 与级联事件

Target 不得在执行 Action 时递归调用 Dispatcher。

返回：

```text
ControlActionResult
├─ Candidate / Resulting Runtime State
└─ 0..N Typed Output Events
```

流程：

```text
Batch N
→ Resolve
→ Atomic Commit
→ 收集新 Events
→ Batch N+1
```

Definition 未声明的 Event ID 不允许由实现偷偷返回。

---

# 32. Control Connection 错误策略

### Authoring / Preflight

以下为 ERROR：

- Target Stable ID 不存在；
- Target 不具备 Control Target Capability；
- Action ID 不存在；
- Params 不符合 Schema；
- Self-target；
- 控制图非法成环；
- 指向不允许作为普通 Target 的动态 Spawn 对象。

### Runtime

若损坏数据仍进入 Runtime：

```text
invalid command
→ safe no-op
→ Diagnostic
→ 其它合法命令继续
```

绝不 fallback 到 Node.name / NodePath / 坐标 / 同类型对象。

---

# 33. Reset Contract

`LevelRuntimeHost` 是 Reset 唯一编排者。

概念职责：

```text
终止旧 generation
→ 清传播 Runtime
→ 移除动态 Spawn
→ 恢复预置实例存在性 / Stable IDs
→ 恢复初始 Typed Configuration
→ 恢复 Inventory
→ 刷新 Registry / Occupancy
→ 重置确有临时 Runtime State 的对象
→ 新 Runtime Generation
```

只有确实拥有临时状态的对象才实现可选 Runtime State Reset Contract。

机关自己的 Reset Hook 只能：

> “清理本实例临时状态，使其回到当前 Configuration 对应的初始运行状态。”

不能改 ID、Inventory、全局 Runtime、其它对象。

---

# 34. Visual API（自动收口）

> 用户授权后按推荐方案冻结。

Gameplay Truth 与 Visual Truth 分离。

正式方向：

```text
Logic / Configuration / Runtime State
→ stable visual semantic state / slot
→ Visual Profile / Visual View
```

Visual 不得反向决定：

- Footprint；
- Direction；
- Speed；
- Objective；
- Occupancy；
- Control State。

Formal Definition 声明：

- Required / Optional Visual Slots；
- visual dimensions；
- direction behavior；
- semantic state IDs；
- Inventory / Preview 所需视觉。

Visual Workbench 消费同一声明。

普通机制代码不得硬写纹理路径作为玩法事实。

缺失 Required Visual Slot 应进入 Validator / Contract Test，而不是只依赖运行时 warning。

---

# 35. Validator Extension API（自动收口）

Validator 只有一个 Core，支持：

```text
Change Set Scope
Current Level Scope
Project Scope
```

通用规则不写机关类型 if-chain。

正式机制可提供**受限、只读的 Validator Extension / Rule Provider**，用于机制特有的作者约束，例如：

```text
Light Barrier
→ 两侧切线方向必须存在固定普通墙
```

Rule Provider 必须：

- 只读；
- 无玩法副作用；
- 不修改关卡；
- 使用公开 Authoring / Placement Query；
- 返回 machine-readable issue；
- 提供最相关对象 / cell 定位信息；
- 能被 Validator `Go To` 使用。

Auto-fix 只允许机械且安全的修复；不能替作者做设计选择。

---

# 36. Testing Contract（自动收口）

目标：

> 普通机关不需要启动完整 LevelRuntime 才能验证自己的契约。

正式测试层建议：

## 36.1 Definition Contract Tests

验证：

- unique type_id；
- PackedScene；
- capability ↔ implementation；
- Field IDs；
- Event / Action IDs；
- Profile；
- Visual Required Slots；
- Condition definitions。

## 36.2 Interaction Contract Fixtures

提供轻量构造：

```text
RayInteractionContext Fixture
ParticleInteractionContext Fixture
LightInteractionResult assertions
```

测试：

- CONTINUE / BLOCK / REDIRECT；
- SpeedDelta；
- OutputEvent；
- 不合法 Result。

## 36.3 Placement Fixtures

测试：

- Typed Configuration；
- Footprint；
- Candidate；
- reason-coded Placement Query；
- Atomic commit / reject。

## 36.4 Objective Fixtures

测试：

- ObjectiveHitContext；
- FormCondition；
- SpeedCondition（启用时）；
- AND；
- Base Success；
- group semantics。

## 36.5 Control Fixtures

测试：

- Event → Connection → Action；
- dedupe；
- conflict；
- invalid Stable ID；
- Batch N → N+1；
- Reset state。

原则：

- 机制单元测试优先纯 / 小型；
- Runtime integration test 只覆盖跨系统边界；
- 不为测试暴露新的核心内部 API。

---

# 37. API 稳定性分层

## 37.1 Stable — 潘陈俣可长期依赖

本轮实现完成后应作为稳定公共 API：

- `content_type_id`；
- Stable Instance ID / Instance Binding；
- Formal Content Definition Contract；
- Definition Discovery / read-only lookup；
- Stable Field ID；
- Interaction Profile；
- Runtime Interaction Permission result；
- Typed Configuration Contract；
- Player Interaction Action；
- Footprint Contract；
- Candidate / Placement Query result；
- 八方向 Domain；
- LightForm；
- Ray / Particle Interaction Context；
- LightInteractionResult；
- Propagation Decision；
- SpeedTier / SpeedDelta；
- Gameplay Color（离散枚举 WHITE/RED/GREEN/BLUE 与 filter 纯函数）；
- ObjectiveHitContext；
- ObjectiveCondition Contract；
- Stable Event / Action ID；
- ControlActionResult；
- Typed Runtime State Contract；
- mechanism test fixtures。

## 37.2 Extension — 预留但不承诺本轮完整实现

- Form Converter / Light Form Change；
- Split / multi-output propagation；
- Gameplay Color Condition（Objective 侧颜色条件，供颜色水晶）；
- limited Neighborhood Query；
- Runtime Spatial Control Action；
- absolute SetSpeed；
- Event runtime payload；
- 高级 multi-effect semantics。

Extension 必须由真实冻结玩法倒逼，不能为了“未来也许”提前开放。

## 37.3 Internal — 普通机关不得依赖

- `LevelRuntimeController`；
- `LevelRuntimeHost` 内部实现；
- Scheduler；
- ParticleRuntimeState；
- raw Tick mapping；
- Ray / Particle executor internals；
- Adapter internals；
- OccupancyRegistry internals；
- Formal Object Registry mutation API；
- SceneTree traversal；
- CoreLoop；
- Runtime Factory internals；
- Control Dispatcher internals；
- ObjectiveController completion internals；
- raw visual resolver internals。

## 37.4 Experimental

尚未有冻结玩法且只可用于原型：

- Splitter topology；
- Form conversion exact lifecycle；
- future neighborhood-aware mechanisms；
- runtime-spawn targets in normal Control Connection。

不得写入“Stable API”文档。

---

# 38. 尚未冻结玩法的扩展边界

## 38.1 Form Converter

当前只冻结**需求边界**：

- 转换必须通过正式 Runtime Result / Extension 表达；
- 机关不能直接操作 Ray / Particle Runtime；
- 必须保留 `emission_id` 与 `runtime_generation` 的正式关联；
- Q 只影响未来 emission 的发射器默认，不应被传播中的转换反向修改。

**不在 v1 中提前冻结 `FORM_CHANGE` 的具体字段和 Ray↔Particle 生命周期。**

## 38.2 Splitter

Split 会改变传播拓扑，不应简单塞成普通 Effect。

未来应作为明确的 Propagation Topology Extension 讨论：

```text
单输入
→ 多个合法 outgoing branches
```

在正式分光规则未冻结前不实现 Stable `SPLIT` API。

## 38.3 Gameplay Color

作者工具中的 Formal Color Palette / Visual Color 与 Gameplay Color 是两回事。

已冻结（Q46 更新）：Gameplay Color 为离散枚举，取值 WHITE=0 / RED=1 / GREEN=2 / BLUE=3，
另有哨兵 NONE=-1（表示吸收 / 非法输入，非真实颜色）。过滤规则：白光→对应单色、同色保持、
异色吸收、不做 RGB 混色（玩法设计 §6 已冻结）。

- 冻结 Gameplay Color 离散枚举与 `filter_color` 纯函数（Stable）；
- 冻结 `COLOR_CHANGE` 光交互效果（`LightInteractionResult` 新 EffectType，字段 `target_color`）；
- ColorCondition（Objective 侧颜色条件，颜色水晶用）保留为 Extension，待颜色水晶实装前冻结；
- 不允许 Visual Color 成为玩法颜色真相。

---

# 39. 当前正式机关压力测试矩阵

| 内容 | Definition / Authoring | Placement / Identity | Ray | Particle | Objective / Control | 结论 |
|---|---|---|---|---|---|---|
| 单格斜面镜 | MechanismDefinition；orientation Field | Inventory；1-cell；Stable ID；Player Tool Profile | REDIRECT/BLOCK | REDIRECT/BLOCK | 无 | 完整覆盖 |
| 双格平面镜 | direction / orientation Typed Config | 动态 Footprint；Anchor；Atomic Rotate | 自身几何 → REDIRECT/BLOCK/CONTINUE | 同一正式入口 | 无 | Footprint + Candidate 是关键压力测试 |
| 光粒加速器 | direction；Inventory Eligible | 1-cell；Generic Spawn | 未声明 Ray → transparent | CONTINUE + SPEED_DELTA(+1) | 无 | 直接解决当前“写了但不可达” |
| 光粒减速器 | direction；Inventory Eligible | 1-cell；Generic Spawn | 未声明 Ray → transparent | CONTINUE + SPEED_DELTA(-1) | 无 | 同上 |
| 光屏障 | Preplaced；direction；Fixed Profile | Formal Registry；Validator 特有规则 | BLOCK | BLOCK / CONTINUE + SPEED_DELTA(-1) | 无 | 验证预置发现、Speed API、Validator Extension |
| 光粒速度监测器 | Preplaced；direction + target_speed | Formal Registry；Fixed Profile | 轴向 CONTINUE / 非轴 BLOCK | CONTINUE/BLOCK + OUTPUT_EVENT | Control Source | 验证 Event → Dispatcher |
| 基础水晶 | ObjectiveTargetDefinition | Preplaced Stable ID | ObjectiveHit | ObjectiveHit | Base Success | 不再依赖“crystal_id + 形态盲入口” |
| Ray 形态目标 | Target + FormCondition(RAY) | Preplaced | Satisfied | Not satisfied | Objective | 不需要独立 Crystal 技术子类 |
| Particle 形态目标 | Target + FormCondition(PARTICLE) | Preplaced | Not satisfied | Satisfied | Objective | 同上 |
| Main Emitter | EmitterDefinition | Preplaced Stable ID | Source | Source | 非 Inventory | 与 MechanismDefinition 分域 |
| Form Converter | Extension | 未定 | Extension | Extension | - | 规则冻结后再正式化 |
| Splitter | Extension | 未定 | Topology Extension | Topology Extension | - | 不塞进普通 Effect |
| 滤光片 | MechanismDefinition；orientation + color Field | Preplaced；1-cell；Fixed Profile | 平行 BLOCK / 穿过 COLOR_CHANGE / 吸收 BLOCK | BLOCK | ColorCondition（Extension） | 验证 Gameplay Color + COLOR_CHANGE |

---

# 40. 当前仓库 API 能力矩阵

> “当前代码”指底审基线 `main@2a9bc02`；“目标”指本文冻结后的正式 API。

| 能力 | 当前代码状态 | v1 目标 |
|---|---|---|
| Ray 机关接入 | Mirror concrete-class hardcode | 对称 `interact_ray` Contract |
| Particle 机关接入 | `has_method()` duck contract | 对称 `interact_particle` Contract |
| Particle Speed | 已有单一 `ParticleMotionRules` | 保留并正式化 SpeedTier / SpeedDelta 边界 |
| 八方向 | 合法值较集中，但映射重复 | 唯一 Direction Domain |
| 玩家 Placement Core | 较类型无关 | 保留并接入 Typed Candidate / Footprint |
| Drag / config | Mirror-specific | Generic Action + Candidate |
| Inventory | 单类型计数器 | `type_id → quantity pool` |
| Runtime Spawn | CoreLoop factory hard编码 Mirror | Definition-driven Generic Spawn |
| Preplaced Mechanism Discovery | 缺失 | Formal Object Registry |
| Objective hit | 形态盲 | ObjectiveHitContext |
| Form Crystal | 数据入口不足 | Target + FormCondition |
| Reset | 全局已有，机关无 hook | Host 编排 + optional state reset |
| Control Event | 未形成正式系统 | Typed Event → Dispatcher → Typed Action |
| Visual | VisualProfile 基础存在；速度机关 profile 缺失 | Definition-driven semantic slots + validation |
| Validator | 固定对象覆盖有限 | Core + declaration-driven + mechanism extension |
| Testing | Particle/Ray 已有轻量 fixture 实证 | 标准 Contract Test Kit |

---

# 41. P0 / P1 / P2 实现冻结

## P0 — 没有它就无法形成正常机关开发 API

### P0-1 Formal Content / Identity

1. FormalContentDefinition / MechanismDefinition / ObjectiveTargetDefinition / EmitterDefinition 职责；
2. stable `content_type_id`；
3. Definition Discovery；
4. Formal Content Registry；
5. Formal Content Instance Binding；
6. Stable Instance ID 生成 / Duplicate / Reset 语义。

### P0-2 Runtime Object Discovery

1. Formal Object Registry；
2. 预置机关注册；
3. 玩家 Spawn 注册；
4. LightWorldQuery / 等价只读查询统一消费；
5. 不再只依赖 PlacementController 找机制。

### P0-3 Light Mechanism Contract

1. Direction Domain；
2. `RayInteractionContext`；
3. `ParticleInteractionContext`；
4. `interact_ray` / `interact_particle`；
5. `LightInteractionResult`；
6. CONTINUE / BLOCK / REDIRECT；
7. SpeedDelta；
8. Interaction Commit 时序；
9. 移除 Ray concrete-class hardcode。

### P0-4 Player Mechanism Integration

1. Typed Configuration；
2. Stable Field ID；
3. Interaction Profile；
4. Runtime Interaction Permission；
5. Player Interaction Action；
6. Footprint Contract；
7. Candidate → Placement Query → Atomic Commit；
8. 通用 Drag / Existing Move；
9. 清除 Mirror-specific DragContext 类型依赖。

### P0-5 Multi-type Inventory

1. Level Inventory Entry；
2. `type_id → quantity` runtime；
3. Reservation + Preview；
4. Definition-driven Spawn；
5. Generic Recover；
6. Reset restore。

### P0-6 Objective

1. ObjectiveHitContext；
2. Target Carrier；
3. Objective Condition Contract；
4. FormCondition；
5. Basic Target Base Success；
6. ObjectiveController 统一完成状态；
7. 形态命中事实贯通 Ray / Particle。

### P0-7 Validator / Test Baseline

1. Definition contract test；
2. interaction fixtures；
3. placement fixtures；
4. Required Visual / capability validation；
5. Go To 可定位问题基础。

---

## P1 — 正常开发强烈需要，或已有正式机关直接依赖

1. Typed Runtime State；
2. Optional Runtime State Reset Contract；
3. Control Source / Target Definition；
4. Stable Event / Action IDs；
5. Control Connection data；
6. Control Dispatcher；
7. Batch / dedupe / conflict；
8. ControlActionResult；
9. 速度监测器完整触发链；
10. Mechanism-specific Validator Extension；
11. 光屏障两侧护墙规则；
12. Visual semantic slots / profile validation；
13. Speed Detector authoring UI；
14. Objective Group：Independent / Simultaneous / Sequence；
15. SpeedCondition（若下一阶段目标要求速度型 Objective）；
16. Gameplay Color 枚举与过滤；
17. 滤光片机关。

---

## P2 — 真实玩法冻结后再扩展

1. Form Converter；
2. Splitter；
3. ColorCondition；
4. SetSpeed；
5. Neighborhood Query；
6. Runtime Spatial Control；
7. Event runtime payload；
8. 更复杂 Control Action combination semantics。

---

# 42. 新机关正式开发流程

## 42.1 玩家可放置机关

潘陈俣：

1. 阅读机关规则；
2. 选择 / 定义稳定 `content_type_id`；
3. 实现 Typed Configuration；
4. 实现 Footprint（单格可直接声明）；
5. 实现需要的 `interact_ray` / `interact_particle`；
6. 返回正式 Result，不修改 Runtime；
7. 定义 Player Interaction Actions；
8. 准备 PackedScene；
9. 建立 MechanismDefinition；
10. 声明 Inventory Eligible；
11. 声明 Inventory Spawn Profile / Defaults；
12. 声明 Level-editable Fields；
13. 声明 Visual Slots；
14. 写 Contract Tests；
15. 写机关玩法 Test。

张梓涵随后在 Inventory Editor 中直接看到该类型，只配置：

```text
类型
数量
顺序
```

无需陈俊贤再修改 Slot / Factory / Drag 白名单。

---

## 42.2 设计者预置机关

潘陈俣：

1. 机关脚本 / PackedScene；
2. MechanismDefinition；
3. Preplaced Capability；
4. Fixed / 合法 Preplaced Interaction Profile；
5. Light Interaction Contract；
6. Level-editable Fields；
7. 如有特殊关卡约束，提供 Validator Rule Provider；
8. Tests。

张梓涵：

```text
Content Palette
→ 放入场景
→ 系统自动生成 Stable ID
→ Inspector 编辑正式字段
→ Validator
```

Runtime 自动通过 Formal Object Registry 发现。

---

## 42.3 Objective Target / Condition

新增目标：

```text
ObjectiveTargetDefinition
+ Target Carrier implementation
+ allowed condition declarations
```

新增条件：

```text
Condition Definition
+ Typed Configuration
+ Pure Evaluator
+ Tests
```

原则上不修改 ObjectiveController 的具体类型分支。

---

## 42.4 Control Source / Target

Source：

```text
Definition 声明 Output Event IDs
→ Runtime Result 返回 Event
```

Target：

```text
Definition 声明 Action IDs + Params + Conflict Semantics
→ Typed Runtime State transition
→ ControlActionResult
```

连接由关卡作者使用 Stable ID 在 Control Connection Editor 中配置。

---

# 43. 潘陈俣需要阅读的 Stable API 文档

正式文档不能只给函数签名。

建议最终至少拆成以下章节：

1. `01_机关开发总览与边界.md`
2. `02_Formal_Content_Definition与身份.md`
3. `03_Typed_Configuration与Field_ID.md`
4. `04_Placement_Footprint与Candidate事务.md`
5. `05_Light_Interaction_Context_Result.md`
6. `06_Direction与Particle_Speed.md`
7. `07_Inventory与Player_Interaction.md`
8. `08_Objective_Target与Condition.md`
9. `09_Control_Event_Action.md`
10. `10_Reset_Runtime_State.md`
11. `11_Visual与Validator_Extension.md`
12. `12_机关测试指南.md`
13. `13_API稳定性与禁止访问的Internal边界.md`

每个公共 API 至少说明：

```text
用途
调用者
输入
输出
副作用
允许调用时机
禁止调用时机
生命周期
稳定性
错误行为
时序边界
最小示例
```

尤其必须写：

> **什么时候不应该调用这个 API。**

---

# 44. 旧 API / 文档迁移要求

底审已确认存在文档与真实代码漂移。

实现阶段应逐项分类：

```text
MATCHED
CODE_ONLY
DOC_ONLY
STALE
MISSING
```

重点处理：

- 文档声称存在、代码不存在的旧稳定方法；
- `SingleCellMirror` / `BasicCrystal` 的过时公共接口描述；
- 旧多道具“目标接口”与本 v1 Inventory Contract 的关系；
- 文件结构文档中目标命名与真实产物命名漂移；
- 旧 Main Emitter W 控制 DOC_ONLY 记录；
- README 索引版本漂移；
- 旧 Crystal subtype 叙述向 Target + Condition 技术模型迁移；
- `mechanism_id` / `crystal_id` 等旧身份概念向 Type ID + Stable Instance ID 映射。

旧接口不能只因为文档写了“Stable”就自动保留；应以当前代码事实 + 本文件正式裁决重新确定。

---

# 45. Core Touch Count 验收标准

一个普通新机关完成接入时，原则上：

### 理想

```text
新增：
- 自身 script
- 自身 scene
- 自身 definition
- 自身 visual resource / slot content
- 自身 tests
- 自身 rule doc

共享核心修改：
0
```

### 可接受

首次引入一个**全新公共能力类别**时，可以修改对应单一 Extension 层。

例如：

```text
第一次正式加入 Form Conversion
→ 允许修改 Light Interaction Extension API
```

但不能因为新增一个同类机关再次修改：

```text
Ray Executor
Particle Executor
Inventory
Palette
Validator
ObjectiveController
CoreLoop
```

若一个普通机关仍需要同时修改 4～6 个 Core 文件，视为 API 设计没有达到本轮目标，应先审查公共边界。

---

# 46. 实现阶段代码规模约束

继续遵守项目已有结构标准：

```text
<250 物理行
→ 常规职责检查

>=250
→ 强制职责复查

>=350
→ 强制拆分评估
```

普通职责目录：

```text
<=6 个主要源码
→ 推荐

7~8
→ 职责密度复查

>8
→ 强制目录 / 子职责拆分评估
```

但不得为了“行数漂亮”拆成大量碎片化文件。

尤其禁止把：

- Formal Content Registry；
- Interaction Result；
- Validator；
- Control Dispatcher；

做成新的 500 行万能核心。

---

# 47. Freeze Ledger

以下为本轮正式冻结项。

| ID | 决定 | 状态 |
|---|---|---|
| Q01 | 玩家机关 + 预置机关 + Objective 均纳入本轮，但只统一真正共享层 | FROZEN |
| X01 | 无代码工具与机关 API 共用唯一 Formal Content Declaration | FROZEN |
| Q02 | 每个正式 Mechanism 类型一个全局 MechanismDefinition | FROZEN |
| Q03 | Definition 声明 Runtime capability tag，但不保存具体算法 | FROZEN |
| Q04 | FormalContentDefinition 根概念；Mechanism / ObjectiveTarget / Emitter 分域 | FROZEN |
| Q05 | Type ID + Stable Instance ID；Light Runtime IDs 独立 | FROZEN |
| Q06 | Inventory + Spawn + Drag 接入由 MechanismDefinition 驱动 | FROZEN |
| Q07 | 同类型一个 Definition + Interaction Profile | FROZEN |
| Q08 | 显式 Level-editable Fields；Type Default / Instance Override / Runtime 分层 | FROZEN |
| Q09 | 共享 Runtime Interaction Permission | FROZEN |
| Q10 | Formal Object Registry 统一正式空间对象索引 | FROZEN |
| Q11 | 普通机关默认不访问 WorldQuery | FROZEN |
| Q12 | Shared Light Context + Ray / Particle 专属 Context | FROZEN |
| Q13 | Propagation Decision + Typed Effects | FROZEN |
| Q14 | 统一 Interaction Commit Pipeline | FROZEN |
| Q15 | 对称 `interact_ray` / `interact_particle` | FROZEN |
| Q16 | 未声明 Light Form = transparent / no interaction | FROZEN |
| Q17 | 唯一八方向 Domain | FROZEN |
| Q18 | 机关只理解 SpeedTier / SpeedDelta | FROZEN |
| Q19 | Static / Pure Dynamic Footprint Contract | FROZEN |
| Q20 | Candidate → Validation → Atomic Commit | FROZEN |
| Q21 | Typed Player Interaction Action | FROZEN |
| Q22 | Typed Configuration | FROZEN |
| Q23 | Stable Configuration Field ID | FROZEN |
| Q24 | Definition 自动发现 → 单一 Registry | FROZEN |
| Q25 | 组合式 Formal Content Instance Binding | FROZEN |
| Q26 | LevelRuntimeHost 编排 Reset；可选 Runtime State Reset | FROZEN |
| Q27 | 独立 ObjectiveHitContext | FROZEN |
| Q28 | Typed Objective Condition + Pure Evaluator | FROZEN |
| Q29 | Typed Event → Dispatcher → Typed Control Action | FROZEN |
| Q30 | 普通 Control Action 只写 Runtime State | FROZEN |
| Q31 | Control Dispatch Batch + dedupe + conflict + atomic commit | FROZEN |
| Q32 | ControlActionResult 产生后续 Event，进入下一 Batch | FROZEN |
| Q33 | Typed Runtime State；无状态机关零额外 State | FROZEN |
| Q34 | Stable Event / Action Schema ID | FROZEN |
| Q35 | Output Event 无 Gameplay Payload；参数固定在 Connection | FROZEN |
| Q36 | Target Definition 声明有限 Conflict Semantics | FROZEN |
| Q37 | Validator strict；Runtime invalid connection no-op + diagnostic | FROZEN |
| Q38 | 一个 LevelInventoryRuntime，按 type_id 管数量池 | FROZEN |
| Q39 | Inventory Drag 使用 Reservation + Preview，成功 Commit 才正式 Spawn / 生成 Stable ID | AUTO-FROZEN |
| Q40 | Visual 使用声明驱动 semantic slots/state，Visual 不决定 Gameplay | AUTO-FROZEN |
| Q41 | Validator Core + 机制特有只读 Rule Provider，不维护类型 if-list | AUTO-FROZEN |
| Q42 | 提供正式 Contract Test Kit，普通机关无需完整 Runtime 才能测试 | AUTO-FROZEN |
| Q43 | Stable / Extension / Internal / Experimental 四级 API 边界 | AUTO-FROZEN |
| Q44 | Form Conversion 只保留受限 Extension 点，具体语义等待玩法冻结 | AUTO-FROZEN |
| Q45 | Split 属于 Propagation Topology Extension，不提前做普通 Effect | AUTO-FROZEN |
| Q46 | Gameplay Color 冻结为离散枚举 WHITE/RED/GREEN/BLUE（NONE=-1 哨兵）；Visual Color 不得成为玩法颜色事实 | FROZEN |

`AUTO-FROZEN` 表示：用户明确授权“后续全部按推荐方案”，由本轮收口直接冻结。

---

# 48. 下一阶段实施判定

本文件完成后，**API 设计讨论阶段可以结束**。

下一步不应继续无限 grill，而应进入：

```text
本冻结文档
↓
GLM-5.3 定向 Gap Audit / Implementation Mapping
↓
按 P0 拆小批次
↓
GLM 主实现
↓
GPT 只审高风险边界 / Evidence Packet
↓
Godot 自动验证
↓
GUI 人工验收
↓
阶段收口
```

建议第一次实施阶段优先解决四个最硬断点：

1. **Formal Content Definition / Discovery / Stable Identity 基础；**
2. **Formal Object Registry + 预置机关 Runtime Discovery；**
3. **Ray / Particle 对称 Interaction Context + Result，移除 Ray concrete-class hardcode；**
4. **Multi-type Inventory + Definition-driven Spawn + Generic Drag/Placement。**

随后再接 Objective、Control、Validator Extension。

---

# 49. 最终一句话

> **《光速奇点》的机关 API 不应成为一个“万能机关框架”，而应成为一组小而稳定的契约：Definition 告诉系统机关拥有什么能力，Context 告诉机关这次发生了什么，Result 告诉 Runtime 应该发生什么；身份、Placement、Inventory、Objective、Control、Reset、Validator 由公共 Infrastructure 统一处理。普通机关只负责自己的局部规则。**

---

**文档状态：v1.0 DESIGN FROZEN，可进入差距映射与实施拆解。**
