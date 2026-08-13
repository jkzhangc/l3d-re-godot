extends Node2D
## 治疗品拾取物 — 放在地图上，玩家触碰自动拾取（增加医疗包数量）

@export var item: ItemData  ## 要给予的治疗品（ItemType.HEALING）

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


func _ready() -> void:
	if _area:
		_area.body_entered.connect(_on_body_entered)
	_refresh_sprite()


func _refresh_sprite() -> void:
	if _sprite and item and item.icon:
		_sprite.texture = item.icon


func _on_body_entered(body: Node2D) -> void:
	if not item:
		return
	if body is CharacterBody2D and body.has_method("get_weapon_data"):
		Global.pickup_consumable(item)
		queue_free()
