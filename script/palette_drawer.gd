extends Control
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
