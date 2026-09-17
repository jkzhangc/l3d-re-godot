@tool
class_name HoldoutMachine extends Node2D

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node2D, @tool）
## 联机：仅单机/Host 启动，结果广播
## 职责：防守战机器：靠近按确定键开启限时防守，驱动 HUD 倒计时、专属 BGM、结束传送点与联机同步。
## 依赖：EventManager、CombatHud、HoldoutTeleportConfig、TeleportPoint

## 防守战机器 — 放在地图上，玩家靠近按「确定键」启动一场限时防守战。
##
## @tool：让行走图（Sprite2D）在编辑器里实时显示，方便摆位与配帧；
## 游戏逻辑（玩家检测 / 倒计时 / 联机广播）在编辑器里全部跳过，避免无 Players/Director 时报错。
##
## 与已有雏形的关系：
##   ScriptedEventTrigger（event_trigger.gd）是「玩家踩进 Area2D 自动触发」的防守事件雏形。
##   本节点是它的交互式改良版，复用同一套 Director → EventManager 剧本事件管线
##   （start_scripted_event / on_event_completed），并额外提供：
##     1) 行走图实体 + 靠近按键交互（沿用 TeleportPoint / SafeDoor 的交互范式）+ 32×32 碰撞体
##     2) 倒计时 UI 完全托管给地图内 CombatHUD（位置/样式在 combat_hud.tscn 里改，本节点无 UI 参数）
##     3) 刷怪节奏由本节点独立配置（「刷怪节奏（防守战专属）」参数组），与普通尸潮参数分离；
##        刷出的丧尸走普通 AI、不会直扑玩家
##     4) 倒计时结束触发可配置的完成事件（隐藏节点 / 显示节点 / 生成多个传送点 / 自定义回调）
##     5) 防守战期间播放专属 BGM，结束/中止时停止
##
## 联机说明：剧本事件与敌人生成是 Host 权威（Director 在 Client 上直接 return），
## 因此本机器只允许单机或 Host 启动；Client 靠近时提示需由主机操作。

# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## 机器碰撞体（32×32 正方形，居中于节点原点）
const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_SIZE: float = 32.0

# 显式 preload 保证类型在编辑器热重载期间也已注册
const TELEPORT_POINT_SCRIPT := preload("res://script/director/teleport_point.gd")
## 击杀计数过滤用（enemy.gd 无 class_name，node_added 时机早于 add_to_group，
## 不能用 "enemy" 组过滤新刷的丧尸，按脚本比对）
const ENEMY_SCRIPT := preload("res://script/enemy.gd")

## 防守战阶段（与 CombatHud 的 countdown 区块一致，用 int 跨 RPC 传递）。
##   0=IDLE（隐藏） 1=PREPARE（准备） 2=ACTIVE（进行） 3=SETTLE（结算）
enum Phase { IDLE = 0, PREPARE = 1, ACTIVE = 2, SETTLE = 3 }

## 结束模式（对照《原作突袭战役防守战时间.md》的原作ラッシュ三分类，2026-09-15）。
##   0=TIMER 耐久型  1=KILL_COUNT 杀怪式  2=EXTERNAL 永续型（外部驱动）
enum EndMode { TIMER = 0, KILL_COUNT = 1, EXTERNAL = 2 }

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal holdout_started(event_name: String)
signal holdout_finished(event_name: String)

# ═══════════════════════════════════════
# 配置 — 外观（VX Ace 行走图，与武器掉落物同一套渲染规则）
# ═══════════════════════════════════════
@export_group("外观（行走图）")
@export var walk_texture: Texture2D                       ## 精灵表，例如 art/misc/[2K-VX]-cps_obj01.png
@export_range(0, 7, 1) var walk_char_index: int = 0       ## 精灵表中的角色索引
@export_range(0, 3, 1) var walk_direction: int = 0        ## 朝向（0=下 1=左 2=右 3=上）
@export var sprite_offset: Vector2 = Vector2(0, -8)       ## 精灵相对节点原点的偏移
@export var step_frames: Array[int] = [1]                 ## 踏步帧序列（0~2）
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = false                        ## 是否播放踏步动画

# ═══════════════════════════════════════
# 配置 — 交互
# ═══════════════════════════════════════
@export_group("交互")
@export var interact_label: String = "启动机器"            ## 待机时的提示文字
@export var interact_label_running: String = "防守中…"     ## 防守战进行中的提示文字
@export var interact_label_done: String = ""              ## 完成后的提示文字（留空=不显示）
@export_range(8.0, 512.0, 1.0) var interact_range: float = 56.0  ## 交互触发距离（像素）
@export var one_shot: bool = true                         ## 只能启动一次
@export var auto_start_on_approach: bool = false          ## true=玩家靠近即自动启动，无需按键

# ═══════════════════════════════════════
# 配置 — 防守战本体
# ═══════════════════════════════════════
@export_group("防守战")
@export var event_name: String = ""                       ## 事件标识（留空=用节点名），用于日志/信号

