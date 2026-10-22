extends Node

## ── 架构定位 ──
## 系统：还原管线配套工具 ｜ 层：tools（只读体检，不改任何资源）
## 职责：扫描 `res://tres/*.tres` 里所有 TileSet，列出「碰撞多边形不是整格矩形」的图块。
##
## 【为什么需要它】敌人寻路的可行走判据是「碰撞体能否在这一格里站下」（`EnemyChaseState._is_walkable`）。
## 碰撞不铺满整格的图块（薄边带 / L 形 / 半高墙）旁边站得下 → 会被当作可通行。
## 项目约定（2026-10-22 用户拍板）：**图块的物理层一律做成整格 32×32**，
## 这样寻路、物理、视觉三者一致。此前那套 `path_blocked` 自定义数据层逐块标注
## 已随 `add_path_blocked_layer` 一并移除（只能覆盖标过的图，换地图必然复发）。
##
## 【判据】多边形顶点的 AABB 换算成格内坐标后是否正好等于 (0,0,32,32)：
##   - 顶点数 != 4 → 非整格（L 形 / 台阶 / 斜边）
##   - AABB != 整格 → 非整格（薄边带）
## 非矩形但仍铺满 AABB 的情况（L 形 6 顶点）也会被列出：寻路靠 AABB 近似会当整格墙，
## 但**物理**是精确多边形，玩家能从缺口钻进去 —— 两边不一致，仍需改成整格。
##
## 用法：godot --headless --path . res://tools/report_non_full_collision.tscn
## 退出码：0 = 全部整格；1 = 存在需要处理的图块（便于接进 batch_check）。

const TILESET_DIR: String = "res://tres"
const CELL: float = 32.0
const HALF: float = 16.0
const EPS: float = 0.01

## 豁免表 —— 「这个图块的碰撞**故意**不铺满整格」。
## 判据：该图块在关卡里沿整排连续摆放、充当通道边界（墙沿 / 地面与墙的交界带）。
## 改成整格等于在通路上砌一整道墙，会把地图切成互不连通的条带。
## 记录时必须写明影响面的实测数据，方便后人复核。
const EXEMPT: Dictionary = {
	"res://tres/Map0136_upper_tileset.tres": {
		Vector2i(15, 2): "街道图沿 y=62/83/95/111/148 整排摆放（单排 85~139 格，共 830 格），改整格少 690 个可行走格、主连通域 5311→4839",
	},
}

var _scanned: int = 0
var _tilesets_with_issue: int = 0
var _tile_count: int = 0
var _poly_count: int = 0
var _exempt_seen: Dictionary = {}


func _ready() -> void:
	print("=== 扫描非整格碰撞图块（判据：物理层多边形 AABB 是否为 32×32 整格）===")
	var paths: Array[String] = _collect()
	for path: String in paths:
		_scan(path)
	print("\n--- 汇总：扫描 tileset %d / 有问题的 tileset %d / 待改图块 %d / 待改多边形 %d / 豁免 %d" % [
		_scanned, _tilesets_with_issue, _tile_count, _poly_count, _exempt_seen.size()])
	for key: String in _exempt_seen.keys():
		print("    [豁免] %s —— %s" % [key, _exempt_seen[key]])
	if _tile_count == 0:
		print("=== NON_FULL_COLLISION: PASS（全部整格）===")
		get_tree().quit(0)
	else:
		print("=== NON_FULL_COLLISION: %d 个图块待处理 ===" % _tile_count)
		get_tree().quit(1)


func _collect() -> Array[String]:
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


func _scan(path: String) -> void:
	var res: Resource = load(path)
	if res == null or not (res is TileSet):
		return   ## 非 TileSet 的 .tres 静默跳过
	var ts: TileSet = res as TileSet
	_scanned += 1
	var n_phys: int = ts.get_physics_layers_count()
	if n_phys == 0:
		return

	var issues: Array[String] = []
	for si in range(ts.get_source_count()):
		var sid: int = ts.get_source_id(si)
		var src: TileSetSource = ts.get_source(sid)
		if not (src is TileSetAtlasSource):
			continue
		var atlas: TileSetAtlasSource = src as TileSetAtlasSource
		for ti in range(atlas.get_tiles_count()):
			var co: Vector2i = atlas.get_tile_id(ti)
			var alts: int = atlas.get_alternative_tiles_count(co)
			for alt in range(alts):
				var td: TileData = atlas.get_tile_data(co, alt)
				if td == null:
					continue
				for pli in range(n_phys):
					var pc: int = td.get_collision_polygons_count(pli)
					for pi in range(pc):
						var pts: PackedVector2Array = td.get_collision_polygon_points(pli, pi)
						if pts.size() < 3:
							continue
						var r: Rect2 = _aabb_cell(pts)
						var full: bool = absf(r.position.x) <= EPS and absf(r.position.y) <= EPS \
							and absf(r.size.x - CELL) <= EPS and absf(r.size.y - CELL) <= EPS
						var quad: bool = pts.size() == 4
						if full and quad and pc == 1:
							continue
						if _exempt_has(path, co):
							_exempt_seen["%s %s" % [path.get_file(), str(co)]] = _exempt_reason(path, co)
							continue
						_tile_count += 1
						_poly_count += 1
						issues.append("    atlas=(%d,%d) alt=%d layer=%d poly#%d  顶点=%d  aabb=(%.1f,%.1f %.1fx%.1f)  覆盖=%.0f%%" % [
							co.x, co.y, alt, pli, pi, pts.size(), r.position.x, r.position.y,
							r.size.x, r.size.y, (r.size.x * r.size.y) / (CELL * CELL) * 100.0])
	if issues.is_empty():
		return
	_tilesets_with_issue += 1
	print("\n[%s]  %d 处待改：" % [path.get_file(), issues.size()])
	for line: String in issues:
		print(line)


func _exempt_has(path: String, co: Vector2i) -> bool:
	var table: Variant = EXEMPT.get(path, null)
	return table is Dictionary and (table as Dictionary).has(co)


func _exempt_reason(path: String, co: Vector2i) -> String:
	var table: Variant = EXEMPT.get(path, null)
	if table is Dictionary and (table as Dictionary).has(co):
		return String((table as Dictionary)[co])
	return ""


func _aabb_cell(pts: PackedVector2Array) -> Rect2:
	var minx := 1e9
	var maxx := -1e9
	var miny := 1e9
	var maxy := -1e9
	for p: Vector2 in pts:
		minx = minf(minx, p.x + HALF)
		maxx = maxf(maxx, p.x + HALF)
		miny = minf(miny, p.y + HALF)
		maxy = maxf(maxy, p.y + HALF)
	return Rect2(minx, miny, maxx - minx, maxy - miny)
