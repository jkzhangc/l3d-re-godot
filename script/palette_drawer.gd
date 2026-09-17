extends Control

## ── 架构定位 ──
## 系统：地图工具 ｜ 层：工具（Control）
## 联机：不涉及
## 职责：图块调色板的绘制与输入转发；由 map_editor 动态挂载。
## 依赖：map_editor（回调 editor_ref）

## 图块调色板——处理 tileset 纹理显示、选中高亮、网格线
## 由 map_editor.gd 通过 set_script 动态附加

## 回调引用（由 map_editor 设置）
var editor_ref: Node2D = null


func _draw() -> void:
	if editor_ref and editor_ref.has_method("_on_palette_draw"):
		editor_ref._on_palette_draw(self)


func _gui_input(event: InputEvent) -> void:
	if editor_ref and editor_ref.has_method("_on_palette_input"):
		editor_ref._on_palette_input(event, self)
