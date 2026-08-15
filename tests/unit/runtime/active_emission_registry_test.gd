extends SceneTree

## ActiveEmissionRegistry 单元测试（M4-E1；M4-E2 扩展双向 runtime_id 映射）。
## 覆盖：emission_id 单调递增（#3）；RAY/PARTICLE 共用同一 ID 空间；多 emission 并存（#4）；finish 一个不清其它（#5）；
##   最后一个 finish 才 has_active==false（#6）；clear 清活动但计数器不回拨（R 后不复用 emission_id）；get_form/get_generation 只读诊断。
## M4-E2 新增（spec 十三.1~6）：generation/form/runtime_id 三身份不混用；emission_id↔runtime_id 双向映射；
##   bind/unbind/find 反查；unbind 不 mark_finished（emission 是否结束由 LRC 据 get_emission_runtime_count 判定）；
##   同 generation 多 emission 并存；一次 emission 多 runtime；clear 清双向映射但 allocator 不回拨。
## headless extends SceneTree，由 Godot --script 运行；通过 preload 引用模块避开全局 class_name 缓存问题。
## 全部失败项收集后统一退出（任一失败 quit(1)）。

const _Registry: GDScript = preload("res://gameplay/runtime/active_emission_registry.gd")
const _LightEmissionTypes: GDScript = preload("res://gameplay/light/light_emission_types.gd")

const _GROUP_COUNT: int = 17

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_test_01_empty_registry()
	_test_02_emission_id_monotonic()
	_test_03_ray_particle_shared_id_space()
	_test_04_multi_emission_coexist()
	_test_05_finish_one_keeps_others()
	_test_06_last_finish_has_active_false()
	_test_07_clear_keeps_counter()
	_test_08_get_form_diagnostics()
	_test_09_allocate_records_generation_and_form()
	_test_10_bind_particle_runtime_bidirectional()
	_test_11_find_emission_for_runtime_reverse_lookup()
	_test_12_unbind_does_not_mark_finished()
	_test_13_one_emission_multiple_runtimes()
	_test_14_clear_clears_bidirectional_mapping()
	_test_15_duplicate_bind_idempotent()
	_test_16_cross_emission_rebind_rejected_zero_side_effect()
	_test_17_readonly_emission_enumeration()
	_report()
	quit(0 if _failures.is_empty() else 1)


# ===== 测试 =====

## 1. 空 registry：初始 active_count==0、has_active==false、total_allocated==0、bound_runtime_count==0。
func _test_01_empty_registry() -> void:
	const G: String = "01_空registry"
	var r: _Registry = _Registry.new()
	_check(G, r.active_count() == 0, "初始 active_count 期望 0。")
	_check(G, not r.has_active(), "初始 has_active 期望 false。")
	_check(G, r.get_total_allocated() == 0, "初始 total_allocated 期望 0。")
	_check(G, r.get_next_emission_id() == 1, "初始 next_emission_id 期望 1。")
	_check(G, r.get_bound_runtime_count() == 0, "初始 bound_runtime_count 期望 0。")
	_check(G, r.find_emission_for_runtime(10) == 0, "初始 find_emission_for_runtime 期望 0。")


## 2. emission_id 单调递增：连续 allocate 返回 1,2,3；total_allocated 同步。
func _test_02_emission_id_monotonic() -> void:
	const G: String = "02_emission_id单调递增"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	var e2: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	var e3: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	_check(G, e1 == 1, "首次 allocate 期望 1，实际 %d。" % e1)
	_check(G, e2 == 2, "二次 allocate 期望 2，实际 %d。" % e2)
	_check(G, e3 == 3, "三次 allocate 期望 3，实际 %d。" % e3)
	_check(G, e1 < e2 and e2 < e3, "emission_id 必须严格单调递增。")
	_check(G, r.get_total_allocated() == 3, "total_allocated 期望 3。")
	_check(G, r.active_count() == 3, "三颗均活动，active_count 期望 3。")