## 结束模式（原作ラッシュ三分类，数据来源《原作突袭战役防守战时间.md》）：
##   TIMER      耐久型 —— holdout_duration 倒计时归零结束，杀敌不影响开门
##               （原作全战役唯一计时型 = 第二关学校 120s；计时器归零开シャッター）
##   KILL_COUNT 杀怪式 —— 无时长限制，杀满 kill_target 只结束
##               （原作 147 终章：杀满 4 只组1丧尸 var1391≥4 → 暴君窗口关闭、开门）
##   EXTERNAL   永续型 —— 无自动结束，外部（到达点/剧情事件）调用 complete_external() 结束
##               （原作坑道：杀到楼梯 EV0059 为止，无计时器；跑得越快越短）
@export var end_mode: EndMode = EndMode.TIMER
@export_range(1, 500, 1) var kill_target: int = 4         ## KILL_COUNT：目标击杀数（原作 147 终章=4）
## KILL_COUNT 计数过滤（2026-09-15 用户需求「杀4只暴君」）：
##   ALL  = 所有敌人都算（原作 147 组1丧尸语义）
##   TANK = 只计 tank_enemies 组（坦克/暴君级；防守战 Tank 通道刷出，需地图 DirectorConfig
##          开 holdout_tank_enabled，否则永远凑不满会卡死——列车台已开）
enum KillFilter { ALL = 0, TANK = 1 }
@export var kill_count_filter: KillFilter = KillFilter.ALL
@export_range(1.0, 1800.0, 1.0) var holdout_duration: float = 120.0  ## TIMER：倒计时总时长（秒；原作学校防守=120）
@export_range(0.0, 30.0, 0.5) var prepare_duration: float = 3.0   ## 准备阶段时长（秒，0=直接进入进行）
@export_range(0.0, 30.0, 0.5) var settle_duration: float = 0.0    ## 结算阶段时长（秒；0=杀满/归零后立即开门。2026-09-15 用户要求去掉结束延迟）
##
## 【刷怪节奏】防守战的刷怪节奏由本节点独立配置（下方「刷怪节奏（防守战专属）」参数组），
## 与普通尸潮（SpawnManager 的 horde_* 参数）完全分离、互不影响：
##   每批数量 = spawn_per_wave、批次间隔 = spawn_interval、
##   存活上限 = max_active（0 = 沿用全局 SpawnManager.max_active_common）。
## 刷出的丧尸会被强制锁定「最近玩家」并直接追击（无视视野/距离，直到防守战结束统一解锁）：
##   单人 = 锁定唯一玩家；联机 = 每个丧尸锁定离自己最近的玩家。
## 开局时机器附近的已存在丧尸（enemy_lock_radius 半径内）也会一并被锁定，立刻投入防守战。
@export_range(64.0, 3000.0, 16.0) var enemy_lock_radius: float = 640.0  ## 开局时，此半径内已存在的丧尸也会被强制锁定追击

# ═══════════════════════════════════════
# 配置 — 刷怪节奏（防守战专属，与普通尸潮参数分离）
# ═══════════════════════════════════════
## 防守战期间 EventManager 按这组参数分批刷怪，不再读取 SpawnManager 的
## horde_batch_size / horde_batch_interval —— 调尸潮不会影响防守战，反之亦然。
## 每台机器可单独配置：想要"开门红大波"就把首批调大，想要"持续小股"就缩短间隔减小批次。
@export_range(1, 50, 1) var spawn_per_wave: int = 4            ## 每批同时刷出几个丧尸
@export_range(0.5, 30.0, 0.5) var spawn_interval: float = 3.0  ## 两批之间的间隔（秒）。设短=连续涌出，设长=一波一波有节奏
@export_range(0, 500, 1) var max_active: int = 0               ## 防守战期间场上最大存活敌人。0 = 沿用全局 max_active_common

# ═══════════════════════════════════════
# 配置 — 音乐
# ═══════════════════════════════════════
@export_group("音乐")
@export var holdout_music: AudioStream                    ## 防守战期间播放的专属 BGM（留空=不播放）
@export_range(-80.0, 12.0, 0.5) var holdout_music_volume_db: float = 0.0
@export var holdout_music_loop: bool = true               ## 播完自动重头播（防守战时长通常大于曲长）
@export var stop_music_on_finish: bool = true             ## 防守战结束 / 中止时停止该 BGM

# ═══════════════════════════════════════
# 配置 — 音效（2026-09-13 用户需求）
# ═══════════════════════════════════════
@export_group("音效")
@export var prepare_sound: AudioStream                    ## 预备音效：PREPARE 阶段开始时播放（留空=不播）
@export var alert_sound: AudioStream                      ## 特殊预警音效：ACTIVE 正式开始时播放（留空=不播）

# ═══════════════════════════════════════
# 配置 — 终章 ED（战役最终防守战专用，2026-09-13）
# ═══════════════════════════════════════
@export_group("终章 ED")
## 开启后：防守完成 → 机器再次交互（文字=finished_interact_label）→ 功能键触发终章流程
## （播 ending_sound → 黑屏淡出 → 角色结局对话 → 战役总结 → 滚动名单 → 标题）。
@export var ending_enabled: bool = false
## 防守完成后的交互文字（如「进入列车」；留空 = 沿用 interact_label_done）
@export var finished_interact_label: String = ""
## 确认进入列车时播放的音效（与黑屏淡出同时；留空=不播）
@export var ending_sound: AudioStream
@export_range(0.5, 6.0, 0.1) var ending_fade_seconds: float = 1.5   ## 黑屏淡出时长（秒）
@export_file("*.tscn") var credits_scene_path: String = "res://scene/ui/credits.tscn"  ## 名单场景（流程终点）

# ═══════════════════════════════════════
# 配置 — 倒计时 UI
# ═══════════════════════════════════════
##
## 本节点**不再持有任何 UI 参数**。倒计时的位置、字号、颜色、背板等一律
## 在 scene/ui/combat_hud.tscn 的 HoldoutCountdown 节点树里直接编辑（编辑器里所见即所得）。
## 机器只负责在正确时机调用 CombatHud.show_holdout() / update_holdout() / hide_holdout()。

# ═══════════════════════════════════════
# 配置 — 完成事件：隐藏 / 显示节点
# ═══════════════════════════════════════
@export_group("完成事件 · 节点显隐")
@export var hide_node_paths: Array[NodePath] = []         ## 倒计时结束后隐藏这些节点（如挡路的门/墙）
@export var show_node_paths: Array[NodePath] = []         ## 倒计时结束后显示这些节点
@export var disable_collision_on_hidden: bool = true      ## 隐藏节点时同步禁用其碰撞体（否则看不见但还挡路）
@export var hide_self_on_complete: bool = false           ## 完成后隐藏机器自身

