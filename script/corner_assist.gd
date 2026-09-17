class_name CornerAssist
extends RefCounted

## ── 架构定位 ──
## 系统：移动手感 ｜ 层：玩法（纯逻辑，RefCounted 全 static）
## 联机：不涉及（单机 / Host / Client 各自驱动自己的实体）
## 职责：像素级蹭墙 / 拐角平滑的共用算法 —— 某轴位移被静态墙面挡住时，沿另一轴做限速侧移。
## 依赖：CharacterBody2D（被测实体）、project.godot 的 2d_physics 图层定义（图块 = bit 1）

## 像素级蹭墙 / 拐角平滑 —— 玩家与敌人共用的纯逻辑实现（无状态，全部 static）。
##
## 【这是什么】
## 角色贴着墙走向门框 / 墙角时，只要横向错位一两像素，碰撞矩形就会顶在凸角上停住。
## 本模块在「某一轴的位移被挡住」时，沿**另一轴**做限速小位移，把角色平滑蹭到能通过的
## 位置 —— 也就是以撒的结合那种贴着门框滑/蹭的手感。
##
## 【三层手感】
##   ① 常规位移仍由 `move_and_slide()` 负责，斜向顶墙天然会沿墙滑行（这一层不需要额外代码）；
##   ② 被挡时做限速侧移修正：每帧最多挪 `speed × delta`，因此观感是几帧内平滑蹭过去，
##      而不是一帧瞬移；畅通时**完全不介入**；
##   ③ 蹭不开就原样返回 false，不产生任何额外位移。
##
## 【四个关键实现要点（都踩过坑，改之前先读）】
##   1. **按轴修正**：阻挡来自轴对齐的墙体，所以要修正的是「另一条轴」。
##      早期实现取「移动方向的垂线」作修正轴，斜向移动时垂线也是斜的，会把角色推向
##      错误方向 —— 表现为"有时有效果、有时反而被弹开"。
##   2. **两步判定**：把「侧移 + 位移」合成一次斜向扫掠（`test_move(motion + offset)`）
##      在角色**贴平墙面**时必然切过墙角，`test_move` 恒为真 → 永远求不出解 → 蹭墙完全失效。
##      必须拆成「纯侧移安全」+「侧移到位后再测位移」两步。
##   3. **只对静态世界几何生效**：探测期间把 `collision_mask` 临时收窄到 `world_mask`
##      （默认仅"图块"层）。否则玩家 / 敌人 / 掉落物的碰撞体会让探测失败 —— 本作导演持续在
##      玩家身边刷怪，不收窄的话蹭墙会"时不时失效"（实测 `test_move` 确实遵守 `collision_mask`）。
##   4. **修正方向跟随玩家入力**：同一距离两侧都可行时优先采纳玩家在该轴上的入力方向，
##      避免把角色推向玩家没在按的一侧。

const SIDES_POS: Array[float] = [1.0, -1.0]
const SIDES_NEG: Array[float] = [-1.0, 1.0]

## 默认只把"图块"层算作静态世界几何（project.godot: 2d_physics/layer_1 = "图块"，bit 1）。
const WORLD_LAYER_BIT: int = 1


## 带蹭墙辅助的移动入口：先按需侧移，再执行 `body.move_and_slide()`。
## 返回本帧是否施加了侧移修正（便于调试与测试）。
static func move_with_assist(body: CharacterBody2D, velocity: Vector2, enabled: bool,
		speed: float, max_shift: float, step: float, follow_input: bool,
		world_mask: int = WORLD_LAYER_BIT) -> bool:
	if not enabled or velocity.is_zero_approx():
		body.move_and_slide()
		return false

	var dt: float = body.get_physics_process_delta_time()
	var nudge: Vector2 = nudge_for(body, velocity.normalized(), velocity * dt,
		max_shift, step, follow_input, world_mask)
	if nudge == Vector2.ZERO:
		body.move_and_slide()
		return false

	var max_step: float = maxf(speed, 0.0) * dt
	body.global_position += nudge.normalized() * minf(nudge.length(), max_step)
	body.move_and_slide()
	return true


## 计算蹭墙修正向量（**未限速**，返回"理想修正量"；ZERO 表示当前无需修正）。
##
## 只对「正在被静态几何挡住的那一轴」做横向修正：水平推不动就沿垂直蹭，反之亦然。
static func nudge_for(body: CharacterBody2D, dir: Vector2, motion: Vector2,
		max_shift: float, step: float, follow_input: bool,
		world_mask: int = WORLD_LAYER_BIT) -> Vector2:
	var nudge := Vector2.ZERO
	var motion_x := Vector2(motion.x, 0.0)
	var motion_y := Vector2(0.0, motion.y)
	var gt: Transform2D = body.global_transform

	# 水平推不动 → 沿垂直方向蹭（例如撞在门框侧柱上，需要上下错开才进得去）
	if absf(dir.x) > 0.01 and absf(motion_x.x) > 0.01 and _hits(body, gt, motion_x, world_mask):
		var shift_y: float = _probe(body, motion_x, Vector2(0.0, 1.0), dir.y,
			max_shift, step, follow_input, world_mask)
		if shift_y != 0.0:
			nudge.y = shift_y

	# 垂直推不动 → 沿水平方向蹭
	if absf(dir.y) > 0.01 and absf(motion_y.y) > 0.01 and _hits(body, gt, motion_y, world_mask):
		var shift_x: float = _probe(body, motion_y, Vector2(1.0, 0.0), dir.x,
			max_shift, step, follow_input, world_mask)
		if shift_x != 0.0:
			nudge.x = shift_x

	return nudge


## 只对静态世界几何做运动测试：探测期间把碰撞掩码临时收窄到 `world_mask`，测完立即还原。
## `world_mask = 0` 表示不做收窄（沿用 body 自身掩码）。
static func _hits(body: CharacterBody2D, from: Transform2D, motion: Vector2, world_mask: int) -> bool:
	if world_mask == 0:
		return body.test_move(from, motion)
	var saved: int = body.collision_mask
	body.collision_mask = world_mask
	var hit: bool = body.test_move(from, motion)
	body.collision_mask = saved
	return hit


## 由近到远试探沿 `axis` 的侧移，返回第一个能让 `blocked_motion` 通行的带符号距离（0 = 无解）。
##
## `input_sign` 是修正轴上的入力分量（正负；0 = 没按那一轴），用于打破同距离的左右僵持。
static func _probe(body: CharacterBody2D, blocked_motion: Vector2, axis: Vector2,
		input_sign: float, max_shift: float, step: float, follow_input: bool,
		world_mask: int) -> float:
	if step <= 0.0 or max_shift <= 0.0:
		return 0.0

	var sides: Array[float] = SIDES_POS
	if follow_input and input_sign < 0.0:
		sides = SIDES_NEG

	var gt: Transform2D = body.global_transform
	var steps: int = int(floor(max_shift / step))
	for i in range(1, steps + 1):
		var dist: float = step * float(i)
		for side: float in sides:
			var offset: Vector2 = axis * dist * side
			if _hits(body, gt, offset, world_mask):
				continue   ## 纯侧移会撞 → 不安全（也覆盖侧移途中的中间位置）
			# 角色无旋转，translated 等价于把原点平移到侧移后的位置
			if _hits(body, gt.translated(offset), blocked_motion, world_mask):
				continue   ## 侧移到位后仍然过不去 → 这个距离没意义
			return dist * side
	return 0.0
