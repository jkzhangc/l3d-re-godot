extends Node2D
## VXTileMap 渲染测试 — A4 墙壁 autotile 验证
##
## 测试模式：
##   1 — 实心矩形墙（验证中央 + 四边 + 四角 tile）
##   2 — L 形墙（验证内外角切换）
##   3 — 孤立墙块
##   4 — 走廊（两侧墙 + 中间空）
##
## 按键：1/2/3/4 切换测试模式，C 清除


@onready var vx_map: VXTileMap = $VXTileMap


func _ready() -> void:
	if not vx_map:
		push_error("请添加 VXTileMap 子节点！")
		return

	# 加载 TileA4-Twnew.png（用户自制的简化 A4 格式）
	if vx_map.tile_sheet == null:
		var tex := load("res://art/Tilesets/TileA4-Twnew.png") as Texture2D
		if tex:
			vx_map.tile_sheet = tex

	vx_map.tile_group = 3
	vx_map.draw_grid = true

	# 默认测试：实心墙
	_test_solid_wall()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	match event.keycode:
		KEY_1:
			_test_solid_wall()
		KEY_2:
			_test_l_wall()
		KEY_3:
			_test_isolated()
		KEY_4:
			_test_corridor()
		KEY_C:
			vx_map.clear()
			print("已清除")


# ═══════════════════════════════════════
# 测试模式
# ═══════════════════════════════════════

## 5×5 实心矩形墙 — 验证中央/边/角
func _test_solid_wall() -> void:
	vx_map.clear()
	var terrain: int = vx_map.autotile_terrain_id + 1
	vx_map.fill_rect(Rect2i(5, 5, 5, 5), terrain)
	print("[测试1] 5x5 实心墙 — 应看到: 四角=外角, 四边=边, 中央=中央(255)")


## L 形墙 — 验证内角 vs 外角
func _test_l_wall() -> void:
	vx_map.clear()
	var t: int = vx_map.autotile_terrain_id + 1
	# 横墙 + 竖墙组成 L 形
	for x: int in range(3, 12):
		vx_map.set_cell(Vector2i(x, 5), t)  # 横墙
	for y: int in range(3, 12):
		vx_map.set_cell(Vector2i(8, y), t)  # 竖墙
	print("[测试2] L形墙 — 拐角处应显示内角 tile")


## 孤立 3×3 墙块
func _test_isolated() -> void:
	vx_map.clear()
	var t: int = vx_map.autotile_terrain_id + 1
	vx_map.fill_rect(Rect2i(5, 5, 3, 3), t)
	print("[测试3] 3x3 孤立墙 — 四角=外角, 四边=边, 中央=中央")


## 走廊 — 两条平行墙
func _test_corridor() -> void:
	vx_map.clear()
	var t: int = vx_map.autotile_terrain_id + 1
	# 上方墙壁
	for x: int in range(5, 15):
		vx_map.set_cell(Vector2i(x, 4), t)
	# 下方墙壁
	for x: int in range(5, 15):
		vx_map.set_cell(Vector2i(x, 10), t)
	print("[测试4] 走廊 — 上下两条平行墙")
