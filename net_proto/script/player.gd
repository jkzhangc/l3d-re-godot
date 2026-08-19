extends Node2D

var peer_id := 0
var display_name := "玩家"
var hp := 100.0
var alive := true

func _ready() -> void:
	queue_redraw()

func setup(new_peer_id: int, new_name: String, new_pos: Vector2, new_hp: float, new_alive: bool) -> void:
	peer_id = new_peer_id
	display_name = new_name
	position = new_pos
	hp = new_hp
	alive = new_alive
	queue_redraw()

func _draw() -> void:
	var color := Color("#5bc0eb") if peer_id == 1 else Color("#9b5de5")
	if not alive:
		color = Color("#666666")
	draw_circle(Vector2.ZERO, 18.0, color)
	draw_circle(Vector2.ZERO, 18.0, Color.WHITE, false, 2.0)
	draw_line(Vector2(-12, -27), Vector2(12, -27), Color("#3a1f1f"), 4.0)
	draw_line(Vector2(-12, -27), Vector2(-12 + 24.0 * clampf(hp / 100.0, 0.0, 1.0), -27), Color("#52d273"), 4.0)
	draw_string(ThemeDB.fallback_font, Vector2(-24, 35), display_name.left(10), HORIZONTAL_ALIGNMENT_CENTER, 48, 12, Color.WHITE)
