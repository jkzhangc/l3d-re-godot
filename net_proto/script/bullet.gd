extends Node2D

const VISUAL_SPEED := 620.0

var bullet_id := 0
var owner_id := 0
var direction := Vector2.RIGHT

func _ready() -> void:
	queue_redraw()

func _process(delta: float) -> void:
	# Host uses exact authoritative positions from Game; clients only extrapolate visuals.
	if not Net.is_host:
		position += direction * VISUAL_SPEED * delta


func setup(new_bullet_id: int, new_owner_id: int, new_pos: Vector2, new_direction: Vector2) -> void:
	bullet_id = new_bullet_id
	owner_id = new_owner_id
	position = new_pos
	direction = new_direction
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 5.0, Color("#ffd166"))
	draw_line(-direction * 8.0, direction * 8.0, Color.WHITE, 2.0)
