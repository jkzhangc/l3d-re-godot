extends Node

## 动画编辑器自检（2026-11-17）。
## 用法：godot --headless --path . res://tools/anim_editor_check.tscn
##
## 覆盖：加载现有动画 → 点格子换帧 → 加帧 → 保存到 user:// → 重新加载校验 → 预览实例状态。
## 不测 UI 外观（外观靠截图），只保证「数据改动能落盘、能读回」。

const EDITOR_SCENE := preload("res://scene/anim_editor.tscn")

var _fail: int = 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _ready() -> void:
	var editor: Control = EDITOR_SCENE.instantiate()
	add_child(editor)
	await get_tree().process_frame
	await get_tree().process_frame

	print("=== 1) 自动加载 ===")
	var data: VXAnimSprite = editor.get("_data")
	_check("已加载数据", data != null, true)
	if data == null:
		get_tree().quit(1)
		return
	_check("有贴图", data.texture != null, true)
	_check("有帧序列", data.frame_sequence.size() > 0, true)
	var original_path: String = editor.get("_file_path")
	_check("文件路径是 anim/*.tscn", original_path.begins_with("res://anim/"), true)
	var seq_len: int = data.frame_sequence.size()
	print("      文件=%s 帧数=%d fps=%.1f" % [original_path.get_file(), seq_len, data.fps])

	print("=== 2) 点格子换当前帧 ===")
	var sel: int = int(editor.get("_sel_frame"))
	var old_pat: int = data.frame_sequence[sel]
	var sheet = editor.get("_sheet")
	var cells: int = int(sheet.call("total_cells"))
	var new_pat: int = (old_pat + 1) % maxi(1, cells)
	editor.call("_on_sheet_pattern_clicked", new_pat)
	await get_tree().process_frame
	_check("数据里第 %d 帧改成 %d" % [sel, new_pat], data.frame_sequence[sel], new_pat)
	var preview: VXAnimSprite = editor.get("_preview")
	_check("预览存在", preview != null, true)
	if preview != null:
		_check("预览序列同步", preview.frame_sequence[sel], new_pat)
		_check("预览停在第 %d 帧" % sel, preview.current_sequence_index(), sel)

	print("=== 3) 加帧 / 删帧 ===")
	editor.call("_on_add_frame")
	await get_tree().process_frame
	_check("加帧后长度", data.frame_sequence.size(), seq_len + 1)
	editor.call("_on_delete_frame")
	await get_tree().process_frame
	_check("删帧后长度", data.frame_sequence.size(), seq_len)

	print("=== 3b) 帧条：拖动排序 / 单帧偏移 / 时长 0 兜底 ===")
	var before: Array[int] = data.frame_sequence.duplicate()
	editor.call("_on_strip_reordered", 0, 2)
	await get_tree().process_frame
	_check("排序后第 3 帧 = 原第 1 帧", data.frame_sequence[2], before[0])
	_check("排序后长度不变", data.frame_sequence.size(), before.size())
	editor.call("_set_offset_at", 0, Vector2(7, -5))
	await get_tree().process_frame
	_check("帧偏移写入", data.frame_offsets[0], Vector2(7, -5))
	var pv2: VXAnimSprite = editor.get("_preview")
	_check("预览偏移同步", pv2 != null and pv2.frame_offsets.size() > 0
		and pv2.frame_offsets[0] == Vector2(7, -5), true)
	editor.call("_set_duration_at", 0, 0.0)
	await get_tree().process_frame
	_check("时长 0 落成 1/FPS（不能为 0）", data.frame_durations[0] > 0.0, true)
	# 还原顺序与参数，避免影响后面的保存断言
	editor.call("_on_strip_reordered", 2, 0)
	editor.call("_set_offset_at", 0, Vector2.ZERO)
	await get_tree().process_frame

	print("=== 3c) 多格 cell：转换 / 放置 / 保存 ===")
	var mc: CheckBox = editor.get("_multi_check")
	mc.button_pressed = true
	editor.call("_on_multi_toggled", true)
	await get_tree().process_frame
	_check("每帧至少 1 个 cell", data.cell_data.size() >= data.frame_sequence.size(), true)
	var n0: int = data.cell_data.size()
	editor.call("_on_overlay_empty_clicked", Vector2(240, 130))
	await get_tree().process_frame
	_check("放置后多 1 个 cell", data.cell_data.size(), n0 + 1)
	var last: VXAnimCellData = data.cell_data[data.cell_data.size() - 1]
	_check("cell 绑到当前帧", last.frame_idx,
		data.frame_sequence[int(editor.get("_sel_frame"))])
	_check("cell 图案 = 当前选中图案", last.pattern, int(editor.get("_armed_pattern")))
	var cell_total: int = data.cell_data.size()

	print("=== 3d) 复制 / 粘贴 / 清空 / 贴上一帧 / 补间 ===")
	# 多格转换后每帧 1 个 cell；把第 1 帧的 cell 挪到 (8,8) 再复制
	if data.cell_data.size() > 0:
		data.cell_data[0].offset = Vector2(8, 8)
	editor.call("_copy_frame_at", 0)
	editor.call("_paste_frame_at", 2)
	await get_tree().process_frame
	var c2: Array = editor.call("_cells_of_index", 2)
	_check("粘贴后第 3 帧有 cell", c2.size() > 0, true)
	_check("粘贴带上位置", c2[0].offset if c2.size() > 0 else Vector2.ZERO, Vector2(8, 8))
	editor.call("_paste_last_at", 3)
	await get_tree().process_frame
	var c3: Array = editor.call("_cells_of_index", 3)
	_check("贴上一帧生效", c3.size(), c2.size())
	editor.call("_clear_frame_at", 3)
	await get_tree().process_frame
	_check("清空后没有 cell", editor.call("_cells_of_index", 3).size(), 0)
	# 补间：第 1 帧 (0,0) → 第 5 帧 (40,0)，中间帧应落在 10/20/30
	var ca: Array = editor.call("_cells_of_index", 0)
	var cb: Array = editor.call("_cells_of_index", 4)
	if ca.size() > 0 and cb.size() > 0:
		ca[0].offset = Vector2.ZERO
		cb[0].offset = Vector2(40, 0)
		editor.call("_tween_frames", 0, 4, true, false, false, false)
		await get_tree().process_frame
		var mid: Array = editor.call("_cells_of_index", 2)
		_check("补间中间帧位置", mid[0].offset if mid.size() > 0 else Vector2.ZERO, Vector2(20, 0))

	print("=== 4) 保存到 user:// 再读回 ===")
	var pat_before_save: int = data.frame_sequence[sel]
	var cell_before_save: int = data.cell_data.size()
	var out_path := "user://anim_editor_check_out.tscn"
	editor.call("_save_to", out_path)
	_check("保存后不再 dirty", editor.get("_dirty"), false)
	var packed: PackedScene = load(out_path) as PackedScene
	_check("能读回场景", packed != null, true)
	if packed != null:
		var node: Node = packed.instantiate()
		var sprite: VXAnimSprite = null
		if node is VXAnimSprite:
			sprite = node as VXAnimSprite
		_check("根节点是 VXAnimSprite", sprite != null, true)
		if sprite != null:
			_check("读回帧数一致", sprite.frame_sequence.size(), seq_len)
			_check("读回贴图一致", sprite.texture == data.texture, true)
			_check("读回 fps 一致", absf(sprite.fps - data.fps) < 0.001, true)
			_check("读回当前帧图案一致", sprite.frame_sequence[sel], pat_before_save)
			_check("读回 cell_data 数量一致", sprite.cell_data.size(), cell_before_save)
		node.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))

	print("=== 5) 新建流程：命名 → 落盘 → 编辑新场景 ===")
	var new_name := "_check_new_anim"
	var new_path := "res://anim/%s.tscn" % new_name
	if FileAccess.file_exists(new_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(new_path))
	editor.call("_create_new", new_name)
	await get_tree().process_frame
	_check("文件已落盘", FileAccess.file_exists(new_path), true)
	_check("当前文件指向新场景", String(editor.get("_file_path")), new_path)
	var nd: VXAnimSprite = editor.get("_data")
	_check("新数据已绑定", nd != null, true)
	_check("新场景为空序列", nd.frame_sequence.size() if nd != null else -1, 0)
	_check("保存后不脏", editor.get("_dirty"), false)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(new_path))

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
