extends Node

## ── 架构定位 ──
## 系统：还原管线配套工具 ｜ 层：tools（数据迁移，一次性/可重跑）
## 职责：给各地图 TileSet 加「寻路障碍」自定义数据层（custom_data_layer = `path_blocked` : bool）。
##       在 TileSet 编辑器里给某个图块勾上 path_blocked 后，`EnemyChaseState._scan_cell`
##       会把该图块所占的格子当作**整格阻挡**（与 wall 层同效）。
##
## 【为什么需要这一层】敌人的可行走判据是「碰撞体能不能在这一格里站下」（求立足点），
## 不是「这格有没有障碍」—— 这是刻意的：旧规则会把自动图块漏进通道格的**薄碰撞边带**
## 当成整格墙，32px 窄通道全被误判走不通。代价是**碰撞体只占格子一部分**的图块
## （路障 / 护栏 / 立柱 / 斑马线挡板…）旁边站得下 → 敌人从旁边挤过去。
## 与其回到会误伤窄通道的旧规则，不如让作者显式标注哪些图块是实心障碍。
##
## 用法：godot --headless --path . res://tools/add_path_blocked_layer.tscn
## 约束：幂等 —— 已有同名自定义数据层的 tileset 直接跳过；
##       **不写任何 tile 上的数据**（默认全 false，行为零变化），标注由作者在编辑器里勾。

const TILESET_DIR: String = "res://tres"
const LAYER_NAME: String = "path_blocked"

## 初始标注表 —— 「这个 tileset 的这几个图块是实心障碍」。
## 只放**当前已确认**的：街道图（Map0136_upper）里两个「碰撞只有一条 ~10px 竖带」的灰墙图块，
## 用户实测敌人从旁边挤过去（.workbuddy/tmp/path_blocked_impact.tscn 实测：
## (6,1) 影响 216 格、(2,3) 影响 194 格当前可行走格）。
## 其余三个非整格图块（15,2 / 4,5 / 6,5）**未标注** —— (15,2) 是沿格底的一条横带，
## 影响 690 格，标了会大幅改变街道通行，留给作者按需在编辑器里勾。
const MARKS: Dictionary = {
	"res://tres/Map0136_upper_tileset.tres": [Vector2i(6, 1), Vector2i(2, 3)],
}

var _scanned: int = 0
var _added: int = 0
var _skipped: int = 0
var _marked: int = 0
var _fails: Array[String] = []


func _ready() -> void:
	print("=== 给地图 TileSet 加「寻路障碍」自定义数据层（%s）===" % LAYER_NAME)
	var paths: Array[String] = _collect_tilesets()
	if paths.is_empty():
		print("[FAIL] 没找到任何 tileset")
		get_tree().quit(1)
		return
	for path: String in paths:
		_migrate(path)
	print("--- 结果：扫描 %d / 新建层 %d / 已存在跳过 %d / 标注图块 %d" % [
		_scanned, _added, _skipped, _marked])
	if _fails.is_empty():
		print("=== PATH_BLOCKED_LAYER: PASS ===")
		get_tree().quit(0)
	else:
		for f: String in _fails:
			print("[FAIL] " + f)
		print("=== PATH_BLOCKED_LAYER: %d FAIL ===" % _fails.size())
		get_tree().quit(1)


