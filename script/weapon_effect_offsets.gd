class_name WeaponEffectOffsets extends Resource
## 单个武器的四方向攻击特效偏移
## 不同方向开枪时枪口位置不同 → 每个方向独立偏移

@export var down: Vector2 = Vector2.ZERO   ## FaceDir.DOWN (0)
@export var left: Vector2 = Vector2.ZERO   ## FaceDir.LEFT (1)
@export var right: Vector2 = Vector2.ZERO  ## FaceDir.RIGHT (2)
@export var up: Vector2 = Vector2.ZERO     ## FaceDir.UP (3)


func get_offset(facing: int) -> Vector2:
	match facing:
		0: return down
		1: return left
		2: return right
		3: return up
	return Vector2.ZERO