# ═══════════════════════════════════════
# 配置 — 完成事件：添加传送点
# ═══════════════════════════════════════
@export_group("完成事件 · 添加传送点")
## 防守战结束后动态生成的传送点，一个条目 = 一个传送点，可配置多个。
## 若只是「显示场景里已摆好但默认隐藏的传送点」，请用上面的 show_node_paths。
@export var teleport_points: Array[HoldoutTeleportConfig] = []

# ═══════════════════════════════════════
# 配置 — 完成事件：自定义回调
# ═══════════════════════════════════════
@export_group("完成事件 · 自定义回调")
@export var notify_node_paths: Array[NodePath] = []       ## 完成后对这些节点调用 notify_method
@export var notify_method: String = ""                    ## 无参方法名，例如 "open_gate"

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _started: bool = false          ## 是否已经启动过（配合 one_shot）
var _active: bool = false           ## 防守战是否进行中
var _completed: bool = false        ## 是否已完成
var _ending_started: bool = false   ## 终章 ED 流程是否已触发（终章配置时，完成后再交互 = 进 ED）
var _can_interact: bool = false
var _step_index: int = 0
var _step_timer: float = 0.0
## 阶段机运行时
var _phase: int = Phase.IDLE
var _phase_timer: float = 0.0
var _phase_total: float = 0.0
var _local_hud_shown: bool = false  ## 本机 CombatHUD 是否已 show_holdout（用于幂等，防止重复叠加）
var _net_token: int = 0             ## 联网权威令牌：标识一次防守战实例，用于丢弃旧场景残留包
var _music_player: AudioStreamPlayer = null  ## 防守战专属 BGM（懒创建，挂在机器下）
## KILL_COUNT 杀怪式运行时
var _kills: int = 0                 ## ACTIVE 期间已击杀敌人数
var _tree_hooked: bool = false      ## 是否已挂 SceneTree.node_added（补连新刷丧尸的死亡信号）


# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if event_name.is_empty():
		event_name = name if not name.is_empty() else "HoldoutMachine"
	if step_frames.is_empty():
		step_frames = [1]
	## 全灭冻结时由 Director 统一收尾（停 BGM / 停刷怪 / 解锁定）——见 Director._freeze_for_death。
	add_to_group("holdout_machine")

	_ensure_children()
	_refresh_sprite()
	_update_label()

	if Engine.is_editor_hint():
		# 编辑器预览：仅刷新行走图，不跑游戏逻辑（无 Players / Director）
		return

	_step_timer = step_duration

	# Boss BGM 优先（2026-09-14）：Boss 登场时防守战 BGM 挂起（stream_paused，
	# 不丢播放进度），Boss 全灭 Director 会广播 false → 恢复播放。
	var director: Node = get_node_or_null("/root/Director")
	if director and director.has_signal("boss_music_changed"):
		director.boss_music_changed.connect(_on_boss_music_changed)


func _on_boss_music_changed(active: bool) -> void:
	if _music_player and is_instance_valid(_music_player):
		_music_player.stream_paused = active
		print("[HoldoutMachine] 防守战 BGM %s（Boss BGM 优先）" % ("挂起" if active else "恢复"))


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		# 编辑器里持续根据导出项刷新行走图（贴图/角色索引/朝向/偏移变化即可见）
		_refresh_sprite()
		return

	# 踏步动画（静态机器也要继续跑距离检测，不能在这里 return）
	if animated and step_frames.size() > 1:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()

	_check_player_proximity()

	if _active:
		_tick_countdown(delta)
	elif _can_interact and auto_start_on_approach:
		trigger()

	if Global.debug_visuals:
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not _can_interact or _active or auto_start_on_approach:
		return
	if event.is_action_pressed("功能键"):
		get_viewport().set_input_as_handled()
		if _completed and _ending_pending():
			_start_ending()
		else:
			trigger()


## 终章 ED（用户 2026-09-13）：防守完成后再交互 →
## 播 ending_sound → 黑屏淡出 → 角色对话 → 战役总结 → 滚动名单 → 标题。
## 编排细节在 CampaignEnding（script/director/campaign_ending.gd）。
func _start_ending() -> void:
	if _ending_started:
		return
	_ending_started = true
	if _is_network_client():
		return
	var label: Label = get_node_or_null("HintLabel") as Label
	if label:
		label.hide()
	if ending_sound:
		Global.play_sfx_managed(ending_sound, get_tree().current_scene)
	var ending: CampaignEnding = CampaignEnding.new()
	ending.fade_seconds = ending_fade_seconds
	# 挂 root：本节点可能藏在"列车门"子树下，且后续场景切换会释放本节点
	get_tree().root.add_child(ending)
	ending.start()
	print("[HoldoutMachine] ★ 终章 ED 启动")


func _draw() -> void:
	if Engine.is_editor_hint():
		return
	if not Global.debug_visuals:
		return
	# 交互范围可视化（与项目其它调试绘制一致，仅调试开关打开时显示）
	var color: Color = Color(0.2, 1.0, 0.4, 0.75) if _can_interact else Color(1.0, 0.7, 0.2, 0.5)
	draw_arc(Vector2.ZERO, interact_range, 0.0, TAU, 48, color, 1.5)


# ═══════════════════════════════════════
# 子节点构建
# ═══════════════════════════════════════

func _ensure_children() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		sprite = Sprite2D.new()
		sprite.name = "Sprite2D"
		sprite.centered = true
		sprite.position = sprite_offset
		add_child(sprite)

	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.position = Vector2(-80, -66)
		label.size = Vector2(160, 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.32))
		## 阴影参数统一走 Global；本脚本是 @tool 且此处在编辑器也会执行，
		## 编辑器进程里没有 autoload，必须判空。
		var g: Node = get_node_or_null("/root/Global")
		if g:
			g.apply_hint_font(label, 12)  ## 字体统一（2026-09-17）：fusion-pixel + 12 整倍
			g.apply_text_shadow(label)
		label.hide()
		add_child(label)

	# ── 32×32 碰撞体：机器是实体，玩家/敌人不能穿过去 ──
	# 正常由 object/holdout_machine.tscn 预制体提供；这里是给旧实例的兜底，
	# 保证拖进地图的老机器也能自动补上碰撞。
	_ensure_collision()


