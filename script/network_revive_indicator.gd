extends Node2D

## ── 架构定位 ──
## 系统：联机 HUD ｜ 层：表现（Node2D）
## 联机：进度来自 Host 快照
## 职责：被救援玩家头顶的救援进度环，由 NetworkWorld 按权威进度写入。
## 依赖：NetworkWorld（按固定节点名复用）

## 联机救援进度指示器 — 由 NetworkWorld 动态挂到"正在被救援的倒地玩家"节点上。
##
## 【与 weapon_pickup 的 HoldIndicator 的关系】
## 武器替换的进度环由"本地按住进度"驱动（父节点持状态、子节点只画）；
## 本指示器的进度来源是 Host 权威的救援进度（快照 revive_progress 字段），
## 被救援者本人和周围所有玩家都要能看到，因此改为自持 progress、
## 由 NetworkWorld 每个快照/每次权威推进时写入。
##
## 【生命周期】
## 出现针对本玩家的救援尝试时由 NetworkWorld 创建（节点名固定
## "NetworkReviveIndicator"，NetworkWorld 依赖该名字做 get_node_or_null 复用）；
## 救援取消/完成/玩家流血死亡时由 NetworkWorld 移除（queue_free）。
##
## 绘制在玩家精灵上方（z_index=20 > 精灵层），随玩家节点一起移动。

## 当前救援进度 0..1。<=0 时不绘制（NetworkWorld 会随之摘除本节点）。
var progress: float = 0.0

## 外观参数与 weapon_pickup.gd 的 HoldIndicator 默认值保持一致，视觉风格统一。
const RING_RADIUS: float = 18.0
const RING_THICKNESS: float = 3.0
## 玩家头顶偏上，避开躺地精灵本体。
const RING_OFFSET: Vector2 = Vector2(0, -48)
const BG_COLOR: Color = Color(0.0, 0.0, 0.0, 0.55)
## 进度弧用暖黄色（与武器替换环同色系），与受击红/倒地染色区分开。
const FG_COLOR: Color = Color(1.0, 0.9, 0.2, 1.0)


func _process(_delta: float) -> void:
	## progress 由 NetworkWorld 外部写入，节点自身不推进数值；
	## 每帧重绘开销可忽略（两个 draw_arc），但能保证写入后立即反映。
	queue_redraw()


func _draw() -> void:
	if progress <= 0.0:
		return
	var pts: int = 64
	# 背景圆环：完整一圈半透明黑底，让进度弧在浅色地面上也可读。
	draw_arc(RING_OFFSET, RING_RADIUS, 0, TAU, pts, BG_COLOR, RING_THICKNESS, true)
	# 进度弧线：从 12 点钟方向开始顺时针填充（与 HoldIndicator 一致）。
	var start_angle: float = -PI / 2.0
	var end_angle: float = start_angle + clampf(progress, 0.0, 1.0) * TAU
	draw_arc(RING_OFFSET, RING_RADIUS, start_angle, end_angle, pts, FG_COLOR, RING_THICKNESS, true)
