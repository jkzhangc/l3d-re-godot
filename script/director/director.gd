extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：单例（autoload: Director）
## 联机：仅单机/Host 运行
## 职责：导演总控 autoload：评估紧张度、驱动节奏阶段，并调用生成/物品/事件子系统；Client 不自行刷怪。
## 依赖：IntensityTracker、PacingController、SpawnManager、ItemManager、EventManager

## 导演系统 Autoload — 全局总控
##
## 负责：紧张度评估、敌人生成、物品投放决策、事件编排
##
## Director 只在单机或联机 Host 运行；联机 Client 不自行刷怪或投放物品，只接收同步结果。
## IntensityTracker/PacingController 决定节奏，SpawnManager/EventManager/ItemManager 执行子系统动作。
# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal intensity_changed(value: float)
signal pacing_phase_changed(phase: String)
signal horde_incoming()
signal horde_started()
signal horde_ended()
signal special_spawned(type: String)
signal tank_spawned(type: String)
signal item_spawn_requested(zone: Vector2)
signal scripted_event_triggered(event: String)
# ═══════════════════════════════════════
# 参数
# ═══════════════════════════════════════
const ENEMY_SCENE_PATH = "res://object/enemy.tscn"
const DEBUG_SPAWN_COUNT = 5
## 内置默认僵尸池（关卡 DirectorConfig.zombie_pool 留空时使用）。
## 按关卡定制：把 tres/zombies/ 下的变体拖进关卡 DirectorConfig 的 zombie_pool。
const DEFAULT_ZOMBIE_POOL: Array = [
	preload("res://tres/zombies/男性ゾンビ.tres"),
	preload("res://tres/zombies/女性ゾンビ.tres"),
	preload("res://tres/zombies/学生ゾンビ.tres"),
]
## 内置默认 Tank（タイラント T-002）。DirectorConfig.tank_data 留空时使用。
## weight 为 0（不入特感池），只由 Tank 编排 / BossEncounter 组件显式生成。
const DEFAULT_TANK_PATH := "res://tres/specials/タイラントT002.tres"
## 当地图里的作者生成点都离当前小队太远时，改为在玩家外围寻找可行走位置。
## 这不是缩短 spawn_min_dist：仍会保持至少该距离，避免敌人直接刷在脸上。
const PREFERRED_SPAWN_MAX_DISTANCE := 900.0

@export var spawn_min_dist: float = 400.0       ## 生成点距玩家最小距离（px）
@export var spawn_map_keywords: Array[String] = []  ## 允许生成的地图名关键字（空=全部允许）
@export var safe_room_keywords: Array[String] = ["安全屋", "safe"]  ## 安全屋地图名关键字
@export var allow_manual_spawn: bool = true
@export var auto_spawn_enabled: bool = true      ## 总开关：是否启用自动生成

# ── 回收（离玩家太远的敌人清除）——由 DirectorConfig 注入 ──
var recycle_enabled: bool = true
var recycle_interval: float = 1.0
var recycle_dist: float = 1400.0
var recycle_clear_corpses: bool = true
var _zombie_pool: Array = []          ## ZombieVariant 池（_apply_config 注入；空则用默认池）
var _horde_rage: bool = false         ## 尸潮（peak 阶段）期间 = true，僵尸切换クリムゾンヘッド形态
var _horde_locked_enemies: Array[Node2D] = []  ## 尸潮期间被锁定"直接追击最近玩家"的丧尸（peak 结束统一解锁）
var _recycle_timer: float = 0.0
var _recycle_cleared: int = 0     ## 累计清除的存活敌人数（诊断 / 现场报告用）
var _recycle_corpses: int = 0     ## 累计清除的尸体数

# ── 特感（SpecialEnemyData：ハンター 等）——由 DirectorConfig 注入 ──
## 与普通僵尸池分开的低频高压编排：紧张度门槛 + 随机冷却 + 同屏互斥。
## 尸潮（peak）期间计时冻结——特感不与尸潮叠加施压。
var _special_pool: Array = []             ## SpecialEnemyData 池（_apply_config 注入；空=不刷）
var special_max_alive: int = 1            ## 同屏最多存活特感数（互斥）
var special_intensity_threshold: float = 0.35
var special_cooldown_min: float = 50.0
var special_cooldown_max: float = 90.0
var _special_first_delay_left: float = 0.0  ## 第一只特感的登场倒计时（秒）
var _special_cooldown_left: float = 0.0     ## 特感冷却倒计时（秒）

# ── Boss / Tank（タイラント T-002）——由 DirectorConfig 注入 ──
## 与特感分开的第二档编排：更低频、更高压、门槛更高。常规与防守战各有独立频率
## （原作：ステージ中は逃げられることもある＝常规可选遭遇；147 图防守战里是核心压迫源）。
var tank_enabled: bool = false
var _tank_data: SpecialEnemyData = null
var tank_cooldown_min: float = 180.0
var tank_cooldown_max: float = 300.0
var tank_max_alive: int = 1
var tank_intensity_threshold: float = 0.6
var holdout_tank_enabled: bool = true
var _holdout_tank_data: SpecialEnemyData = null
var holdout_tank_first_delay: float = 25.0
var holdout_tank_cooldown_min: float = 45.0
var holdout_tank_cooldown_max: float = 75.0
var holdout_tank_max_alive: int = 1
var _tank_cooldown_left: float = 0.0        ## 常规 Tank 冷却
var _holdout_tank_first_left: float = 0.0   ## 防守战首只 Tank 延迟
var _holdout_tank_cooldown_left: float = 0.0 ## 防守战 Tank 冷却

# ═══════════════════════════════════════
# 子模块
# ═══════════════════════════════════════
var intensity_tracker: Node = null
var _enemy_scene: PackedScene = null
var _spawn_history: Array = []
var _last_scene: Node = null  ## 检测场景切换，读取 DirectorConfig
var current_config: DirectorConfig = null  ## 当前关卡的配置节点（ItemManager 读掉落池等用）

const NIGHT_DEBUG_DEFAULT_DARKNESS := 0.8  ## F8 调试开夜时，若本图未配 night_darkness 用的默认浓度


## F8 = 夜间视界调试开关（2026-09-16 测试用，不写进地图数据）：
## 当前图无 NightOverlay → 开夜（浓度取本图 night_darkness，未配则用 0.8）；
## 已有 → 关掉恢复白天。换图后按 DirectorConfig 重新生效。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		_toggle_night_debug()


func _toggle_night_debug() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if NightOverlay.find_in_scene(scene):
		NightOverlay.apply_darkness(scene, 0.0)
		print("[Director] F8 夜幕关闭（调试）")
	else:
		var d: float = current_config.night_darkness if current_config else 0.0
		if d <= 0.0:
			d = NIGHT_DEBUG_DEFAULT_DARKNESS
		NightOverlay.apply_darkness(scene, d)
		print("[Director] F8 夜幕开启 darkness=%.2f（调试）" % d)

# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	var it_script = load("res://script/director/intensity_tracker.gd")
	intensity_tracker = Node.new()
	intensity_tracker.name = "IntensityTracker"
	intensity_tracker.set_script(it_script)
	add_child(intensity_tracker)

	# ── PacingController ──
	var pc_script = load("res://script/director/pacing_controller.gd")
	var pc := Node.new()
	pc.name = "PacingController"
	pc.set_script(pc_script)
	add_child(pc)

	# ── SpawnManager ──
	var sm_script = load("res://script/director/spawn_manager.gd")
	var sm := Node.new()
	sm.name = "SpawnManager"
	sm.set_script(sm_script)
	add_child(sm)
	if sm.has_method("setup"):
		sm.setup(self)

	# ── FrontSpawner（前方屏外定点刷怪）──
	# 负责"玩家前方、屏幕外的固定数量补位"：取代旧的全图随机撒点回退。
	var fs_script = load("res://script/director/front_spawner.gd")
	var fs: Node = Node.new()
	fs.name = "FrontSpawner"
	fs.set_script(fs_script)
	add_child(fs)
	if fs.has_method("setup"):
		fs.setup(self)

	# ── EventManager ──
	var em_script = load("res://script/director/event_manager.gd")
	var em := Node.new()
	em.name = "EventManager"
	em.set_script(em_script)
	add_child(em)
	if em.has_method("setup"):
		em.setup(self)

	# ── ItemManager ──
	var im_script = load("res://script/director/item_manager.gd")
	var im := Node.new()
	im.name = "ItemManager"
	im.set_script(im_script)
	add_child(im)
	if im.has_method("setup"):
		im.setup(self)

	if pc.has_signal("phase_changed"):
		pc.phase_changed.connect(_on_phase_changed)

	if ResourceLoader.exists(ENEMY_SCENE_PATH):
		_enemy_scene = load(ENEMY_SCENE_PATH) as PackedScene
	else:
		printerr("[Director] enemy scene not found: %s" % ENEMY_SCENE_PATH)

	if intensity_tracker and intensity_tracker.has_method("set_progress"):
		intensity_tracker.set_progress(0.3)

	print("[Director] initialized (Phase 3)")


