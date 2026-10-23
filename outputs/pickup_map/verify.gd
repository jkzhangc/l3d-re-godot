extends SceneTree

## 临时校验脚本：加载 object/ 下所有 ItemData 资源，
## 1) 检查 pickup_texture / char_idx / direction 裁帧是否越界；
## 2) 检查该裁帧里是否真的有像素（防空格 → 地上看不见东西）；
## 3) 打印 icon / tex 路径，便于人工核对对应关系。
## 运行：godot --headless --path . --script res://outputs/pickup_map/verify.gd

const FW := 48
const FH := 64
const COLS := 4
const DIRS := 4

var _bad: int = 0


func _init() -> void:
	var dir := DirAccess.open("res://object")
	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".tres"):
			names.append(f)
	names.sort()
	for f in names:
		var res: Resource = load("res://object/" + f)
		if res == null or not (res is ItemData):
			continue
		var it := res as ItemData
		var tex_path: String = it.pickup_texture.resource_path if it.pickup_texture else "-"
		var icon_path: String = it.icon.resource_path if it.icon else "-"
		var problems: Array[String] = []
		if it.pickup_texture != null:
			var sz: Vector2i = Vector2i(it.pickup_texture.get_size())
			var col: int = it.pickup_char_idx % COLS
			var row: int = it.pickup_char_idx / COLS
			var x: int = col * (FW * 3) + FW
			var y: int = row * (FH * DIRS) + it.pickup_direction * FH
			if x + FW > sz.x or y + FH > sz.y:
				problems.append("裁帧越界")
			else:
				var img: Image = it.pickup_texture.get_image()
				if img != null:
					var cell: Image = img.get_region(Rect2i(x, y, FW, FH))
					var used: int = 0
					for py in FH:
						for px in FW:
							if cell.get_pixel(px, py).a > 0.05:
								used += 1
					if used == 0:
						problems.append("空格（地上会看不见）")
					elif used < 40:
						problems.append("像素过少(%d)" % used)
		else:
			problems.append("无地面贴图")
		if it.icon == null:
			problems.append("无图标")
		if not problems.is_empty():
			_bad += 1
		print("%-22s tex=%-48s idx=%d dir=%d icon=%-44s %s" % [
			it.item_id, tex_path.trim_prefix("res://"), it.pickup_char_idx,
			it.pickup_direction, icon_path.trim_prefix("res://"),
			"" if problems.is_empty() else "！" + ", ".join(problems)])
	print("---- bad=%d" % _bad)
	quit(0)
