# D7-R5 GUI 验收 Fix Loop — 镜面反射与反射格视觉修复 EVIDENCE PACKET

> 日期：2026-08-15　Worker：D7-R5 GUI Fix Loop Worker（dispatch task_d417007a13af）
> Worktree：`E:\orca_workspace\light-speed-singularity\tetra`（单写者）　分支：`luehunyo/feat-d7-remaining-integration`
> 触发：用户在 Godot 4.6.1 编辑器 F5 GUI 人工验收中发现并截图上报（截图即本包 §1）。
> 约束遵守：未使用 Ultracode/Workflow；未执行任何 Git 写操作；未改冻结玩法规则 / Q / cooldown / multi-emission / Snapshot schema / R1-R4 契约。

## STATUS

**PASS —— 修复完成（自动门禁 98/98、5117 断言、0 失败、全部 ExitCode 0），且 Human GUI 复验已通过（GUI_ACCEPT_PASS，2026-08-15，在镜面反射与反射格视觉修复后复验）**。

## 1. 用户截图现象与像素级根因定位

两张截图（用户提供，591×289 / 527×294 PNG）经像素级分析（颜色分类 + 1px 精度 bbox 测量，对照工程美术资产颜色与 64px 网格）：

- **截图 1（RAY 形态）**：Emitter(1,3) 向右发射 → 镜面 "/" 置于 (3,3) → Ray 正确反射向上穿过水晶 (3,1)。**所有视觉元素（光束/发射器/水晶/镜面/墙）均与 64px 网格精确对齐（±1px），无坐标错位、无 stale 残影段**。用户感知的"显示 bug"根因 = **反射格视觉缺陷**：镜面格渲染的是"入射方向整格段"（光束视觉上**穿过镜面格直到格远端边缘**），而出射竖直光束只从镜面格**上边缘**开始（镜面格中心到上边缘之间有 32px 空档）——拐角处光束既"穿透镜面"又"断裂"，反射看起来错位/未发生。
- **截图 2（PARTICLE 形态）**：同一布局，光粒 24×16 黄色主体水平停靠在镜面格 (3,3) 中心（测量中心 (226.5,224.5)≈格中心 (224,224)），方向仍为入射方向 RIGHT。根因 = **Particle 规则/适配层缺陷（非视觉缺陷）**：`ParticleMechanismAdapter.adapt()` 只消费 `get_speed_modifier` 速度机关契约，从不读取镜面的 `reflect_direction`——光粒直接穿过镜面继续直行（其后在墙 (5,3) 边界消失）。截图 2 中的另一个黄色块为已点亮水晶的 lit 态美术（crystal_normal_lit.png 中心金色），非残影。

结论分类（dispatch SCOPE 要求）：**镜面格光束"穿镜+断口"= Ray 视觉渲染缺陷；光粒不反射 = Particle 规则/调度适配缺陷**。两者均为独立最小修复，未互相掩盖。

## 2. 修复内容（最小修复，5 个生产文件 + 5 个测试文件）

### 2.1 Particle 镜面反射（规则/适配层）

- `gameplay/particle/particle_mechanism_adapter.gd`：`adapt()` 新增镜面契约分支——机关 `has_method("reflect_direction")` 时读取 `reflect_direction(incoming)` 作为 `outgoing_direction`（`speed_delta=0`，改向不改速）；反射返回 ZERO（非法入射哨兵；正式传播八方向恒合法，实际不可达）安全降级保持入射方向。与 Ray 路径的 `RayMechanismAdapter` 同源同镜同公式，与速度机关同样只认公共方法契约、不依赖 `SingleCellMirror` 类名。正式规则依据：机关规则 v0.3 §8"传播过程中：镜面仍可改变方向"、玩法设计 v1.0"镜面等机关可以把光线反射到八方向"——本修复是**实装已冻结规则**，未改任何玩法语义。
- `gameplay/particle/particle_step_executor.gd`：仅更新过时注释（"outgoing_direction 恒为入射方向"→"镜面机关按正式规则改向"），逻辑零改——`next_step_blocked` 前瞻已按 `outgoing_direction` 计算，斜向/正交 `ticks_for` 由 scheduler 以出射方向统一查表，天然生效，零额外改动。
- 调度与视觉零改动：scheduler `apply_move` 写入反射方向、`next_move_tick` 按出射方向 Tick；ParticleVisualController MOVE 处理按事件 `direction` 校准旋转并从镜面格中心向下格 Tween——粒子在镜面格中心正确转弯。

### 2.2 Ray 反射格拐角视觉（视觉层）

- `gameplay/visuals/light_segments/light_segment_view.gd`：新增 `set_direction_half()` 半段模式——fallback 占位光束从格中心画到 `direction` 指向的格边（正交 CELL_SIZE/2=32、斜向 CELL_SIZE*√2/2 格中心到格角；厚度恒 16；pivot 锚定格中心）；`set_direction()` 复位回全段；半段模式显式回退占位块（有纹理也不显示 64×64 整格纹理，防止正式美术接入后拐角退化回贯穿整格；正式反射角美术留后续美术接入）。
- `gameplay/visuals/light_visual_controller.gd`：新增 `show_reflection_step(emission_id, generation, cell, incoming, outgoing)`——在同一格创建两段半光束（入射半段指向 -incoming 覆盖"入射边→格中心"，出射半段指向 outgoing 覆盖"格中心→出射边"），与相邻格全段在共享边中点相接；per-emission ownership / 计数 / 清理与 `show_step` 同语义。未触碰既有方法签名与冻结令牌边界（组 18/19 源码扫描测试仍 PASS）。
- `gameplay/runtime/ray_emission_driver.gd`：`_apply_ray_execution_result` 增加反射格判定——纯读相邻 step 事实（`steps[i+1].incoming_direction != steps[i].incoming_direction` = 该格机关改向），反射格改调 `show_reflection_step`，其余格照常 `show_step`；不重查机关、不复制反射算法；"视觉→水晶"冻结顺序保持（组 20 源码扫描仍 PASS）。