func _process(delta: float) -> void:
	# 联机采用 Host 权威：Host 继续运行导演并生成实体，Client 只接收 NetworkWorld 快照。
	if _is_network_client_session():
		return
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return
	# ── 全灭冻结（2026-09-12）：全员死亡/濒死 → 收尾尸潮并挂起，直到场景重载 ──
	# 此前仅"跳过濒死玩家"，已进入 peak 的尸潮没人收尾：PacingController 停在 peak、
	# _horde_rage/目标锁定跨场景残留、尸潮 BGM（挂在 autoload 下）不随重载消失 ——
	# 表现为"死亡后尸潮还在继续、死亡音乐和尸潮 BGM 同时响"。
	if _are_all_players_dead():
		if not _frozen_by_death:
			_freeze_for_death()
		return
	_frozen_by_death = false
	# 跳过濒死/死亡玩家（死亡动画播放中或场景重载中）；仍有队友存活时导演照常运行
	if player.get("_is_dying") == true:
		return

	_check_scene_change()

	# Boss BGM 收尾（2026-09-15）：坦克全灭即停 —— 此前 _update_boss_music 定义了但
	# 从未被调用，坦克死后 BGM 一直播（盖住死亡音效、后续复活/防守阶段也还在响）。
	# 放在挂起闸门之前：防守战期间（director_suspended）打死的坦克也要正确收音。
	_update_boss_music()

	# ── spawn_enabled=false / 安全屋黑名单：只关「常规刷怪编排」──
	# （2026-09-13 列车台回归：此前整段 _process 早退，把防守战刷怪的驱动源
	#   EventManager、回收、紧张度一起带走——开场静默图 + 防守战刷怪互斥）
	# 关掉的：AmbientZone 补齐、Pacing（尸潮节奏）、SpawnManager、FrontSpawner、
	#         特感通道、常规 Tank 通道。
	# 照常的：紧张度、回收、EventManager（剧本事件=防守战刷怪本体）、ItemManager、
	#         防守战专属 Tank 通道（director_suspended 期间）。
	var spawn_map: bool = _is_spawn_map()

	# ── 防守战挂起期间（HoldoutMachine）：常规编排冻结 ──
	# EventManager 继续每帧驱动（防守战刷怪本身走剧本事件管线），回收/紧张度照常；
	# 冻结的是：AmbientZone 补齐、Pacing 阶段推进（尸潮触发源）、SpawnManager、FrontSpawner。
	# ItemManager 保持运行（补给投放对防守战有益无害）。
	if not director_suspended and spawn_map:
		# ── 仅在 SpawnZone 区域内补齐，禁用画面外刷怪，以防“某地满、某地空” ──
		_update_ambient_zones(delta, player)

	# ── 紧张度 ──
	var prev_intensity: float = get_intensity()
	var new_intensity: float = prev_intensity
	if intensity_tracker and intensity_tracker.has_method("evaluate"):
		new_intensity = intensity_tracker.evaluate(player, delta)
		_update_combat_state(player)
		if abs(new_intensity - prev_intensity) > 0.05:
			intensity_changed.emit(new_intensity)

	# ── 回收（离玩家太远的敌人直接清除）──
	# 必须先于存活计数：清掉远处敌人之后，本帧所有生成闸门看到的才是真实余量。
	_update_recycle(delta, player)

	# ── 存活敌人计数 ──
	var alive_count: int = _count_alive_enemies()

	# ── 节奏控制 ──
	# spawn_map=false 时 Pacing 冻结（无尸潮节奏；phase 维持初值供 EventManager 读取）
	var pc: Node = get_node_or_null("PacingController")
	if pc and pc.has_method("update") and spawn_map:
		pc.update(delta, new_intensity, alive_count)
	var current_phase: StringName = &"cooldown"
	if pc:
		match pc.current_phase:
			0: current_phase = &"build"
			1: current_phase = &"peak"
			_: current_phase = &"cooldown"

	# ── 事件编排（先于生成调度，剧本事件期间会禁用 SpawnManager）──
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("update"):
		em.update(delta, new_intensity, current_phase, alive_count)

	# ── 敌人生成调度 / 前方屏外补位：防守战挂起期间或 spawn_map=false 时冻结 ──
	if not director_suspended and spawn_map:
		var sm: Node = get_node_or_null("SpawnManager")
		if sm and sm.has_method("update"):
			sm.update(delta, new_intensity, alive_count)

		var fs: Node = get_node_or_null("FrontSpawner")
		if fs and fs.has_method("update"):
			fs.update(delta, player, alive_count, current_phase)

		# ── 特感编排：与常规刷怪同一闸门（防守战挂起期间冻结）──
		_update_specials(delta, player, current_phase)

	# ── Tank 编排 ──
	# 防守战期间（director_suspended）常规 Tank 冻结，但防守战专属 Tank 照常
	# （原作 147 图：Tank 是防守战核心压迫源，不能因为挂起导演就一起停掉）。
	# spawn_map=false 时常规 Tank 也停（列车台：开场静默，防守战才上 T-002）。
	_update_tanks(delta, player, current_phase, spawn_map)

	# ── 物品投放 ──
	var im: Node = get_node_or_null("ItemManager")
	if im and im.has_method("update"):
		im.update(delta, current_phase, alive_count)


# ═══════════════════════════════════════
# 全灭冻结（死亡收尾）
# ═══════════════════════════════════════

var _frozen_by_death: bool = false  ## 全员死亡触发的冻结标志（场景重载、玩家复活后自动解除）

func _are_all_players_dead() -> bool:
	## 全部玩家实体都处于死亡/濒死状态（单机=唯一玩家死亡；联机=Host 上全灭）。
	## 实体列表为空（菜单/场景切换瞬间）不算全灭。
	var entities: Array[Node2D] = Players.all_entities()
	if entities.is_empty():
		return false
	for e: Node2D in entities:
		if is_instance_valid(e) and e.get("_is_dying") != true and e.get("_is_dead") != true:
			return false
	return true

func _freeze_for_death() -> void:
	## 一次性收尾：peak 强制回 cooldown（解除狂暴/目标锁定/停尸潮 BGM）+ 中止剧本事件与防守战。
	## 之后每帧提前 return（黑屏-重载期间保持挂起）；重载后玩家复活，状态自然复位。
	_frozen_by_death = true
	var pc: Node = get_node_or_null("PacingController")
	if pc and pc.get("current_phase") == 1:  # 1 = Phase.PEAK（与 set_director_suspended 同判定）
		pc.force_cooldown()
	_stop_horde_music()
	## Boss BGM 一并收（2026-09-16 用户反馈「死亡后尸潮/Boss 音乐还在响」）：
	## 冻结后 _process 每帧早退，_update_boss_music 再也不会被调用 → 必须在这里显式停。
	stop_boss_music(false)
	## 防守战（HoldoutMachine）也必须中止：它自带的 holdout_music 挂在机器节点下，
	## 不归导演管；此前只 abort_scripted_event（EventManager），机器照常倒数+刷怪+放 BGM
	## → 黑屏期间音乐不断、复活后场面还在打（2026-09-16 修复）。
	for machine: Node in get_tree().get_nodes_in_group("holdout_machine"):
		if machine.has_method("abort"):
			machine.call("abort")
	abort_scripted_event()
	print("[Director] 全员死亡：导演冻结（尸潮/Boss/防守战 BGM 停止、剧本事件中止）")


func _on_phase_changed(phase: StringName) -> void:
	## 节奏阶段切换 → 通知 SpawnManager + 发出信号
	print("[Director] pacing phase → %s" % phase)
	pacing_phase_changed.emit(phase)

	var sm: Node = get_node_or_null("SpawnManager")
	if sm and sm.has_method("on_phase_changed"):
		sm.on_phase_changed(phase)

	if phase == &"peak":
		_horde_rage = true
		_set_all_enemies_rage(true)   ## 尸潮触发 → 僵尸切换クリムゾンヘッド（狂暴）
		_lock_all_enemies_for_horde() ## 尸潮触发 → 附近全部丧尸直接追击最近玩家（对齐防守战）
		_play_horde_music()
		horde_started.emit()
	elif phase == &"cooldown":
		_horde_rage = false
		_set_all_enemies_rage(false)  ## 尸潮结束 → 恢复普通形态
		_release_horde_locks()        ## 尸潮结束 → 解除目标锁定，恢复普通 AI
		_stop_horde_music()
		horde_ended.emit()


## ── 尸潮 BGM（DirectorConfig「音乐 — 尸潮」组；默认 = 原作ラッシュ１）──
var _horde_music_player: AudioStreamPlayer = null

func _play_horde_music() -> void:
	var stream: AudioStream = current_config.horde_music if current_config else null
	if not stream:
		return
	if _boss_music_active:
		return  ## Boss BGM 优先级更高：Boss 存活期间尸潮不抢 BGM（Boss 灭后自动接回）
	if not _horde_music_player:
		_horde_music_player = AudioStreamPlayer.new()
		_horde_music_player.name = "HordeMusicPlayer"
		_horde_music_player.bus = &"Music"
		add_child(_horde_music_player)
	_horde_music_player.stop()
	_horde_music_player.stream = stream
	_horde_music_player.volume_db = current_config.horde_music_volume_db if current_config else 0.0
	_horde_music_player.play()
	print("[Director] 尸潮 BGM 开始")

func _stop_horde_music() -> void:
	if _horde_music_player and _horde_music_player.playing:
		_horde_music_player.stop()
		print("[Director] 尸潮 BGM 停止")


## ── Boss BGM（DirectorConfig「音乐 — Boss」组；2026-09-14 用户定稿）──
## 优先级最高：Boss（tank_enemies 成员 / BossEncounter 定点遭遇）登场时
## 立即停尸潮 BGM 改播 Boss BGM；Boss 全灭自动停止，若尸潮仍在 peak 则接回尸潮 BGM。
## 防守战 BGM 不停播而是 stream_paused 挂起（HoldoutMachine 监听 boss_music_changed）。
signal boss_music_changed(active: bool)

var _boss_music_player: AudioStreamPlayer = null
var _boss_music_active: bool = false
## 需要由本模块监视存活的 Boss 实体（含未入 tank_enemies 组的 BossEncounter 生成物）。
var _boss_music_watchlist: Array[Node2D] = []

## Boss 登场时调用（_spawn_tank / BossEncounter.trigger）。
## watch = 要监视存活的 Boss 实体；已激活时刷新监视列表但不重播（多 Boss 连场不切歌）。
func play_boss_music(watch: Node2D = null) -> void:
	var stream: AudioStream = current_config.boss_music if current_config else null
	if stream == null:
		return
	if watch and is_instance_valid(watch) and not _boss_music_watchlist.has(watch):
		_boss_music_watchlist.append(watch)
	if _boss_music_active and _boss_music_player and _boss_music_player.playing:
		return  ## 已在播（可能正压着另一只 Boss），不重头
	if not _boss_music_player:
		_boss_music_player = AudioStreamPlayer.new()
		_boss_music_player.name = "BossMusicPlayer"
		_boss_music_player.bus = &"Music"
		add_child(_boss_music_player)
	_stop_horde_music()
	_boss_music_player.stop()
	_boss_music_player.stream = stream
	_boss_music_player.volume_db = current_config.boss_music_volume_db if current_config else 0.0
	_boss_music_player.play()
	_boss_music_active = true
	boss_music_changed.emit(true)
	print("[Director] ★ Boss BGM 开始")

## Boss 全灭 / 全员死亡冻结时调用。resume_horde=true 且尸潮仍在 peak 时接回尸潮 BGM。
func stop_boss_music(resume_horde: bool = false) -> void:
	if not _boss_music_active:
		return
	_boss_music_active = false
	_boss_music_watchlist.clear()
	if _boss_music_player:
		_boss_music_player.stop()
	boss_music_changed.emit(false)
	print("[Director] Boss BGM 停止")
	if resume_horde:
		var pc: Node = get_node_or_null("PacingController")
		if pc and pc.get("current_phase") == 1:  # 1 = peak
			_play_horde_music()

## 每帧调用：Boss 全灭（tank 组空 + 监视列表全灭）→ 收 Boss BGM。
func _update_boss_music() -> void:
	if not _boss_music_active:
		return
	if _count_alive_tanks() > 0:
		return
	_boss_music_watchlist = _boss_music_watchlist.filter(func(e: Node2D) -> bool:
		return is_instance_valid(e) and e.get("_is_dead") != true and e.get("_is_dying") != true)
	if not _boss_music_watchlist.is_empty():
		return
	stop_boss_music(true)


