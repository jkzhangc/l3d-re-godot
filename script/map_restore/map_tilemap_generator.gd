extends SceneTree

## ── 架构定位 ──
## 系统：地图还原 ｜ 层：工具（SceneTree）
## 联机：不涉及
## 职责：命令行工具：把 export_map.py 输出的分层 JSON/atlas 生成为可编辑的 TileMapLayer 场景。
## 依赖：OS 命令行参数、TileSet 生成

## 将 export_map.py 的分层 JSON/atlas 生成为真正可编辑的 TileMapLayer 场景。
## 用法：-- <json> <lower.png> <upper.png> <lower.tres> <upper.tres> <scene.tscn> [rebuild]
##
## 增量约定：目标 TileSet 已存在时**复用**它，只补齐缺失的格位，从而保留编辑器
## 侧的加工（碰撞多边形、逐格 z_index、以及把 atlas 链成 ext_resource 而不是内嵌
## 纹理）。传第 7 个参数 `rebuild` 可强制重建（会丢弃上述加工）。
## scene/maps_auto/MapXXXX_auto.tscn 本身始终重生成（它是流水线的派生产物）。

## RM2K3 Block A（水面）每帧时长（秒），与 export_map.py 的 BLOCK_A_DURATION 一致
const BLOCK_A_DURATION := 0.3

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 6:
		push_error("用法: -- <json> <lower.png> <upper.png> <lower.tres> <upper.tres> <scene.tscn> [rebuild]")
		quit(2)
		return
	await process_frame
	var json_path := args[0]
	var lower_atlas_path := args[1]
	var upper_atlas_path := args[2]
	var lower_tileset_path := args[3]
	var upper_tileset_path := args[4]
	var scene_path := args[5]
	var rebuild := args.size() > 6 and args[6] == "rebuild"
	# 保存前先记住原 tres 的元数据：headless 运行没有编辑器的 ResourceUID 缓存，
	# ResourceSaver 不写 uid=（资源自身的 uid 和 ext_resource 的 uid 都会丢），
	# 会打断按 uid 引用这些 TileSet 的场景。
	var lower_before := _read_tres_text(lower_tileset_path)
	var upper_before := _read_tres_text(upper_tileset_path)
	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("无法打开 JSON: %s" % json_path)
		quit(3)
		return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		push_error("JSON 无效: %s" % json_path)
		quit(4)
		return
	var lower_state := _make_tileset(lower_atlas_path, data.lower_tiles, int(data.tile_size),
		lower_tileset_path, rebuild, lower_before, _anim_lower(data))
	var upper_state := _make_tileset(upper_atlas_path, data.upper_tiles, int(data.tile_size),
		upper_tileset_path, rebuild, upper_before, {})
	if lower_state.tileset == null or upper_state.tileset == null:
		quit(5)
		return
	for state in [lower_state, upper_state]:
		if state.action != "write":
			continue
		if ResourceSaver.save(state.tileset, state.path) != OK:
			push_error("TileSet 保存失败：%s" % state.path)
			quit(6)
			return
		_restore_tres_metadata(state.path, state.before_text)
	# 重新加载，确保 PackedScene 保存外置 TileSet 引用。
	var saved_lower := ResourceLoader.load(lower_tileset_path) as TileSet
	var saved_upper := ResourceLoader.load(upper_tileset_path) as TileSet
	var root := Node2D.new()
	root.name = "Map%04d" % int(data.map_id)
	var ground := TileMapLayer.new()
	ground.name = "GroundLayer"
	ground.tile_set = saved_lower
	root.add_child(ground)
	ground.owner = root
	var decor := Node2D.new()
	decor.name = "DecorLayer"
	decor.y_sort_enabled = true
	root.add_child(decor)
	decor.owner = root
	var spawn := Node2D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector2(int(data.width) * int(data.tile_size) / 2, int(data.height) * int(data.tile_size) / 2)
	decor.add_child(spawn)
	spawn.owner = root
	var player_scene := load("res://object/player.tscn") as PackedScene
	if player_scene:
		var player := player_scene.instantiate()
		player.name = "Player"
		spawn.add_child(player)
		player.owner = root
	var upper := TileMapLayer.new()
	upper.name = "UpperLayer"
	upper.y_sort_enabled = true
	upper.tile_set = saved_upper
	root.add_child(upper)
	upper.owner = root
	var lower_tiles: Dictionary = data.lower_tiles
	var upper_tiles: Dictionary = data.upper_tiles
	var ground_count := 0
	var upper_count := 0
	for cell in data.cells:
		var pos := Vector2i(int(cell.x), int(cell.y))
		var lower_key = cell.get("lower_key", null)
		if lower_key is String and lower_tiles.has(lower_key):
			var lc: Array = lower_tiles[lower_key]
			ground.set_cell(pos, 0, Vector2i(int(lc[0]), int(lc[1])))
			ground_count += 1
		var upper_key = cell.get("upper_key", null)
		if upper_key is String and upper_tiles.has(upper_key):
			var uc: Array = upper_tiles[upper_key]
			upper.set_cell(pos, 0, Vector2i(int(uc[0]), int(uc[1])))
			upper_count += 1
	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.position = spawn.position
	camera.limit_right = int(data.width) * int(data.tile_size)
	camera.limit_bottom = int(data.height) * int(data.tile_size)
	root.add_child(camera)
	camera.owner = root
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("场景打包失败")
		quit(8)
		return
	if ResourceSaver.save(packed, scene_path) != OK:
		push_error("场景保存失败")
		quit(9)
		return
	print("lower TileSet: %s (%d tiles)" % [lower_tileset_path, lower_tiles.size()])
	print("upper TileSet: %s (%d tiles)" % [upper_tileset_path, upper_tiles.size()])
	print("TileMap: %s | ground=%d | upper=%d" % [scene_path, ground_count, upper_count])
	# 主动释放临时场景树：root 从未入树，free() 立即生效且安全。
	# 不释放的话退出时会报一堆 RID / ObjectDB 泄漏（body/shape/CanvasItem/纹理），
	# 把真正的错误淹没掉。root 里的 Player 也随之一并释放。
	root.free()
	saved_lower = null
	saved_upper = null
	packed = null
	quit(0)

