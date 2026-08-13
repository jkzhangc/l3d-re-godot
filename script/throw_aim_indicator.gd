extends Node2D
## 投掷瞄准指示器 — 绘制投掷路径（线）+ 终点（圆）
## 由 PlayerThrowableState 创建为玩家子节点，direction/range_tiles 每帧更新

var direction: Vector2 = Vector2.DOWN
var range_tiles: int = 3
var tile_size: int = 32


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var end: Vector2 = direction * (range_tiles * tile_size)
	draw_line(Vector2.ZERO, end, Color(1.0, 0.85, 0.2, 0.9), 2.0)
	draw_circle(end, 12.0, Color(1.0, 0.85, 0.2, 0.85))
	draw_circle(end, 4.0, Color(1.0, 0.35, 0.1, 1.0))