## 尸潮（peak）开始：全部存活丧尸锁定最近玩家、无视视野直接追击（用户 2026-09-11，
## 行为对齐防守战 HoldoutMachine 的 target_lock）。
## "附近"由回收机制兜底：离玩家 > recycle_dist 的敌人 1s 内就会被清掉，
## 场上存活的本来就是附近那批，因此直接锁全量即可。
func _lock_all_enemies_for_horde() -> void:
	var locked: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		if e.get("recycle_exempt") == true:
			continue
		# 已被其他系统锁定（如防守战）的不重复接管
		if e.has_method("has_forced_target") and e.has_forced_target():
			continue
		if not e.has_method("lock_forced_target"):
			continue
		e.lock_forced_target(Players.nearest_entity_to(e.global_position))
		_horde_locked_enemies.append(e)
		locked += 1
	if locked > 0:
		print("[Director] 尸潮：已锁定 %d 只丧尸直接追击最近玩家" % locked)


## 尸潮结束：解除本次尸潮锁定的全部丧尸，恢复普通 AI（视野发现 → 追击）。
## 防守战（剧本事件）锁定的不在本列表内，互不干扰。
func _release_horde_locks() -> void:
	var released: int = 0
	for e: Node2D in _horde_locked_enemies:
		if is_instance_valid(e) and e.has_method("release_forced_target"):
			e.release_forced_target()
			released += 1
	_horde_locked_enemies.clear()
	if released > 0:
		print("[Director] 尸潮结束：解除 %d 只丧尸的目标锁定" % released)


func _input(event: InputEvent) -> void:
	# F2 调试生成也必须只在 Host / 单机执行，避免 Client 本地生成未同步实体。
	if _is_network_client_session() or not allow_manual_spawn:
		return
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_F2:
		_debug_spawn()


func _is_network_client_session() -> bool:
	# 用节点路径而非 Autoload 标识符，兼容编辑器脚本热重载期间的全局类刷新时序。
	var net: Node = get_node_or_null("/root/Net")
	return net != null \
		and net.has_method("is_online_session") \
		and net.is_online_session() \
		and not bool(net.get("is_host"))


# ═══════════════════════════════════════
# 剧本事件 API
# ═══════════════════════════════════════

## ── 防守战挂起（2026-09-12）──
## HoldoutMachine 存续期间冻结常规编排：节奏阶段推进（尸潮触发源）、SpawnManager、
## FrontSpawner、AmbientZone。EventManager 不冻结（防守战刷怪本身走剧本事件管线），
## 回收/紧张度/物品投放照常。用计数器支持多机器并存（挂起/恢复必须配对调用）。
var director_suspended: bool = false
var _suspend_count: int = 0

func set_director_suspended(suspended: bool) -> void:
	_suspend_count = maxi(0, _suspend_count + (1 if suspended else -1))
	var should_suspend: bool = _suspend_count > 0
	## 尸潮收尾必须在幂等早退之前执行：若上一场防守战残留了挂起计数
	## （如防守战中玩家死亡/切图，机器没走 finish/abort），本次 trigger 的
	## 「挂起瞬间正处尸潮」清理会被 early-return 跳过 → 尸潮 BGM 停不下来。
	if suspended:
		var pc_now: Node = get_node_or_null("PacingController")
		if pc_now and pc_now.get("current_phase") == 1:
			pc_now.force_cooldown()  ## 正常收尾：解除狂暴/锁定/停尸潮 BGM
		_stop_horde_music()
	if director_suspended == should_suspend:
		return
	director_suspended = should_suspend
	var pc: Node = get_node_or_null("PacingController")
	if suspended:
		print("[Director] 防守战挂起：节奏/常规刷怪冻结（EventManager 防守战刷怪不受影响）")
		if pc:
			pc.set("paused", true)
	else:
		print("[Director] 防守战结束：恢复常规编排（从喘息重新开始）")
		if pc:
			pc.set("paused", false)
			pc.force_cooldown()  ## 从 cooldown 重新计时，给玩家一段喘息


## 防守战狂暴（2026-09-12 用户需求）：防守战期间丧尸与尸潮一样狂暴（クリムゾンヘッド）。
## 复用 _horde_rage 的 spawn 注入路径 → 防守战期间 EventManager 经 spawn_horde_nodes
## 刷出的新敌人也直接以狂暴形态登场。目标锁定不在此接管：防守战的锁定由剧本事件
## 自己管理（target_lock / lock_nearby_at_start），与 _horde_locked_enemies 互不干扰。
func set_holdout_rage(active: bool) -> void:
	_horde_rage = active
	_set_all_enemies_rage(active)


func start_scripted_event(config: Dictionary) -> void:
	## 开始一个剧本事件（由 ScriptedEventTrigger 调用）
	## config 包含: event_name, event_type, event_duration,
	##              spawn_interval, spawn_per_wave, max_active, trigger_node
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("start_scripted_event"):
		em.start_scripted_event(config)
	else:
		printerr("[Director] EventManager 未就绪，无法开始剧本事件")


func is_scripted_event_active() -> bool:
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("is_scripted_event_active"):
		return em.is_scripted_event_active()
	return false


## 剧本事件（含防守战）剩余秒数；无事件进行中返回 0。倒计时 UI 用。
func get_scripted_event_remaining() -> float:
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("get_event_remaining"):
		return em.get_event_remaining()
	return 0.0


## 剧本事件总时长（秒）；无事件进行中返回 0。
func get_scripted_event_duration() -> float:
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("get_event_duration"):
		return em.get_event_duration()
	return 0.0


## 提前结束当前剧本事件（调试/剧情跳过用）。
func abort_scripted_event() -> void:
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("abort_scripted_event"):
		em.abort_scripted_event()


# ═══════════════════════════════════════
# 敌人生成
# ═══════════════════════════════════════

func spawn_enemy(pos: Vector2, decor_layer: Node, facing: int = -1) -> Node2D:
	# 事件/调试入口也不能绕过 Client 侧的生成禁令。
	if _is_network_client_session():
		return null
	if not _enemy_scene:
		printerr("[Director] enemy scene not loaded")
		return null

	var enemy = _enemy_scene.instantiate()
	enemy.global_position = pos
	## 僵尸变体：按关卡池权重随机选一种，注入外观与数值。
	## 必须在 add_child 之前（enemy._ready() 里 _refresh_sprite 用到 walk_texture）。
	if not _zombie_pool.is_empty():
		var zv: Resource = _pick_zombie_variant()
		if zv:
			enemy.walk_texture = zv.normal_texture
			enemy.move_speed = zv.move_speed
			enemy.attack_damage = zv.attack_damage
			# 血量/普通音效：0 或 null 表示沿用敌人自身默认值
			if float(zv.get("max_hp")) > 0.0:
				enemy.max_hp = float(zv.get("max_hp"))
			if zv.get("discover_sound") != null:
				enemy.discover_sound = zv.get("discover_sound")
			if zv.get("hurt_sound") != null:
				enemy.hurt_sound = zv.get("hurt_sound")
			if zv.get("attack_sound") != null:
				enemy.attack_sound = zv.get("attack_sound")
			# 死亡系音效（2026-09-14 补）：留空沿用 enemy.tscn 默认
			if zv.get("death_sound") != null:
				enemy.death_sound = zv.get("death_sound")
			if zv.get("headshot_sound") != null:
				enemy.headshot_sound = zv.get("headshot_sound")
			if zv.get("headshot_fall_sound") != null:
				enemy.headshot_fall_sound = zv.get("headshot_fall_sound")
			if zv.get("hit_target_sound") != null:
				enemy.hit_target_sound = zv.get("hit_target_sound")
			# 音效音调（2026-09-15 每音效可设音调）：0 = 沿用敌人自身默认
			if float(zv.get("discover_sound_pitch")) > 0.0:
				enemy.discover_sound_pitch = float(zv.get("discover_sound_pitch"))
			if float(zv.get("hurt_sound_pitch")) > 0.0:
				enemy.hurt_sound_pitch = float(zv.get("hurt_sound_pitch"))
			if float(zv.get("attack_sound_pitch")) > 0.0:
				enemy.attack_sound_pitch = float(zv.get("attack_sound_pitch"))
			if float(zv.get("death_sound_pitch")) > 0.0:
				enemy.death_sound_pitch = float(zv.get("death_sound_pitch"))
			if float(zv.get("headshot_sound_pitch")) > 0.0:
				enemy.headshot_sound_pitch = float(zv.get("headshot_sound_pitch"))
			if float(zv.get("headshot_fall_sound_pitch")) > 0.0:
				enemy.headshot_fall_sound_pitch = float(zv.get("headshot_fall_sound_pitch"))
			if float(zv.get("hit_target_sound_pitch")) > 0.0:
				enemy.hit_target_sound_pitch = float(zv.get("hit_target_sound_pitch"))
			if float(zv.get("rage_discover_sound_pitch")) > 0.0:
				enemy.variant_rage_discover_pitch = float(zv.get("rage_discover_sound_pitch"))
			enemy.variant_rage_texture = zv.rage_texture
			enemy.variant_rage_move_speed = zv.rage_move_speed
			enemy.variant_rage_attack_damage = zv.rage_attack_damage
			enemy.variant_rage_discover_sound = zv.rage_discover_sound
			enemy.variant_rage_exhaust_seconds = float(zv.get("rage_exhaust_seconds"))
			enemy.variant_rage_exhaust_down_seconds = float(zv.get("rage_exhaust_down_seconds"))
			# 数值扩展（2026-09-14 补差异化）：0 / 零值 = 沿用 enemy.gd 默认
			if int(zv.get("attack_cooldown_frames")) > 0:
				enemy.attack_cooldown_frames = int(zv.get("attack_cooldown_frames"))
			if int(zv.get("attack_element")) != 0:
				enemy.attack_element = int(zv.get("attack_element"))
			if float(zv.get("vision_angle")) > 0.0:
				enemy.vision_angle = float(zv.get("vision_angle"))
			if float(zv.get("vision_range")) > 0.0:
				enemy.vision_range = float(zv.get("vision_range"))
			if float(zv.get("walk_frame_duration")) > 0.0:
				enemy.walk_frame_duration = float(zv.get("walk_frame_duration"))
			if (zv.get("hurtbox_size") as Vector2) != Vector2.ZERO:
				enemy.hurtbox_size = zv.get("hurtbox_size")
			if (zv.get("hurtbox_offset") as Vector2) != Vector2.ZERO:
				enemy.hurtbox_offset = zv.get("hurtbox_offset")
	# 必须在 add_child 前设 initial_facing（@export），
	# 因为 enemy._ready() 里 _facing = initial_facing，
	# 之后 _refresh_sprite() 每次都用 _facing 重算精灵帧
	if facing >= 0:
		enemy.initial_facing = facing
	else:
		# 未指定朝向时，自动面向玩家
		enemy.initial_facing = _calc_facing_toward_player(pos)
	# 挂载点缺失（关卡尚无装饰层 / 测试场无地图）时不能直接 add_child，
	# 否则会在 null 上调用方法并使本次生成整体报错。此时释放刚实例化、尚未入树的节点。
	if decor_layer == null:
		printerr("[Director] spawn aborted: decor layer is null")
		enemy.free()
		return null
	decor_layer.add_child(enemy)
	## 尸潮期间刷出的敌人直接以狂暴形态登场（在 add_child 之后，_refresh_sprite 已就绪）
	if _horde_rage:
		enemy.set_rage(true)
		# 尸潮期间新刷的丧尸同样直接锁定最近玩家追击（对齐防守战行为）
		if enemy.has_method("lock_forced_target"):
			enemy.lock_forced_target(Players.nearest_entity_to(enemy.global_position))
			_horde_locked_enemies.append(enemy)

	_spawn_history.append({
		"time": Time.get_ticks_msec(),
		"pos": pos,
		"type": "common"
	})
	if _spawn_history.size() > 100:
		_spawn_history = _spawn_history.slice(-50)

	print("[Director] spawned enemy at (%d, %d)" % [int(pos.x), int(pos.y)])
	return enemy