## 3. RAY/PARTICLE 共用同一 ID 空间：两形态 allocate 在同一单调序列，不分区。
func _test_03_ray_particle_shared_id_space() -> void:
	const G: String = "03_RAY_PARTICLE共用ID空间"
	var r: _Registry = _Registry.new()
	var er: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	var ep: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, er == 1 and ep == 2, "RAY/PARTICLE 共用同一 ID 空间：期望 1,2，实际 %d,%d。" % [er, ep])
	_check(G, r.get_form(er) == _LightEmissionTypes.LightForm.RAY, "e1 form 期望 RAY。")
	_check(G, r.get_form(ep) == _LightEmissionTypes.LightForm.PARTICLE, "e2 form 期望 PARTICLE。")


## 4. 多 emission 并存（含同 generation）：同 generation 三颗 allocate 后 active_count==3、has_active==true。
func _test_04_multi_emission_coexist() -> void:
	const G: String = "04_多emission并存同generation"
	var r: _Registry = _Registry.new()
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	_check(G, r.active_count() == 3, "三颗并存 active_count 期望 3，实际 %d。" % r.active_count())
	_check(G, r.has_active(), "三颗并存 has_active 期望 true。")


## 5. finish 一个不清其它：三颗 allocate → mark_finished(2) → 另两颗仍活动。
func _test_05_finish_one_keeps_others() -> void:
	const G: String = "05_finish一个不清其它"
	var r: _Registry = _Registry.new()
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 1
	r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 2
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 3
	r.mark_finished(2)
	_check(G, r.active_count() == 2, "finish e2 后 active_count 期望 2，实际 %d。" % r.active_count())
	_check(G, r.has_active(), "finish e2 后仍有活动 emission。")
	_check(G, r.get_form(1) == _LightEmissionTypes.LightForm.RAY, "e1 仍活动（form 可查）。")
	_check(G, r.get_form(3) == _LightEmissionTypes.LightForm.RAY, "e3 仍活动（form 可查）。")
	_check(G, r.get_form(2) == -1, "e2 已 finish，get_form 期望 -1。")
	_check(G, not r.is_active(2), "e2 is_active 期望 false。")
	_check(G, r.is_active(1) and r.is_active(3), "e1/e3 is_active 期望 true。")


## 6. 最后一个 finish 才 has_active==false：逐一 finish，仅最后一颗 finish 后 has_active 转 false。
func _test_06_last_finish_has_active_false() -> void:
	const G: String = "06_最后finish才无活动"
	var r: _Registry = _Registry.new()
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 1
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 2
	r.mark_finished(1)
	_check(G, r.has_active(), "finish e1 后 e2 仍活动，has_active 期望 true。")
	_check(G, r.active_count() == 1, "active_count 期望 1。")
	r.mark_finished(2)
	_check(G, not r.has_active(), "最后 e2 finish 后 has_active 期望 false。")
	_check(G, r.active_count() == 0, "active_count 期望 0。")
	# finish 未登记 / 重复 finish 安全 no-op。
	r.mark_finished(999)
	r.mark_finished(1)
	_check(G, r.active_count() == 0, "finish 未登记/重复 id 安全 no-op，active_count 仍 0。")


## 7. clear 清活动但计数器不回拨（R 后不复用 emission_id）：clear 后 active 归零，但 total_allocated / next_emission_id 不回拨。
func _test_07_clear_keeps_counter() -> void:
	const G: String = "07_clear不清计数器"
	var r: _Registry = _Registry.new()
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 1
	r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 2
	_check(G, r.get_total_allocated() == 2, "clear 前 total_allocated 期望 2。")
	r.clear()
	_check(G, r.active_count() == 0, "clear 后 active_count 期望 0。")
	_check(G, not r.has_active(), "clear 后 has_active 期望 false。")
	_check(G, r.get_total_allocated() == 2, "clear 后 total_allocated 仍 2（R 后不复用 emission_id）。")
	_check(G, r.get_next_emission_id() == 3, "clear 后 next_emission_id 仍 3。")
	# clear 后新 allocate 从 3 起（不复用 1/2）。
	var e3: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	_check(G, e3 == 3, "clear 后新 allocate 期望 3（不复用），实际 %d。" % e3)