func _collect_tilesets() -> Array[String]:
	## 目录里所有 .tres —— 再按「load 出来是不是 TileSet」过滤。
	## （地图 tileset 命名不统一：Map0136_lower_tileset / Map0141_tileset / 街道A4 …）
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(TILESET_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			out.append(TILESET_DIR + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _migrate(path: String) -> void:
	var res: Resource = load(path)
	if res == null or not (res is TileSet):
		return   ## 非 TileSet 的 .tres（武器/敌人数据等）静默跳过
	var ts: TileSet = res as TileSet
	_scanned += 1
	## ★ResourceSaver.save() 会丢掉两种 uid：文件头 `[gd_resource ... uid=...]` 与
	## **每一行 `[ext_resource ... uid=...]`**（实测：21 个 tileset 共丢 26 个 ext uid）。
	## 后者更隐蔽 —— 只留 path，若某个 texture 的 path 已过期、原先靠 uid 兜底，
	## 就会改成按 path 解析 → 可能加载到错的资源。两处都先抓、保存后补回。
	var original_uid: String = _read_uid(path)
	var ext_lines: Dictionary = _read_ext_lines(path)
	var idx: int = _find_layer(ts)
	if idx < 0:
		ts.add_custom_data_layer()
		idx = ts.get_custom_data_layers_count() - 1
		ts.set_custom_data_layer_name(idx, StringName(LAYER_NAME))
		ts.set_custom_data_layer_type(idx, TYPE_BOOL)
		var err: Error = ResourceSaver.save(ts, path)
		if err != OK:
			_fails.append("%s 保存失败 err=%d" % [path, err])
			return
		_restore_uid(path, original_uid)
		_restore_ext_lines(path, ext_lines)
		_added += 1
		print("  %-44s 新建 layer %d（bool）" % [path.get_file(), idx])
	else:
		_skipped += 1
	## 标注表（幂等：已经为 true 的不重复计数、也不重复保存）
	if not MARKS.has(path):
		return
	var marks: Array = MARKS[path]
	var changed: int = 0
	for coords: Vector2i in marks:
		var td: TileData = _tile_data(ts, coords)
		if td == null:
			_fails.append("%s 找不到图块 %s" % [path.get_file(), str(coords)])
			continue
		## ★先 `has_custom_data()` 探测：图块从没赋过自定义值时它内部的 custom_data 是**空数组**，
		## 直接按 layer_id 取值会报 "Index p_layer_id = 0 is out of bounds"（详见 EnemyChaseState
		## 的 `_cell_path_blocked` 注释）；也**不能**写 `bool(...)`（GDScript 没有 bool() 构造）。
		if td.has_custom_data(StringName(LAYER_NAME)) and td.get_custom_data(StringName(LAYER_NAME)) == true:
			continue   ## 已标注
		td.set_custom_data_by_layer_id(idx, true)
		changed += 1
	if changed == 0:
		print("  %-44s 标注已齐（%d 个图块）" % [path.get_file(), marks.size()])
		return
	var err2: Error = ResourceSaver.save(ts, path)
	if err2 != OK:
		_fails.append("%s 标注保存失败 err=%d" % [path, err2])
		return
	_restore_uid(path, original_uid)
	_restore_ext_lines(path, ext_lines)
	_marked += changed
	print("  %-44s 标注 %d 个图块为 path_blocked" % [path.get_file(), changed])


func _find_layer(ts: TileSet) -> int:
	for i in range(ts.get_custom_data_layers_count()):
		if ts.get_custom_data_layer_name(i) == StringName(LAYER_NAME):
			return i
	return -1


func _tile_data(ts: TileSet, coords: Vector2i) -> TileData:
	for si: int in ts.get_source_count():
		var src: TileSetSource = ts.get_source(ts.get_source_id(si))
		if src is TileSetAtlasSource:
			var atlas: TileSetAtlasSource = src as TileSetAtlasSource
			if atlas.has_tile(coords):
				return atlas.get_tile_data(coords, 0)
	return null


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


## 读出 `[ext_resource ...]` 的「去 uid 规范化文本 → 原始整行」表（保存前抓）。
## ⚠ 两个坑：
##   ① `uid="..."` 里**含有子串 `id="`**，用 `find("id=\"")` 会命中 uid 自己的那一半
##      （实测抓到 `uids["bls561edu171y"]`）→ 必须 `\b` 词边界匹配；
##   ② ResourceSaver 还会把属性顺序改写（uid 挪到最前），所以**不要只补 uid**，
##      而是按规范化文本把整行换回原样 —— 这样格式与属性顺序一并还原，diff 归零。
var _RE_UID_TOKEN: RegEx = null


func _ensure_regex() -> void:
	if _RE_UID_TOKEN != null:
		return
	_RE_UID_TOKEN = RegEx.new()
	_RE_UID_TOKEN.compile("\\buid=\"[^\"]*\"\\s*")


func _norm_ext_line(line: String) -> String:
	var s: String = _RE_UID_TOKEN.sub(line.strip_edges(), "", true)
	var parts: PackedStringArray = s.split(" ", false)
	return " ".join(parts)


func _read_ext_lines(path: String) -> Dictionary:
	_ensure_regex()
	var out: Dictionary = {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var raw: String = f.get_line()
		if not raw.strip_edges().begins_with("[ext_resource"):
			continue
		out[_norm_ext_line(raw)] = raw
	f.close()
	return out


## 保存后把 `[ext_resource ...]` 整行换回原始行（除 uid 外内容相同的才换）。
func _restore_ext_lines(path: String, table: Dictionary) -> void:
	if table.is_empty():
		return
	_ensure_regex()
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var lines: PackedStringArray = f.get_as_text().split("\n")
	f.close()
	var changed: int = 0
	for i in range(lines.size()):
		var line: String = lines[i]
		if not line.strip_edges().begins_with("[ext_resource"):
			continue
		var key: String = _norm_ext_line(line)
		if table.has(key) and table[key] != line:
			lines[i] = table[key]
			changed += 1
	if changed <= 0:
		return
	var w: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		_fails.append("%s ext 行回写失败（无法打开）" % path)
		return
	w.store_string("\n".join(lines))
	w.close()
