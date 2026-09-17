extends TileMapLayer

## ── 架构定位 ──
## 系统：剧情机关 ｜ 层：玩法（TileMapLayer）
## 联机：爆炸/放置结算仅 Host/单机（call 方是 authoritative 投掷物或请求方）；进度走 Global flag 广播
## 职责：可爆破墙体 —— 用图块直接画墙（本节点就是 TileMapLayer）。
##       ① 被炸药/手雷爆炸命中后擦除图块、更新敌人寻路、置 flag 持久化；
##       ② 关键物品方案：持 flag 的玩家靠近按确定键放置炸药（可配行走图），
##          引线烧完 fuse_time 秒后自动引爆破坏。
## 依赖：Global（quest flag / 音效）、EnemyChaseState（A* 失效接口）、VXAnimSprite（瓦砾动画）、NetworkWorld（联机放置请求）

## 可爆破墙体 — 用 TileMapLayer 画出来的墙，爆炸物可炸开
##
## 摆图方法：
##   1. 在地图场景里新建一个 TileMapLayer 节点，挂上本脚本；
##   2. **节点名必须包含 "wall"（不分大小写）** —— 敌人 A* 按层名判定硬阻挡，
##      起名如 `BlastWall_矿洞入口`；
##   3. 用 TileSet 图块把墙画出来（图块需带物理碰撞，玩家才走不过去）；
##   4. 填 wall_flag（全图唯一，如 "ch3_wall_mine_broken"）。
## 炸开后：图块全部擦除（碰撞随之消失）→ A* 缓存失效重建 → flag 广播给联机全员并存档。
## flag 已置时（存档恢复/联机同步/死亡回安全屋）启动即静默移除，不会复墙。
##
## 两种引爆途径（可并存）：
##   · 投掷物：手雷/炸药投掷物爆炸命中（apply_explosion，走 hits_required 计数）；
##   · 定时放置（推荐，原作第三章玩法）：place_required_flag 填关键道具 flag
##     （由 ItemPickupPoint 发放，grant_throwable 留空），玩家靠近按确定键放置 →
##     墙上显示行走图（引线燃烧）→ fuse_time 秒后自动炸开（无视 hits_required）。
##
## ⚠ 存档/重进简化：引线中途存档，重进后（Host/单机）引线从 fuse_time 重新计满。

const TILE_SIZE: int = 32

# 精灵帧常量（VX Ace 行走图，同 item_pickup_point）
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export_group("破坏进度")
@export var wall_flag: String = ""  ## 破坏标记 flag 名（全图唯一，如 "ch3_wall_mine_broken"）
@export_range(1, 9, 1) var hits_required: int = 1  ## 投掷物路线需要几次爆炸（放置引爆无视此项，一次炸穿）

@export_group("炸药放置（关键物品方案）")
@export var place_required_flag: String = ""  ## 放置所需的关键道具 flag（如 "ch3_has_dynamite"，由拾取点发放）；空 = 不启用放置交互
@export var place_consume_flag: bool = true  ## 放置后清除上述 flag（一面墙消耗一瓶时用）
@export var place_flag: String = ""  ## 已放置标记 flag（联机同步/存档恢复/客户端显示引线用；空则放置状态不同步）
@export_range(0.5, 30.0, 0.5) var fuse_time: float = 3.0  ## 放置到引爆的秒数（引线时间）
@export_range(32.0, 256.0, 1.0) var place_range: float = 96.0  ## 可放置距离（距最近 painted 格）
@export var place_interact_label: String = "放置炸药"  ## 靠近提示（自动拼 [确定]）
@export var place_sound: AudioStream  ## 放置/点燃音效

@export_group("放置外观（VX 行走图）")
@export var place_walk_texture: Texture2D
@export_range(0, 31, 1) var place_char_index: int = 0
@export_range(0, 3, 1) var place_direction: int = 0
@export var place_step_frames: Array[int] = [1, 0, 1, 2]
@export var place_step_duration: float = 0.25

@export_group("提示文字")
@export var show_hint: bool = true  ## 玩家靠近时是否显示提示
@export var hint_text: String = "墙上有裂痕……爆炸物似乎能炸开它。"
@export var hint_text_missing: String = "需要炸药之类的爆炸物才能炸开。"
@export var resupply_hint: String = ""  ## 可选指路文案：全队没爆炸物时替换 missing 显示（如"炸药的补给在入口附近"）
@export_range(32.0, 512.0, 1.0) var hint_range: float = 96.0  ## 提示触发距离（像素，相对最近 painted 格）