## 8. get_form / get_generation 只读诊断：未登记返回 -1；登记的返回原 form / generation。
func _test_08_get_form_diagnostics() -> void:
	const G: String = "08_get_form_generation只读诊断"
	var r: _Registry = _Registry.new()
	_check(G, r.get_form(1) == -1, "未登记 emission_id get_form 期望 -1。")
	_check(G, r.get_generation(1) == -1, "未登记 emission_id get_generation 期望 -1。")
	var e1: int = r.allocate(7, _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, r.get_form(e1) == _LightEmissionTypes.LightForm.PARTICLE, "登记后 get_form 期望 PARTICLE。")
	_check(G, r.get_generation(e1) == 7, "登记后 get_generation 期望传入的 7。")


## 9. allocate 记录 generation 与 form（三身份不混用）：emission_id 单调，generation 只原样存储不参与单调，form 区分形态。
func _test_09_allocate_records_generation_and_form() -> void:
	const G: String = "09_allocate记录generation_form"
	var r: _Registry = _Registry.new()
	# 同 generation（epoch=5）两次发射：emission_id 递增，generation 相同。
	var e1: int = r.allocate(5, _LightEmissionTypes.LightForm.RAY)
	var e2: int = r.allocate(5, _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, e1 == 1 and e2 == 2, "同 generation 下 emission_id 仍单调（1,2）。")
	_check(G, r.get_generation(e1) == 5 and r.get_generation(e2) == 5, "两 emission 共享同一 generation 5。")
	_check(G, r.get_form(e1) != r.get_form(e2), "两 emission form 不同（RAY vs PARTICLE）。")
	# 不同 generation：emission_id 继续单调，generation 各自记录。
	var e3: int = r.allocate(6, _LightEmissionTypes.LightForm.RAY)
	_check(G, e3 == 3, "新 generation 下 emission_id 继续 3（不回拨）。")
	_check(G, r.get_generation(e3) == 6, "e3 generation 期望 6（与 e1/e2 的 5 区分）。")


## 10.（spec 十三.2/3）bind_particle_runtime 建立双向映射：runtime 10→emission1、runtime 11→emission2；find 反查正确。
func _test_10_bind_particle_runtime_bidirectional() -> void:
	const G: String = "10_bind建立双向映射"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 1
	var e2: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 2
	r.bind_particle_runtime(e1, 10)
	r.bind_particle_runtime(e2, 11)
	_check(G, r.find_emission_for_runtime(10) == e1, "runtime 10 应映射到 emission1。")
	_check(G, r.find_emission_for_runtime(11) == e2, "runtime 11 应映射到 emission2。")
	_check(G, r.get_emission_runtime_count(e1) == 1, "emission1 runtime 数期望 1。")
	_check(G, r.get_emission_runtime_count(e2) == 1, "emission2 runtime 数期望 1。")
	_check(G, r.get_bound_runtime_count() == 2, "bound_runtime_count 期望 2。")
	# 未登记 emission bind 安全 no-op。
	r.bind_particle_runtime(999, 42)
	_check(G, r.find_emission_for_runtime(42) == 0, "未登记 emission bind 应 no-op，runtime 42 无映射。")


## 11.（spec 十三.4 前置）find_emission_for_runtime 反查：未绑定返回 0；绑定返回所属 emission。
func _test_11_find_emission_for_runtime_reverse_lookup() -> void:
	const G: String = "11_find反查"
	var r: _Registry = _Registry.new()
	_check(G, r.find_emission_for_runtime(99) == 0, "未绑定 runtime find 期望 0。")
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	r.bind_particle_runtime(e1, 7)
	_check(G, r.find_emission_for_runtime(7) == e1, "绑定后 find 应返回 emission1。")
	_check(G, r.find_emission_for_runtime(8) == 0, "未绑定的另一 runtime 仍期望 0。")


