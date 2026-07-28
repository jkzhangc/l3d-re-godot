@tool
extends EditorPlugin
## VXTileMap 编辑器插件
##   - 注册 VXTileMap 节点类型
##   - 编辑器内左键放置 / 右键擦除 tile
##   - 滚轮切换 terrain_id | Ctrl+Z 撤销


var _active_vxmap: VXTileMap = null
var _current_terrain: int = 1
var _grid_editor: Control = null
const DOCK_NAME := "VX Grid"


func _enter_tree() -> void:
	add_custom_type("VXTileMap", "Node2D",
		preload("res://addons/vx_tilemap/vx_tilemap.gd"), null)

	# 添加网格编辑器底部面板
	_grid_editor = _create_grid_editor()
	add_control_to_bottom_panel(_grid_editor, DOCK_NAME)

	print("[VXTileMap] 已加载 | 左键画 右键擦 滚轮换terrain | Grid Dock 就绪")


func _exit_tree() -> void:
	remove_custom_type("VXTileMap")
	if _grid_editor:
		remove_control_from_bottom_panel(_grid_editor)
		_grid_editor.queue_free()
		_grid_editor = null
	print("[VXTileMap] 已卸载")


# ═══════════════════════════════════════
# 编辑器交互
# ═══════════════════════════════════════

func _handles(object: Object) -> bool:
	return object is VXTileMap


func _edit(object: Object) -> void:
	_active_vxmap = object as VXTileMap
	# 将选中节点的配置传给网格编辑器
	if _active_vxmap and _grid_editor and _grid_editor.has_method("load_config"):
		if _active_vxmap.grid_config:
			_grid_editor.load_config(_active_vxmap.grid_config)


func _make_visible(visible: bool) -> void:
	if not visible:
		_active_vxmap = null


func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if not _active_vxmap:
		return false

	# 鼠标移动 → 更新光标预览
	if event is InputEventMouseMotion:
		_active_vxmap.editor_hover_cell = _mouse_to_cell(event.global_position)
		return false  # 不消费，让编辑器正常处理

	# 滚轮切换 terrain
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_current_terrain = mini(_current_terrain + 1, 99)
			print("[VXTileMap] terrain = %d" % _current_terrain)
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_current_terrain = maxi(_current_terrain - 1, 0)
			if _current_terrain == 0:
				print("[VXTileMap] terrain = %d (擦除模式)" % _current_terrain)
			else:
				print("[VXTileMap] terrain = %d" % _current_terrain)
			return true

		# 左键放置
		if event.button_index == MOUSE_BUTTON_LEFT:
			var cell := _mouse_to_cell(event.global_position)
			if _current_terrain > 0:
				_active_vxmap.set_cell(cell, _current_terrain)
			else:
				_active_vxmap.erase_cell(cell)
			_active_vxmap.queue_redraw()
			return true

		# 右键擦除
		if event.button_index == MOUSE_BUTTON_RIGHT:
			var cell := _mouse_to_cell(event.global_position)
			_active_vxmap.erase_cell(cell)
			_active_vxmap.queue_redraw()
			return true

	return false


## 屏幕坐标 → 地图格坐标
func _mouse_to_cell(screen_pos: Vector2) -> Vector2i:
	if not _active_vxmap:
		return Vector2i.ZERO

	var ed := get_editor_interface()
	var canvas := ed.get_editor_viewport_2d()
	if not canvas:
		return Vector2i.ZERO

	var xform := canvas.get_screen_transform()
	var local := xform.affine_inverse() * screen_pos - _active_vxmap.global_position
	var ts := _active_vxmap.tile_size
	return Vector2i(int(floor(local.x / ts)), int(floor(local.y / ts)))


## 创建网格编辑器 Control 实例。
func _create_grid_editor() -> Control:
	var script: Script = load("res://addons/vx_tilemap/vx_grid_editor.gd") as Script
	var ctrl := Control.new()
	ctrl.name = "VXGridEditor"
	ctrl.set_script(script)
	ctrl.set("editor_interface", get_editor_interface())
	return ctrl
