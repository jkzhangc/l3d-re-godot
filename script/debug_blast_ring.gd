extends Node2D

## ── 架构定位 ──
## 系统：调试可视化 ｜ 层：工具（Node2D，**仅调试期生成**）
## 联机：两端各自本地绘制（不广播、不吃快照）
## 职责：爆炸范围指示环 —— TAB 打开 `Global.debug_visuals` 后，每次爆炸在爆心画出实际半径圆环，
##       并**停留 2 秒**（用户 2026-10-01 需求），用于目视核对「这一炸到底该波及到谁」。
## 依赖：`Global.debug_visuals`（总开关）、`Global.get_ui_font()`（半径文字）
##
## 【为什么两个 hook 都调这里】爆炸只有两个入口，别无他处：
##   · 权威结算 —— `bullet.gd::_explode()`（单机 / Host；手雷、火箭筒、榴弹系都走它）
##   · 客户端表现 —— `NetworkWorld.bullet_explode_effect()`（Client 收到广播后播同一套表现）
## 两处都调本脚本的静态入口 → 不会漏任何一种爆炸武器，也不会在两端各画一套不同的东西。
##
## 【为什么用运行时 load() 造节点】脚本自己 preload 自己会形成循环引用（项目既有铁律：
## self-ref 一律运行时 `load()`）。这里每次爆炸只查一次缓存，开销可忽略。

## 停留总时长（用户要求「最好停留 2 秒」）。
const LINGER_SECONDS: float = 2.0
## 末尾淡出时长（**含在**总时长内，不额外延长）。
const FADE_SECONDS: float = 0.7
const LINE_WIDTH: float = 3.0
## 半径文字字号：必须是 12 的整倍（像素字体铁律）。
const FONT_SIZE: int = 24
## 对敌伤害半径（主环，橙色）。
const COLOR_BLAST := Color(1.0, 0.62, 0.15)
## 对玩家自爆半径（危险区，红色；仅在与主环不同时才另画）。
const COLOR_SELF := Color(1.0, 0.25, 0.25)
## 画在场景实体之上（爆炸表现也是同层，调试环必须压得住）。
const Z_INDEX_DEBUG: int = 4096

var blast_radius: float = 0.0
var self_radius: float = 0.0   ## 0 或与 blast 相同 = 不另画（对玩家无自爆 / 半径一致）
var _age: float = 0.0


## 唯一入口：在爆心画环并停留 `LINGER_SECONDS` 秒。
## `Global.debug_visuals` 关闭时**不生成任何节点**（零开销、也不会污染正常游玩）。
## `parent` 传 `get_tree().current_scene`（与爆炸表现同层）。
static func show_ring(center: Vector2, blast_radius: float, parent: Node,
		self_radius: float = 0.0) -> Node2D:
	if parent == null or not is_instance_valid(parent) or blast_radius <= 0.0:
		return null
	var g: Node = parent.get_node_or_null("/root/Global")
	if g == null or not bool(g.get("debug_visuals")):
		return null
	var script: GDScript = load("res://script/debug_blast_ring.gd")
	if script == null:
		return null
	var ring: Node2D = script.new() as Node2D
	if ring == null:
		return null
	ring.set("blast_radius", blast_radius)
	ring.set("self_radius", maxf(self_radius, 0.0))
	ring.z_index = Z_INDEX_DEBUG
	parent.add_child(ring)
	## ⚠ 位置在 `add_child` 之后再设：未入树时 `global_position` 语义不完整。
	ring.global_position = center
	return ring


func _process(delta: float) -> void:
	_age += delta
	var left: float = LINGER_SECONDS - _age
	if left <= 0.0:
		queue_free()
		return
	## 末尾淡出（不延长总停留时长）
	if left < FADE_SECONDS:
		modulate.a = clampf(left / FADE_SECONDS, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	## 半透明填充 + 描边：既看得见覆盖面积，也不会糊住底下的角色。
	draw_circle(Vector2.ZERO, blast_radius, Color(COLOR_BLAST.r, COLOR_BLAST.g, COLOR_BLAST.b, 0.10))
	draw_arc(Vector2.ZERO, blast_radius, 0.0, TAU, 96, COLOR_BLAST, LINE_WIDTH, true)
	if self_radius > 0.0 and not is_equal_approx(self_radius, blast_radius):
		draw_arc(Vector2.ZERO, self_radius, 0.0, TAU, 96, COLOR_SELF, LINE_WIDTH, true)
	## 爆心十字
	var arm: float = 10.0
	draw_line(Vector2(-arm, 0.0), Vector2(arm, 0.0), COLOR_BLAST, LINE_WIDTH)
	draw_line(Vector2(0.0, -arm), Vector2(0.0, arm), COLOR_BLAST, LINE_WIDTH)
	## 半径文字（调参时直接读数，不用去翻 .tres）
	var font: Font = Global.get_ui_font()
	if font == null:
		return
	var text: String = "R=%.0f" % blast_radius
	if self_radius > 0.0 and not is_equal_approx(self_radius, blast_radius):
		text += " / 自伤=%.0f" % self_radius
	draw_string(font, Vector2(-blast_radius, -blast_radius - 6.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, COLOR_BLAST)