## 确保存在 Collision(StaticBody2D) → Shape(CollisionShape2D，32×32 矩形)。
func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if not body:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)

	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if not shape_node:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)

	if not shape_node.shape:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(COLLISION_SIZE, COLLISION_SIZE)
		shape_node.shape = rect


func _refresh_sprite() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		return
	sprite.texture = walk_texture
	sprite.visible = walk_texture != null
	sprite.position = sprite_offset
	if not walk_texture:
		return

	sprite.region_enabled = true
	var frame_index: int = clampi(step_frames[_step_index % step_frames.size()], 0, 2)
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var x: int = char_col * FRAME_W * 3 + frame_index * FRAME_W
	var y: int = char_row * FRAME_H * DIRECTIONS + walk_direction * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


# ═══════════════════════════════════════
# 玩家检测
# ═══════════════════════════════════════

func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())


func _is_network_client() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	if not net or not net.has_method("is_online_session"):
		return false
	return bool(net.is_online_session()) and not bool(net.get("is_host"))


func _check_player_proximity() -> void:
	# 联机时提示只能基于本机操控的角色，不能因远端玩家靠近而在本机亮起
	var candidate: Node2D = Players.get_local_entity() if _is_online_session() else Players.nearest_entity_to(global_position)
	var reachable: bool = (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.global_position.distance_to(global_position) <= interact_range
	)
	# 终章配置下：防守完成后机器保持可交互（再次交互 = 触发 ED），不再被 one_shot 封死
	var blocked: bool = _completed and one_shot and not _ending_pending()
	_can_interact = reachable and not blocked
	_update_label()


func _ending_pending() -> bool:
	return ending_enabled and not _ending_started


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return

	if _active:
		label.text = interact_label_running
		label.visible = _can_interact and not interact_label_running.is_empty()
		return

	# 终章待触发：显示「进入列车」一类文字（用户 2026-09-13）
	if _completed and _ending_pending():
		var t: String = finished_interact_label if not finished_interact_label.is_empty() else interact_label_done
		if _is_network_client():
			label.text = "%s（需主机操作）" % t
		else:
			label.text = "%s  [D]" % t
		label.visible = _can_interact and not t.is_empty()
		return

	if _completed and one_shot:
		label.text = interact_label_done
		label.visible = _can_interact and not interact_label_done.is_empty()
		return

	if _is_network_client():
		label.text = "%s（需主机操作）" % interact_label
	elif auto_start_on_approach:
		label.text = interact_label
	else:
		label.text = "%s  [D]" % interact_label
	label.visible = _can_interact


# ═══════════════════════════════════════
# 启动 / 结束
# ═══════════════════════════════════════

## 手动启动防守战（也可由其它脚本/事件直接调用）。
## 仅单机或联机 Host 可执行；Client 靠近只提示需主机操作（避免 Client 本地倒计时与 Host 权威漂移）。
func trigger() -> void:
	if _active:
		return
	if _started and one_shot:
		return

	# 剧本事件与敌人生成都是 Host 权威，Client 本地启动只会造成不同步
	if _is_network_client():
		print("[HoldoutMachine] %s 联机 Client 不能自行启动防守战，需由主机操作" % event_name)
		return

	var director: Node = get_node_or_null("/root/Director")
	if not director:
		printerr("[HoldoutMachine] Director autoload 未找到，无法启动防守战")
		return
	if director.has_method("is_scripted_event_active") and director.is_scripted_event_active():
		print("[HoldoutMachine] 已有剧本事件进行中，%s 暂不启动" % event_name)
		return
	if not director.has_method("start_scripted_event"):
		printerr("[HoldoutMachine] Director 缺少 start_scripted_event 方法")
		return

	_started = true
	_active = true
	_completed = false
	_phase = Phase.PREPARE
	_phase_timer = prepare_duration
	_phase_total = prepare_duration
	_local_hud_shown = false
	# 本次防守战实例令牌：Client 用它校验收到的包是否来自当前场景的这场战斗，
	# 丢弃旧场景残留的过期 RPC，避免在新场景里弹出幽灵 HUD。
	_net_token = randi_range(1, 1000000)
	print("[HoldoutMachine] ★ 防守战启动: %s（%s | 准备 %.1fs → %s → 结算 %.1fs）" % [
		event_name, ["耐久型", "杀怪式", "永续型"][end_mode], prepare_duration,
		("进行 %.0fs" % holdout_duration) if end_mode == EndMode.TIMER else "无限时", settle_duration
	])

	# 准备阶段立即在本地显示 HUD（单机/Host），并通知所有 Client
	_drive_local_hud(Phase.PREPARE, _phase_timer, _phase_total)
	_broadcast_state(Phase.PREPARE, _phase_timer, _phase_total, true)
	# BGM 不在预备阶段播（用户 2026-09-13）：移到 _begin_active() 正式开始时。
	# 预备音效（用户 2026-09-13 新增）：预备倒计时开始时响一声。
	if prepare_sound:
		Global.play_sfx_managed(prepare_sound, get_tree().current_scene)
	_update_label()
	# 冻结常规导演编排（尸潮节奏/常规刷怪），防止尸潮 BGM 与防守战 BGM 叠加、
	# 尸潮刷怪/狂暴干扰防守战；防守战自身刷怪走 EventManager 剧本事件管线不受影响。
	if not _is_network_client() and director.has_method("set_director_suspended"):
		director.set_director_suspended(true)
	# 防守战期间丧尸与尸潮一样狂暴（存量切形态 + 新刷直接狂暴登场）。
	# 注意顺序：先挂起（其中若正处尸潮会先收尾解狂暴）再开防守战狂暴。
	if not _is_network_client() and director.has_method("set_holdout_rage"):
		director.set_holdout_rage(true)
	# 防守战 Tank 通道开启：重置首只延迟（防守战里 Tank 是核心压迫源，频率与常规不同）。
	if not _is_network_client() and director.has_method("notify_holdout_started"):
		director.notify_holdout_started()
	holdout_started.emit(event_name)


