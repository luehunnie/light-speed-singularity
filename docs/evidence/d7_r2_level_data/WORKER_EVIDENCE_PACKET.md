# D7-R2 LevelData Resource 基础 — WORKER_EVIDENCE_PACKET

> 日期：2026-08-15（Gate 2 Fix Loop 更新：新增 SCHEMA_EVOLUTION 节）
> Worker：D7-R2 Claude Code Worker（GLM-5.2，ponytail lite；未使用 Ultracode/Workflow，未加载其他 Skill）
> 工作区：`E:\orca_workspace\light-speed-singularity\tetra`（worktree，Single Writer；零 Git 写操作）
> 规格来源：D7 统合文档 §7（R2）/§12-14/§3（工作流 v2.0）+ 本次任务 prompt 内嵌 spec

---

## STATUS

**PASS** — 最小 LevelData Resource 契约 + 只读场景提取器已落地；全部自动测试 PASS；现有场景零迁移零回归；无未决 must-fix。无 DECISION_NEEDED 项。

## BASELINE

- 分支：`luehunyo/feat-d7-remaining-integration`；HEAD 基于 M4 合并（`3b619ef`）之后的 D7-R1 进行中分支。
- R1 in-flight 改动（diagnostics/console/snapshot、LRC、project.godot 等 8 modified + 多个 untracked）**原样保留，未触碰**。
- 改动前基线回归：**94 入口 / 94 PASS / 0 FAIL / 全部 ExitCode 0**（发现规则 `tests/**/*_test.gd`，排除 fixtures/support/helper）。
- 定向调查结论（§7.2 要求）：
  - Terrain/Wall/LegalArea 场景表达 = 关卡根直属 `TerrainLayer`/`WallLayer`/`LegalAreaLayer`（TileMapLayer used cells；`DecorationLayer` 纯视觉）。
  - Emitter 配置来源 = `RuntimeObjects/Emitter`（`EmitterConfigNode`：default_light_form / allow_form_switch / ray_default_direction / particle_default_direction / position）。
  - Crystal 配置来源 = `RuntimeObjects` 下唯一 `BasicCrystal`（crystal_id / position）。
  - LevelValidator 输入 = 关卡根 Node（`LevelValidator.validate(level_root)`，固定对象委派 `LevelFixedObjectValidator`）。
  - **level_id 无正式来源**（R1 Snapshot 已确立 unavailable 政策）→ 本契约沿用：默认空合法、可显式配置、绝不用 Node.name/instance_id 顶替。
  - 编辑器工作流：已有 `@tool class_name ... extends Resource` 先例（`ObjectVisualProfile`），Resource 化零阻碍。
  - R1 在途改动与本批零交集（本批只新增 `gameplay/level/data/` 与一个测试文件）。

## FIELD_SOURCES（字段来源表）

| LevelData 字段 | 现实来源 | 备注 |
|---|---|---|
| `level_id: StringName`（默认空） | 无正式来源 | unavailable 政策；非空必须显式配置且不得含空白；禁止 Node.name/instance_id 顶替 |
| `terrain_cells: Array[Vector2i]` | `TerrainLayer.get_used_cells()` | 空 → validate 报错（镜像 `terrain_empty`） |
| `wall_cells: Array[Vector2i]` | `WallLayer.get_used_cells()` | 可空；每格须在 Terrain 内（镜像 `wall_outside_terrain`） |
| `legal_area_cells: Array[Vector2i]` | `LegalAreaLayer.get_used_cells()` | 可空；每格须在 Terrain 内（镜像 `legal_outside_terrain`） |
| `emitter_cell: Vector2i` | `EmitterConfigNode.position` 经 `GridCoordinateRules.world_to_cell` | 唯一派生入口，不存 position 第二事实 |
| `emitter_form: int` | `EmitterConfigNode.default_light_form` | 值域=公共 LightForm 契约（RAY=0/PARTICLE=1，冻结），校验委派不另立白名单 |
| `emitter_allow_form_switch: bool` | `EmitterConfigNode.allow_form_switch` | M4-E4 正式配置 |
| `emitter_ray_direction: int` | `EmitterConfigNode.ray_default_direction` | 值域=RayDirection 八方向 |
| `emitter_particle_direction: int` | `EmitterConfigNode.particle_default_direction` | 值域=ParticleDirection 八方向 |
| `crystal_cell: Vector2i` | `BasicCrystal.position` 经 `world_to_cell` | 同上派生规则 |
| `crystal_id: StringName` | `BasicCrystal.crystal_id` | 稳定 ID，可为空（validate 报告，不静默造 ID） |

刻意不入契约：Decoration 格（纯视觉）、TileSet 引用、节点结构/transform、VisualProfile（皆属场景表达与 LevelValidator 校验域）；多发射器/多水晶数组（v0 冻结合同恰为 1+1，不发明未冻结事实）。

