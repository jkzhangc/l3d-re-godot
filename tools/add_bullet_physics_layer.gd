extends Node

## ── 架构定位 ──
## 系统：还原管线配套工具 ｜ 层：tools（数据迁移，一次性/可重跑）
## 职责：给各地图 TileSet 加「子弹阻挡」物理层（physics_layer_1，collision_layer = 32），
##       并把 physics_layer_0 的碰撞多边形**原样复制**到新层 —— 零行为变化，
##       之后在 TileSet 编辑器里逐格擦掉"不该挡子弹"的格子（家具/矮桌等）。
## 用法：godot --headless --path . res://tools/add_bullet_physics_layer.tscn
## 约束：幂等 —— 已有 physics_layer_1 的 tileset 只在缺格时补齐；不改 layer0。
##       复制计数必须与 layer0 逐格一致，否则报 FAIL（防止某个 tileset 漏写 → 子弹穿墙）。

const TILESET_GLOB := "res://tres/Map0"
const BULLET_LAYER_INDEX: int = 1     ## 新物理层在 TileSet 里的索引
const BULLET_COLLISION_LAYER: int = 32  ## 位值 32 = 物理层 6（project.godot layer_names 里命名「子弹阻挡」）

var _files: int = 0
var _layers_added: int = 0
var _tiles_copied: int = 0
var _fails: Array[String] = []


func _ready() -> void:
	print("=== 给地图 TileSet 加「子弹阻挡」物理层 ===")
	var paths: Array[String] = _collect_tilesets()
	if paths.is_empty():
		print("[FAIL] 没找到任何地图 tileset")
		get_tree().quit(1)
		return
	for path: String in paths:
		_migrate(path)
	print("--- 结果：文件 %d 个 / 新建层 %d 个 / 复制碰撞 %d 个" % [_files, _layers_added, _tiles_copied])
	if _fails.is_empty():
		print("=== BULLET_LAYER_MIGRATE: PASS ===")
		get_tree().quit(0)
	else:
		for f: String in _fails:
			print("[FAIL] " + f)
		print("=== BULLET_LAYER_MIGRATE: %d FAIL ===" % _fails.size())
		get_tree().quit(1)


func _collect_tilesets() -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open("res://tres")
	if dir == null:
		return out
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.begins_with("Map0") and name.ends_with("_tileset.tres"):
			out.append("res://tres/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _migrate(path: String) -> void:
	var ts: TileSet = load(path) as TileSet
	if ts == null:
		_fails.append("%s 加载失败" % path)
		return
	## ⚠ ResourceSaver.save() 会丢掉 .tres 头部的 uid（实测），导致场景里按 uid 的引用失配。
	## 先抓原始 uid，保存后再补回头部。
	var original_uid: String = _read_uid(path)
	_files += 1
	# ① 确保存在「子弹阻挡」层
	while ts.get_physics_layers_count() <= BULLET_LAYER_INDEX:
		ts.add_physics_layer()
		_layers_added += 1
	if ts.has_method("set_physics_layer_collision_layer"):
		ts.set_physics_layer_collision_layer(BULLET_LAYER_INDEX, BULLET_COLLISION_LAYER)
	else:
		_fails.append("%s 缺少 set_physics_layer_collision_layer API" % path)
		return
	# ② 逐格把 layer0 的多边形复制到 layer1
	var copied: int = 0
	var expected: int = 0
	for si: int in ts.get_source_count():
		var sid: int = ts.get_source_id(si)
		var src: TileSetSource = ts.get_source(sid)
		if not (src is TileSetAtlasSource):
			continue
		var atlas: TileSetAtlasSource = src as TileSetAtlasSource
		for ti: int in atlas.get_tiles_count():
			var coords: Vector2i = atlas.get_tile_id(ti)
			for alt: int in atlas.get_alternative_tiles_count(coords):
				var alt_id: int = atlas.get_alternative_tile_id(coords, alt)
				var td: TileData = atlas.get_tile_data(coords, alt_id)
				if td == null:
					continue
				expected += td.get_collision_polygons_count(0)
				var have: int = td.get_collision_polygons_count(BULLET_LAYER_INDEX)
				for pi: int in td.get_collision_polygons_count(0):
					var pts: PackedVector2Array = td.get_collision_polygon_points(0, pi)
					if pi < have:
						td.set_collision_polygon_points(BULLET_LAYER_INDEX, pi, pts)
					else:
						td.add_collision_polygon(BULLET_LAYER_INDEX)
						td.set_collision_polygon_points(BULLET_LAYER_INDEX, pi, pts)
					copied += 1
	if copied != expected:
		_fails.append("%s 复制数不符：expected=%d copied=%d" % [path, expected, copied])
	var err: Error = ResourceSaver.save(ts, path)
	if err != OK:
		_fails.append("%s 保存失败 err=%d" % [path, err])
	_restore_uid(path, original_uid)
	_tiles_copied += copied
	print("  %-42s layer0=%d → layer1 复制 %d" % [path.get_file(), expected, copied])


## 读取 .tres 头部 `uid="uid://xxx"`（没有则返回空串）。
func _read_uid(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var head: String = f.get_line()
	f.close()
	var i: int = head.find("uid=\"")
	if i < 0:
		return ""
	var j: int = head.find("\"", i + 5)
	if j < 0:
		return ""
	return head.substr(i + 5, j - i - 5)


## 把 uid 补回 .tres 头部（ResourceSaver 保存后会丢，见 _migrate 注释）。
func _restore_uid(path: String, uid: String) -> void:
	if uid.is_empty():
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var first_nl: int = text.find("\n")
	var head: String = text.substr(0, first_nl) if first_nl > 0 else text
	if head.contains("uid="):
		return
	if not head.begins_with("[gd_resource"):
		return
	var fixed: String = head.replace("format=3", "format=3 uid=\"%s\"" % uid)
	var w: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		_fails.append("%s uid 回写失败（无法打开）" % path)
		return
	w.store_string(fixed + text.substr(first_nl))
	w.close()