func spawn_special_enemy(pos: Vector2, data: SpecialEnemyData, decor_layer: Node, facing: int = -1) -> Node2D:
	## 生成一只特感（ハンター 等）：复用 enemy.tscn 骨架，注入 SpecialEnemyData 的外观与数值。
	## 与 spawn_enemy 的区别：无僵尸变体池 / 无狂暴形态注入（variant_rage_texture 保持 null，
	## set_rage 自动 no-op）；入组 "special_enemies" 供同屏互斥计数；spawn_history 记为 special。
	## 仅单机 / Host 可调用（Client 生成禁令与 spawn_enemy 一致）。
	if _is_network_client_session():
		return null
	if data == null:
		printerr("[Director] spawn_special aborted: data is null")
		return null
	if not _enemy_scene:
		printerr("[Director] enemy scene not loaded")
		return null
	if decor_layer == null:
		printerr("[Director] spawn_special aborted: decor layer is null")
		return null

	var enemy = _enemy_scene.instantiate()
	enemy.global_position = pos
	# 注入必须全部发生在 add_child 之前：enemy._ready() 里 _refresh_sprite 就要用 walk_texture。
	if data.texture:
		enemy.walk_texture = data.texture
		enemy.walk_char_index = data.walk_char_index
	enemy.move_speed = data.move_speed
	enemy.attack_damage = data.attack_damage
	# 步行/跑步双移动模式（暴君・猎杀者：-1/0 = 未配置 = 单速）
	enemy.run_char_index = data.run_char_index
	enemy.run_speed = data.run_speed
	enemy.run_trigger_distance = data.run_trigger_distance
	# 初始行为：特感/Tank 登场即追击（跳过 Idle 徘徊与 Discover）
	enemy.starts_in_chase = data.starts_in_chase
	enemy.chase_acquire_range = data.chase_acquire_range
	if float(data.max_hp) > 0.0:
		enemy.max_hp = float(data.max_hp)
	if data.attack_range.x > 0.0 and data.attack_range.y > 0.0:
		enemy.attack_range = data.attack_range
	if data.attack_hit_range.x > 0.0 and data.attack_hit_range.y > 0.0:
		enemy.attack_hit_range = data.attack_hit_range
	if data.attack_cooldown_frames > 0:
		enemy.attack_cooldown_frames = data.attack_cooldown_frames
	if data.vision_range > 0.0:
		enemy.vision_range = data.vision_range
	enemy.attack_causes_heat = data.attack_causes_heat
	enemy.attack_element = data.attack_element
	enemy.melee_enabled = data.melee_enabled
	enemy.instant_kill_immune = data.instant_kill_immune
	# 远程吐酸（ブレインディモス，全工程首个敌人远程攻击）
	enemy.spit_enabled = data.spit_enabled
	enemy.spit_trigger_min_dist = data.spit_trigger_min_dist
	enemy.spit_trigger_max_dist = data.spit_trigger_max_dist
	enemy.spit_cooldown_seconds = data.spit_cooldown_seconds
	enemy.spit_windup_seconds = data.spit_windup_seconds
	enemy.spit_recover_seconds = data.spit_recover_seconds
	enemy.spit_projectile_speed = data.spit_projectile_speed
	enemy.spit_damage = data.spit_damage
	enemy.spit_char_sequence = data.spit_char_sequence
	enemy.spit_fire_at_sequence_idx = data.spit_fire_at_sequence_idx
	enemy.spit_sound = data.spit_sound
	enemy.spit_sound_pitch = data.spit_sound_pitch
	enemy.spit_impact_effect = data.spit_impact_effect
	enemy.spit_impact_tone = data.spit_impact_tone
	# 正面抗性（Hunter β 回避 / Tyrant Normalize）
	enemy.frontal_damage_mult = data.frontal_damage_mult
	enemy.frontal_arc_degrees = data.frontal_arc_degrees
	enemy.frontal_normalize = data.frontal_normalize
	enemy.frontal_normalize_ratio = data.frontal_normalize_ratio
	# 首狩り突进（ハンター 系）
	enemy.pounce_enabled = data.pounce_enabled
	enemy.pounce_trigger_min_dist = data.pounce_trigger_min_dist
	enemy.pounce_trigger_max_dist = data.pounce_trigger_max_dist
	enemy.pounce_windup_seconds = data.pounce_windup_seconds
	enemy.pounce_dash_seconds = data.pounce_dash_seconds
	enemy.pounce_speed_mult = data.pounce_speed_mult
	enemy.pounce_dash_speed = data.pounce_dash_speed
	enemy.pounce_hit_radius = data.pounce_hit_radius
	enemy.pounce_homing_turn_rate = data.pounce_homing_turn_rate
	enemy.pounce_hit_tolerance = data.pounce_hit_tolerance
	enemy.pounce_damage_mult = data.pounce_damage_mult
	enemy.pounce_cooldown_seconds = data.pounce_cooldown_seconds
	# 冲刺期锁定突刺帧（ハンターγ：原作「直到突刺移动结束之前，一直保持1」）
	enemy.pounce_hold_frame_during_dash = data.pounce_hold_frame_during_dash
	# 特感专属攻击动画帧序列（空 = 沿用丧尸默认帧）
	if data.attack_char_sequence.size() > 0:
		enemy.attack_char_sequence = data.attack_char_sequence
	# 攻击动画节奏与判定帧（tres 未配置 = 沿用 enemy 默认）。
	# 让特感的攻击判定精确落在素材「挥中」帧上，对齐普通丧尸的判定链路。
	if data.attack_frame_durations.size() > 0:
		enemy.attack_frame_durations = data.attack_frame_durations
	if data.hit_at_sequence_idx >= 0:
		enemy.hit_at_sequence_idx = data.hit_at_sequence_idx
	if data.attack_hit_forward_offset >= 0.0:
		enemy.attack_hit_forward_offset = data.attack_hit_forward_offset
	# 放大版素材帧尺寸（0 = 由 enemy.gd 按贴图自动推断）
	enemy.sprite_frame_w = data.sprite_frame_w
	enemy.sprite_frame_h = data.sprite_frame_h
	# 受击表现偏移 + 受击碰撞体（大体型敌人：原点在脚部，表现/判定要抬到躯干）
	enemy.hurt_effect_offset = data.hurt_effect_offset
	if data.hurtbox_size != Vector2.ZERO:
		enemy.hurtbox_size = data.hurtbox_size
	if data.hurtbox_offset != Vector2.ZERO:
		enemy.hurtbox_offset = data.hurtbox_offset
	# 附加动作表（T-002 等：走/攻/死分属不同贴图文件）
	if data.attack_texture != null:
		enemy.attack_texture = data.attack_texture
	if data.death_texture != null:
		enemy.death_texture = data.death_texture
	# death_char_index 语义按「有没有专用死亡表」分流（-1 = 不覆盖）：
	#   有 death_texture → 它是**死亡表内**的格索引（T-002 = 3）
	#   无 death_texture → 它是**行走表内**的格索引（女巫 = 3）
	# 2026-09-16 修：旧代码只在 death_texture != null 时注入，导致女巫配的 3 从未生效
	# （enemy 一直用默认 4 → 死亡显示攻击帧）。
	if data.death_char_index >= 0:
		if data.death_texture != null:
			enemy.death_texture_char_index = data.death_char_index
		else:
			enemy.death_char_index = data.death_char_index
	# 女巫徘徊（ブレアウィッチ）
	enemy.witch_enabled = data.witch_enabled
	enemy.witch_wander_speed = data.witch_wander_speed
	enemy.witch_stim_radius = data.witch_stim_radius
	enemy.witch_stim_speed = data.witch_stim_speed
	enemy.witch_enrage_speed_mult = data.witch_enrage_speed_mult
	if data.witch_scream_sound != null:
		enemy.witch_scream_sound = data.witch_scream_sound
	if data.witch_scream_sound_pitch > 0.0:
		enemy.witch_scream_sound_pitch = data.witch_scream_sound_pitch
	# 攻击挥击音效（空 = 沿用敌人自身 attack_sound）
	if data.attack_sound != null:
		enemy.attack_sound = data.attack_sound
	if data.attack_sound_pitch > 0.0:
		enemy.attack_sound_pitch = data.attack_sound_pitch
	# 击中目标音效（空 = 沿用敌人自身 hit_target_sound，2026-09-15）
	if data.hit_target_sound != null:
		enemy.hit_target_sound = data.hit_target_sound
	if data.hit_target_sound_pitch > 0.0:
		enemy.hit_target_sound_pitch = data.hit_target_sound_pitch
	# 死亡音效（空 = 沿用敌人自身 death_sound，2026-09-15 特感 tres 可配）
	if data.death_sound != null:
		enemy.death_sound = data.death_sound
	if data.death_sound_pitch > 0.0:
		enemy.death_sound_pitch = data.death_sound_pitch
	# 首狩り起跳/突进音效（空 = 沿用敌人自身 pounce_sound，再回退 attack_sound）
	if data.pounce_sound != null:
		enemy.pounce_sound = data.pounce_sound
	if data.pounce_sound_pitch > 0.0:
		enemy.pounce_sound_pitch = data.pounce_sound_pitch
	# 丸呑み（ハンターγ）
	enemy.swallow_enabled = data.swallow_enabled
	enemy.swallow_trigger_range = data.swallow_trigger_range
	enemy.swallow_chance = data.swallow_chance
	enemy.swallow_chew_cycles = data.swallow_chew_cycles
	enemy.swallow_chew_interval = data.swallow_chew_interval
	enemy.swallow_recover_seconds = data.swallow_recover_seconds
	enemy.swallow_char_sequence = data.swallow_char_sequence
	enemy.swallow_is_lethal = data.swallow_is_lethal
	enemy.swallow_weapon_attrition = data.swallow_weapon_attrition
	if data.swallow_texture != null:
		enemy.swallow_texture = data.swallow_texture
	if data.discover_sound != null:
		enemy.discover_sound = data.discover_sound
	if data.discover_sound_pitch > 0.0:
		enemy.discover_sound_pitch = data.discover_sound_pitch
	if data.hurt_sound != null:
		enemy.hurt_sound = data.hurt_sound
	if data.hurt_sound_pitch > 0.0:
		enemy.hurt_sound_pitch = data.hurt_sound_pitch
	enemy.initial_facing = facing if facing >= 0 else _calc_facing_toward_player(pos)
	decor_layer.add_child(enemy)
	# 入树后再进组：同屏互斥计数（_update_specials）依赖本组。
	enemy.add_to_group("special_enemies")

	_spawn_history.append({
		"time": Time.get_ticks_msec(),
		"pos": pos,
		"type": "special"
	})
	if _spawn_history.size() > 100:
		_spawn_history = _spawn_history.slice(-50)

	special_spawned.emit(String(data.id))
	print("[Director] spawned special enemy '%s' at (%d, %d)" % [String(data.id), int(pos.x), int(pos.y)])
	return enemy


