extends Node

## ── 架构定位 ──
## 系统：调试工具 ｜ 层：单例挂载（由 Global 在 _ready 里动态创建，不落场景文件）
## 联机：纯本机，只读现场状态，不改任何权威数据
## 职责：按键把「画面 + 现场数据」一起存盘 —— 用于把"敌人卡住/挤墙"这类动态问题交给外部排查。
## 依赖：Global（debug 开关）、EnemyChaseState（静态可行走判定）、场景树（player / enemy 分组）

## 现场抓取器
##
## 【为什么需要它】
## 静态截图看不出"卡住"是怎么形成的 —— 看不出敌人当前路径、当前航点在不在墙里、
## 它脚下那格到底判成可行走还是阻挡。而录像这边没法直接看，所以这里改成
## 「连拍若干张 PNG + 一份带数字的报告」，报告里直接画出每只敌人周围 7×7 格的
## 可行走地图（ASCII），把"它为什么拐不了弯"变成可读的文字。
##
## 【用法】游戏运行中：
##   F2 → 连拍 8 张（每 0.25 秒一张）+ 写报告
##   F4 → 只写报告（瞬时，不产生图片）
## 产物目录会打印在控制台（形如 <项目目录>/Godot/app_userdata/<项目名>/debug_capture/run_<时间戳>/），
## 把这个目录告诉排查方即可。
##
## 【为什么用 user:// 而不是 res://】user:// 已被 .gitignore 排除，抓取产物不会污染版本库。

const CHASE_SCRIPT := preload("res://script/enemy/EnemyChaseState.gd")

const CAPTURE_KEY: int = KEY_F2      ## 连拍 + 报告
const REPORT_KEY: int = KEY_F4       ## 只写报告
const OUT_DIR: String = "user://debug_capture"
const SHOT_COUNT: int = 8            ## 连拍张数
const SHOT_INTERVAL: float = 0.25    ## 连拍间隔（秒）
const SURROUND_RADIUS: int = 3       ## 报告里画敌人周围几圈格子

var _run_dir: String = ""
var _shots_left: int = 0
var _shot_timer: float = 0.0
var _shot_index: int = 0


func _ready() -> void:
	set_process(true)
	print("[抓取] 就绪 —— F2 连拍+报告，F4 只写报告（输出目录会在触发时打印）")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k: InputEventKey = event
	if not k.pressed or k.echo:
		return
	var code: int = k.physical_keycode
	if code == 0:
		code = k.keycode
	if code == CAPTURE_KEY:
		start_capture(true)
	elif code == REPORT_KEY:
		start_capture(false)


func _process(delta: float) -> void:
	if _shots_left <= 0:
		return
	_shot_timer -= delta
	if _shot_timer > 0.0:
		return
	_shot_timer = SHOT_INTERVAL
	var idx: int = _shot_index
	_shot_index += 1
	_shots_left -= 1
	await _save_shot(idx)
	if _shots_left <= 0:
		print("[抓取] 连拍结束")


## 触发一次抓取。with_shots=false 时只写报告（瞬时）。
func start_capture(with_shots: bool) -> void:
	## 时间戳只留数字与下划线：目录名带空格会让命令行引用变麻烦
	var stamp: String = Time.get_datetime_string_from_system(false, true)
	stamp = stamp.replace("-", "").replace(":", "").replace("T", "_").replace(" ", "_")
	_run_dir = "%s/run_%s" % [OUT_DIR, stamp]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_dir))
	print("[抓取] 输出目录: %s" % abs_path(_run_dir))
	_write_report()
	if with_shots:
		_shots_left = SHOT_COUNT
		_shot_index = 0
		_shot_timer = 0.0
	else:
		_shots_left = 0
		print("[抓取] 仅报告已写出（F2 可同时连拍画面）")


## 取绝对路径。自包含运行（user:// 落在项目内）时 globalize_path 可能返回 "./xxx"，
## 这时用 res:// 的绝对路径拼一下 —— 输出要能直接粘贴给排查方。
func abs_path(p: String) -> String:
	var g: String = ProjectSettings.globalize_path(p)
	if g.begins_with("./") or g.begins_with(".\\"):
		g = ProjectSettings.globalize_path("res://").path_join(g.substr(2))
	return g.simplify_path()


