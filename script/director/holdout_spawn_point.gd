@tool
class_name HoldoutSpawnPoint extends Node2D

## ── 架构定位 ──
## 系统：防守战（HoldoutMachine） ｜ 层：玩法（Node2D，关卡作者标记）
## 联机：仅单机 / Host —— 坐标在防守战开始时被写进事件配置，Client 不需要
## 职责：防守战**固定刷怪点**标记。挂上之后，防守战每批敌人在这些点之间**轮转均分**
##       （5 只 / 3 点 → 2、2、1）；一个都没挂则完全沿用原来的"屏幕外刷"。
## 依赖：HoldoutMachine._collect_spawn_points → EventManager → Director.spawn_horde_nodes_at_positions

## 【为什么需要它】2026-09-25 用户需求：
## 屏外刷法只保证"玩家看不到凭空出现"，位置完全由算法决定 ——
## 想要"从走廊两端 / 楼梯口 / 破窗涌进来"这种关卡设计感，就需要作者能固定点位。
##
## 【怎么挂】两种都被支持（HoldoutMachine 里优先取第一种）：
##   ① 作为 **HoldoutMachine 的子节点**（含孙节点）—— 归属最明确，一台机器一套点；
##   ② 放在场景任意位置 —— 只要不出现在机器子树上，就会被"全场景扫描"兜底收集到。
##
## 【落点安全】不想让敌人从墙里/人堆里钻出来就什么都不用做：
## 生成时每个落点都会先过 SpawnSpotResolver（图块碰撞 + 物理探测 墙/玩家/敌人）
## 挪到最近的可站空位；实在找不到空位的才退回屏幕外刷法。

@export var enabled: bool = true                  ## 关掉后该点不参与均分（便于临时对比）
@export var marker_color: Color = Color(1.0, 0.35, 0.25, 1.0)  ## 编辑器标记色（仅编辑器可见）
@export_range(4.0, 40.0, 2.0) var marker_radius: float = 10.0


## 运行时默认不画标记（只在编辑器可见）；按 TAB 打开 `Global.debug_visuals` 才在游戏里显示。
## ⚠ 2026-09-26 用户实测：初版 `_draw()` 没有这层闸门，红点直接出现在游戏画面里。
var _marker_shown: bool = false


func _ready() -> void:
	_marker_shown = _marker_wanted()
	set_process(not Engine.is_editor_hint())
	queue_redraw()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var want: bool = _marker_wanted()
	if want != _marker_shown:
		_marker_shown = want
		queue_redraw()


func _marker_wanted() -> bool:
	if Engine.is_editor_hint():
		return true
	var g: Node = get_node_or_null("/root/Global")
	return g != null and bool(g.get("debug_visuals"))


func _draw() -> void:
	if not _marker_wanted():
		return
	var col: Color = marker_color if enabled else Color(0.55, 0.55, 0.55, 1.0)
	draw_arc(Vector2.ZERO, marker_radius, 0.0, TAU, 24, col, 2.0)
	draw_line(Vector2(-marker_radius, 0.0), Vector2(marker_radius, 0.0), col, 1.0)
	draw_line(Vector2(0.0, -marker_radius), Vector2(0.0, marker_radius), col, 1.0)