## CHANGED

全部为新增文件，零 tracked 文件修改：

- `gameplay/level/data/level_data.gd`（112 行，@tool class_name LevelData extends Resource）
- `gameplay/level/data/level_data_capture.gd`（94 行，RefCounted 静态提取器，无 class_name——沿用 LevelTileLayerSnapshot 避全局缓存坑策略）
- `gameplay/level/data/*.uid`（headless --import 生成，无 .tres/.tscn 污染）
- `tests/unit/level/level_data_test.gd`（395 行）+ `.uid`

## IMPLEMENTATION

- **LevelData**：扁平最小字段（见 FIELD_SOURCES）；`validate() -> PackedStringArray`（可读中文、一次返回全部问题、无副作用），校验域 = LevelValidator 对同源事实 ERROR 级规则在纯数据上的等价镜像（terrain 空 / wall、legal 越界 / 发射器与水晶越界 Terrain、位于 Wall、同格重叠 / crystal_id 空 / 形态与双方向枚举越域 / level_id 空白）。WARNING 级（legal_area_empty、legal_wall_overlap）刻意不在数据域，仍归场景校验——已在 docstring 与测试 09 固化。
- **LevelDataCapture.capture(level_root) -> LevelData/null**：只读一次提取四层逻辑格 + 固定对象配置；根非法、任一逻辑层缺/缺 TileSet、发射器或水晶数量≠1、position 非有限 → push_error 明确原因并返回 null（不部分提取、不静默降级）。level_id 恒保持空。扫描口径与 LevelFixedObjectValidator 一致（DFS is_instance_of）。
- 复用而非重写：格子派生走 `GridCoordinateRules`、枚举域走 `EmitterConfigNode` 公共枚举、提取失败口径沿用 `LevelTileLayerSnapshot.validate_layers` 的 push_error 风格。
- ponytail lite 说明：更懒的替代本可用 `Array[LevelEmitterData]` 嵌套子 Resource 承载固定对象，但 v0 冻结合同恰为 1+1，扁平字段少一个类、少一层序列化，故取扁平；未来多对象需求出现时再升级。

## SERIALIZATION

- 保存/加载：原生 `ResourceSaver.save` / `ResourceLoader.load`（.tres；typed `Array[Vector2i]` 原生序列化）。round-trip 测试（组 10）：11 字段逐项相等、validate 结果一致、临时文件清理成功。
- 复制：原生 `Resource.duplicate(true)` 深拷贝（测试组 11 证明数组/标量独立）。**不自建第二套 copy/save 语义。**
- 可变数据资源语义（与 ObjectVisualProfile 先例一致）：无 setter、无不可变承诺；值域合法性由 validate() 保证。

## SCHEMA_EVOLUTION

**策略：additive-only（Godot 原生属性名序列化），不引入 schema_version。** 依据（测试事实优先，非猜测）：

1. **R2 无已发布持久化资产**——LevelData 是本批新增契约，仓库内不存在任何历史 LevelData .tres 需要迁移；当前不存在旧版本兼容对象。
2. **Godot 原生行为已覆盖 additive-only**（由 probe 实测 + 测试组 16/17 固化）：
   - `ResourceSaver` 按属性名序列化，且**等于默认值的属性不写盘**（保存仅设 5 个非默认字段时，.tres 中只出现这 5 行）；
   - `ResourceLoader` 加载缺失属性时**回落脚本默认值**：手工构造仅含 `level_id`/`terrain_cells`/`crystal_cell` 的旧式 .tres，缺失的 `wall_cells`/`legal_area_cells`/`emitter_*`/`crystal_id` 全部回落（空数组 / 0 / false / 空 StringName），已写入属性按文件值加载；
   - 回落后 `validate()` 行为确定性：缺 `crystal_id` 恰报 1 条 crystal_id 空，不崩溃、不静默造 ID；缺省回落补全后（组 17）可构成 validate 为空的完整合法数据。
3. **兼容界限**：新增导出字段必须带兼容默认值（本契约现有 11 字段全部满足）；**重命名 / 删除 / 类型变化属 breaking**，本策略不覆盖——未来真正发生时才引入显式 `schema_version` 技术元数据 + 迁移器（届时 schema_version 属技术元数据而非玩法字段，无现实玩法来源，需单独说明）。
4. 刻意不做：不预先添加任何"为未来抽象"的 gameplay 字段或 schema_version（ponytail：YAGNI；Godot 属性名缺省回落已给出与"schema_version 默认 0"等价的兼容行为）。

## COMPATIBILITY