修复后效果：光束在镜面格**入射边→格中心→出射边**连续拐弯，不再穿透镜面格远端、拐角无 32px 断口。

## 3. 针对性自动测试（新增/扩展，5 文件）

| 测试 | 新增组 | 覆盖 |
|---|---|---|
| `tests/unit/particle/particle_mechanism_adapter_test.gd` | 06_镜面反射（5→7 组） | SLASH/BACKSLASH/斜向/ZERO 哨兵/契约不依赖类名 |
| `tests/unit/particle/particle_step_executor_test.gd` | 12_镜面反射MOVE（6→7 组） | MOVE+entered=镜面格+outgoing=反射方向+前瞻沿反射方向 |
| `tests/unit/particle/particle_scheduler_test.gd` | 31_镜面反射端到端（19→20 组） | tick4 进镜面格事件/状态双向改向、next_move_tick 按出射方向、tick8 沿反射方向入 (1,-1) |
| `tests/unit/visuals/light_segments/light_segment_view_fallback_test.gd` | 10_半段光束几何（9→10 组） | 半段长 32/45.25、厚度 16、锚点格中心、rotation、set_direction 复位 |
| `tests/unit/light/light_visual_controller_test.gd` | 21_反射格两段半光束 + 22_driver反射格拐角（20→22 组） | 两段半光束方向/位置/计数/清理；driver 对 steps 的全段/反射段分派与水晶处理不变 |

fixture 扩展：`tests/unit/particle/fixtures/fake_particle_world_query.gd` 新增 `FakeReflectMechanism`（与 SingleCellMirror 反射公式同源，只实现公共方法契约）。

## 4. VERIFICATION

- **全量回归**：`find tests -name "*_test.gd" | grep -vE "(fixtures|support|helper)"` → 98 入口全部逐入口 `--headless --script` 执行：**98/98 PASS、0 失败断言、全部 ExitCode 0**（详细数字见 §6 本批实测）。无新增测试入口（新覆盖全部并入既有 5 个入口，入口数保持 98）。
- **`git diff --check`**：PASS。
- 全部日志无 `SCRIPT ERROR`（负向用例预期 `push_error` 不判失败，§12 口径）。

## 5. INVARIANTS

- 未改冻结玩法规则：镜面八方向反射公式 / Tick 表 / 速度档位 / 五态 / Q / cooldown / multi-emission / Snapshot schema / R1-R4 契约全部原样；本修复实装的是机关规则 §8 已冻结的"镜面仍可改变方向"。
- 未改任何公共接口签名：`show_step` / `set_direction` / `adapt` / `evaluate_step` / `advance_one_tick` 签名不变（仅新增方法与可选内部模式）。
- LightVisualController 冻结令牌边界（组 18/19 扫描）与 driver"视觉→水晶"顺序（组 20 扫描）保持 PASS。
- 未执行任何 Git 写操作；未触碰外部只读目录。

## 6. GUI 复验清单（Human 已执行，2026-08-15 复验通过 GUI_ACCEPT_PASS）

启动：Godot 4.6.1 编辑器打开 `E:\orca_workspace\light-speed-singularity\tetra`，F5 运行。

1. **镜面放置**：SETUP 下从底部机关栏拖出镜面，放到发射器 (1,3) 正右方两格 (3,3)（发射器与墙 (5,3) 之间），保持 "/" 朝向。
2. **RAY 反射视觉**：点"开始运行"→ Space → 预期：光束向右到镜面格**在格中心拐弯向上**，不再穿过镜面格右边缘、拐角处无空档；光束继续向上穿过并点亮水晶。
3. **PARTICLE 反射**：按 Q 切到 PARTICLE → Space → 预期：光粒飞到镜面格**在格中心转弯向上**（穿过水晶格时点亮水晶，向上出界即消失），**不再水平穿过镜面**。
4. **R 重置**：按 R → 光束/光粒/镜面放置全部清理回库存，无残影。

**复验结果（2026-08-15）**：Human 按上述清单执行 GUI 复验，明确回复 **GUI_ACCEPT_PASS**——镜面反射与反射格视觉两项修复均按预期呈现，无"穿镜/断口/不反射"现象，R 重置无残留。本包 GUI 状态正式记为 PASS，无待复验事项。

## 7. 遗留

- 反射格拐角目前使用 fallback 占位半段光束渲染；正式"反射角"美术纹理接入（LightSegmentVisualProfile 扩展角块状态）留后续美术任务，接入前半段模式显式回退占位块（已在 View 注释与本包 §2.2 说明）。
- 截图中镜面/发射器格下的深灰 64×64 底块为既有 token 视觉层表现，非本批缺陷范围。