## 12.（spec 十三.4）unbind 不 mark_finished：解绑 emission1 的 runtime 后 emission1 仍活动（emission 是否结束由 LRC 据 runtime_count 判定）；
##     emission2 不受影响；反向索引同步删除。
func _test_12_unbind_does_not_mark_finished() -> void:
	const G: String = "12_unbind不mark_finished"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 1
	var e2: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 2
	r.bind_particle_runtime(e1, 10)
	r.bind_particle_runtime(e2, 11)
	# 解绑 runtime 10（emission1 的唯一 runtime）。
	var unbound_eid: int = r.unbind_particle_runtime(10)
	_check(G, unbound_eid == e1, "unbind 应返回被解绑 runtime 原属 emission1。")
	_check(G, r.find_emission_for_runtime(10) == 0, "解绑后 runtime 10 反向索引应删除。")
	_check(G, r.get_emission_runtime_count(e1) == 0, "emission1 runtime 数期望 0。")
	# 关键：unbind 不 mark_finished——emission1 仍活动（是否结束由 LRC 判定）。
	_check(G, r.is_active(e1), "unbind 后 emission1 仍活动（不 mark_finished）。")
	_check(G, r.active_count() == 2, "两 emission 均仍活动，active_count 期望 2。")
	# emission2 不受影响。
	_check(G, r.find_emission_for_runtime(11) == e2, "emission2 的 runtime 11 映射不受影响。")
	_check(G, r.get_emission_runtime_count(e2) == 1, "emission2 runtime 数仍 1。")
	# 再 mark_finished emission1 才移出活动表。
	r.mark_finished(e1)
	_check(G, not r.is_active(e1), "mark_finished 后 emission1 不再活动。")
	_check(G, r.active_count() == 1, "active_count 期望 1。")
	# 未绑定 runtime unbind 安全 no-op（返回 0）。
	_check(G, r.unbind_particle_runtime(999) == 0, "未绑定 runtime unbind 应返回 0。")


## 13.（一次 emission 多 runtime）同一 emission 绑定多个 runtime：count 反映全部；逐个 unbind 至 0 期间 emission 始终活动。
func _test_13_one_emission_multiple_runtimes() -> void:
	const G: String = "13_一次emission多runtime"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	r.bind_particle_runtime(e1, 20)
	r.bind_particle_runtime(e1, 21)
	r.bind_particle_runtime(e1, 22)
	_check(G, r.get_emission_runtime_count(e1) == 3, "emission1 绑 3 runtime 后 count 期望 3。")
	_check(G, r.get_bound_runtime_count() == 3, "bound_runtime_count 期望 3。")
	_check(G, r.find_emission_for_runtime(21) == e1, "runtime 21 应映射到 emission1。")
	# 解绑一个：count 2，emission 仍活动。
	r.unbind_particle_runtime(21)
	_check(G, r.get_emission_runtime_count(e1) == 2, "解绑 1 个后 count 期望 2。")
	_check(G, r.find_emission_for_runtime(21) == 0, "解绑的 runtime 反向索引删除。")
	_check(G, r.is_active(e1), "emission1 仍活动。")
	# mark_finished 清整条 emission 时残留 runtime 反向索引一并清理（防御性兜底）。
	r.mark_finished(e1)
	_check(G, r.find_emission_for_runtime(20) == 0 and r.find_emission_for_runtime(22) == 0, "mark_finished 后残留 runtime 反向索引一并清理。")
	_check(G, r.get_bound_runtime_count() == 0, "mark_finished 后 bound_runtime_count 期望 0。")