## 兼容旧接口：事件编排器完成回调。当前防守战由机器自身阶段机驱动，
## 正常流程不会由此触发；保留为安全入口，统一收敛到 _finish_holdout。
func on_event_completed() -> void:
	if not _active:
		return
	_finish_holdout()


## 外部完成入口（EXTERNAL 永续型专用，2026-09-15 原作坑道式：到达目标点即结束）。
## 由到达点 / 剧情事件 / 其它脚本调用；立即进入结算（开门/传送点等完成事件照常执行）。
func complete_external() -> void:
	if not _active or _phase != Phase.ACTIVE:
		return
	if end_mode != EndMode.EXTERNAL:
		print("[HoldoutMachine] %s 非 EXTERNAL 模式，忽略外部完成调用" % event_name)
		return
	print("[HoldoutMachine] 外部完成信号: %s（永续型防守结束）" % event_name)
	_begin_settle()


# ═══════════════════════════════════════
# 击杀计数（KILL_COUNT 杀怪式）
# ═══════════════════════════════════════

## 挂击杀钩子：ACTIVE 开始时的存量丧尸 + 之后新刷的（node_added 补连）都算。
## 对齐原作 147 语义：组1丧尸逐杀 +1（CE693），杀满 4 只开门。
func _connect_kill_hooks() -> void:
	_kills = 0
	for enemy: Node in get_tree().get_nodes_in_group("enemy"):
		_hook_enemy(enemy)
	if not _tree_hooked:
		get_tree().node_added.connect(_on_node_added)
		_tree_hooked = true


func _disconnect_kill_hooks() -> void:
	if _tree_hooked:
		if is_instance_valid(get_tree()):
			get_tree().node_added.disconnect(_on_node_added)
		_tree_hooked = false
	## 存活连接逐个摘除；已释放的（尸体被回收）会随对象自动断开
	if is_inside_tree():
		for enemy: Node in get_tree().get_nodes_in_group("enemy"):
			if enemy.has_signal("died") and enemy.is_connected("died", _on_enemy_died):
				enemy.died.disconnect(_on_enemy_died)


## node_added 时机早于敌人的 add_to_group("enemy")，所以这里按脚本比对过滤
func _on_node_added(node: Node) -> void:
	if _phase != Phase.ACTIVE or end_mode != EndMode.KILL_COUNT:
		return
	if node.get_script() == ENEMY_SCRIPT:
		_hook_enemy(node)


func _hook_enemy(enemy: Node) -> void:
	if enemy.has_signal("died") and not enemy.is_connected("died", _on_enemy_died):
		enemy.died.connect(_on_enemy_died)


func _on_enemy_died(_enemy: Node) -> void:
	if not _active or _phase != Phase.ACTIVE or end_mode != EndMode.KILL_COUNT:
		return
	## TANK 过滤：只计坦克/暴君级（tank_enemies 组），普通丧尸不计
	if kill_count_filter == KillFilter.TANK and not _enemy.is_in_group("tank_enemies"):
		return
	_kills += 1
	print("[HoldoutMachine] 击杀计数: %d / %d" % [_kills, kill_target])
	if _kills >= kill_target:
		_begin_settle()


## 提前中止防守战（外部条件触发或机器被移除时）。隐藏 HUD、解除敌人锁定并复位状态。
func abort() -> void:
	if not _active:
		return
	_active = false
	_phase = Phase.IDLE
	_disconnect_kill_hooks()
	var director: Node = get_node_or_null("/root/Director")
	if director and director.has_method("abort_scripted_event"):
		director.abort_scripted_event()
	if not _is_network_client() and director and director.has_method("set_director_suspended"):
		director.set_director_suspended(false)  ## 恢复常规导演编排
	if not _is_network_client() and director and director.has_method("set_holdout_rage"):
		director.set_holdout_rage(false)  ## 防守战丧尸恢复普通形态
	if not _is_network_client() and director and director.has_method("notify_holdout_finished"):
		director.notify_holdout_finished()  ## 防守战 Tank 通道收尾
	_drive_local_hud(Phase.IDLE, 0.0, 0.0)
	_broadcast_state(Phase.IDLE, 0.0, 0.0, true)
	_stop_holdout_music()
	_update_label()
	print("[HoldoutMachine] 防守战提前中止: %s" % event_name)


## 阶段机主循环：PREPARE → ACTIVE → SETTLE → IDLE。
## 每帧推进权威倒计时并下发；仅在 _active 时由 _process 调用。单机与联机 Host 走此路径。
## ACTIVE 的结束条件按 end_mode 分流（2026-09-15 原作三分类）：
##   TIMER      倒计时归零结算
##   KILL_COUNT 击杀数驱动（_on_enemy_died 里推进），无数字显示
##   EXTERNAL   外部驱动（complete_external()），无数字显示
func _tick_countdown(delta: float) -> void:
	match _phase:
		Phase.PREPARE:
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_begin_active()
		Phase.ACTIVE:
			if end_mode == EndMode.TIMER:
				_phase_timer -= delta
				if _phase_timer <= 0.0:
					_begin_settle()
			## KILL_COUNT / EXTERNAL：由击杀回调 / complete_external() 推进，这里不倒计时
		Phase.SETTLE:
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_finish_holdout()
				return
	if _phase == Phase.ACTIVE and end_mode != EndMode.TIMER:
		return  ## 杀怪式/永续型：ACTIVE 期间不下发数字（HUD 已收起，2026-09-15 用户定稿）
	var remaining := maxf(_phase_timer, 0.0)
	var total := _phase_total
	_drive_local_hud(_phase, remaining, total)
	_broadcast_state(_phase, remaining, total)