func _save_shot(index: int) -> void:
	if DisplayServer.get_name() == "headless":
		print("[抓取] headless 无画面，跳过截图")
		_shots_left = 0
		return
	await RenderingServer.frame_post_draw
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null:
		return
	var path: String = "%s/shot_%02d.png" % [_run_dir, index]
	if img.save_png(path) == OK:
		print("[抓取] 画面 %s" % abs_path(path))


# ═══════════════════════════════════════
# 报告
# ═══════════════════════════════════════

func _write_report() -> void:
	var out: PackedStringArray = []
	out.append("=== 现场抓取 %s ===" % Time.get_datetime_string_from_system())
	var cs: Node = get_tree().current_scene
	out.append("场景: %s" % (cs.scene_file_path if cs else "(无)"))
	out.append("debug_enabled=%s  debug_visuals=%s（调试层开关＝TAB）" % [
		str(Global.debug_enabled), str(Global.debug_visuals)])
	out.append("A* 网格: 已构建=%s 构建中=%s 格子缓存=%d 立足点缓存=%d 碰撞盒缓存=%d 图层=%d" % [
		str(CHASE_SCRIPT._astar_grid != null), str(CHASE_SCRIPT._grid_building),
		CHASE_SCRIPT._tile_walk_cache.size(), CHASE_SCRIPT._stand_cache.size(),
		CHASE_SCRIPT._cell_rect_cache.size(), CHASE_SCRIPT._tilemaps.size()])
	var dr: Node = get_node_or_null("/root/Director")
	if dr:
		out.append("回收: 启用=%s 距离=%.0f 已清存活=%d 已清尸体=%d" % [
			str(dr.get("recycle_enabled")), float(dr.get("recycle_dist")),
			int(dr.get("_recycle_cleared")), int(dr.get("_recycle_corpses"))])
		var fs2: Node = dr.get_node_or_null("FrontSpawner")
		var p0: Node2D = get_tree().get_first_node_in_group("player") as Node2D
		if fs2 and p0:
			out.append("    %s" % str(fs2.debug_state(p0)))
	var layer_names: PackedStringArray = []
	for tm in CHASE_SCRIPT._tilemaps:
		if is_instance_valid(tm):
			layer_names.append(tm.name)
	out.append("图层: %s" % ", ".join(layer_names))

	out.append("")
	_append_entities(out, "player", "玩家")
	out.append("")
	_append_entities(out, "enemy", "敌人")

	var text: String = "\n".join(out) + "\n"
	var path: String = "%s/report.txt" % _run_dir
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[抓取] ❌ 报告写入失败: %s" % path)
		return
	f.store_string(text)
	f.close()
	print("[抓取] 报告 %s" % abs_path(path))


func _append_entities(out: PackedStringArray, group: String, label: String) -> void:
	var nodes: Array[Node] = get_tree().get_nodes_in_group(group)
	out.append("── %s %d 个 ──" % [label, nodes.size()])
	for i in range(nodes.size()):
		var n: Node2D = nodes[i] as Node2D
		if n == null or not is_instance_valid(n):
			out.append("  #%d （已失效）" % i)
			continue
		out.append("  #%d" % i)
		_append_common(out, n)
		if group == "enemy":
			_append_enemy_extra(out, n)
		_append_surround(out, n)


func _append_common(out: PackedStringArray, n: Node2D) -> void:
	var pos: Vector2 = n.global_position
	var gp: Vector2i = Vector2i(floori(pos.x / CHASE_SCRIPT._cell_size), floori(pos.y / CHASE_SCRIPT._cell_size))
	out.append("    节点=%s  位置=(%.1f, %.1f)  所在格=%s" % [n.name, pos.x, pos.y, str(gp)])
	var hp_v: Variant = n.get("current_hp")
	var max_v: Variant = n.get("max_hp")
	if hp_v != null:
		out.append("    hp=%s/%s" % [str(hp_v), str(max_v)])
	var sm: Node = n.get_node_or_null("StateMachine")
	if sm and sm.get("current_state"):
		var st: Node = sm.get("current_state")
		out.append("    状态机=%s" % st.name)
		out.append("    状态字段 stuck=%s fallback=%s no_path=%s" % [
			str(st.get("_stuck_frames")), str(st.get("_fallback_mode")),
			str(st.get("_no_path_count"))])