## 14.（spec 十三.6）clear 清双向映射但 allocator 不回拨：bind 后 clear，映射全清但 emission_id / runtime 反向索引归零、计数器不回拨。
func _test_14_clear_clears_bidirectional_mapping() -> void:
	const G: String = "14_clear清双向映射"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 1
	var e2: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)  # 2
	r.bind_particle_runtime(e1, 30)
	r.bind_particle_runtime(e1, 31)
	_check(G, r.get_bound_runtime_count() == 2, "clear 前 bound_runtime_count 期望 2。")
	r.clear()
	_check(G, r.active_count() == 0, "clear 后 active_count 期望 0。")
	_check(G, r.get_bound_runtime_count() == 0, "clear 后 bound_runtime_count 期望 0（反向索引全清）。")
	_check(G, r.find_emission_for_runtime(30) == 0, "clear 后 runtime 30 反向索引已清。")
	_check(G, r.get_emission_runtime_count(e1) == 0, "clear 后 emission1 runtime 数期望 0（已不存在）。")
	_check(G, r.get_total_allocated() == 2, "clear 后 total_allocated 仍 2（计数器不回拨）。")
	_check(G, r.get_next_emission_id() == 3, "clear 后 next_emission_id 仍 3（不回拨）。")
	# clear 后新 allocate 从 3 起（不复用 1/2）。
	var e3: int = r.allocate(1, _LightEmissionTypes.LightForm.RAY)
	_check(G, e3 == 3, "clear 后新 allocate 期望 3（不复用）。")


## 15.（M4-E2.1 bind/rebind 原子一致性）duplicate bind 幂等：同 emission 重复 bind 同 runtime_id 不重复 append forward（count 仍 1），反向映射不变。
func _test_15_duplicate_bind_idempotent() -> void:
	const G: String = "15_duplicate_bind幂等"
	var r: _Registry = _Registry.new()
	var e1: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)
	_check(G, r.bind_particle_runtime(e1, 100) == true, "首次 bind 应返回 true。")
	_check(G, r.bind_particle_runtime(e1, 100) == true, "重复 bind 同 emission + 同 runtime 应幂等返回 true。")
	_check(G, r.get_emission_runtime_count(e1) == 1, "重复 bind 不应重复 append forward，count 期望 1，实际 %d。" % [r.get_emission_runtime_count(e1)])
	_check(G, r.find_emission_for_runtime(100) == e1, "反向映射仍指向 e1。")
	_check(G, r.get_bound_runtime_count() == 1, "bound_runtime_count 期望 1，实际 %d。" % [r.get_bound_runtime_count()])
	_check(G, r.active_count() == 1, "active_count 期望 1。")