@export_group("破坏表现")
@export var rubble_anim: PackedScene  ## 瓦砾/爆裂 VX 动画场景（VXAnimSprite.play_scene 用），留空则不播
@export var destroy_sound: AudioStream  ## 炸开音效
@export var hit_sound: AudioStream  ## 未炸穿时的受击音效（hits_required>1 时用）

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _hits_left: int = 1
var _destroyed: bool = false
var _hint_label: Label = null
var _hint_visible_for: float = 0.0
var _placed: bool = false          ## 炸药已放置（引线燃烧中）
var _placing: bool = false         ## Client 放置请求已提交（防重复提交）
var _placing_timeout: float = 0.0  ## Client 提交锁超时
var _fuse_timer: float = 0.0       ## 引线剩余秒数（仅 Host/单机倒数）
var _fuse_sprite: Sprite2D = null
var _step_index: int = 0
var _step_timer: float = 0.0
var _can_place: bool = false       ## 本帧是否可放置（_update_hint 里统一算好给输入用）


func _ready() -> void:
	add_to_group("blast_wall")
	_hits_left = maxi(1, hits_required)
	_destroyed = Global.has_quest_flag(wall_flag) if not wall_flag.is_empty() else false
	if _destroyed:
		## flag 已置：存档恢复 / 联机同步 / 死亡回安全屋 —— 启动即移除，不播表现
		_apply_destroyed_visual()
		return
	Global.quest_flag_changed.connect(_on_quest_flag_changed)
	# 放置状态恢复（存档/联机同步后重进场景）：显示引线动画；Host/单机重新倒数
	if not place_flag.is_empty() and Global.has_quest_flag(place_flag):
		_placed = true
		_show_fuse_sprite()
		if not _is_client_session():
			_fuse_timer = fuse_time


func _exit_tree() -> void:
	if Global.quest_flag_changed.is_connected(_on_quest_flag_changed):
		Global.quest_flag_changed.disconnect(_on_quest_flag_changed)


func _on_quest_flag_changed(flag_name: String, value: bool) -> void:
	## 联机 Client / 其他路径收到 flag 广播 → 本地做纯表现
	if not wall_flag.is_empty() and flag_name == wall_flag and value:
		_destroyed = true
		_placed = false
		_apply_destroyed_visual()
	elif not place_flag.is_empty() and flag_name == place_flag and value:
		_placing = false
		if not _placed:
			_placed = true
			_show_fuse_sprite()


func _process(delta: float) -> void:
	if _destroyed:
		if _hint_label and _hint_label.visible:
			_hint_label.visible = false
		return
	# 引线：动画所有端都播（纯表现）；倒数只在 Host/单机（Client 等 wall_flag 广播）
	if _placed:
		_tick_fuse(delta)
	# Client 放置提交锁超时复位
	if _placing:
		_placing_timeout -= delta
		if _placing_timeout <= 0.0:
			_placing = false
	if not show_hint:
		if _hint_label and _hint_label.visible:
			_hint_label.visible = false
		return
	_update_hint()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _destroyed or _placed or _placing or not _can_place:
		return
	if event.is_action_pressed("确定键"):
		## 与拾取点/安全门一致：UI 先消费按键，不隔着菜单误触发
		get_viewport().set_input_as_handled()
		var players: Node = get_node_or_null("/root/Players")
		var player: CharacterBody2D = players.nearest_entity_to(global_position) if players and players.has_method("nearest_entity_to") else null
		_request_place(player)


# ═══════════════════════════════════════
# 爆炸结算（仅单机 / Host 调用）
# ═══════════════════════════════════════

## 投掷物/爆炸子弹回调：爆炸圆心 pos、半径 radius_px。命中任意 painted 格 → 计 1 次破坏。
## can_break=false 的爆炸源（火箭筒/榴弹/手雷等，见 BulletData/ThrowableData.breaks_blast_wall）
## 只给"炸不开"的反馈，不计破坏进度 —— 2026-09-16 用户定稿：矿洞墙体只认炸药。
## 返回是否命中（供调用方决定是否播爆炸墙表现）。
func apply_explosion(pos: Vector2, radius_px: float, can_break: bool = true) -> bool:
	if _destroyed:
		return false
	var hit: bool = false
	for gp in get_used_cells():
		var center: Vector2 = to_global(map_to_local(gp))
		if center.distance_to(pos) <= radius_px + TILE_SIZE * 0.5:
			hit = true
			break
	if not hit:
		return false
	if not can_break:
		if hit_sound:
			Global.play_sfx_managed(hit_sound, get_tree().current_scene)
		print("[BlastWall] %s 挨了一发但纹丝不动（此爆炸物炸不开，需要炸药）" % name)
		return false
	_hits_left -= 1
	if _hits_left <= 0:
		_destroyed = true
		_apply_destroyed_visual(pos)
		_commit_destroy_flag()
		print("[BlastWall] %s 被炸开" % name)
	else:
		if hit_sound:
			Global.play_sfx_managed(hit_sound, get_tree().current_scene)
		print("[BlastWall] %s 受击，剩余 %d 次" % [name, _hits_left])
	return true