func _begin_active() -> void:
	_phase = Phase.ACTIVE
	_phase_timer = holdout_duration
	_phase_total = holdout_duration
	_kills = 0
	# BGM 从「正式开始」才播（2026-09-13 用户反馈：预备阶段不播）。
	# 原先在 _start_holdout（PREPARE）就播，导致倒计时 3 秒里 BGM 先响。
	_play_holdout_music()
	# 特殊预警音效（用户 2026-09-13 新增）：正式开始时响。
	if alert_sound:
		Global.play_sfx_managed(alert_sound, get_tree().current_scene)
	# 正式启动剧本事件：由 EventManager 按尸潮节奏刷怪（Host 权威）
	var director: Node = get_node_or_null("/root/Director")
	if director and director.has_method("start_scripted_event"):
		director.start_scripted_event(_build_config())
	# 杀怪式：挂击杀计数钩子（存量丧尸 + ACTIVE 期间新刷的都算，对齐原作组1计数语义）
	if end_mode == EndMode.KILL_COUNT:
		_connect_kill_hooks()
	# 杀怪式/永续型：ACTIVE 无计时数字可显（2026-09-15 用户定稿：不显示击杀数），
	# 收起倒计时面板（PREPARE 的 3-2-1 照常显示过）
	if end_mode != EndMode.TIMER:
		_drive_local_hud(Phase.ACTIVE, 0.0, 0.0)
		_broadcast_state(Phase.ACTIVE, 0.0, 0.0, true)


func _begin_settle() -> void:
	## 结算时长为 0（2026-09-15 默认）：跳过 SETTLE 展示直接完成，开门/传送点不再等几秒
	if settle_duration <= 0.0:
		_finish_holdout()
		return
	_phase = Phase.SETTLE
	_phase_timer = settle_duration
	_phase_total = settle_duration
	# 停止刷怪，恢复常规导演节奏（防守战刷出的丧尸本就是普通 AI，无需解锁）
	var director: Node = get_node_or_null("/root/Director")
	if director and director.has_method("abort_scripted_event"):
		director.abort_scripted_event()
	_broadcast_state(Phase.SETTLE, _phase_timer, _phase_total, true)


func _finish_holdout() -> void:
	_active = false
	_completed = true
	_phase = Phase.IDLE
	_local_hud_shown = false
	_disconnect_kill_hooks()
	_drive_local_hud(Phase.IDLE, 0.0, 0.0)
	_broadcast_state(Phase.IDLE, 0.0, 0.0, true)  # 通知所有 Client 隐藏 HUD
	_stop_holdout_music()
	_update_label()
	# 恢复常规导演编排（节奏/常规刷怪从喘息重新开始）——仅权威端，Client 的 Director 本就不跑生成
	if not _is_network_client():
		var director: Node = get_node_or_null("/root/Director")
		if director and director.has_method("set_director_suspended"):
			director.set_director_suspended(false)
		if director and director.has_method("set_holdout_rage"):
			director.set_holdout_rage(false)  ## 防守战丧尸恢复普通形态
		if director and director.has_method("notify_holdout_finished"):
			director.notify_holdout_finished()  ## 防守战 Tank 通道收尾
	# 完成事件（隐藏节点/传送点/回调）仅在权威端执行一次
	if not _is_network_client():
		_run_completion_events()
		holdout_finished.emit(event_name)
		_broadcast_completion()  # Client 也执行节点显隐（传送点仅 Host 创建）


func is_active() -> bool:
	return _active


func is_completed() -> bool:
	return _completed


func _build_config() -> Dictionary:
	## 复用 ScriptedEventTrigger 的 config 协议。
	## 不再传 trigger_node：防守战完成由机器自身阶段机驱动（_finish_holdout），
	## 避免与 EventManager 的完成回调重复触发。
	## 刷怪参数 = 本节点的「刷怪节奏（防守战专属）」参数组，与普通尸潮参数分离；
	## max_active = 0 时不传该字段，EventManager 回退到全局 SpawnManager.max_active_common。
	## target_lock = true：每批新刷出的丧尸锁定「最近玩家」并直接追击（无视视野）。
	## lock_nearby_at_start / center / radius：开局把机器附近已存在的丧尸也一并锁定，
	## 让"附近已刷出来的丧尸"在防守战一开始就扑向玩家。
	var cfg: Dictionary = {
		"event_name": event_name,
		"event_type": ScriptedEventTrigger.EventType.CRESCENDO,
		"event_duration": holdout_duration,
		"target_lock": true,
		"lock_nearby_at_start": true,
		"lock_nearby_center": global_position,
		"lock_nearby_radius": enemy_lock_radius,
		"spawn_per_wave": spawn_per_wave,
		"spawn_interval": spawn_interval,
	}
	## 杀怪式/永续型无时长上限：给 EventManager 一个足够大的刷怪时长，
	## 让刷怪持续到机器结算（_begin_settle 里 abort_scripted_event 收尾）为止
	if end_mode != EndMode.TIMER:
		cfg["event_duration"] = 3600.0
	if max_active > 0:
		cfg["max_active"] = max_active
	return cfg


# ═══════════════════════════════════════
# 倒计时 HUD（承载于地图内 CombatHUD）
# ═══════════════════════════════════════
#
# 设计：倒计时 UI 不再自建 CanvasLayer，而是复用关卡内已存在的 CombatHUD 节点
# （见 combat_hud.gd 末尾的「防守战倒计时」区块）。好处：
#   - 自动继承 CombatHUD 的 layer(10) 与生命周期：换图时随地图内 CombatHUD 一起释放，
#     不会残留悬空 UI 层（满足「不会残留或重复叠加」）。
#   - 与 HP/TP/武器图标同属一个 CanvasLayer，层级与排版天然兼容（满足布局兼容要求）。
#   - 单机：机器直接驱动本地 CombatHUD；联机：Host 机器计算权威值并经 NetworkWorld
#     可靠广播到所有 Client，Client 用同一份 combat_hud.tscn（场景导出值一致）驱动外观。
#     倒计时外观不经过网络传输，位置/字号/颜色/背板全在 combat_hud.tscn 里直接编辑。

