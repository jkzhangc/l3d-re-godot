extends Node2D
## 网络玩家节点 — 远程玩家的视觉标识。
## 位置由 NetworkSpawner 通过 RPC 直接更新（无需 MultiplayerSynchronizer）。

@export var player_name: String = ""
@export var peer_id: int = 0

var _sprite: Sprite2D = null
var _hp_bar_fill: ColorRect = null


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "RemoteSprite"
	var tex := load("res://art/Characters/のび太セット.png") as Texture2D
	if tex:
		_sprite.texture = tex
		_sprite.region_enabled = true
		_sprite.region_rect = Rect2(48, 0, 48, 64)
	add_child(_sprite)

	# HP 条
	var bar_container := Control.new()
	bar_container.name = "HPBar"
	bar_container.position = Vector2(-24, -40)
	add_child(bar_container)

	var bg := ColorRect.new()
	bg.color = Color(0.3, 0.3, 0.3, 0.8)
	bg.size = Vector2(48, 4)
	bar_container.add_child(bg)

	_hp_bar_fill = ColorRect.new()
	_hp_bar_fill.color = Color(0.2, 0.8, 0.2, 0.9)
	_hp_bar_fill.size = Vector2(48, 4)
	bar_container.add_child(_hp_bar_fill)

	# 名字标签
	var label := Label.new()
	label.name = "NameLabel"
	label.text = player_name if not player_name.is_empty() else ("P%d" % peer_id)
	label.add_theme_font_size_override("font_size", 10)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-30, -52)
	add_child(label)
