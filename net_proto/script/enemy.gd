extends Node2D

var enemy_id := 0
var hp := 100.0
var alive := true

func _ready() -> void:
	queue_redraw()

func setup(new_enemy_id: int, new_pos: Vector2, new_hp: float, new_alive: bool) -> void:
	enemy_id = new_enemy_id
	position = new_pos
	hp = new_hp
	alive = new_alive
	queue_redraw()

func _draw() -> void:
	var color := Color("#e63946") if alive else Color("#555555")
	draw_rect(Rect2(-16, -16, 32, 32), color)
	draw_rect(Rect2(-16, -16, 32, 32), Color.WHITE, false, 2.0)
	draw_line(Vector2(-12, -24), Vector2(12, -24), Color("#3a1f1f"), 4.0)
	draw_line(Vector2(-12, -24), Vector2(-12 + 24.0 * clampf(hp / 100.0, 0.0, 1.0), -24), Color("#ffcb77"), 4.0)