## Host 权威提交 flag（单机/Host 已由本节点结算表现，广播让 Client 同步表现）。
func _commit_destroy_flag() -> void:
	if wall_flag.is_empty():
		printerr("[BlastWall] %s 未配置 wall_flag，破坏进度不会被记录！" % name)
		return
	Global.request_quest_flag(wall_flag, true)


# ═══════════════════════════════════════
# 炸药放置（关键物品方案）
# ═══════════════════════════════════════

func _request_place(player: CharacterBody2D) -> void:
	## 确定键入口。单机/Host 直接结算；Client 提交请求，等 place_flag 回包做表现。
	var scene := get_tree().current_scene
	var world := scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_wall_place"):
		_placing = true
		_placing_timeout = 2.0
		world.call("request_wall_place", scene.get_path_to(self))
		return
	host_commit_place(player)


## Host 权威提交（单机直调 / NetworkWorld._try_host_wall_place 调用）。
## 校验：未破坏、未放置、配置齐全、持有 flag、距离合法。
## 结算：置 place_flag（广播）→ 消耗关键道具 flag → 表现 + 启动引线。
func host_commit_place(player: CharacterBody2D) -> void:
	if _destroyed or _placed or place_required_flag.is_empty():
		return
	if not Global.has_quest_flag(place_required_flag):
		return
	var ppos: Vector2 = player.global_position if is_instance_valid(player) else global_position
	var nearest := _nearest_cell_center(ppos)
	if nearest == Vector2.INF or nearest.distance_to(ppos) > place_range:
		print("[BlastWall] %s 放置拒绝：距离过远" % name)
		return
	_placed = true
	_fuse_timer = fuse_time
	_step_timer = 0.0
	if not place_flag.is_empty():
		## flag 回环会再调一次 _show_fuse_sprite（幂等）；本地先摆好位置防回包延迟
		_show_fuse_sprite(nearest)
		Global.request_quest_flag(place_flag, true)
	else:
		_show_fuse_sprite(nearest)
	if place_consume_flag:
		Global.request_quest_flag(place_required_flag, false)
	if place_sound:
		Global.play_sfx_managed(place_sound, get_tree().current_scene)
	print("[BlastWall] %s 炸药已放置，%.1f 秒后引爆" % [name, fuse_time])


func _tick_fuse(delta: float) -> void:
	## 引线行走图所有端都播（纯表现）；倒数只在 Host/单机，Client 等 wall_flag 广播。
	if place_walk_texture and not place_step_frames.is_empty():
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(place_step_duration, 0.02)
			_step_index = (_step_index + 1) % place_step_frames.size()
			_refresh_fuse_sprite()
	if _is_client_session():
		return
	_fuse_timer -= delta
	if _fuse_timer <= 0.0:
		_explode_placed()


func _explode_placed() -> void:
	var at: Vector2 = _fuse_sprite.global_position if _fuse_sprite else _nearest_cell_center(global_position)
	if at == Vector2.INF:
		at = global_position
	_destroyed = true
	_placed = false
	_apply_destroyed_visual(at)
	_commit_destroy_flag()
	print("[BlastWall] %s 放置的炸药引爆" % name)


func _show_fuse_sprite(at: Vector2 = Vector2.INF) -> void:
	if place_walk_texture == null:
		return
	if not _fuse_sprite:
		_fuse_sprite = Sprite2D.new()
		_fuse_sprite.name = "FuseSprite"
		add_child(_fuse_sprite)
	if at == Vector2.INF:
		## 广播恢复路径：取最近 painted 格（相对本地最近玩家；无玩家则层原点）
		var players: Node = get_node_or_null("/root/Players")
		var player: CharacterBody2D = players.nearest_entity_to(global_position) if players and players.has_method("nearest_entity_to") else null
		var base: Vector2 = player.global_position if is_instance_valid(player) else global_position
		at = _nearest_cell_center(base)
		if at == Vector2.INF:
			at = global_position
	_fuse_sprite.global_position = at
	_fuse_sprite.visible = true
	_step_index = 0
	_step_timer = 0.0
	_refresh_fuse_sprite()