func spawn_ahead_batch(count: int) -> Array[Node2D]:
	## 「前方屏外定点刷怪」的统一出口：把 count 只敌人补到玩家前方、屏幕之外。
	##
	## 与 `spawn_horde_nodes()` 的区别：
	##   · 位置一律走 FrontSpawner（前方扇区 + 屏外 + 距离带），**不再全图随机撒**；
	##   · 前方带内数量已达上限时**直接不刷**（"这个范围里已经有一定数量就不刷"）。
	## 事件编排（散兵 / 尸潮 / 防守战）都应走这个入口，保证分布一致。
	var out: Array[Node2D] = []
	var player: Node2D = _find_player()
	if player == null:
		return out
	var fs: Node = get_node_or_null("FrontSpawner")
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		printerr("[Director] spawn_ahead_batch aborted: decor layer is null")
		return out

	## 附近闸（2026-09-17 用户需求）：附近敌人达标且玩家静止 → 一只不刷（散兵/尸潮/防守战统一入口）
	if _nearby_spawn_blocked():
		return out

	var want: int = count
	if fs and fs.get("enabled") == true:
		var ahead: int = fs.count_ahead(player)
		var target: int = int(fs.get("target_ahead"))
		# 前方带里已经够了 → 一只都不刷（这是"别太密"的主要闸门）
		if ahead >= target:
			return out
		want = mini(want, target - ahead)

	for _i: int in range(want):
		var pos: Vector2 = Vector2.ZERO
		if fs:
			pos = fs.pick_ahead_position(player)
		if pos == Vector2.ZERO:
			# FrontSpawner 被禁用 / 找不到合适点时，退回旧的作者刷新点逻辑
			pos = _pick_spawn_position(player, _get_nearby_spawn_points(player, _get_valid_spawn_points(player, decor_layer)), 0)
			if pos == Vector2.ZERO:
				break
		var enemy: Node2D = spawn_enemy(_add_spawn_scatter(pos), decor_layer, -1)
		if enemy:
			out.append(enemy)
	return out


func spawn_horde(count: int, decor_layer: Node) -> int:
	## 兼容旧调用：只关心生成数量。
	return spawn_horde_nodes(count, decor_layer).size()


## 与 spawn_horde 相同，但返回生成出来的敌人节点数组。
## 防守战需要逐个给新敌人锁定玩家目标，因此必须拿到节点本身。
func spawn_horde_nodes(count: int, decor_layer: Node) -> Array[Node2D]:
	var spawned_nodes: Array[Node2D] = []
	var player: Node2D = _find_player()
	if not player:
		return spawned_nodes

	var spawn_points: Array = _get_valid_spawn_points(player, decor_layer)
	var nearby_spawn_points: Array = _get_nearby_spawn_points(player, spawn_points)
	var use_near_player_fallback := nearby_spawn_points.is_empty()
	if use_near_player_fallback:
		# 地图作者的生成区可能在后续区域；若它们全在很远处，首批怪物既看不到也不会因
		# 视野范围而主动靠近。优先在玩家外围找可行走格；找不到才退回作者生成区。
		print("[Director] spawn candidates: total=%d nearby=0 fallback=near_player" % spawn_points.size())
	elif nearby_spawn_points.size() != spawn_points.size():
		print("[Director] spawn candidates: total=%d nearby=%d" % [spawn_points.size(), nearby_spawn_points.size()])

	var fs: Node = get_node_or_null("FrontSpawner")
	var spawned: int = 0
	for _i: int in range(count):
		var pos := Vector2.ZERO
		## 尸潮批位置（2026-09-17 用户反馈）：优先前方屏外带（与普通补位同一取点），
		## 让尸潮怪从玩家前方屏外涌来——旧逻辑优先「附近作者生成区」，经常全在玩家
		## 身后来时的路上，表现为「尸潮一只没见到、回头走才遇到」。
		if fs and fs.get("enabled") == true:
			pos = fs.call("pick_ahead_position", player)
		if pos == Vector2.ZERO:
			if not use_near_player_fallback:
				pos = _pick_spawn_position(player, nearby_spawn_points, spawned)
			else:
				pos = _find_walkable_near_player(player)
				if pos == Vector2.ZERO and not spawn_points.is_empty():
					# 极少数出生点被墙完全包围的地图仍可使用原有生成区，不会因为回退策略而停刷。
					pos = _pick_spawn_position(player, spawn_points, spawned)
		if pos == Vector2.ZERO:
			continue
		pos = _add_spawn_scatter(pos)
		var enemy: Node2D = spawn_enemy(pos, decor_layer, -1)
		if enemy:
			spawned += 1
			spawned_nodes.append(enemy)

	if spawned == 0 and spawn_points.is_empty():
		printerr("[Director] no valid spawn points or nearby walkable fallback")
	return spawned_nodes


func _pick_spawn_position(player: Node2D, spawn_points: Array, spawned_count: int) -> Vector2:
	if not spawn_points.is_empty():
		var sp: Node2D = spawn_points[spawned_count % spawn_points.size()] as Node2D
		if sp is SpawnZone:
			return (sp as SpawnZone).get_random_position()
		else:
			return sp.global_position
	return _find_walkable_near_player(player)


func _add_spawn_scatter(pos: Vector2) -> Vector2:
	## 散步 + 避开现有敌人碰撞体（间距 28px）。若附近都不可用，保留已验证的原始位置。
	for _attempt: int in range(20):
		var scattered: Vector2 = pos + Vector2(randf_range(-36, 36), randf_range(-36, 36))
		if _is_walkable(scattered) and not _is_occupied_by_enemy(scattered) and not _was_recently_used(scattered):
			return scattered
	return pos


func _is_occupied_by_enemy(global_pos: Vector2) -> bool:
	const MIN_SEP: float = 28.0
	var tree: SceneTree = get_tree()
	if not tree:
		return false
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if global_pos.distance_to(e.global_position) < MIN_SEP:
			return true
	return false


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════

func get_intensity() -> float:
	if intensity_tracker and intensity_tracker.has_method("get_intensity"):
		return intensity_tracker.get_intensity()
	return 0.0


func set_progress(ratio: float) -> void:
	if intensity_tracker and intensity_tracker.has_method("set_progress"):
		intensity_tracker.set_progress(ratio)


func set_combat(active: bool) -> void:
	if intensity_tracker and intensity_tracker.has_method("set_combat"):
		intensity_tracker.set_combat(active)


# ═══════════════════════════════════════
# 内部 — 玩家/场景查找
# ═══════════════════════════════════════

## 上一次"生成图判定"的结果（-1 = 未初始化）。用于只在该判定翻转时打一条日志 ——
## 安全屋/静默图不刷怪这件事没有别的可观测点，出问题时只能靠这行确认判成了什么。
var _last_spawn_verdict: int = -1


func _is_spawn_map() -> bool:
	## 检查当前场景是否允许敌人生成（结果变化时打一条日志，便于排查"安全屋刷怪"类问题）。
	var verdict: bool = _evaluate_spawn_map()
	if (1 if verdict else 0) != _last_spawn_verdict:
		_last_spawn_verdict = 1 if verdict else 0
		var sp: String = ""
		var t: SceneTree = get_tree()
		if t and t.current_scene:
			sp = t.current_scene.scene_file_path
		print("[Director] 生成图判定: %s | 场景=%s | auto_spawn=%s | 安全屋黑名单=%s" % [
			"允许生成" if verdict else "禁止生成（安全屋/静默图）",
			sp.get_file(), str(auto_spawn_enabled), str(safe_room_keywords)])
	return verdict


func _evaluate_spawn_map() -> bool:
	if not auto_spawn_enabled:
		return false
	var tree: SceneTree = get_tree()
	if not tree or not tree.current_scene:
		return false
	var scene_path: String = tree.current_scene.scene_file_path.to_lower()
	# 白名单：指定了关键字则必须匹配
	if spawn_map_keywords.size() > 0:
		var matched: bool = false
		for kw: String in spawn_map_keywords:
			if kw.to_lower() in scene_path:
				matched = true
				break
		if not matched:
			return false
	# 黑名单：安全屋不生成
	for kw: String in safe_room_keywords:
		if kw.to_lower() in scene_path:
			return false
	return true


func _check_scene_change() -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var scene: Node = tree.current_scene
	if scene == _last_scene:
		return
	_last_scene = scene
	# 场景切换 → 清空 TileMapLayer 缓存（旧引用已释放）
	_tilemap_cache.clear()
	_tilemap_cache_ready = false
	# 场景切换 → 同步清空禁刷怪层缓存（NoSpawnLayer）
	_no_spawn_layers.clear()
	_no_spawn_cache_ready = false
	# 场景切换 → 复位防守战挂起状态：旧场景的 HoldoutMachine 已随场景释放，
	# 不会再来 resume；残留的挂起计数会让节奏永久冻结（且让幂等早退吞掉新防守战
	# 的尸潮收尾，尸潮 BGM 停不下来）。
	if director_suspended or _suspend_count > 0:
		director_suspended = false
		_suspend_count = 0
		var pc_reset: Node = get_node_or_null("PacingController")
		if pc_reset:
			pc_reset.set("paused", false)
		print("[Director] 场景切换：残留的防守战挂起状态已复位")
	if not scene:
		return
	var cfg: DirectorConfig = _find_director_config(scene)
	if cfg:
		print("[Director] applying DirectorConfig from: %s" % scene.scene_file_path)
		_apply_config(cfg)
		current_config = cfg
	else:
		print("[Director] no DirectorConfig in scene, using defaults")


