# D7-R1-GUI-FIX Evidence Packet

Date: 2026-08-15 ｜ Worktree: `E:\orca_workspace\light-speed-singularity\tetra` ｜ Branch: `luehunyo/feat-d7-remaining-integration`

## STATUS

**PASS（工程修复+自动化验证）— 人工验收（GUI 视觉项）PENDING**。两项修复已落地并通过目标测试与回归；1920×1080 窗口尺寸已用真实非 headless GUI 启动取证；F3 开关/可读性/按钮/不遮挡的**人工 GUI 确认未完成**（合成键盘输入在本机被环境拦截，且协调者已明确要求所有人工测试项留给人工），列入 HUMAN_RECHECK。

## CHANGED

| 文件 | 变更 | 说明 |
|---|---|---|
| `project.godot` | 新增 `[display]` 段：`viewport_width=1920`、`viewport_height=1080` | 原文件无任何 display 配置（Godot 默认 1152×648，与用户截图 1152×648 一致） |
| `gameplay/diagnostics/console/debug_console_view.gd` | `setup()` 面板 `offset_top 72→16`、`offset_bottom 640→584`（注释同步） | 宽 464（-480..-16）与高 568 内容容量保持不变；上/右各 16px 对称边距；锚点本就为右缘（anchor_left/right=1.0），任意窗口尺寸稳定贴右上 |
| `docs/evidence/d7_r1_gui_fix/` | 新增（本包 + 窗口截图） | 证据目录 |

未触碰：RuntimeSnapshot schema/lifecycle、gameplay、R2-R4、`E:\godot_project\light-speed-singularity`；未执行任何 git add/commit/push 等；用户既有修改全部保留（git status 仅多出上述两项变更 + docs/evidence/）。

## IMPLEMENTATION

1. **1920×1080 视口**：`project.godot` 增 `[display]` 两行。无 stretch/无 window override——场景无 Camera2D、世界坐标原点固定，视口放大不改任何 gameplay 坐标（棋盘仍 0..~1024，右侧多出可见空间）。
2. **控制台右上锚定**：仅调 offset。原 1152×648 下面板占 40% 宽×88% 高（用户截图实测 x≈672..1136、y≈72..636，即"占满右侧"主因是小窗口）；1920×1080 下为 24% 宽×53% 高，且 16px 上/右边距。
   - ponytail(lite) 备注：更懒的做法是只改 viewport_width/height——面板本已右缘锚定，offset 调整仅为边距对称化，如需可回退此半处。

## VERIFICATION

命令与结果（Godot 4.6.1 stable console binary，headless `--script`）：

| 测试 | 结果 |
|---|---|
| `tests/unit/diagnostics/debug_console_view_test.gd` | 6 组 42 断言 PASS |
| `tests/unit/diagnostics/runtime_snapshot_sampler_test.gd` | 56 断言 PASS |
| `tests/unit/diagnostics/runtime_snapshot_schema_test.gd` | 50 断言 PASS |
| `tests/unit/runtime/level_runtime/start_run_flow_test.gd` | 63 断言 PASS |
| `tests/unit/runtime/level_runtime/fire_flow_test.gd` | 47 断言 PASS |
| `tests/unit/runtime/level_runtime/multi_emission_runtime_test.gd` | 21 断言 PASS |

`git diff --check` → rc=0（无空白错误）。

## WINDOW_EVIDENCE

- 真实非 headless Debug GUI 启动：`Godot_v4.6.1-stable_win64.exe --path .`，窗口标题 `Light_speed_singularity (DEBUG)`。
- orca computer 窗口几何：`1936×1119 @ (312,125)` = 1920×1080 客户区 + Windows 边框（含标题栏），见 `01_window_1920x1080_console_closed.png`（orca 窗口位图截取，1936×1119）。
- 交叉验证：Win32 `GetWindowRect`（SetProcessDPIAware 后）同报 1936×1119；截图像素分析显示真实 HUD 内容（左上提示文本、底部 InventoryBar），非空白帧。
- 主屏 2560×1440，1920×1080 带边框窗口可完整显示。
- （`OS.is_debug_build()` 对该 stable 二元为 true，`--script` 实测打印确认；故 Debug 控制台在真实运行中会构造。）

## POSITION_EVIDENCE

- **静态（已完成）**：`debug_console_view.gd:77-86` 锚点/offset 即位置事实——anchor_left/right=1.0（右缘锚定，窗口任意尺寸下 `offset_right=-16` 恒为右 16px），面板宽 464、高 568、上 16px；宽高与既有内容容量一致。测试无几何断言（已核 `debug_console_view_test.gd`），无测试需适配。
- **动态（PENDING，见 HUMAN_RECHECK）**：F3 打开后的实机截图未取得——合成键盘（keybd_event/SendInput/PostMessage/orca press-key）在本桌面全部无法送达任何应用（OS 层 `GetAsyncKeyState` 可见注入但应用不收；鼠标注入正常——StartRun 按钮真实点击已使 HUD 变化）；OSK 屏幕键盘方案又因活跃用户会话不断最小化/关闭窗口中断。协调者裁定：GUI 人工测试全部留给人工。

## DIFF

```diff
--- a/project.godot
+++ b/project.godot
@@ -15,6 +15,11 @@
+[display]
+
+window/size/viewport_width=1920
+window/size/viewport_height=1080
```

```diff
--- a/gameplay/diagnostics/console/debug_console_view.gd（未跟踪新文件，节选 setup()）
-	# 面板置于画面右上区域，避开既有 HintLabel / InventoryBar / StartRun UI。
+	# 面板锚定画面右上角（左右锚点=1.0，随任意窗口尺寸稳定贴右）；宽 464 / 高 568 保持内容容量，
+	# 上/右各留 16px 边距；避开左上 HintLabel / RunStartView 与底部 InventoryBar。
 	panel.offset_left = -480.0
 	panel.offset_right = -16.0
-	panel.offset_top = 72.0
-	panel.offset_bottom = 640.0
+	panel.offset_top = 16.0
+	panel.offset_bottom = 584.0
```

## RISKS

- 视口放大后无 stretch：分辨率不足的屏幕上 1920×1080 窗口可能超出屏幕（本机主屏 2560×1440 无碍）；如需适配小屏，后续可加 `window_width_override` 或 stretch，本批刻意未做。
- 控制台面板高度 568（占 1080 的 53%）：保留原内容容量未压缩；若人工验收仍嫌大，需先压缩显示行数再缩高。
- 我调试期间向用户桌面注入过窗口置顶/鼠标点击（已停止；我启动的游戏与 OSK 进程已全部结束，用户编辑器实例 pid 60968 未动）。

## HUMAN_RECHECK（人工验收清单，PENDING）

1. 编辑器 F5 运行：窗口应为 1920×1080（含系统边框 1936×1119），玩法区域坐标/棋盘位置与之前一致。
2. 按 F3：控制台出现在右上角，上/右各 16px 边距，宽约 464px，不占满右侧。
3. 字段可读（run_state/generation/emission/Particle/emitter/库存/水晶/Perf 各行完整显示）。
4. 四个按钮（刷新/生成快照/写盘/关闭）可点击生效。
5. 控制台不遮挡 HintLabel、开始运行按钮、底部 InventoryBar 与关键棋盘区。
6. 再按 F3 可关闭。

## 结论

**PASS（工程修复）／FIX-BLOCKED→人工验收 PENDING（GUI 视觉项）**