- 现有关卡场景（template/editing_example/prototypes）**零迁移、零改动、零运行时接线**：Runtime 与 core_loop 未触碰，不要求只接受 LevelData（§7.2 禁区遵守）。
- 唯一适配层 = LevelDataCapture（纯只读、无运行时副作用、不改任何现有模块）；真实场景捕获已由测试 15 用正式编辑示例场景端到端证明。
- 未触碰：Terrain/Wall/LegalArea/Emitter/Crystal/Validator 语义、MoveRequest、多格对象、存档/选关、编辑插件。

## VERIFICATION

- 发现规则：`find tests -name "*_test.gd" | grep -vE "(fixtures|support|helper)"` → 95 入口（基线 94 + 新增 1）。
- 回归入口：逐入口 `Godot_v4.6.1-stable_win64.exe --headless --script res://tests/...`。
- 结果：**95 入口 / 95 PASS / 0 FAIL / 全部 ExitCode 0**（含 R1 in-flight 的 3 个 diagnostics 测试与全部既有 91+ 用例；入口数不变——schema 演化用例以新增组并入既有 level_data_test）。
- 新测试 `tests/unit/level/level_data_test.gd`：**17 组 / 79 断言 / 0 失败**（覆盖默认构造、全部校验域、unavailable 政策、WARNING 域外、round-trip、深拷贝、捕获对齐/null 路径/只读两次一致、真实场景捕获、**additive-only 缺省回落组 16/17**）。
- `git diff --check`：干净（ExitCode 0，无 whitespace 错误）。
- 新脚本三件 `--check-only` 全部通过；负向用例的预期 `push_error` 已按 §12 提示不被误判为失败。
- 断言总量：逐入口解析测试报告断言数合计 **4948**（新测试贡献 79；基线含 R1 in-flight 用例）。
- 最终 `git status`：本批新增仅 `gameplay/level/data/`（4 文件）+ `tests/unit/level/level_data_test.gd(.uid)` + 本报告；R1 的 8 modified 与其 untracked 文件原样未动。

## INVARIANTS

1. level_id 永不来自 Node.name / instance_id；无来源即空。
2. cell 一律由 position 经 GridCoordinateRules 派生，不存在第二套坐标换算。
3. LevelData.validate 只镜像单解释的 ERROR 规则，不吞并场景结构校验（LevelValidator 职责不变）。
4. Capture 只读、全有或全无（不产出半成品数据）、失败必 push_error。
5. 枚举域校验委派公共契约（EmitterConfigNode / LightEmissionTypes 值域），不复制白名单。
6. 现有场景与 Runtime 行为零变化（回归 94 基线全 PASS 证明）。

## DIFF

- 关键新文件内容概要：`level_data.gd` = 字段导出（分组：标识/四层静态格子/发射器/水晶）+ `validate()`（~70 行规则实现）+ 关键边界含 additive-only 序列化演化策略；`level_data_capture.gd` = `capture()` + 4 个私有辅助（层读取/格拷贝/DFS 扫描/有限值判定）。
- 文件规模：level_data.gd 115 行、level_data_capture.gd 94 行（均 <250，常规职责检查即可）；测试 469 行（测试文件不受生产 250 纪律约束）。`gameplay/level/data/` 新目录 2 个源文件（≤6 正常）。
- `git status`：本批仅新增 `gameplay/level/data/`（含 .uid）与 `tests/unit/level/level_data_test.gd`（含 .uid）；8 个 R1 modified 文件保持原样。

## RISKS

- 低：`emitter_form`/方向以 int 存储（docstring 标明值域），Inspector 无枚举下拉——如需可视化编辑体验，后续可换 enum 标注，不影响序列化兼容（同为 int）。
- 低：capture 对层缺失/对象数量≠1 直接放弃提取；这是刻意保守（与 LevelValidator ERROR 口径一致），未来多发射器正式化时需同步扩展契约。
- 无：未修改任何 tracked 文件，回滚 = 删除新增文件。

## DECISION_NEEDED

无。字段产品含义均来自已冻结事实（四层格、v0 恰 1 发射器 + 1 水晶、M4 形态/切换配置、unavailable level_id 政策），未出现两个会改变玩法的合理方案，未触发 NEED_USER_INPUT。

## GATE_2

- 最小正式静态数据边界成立：✔（11 字段全部有现实来源，见 FIELD_SOURCES）
- 可序列化/加载/验证/复制：✔（原生三件套 + 测试 10/11）
- schema 演化策略明确：✔（additive-only；缺省属性回落已由组 16/17 测试证明；breaking 变化才引入 schema_version + 迁移器，见 SCHEMA_EVOLUTION）
- 现有场景零回归：✔（全量回归全 PASS）
- 未越界（无整批 .tscn 迁移 / 无 Runtime 只收 LevelData / 无插件重写 / 无存档选关 / 无 MoveRequest / 无多格对象 / 无语义变更 / 未进 R3/R4）：✔
- Git 零写操作：✔（用户保留 Git 最终控制）