func _append_enemy_extra(out: PackedStringArray, n: Node2D) -> void:
	var target: Variant = n.get("_player_ref")
	if target is Node2D:
		var t: Vector2 = (target as Node2D).global_position
		out.append("    追击目标=(%.1f, %.1f) 距离=%.1f" % [
			t.x, t.y, n.global_position.distance_to(t)])
	var path_v: Variant = n.get("_debug_path")
	var path: Array = path_v if path_v is Array else []
	var idx_v: Variant = n.get("_debug_path_idx")
	var idx: int = int(idx_v) if idx_v != null else 0
	out.append("    路径: 航点数=%d 当前航点#%d 寻路成功=%s" % [
		path.size(), idx, str(n.get("_debug_path_found"))])
	if path.size() > 0:
		if idx < path.size():
			var wp: Vector2 = path[idx]
			out.append("    当前航点=(%.1f, %.1f) 距该点=%.1f" % [
				wp.x, wp.y, n.global_position.distance_to(wp)])
		var tail: PackedStringArray = []
		for j in range(idx, mini(path.size(), idx + 6)):
			var p: Vector2 = path[j]
			tail.append("(%.0f,%.0f)" % [p.x, p.y])
		out.append("    后续航点: %s" % " → ".join(tail))
		_append_path_followable(out, path)


func _append_path_followable(out: PackedStringArray, path: Array) -> void:
	## 逐段复核整条路径「碰撞体是否全程可通过」。这是"路径线穿墙 / 敌人顶着墙磨"的
	## **直接判据** —— 报告里带上它，就不必再让人猜是哪一段出的问题。
	if path.size() < 2:
		return
	var bad: PackedStringArray = []
	for i in range(path.size() - 1):
		if not CHASE_SCRIPT._segment_followable(path[i], path[i + 1]):
			bad.append("#%d" % i)
	if bad.is_empty():
		out.append("    路径可跟随: 是（%d 段全部「碰撞体全程可通过」）" % (path.size() - 1))
	else:
		out.append("    路径可跟随: ❌ 否 —— 段 %s 不可跟随（该段上有位置站不下 / 穿过不可行走格）" % ", ".join(bad))


func _append_surround(out: PackedStringArray, n: Node2D) -> void:
	var cs: float = CHASE_SCRIPT._cell_size
	var pos: Vector2 = n.global_position
	var c: Vector2i = Vector2i(floori(pos.x / cs), floori(pos.y / cs))
	out.append("    周边 %d×%d（O=可行走 X=不可行走 ◎=实体所在格 *=下一个航点）:" % [
		SURROUND_RADIUS * 2 + 1, SURROUND_RADIUS * 2 + 1])
	var wp_cell := Vector2i(-99999, -99999)
	var path_v: Variant = n.get("_debug_path")
	var idx_v: Variant = n.get("_debug_path_idx")
	if path_v is Array and idx_v != null:
		var arr: Array = path_v
		var ii: int = int(idx_v)
		if ii >= 0 and ii < arr.size():
			var w: Vector2 = arr[ii]
			wp_cell = Vector2i(floori(w.x / cs), floori(w.y / cs))
	for dy in range(-SURROUND_RADIUS, SURROUND_RADIUS + 1):
		var row: PackedStringArray = []
		for dx in range(-SURROUND_RADIUS, SURROUND_RADIUS + 1):
			var gp := Vector2i(c.x + dx, c.y + dy)
			var ch: String = "."
			if gp == c:
				ch = "◎"
			elif gp == wp_cell:
				ch = "*"
			elif CHASE_SCRIPT._is_walkable(gp):
				ch = "O"
			else:
				ch = "X"
			row.append(ch)
		out.append("      " + " ".join(row))
	# 实体所在格自身的细节
	out.append("    ◎格明细: 可行走=%s 立足点=%s 有地面=%s 有wall层=%s 阻挡盒=%d" % [
		str(CHASE_SCRIPT._is_walkable(c)), str(CHASE_SCRIPT._stand_center(c)),
		str(CHASE_SCRIPT._has_ground_at(c)), str(CHASE_SCRIPT._has_wall_at(c)),
		CHASE_SCRIPT._cell_block_rects(c).size()])
	if wp_cell.x != -99999:
		out.append("    *格明细: 可行走=%s 立足点=%s 阻挡盒=%d" % [
			str(CHASE_SCRIPT._is_walkable(wp_cell)), str(CHASE_SCRIPT._stand_center(wp_cell)),
			CHASE_SCRIPT._cell_block_rects(wp_cell).size()])
