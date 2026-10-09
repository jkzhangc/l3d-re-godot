extends RefCounted

## ── 架构定位 ──
## 系统：玩家调试可视化 ｜ 层：服务类（RefCounted，由 player 持有）
## 联机：仅本机调试（Global.debug_visuals 关闭时整块不执行），与联机无关
## 职责：在玩家节点上绘制调试信息：碰撞体矩形 / HP 条 / 受击区矩形。
## 依赖：player 实体（读 _is_dying / current_hp / max_hp / hurt_area；经 _p.draw_rect 发绘制指令）
##
## 【为什么从 player.gd 抽出（2026-10-08）】调试绘制约 26 行、纯可视化、零玩法耦合，
## 且 `_draw` 是引擎回调、外部零调用点 —— 拆分风险最低的一块。
## 抽出后 player.gd 只留 `func _draw(): _debug_drawer.draw()` 一行转发。
##
## 【为什么要经 _p.draw_rect 而不是自己画】`draw_rect` 等是 **CanvasItem 的绘制
## 指令**，必须在宿主节点自己的 `_draw()` 回调**同步调用栈内**发出才有效。本服务的
## `draw()` 正是被 `_p._draw()` 同步调用的，所以 `_p.draw_rect(...)` 落在同一次绘制
## 通道内，行为等价（与 enemy_debug_drawer.gd 同款约定）。
##
## 【状态变量留在 player】`_is_dying` / `current_hp` / `max_hp` / `hurt_area` 全部保留在
## player.gd（其中 hurt_area 被 character_switch_manager 直接读，current_hp/max_hp 被
## nameplate/item_manager/network_world 等直接读，绝不能迁走）。本服务只读不改。

var _p: Node = null


func _init(player: Node) -> void:
	_p = player


## 调试可视化主入口（由 player._draw() 转发）。Global.debug_visuals 关闭时直接返回。
func draw() -> void:
	if not Global.debug_visuals:
		return
	# 绘制玩家碰撞体
	var cs: CollisionShape2D = _p.get_node_or_null("CollisionShape2D")
	if cs:
		var shape: Shape2D = cs.shape
		if shape is RectangleShape2D:
			var rect: RectangleShape2D = shape as RectangleShape2D
			var color: Color = Color.GRAY if _p._is_dying else Color.GREEN
			var pos: Vector2 = cs.position
			_p.draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)
	# 绘制 HP 条
	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = _p.current_hp / _p.max_hp
	_p.draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	_p.draw_rect(Rect2(-bar_w / 2, bar_y, bar_w * ratio, bar_h), Color.GREEN if not _p._is_dying else Color.GRAY, true)

	# 绘制受击碰撞体（黄色虚线）
	if _p.hurt_area:
		var hshape_node: CollisionShape2D = _p.hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			_p.draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)