## Block A（水面等）的动画信息：{键: 帧数}。旧版 JSON 没有该字段，返回空。
func _anim_lower(data: Dictionary) -> Dictionary:
	var anim = data.get("animation", {})
	if anim is Dictionary and anim.get("lower") is Dictionary:
		return anim["lower"]
	return {}

## 动画图块：本体键不带后缀，其余帧带 #序号。建格时要跳过帧键——Godot 会把
## 本体右侧的连续格当作动画帧，它们必须保持无格状态。
func _is_anim_frame_key(key: String) -> bool:
	return key.find("#") >= 0

## 返回 {action, tileset, path, before_text}：
##   action = "write"  需要保存（新建 / 补齐了缺失格位 / 被要求重建）
##   action = "skip"   既有 TileSet 已覆盖全部所需格位，不动文件，避免纯格式抖动
## tileset 为 null 表示构建失败，调用方直接退出。
func _make_tileset(atlas_path: String, mapping: Dictionary, tile_size: int,
		existing_path: String, rebuild: bool, before_text: String, anim: Dictionary) -> Dictionary:
	var state := {"action": "write", "tileset": null, "path": existing_path, "before_text": before_text}
	var reuse = _reuse_tileset(existing_path, mapping, tile_size, before_text, anim, atlas_path)
	if not rebuild and reuse != null:
		state.tileset = reuse.tileset
		if reuse.changed == 0:
			state.action = "skip"
			print("reused existing TileSet unchanged: %s (%d declared tiles)" % [existing_path, mapping.size()])
		else:
			print("updated existing TileSet: %s | added %d tiles, refreshed %d textures" % [existing_path, reuse.added, reuse.textures_refreshed])
		return state
	state.tileset = _build_tileset(atlas_path, mapping, tile_size, anim)
	return state

func _build_tileset(atlas_path: String, mapping: Dictionary, tile_size: int, anim: Dictionary) -> TileSet:
	var image := Image.load_from_file(atlas_path)
	if image == null or image.is_empty():
		push_error("无法读取 atlas: %s" % atlas_path)
		return null
	var texture := ImageTexture.create_from_image(image)
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(tile_size, tile_size)
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = tileset.tile_size
	for key in mapping:
		if _is_anim_frame_key(key):
			continue                       # 动画帧由本体格的 animation 设置接管
		var coord: Array = mapping[key]
		source.create_tile(Vector2i(int(coord[0]), int(coord[1])))
	tileset.add_source(source)
	_apply_animation(source, mapping, anim)
	return tileset

