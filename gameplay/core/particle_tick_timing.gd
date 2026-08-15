extends RefCounted

## 光粒 Tick 现实 cadence 共享常量（D7-4 B4b-2）。
## 职责：集中保存光粒整数 Tick 与现实秒数之间的唯一换算系数 TICK_SECONDS = 0.1，
##   作为“1 整数 Tick = 0.1 秒现实时间”的单一事实来源，供光粒运行期 Tick 泵（ParticleTickPump 的 await 间隔）
##   与光粒视觉 Tween 时长换算（ParticleVisualController 的 duration_ticks * TICK_SECONDS）共同读取。
##   本模块是 0.1 秒字面量的唯一出现点——运行期与视觉层不得各自维护第二份 0.1 常量。
## 位置：位于 gameplay/core 下（跨层中性目录）；既不属于 gameplay/particle 调度域，也不属于 gameplay/runtime 泵域或
##   gameplay/visuals 视觉域，避免任何一方“拥有” cadence 而迫使另一方反向依赖。运行期泵与视觉控制器只单向 preload 本模块。
## 依赖：不 preload 任何游戏脚本；不引用 ParticleTickPump / ParticleScheduler / ParticleVisualController / 任何 Node。
## 不负责：SceneTreeTimer 创建、await 循环、Tween 创建、gameplay Tick 推进、视觉节点管理——这些由各自所有者负责；
##   本模块只提供冻结的换算系数。
## 边界条件：TICK_SECONDS 冻结 0.1；修改它同时影响运行期 await 间隔与视觉 Tween 时长（二者必须同步，这正是单一来源的目的）。
##   gameplay Tick 真值仍为 ParticleScheduler._current_tick 整数递增；本系数只把整数 Tick 换算为现实秒数，不成为 gameplay 状态。
## 类型约束：不加 class_name（与 GridMetrics 一致），调用方一律 preload() 引用以避开 MCP run_project 未重建全局 class 缓存问题。


## 1 整数光粒 Tick 对应的现实秒数（冻结，0.1 秒字面量唯一出现点）。
## 运行期：ParticleTickPump.await 间隔 = TICK_SECONDS；视觉：Tween duration = duration_ticks * TICK_SECONDS。
## 二者经同一本常量换算，保证视觉 Tween 与 gameplay Tick 现实节奏一致，不形成两份独立 0.1 常量。
const TICK_SECONDS: float = 0.1