func _find_director_config(node: Node) -> DirectorConfig:
	if node is DirectorConfig:
		return node as DirectorConfig
	for child: Node in node.get_children():
		var found: DirectorConfig = _find_director_config(child)
		if found:
			return found
	return null


func _apply_config(cfg: DirectorConfig) -> void:
	auto_spawn_enabled = cfg.spawn_enabled
	spawn_min_dist = cfg.spawn_min_dist
	var pc: Node = get_node_or_null("PacingController")
	if pc:
		_copy_props(cfg, pc, ["build_min", "build_max", "peak_timeout",
			"cooldown_min", "cooldown_max", "peak_intensity_threshold", "cooldown_intensity_threshold"])
	# FrontSpawner 的参数名与 DirectorConfig 前缀不同（配置里带 front_ 前缀便于在 Inspector 分组），
	# 因此这里逐项显式映射，不能走 _copy_props 的同名约定。
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs:
		fs.set("enabled", cfg.front_spawn_enabled)
		fs.set("target_ahead", cfg.front_target_ahead)
		fs.set("target_ahead_peak", cfg.front_target_ahead_peak)
		fs.set("batch", cfg.front_batch)
		fs.set("batch_peak", cfg.front_batch_peak)
		fs.set("interval_min_peak", cfg.front_interval_min_peak)
		fs.set("front_half_angle", cfg.front_half_angle)
		fs.set("min_dist", cfg.front_min_dist)
		fs.set("max_dist", cfg.front_max_dist)
		fs.set("offscreen_margin", cfg.front_offscreen_margin)
		fs.set("advance_step", cfg.front_advance_step)
		fs.set("interval_min", cfg.front_interval_min)
		fs.set("spawn_when_idle", cfg.front_spawn_when_idle)
		fs.set("max_active_common", cfg.max_active_common)
		fs.set("nearby_gate_count", cfg.nearby_gate_count)
		fs.set("nearby_gate_radius", cfg.nearby_gate_radius)
	_copy_props(cfg, self, ["recycle_enabled", "recycle_interval", "recycle_dist", "recycle_clear_corpses"])
	_zombie_pool = cfg.zombie_pool if not cfg.zombie_pool.is_empty() else DEFAULT_ZOMBIE_POOL
	# ── 特感池与节奏：地图不配 special_pool 就完全不刷（向后兼容）──
	_special_pool = cfg.special_pool
	special_max_alive = cfg.special_max_alive
	special_intensity_threshold = cfg.special_intensity_threshold
	special_cooldown_min = cfg.special_cooldown_min
	special_cooldown_max = cfg.special_cooldown_max
	# 换图重置计时：第一只特感按本关配置延迟登场，冷却归零（首延迟本身就是第一只的等待）。
	_special_first_delay_left = randf_range(cfg.special_first_delay_min, cfg.special_first_delay_max)
	_special_cooldown_left = 0.0
	# ── 夜间视界（Night Hunter）：night_darkness>0 时在场景根挂 NightOverlay ──
	# 安全屋等 spawn_enabled=false 的场景也生效——夜是场景属性，与刷怪无关。
	NightOverlay.apply_darkness(get_tree().current_scene, cfg.night_darkness)
	# ── Boss / Tank 编排参数 ──
	tank_enabled = cfg.tank_enabled
	_tank_data = cfg.tank_data if cfg.tank_data != null else load(DEFAULT_TANK_PATH)
	tank_max_alive = cfg.tank_max_alive
	tank_intensity_threshold = cfg.tank_intensity_threshold
	tank_cooldown_min = cfg.tank_cooldown_min
	tank_cooldown_max = cfg.tank_cooldown_max
	holdout_tank_enabled = cfg.holdout_tank_enabled
	_holdout_tank_data = cfg.holdout_tank_data if cfg.holdout_tank_data != null else _tank_data
	holdout_tank_first_delay = cfg.holdout_tank_first_delay
	holdout_tank_cooldown_min = cfg.holdout_tank_cooldown_min
	holdout_tank_cooldown_max = cfg.holdout_tank_cooldown_max
	holdout_tank_max_alive = cfg.holdout_tank_max_alive
	# 换图重置：常规 Tank 冷却从本关开始时起算；防守战计时在防守战开启时再重置。
	_tank_cooldown_left = randf_range(tank_cooldown_min, tank_cooldown_max)
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0
	var sm: Node = get_node_or_null("SpawnManager")
	if sm:
		_copy_props(cfg, sm, ["scatter_min", "scatter_max",
			"scatter_interval_min", "scatter_interval_max",
			"horde_total_min", "horde_total_max",
			"horde_batch_size", "horde_batch_interval", "max_active_common"])
	print("[Director] config applied: spawn=%s cooldown=%.0f-%.0fs" % [cfg.spawn_enabled, cfg.cooldown_min, cfg.cooldown_max])


func _copy_props(src: Object, dst: Object, props: Array[String]) -> void:
	for prop: String in props:
		var val = src.get(prop)
		if val != null and prop in dst:
			dst.set(prop, val)


func _find_player() -> Node2D:
	var players: Array[Node2D] = Players.all_entities()
	return players[0] if not players.is_empty() else null


## 附近闸（2026-09-17 用户需求）：附近敌人 ≥ 阈值且玩家静止 → 暂停刷怪
## （散兵/事件批统一入口 spawn_ahead_batch 调用）。参数挂 FrontSpawner
## （nearby_gate_count / nearby_gate_radius，由 DirectorConfig 注入）；玩家开始移动立即放行。
## 防守战走 spawn_horde_nodes 路径，不经本闸（守家蹲点不能断怪）。
func _nearby_spawn_blocked() -> bool:
	var fs: Node = get_node_or_null("FrontSpawner")
	var gate: int = int(fs.get("nearby_gate_count")) if fs else 10
	if gate <= 0:
		return false
	var player: Node2D = _find_player()
	if player == null:
		return false
	var vel: Variant = player.get("velocity")
	if vel is Vector2 and (vel as Vector2).length() >= 20.0:
		return false  ## 玩家在移动 → 放行
	var radius: float = float(fs.get("nearby_gate_radius")) if fs else 600.0
	var r2: float = radius * radius
	var count: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and e.global_position.distance_squared_to(player.global_position) <= r2:
			count += 1
	return count >= gate


func _find_decor_layer() -> Node:
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	return _find_decor_recursive(tree.root)


func _find_decor_recursive(node: Node) -> Node:
	if not is_instance_valid(node):
		return null
	if "decor" in node.name.to_lower():
		return node
	for child: Node in node.get_children():
		var found: Node = _find_decor_recursive(child)
		if found:
			return found
	return null


# ═══════════════════════════════════════
# 内部 — 生成点管理
# ═══════════════════════════════════════

func _get_valid_spawn_points(player: Node2D, _decor_layer: Node) -> Array:
	var tree: SceneTree = get_tree()
	if not tree:
		return []

	var all_points: Array = []
	_collect_spawn_nodes(tree.root, all_points)
	print("[Director] found %d spawn nodes" % all_points.size())

	var valid: Array = []
	for sp: Node2D in all_points:
		if not is_instance_valid(sp):
			continue
		if sp is SpawnPoint and not (sp as SpawnPoint).enabled:
			continue
		if sp is SpawnZone and not (sp as SpawnZone).enabled:
			continue
		var dist: float = player.global_position.distance_to(sp.global_position)
		if dist < spawn_min_dist:
			continue
		if _was_recently_used(sp.global_position):
			continue
		# 只检查 SpawnPoint 本身是否合法（SpawnZone 内部随机位置由后续检查）
		if sp is SpawnPoint and not _is_walkable(sp.global_position):
			print("[Director]   skip SpawnPoint at (%d,%d): on collision tile" % [int(sp.global_position.x), int(sp.global_position.y)])
			continue
		valid.append(sp)

	if valid.size() > 1:
		_sort_spawn_points_by_priority(valid)

	print("[Director] valid spawns: %d" % valid.size())
	return valid


func _get_nearby_spawn_points(player: Node2D, spawn_points: Array) -> Array:
	var nearby: Array = []
	var max_distance := maxf(PREFERRED_SPAWN_MAX_DISTANCE, spawn_min_dist + 240.0)
	for sp: Node2D in spawn_points:
		if is_instance_valid(sp) and player.global_position.distance_to(sp.global_position) <= max_distance:
			nearby.append(sp)
	if nearby.size() > 1:
		_sort_spawn_points_by_priority(nearby)
	return nearby


func _sort_spawn_points_by_priority(arr: Array) -> void:
	var n: int = arr.size()
	for i: int in range(n):
		for j: int in range(n - i - 1):
			var a: Node2D = arr[j] as Node2D
			var b: Node2D = arr[j + 1] as Node2D
			var pa: float = _get_spawn_priority(a)
			var pb: float = _get_spawn_priority(b)
			if pa < pb:
				arr[j] = b
				arr[j + 1] = a


func _get_spawn_priority(sp: Node2D) -> float:
	if sp is SpawnPoint:
		return (sp as SpawnPoint).priority
	return 1.0




func _calc_facing_toward_player(from_pos: Vector2) -> int:
	## 计算从 from_pos 朝向玩家的方向（0=下,1=左,2=右,3=上）
	var player: Node2D = _find_player()
	if not player:
		return 0
	var to_player: Vector2 = player.global_position - from_pos
	# 与 enemy.gd update_facing_from_direction() 逻辑一致
	if abs(to_player.x) > abs(to_player.y):
		return 2 if to_player.x > 0 else 1  # RIGHT : LEFT
	else:
		return 0 if to_player.y > 0 else 3  # DOWN : UP


func _get_spawn_facing(sp: Node2D) -> int:
	var use_random: bool = false
	var default_facing: int = 0
	if sp is SpawnPoint:
		var pt: SpawnPoint = sp as SpawnPoint
		use_random = pt.random_facing
		default_facing = pt.facing
	elif sp is SpawnZone:
		var zone: SpawnZone = sp as SpawnZone
		use_random = zone.random_facing
		default_facing = zone.facing
	if use_random:
		return randi() % 4
	return default_facing

func _collect_spawn_nodes(node: Node, out: Array) -> void:
	if not is_instance_valid(node):
		return
	if node is SpawnPoint or node is SpawnZone:
		out.append(node)
	for child: Node in node.get_children():
		_collect_spawn_nodes(child, out)


# ═══════════════════════════════════════
# 内部 — 重复检查
# ═══════════════════════════════════════

const RECENT_SPAWN_RADIUS = 48.0
const RECENT_SPAWN_TIME_MSEC = 2000

func _was_recently_used(pos: Vector2) -> bool:
	var now: int = Time.get_ticks_msec()
	for entry: Dictionary in _spawn_history:
		if now - entry["time"] > RECENT_SPAWN_TIME_MSEC:
			continue
		var entry_pos: Vector2 = entry["pos"] as Vector2
		if pos.distance_to(entry_pos) < RECENT_SPAWN_RADIUS:
			return true
	return false


