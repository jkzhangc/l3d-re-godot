@tool
extends EditorPlugin
## VXAnimSprite 可视化编辑器插件
##   - 在底部面板提供 VX Anim 编辑面板
##   - 选中场景中的 VXAnimSprite 节点即可编辑


var _panel: Control = null
const DOCK_NAME := "VX Anim"


func _enter_tree() -> void:
	_panel = _create_panel()
	add_control_to_bottom_panel(_panel, DOCK_NAME)
	print("[VXAnimEditor] 已加载 | 选中 VXAnimSprite 节点开始编辑")


func _exit_tree() -> void:
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	print("[VXAnimEditor] 已卸载")


func _handles(object: Object) -> bool:
	return object is VXAnimSprite


func _edit(object: Object) -> void:
	if _panel and _panel.has_method("edit_object"):
		_panel.edit_object(object as VXAnimSprite)


func _make_visible(visible: bool) -> void:
	if not visible and _panel and _panel.has_method("clear"):
		_panel.clear()


## 创建底部面板 Control 实例
func _create_panel() -> Control:
	var script: Script = load("res://addons/vx_anim_editor/anim_editor_panel.gd") as Script
	var ctrl := Control.new()
	ctrl.name = "VXAnimEditorPanel"
	ctrl.set_script(script)
	ctrl.set("editor_interface", get_editor_interface())
	return ctrl