## 给动画图块设帧数与帧时长。帧必须位于本体右侧连续格且无格，否则跳过并告警。
func _apply_animation(source: TileSetAtlasSource, mapping: Dictionary, anim: Dictionary) -> void:
	for key in anim:
		if not mapping.has(key):
			continue
		var coord: Array = mapping[key]
		var cell := Vector2i(int(coord[0]), int(coord[1]))
		if not source.has_tile(cell):
			continue
		var frames := int(anim[key])
		if frames < 2:
			continue
		var blocked := false
		for f in range(1, frames):
			if source.has_tile(cell + Vector2i(f, 0)):
				blocked = true
		if blocked:
			push_warning("动画帧格被占用，跳过动画设置：%s" % key)
			continue
		source.set_tile_animation_frames_count(cell, frames)
		for f in range(frames):
			source.set_tile_animation_frame_duration(cell, f, BLOCK_A_DURATION)

## 复用已存在的 TileSet，只补齐缺失格位，从而保留编辑器侧的加工：
## 碰撞多边形（physics_layer_0/*）、逐格 z_index、以及资源与外链的 uid。
## atlas 纹理与磁盘 PNG 不一致时会**原地刷新纹理**（内嵌像素是生成时的快照，
## atlas 追加了新图块后旧快照不会自动跟上，表现是新格位在编辑器里全黑）；
## 外链纹理指向同一路径时本来就跟随文件，刷新无害。
## 返回 {tileset, added, changed, textures_refreshed}；任何前置条件不满足都返回
## null，由调用方回退到全新构建（宁可重建也不写坏文件，原因用 push_warning 说明）。
func _reuse_tileset(existing_path: String, mapping: Dictionary, tile_size: int,
		before_text: String, anim: Dictionary, atlas_path: String):
	if not ResourceLoader.exists(existing_path):
		return null
	if before_text == "":
		push_warning("现有 TileSet 存在但无法读取文本，改为重建：%s" % existing_path)
		return null
	var kept := ResourceLoader.load(existing_path) as TileSet
	if kept == null:
		push_warning("现有 TileSet 无法加载，改为重建：%s" % existing_path)
		return null
	if kept.tile_size != Vector2i(tile_size, tile_size):
		push_warning("现有 TileSet 的 tile_size=%s 与本次 %d 不符，改为重建：%s"
			% [str(kept.tile_size), tile_size, existing_path])
		return null
	if kept.get_source_count() == 0:
		push_warning("现有 TileSet 没有任何图层源，改为重建：%s" % existing_path)
		return null
	# atlas 图尺寸变了（重新导出了更大的图集）→ 必须重建。
	# 复用路径只会 _refresh_texture() 换纹理，**不会**按新尺寸补齐/清理已建 tile 的 cell，
	# 结果就是"图集换了、tileset 还是旧的网格"——2026-09-16 排查"某些图块没导出来"时
	# 发现这个盲区（当时靠尺寸恰好一致才没出事，属隐患）。
	var probe := Image.load_from_file(atlas_path)
	if probe != null and not probe.is_empty():
		var src0 := kept.get_source(kept.get_source_id(0)) as TileSetAtlasSource
		if src0 and src0.texture:
			var old_img := src0.texture.get_image()
			if old_img and not old_img.is_empty() and old_img.get_size() != probe.get_size():
				push_warning("现有 TileSet 的 atlas 尺寸 %s 与本次 %s 不符，改为重建：%s"
					% [str(old_img.get_size()), str(probe.get_size()), existing_path])
				return null
	# 逐源补齐：现有 TileSet 可能被编辑器复制出多个 atlas 源，全部补齐最稳妥。
	# 纹理刷新只作用于**第一个** atlas 源（生成器建的主源）；其余源可能是编辑器
	# 里手动链接的（如 Map0141 upper 的第二源链到下层 PNG），不能擅改。
	var sources := 0
	var added := 0
	var refreshed := 0
	for index in range(kept.get_source_count()):
		var source := kept.get_source(kept.get_source_id(index)) as TileSetAtlasSource
		if source == null:
			continue
		if source.texture == null:
			push_warning("现有 TileSet 的第 %d 个 atlas 源纹理链已断，改为重建：%s" % [index, existing_path])
			return null
		for key in mapping:
			if _is_anim_frame_key(key):
				continue                       # 动画帧格必须保持无格
			var coord: Array = mapping[key]
			var cell := Vector2i(int(coord[0]), int(coord[1]))
			if not source.has_tile(cell):
				source.create_tile(cell)
				added += 1
		_apply_animation(source, mapping, anim)
		if sources == 0 and _refresh_texture(source, atlas_path):
			refreshed += 1
		sources += 1
	if sources == 0:
		push_warning("现有 TileSet 不含 TileSetAtlasSource，改为重建：%s" % existing_path)
		return null
	return {"tileset": kept, "added": added, "changed": added + refreshed,
			"textures_refreshed": refreshed}