# ═══════════════════════════════════════
# 内部 — 可通行检查（TileData 碰撞）
# ═══════════════════════════════════════

var _tilemap_cache: Array = []
var _tilemap_cache_ready: bool = false

## ── 禁刷怪层（NoSpawnLayer）缓存 ──
## 关卡作者在 NoSpawnLayer 上涂过的格子 = 禁止生成敌人的区域
## （剧情点/爆破点附近不准刷怪）。经 _is_walkable 生效，所有刷怪闸门统一覆盖。
var _no_spawn_layers: Array = []
var _no_spawn_cache_ready: bool = false

func _ensure_no_spawn_cache(from_node: Node2D) -> void:
	if _no_spawn_cache_ready:
		return
	var tree: SceneTree = from_node.get_tree()
	if not tree:
		return
	_find_no_spawn_layers(tree.root)
	_no_spawn_cache_ready = true
	if not _no_spawn_layers.is_empty():
		print("[Director] NoSpawnLayer 缓存: %d 层" % _no_spawn_layers.size())


func _find_no_spawn_layers(node: Node) -> void:
	if node is NoSpawnLayer:
		_no_spawn_layers.append(node)
	for child: Node in node.get_children():
		_find_no_spawn_layers(child)


func _is_no_spawn(global_pos: Vector2) -> bool:
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return false
	_ensure_no_spawn_cache(player)
	for layer: Node in _no_spawn_layers:
		if not is_instance_valid(layer):
			continue
		var tm := layer as TileMapLayer
		var coords: Vector2i = tm.local_to_map(tm.to_local(global_pos))
		if tm.get_cell_source_id(coords) != -1:
			return true
	return false


## 落点是否在地图图块范围内（任一 TileMapLayer 的有效格 = 有图块）。
## 纯视觉层（无 physics）也算——它们同样界定"图内"；NoSpawnLayer 除外
## （作者可能把标记涂到图外，不能反过来把图外判成"图内"）。
func _is_inside_map(global_pos: Vector2) -> bool:
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return true  ## 无玩家时无从取缓存，保守放行（与 _is_walkable 旧兜底一致）
	_ensure_tilemap_cache(player)
	for tm: TileMapLayer in _tilemap_cache:
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		if tm is NoSpawnLayer:
			continue
		var coords: Vector2i = tm.local_to_map(tm.to_local(global_pos))
		if tm.get_cell_source_id(coords) != -1:
			return true
	return false

func _ensure_tilemap_cache(from_node: Node2D) -> void:
	if _tilemap_cache_ready:
		return
	var tree: SceneTree = from_node.get_tree()
	if not tree:
		return
	_find_tilemaps(tree.root)
	_tilemap_cache_ready = true
	print("[Director] TileMapLayer cache: %d layers" % _tilemap_cache.size())


func _find_tilemaps(node: Node) -> void:
	if node is TileMapLayer:
		_tilemap_cache.append(node as TileMapLayer)
	for child: Node in node.get_children():
		_find_tilemaps(child)


func _is_walkable(global_pos: Vector2) -> bool:
	## 禁刷怪层优先：作者标注的 NoSpawn 格子一律不可作为刷怪落点（可通行但禁刷）。
	if _is_no_spawn(global_pos):
		return false
	## 图块范围闸（2026-09-14）：地图外的格子没有碰撞数据，旧逻辑判成"可走"，
	## 防守战会出现刷在地图最外层之外的敌人——落点必须在任一层的有效图块上。
	if not _is_inside_map(global_pos):
		return false
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return true
	_ensure_tilemap_cache(player)
	if _tilemap_cache.is_empty():
		return true

	for tm: TileMapLayer in _tilemap_cache:
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		## 无 physics layer 的 TileSet（纯视觉图块集）直接跳过：否则
		## get_collision_polygons_count(0) 会每格刷 "Index p_layer_id = 0 is out of bounds"。
		if tm.tile_set.get_physics_layers_count() == 0:
			continue
		var local_pos: Vector2 = tm.to_local(global_pos)
		var coords: Vector2i = tm.local_to_map(local_pos)
		var tile_data: TileData = tm.get_cell_tile_data(coords)
		if tile_data and tile_data.get_collision_polygons_count(0) > 0:
			return false
	return true


# ═══════════════════════════════════════
# 僵尸变体（ZombieVariant 池 + 尸潮狂暴）
# ═══════════════════════════════════════

func _pick_zombie_variant() -> Resource:
	## 按权重从关卡僵尸池随机选一种变体（weight=0 的不会被选中）。
	if _zombie_pool.is_empty():
		return null
	var total: float = 0.0
	for v: Resource in _zombie_pool:
		total += maxf(float(v.weight), 0.0)
	if total <= 0.0:
		return _zombie_pool[0]
	var roll: float = randf() * total
	for v: Resource in _zombie_pool:
		roll -= maxf(float(v.weight), 0.0)
		if roll <= 0.0:
			return v
	return _zombie_pool.back()


func _set_all_enemies_rage(on: bool) -> void:
	## 尸潮触发/结束 → 全场僵尸切换狂暴（クリムゾンヘッド）/普通形态。
	## 无狂暴图的外观（variant_rage_texture == null）在 set_rage 内部自动跳过。
	var n: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		if e.has_method("set_rage"):
			e.set_rage(on)
			n += 1
	if n > 0:
		print("[Director] 尸潮狂暴%s：%d 只僵尸%s" % [
			"开启" if on else "解除", n,
			"切换为クリムゾンヘッド" if on else "恢复普通形态"])


# ═══════════════════════════════════════
# 特感编排（SpecialEnemyData：ハンター 等）
# ═══════════════════════════════════════

func _update_specials(delta: float, player: Node2D, current_phase: StringName) -> void:
	## 特感低频高压编排：紧张度门槛 + 随机冷却 + 同屏上限（special_max_alive）。
	## 池空 = 本关未启用特感，直接待机；尸潮（peak）期间计时冻结，不与尸潮叠加施压。
	if _special_pool.is_empty():
		return
	if current_phase == &"peak":
		return
	# 同屏上限（2026-09-16 修复）：此前写死「有任意一只存活特感就不刷」，把地图 Inspector
	# 配的 special_max_alive=2/3 彻底架空 —— 叠加 Hunter β 正面免疫导致的高存活率，
	# 表现为「很少有特感出现」（用户实测反馈）。现在按本关卡配置计数放行。
	var alive_specials: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("special_enemies"):
		if is_instance_valid(e) and e.get("_is_dying") != true and e.get("_is_dead") != true:
			alive_specials += 1
	if alive_specials >= maxi(1, special_max_alive):
		return
	# 第一只特感的登场延迟（_apply_config 掷 first_delay_min~max）
	if _special_first_delay_left > 0.0:
		_special_first_delay_left -= delta
		return
	# 冷却：每刷出一只后重掷 cooldown_min~max
	if _special_cooldown_left > 0.0:
		_special_cooldown_left -= delta
		return
	# 紧张度门槛：玩家压力不足时特感不登场（特感是压力放大器，不是开场惊喜）
	if get_intensity() < special_intensity_threshold:
		return

	var data: SpecialEnemyData = _pick_special_enemy()
	if data == null:
		return
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		return
	# 刷怪点：优先 FrontSpawner 的「前方扇区 + 屏外 + 距离带」取点，找不到再退玩家外围。
	var pos: Vector2 = Vector2.ZERO
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.get("enabled") == true:
		pos = fs.pick_ahead_position(player)
	if pos == Vector2.ZERO:
		pos = _find_walkable_near_player(player)
	if pos == Vector2.ZERO:
		return  # 本帧没有合法点位：保持冷却为 0，下一帧重试
	if spawn_special_enemy(pos, data, decor_layer, -1):
		_special_cooldown_left = randf_range(special_cooldown_min, special_cooldown_max)


func _pick_special_enemy() -> SpecialEnemyData:
	## 按 weight 从关卡特感池随机选一种（weight=0 的不会被选中）。空池返回 null。
	if _special_pool.is_empty():
		return null
	var total: float = 0.0
	for v: Resource in _special_pool:
		total += maxf(float(v.weight), 0.0)
	if total <= 0.0:
		return _special_pool[0] as SpecialEnemyData
	var roll: float = randf() * total
	for v: Resource in _special_pool:
		roll -= maxf(float(v.weight), 0.0)
		if roll <= 0.0:
			return v as SpecialEnemyData
	return _special_pool.back() as SpecialEnemyData


# ═══════════════════════════════════════
# Tank 编排（タイラント T-002）
# ═══════════════════════════════════════