## 把当前阶段/剩余时间应用到本机 CombatHUD。Host 与 Client 共用此入口，幂等可重入。
## 不再传任何外观配置：倒计时的位置/字号/颜色/背板一律以 combat_hud.tscn 里
## HoldoutCountdown 节点的编辑器设置为准，所见即所得。
func _drive_local_hud(phase: int, remaining: float, total: float) -> void:
	var hud: CombatHud = CombatHud.find_in_scene(self)
	if not hud:
		return
	if phase <= 0:
		hud.hide_holdout()
		_local_hud_shown = false
		return
	if not _local_hud_shown:
		hud.show_holdout()
		_local_hud_shown = true
	hud.update_holdout(phase, remaining, total)


## Client 收到 NetworkWorld 的权威包后调用，驱动本机 HUD。
## token 用于丢弃旧场景残留的过期包；-1 为「本场已结束」哨兵，忽略之后任何迟到/重放的旧包。
func apply_remote_holdout_state(phase: int, remaining: float, total: float, token: int) -> void:
	# 结束哨兵：本次防守战已结束。若收到的是「全新 token 的合法新防守战」则放行并清除哨兵；
	# 残留的旧 token 包（仅极端网络延迟下可能出现）会被忽略，避免幽灵 HUD。
	if _net_token == -1:
		if token != -1:
			_net_token = 0  # 新一场防守战，重置哨兵
		else:
			return
	if _net_token != 0 and token != _net_token:
		return  # 旧场景残留包，忽略
	_net_token = token
	if phase <= 0:
		_net_token = -1  # 结束哨兵：后续迟到包一律忽略，直到下一场 trigger 重置
	_drive_local_hud(phase, remaining, total)


## Client 收到防守战完成广播后执行本地完成事件（节点显隐等；传送点仅 Host 创建）。
func apply_remote_completion(token: int) -> void:
	if _net_token != 0 and token != _net_token:
		return
	_run_completion_events()


## 联网时把权威状态交给 NetworkWorld 广播；单机无 NetworkWorld 时为空操作，
## 本地 HUD 仍由 _drive_local_hud 直接驱动（现有单机行为不变）。
func _broadcast_state(phase: int, remaining: float, total: float, force: bool = false) -> void:
	var world: Node = _find_network_world()
	if world and world.has_method("broadcast_holdout_state"):
		world.broadcast_holdout_state(phase, remaining, total, _net_token, force)


func _broadcast_completion() -> void:
	var world: Node = _find_network_world()
	if world and world.has_method("broadcast_holdout_completed"):
		world.broadcast_holdout_completed(_net_token)


func _find_network_world() -> Node:
	var tree := get_tree()
	if not tree:
		return null
	var scene := tree.current_scene
	if not scene:
		return null
	return scene.find_child("NetworkWorld", true, false)


# ═══════════════════════════════════════
# 完成事件
# ═══════════════════════════════════════

func _run_completion_events() -> void:
	for path: NodePath in hide_node_paths:
		var node: Node = _resolve_node(path)
		if node:
			_set_node_shown(node, false)
			print("[HoldoutMachine] 完成事件：隐藏节点 %s" % node.name)
		elif not path.is_empty():
			push_warning("[HoldoutMachine] 完成事件找不到要隐藏的节点: %s" % path)

	for path: NodePath in show_node_paths:
		var node: Node = _resolve_node(path)
		if node:
			_set_node_shown(node, true)
			print("[HoldoutMachine] 完成事件：显示节点 %s" % node.name)
		elif not path.is_empty():
			push_warning("[HoldoutMachine] 完成事件找不到要显示的节点: %s" % path)

	# 传送点仅在权威端（单机或 Host）创建；Client 没有节点复制框架，
	# 若也创建会产生重复实例，因此客户端跳过（节点显隐/回调仍会在 Client 上同步执行）。
	if not teleport_points.is_empty() and not _is_network_client():
		_create_teleport_points()

	if not notify_method.is_empty():
		for path: NodePath in notify_node_paths:
			var node: Node = _resolve_node(path)
			if node and node.has_method(notify_method):
				node.call(notify_method)
				print("[HoldoutMachine] 完成事件：调用 %s.%s()" % [node.name, notify_method])
			elif node:
				push_warning("[HoldoutMachine] 节点 %s 没有方法 %s" % [node.name, notify_method])

	if hide_self_on_complete:
		_set_node_shown(self, false)


## 三级解析，尽量让 Inspector 里填的路径都能命中：
##   1) 相对本机器（如 "../大门"）
##   2) 相对场景根（如 "GroundLayer/大门"）
##   3) 兜底：取路径最后一段当节点名，在整棵场景树里递归查找
##      —— 兼容"在预制体上填了路径、实例化后路径失效"或只填了节点名的情况。
func _resolve_node(path: NodePath) -> Node:
	if path.is_empty():
		return null

	var node: Node = get_node_or_null(path)
	if node:
		return node

	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene:
		node = scene.get_node_or_null(path)
		if node:
			return node

	var leaf := _leaf_node_name(String(path))
	if leaf.is_empty():
		return null
	if scene:
		node = scene.find_child(leaf, true, false)
		if node:
			return node
	# 当前场景里没有（例如路径指向的是机器自身所在分支之外），再退回机器子树
	return find_child(leaf, true, false)


## 取 NodePath 的最后一段作为节点名："../GroundLayer/大门" → "大门"
func _leaf_node_name(raw_path: String) -> String:
	var parts: PackedStringArray = raw_path.split("/", false)
	return parts[parts.size() - 1] if not parts.is_empty() else ""