func _refresh_fuse_sprite() -> void:
	if not _fuse_sprite or not place_walk_texture:
		return
	_fuse_sprite.texture = place_walk_texture
	_fuse_sprite.region_enabled = true
	var frame: int = clampi(place_step_frames[_step_index], 0, 2) if _step_index < place_step_frames.size() else 0
	var char_col: int = place_char_index % CHARS_PER_ROW
	var char_row: int = place_char_index / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + place_direction * FRAME_H
	_fuse_sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _hide_fuse_sprite() -> void:
	if _fuse_sprite:
		_fuse_sprite.visible = false


func _is_client_session() -> bool:
	## 用节点路径而非 autoload 标识符，兼容编辑器脚本热重载时序（同 Director 做法）
	var net: Node = get_node_or_null("/root/Net")
	return net != null \
		and net.has_method("is_online_session") \
		and net.is_online_session() \
		and not bool(net.get("is_host"))


## flag 回环去重：本节点自己结算时已置 _destroyed，广播回来不会重复播表现。
func _apply_destroyed_visual(blast_pos: Vector2 = Vector2.INF) -> void:
	var had_cells: bool = not get_used_cells().is_empty()
	for gp in get_used_cells():
		erase_cell(gp)
	enabled = false
	visible = false
	_hide_fuse_sprite()
	if _hint_label:
		_hint_label.visible = false
	if had_cells:
		EnemyChaseState.notify_map_changed()
	## 瓦砾/爆裂表现：结算路径用爆炸点，广播路径回退层原点
	if rubble_anim:
		var at: Vector2 = blast_pos if blast_pos != Vector2.INF else global_position
		VXAnimSprite.play_scene(rubble_anim, at, get_tree().current_scene)


# ═══════════════════════════════════════
# 提示
# ═══════════════════════════════════════

func _update_hint() -> void:
	var players: Node = get_node_or_null("/root/Players")
	var player: CharacterBody2D = players.nearest_entity_to(global_position) if players and players.has_method("nearest_entity_to") else null
	if not is_instance_valid(player):
		_can_place = false
		_hide_hint()
		return
	# 以最近的 painted 格中心为基准测距（层原点可能在地图角落）
	var nearest := _nearest_cell_center(player.global_position)
	var dist: float = nearest.distance_to(player.global_position) if nearest != Vector2.INF else INF
	# 放置资格：启用放置、未放置、持有 flag、距离足够（供 _unhandled_input 用）
	_can_place = not _placed \
		and not place_required_flag.is_empty() \
		and Global.has_quest_flag(place_required_flag) \
		and dist <= place_range
	# 引线燃烧中不显示任何提示
	if _placed:
		_can_place = false
		_hide_hint()
		return
	var text: String = ""
	if _can_place:
		text = "%s [确定]" % place_interact_label
	elif dist <= hint_range:
		if not place_required_flag.is_empty():
			## 关键物品方案：没带炸药时给缺失/指路提示
			text = resupply_hint if not resupply_hint.is_empty() else hint_text_missing
		elif Global.team_has_wall_breaker():
			text = hint_text
		else:
			text = resupply_hint if not resupply_hint.is_empty() else hint_text_missing
	else:
		_hide_hint()
		return
	if not _hint_label:
		_hint_label = Label.new()
		_hint_label.name = "HintLabel"
		Global.apply_text_shadow(_hint_label)
		Global.apply_hint_font(_hint_label, 24)  ## 字体统一（2026-09-17）：多行提示信息用 24 保读性
		_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint_label.size = Vector2(320, 48)
		add_child(_hint_label)
	if _hint_label.text != text:
		_hint_label.text = text
	_hint_label.position = Vector2(-160.0, -64.0)
	_hint_label.visible = true


func _hide_hint() -> void:
	if _hint_label and _hint_label.visible:
		_hint_label.visible = false


func _nearest_cell_center(pos: Vector2) -> Vector2:
	## 最近的 painted 格中心（世界坐标）；无图块返回 Vector2.INF
	var best: Vector2 = Vector2.INF
	var best_d: float = INF
	for gp in get_used_cells():
		var center: Vector2 = to_global(map_to_local(gp))
		var d: float = center.distance_to(pos)
		if d < best_d:
			best_d = d
			best = center
	return best