## Tank 双通道编排：常规通道（tank_enabled）+ 防守战通道（holdout_tank_enabled）。
##
## 两条通道频率独立 —— 对齐原作：普通关卡里 Tank 是可选遭遇（拉什开始后才有机会），
## 147 图防守战里则是核心压迫源（早期就登场，菲纳莱必战）。
## 同屏互斥用 tank_max_alive / holdout_tank_max_alive，对应原作「重点敌人互斥」机制。
func _update_tanks(delta: float, player: Node2D, current_phase: StringName, spawn_map: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return

	# 防守战进行中 → 走防守战通道；否则走常规通道（互斥，不叠加施压）。
	# spawn_map=false（开场静默图）：常规通道停，防守战通道不受影响。
	if director_suspended:
		_update_holdout_tank(delta, player)
	elif spawn_map:
		_update_regular_tank(delta, player, current_phase)


func _update_regular_tank(delta: float, player: Node2D, current_phase: StringName) -> void:
	if not tank_enabled or _tank_data == null:
		return
	# 尸潮 peak 期间冻结计时：Tank 不与尸潮叠加（原作里两者是分开的高压事件）
	if current_phase == &"peak":
		return
	if _count_alive_tanks() > 0:
		return
	if _tank_cooldown_left > 0.0:
		_tank_cooldown_left -= delta
		return
	# Tank 门槛比特感更高：局面已经吃力时才是它出场的时候
	if get_intensity() < tank_intensity_threshold:
		return
	if _spawn_tank(_tank_data, player):
		_tank_cooldown_left = randf_range(tank_cooldown_min, tank_cooldown_max)


func _update_holdout_tank(delta: float, player: Node2D) -> void:
	if not holdout_tank_enabled or _holdout_tank_data == null:
		return
	if _count_alive_tanks() >= maxi(holdout_tank_max_alive, 1):
		return
	# 首只延迟：防守战开始后先给一段预热，再上 Tank
	if _holdout_tank_first_left > 0.0:
		_holdout_tank_first_left -= delta
		return
	if _holdout_tank_cooldown_left > 0.0:
		_holdout_tank_cooldown_left -= delta
		return
	if _spawn_tank(_holdout_tank_data, player):
		_holdout_tank_cooldown_left = randf_range(
			holdout_tank_cooldown_min, holdout_tank_cooldown_max)


## 生成一只 Tank。与特感共用 spawn_special_enemy（Tank 也是 SpecialEnemyData），
## 但额外入 "tank_enemies" 组供 count 用，并广播信号给 HUD（Boss 登场提示）。
func _spawn_tank(data: SpecialEnemyData, player: Node2D) -> bool:
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		return false
	# 刷怪点：Tank 应出现在玩家附近但屏外，用 FrontSpawner 的距离带取点
	var pos: Vector2 = Vector2.ZERO
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.get("enabled") == true:
		pos = fs.pick_ahead_position(player)
	if pos == Vector2.ZERO:
		pos = _find_walkable_near_player(player)
	if pos == Vector2.ZERO:
		return false
	# facing：让 Tank 登场时面朝玩家（压迫感）
	var facing: int = _calc_facing_toward_player(pos)
	var tank: Node2D = spawn_special_enemy(pos, data, decor_layer, facing)
	if tank == null:
		return false
	tank.add_to_group("tank_enemies")
	tank_spawned.emit(String(data.id))
	play_boss_music(tank)
	print("[Director] ★ Tank 登场: %s at (%d, %d)" % [String(data.id), int(pos.x), int(pos.y)])
	return true


## 当前存活坦克数（含濒死/倒地中 —— 未彻底清除前不刷下一只）。
func _count_alive_tanks() -> int:
	var n: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("tank_enemies"):
		if is_instance_valid(e) and e.get("_is_dying") != true and e.get("_is_dead") != true:
			n += 1
	return n


## 防守战开始时调用：重置防守战 Tank 计时（首只延迟重新起算）。
func notify_holdout_started() -> void:
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0


## 防守战结束时调用：清掉冷却，避免残留计时影响下一次防守战。
func notify_holdout_finished() -> void:
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0


# ═══════════════════════════════════════
# 回收（离玩家太远的敌人清除）
# ═══════════════════════════════════════

func _update_recycle(delta: float, player: Node2D) -> void:
	## 对应原作 #506「★☆敵の回収設定☆★」：把离玩家太远的敌人收回。
	##
	## 没有回收时（实测学校地图 60 秒）：被甩在身后的敌人只增不减（0 → 28 只），
	## 全场存活 29 秒即顶满上限 50 → 前方补位被"全场存活已达上限"永久掐断
	## （用户报的"前面刷得多、后面越来越少"），同时它们还在继续跑 A*（用户报的卡顿）。
	## 死亡动画中（_is_dying）不参与回收 —— 播完变尸体后下一轮按尸体清。
	if not recycle_enabled or player == null or not is_instance_valid(player):
		return
	_recycle_timer += delta
	if _recycle_timer < recycle_interval:
		return
	_recycle_timer = 0.0

	var cleared_alive: int = 0
	var cleared_corpses: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("recycle_exempt") == true:
			continue
		if e.get("_is_dying") == true:
			continue
		if e.global_position.distance_to(player.global_position) <= recycle_dist:
			continue
		if e.get("_is_dead") == true:
			if not recycle_clear_corpses:
				continue
			e.queue_free()
			cleared_corpses += 1
		else:
			_remove_enemy_networkwide(e)
			cleared_alive += 1

	if cleared_alive > 0 or cleared_corpses > 0:
		_recycle_cleared += cleared_alive
		_recycle_corpses += cleared_corpses
		print("[Director] 回收：清除远处存活敌人 %d / 尸体 %d（累计 %d / %d）" % [
			cleared_alive, cleared_corpses, _recycle_cleared, _recycle_corpses])


func _remove_enemy_networkwide(enemy: Node2D) -> void:
	## 清除一只存活敌人；联机会话下必须通知 Client 一并移除，
	## 否则 Client 会留下永久幽灵表现实体（Client 的实体不受 Host 直接管辖）。
	## ⚠ NetworkWorld 挂在**当前场景**下（GameInit._start_network_world 里 name="NetworkWorld"），
	## 不是 /root 下的 autoload —— 路径写错会静默找不到，Client 留幽灵实体。
	var tree: SceneTree = get_tree()
	var nw: Node = tree.current_scene.get_node_or_null("NetworkWorld") if tree and tree.current_scene else null
	if nw and nw.has_method("despawn_enemy_networkwide"):
		nw.despawn_enemy_networkwide(enemy)
		return
	enemy.queue_free()


# ═══════════════════════════════════════
# 内部 — 敌人统计
# ═══════════════════════════════════════

func _count_alive_enemies() -> int:
	var tree: SceneTree = get_tree()
	if not tree:
		return 0
	var count: int = 0
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		count += 1
	return count


# 内部 — 战斗状态
# ═══════════════════════════════════════

func _update_combat_state(player: Node2D) -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var enemies: Array = tree.get_nodes_in_group("enemy")
	var in_combat: bool = false
	for e: Node2D in enemies:
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if player.global_position.distance_to(e.global_position) < 500.0:
			in_combat = true
			break
	set_combat(in_combat)


# ═══════════════════════════════════════
# 内部 — F2 调试生成
# ═══════════════════════════════════════

func _debug_spawn() -> void:
	var decor_layer: Node = _find_decor_layer()
	if not decor_layer:
		printerr("[Director] DecorLayer not found")
		return

	var player: Node2D = _find_player()
	if not player:
		printerr("[Director] player not found")
		return

	var spawn_points: Array = _get_valid_spawn_points(player, decor_layer)
	var spawned: int = 0

	if spawn_points.is_empty():
		print("[Director] no SpawnPoints, spawning around player...")
		for i: int in range(DEBUG_SPAWN_COUNT):
			var pos: Vector2 = _find_walkable_near_player(player)
			if pos == Vector2.ZERO:
				continue
			if _was_recently_used(pos):
				continue
			var enemy: Node2D = spawn_enemy(pos, decor_layer, -1)  # -1=自动面向玩家
			if enemy:
				spawned += 1
	else:
		for i: int in range(DEBUG_SPAWN_COUNT):
			if spawn_points.is_empty():
				break
			var idx: int = randi() % spawn_points.size()
			var sp: Node2D = spawn_points[idx] as Node2D
			spawn_points.remove_at(idx)

			var pos: Vector2
			if sp is SpawnZone:
				# SpawnZone: 区域内随机，确保可行走
				for _attempt: int in range(10):
					pos = (sp as SpawnZone).get_random_position()
					if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
						break
				if pos == Vector2.ZERO:
					pos = (sp as SpawnZone).get_random_position()
			else:
				# SpawnPoint: 加小幅度散步，并确保最终位置可行走
				for _attempt: int in range(10):
					pos = sp.global_position + Vector2(randf_range(-12, 12), randf_range(-12, 12))
					if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
						break

			var enemy: Node2D = spawn_enemy(pos, decor_layer, _get_spawn_facing(sp))
			if enemy:
				spawned += 1

	print("[Director] F2 debug spawn: %d/%d enemies" % [spawned, DEBUG_SPAWN_COUNT])


func _find_walkable_near_player(player: Node2D) -> Vector2:
	## 玩家外围的可行走位置 —— 现在由 FrontSpawner 提供「前方 + 屏外 + 距离带」的取点。
	## 旧实现是在玩家周围 400~720px 的**任意方向**随机取点，敌人可能直接出现在可视范围内，
	## 分布也很散（用户反馈的"全图自动刷新、刷得很散"）。保留本函数名以免破坏其它调用点，
	## 但取点规则已改为"只在前方、只在屏外"。
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.get("enabled") == true:
		var pos_front: Vector2 = fs.pick_ahead_position(player)
		if pos_front != Vector2.ZERO:
			return pos_front
	for _attempt: int in range(36):
		var angle: float = randf() * TAU
		var dist: float = randf_range(spawn_min_dist, spawn_min_dist + 320.0)
		var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(angle) * dist
		pos += Vector2(randf_range(-16, 16), randf_range(-16, 16))
		if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
			return pos
	return Vector2.ZERO


func _update_ambient_zones(delta: float, player: Node2D) -> void:
	# 仅按区域预算补齐：不再从画面外批量刷丧尸，避免某地满、某地空。
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var decor_layer: Node = _find_decor_layer()
	if not decor_layer:
		return

	var zones: Array = []
	_collect_spawn_nodes(tree.root, zones)
	for sp: Node2D in zones:
		if not is_instance_valid(sp):
			continue
		if not (sp is SpawnZone):
			continue
		var zone: SpawnZone = sp as SpawnZone
		if not zone.enabled:
			continue
		var dist: float = player.global_position.distance_to(zone.global_position)
		if dist < zone.ambient_min_player_dist:
			continue
		if zone.poll_ambient_timer(delta) == false:
			continue

		var zone_cap: int = maxi(0, zone.max_spawns)
		if zone_cap <= 0:
			continue
		var current_count: int = 0
		for enemy: Node2D in tree.get_nodes_in_group("enemy"):
			if not is_instance_valid(enemy):
				continue
			if enemy.get("_is_dying") == true or enemy.get("_is_dead") == true:
				continue
			if enemy.global_position.distance_to(zone.global_position) <= zone.get_zone_radius():
				current_count += 1
		var target_count: int = mini(zone.ambient_budget, zone_cap)
		var shortage: int = maxi(0, target_count - current_count)
		if shortage <= 0:
			continue
		for _i: int in range(shortage):
			var pos: Vector2 = zone.get_random_position()
			if pos.distance_to(player.global_position) < zone.ambient_min_player_dist:
				continue
			# 必须在屏幕之外：区域是关卡作者摆的"刷在哪里"，但"何时刷"仍要避开玩家视野，
			# 否则会出现"眼睁睁看着敌人凭空冒出来"（复用 FrontSpawner 的屏幕判定）。
			var fs_node: Node = get_node_or_null("FrontSpawner")
			if fs_node and fs_node.get("enabled") == true and not fs_node.is_offscreen(player, pos):
				continue
			if not _is_walkable(pos):
				continue
			if _is_occupied_by_enemy(pos) or _was_recently_used(pos):
				continue
			var zone_count_after: int = _count_enemies_in_zone(zone)
			if zone_count_after >= zone_cap:
				break
			var enemy: Node2D = spawn_enemy(pos, decor_layer, _get_spawn_facing(zone))
			if enemy:
				continue
			break


func _count_enemies_in_zone(zone: SpawnZone) -> int:
	var tree: SceneTree = get_tree()
	if not tree:
		return 0
	var count: int = 0
	for enemy: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		if enemy.get("_is_dying") == true or enemy.get("_is_dead") == true:
			continue
		if enemy.global_position.distance_to(zone.global_position) <= zone.get_zone_radius():
			count += 1
	return count
