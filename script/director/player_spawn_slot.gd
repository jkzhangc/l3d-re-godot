@tool
class_name PlayerSpawnSlot extends Node2D

## ── 架构定位 ──
## 系统：联机实体就位 ｜ 层：玩法（Node2D，关卡作者标记）
## 联机：Host 侧用它分配每位玩家的落点；Client 侧用**自己的座位号**取同一个槽位
## 职责：给「第 N 位玩家」指定出生位置。N 与 HUD 的「NP玩家」标号、座位号一一对应
##       （1 = 主机/1P，2 = 2P …），所以玩家看到的编号与你摆的槽位号是一致的。
## 依赖：NetworkWorld._collect_player_slots / _spawn_position / _apply_own_spawn_slot

## 【为什么要这个节点（2026-09-26 用户需求）】
## 之前多人落点只能靠算法猜（以主机为圆心由近及远找空位），在小房间（如第二关结尾安全屋，
## 大半格是水和墙）里第 3、4 个人可能挤不出合适位置。摆上槽位后，**位置完全由关卡作者决定**，
## 算法只负责兜底。
##
## 【优先级】传送抵达点 > 本节点 > 算法环形搜索。
##   进图时若有"抵达点"（楼梯/安全门传送），全队围绕抵达点展开，槽位不参与 ——
##   因为槽位表达的是"关卡起点"，不是"从楼梯上来时站哪"。
##
## 【被摆在不合法位置怎么办】落点会先过 SpawnSpotResolver：
##   压墙/虚空/被敌人占 → 自动挪到最近可用点并打告警（日志里会指出是哪个槽位），
##   但**绝不会**把人放进墙里。所以摆错了不会卡关，只会看到一条 warning。

@export_range(1, 4, 1) var peer_slot: int = 1     ## 第几位玩家（1=主机/1P，与 HUD 标号一致）
@export var enabled: bool = true                   ## 关掉后该槽位不参与（退回算法分配）
@export var marker_color: Color = Color(0.35, 0.85, 1.0, 1.0)  ## 编辑器标记色
@export_range(6.0, 40.0, 2.0) var marker_radius: float = 12.0


## 运行时默认不画标记（只在编辑器可见）；按 TAB 打开 `Global.debug_visuals` 才在游戏里显示。
## 与 HoldoutSpawnPoint 同一口径（同一天用户实测："标记不该出现在游戏画面里"）。
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
	## 编辑器里一眼看出这是几号位（运行时默认不画）。
	if not _marker_wanted():
		return
	var col: Color = marker_color if enabled else Color(0.55, 0.55, 0.55, 1.0)
	draw_arc(Vector2.ZERO, marker_radius, 0.0, TAU, 24, col, 2.0)
	draw_line(Vector2(-marker_radius, 0.0), Vector2(marker_radius, 0.0), col, 1.0)
	draw_line(Vector2(0.0, -marker_radius), Vector2(0.0, marker_radius), col, 1.0)
	var font: Font = ThemeDB.fallback_font
	if font != null:
		draw_string(font, Vector2(-4.0, -marker_radius - 4.0), str(peer_slot),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)
