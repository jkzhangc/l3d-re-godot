@tool
extends Node
## 从 RPG Maker VX Ace 图块图片生成 Godot TileSet 资源的编辑器工具。
##
## 使用方法：
##   1. 将此脚本附加到场景中的任意 Node
##   2. 在检查器中设置 tileset_texture 和 tileset_type
##   3. 点击 "Generate TileSet" 按钮
##   4. 生成的 .tres 文件保存到 object/ 目录
##
## 支持的图块类型：
##   - A5:       256×512, 8×16 普通下层图块
##   - B / C / D / E: 512×512, 16×16 上层图块（B 组左上角留空）
##   - A1-A4:    自动图块，基础切片（地形需手动设置）

@export var tileset_texture: Texture2D:
	set(v):
		tileset_texture = v
		_update_preview()
@export var tileset_type: String = "B":
	set(v):
		tileset_type = v
		_update_preview()
@export var tile_size: int = 32
@export var output_name: String = "new_tileset"

enum TileType {
	TYPE_A1,   # 512×384, 自动图块（水面/动画）
	TYPE_A2,   # 512×384, 自动图块（地面）
	TYPE_A3,   # 512×256, 自动图块（建筑外观）
	TYPE_A4,   # 512×480, 自动图块（墙壁）
	TYPE_A5,   # 256×512, 普通下层图块
	TYPE_B,    # 512×512, 上层图块（左上留空）
	TYPE_C,    # 512×512, 上层图块
	TYPE_D,    # 512×512, 上层图块
	TYPE_E,    # 512×512, 上层图块（与 B/C/D 相同格式）
}

## VX Ace 图块组与 Godot TileSetAtlasSource 的分组映射信息
const GROUP_INFO: Dictionary = {
	TileType.TYPE_A1: {
		"desc": "A1 — 动画自动图块（海洋/深水/瀑布）",
		"cols": 16, "rows": 12, "has_autotile": true,
		"note": "5 个 block（A~E），含动画帧。建议用 TileMapLayer 的 terrain 系统处理。"
	},
	TileType.TYPE_A2: {
		"desc": "A2 — 地面自动图块",
		"cols": 16, "rows": 12, "has_autotile": true,
		"note": "4 组 × 4 行。Field Type / Area Type。建议用 terrain + bitmask。"
	},
	TileType.TYPE_A3: {
		"desc": "A3 — 建筑外观自动图块",
		"cols": 16, "rows": 8, "has_autotile": true,
		"note": "8×4 排列，自动生成阴影。建议用 terrain 系统处理。"
	},
	TileType.TYPE_A4: {
		"desc": "A4 — 墙壁自动图块",
		"cols": 16, "rows": 15, "has_autotile": true,
		"note": "8×3 排列，用于地牢生成。建议用 terrain 系统处理。"
	},
	TileType.TYPE_A5: {
		"desc": "A5 — 普通下层图块",
		"cols": 8, "rows": 16, "has_autotile": false,
		"note": "8×16 非自动图块，直接切片即可。"
	},
	TileType.TYPE_B: {
		"desc": "B — 上层装饰图块",
		"cols": 16, "rows": 16, "has_autotile": false,
		"note": "16×16，左上角必须留空。"
	},
	TileType.TYPE_C: {
		"desc": "C — 上层装饰图块",
		"cols": 16, "rows": 16, "has_autotile": false,
		"note": "16×16 上层图块。"
	},
	TileType.TYPE_D: {
		"desc": "D — 上层装饰图块",
		"cols": 16, "rows": 16, "has_autotile": false,
		"note": "16×16 上层图块。"
	},
	TileType.TYPE_E: {
		"desc": "E — 上层装饰图块",
		"cols": 16, "rows": 16, "has_autotile": false,
		"note": "16×16 上层图块。"
	},
}


func _get_type_enum() -> int:
	match tileset_type:
		"A1": return TileType.TYPE_A1
		"A2": return TileType.TYPE_A2
		"A3": return TileType.TYPE_A3
		"A4": return TileType.TYPE_A4
		"A5": return TileType.TYPE_A5
		"B":  return TileType.TYPE_B
		"C":  return TileType.TYPE_C
		"D":  return TileType.TYPE_D
		"E":  return TileType.TYPE_E
	return TileType.TYPE_B


func _update_preview() -> void:
	notify_property_list_changed()


## 由编辑器按钮触发：生成 TileSet 并保存到文件
func generate_tileset() -> void:
	if tileset_texture == null:
		push_error("请先设置 tileset_texture！")
		return

	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)

	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture = tileset_texture
	source.texture_region_size = Vector2i(tile_size, tile_size)

	var tex_width: int = tileset_texture.get_width()
	var tex_height: int = tileset_texture.get_height()
	var cols: int = tex_width / tile_size
	var rows: int = tex_height / tile_size

	var tile_type: int = _get_type_enum()
	var info: Dictionary = GROUP_INFO[tile_type]
	print("生成 TileSet: %s → %d×%d 网格 (%d×%d tiles)" % [
		info["desc"], cols, rows, cols, rows
	])

	# 创建所有 tile
	for y: int in rows:
		for x: int in cols:
			# B 组左上角留空
			if tile_type == TileType.TYPE_B and x == 0 and y == 0:
				continue
			var atlas_coords: Vector2i = Vector2i(x, y)
			source.create_tile(atlas_coords)

	var source_id: int = ts.add_source(source)
	print("  创建了 %d 个图块，source_id = %d" % [
		ts.get_source_count() if ts.get_source_count() > 0 else 1, source_id
	])

	# 保存
	var save_path: String = "res://object/%s.tres" % output_name
	var err: int = ResourceSaver.save(ts, save_path)
	if err == OK:
		print("  TileSet 已保存: %s" % save_path)
	else:
		push_error("  保存失败: %s (error %d)" % [save_path, err])


## 返回类型描述信息（供外部查询）
func get_group_info(type_str: String) -> Dictionary:
	var type_enum: int = _get_type_enum_for(type_str)
	return GROUP_INFO.get(type_enum, {})


func _get_type_enum_for(s: String) -> int:
	match s:
		"A1": return TileType.TYPE_A1
		"A2": return TileType.TYPE_A2
		"A3": return TileType.TYPE_A3
		"A4": return TileType.TYPE_A4
		"A5": return TileType.TYPE_A5
		"B":  return TileType.TYPE_B
		"C":  return TileType.TYPE_C
		"D":  return TileType.TYPE_D
		"E":  return TileType.TYPE_E
	return TileType.TYPE_B


func _on_button_pressed() -> void:
	generate_tileset()
