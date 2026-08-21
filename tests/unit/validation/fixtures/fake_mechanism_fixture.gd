extends Node2D

## AF-06 测试 fixture：可配置机关实例（AF-02 镜像契约面）。
## get_light_interaction_forms() 返回可配置数组，供 ValidatorCore Interaction 域
##   镜像一致性校验构造 命中/偏差/缺失 三类用例；不承载任何玩法。


## 实例声明的光交互形态镜像（子集 of {RAY, PARTICLE}）。
var interaction_forms: Array = []


## AF-02 机关镜像契约面：返回实例声明支持的光形态 token。
func get_light_interaction_forms() -> Array:
	return interaction_forms