func _set_node_shown(node: Node, shown: bool) -> void:
	if node is CanvasItem:
		(node as CanvasItem).visible = shown
	elif node.has_method("set_visible"):
		node.call("set_visible", shown)
	else:
		# 根节点不是 CanvasItem（如 Node2D/StaticBody2D 包装层）时，显隐其子级画布项，
		# 否则"隐藏节点"后子精灵仍然可见（用户 2026-09-11 反馈的"改隐藏的节点还是没隐藏"）
		for child: Node in node.get_children():
			if child is CanvasItem:
				(child as CanvasItem).visible = shown

	if not disable_collision_on_hidden:
		return
	# 隐藏时同步关掉碰撞，否则「看不见但还挡路」
	_set_collision_enabled(node, shown)


## 递归开关碰撞。只动真正决定"挡不挡路"的属性：
## CollisionShape2D.disabled 与 TileMapLayer.collision_enabled。
## 刻意不改 process_mode / collision_layer —— 前者会把节点连脚本一起冻住，
## 后者需要额外保存原值才能还原，都不适合做通用完成事件。
func _set_collision_enabled(node: Node, enabled: bool) -> void:
	if node is CollisionShape2D:
		(node as CollisionShape2D).set_deferred("disabled", not enabled)
	elif node is CollisionPolygon2D:
		(node as CollisionPolygon2D).set_deferred("disabled", not enabled)
	elif node is TileMapLayer:
		(node as TileMapLayer).set_deferred("collision_enabled", enabled)
	for child: Node in node.get_children():
		_set_collision_enabled(child, enabled)


## 按 teleport_points 数组逐条生成传送点（一个条目 = 一个传送点）。
## 任一条目配置不全只跳过该条并告警，不影响其它条目。
func _create_teleport_points() -> void:
	for i: int in teleport_points.size():
		var cfg: HoldoutTeleportConfig = teleport_points[i]
		if not cfg or not cfg.enabled:
			continue
		_create_one_teleport_point(cfg, i)


func _create_one_teleport_point(cfg: HoldoutTeleportConfig, index: int) -> void:
	if cfg.target_scene.is_empty():
		push_warning("[HoldoutMachine] teleport_points[%d] 未设置 target_scene，跳过" % index)
		return
	if not ResourceLoader.exists(cfg.target_scene):
		printerr("[HoldoutMachine] teleport_points[%d] 传送目标场景不存在: %s" % [index, cfg.target_scene])
		return

	var tp: TeleportPoint = TELEPORT_POINT_SCRIPT.new()
	tp.name = "%s_TeleportPoint%d" % [event_name, index]
	tp.target_scene = cfg.target_scene
	tp.target_arrival_id = cfg.target_arrival_id
	tp.use_target_arrival_position = cfg.use_target_arrival_position
	tp.target_arrival_position = cfg.target_arrival_position
	tp.walk_texture = cfg.walk_texture if cfg.walk_texture else walk_texture
	tp.walk_char_index = cfg.walk_char_index
	tp.walk_direction = cfg.walk_direction
	tp.interact_label = cfg.interact_label
	tp.interact_range = cfg.interact_range
	tp.capture_checkpoint = cfg.capture_checkpoint
	tp.animated = cfg.animated

	# 位置：优先用 marker 节点，其次用相对机器的偏移
	var marker: Node = _resolve_node(cfg.marker_path)
	var spawn_pos: Vector2 = global_position + cfg.offset
	if marker and marker is Node2D:
		spawn_pos = (marker as Node2D).global_position

	# 与机器同父级 → 继承同一图层的 z 排序
	var parent: Node = get_parent()
	if not parent:
		parent = get_tree().current_scene
	parent.add_child(tp)
	tp.global_position = spawn_pos
	# start_hidden 必须在 add_child 之后设置，否则会被 _ready 之后的状态覆盖
	if cfg.start_hidden:
		tp.visible = false
	print("[HoldoutMachine] 完成事件：已添加传送点[%d] → %s @ (%d, %d)%s" % [
		index, cfg.target_scene, int(spawn_pos.x), int(spawn_pos.y),
		"（初始隐藏）" if cfg.start_hidden else ""
	])


# ═══════════════════════════════════════
# 音乐
# ═══════════════════════════════════════

## 防守战开始时播放专属 BGM。与 safehouse_arrival_music / chapter_summary 同款做法：
## 懒建一个 AudioStreamPlayer 挂在本机下，走 "Music" 总线（音量受游戏内音乐音量控制）。
func _play_holdout_music() -> void:
	if not holdout_music:
		return
	if not _music_player:
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "HoldoutMusicPlayer"
		_music_player.bus = &"Music"
		add_child(_music_player)
		# 曲子播完自动重头播：防守战时长通常大于单曲长度
		if holdout_music_loop:
			_music_player.finished.connect(_on_holdout_music_finished)
	_music_player.stop()
	_music_player.stream = holdout_music
	_music_player.volume_db = holdout_music_volume_db
	_music_player.play()


func _on_holdout_music_finished() -> void:
	# 只有防守战仍在进行（或刚结束但允许续播）时才重播；结束时会先 stop()，
	# 这里再判断一次避免在结算/结束后又把它拉起来。
	if _music_player and _music_player.playing:
		return
	if _active and _music_player:
		_music_player.play()


## 防守战结束 / 中止时停止专属 BGM。
func _stop_holdout_music() -> void:
	if not stop_music_on_finish:
		return
	if _music_player and (_music_player.playing or _music_player.stream):
		_music_player.stop()
		print("[HoldoutMachine] 防守战 BGM 已停止")


func _exit_tree() -> void:
	# 防守战进行中机器被移除（如切图/卸载）：主动中止并隐藏本机 HUD，
	# 避免倒计时 UI 残留在已释放的 CombatHUD 之外或重复叠加。
	if _active:
		abort()
	_stop_holdout_music()
