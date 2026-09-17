extends Node2D

## ── 架构定位 ──
## 系统：地图还原 ｜ 层：工具（Node2D）
## 联机：不涉及
## 职责：RM2K3 还原数据预览：读取分层 JSON 与渲染图并叠加显示，用于核对还原结果。
## 依赖：art/Tilesets/rm2k3_auto 下的 JSON 与 PNG


@export_file("*.json") var map_data_path := "res://art/Tilesets/rm2k3_auto/Map0141.json"
@export_file("*.png") var render_path := "res://art/Tilesets/rm2k3_auto/Map0141_render.png"

func _ready() -> void:
	var file := FileAccess.open(map_data_path, FileAccess.READ)
	if file == null:
		push_error("Map restore data not found: %s" % map_data_path)
		return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		push_error("Invalid map restore JSON")
		return
	$Camera2D.position = Vector2(data.width * 16, data.height * 16)
	$Camera2D.limit_right = data.width * 32
	$Camera2D.limit_bottom = data.height * 32