## 把 atlas 源的纹理刷成磁盘上最新的 PNG（仅当内容确实不同时）。
## 返回是否发生了替换。取不到旧图像（如非内嵌的压缩纹理）时跳过并告警。
func _refresh_texture(source: TileSetAtlasSource, atlas_path: String) -> bool:
	var fresh := Image.load_from_file(atlas_path)
	if fresh == null or fresh.is_empty():
		push_warning("无法读取最新 atlas，纹理未刷新：%s" % atlas_path)
		return false
	var old := source.texture.get_image()
	if old != null and not old.is_empty():
		if old.get_size() == fresh.get_size() and old.get_data() == fresh.get_data():
			return false                   # 内容一致，不动（避免格式抖动）
	source.texture = ImageTexture.create_from_image(fresh)
	return true

func _read_tres_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _first_line(text: String) -> String:
	var newline := text.find("\n")
	return text.substr(0, newline if newline >= 0 else text.length())

func _extract_attr(line: String, name: String) -> String:
	# 前导空格避免把 uid= 误当成 id=（"uid=\"" 内含 "id=\""）
	var marker := " " + name + "=\""
	var at := line.find(marker)
	if at < 0:
		return ""
	var rest := line.substr(at + marker.length())
	var end := rest.find("\"")
	return "" if end < 0 else rest.substr(0, end)

## 保存前的 tres 里，某个 ext_resource id 对应的 uid（没有则返回空串）。
func wanted_uid(before_text: String, res_id: String) -> String:
	for line in before_text.split("\n"):
		if line.begins_with("[ext_resource") and _extract_attr(line, "id") == res_id:
			return _extract_attr(line, "uid")
	return ""

## 把保存前的 tres 元数据补回去。headless 运行没有编辑器的 ResourceUID 缓存，
## ResourceSaver 不写 uid=，会打断按 uid 引用这些 TileSet 的场景
## （如 突袭-第二关-学校门口.tscn），编辑器里外部纹理的 uid 属性也会丢。
## 已有值时不动，避免重复。
func _restore_tres_metadata(path: String, before_text: String) -> void:
	if before_text == "" or not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var lines := text.split("\n")
	var changed := false
	for index in range(lines.size()):
		var line: String = lines[index]
		if index == 0 and line.begins_with("[gd_resource") and line.find("uid=") < 0:
			var uid_text := _extract_attr(_first_line(before_text), "uid")
			if uid_text != "":
				var close := line.rfind("]")
				if close >= 0:
					lines[index] = line.substr(0, close) + " uid=\"" + uid_text + "\"" + line.substr(close)
					changed = true
		elif line.begins_with("[ext_resource"):
			var res_id := _extract_attr(line, "id")
			if res_id != "" and _extract_attr(line, "uid") == "":
				var wanted := wanted_uid(before_text, res_id)
				if wanted != "":
					var close := line.rfind("]")
					if close >= 0:
						lines[index] = line.substr(0, close) + " uid=\"" + wanted + "\"" + line.substr(close)
						changed = true
	if not changed:
		return
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_warning("无法写回 tres，元数据未补回：%s" % path)
		return
	out.store_string("\n".join(lines))
	out.close()
	print("restored tres metadata: %s" % path.get_file())
