class_name RuntimeInteractionTypes
extends RefCounted

## 运行交互共享类型契约（批次 4B-D2）。
## 职责：集中持有核心闭环原型（core_loop_prototype.gd）的运行状态枚举 RunState 与拖拽来源枚举 DragSource，
## 作为跨模块共享的稳定枚举值契约，避免枚举定义分散在关卡控制器内部导致下游自检与未来模块各自复制一份。
## 本模块只定义枚举类型与稳定数值，不持有任何函数、字段或实例状态，不参与玩法判断，不访问 Node、场景树、文件、时间或随机数。
## 不依赖 core_loop_prototype，也不依赖 Diagnostics；调用方通过 preload 路径引用本类后再访问嵌套枚举。
## 重要：每个成员的整数值已显式写出并被自检与存档/诊断边界隐式依赖，修改任意数值会破坏状态规则与存档/诊断兼容边界，禁止更改。

## 当前原型的最小运行状态。
## SETUP 表示尚未开始本次运行；PULSE_ACTIVE 表示普通脉冲仍在统一显示窗口内；
## MOVE_WINDOW 表示脉冲结束但未通关，未来可在此提交有限移动；COMPLETED 表示通关结果已成立。
## 本枚举只服务当前关卡控制器的运行阶段判定，不是完整 RunStateController。
## 数值被 core_loop_prototype 的状态机、runtime_move 自检与启动自检隐式依赖，修改会破坏状态规则与诊断兼容边界。
enum RunState {
	## 尚未开始本次运行；允许完整布置（拿取、首次放置、移动、回收、右键配置）且移动不计次。数值 0。
	SETUP = 0,
	## 普通脉冲仍在统一显示窗口内；允许拿取/首次放置/移动/回收，右键配置锁定，禁止 Space。数值 1。
	PULSE_ACTIVE = 1,
	## 脉冲结束但未通关；允许拿取/首次放置/移动/回收，右键配置锁定，已放置机关跨格成功移动消耗 runtime_move_limit。数值 2。
	MOVE_WINDOW = 2,
	## 通关结果已成立；冻结全部关卡交互，只允许 R。数值 3。
	COMPLETED = 3,
}

## 当前鼠标拖拽来源。
## NONE 表示没有拖拽；INVENTORY 表示从机关栏拿取但尚未扣库存；PLACED 表示拖动已放置机关且旧逻辑占用仍保留。
## 数值被 core_loop_prototype 的拖拽/放置/回收/取消事务与 runtime_move 自检隐式依赖，修改会破坏拖拽来源判定与诊断兼容边界。
enum DragSource {
	## 没有正在进行的拖拽。数值 0。
	NONE = 0,
	## 从机关栏拿取但尚未扣库存的拖拽来源。数值 1。
	INVENTORY = 1,
	## 拖动已放置机关的拖拽来源，旧逻辑占用仍保留。数值 2。
	PLACED = 2,
}