## 16.（M4-E2.1 bind/rebind 原子一致性）cross-emission rebind 明确拒绝 + 零副作用：runtime_id 已属 A 再绑 B 被拒（返回 false），两侧映射完全不变；
##     mark_finished A 不删 B 反向；unbind 后无 stale forward entry。
func _test_16_cross_emission_rebind_rejected_zero_side_effect() -> void:
	const G: String = "16_cross_emission_rebind拒绝零副作用"
	var r: _Registry = _Registry.new()
	var eA: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 1
	var eB: int = r.allocate(1, _LightEmissionTypes.LightForm.PARTICLE)  # 2
	_check(G, r.bind_particle_runtime(eA, 200) == true, "runtime 200 绑 A 应成功。")
	# runtime 200 已属 A，尝试绑 B → 明确拒绝，零副作用。
	_check(G, r.bind_particle_runtime(eB, 200) == false, "cross-emission rebind 应被拒绝（返回 false）。")
	# 拒绝后两侧映射完全不变。
	_check(G, r.find_emission_for_runtime(200) == eA, "拒绝后反向映射不变，仍指向 A。")
	_check(G, r.get_emission_runtime_count(eA) == 1, "A 的 forward 不变（count 1）。")
	_check(G, r.get_emission_runtime_count(eB) == 0, "B 未获得该 runtime（count 0），无 stale forward。")
	_check(G, r.get_bound_runtime_count() == 1, "bound_runtime_count 仍 1。")
	_check(G, r.is_active(eA) and r.is_active(eB), "A/B 均仍活动。")
	# mark_finished A 不影响 B：先给 B 绑独立 runtime 201，再 finish A。
	_check(G, r.bind_particle_runtime(eB, 201) == true, "runtime 201 绑 B 应成功。")
	r.mark_finished(eA)
	_check(G, r.find_emission_for_runtime(201) == eB, "mark_finished A 不应删除 B 的 runtime 201 反向映射。")
	_check(G, r.is_active(eB), "B 仍活动。")
	_check(G, r.find_emission_for_runtime(200) == 0, "A finish 后其 runtime 200 反向应已清。")
	_check(G, r.active_count() == 1, "active_count 期望 1（只剩 B）。")
	# unbind 后无 stale forward entry。
	_check(G, r.unbind_particle_runtime(201) == eB, "unbind 201 应返回 eB。")
	_check(G, r.get_emission_runtime_count(eB) == 0, "unbind 201 后 B 的 forward count 0，无 stale。")
	_check(G, r.find_emission_for_runtime(201) == 0, "unbind 后反向已删。")
	_check(G, r.get_bound_runtime_count() == 0, "bound_runtime_count 期望 0。")


## 17. D7-R1 只读枚举：get_active_emission_ids 按 allocate 顺序；get_emission_runtime_ids 返回独立副本；未登记/finish/clear 边界。
func _test_17_readonly_emission_enumeration() -> void:
	const G: String = "17_只读枚举访问器"
	var r: _Registry = _Registry.new()
	_check(G, r.get_active_emission_ids().is_empty(), "初始枚举应为空。")
	_check(G, r.get_emission_runtime_ids(99).is_empty(), "未登记 emission 的 runtime 枚举应为空。")
	var e1: int = r.allocate(2, _LightEmissionTypes.LightForm.RAY)
	var e2: int = r.allocate(2, _LightEmissionTypes.LightForm.PARTICLE)
	r.bind_particle_runtime(e2, 5)
	r.bind_particle_runtime(e2, 6)
	var ids: Array[int] = r.get_active_emission_ids()
	_check(G, ids == [e1, e2], "枚举应按 allocate 顺序 [1,2]，实际 %s。" % str(ids))
	var runtime_ids: Array[int] = r.get_emission_runtime_ids(e2)
	_check(G, runtime_ids == [5, 6], "e2 runtime 枚举应为 [5,6]，实际 %s。" % str(runtime_ids))
	runtime_ids.append(7)
	_check(G, r.get_emission_runtime_ids(e2).size() == 2, "修改返回副本不得影响 registry 内部 runtime_ids。")
	r.mark_finished(e2)
	_check(G, r.get_emission_runtime_ids(e2).is_empty(), "finish 后该 emission runtime 枚举应为空。")
	_check(G, r.get_active_emission_ids() == [e1], "finish 后枚举只剩 e1。")
	r.clear()
	_check(G, r.get_active_emission_ids().is_empty(), "clear 后枚举应为空。")


# ===== 断言与报告 =====

## 单项断言。
func _check(group: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures.append("[%s] %s" % [group, detail])


## 输出测试摘要并退出。
func _report() -> void:
	var passed_checks: int = _checks - _failures.size()
	print("==== ActiveEmissionRegistry 测试摘要（M4-E2）====")
	print("测试组数：%d" % _GROUP_COUNT)
	print("断言总数：%d" % _checks)
	print("通过断言：%d" % passed_checks)
	print("失败断言：%d" % _failures.size())
	if _failures.is_empty():
		print("结果：PASS")
	else:
		print("结果：FAIL")
		for failure: String in _failures:
			print(failure)
