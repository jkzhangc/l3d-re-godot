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
## 固定刷怪点落点安全用的探测半径与工具（2026-09-26）。
## 敌人碰撞盒 20×28 → 半宽 10 / 半高 14，取 14 保证整盒不压墙。
## 用 preload 常量而不是裸全局类名（新建脚本的 class_name 要等编辑器重扫才进全局缓存）。
const SPOT_RESOLVER := preload("res://script/director/spawn_spot_resolver.gd")
const ENEMY_SPOT_PROBE_RADIUS: float = 14.0
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
## 尸潮期间的回收距离系数（2026-09-26 用户诉求：尸潮里我一直跑，前面就一直不刷了；
## 丧尸被刷掉后前面应当立马补几个过来，但不要超过上限）。
## 根因：`max_active` 数的是**全场**存活（含甩在身后的掉队者）——跑起来时上限被身后占满，
## 尸潮事件批就被"同屏存活已达上限"挡住 → 前方空场。尸潮期间收紧到 0.6×，
## 掉队者更快清掉、上限腾出，事件批照旧在**前方屏外**补回（仍受 max_active / 每批量限制）。
const PEAK_RECYCLE_SCALE: float = 0.6
var recycle_clear_corpses: bool = true
var _zombie_pool: Array = []          ## ZombieVariant 池（_apply_config 注入；空则用默认池）
## ★两个**必须分开**的标志（2026-10-31 修复 bug）：
## `_horde_rage` = 「尸潮/防守战窗口进行中」—— 决定**新刷的敌人是否直接锁定玩家追击**。
## `_horde_berserk` = 「窗口内是否真的切成クリムゾンヘッド形态」—— 只受附加参数控制。
## ⚠ 曾经把「目标锁定」写在 `if _horde_rage` 里，而 `_horde_rage` 又被附加参数直接置 false，
##   结果关掉「尸潮狂暴」后：新刷的丧尸不锁目标 → 站着不追人 → 不死 → 场上存活数卡在目标值
##   → `_update_horde` 认为达标不再补怪。玩家看到的就是「没补怪 + 新怪不主动来」。
var _horde_rage: bool = false         ## 尸潮/防守战窗口进行中（决定 spawn 时是否 lock_forced_target）
var _horde_berserk: bool = false      ## 窗口内是否切狂暴形态（附加参数可关；防守战恒开）
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
var mercy_hp_ratio: float = 0.35      ## 怜悯闸：任一存活玩家 HP 比例低于此值 → 暂停加压

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
## ★防守战 Tank「需求数」（2026-10-25）：> 0 表示这场防守战**必须靠杀 Tank 才能推进**
## （HoldoutMachine 的 KILL_COUNT + KillFilter.TANK，如列车台「杀 2 只开门」）。
## 此时 Tank 供给改用「需求间隔」而不是环境压力的 90~150s 随机冷却 ——
## 否则机器规定"杀 2 只"，导演却 2~3 分钟才放一只，玩家会以为门永远开不了。
var holdout_tank_demand: int = 0
## 需求模式下的 Tank 间隔（秒，会带 ±20% 抖动）。只在 `holdout_tank_demand > 0` 时生效。
var holdout_tank_demand_interval: float = 15.0
var _holdout_tank_retry_left: float = 0.0   ## 生成失败后的短退避（旧实现失败时不设冷却 → 每帧重试刷日志）
var _tank_cooldown_left: float = 0.0        ## 常规 Tank 冷却
var _holdout_tank_first_left: float = 0.0   ## 防守战首只 Tank 延迟
var _holdout_tank_cooldown_left: float = 0.0 ## 防守战 Tank 冷却

# ── Boss 发牌（L4D，2026-10-24 第二批）──
## 沿"里程"发牌：牌堆 = Tank / 女巫 / 无事，洗牌、不允许连续重复。
## 与节奏解耦 —— L4D 明确说过：Boss 若受节奏控制，高压时就不会出现，整体节奏反而崩。
const DEFAULT_WITCH_PATH := "res://tres/specials/ブレアウィッチ.tres"
var boss_deck_enabled: bool = true
var boss_deck_step: float = 3200.0
var boss_deck_first_ratio: float = 1.0
var boss_deck_nothing_weight: int = 4
var _witch_data: SpecialEnemyData = null
var _boss_deck: Array[int] = []          ## 待发的牌：0=Tank 1=女巫 2=无事
var _boss_deck_last: int = -1            ## 上一张（防连续重复）
var _boss_trail: float = 0.0             ## 本图累计前进里程（px）
var _boss_next_anchor: float = INF       ## 下一张牌的里程
var boss_deck_max_tanks: int = 1        ## 本图 Tank 牌上限（硬上限，防"一图四只"）
var boss_deck_max_witches: int = 1      ## 本图女巫牌上限
## ★L4D flow 闸（2026-10-25）：Tank 只允许在「已走过路程比例」的这个窗口内登场。
## 取值参照 L4D2 mission.txt `coop_boss_spawning.spawn_pos_min/max`（社区默认 0.2~0.8，
## 官方部分图 0.4~0.8）。这里默认 0.35~0.85：开局 1/3 段绝不遇 Tank，接近出口也不再放。
var tank_spawn_pos_min: float = 0.35
var tank_spawn_pos_max: float = 0.85
## 不允许连续两张图都出 Tank（L4D：不存在"两张图连着出、中间没有间隔"）。
var tank_no_repeat_maps: bool = true
var _boss_tank_weight: int = 1          ## 本图牌堆里放几张 Tank 牌（0 = 本图不出 Tank）
var _prev_map_had_tank: bool = false    ## 上一张「可用图」是否真的出过 Tank（跨图"不连续"判据）
var _boss_tanks_dealt: int = 0
var _tank_drought: int = 0        ## 连续几张图没发到 Tank（跨图保底）
var _deck_initialized: bool = false
var _boss_witches_dealt: int = 0

# ── L4D 节奏模型（2026-10-24）──
## 开启后：加压预算 / 峰值一次性尸潮（停手）/ 余韵 / 喘息低人口。
## 关掉 = 完全回到旧的"维持数量"模型（可 A/B、可整体回退）。
var l4d_pacing: bool = true
var relax_advance: float = 700.0            ## 喘息期累计前进多少像素提前结束
var _relax_anchor: Dictionary = {}          ## tid -> 进喘息时的位置快照

# ── 区域游荡者（wanderers，2026-10-24）──
## L4D 的 wanderers 是**预先铺在区域里**的：一片区域本来就有丧尸在晃。
## 本项目地图没有任何 SpawnZone/SpawnPoint（街道图实测 0 个），
## 所以进图与换区时由导演主动铺一层，替代 L4D 的 Active Area Set 预置。
var wander_seed_min: int = 6
var wander_seed_max: int = 9
var wander_seed_step: float = 900.0        ## 队伍累计前进多少像素算"进入新区域"
var wander_seed_refill: int = 3            ## 每次换区补几只
## ★密度自适应（2026-10-24 用户提议）：附近（威胁圈内）希望维持的游荡者总数。
## 补层时先数一次，**只补差额** —— 已经够就不补、不足才补，不会越补越多。
var wander_target_near: int = 10
var _wander_advance: float = 0.0           ## 自上次换区以来的累计净位移
var _wander_positions: Dictionary = {}     ## tid -> 上一帧位置
var _phase_cache: StringName = &"cooldown" ## 上一帧的节奏阶段（供区域补齐等早期块使用）

# ── 画面外补怪总开关（2026-10-29 用户需求）──
## 默认关闭：不再在玩家视野外"维持人口"，只保留作者 SpawnZone + 尸潮/特感/Boss 事件。
## 打开后由 SpawnManager 按下面的人数区间补位（见 DirectorConfig 同名分组）。
var offscreen_refill_enabled: bool = false
var offscreen_refill_min: int = 4
var offscreen_refill_max: int = 10

# ═══════════════════════════════════════
# 子模块
# ═══════════════════════════════════════
var intensity_tracker: Node = null
var progress_tracker: Node = null     ## ProgressTracker 子节点（关卡进度估计，2026-10-25）
var progress_enabled: bool = true     ## false = 保持旧行为（进度因子恒定 0.3）
var progress_length_px: float = 0.0   ## 参考总路程（0 = 自动：出口直线 ×1.6）
var _progress_cache: float = -1.0     ## 上次喂给 IntensityTracker 的值（变化才推送）
var _enemy_scene: PackedScene = null
var _spawn_history: Array = []
var _last_scene: Node = null  ## 检测场景切换，读取 DirectorConfig
var current_config: DirectorConfig = null  ## 当前关卡的配置节点（ItemManager 读掉落池等用）

const NIGHT_DEBUG_DEFAULT_DARKNESS := 0.8  ## F8 调试开夜时，若本图未配 night_darkness 用的默认浓度


## F8 = 夜间视界调试开关（2026-09-16 测试用，不写进地图数据）：
## 当前图无 NightOverlay → 开夜（浓度取本图 night_darkness，未配则用 0.8）；
## 已有 → 关掉恢复白天。换图后按 DirectorConfig 重新生效。
## F3 = 导演调试面板（2026-10-25，见文件末尾 `debug_snapshot()`；导出包随 debug_enabled 关闭）。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_F8:
		_toggle_night_debug()
	elif key.keycode == DEBUG_PANEL_KEY:
		_toggle_debug_panel()


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

	# ── ProgressTracker（关卡进度估计，2026-10-25）──
	# 供 ① 紧张度的进度因子 ② Boss 发牌的路程闸（L4D flow）使用。
	# 必须在 IntensityTracker 之后创建：_ready 末尾要把进度喂给它。
	var pt_script = load("res://script/director/progress_tracker.gd")
	var pt := Node.new()
	pt.name = "ProgressTracker"
	pt.set_script(pt_script)
	add_child(pt)
	progress_tracker = pt

	if pc.has_signal("phase_changed"):
		pc.phase_changed.connect(_on_phase_changed)

	## ── L4D 模型开关同步（2026-10-24）──
	## 子模块自身的默认值是 false（方便回归 harness 单独实例化时走旧模型），
	## 实际运行一律以 Director 的 l4d_pacing 为准；没有 DirectorConfig 的图（安全屋等）
	## 也必须一致，否则会出现"Director 认为是新模型、生成器还是旧模型"的错配。
	_apply_l4d_model()

	if ResourceLoader.exists(ENEMY_SCENE_PATH):
		_enemy_scene = load(ENEMY_SCENE_PATH) as PackedScene
	else:
		printerr("[Director] enemy scene not found: %s" % ENEMY_SCENE_PATH)

	## 进度因子初值：不再写死 0.3（2026-10-25）。
	## 关掉 `progress_enabled` 的图维持旧行为（恒定 0.3），便于对照/回退。
	_sync_progress_to_intensity(true)

	print("[Director] initialized (Phase 4)")


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
	if _frozen_by_death:
		## 全灭结束（新场景实例已就位 / 检查点复活）→ 尸潮计时重新起算，见 _resume_after_death
		_resume_after_death()
	_frozen_by_death = false
	# 跳过濒死/死亡玩家（死亡动画播放中或场景重载中）；仍有队友存活时导演照常运行
	if player.get("_is_dying") == true:
		return
	## ── 队伍单位（2026-09-24）──
	## 本帧的「全体存活玩家」集合：刷怪锚点、紧张度、战斗状态一律以它为单位
	## （旧实现一律以 `_find_player()` = 座位 0 的主机为基准）。
	## 一帧只算一次后传给各消费者，避免在 60Hz 热路径上重复遍历玩家表。
	var teammates: Array[Node2D] = spawn_reference_players()
	if teammates.is_empty():
		## 兜底：极端时序下至少保留主参考。
		## ⚠ 必须另建局部数组 —— spawn_reference_players() 现在返回**共享的每帧缓存**，
		## 就地 append 会污染同一帧其它调用者拿到的同一份数组。
		teammates = [player]
	## ★玩家运动实测（2026-09-26）：必须在 pick_spawn_anchor / fs.update **之前**采样，
	## 否则本帧的锚点权重与前方方向用的还是上一帧的数据（首帧更是全 0）。
	sample_player_motion(teammates, delta)
	## 区域换区计量（L4D 的 Active Area Set 近似）：累计位移够了就补一层游荡者。
	_update_wander_advance(teammates)

	## ── 刷怪锚点（2026-09-23 多人修复）──
	## anchor = 本帧**刷怪与区域补齐**的圆心：L4D 式偏好"落单 / 走得远 / 移动中"的玩家。
	## 旧实现所有生成都以 _find_player()（座位 0 = 主机）为圆心 → 客户端跑在前面时，
	## 按"主机屏外"算出的取点正落在客户端画面里（用户实测「怪直接刷在客户端玩家面前」）。
	var anchor: Node2D = player
	var picked_anchor: Node2D = pick_spawn_anchor(teammates)
	if picked_anchor and is_instance_valid(picked_anchor):
		anchor = picked_anchor

	_check_scene_change()

	# Boss BGM 收尾（2026-09-15）：坦克全灭即停 —— 此前 _update_boss_music 定义了但
	# 从未被调用，坦克死后 BGM 一直播（盖住死亡音效、后续复活/防守阶段也还在响）。
	# 放在挂起闸门之前：防守战期间（director_suspended）打死的坦克也要正确收音。
	_update_boss_music()
	_update_calm_volume()

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
		## ★L4D 模型（2026-10-24）：区域补齐只在 **BUILD** 阶段跑。
		## 否则手工摆的 SpawnZone 会变成第二个"供水口"——峰值/喘息期照样往场上补，
		## 「峰值停手、喘息空窗」立刻失效。旧模型保持原行为（每帧补齐）。
		## 用上一帧缓存的阶段：本块在 pc.update 之前执行，差一帧对补齐无影响。
		if not l4d_pacing or _phase_cache == &"build":
			_update_ambient_zones(delta)

	# ── 紧张度（按全体存活玩家取「最吃紧的那位」，2026-09-24）──
	var prev_intensity: float = get_intensity()
	var new_intensity: float = prev_intensity
	if intensity_tracker and intensity_tracker.has_method("evaluate"):
		new_intensity = intensity_tracker.evaluate(teammates, delta)
		_update_combat_state(teammates)
		if abs(new_intensity - prev_intensity) > 0.05:
			intensity_changed.emit(new_intensity)

	# ── 回收（离玩家太远的敌人直接清除）──
	# 必须先于存活计数：清掉远处敌人之后，本帧所有生成闸门看到的才是真实余量。
	_update_recycle(delta)

	# ── 存活敌人计数 ──
	var alive_count: int = _count_alive_enemies()

	# ── 节奏控制 ──
	# spawn_map=false 时 Pacing 冻结（无尸潮节奏；phase 维持初值供 EventManager 读取）
	var pc: Node = get_node_or_null("PacingController")
	## 尸潮窗口是否仍在（SpawnManager 正在维持数量）：告诉节奏控制器别因"一时清空"提前结束峰值。
	## 取的是上一帧的状态；峰值刚进入那一帧 horde_active 还是 false，但 phase_elapsed=0 不会触发提前结束。
	var horde_running: bool = false
	var sm_probe: Node = get_node_or_null("SpawnManager")
	if sm_probe != null and sm_probe.has_method("is_horde_active"):
		horde_running = bool(sm_probe.call("is_horde_active"))
	if pc and pc.has_method("update") and spawn_map:
		## L4D 模型下 FADE 段需要知道"是否还有交战"（等自然收尾）。
		## `in_combat` 由 IntensityTracker 维护（任一存活玩家 500px 内有敌人）。
		var engaged: bool = false
		if intensity_tracker != null and is_instance_valid(intensity_tracker):
			engaged = bool(intensity_tracker.get("in_combat"))
		## 智能尸潮：把「本章新增击杀」喂给节奏控制器（杀得越多，压力条越快填满）
		## 附加参数（关闭尸潮 / 紧张度系数）先对齐一次，保证首帧就正确。
		_sync_horde_modifiers(pc)
		_feed_smart_horde_kills(pc, delta)
		pc.update(delta, new_intensity, alive_count, horde_running, engaged)
	var current_phase: StringName = &"cooldown"
	if pc:
		## ★必须走 get_phase_name()：2026-10-24 起枚举多了 FADE，
		## 按序号 match 会把 fade 误判成 cooldown（补位/音乐衔接全错）。
		if pc.has_method("get_phase_name"):
			current_phase = pc.call("get_phase_name")
		else:
			match pc.current_phase:
				0: current_phase = &"build"
				1: current_phase = &"peak"
				_: current_phase = &"cooldown"

	## 喘息期「走远即结束」（L4D Relax 的提前退出条件）
	_update_relax_advance(teammates, current_phase)
	_phase_cache = current_phase
	## 临峰预告必须在 pc/current_phase 都已求值之后（2026-10-25 修正作用域）
	_maybe_play_pre_peak_alert(current_phase, pc)

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
		## 画面外补怪关闭时，FrontSpawner 只保留"取点器"职责（尸潮/事件批仍要用它算落点），
		## 不再自己补位。旧模型（l4d_pacing=false）的补位入口就是这里。
		if fs and fs.has_method("update") and refill_allowed():
			fs.update(delta, anchor, alive_count, current_phase)

		# ── 特感编排：与常规刷怪同一闸门（防守战挂起期间冻结）──
		_update_specials(delta, anchor, current_phase)

	# ── Tank 编排 ──
	# 防守战期间（director_suspended）常规 Tank 冻结，但防守战专属 Tank 照常
	# （原作 147 图：Tank 是防守战核心压迫源，不能因为挂起导演就一起停掉）。
	# spawn_map=false 时常规 Tank 也停（列车台：开场静默，防守战才上 T-002）。
	_update_tanks(delta, anchor, current_phase, spawn_map)

	# ── 物品投放 ──
	var im: Node = get_node_or_null("ItemManager")
	if im and im.has_method("update"):
		im.update(delta, current_phase, alive_count)


# ═══════════════════════════════════════
# 全灭冻结（死亡收尾）
# ═══════════════════════════════════════

var _frozen_by_death: bool = false  ## 全员死亡触发的冻结标志（场景重载、玩家复活后自动解除）

## ── 每帧玩家集合缓存（2026-10-08 性能）──
## `_find_player()` / `spawn_reference_players()` 在一帧内被多处高频调用：
##   _process 顶部、`_is_walkable` 的**每次取点**（ring×angle 采样 + 36 次近点尝试）、
##   players_moving、nearest_player_distance、_count_alive_tanks、_nearby_spawn_blocked…
## 而旧实现每次调用都走 `Players.all_entities()` → **新分配 Array + `_prune_invalid()`**。
## 同一帧内玩家集合（哪些节点）不变，缓存一次即可。按 idle 帧号失效。
## ⚠ 返回的是**共享数组**，调用方**不得 append/erase**（只读遍历）。唯一会改写的
##   `_process` 兜底分支已改为另建局部数组（见该处注释）。
var _frame_players_frame: int = -1
var _frame_ref_players: Array[Node2D] = []
var _frame_all_entities: Array[Node2D] = []


## 本帧「可作刷怪/回收基准的存活玩家」（排除 _is_dying / _is_dead）。同一帧内共享。
func _cached_reference_players() -> Array[Node2D]:
	var fno: int = Engine.get_process_frames()
	if fno != _frame_players_frame:
		_frame_players_frame = fno
		_frame_ref_players = _build_reference_players()
		_frame_all_entities = Players.all_entities()
	return _frame_ref_players


## 本帧 `Players.all_entities()` 视图（仅排除 _is_dying，与旧 `_find_player()` 同口径）。
func _cached_all_entities() -> Array[Node2D]:
	_cached_reference_players()  ## 确保两个缓存同帧一起刷新
	return _frame_all_entities


func _build_reference_players() -> Array[Node2D]:
	var out: Array[Node2D] = []
	for e: Node2D in Players.all_entities():
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		out.append(e)
	return out

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
	## ★ 无论当时在哪个阶段都强制回 cooldown（2026-09-23 实测修复）：
	## 此前只在 peak 时收尾，于是"死亡时正处于 build/cooldown"时 **phase_elapsed 会跨场景重载保留**
	## （Director 是 autoload、PacingController 是它的子节点，重载不会重建它们）——
	## 复活后计时接着走，几秒内就推进到 peak，正是用户实测的「全体死亡复活后没多久就尸潮」。
	## force_cooldown 会清零 elapsed 并**重掷** cooldown 时长（DirectorConfig 的 cooldown_min~max），
	## 单机与联机（Host 权威）走的是同一条路径。
	var pc: Node = get_node_or_null("PacingController")
	if pc and pc.has_method("force_cooldown"):
		pc.force_cooldown()
	_reset_intensity()
	_stop_horde_music()
	## ★狂暴形态与目标锁定**在这里也显式清一遍**（2026-10-02）：它们平时由
	## `_on_phase_changed(cooldown)` 清，但只要 phase 没有真的切换（例如 PacingController
	## 已停在 cooldown、或 force_cooldown 发的信号被别处吞掉），死亡时就会残留 ——
	## 复活后全场丧尸仍是クリムゾンヘッド、且继续无条件追着玩家，观感就是"尸潮没结束"。
	## 两个函数都是幂等的，重复调用无副作用。
	_horde_rage = false
	_horde_berserk = false
	_set_all_enemies_rage(false)
	_release_horde_locks()
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


func _resume_after_death() -> void:
	## 全员复活后的第一帧（2026-09-23 实测修复「复活没多久就尸潮」）。
	## 死亡期间 _process 每帧早退 → 阶段计时不推进，但 phase/elapsed 会跨场景重载保留，
	## 因此这里再显式重掷一次 cooldown，保证"复活即从新的一段喘息开始"。
	## 同时归零紧张度：否则残留的高紧张度会让 cooldown 走"3 秒后提前结束"的捷径。
	var pc: Node = get_node_or_null("PacingController")
	if pc and pc.has_method("force_cooldown"):
		pc.force_cooldown()
	_reset_intensity()
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.has_method("reset_batch_tracking"):
		fs.call("reset_batch_tracking")  ## 复活瞬间的坐标跳变不该被当成"前进量"触发补位
	print("[Director] 全员复活：尸潮计时重新起算（cooldown 重掷 + 紧张度归零）")


func _reset_intensity() -> void:
	## 团灭收尾 / 复活 / 换图时把紧张度归零（IntensityTracker 是普通 Node，无 reset 接口）。
	if intensity_tracker == null or not is_instance_valid(intensity_tracker):
		return
	intensity_tracker.set("_current_intensity", 0.0)
	intensity_tracker.set("_raw_intensity", 0.0)


## ── 回标题：导演系统彻底收尾（2026-10-03 用户实测「打完一局回标题，再开一局刚出安全屋就尸潮」）──
## ★为什么必须单独有这个入口（不是 `_freeze_for_death` 就够了）：
##   Director 是 **autoload**，它的子节点 PacingController / SpawnManager / EventManager /
##   FrontSpawner / ItemManager 以及 `_horde_music_player` 全部跨场景存活 —— 换图/回标题
##   都不会重建它们。而 `_freeze_for_death()` 只在「全员死亡」时跑；**主动回标题时玩家没死**，
##   于是上一局的一切都原样带进下一局：
##   ① `_horde_music_player` 挂在 autoload 下 → 回标题后尸潮 BGM 继续播（用户实测）；
##   ② `PacingController.current_phase` 停在 peak、`phase_elapsed` 保留 → 新一局刚出安全屋
##      几秒内就进 peak（用户实测「刚出安全屋就直接尸潮」）；
##   ③ `_horde_rage` / 狂暴形态 / 目标锁定残留 → 复活后满场クリムゾンヘッド 且无条件追人；
##   ④ `EventManager._scripted_event_active` 残留 → 新一局 `HoldoutMachine.trigger()` 被
##      「已有剧本事件进行中」静默挡死（用户实测「防守战机器有时候开不了」）；
##   ⑤ `SpawnManager.enabled=false` / `PacingController.paused=true` 残留（由剧本事件设置，
##      事件被中止时才复原）→ 新一局常规刷怪与节奏全废。
## ★幂等：全程走「先判再动」，重复调用无副作用（标题画面/菜单里可能被调多次）。
func reset_for_title_return() -> void:
	## ①~⑧ 收尾「本局正在进行中的战斗状态」（与「进入安全屋」共用同一份逻辑）
	_reset_live_combat_state()
	## ⑨ 死亡冻结标志复位（否则新一局第一帧会被 _resume_after_death 之外的路径误判）
	_frozen_by_death = false
	## ⑩ 场景缓存标记（下一帧 _check_scene_change 会重新收集 TileMap / NoSpawnLayer；
	##   这里只把 _last_scene 清掉，强制它重新走一遍换图钩子）
	_last_scene = null
	# 敌人节点本身随场景释放，这里只清锁定引用，避免跨局指向已释放实例
	_boss_music_watchlist.clear()
	## ⑪ 关卡进度与 Boss 干旱计数归零（2026-10-25）：
	## 干旱保底是"同一战役内跨图"的概念，不该继承到下一个战役 ——
	## 否则上一局没出 Tank，新战役第一张图就被强行保底（用户实测「第一章必定有 Tank」的成因之一）。
	_tank_drought = 0
	_prev_map_had_tank = false
	_deck_initialized = false
	if progress_tracker != null and is_instance_valid(progress_tracker):
		progress_tracker.call("reset_for_scene", null)
		_sync_progress_to_intensity(true)
	print("[Director] 回标题收尾：剧本事件/防守战已中止、节奏回 cooldown、狂暴与 BGM 已清")


## ── 收尾「本局正在进行中的战斗状态」（2026-10-03 二次抽取）──
## 两个调用者，收尾动作相同、语义略有差异：
##   · `reset_for_title_return()` —— 回标题：跨局残留必须清干净；
##   · `_check_scene_change()` 检测到**进入安全屋** —— 安全屋是本局的中场休息，
##     必须把门外那一波尸潮彻底收掉。
##
## ★为什么「进安全屋」也必须走这里，而不是靠 `spawn_map=false` 冻结就够了：
##   `spawn_map=false` 只让 `_process` **不再推进** Pacing/SpawnManager/FrontSpawner，
##   **不会**把已经进入 peak 的状态收掉 —— `current_phase` 仍停在 peak、
##   `_horde_rage` / 目标锁定 / 尸潮 BGM（`_horde_music_player` 挂在 autoload 下，
##   不随场景释放）全部残留。玩家在安全屋里就听到尸潮 BGM 不停；
##   出门后 `spawn_map` 恢复 true，Pacing 从 peak 接着走 → 刚出安全屋直接又是一波尸潮。
##   （用户 2026-10-03 实测：「在安全屋里尸潮音乐还没结束」「出安全屋后直接尸潮」）
## ★进安全屋时 Pacing 的 `phase_elapsed` 被归零，而安全屋里 `pc.update()` 因
##   `spawn_map=false` 根本不跑 → 出门后从 0 起算，拥有一整段完整的喘息期。
## ★幂等：全程「先判再动」，重复调用无副作用。
func _reset_live_combat_state() -> void:
	## ① 剧本事件与防守战先收：它们是 ④⑤ 的来源，且持有 BGM / 挂起计数。
	abort_scripted_event()
	for machine: Node in get_tree().get_nodes_in_group("holdout_machine"):
		if is_instance_valid(machine) and machine.has_method("abort"):
			machine.call("abort")
	## ② 防守战挂起计数归零（否则新一局节奏永久冻结，见 set_director_suspended 的计数语义）
	director_suspended = false
	_suspend_count = 0
	## ③ 节奏：解除暂停 + 强制回 cooldown（清零 phase_elapsed 并重掷时长）
	var pc: Node = get_node_or_null("PacingController")
	if pc:
		pc.set("paused", false)
		if pc.has_method("force_cooldown"):
			pc.force_cooldown()
	## ④ SpawnManager：解除停用 + 复位尸潮窗口
	##（`on_phase_changed(cooldown)` 会清 _horde_active；经 force_cooldown 的 phase_changed
	##  信号本也会走到，但 _stop_horde_music 等分支不依赖信号，直接显式调更稳）
	var sm: Node = get_node_or_null("SpawnManager")
	if sm:
		if "enabled" in sm:
			sm.set("enabled", true)
		if sm.has_method("on_phase_changed"):
			sm.call("on_phase_changed", &"cooldown")
	## ⑤ 狂暴形态 / 目标锁定（与 _freeze_for_death 同款，幂等）
	_horde_rage = false
	_horde_berserk = false
	_set_all_enemies_rage(false)
	_release_horde_locks()
	## ⑥ BGM：尸潮 + Boss 都收（判据见 _stop_horde_music 的 stream_paused 铁律）
	_stop_horde_music()
	stop_boss_music(false)
	## ⑦ 紧张度归零（残留高紧张度会让 cooldown 走「3 秒提前结束」捷径）
	_reset_intensity()
	## ⑦b 喘息期前进量快照（换图后旧 instance_id 全部失效）
	_relax_anchor.clear()
	## ⑦c 换区计量（游荡者补层）
	_wander_advance = 0.0
	_wander_positions.clear()
	## ⑧ 前方补位记账（_batch_player_pos 里是旧图玩家的 instance_id）
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.has_method("reset_batch_tracking"):
		fs.call("reset_batch_tracking")


func _on_phase_changed(phase: StringName) -> void:
	## 节奏阶段切换 → 通知 SpawnManager + 发出信号
	print("[Director] pacing phase → %s" % phase)
	debug_event("阶段 → %s" % phase)
	_music_phase = phase
	pacing_phase_changed.emit(phase)

	var sm: Node = get_node_or_null("SpawnManager")
	if sm and sm.has_method("on_phase_changed"):
		sm.on_phase_changed(phase)

	## 可听化（2026-10-25）：阶段决定音乐 —— 加压/喘息铺底，峰值让位给尸潮曲，余韵回到铺底。
	if phase == &"build":
		_play_calm_music()
	elif phase == &"peak":
		_stop_calm_music()
		## ★附加参数「尸潮狂暴」（2026-10-31）：只控制**形态切换**。
		## 窗口标志 `_horde_rage` 与形态标志 `_horde_berserk` 必须分开 ——
		## 前者决定「新刷的敌人是否直接锁定玩家」，关掉狂暴**绝不能**连带关掉锁定。
		_horde_rage = true
		_horde_berserk = _berserk_enabled()
		if _horde_berserk:
			_set_all_enemies_rage(true)   ## 尸潮触发 → 僵尸切换クリムゾンヘッド（狂暴）
		else:
			print("[Director] 尸潮狂暴已关闭（附加参数）：保持普通形态，但目标锁定照常")
		_lock_all_enemies_for_horde() ## 尸潮触发 → 附近全部丧尸直接追击最近玩家（对齐防守战）
		_play_horde_music()
		## 临峰已预告过（5 秒内）就不要再响一次
		if Time.get_ticks_msec() - _pre_peak_alert_at_msec >= 5000:
			_play_horde_alert()
		horde_started.emit()
	elif phase == &"cooldown" or phase == &"fade":
		_play_calm_music()
		_horde_rage = false
		_horde_berserk = false
		_set_all_enemies_rage(false)  ## 尸潮结束 / 进入余韵 → 恢复普通形态
		_release_horde_locks()        ## 解除目标锁定，恢复普通 AI
		_stop_horde_music()
		horde_ended.emit()


## ── 尸潮 BGM（DirectorConfig「音乐 — 尸潮」组；默认 = 原作ラッシュ１）──
var _horde_music_player: AudioStreamPlayer = null
## 本次播放实际用到的池内下标（-1 = 走的单曲）。
## 曲目本身来自 `Global.horde_music_track`（一局固定一首），这里存的是「按当前图的池
## 取模之后」的真实下标 —— 广播给 Client 的也是它。
var _horde_track_index: int = -1
## 内置默认随机池（2026-10-29 用户需求：原作尸潮音乐是随机的）。
## 写成**路径**而不是 preload：6 首 mp3 合计约 10MB，preload 会在脚本加载时就全部驻留内存；
## 这里只在抽到某一首时才 load，且用 `_default_horde_cache` 缓存，不重复解码。
## 池子的优先级：DirectorConfig.horde_music_pool（非空）→ 本默认池 → horde_music 单曲。
const DEFAULT_HORDE_POOL: Array[String] = [
	"res://music/ラッシュ１.mp3",
	"res://music/ラッシュ２.mp3",
	"res://music/ラッシュ３.mp3",
	"res://music/ラッシュ４.mp3",
	"res://music/ラッシュ５.mp3",
	"res://music/ラッシュ６.mp3",
]
static var _default_horde_cache: Dictionary = {}

## ── 常态铺底 BGM（Build / Relax，2026-10-25 可听化第一步）──
## 与尸潮/Boss 曲的区别：它是"低张力的底"，**不随强度变化**；尸潮或 Boss 一响就让位。
## 只在本机播放（音乐属于个人混音，L4D 也是每人一套），不做联机广播。
var _calm_music_player: AudioStreamPlayer = null
var _calm_tween: Tween = null
## 铺底随紧张度抬升的音量上限（dB）：intensity 0→1 对应 +0→+n dB（2026-10-25 第二步）
var calm_music_intensity_boost_db: float = 7.0
var _pre_peak_alert_at_msec: int = -999999   ## 临峰预警音的时间戳（防与峰值同帧重复播）


## 铺底默认曲（2026-10-25）：写成运行时路径而不是 @export 默认值 ——
## 文件缺失时只是"没声音"，不会让整份脚本编译失败。
const DEFAULT_CALM_MUSIC_BUILD := "res://music/bh quarantine 01.mp3"
const DEFAULT_CALM_MUSIC_RELAX := "res://music/da quarantine 01.mp3"
var _music_phase: StringName = &"cooldown"


## 取当前阶段该用的铺底曲：配置字段优先 → 内置默认（文件存在才用）→ null。
func _calm_stream_for_phase(phase: StringName) -> AudioStream:
	var is_relax: bool = phase == &"cooldown" or phase == &"fade"
	var cfg_stream: AudioStream = null
	if current_config != null:
		cfg_stream = current_config.calm_music_relax if is_relax else current_config.calm_music
	if cfg_stream != null:
		return cfg_stream
	var path: String = DEFAULT_CALM_MUSIC_RELAX if is_relax else DEFAULT_CALM_MUSIC_BUILD
	if ResourceLoader.exists(path):
		return load(path) as AudioStream
	return null


func _play_calm_music() -> void:
	var stream: AudioStream = _calm_stream_for_phase(_music_phase)
	if stream == null:
		return
	if _boss_music_active:
		return   ## Boss 优先
	if _horde_music_player != null and _horde_music_player.playing:
		return   ## 尸潮曲还在响 → 不抢
	if _calm_music_player == null:
		_calm_music_player = AudioStreamPlayer.new()
		_calm_music_player.name = "CalmMusicPlayer"
		_calm_music_player.bus = &"Music"
		add_child(_calm_music_player)
	if _calm_music_player.playing and _calm_music_player.stream == stream:
		return
	_calm_music_player.stop()
	## ★铺底必须是**循环**的（2026-10-25）：L4D 的 calm 是持续底噪，不是一段过场。
	## MP3/OGG 导入后 `loop` 默认 false → 播完一遍就静音，听起来像"音乐坏了"。
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_calm_music_player.stream = stream
	## 淡入（2026-10-25 用户要求）：从目标音量 -24dB 起 0.8 秒抬到目标，避免硬切的"啪"声。
	var target_db: float = current_config.calm_music_volume_db if current_config else -14.0
	_calm_music_player.volume_db = target_db - 24.0
	_calm_music_player.play()
	if _calm_tween != null and _calm_tween.is_valid():
		_calm_tween.kill()
	_calm_tween = create_tween()
	_calm_tween.tween_property(_calm_music_player, "volume_db", target_db, 0.8)


## 铺底随紧张度抬音量（2026-10-25 第二步）：不是硬切，而是在 base 上做连续偏移。
## 只在"淡入淡出补间未在跑"时接管音量，避免和 tween 抢同一个属性。
func _update_calm_volume() -> void:
	if _calm_music_player == null or not _calm_music_player.playing:
		return
	if _calm_tween != null and _calm_tween.is_valid():
		return
	var base_db: float = current_config.calm_music_volume_db if current_config else -8.0
	var boost: float = calm_music_intensity_boost_db * clampf(get_intensity(), 0.0, 1.0)
	_calm_music_player.volume_db = base_db + boost


## 临峰预告（2026-10-25 第二步其二）：BUILD 末段提前约 2 秒给预警音。
## 原来 `horde_alert_sound` 和峰值**同帧**播，玩家听到"预警"时尸潮已经砸下来了，预告失去意义。
## 这里在 build 剩余 ≤2 秒时先响一次；峰值分支用时间戳去重，不会连响两次。
func _maybe_play_pre_peak_alert(phase: StringName, pc: Node) -> void:
	if phase != &"build" or pc == null:
		return
	var dur: float = float(pc.get("phase_duration"))
	var el: float = float(pc.get("phase_elapsed"))
	if dur < 8.0:
		return   ## 太短的 build 来不及形成"预告感"
	if el < dur - 2.0:
		return
	if Time.get_ticks_msec() - _pre_peak_alert_at_msec < 5000:
		return
	_pre_peak_alert_at_msec = Time.get_ticks_msec()
	_play_horde_alert()
	print("[Director] 临峰预告：约 %.1fs 后进入峰值" % maxf(dur - el, 0.0))


func _stop_calm_music() -> void:
	if _calm_music_player == null:
		return
	if not _calm_music_player.playing and not _calm_music_player.stream_paused:
		return
	## 淡出 0.5 秒再停（进峰值时不要硬切）
	if _calm_tween != null and _calm_tween.is_valid():
		_calm_tween.kill()
	_calm_tween = create_tween()
	_calm_tween.tween_property(_calm_music_player, "volume_db",
		_calm_music_player.volume_db - 30.0, 0.9)
	_calm_tween.tween_callback(Callable(_calm_music_player, "stop"))


## 解析本次可用的随机池：配置池（非空）→ 内置默认池（按需 load）→ 空（= 走单曲）。
func _horde_pool() -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	if current_config != null:
		for s: AudioStream in current_config.horde_music_pool:
			if s != null:
				out.append(s)
	if not out.is_empty():
		return out
	for path: String in DEFAULT_HORDE_POOL:
		var hit: Variant = _default_horde_cache.get(path)
		if hit is AudioStream:
			out.append(hit as AudioStream)
			continue
		if not ResourceLoader.exists(path):
			continue   ## 缺文件只是少一首，不让整局没声音
		var st: AudioStream = load(path) as AudioStream
		if st == null:
			continue
		_default_horde_cache[path] = st
		out.append(st)
	return out


## 本局曲目的抽签入口（Global.init_new_game / 读旧档缺键时调用）。
## 那时还没进图、拿不到 DirectorConfig 的自定义池，所以按**内置默认池**的大小抽；
## 播放时用 `% 池大小` 取，任何一张图把池改小了也不会越界。
func roll_new_run_horde_track() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("roll_horde_music_track"):
		return
	g.call("roll_horde_music_track", maxi(DEFAULT_HORDE_POOL.size(), 1))


## 本局固定曲目在池里的下标（Global 存的是"整局一首"）。
## 旧存档/极端情况下还没抽 → 当场补抽一次，保证开局就定下来。
func _run_horde_track() -> int:
	var g: Node = get_node_or_null("/root/Global")
	if g == null:
		return -1
	var idx: int = int(g.get("horde_music_track"))
	if idx < 0:
		roll_new_run_horde_track()
		idx = int(g.get("horde_music_track"))
	return idx


## track_index >= 0：联机时 Host 定的曲目（Client 照播，保证两端同曲）。
## resume = true：Boss 打完后接回尸潮 —— 曲目本来就是全局固定的，这里只为日志区分。
## ★2026-10-29 改版：曲目**一局一首**（Global.horde_music_track，开局抽一次），
## 不再是每次进峰值重抽；同一局里所有尸潮都是同一首。
func _play_horde_music(track_index: int = -1, resume: bool = false) -> void:
	if _boss_music_active:
		return  ## Boss BGM 优先级更高：Boss 存活期间尸潮不抢 BGM（Boss 灭后自动接回）
	var cfg: DirectorConfig = current_config
	# 关闭随机 = 不建池，直接走旧路径（cfg.horde_music）
	var pool: Array[AudioStream] = []
	if cfg == null or cfg.horde_music_randomize:
		pool = _horde_pool()

	var stream: AudioStream = null
	if not pool.is_empty():
		var idx: int = track_index
		if idx < 0:
			idx = _run_horde_track()
		if idx >= 0:
			_horde_track_index = idx % pool.size()
			stream = pool[_horde_track_index]
	if stream == null:
		_horde_track_index = -1
		if cfg != null:
			stream = cfg.horde_music   ## 随机关 / 池为空 → 旧行为：单曲
	if not stream:
		return
	if not _horde_music_player:
		_horde_music_player = AudioStreamPlayer.new()
		_horde_music_player.name = "HordeMusicPlayer"
		_horde_music_player.bus = &"Music"
		add_child(_horde_music_player)
	_horde_music_player.stop()
	_horde_music_player.stream = stream
	_horde_music_player.volume_db = current_config.horde_music_volume_db if current_config else 0.0
	_horde_music_player.play()
	_announce_music("horde", true, _horde_track_index)
	if _horde_track_index >= 0:
		print("[Director] 尸潮 BGM 开始（本局固定 #%d/%d%s）" % [
			_horde_track_index + 1, pool.size(), "，Boss 后接回" if resume else ""])
	else:
		print("[Director] 尸潮 BGM 开始")

func _stop_horde_music() -> void:
	if _horde_music_player == null:
		return
	## ★判据必须带 `stream_paused`（项目铁律「`stream_paused` 时 `playing` 为 false」）：
	## 尸潮 BGM 会被 Boss BGM 用 `stream_paused` 挂起，这时 `playing` 返回 **false** →
	## 只判 `playing` 就会**漏停**，于是死亡收尾/尸潮结束时它一直在（或复活后被恢复播放），
	## 表现为「死亡后尸潮音乐还在响」「尸潮好像永不停」（2026-10-02 用户实测）。
	if not (_horde_music_player.playing or _horde_music_player.stream_paused):
		return
	_horde_music_player.stop()
	_announce_music("horde", false)
	print("[Director] 尸潮 BGM 停止")


## ── 尸潮预警音效（DirectorConfig「音效 — 尸潮预警」；2026-09-30 用户需求）──
## 尸潮（Peak）**开始的那一刻**响一次，与 BGM 并行（预警音压不住 BGM 的起播）。
## 与 BGM 的两点差异：
## · **不看 Boss 优先级** —— Boss 在场时 BGM 不换，但「尸潮来了」这个提示仍要给玩家；
## · **不是循环** —— 一次性播放，尸潮结束时无需停止。
## 联机：本函数自身不判端，Host 与 Client 都走它；广播由 `_announce_music` 里
## 的 Client 早退闸负责（Client 调用时不会再广播回去 → 不会回环）。
func _play_horde_alert() -> void:
	var stream: AudioStream = current_config.horde_alert_sound if current_config else null
	if not stream:
		return
	var scene: Node = get_tree().current_scene if get_tree() != null else null
	if scene == null:
		return
	Global.play_sfx_managed(stream, scene)
	_announce_music("horde_alert", true)
	print("[Director] 尸潮预警音效")


## ── Boss BGM（DirectorConfig「音乐 — Boss」组；2026-09-14 用户定稿）──
## 优先级最高：Boss（tank_enemies 成员 / BossEncounter 定点遭遇）登场时
## 立即停尸潮 BGM 改播 Boss BGM；Boss 全灭自动停止，若尸潮仍在 peak 则接回尸潮 BGM。
## 防守战 BGM 不停播而是 stream_paused 挂起（HoldoutMachine 监听 boss_music_changed）。
signal boss_music_changed(active: bool)

var _boss_music_player: AudioStreamPlayer = null
var _boss_music_active: bool = false
## 「boss_music 未配置」只告警一次：这是"坦克登场却没音乐"的直接原因（2026-10-19），
## 但每次坦克刷新都 push 会刷屏，因此只在首次留痕。
var _boss_music_missing_warned: bool = false
## 需要由本模块监视存活的 Boss 实体（含未入 tank_enemies 组的 BossEncounter 生成物）。
var _boss_music_watchlist: Array[Node2D] = []

## Boss 登场时调用（_spawn_tank / BossEncounter.trigger）。
## watch = 要监视存活的 Boss 实体；已激活时刷新监视列表但不重播（多 Boss 连场不切歌）。
func play_boss_music(watch: Node2D = null) -> void:
	var stream: AudioStream = current_config.boss_music if current_config else null
	if stream == null:
		## ★不要静默早退：旧日志里"坦克出现了但没音乐"完全查不到原因。
		## 默认值已在 DirectorConfig 设为「ボス１」；走到这里说明该图把它清空了
		## 或 current_config 还没应用（Client 首个 BGM 包早到）。
		if not _boss_music_missing_warned:
			_boss_music_missing_warned = true
			push_warning("[Director] current_config.boss_music 为空 → 坦克/Boss 登场不播 BGM（DirectorConfig「音乐 — Boss」组默认应为 ボス１）")
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
	_announce_music("boss", true)
	print("[Director] ★ Boss BGM 开始")

## Boss BGM 是否正在播。防守战（HoldoutMachine）BGM 的互斥判定用：
## 那台机器必须在「开始/重播」时也查一次，不能只依赖 boss_music_changed 信号
## （信号只在状态切换时发，而 play() 会复位 stream_paused）——见 holdout_machine。
func is_boss_music_active() -> bool:
	return _boss_music_active


## Boss 全灭 / 全员死亡冻结 / 换图时调用。resume_horde=true 且尸潮仍在 peak 时接回尸潮 BGM。
## ★2026-10-19 加固：不再以 `_boss_music_active` 作为唯一早退条件 ——
## 状态位与播放器短暂不同步时（例如 play() 后立刻收到结束），旧写法会直接 return，
## 坦克已经没了 BGM 却还在响。现在先无条件 stop 播放器，只有"确实由激活态转入停止"
## 才广播/发信号，避免 Client 侧无意义的状态抖动。
func stop_boss_music(resume_horde: bool = false) -> void:
	var was_active: bool = _boss_music_active
	_boss_music_active = false
	_boss_music_watchlist.clear()
	if _boss_music_player:
		_boss_music_player.stop()
	if not was_active:
		return
	boss_music_changed.emit(false)
	_announce_music("boss", false)
	print("[Director] Boss BGM 停止")
	if resume_horde:
		var pc: Node = get_node_or_null("PacingController")
		if pc and pc.get("current_phase") == 1:  # 1 = peak
			## resume：沿用本轮尸潮已经抽到的曲目，避免 Boss 一死就换歌
			_play_horde_music(-1, true)


## ── 联机：BGM 事件转发（A6，2026-09-18）──
## Client 的 _process 整体早退 → 尸潮/Boss BGM 从不播放。Host 在真正的起停
## 发生处经 NetworkWorld 广播 music key（"horde"/"boss"），音源由 Client 从
## 本地 current_config 解析（场景切换钩子对所有 peer 生效 → Client 也有值），
## 资源不经网络传输（白名单铁律）。
## `track_index`（2026-10-29）：尸潮改随机池后，**抽签结果必须由 Host 决定并广播** ——
## 两端各自随机就会各播各的。Client 拿下标到本地池里取同一首；-1 = 没随机（单曲）。
func _announce_music(music_key: String, active: bool, track_index: int = -1) -> void:
	# Client 不会走到这里（_process 早退），此闸兜底防御 + 避免表现回环二次广播。
	if _is_network_client_session():
		return
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null:
		return
	var world: Node = scene.find_child("NetworkWorld", true, false)
	if world and world.has_method("announce_director_music"):
		world.call("announce_director_music", music_key, active, track_index)


## Client 收到 NetworkWorld 的 BGM 事件后调用：复用既有起停函数——音源/音量
## 从本地 current_config 解析，_boss_music_active 状态与 boss_music_changed
## 信号一并维护（Client 的 HoldoutMachine 靠该信号挂起/恢复防守战 BGM）。
## reliable RPC 保序：Host 的 boss=false → horde=true 序列在 Client 以同序重放。
func apply_network_music(music_key: String, active: bool, track_index: int = -1) -> void:
	match music_key:
		"horde":
			if active:
				_play_horde_music(track_index)
			else:
				_stop_horde_music()
		"horde_alert":
			## 一次性音效（2026-09-30）：Host 在尸潮 peak 开始时广播，Client 本地响一次。
			## `active` 恒为 true（没有"停止"语义），Client 侧不会再广播（_announce_music 早退）。
			if active:
				_play_horde_alert()
		"boss":
			if active:
				play_boss_music(null)  # watch 监视是 Host 职责，Client 只管播放
			else:
				stop_boss_music(false)  # 尸潮接回由随后到达的 horde=true 事件驱动
		_:
			push_warning("[Director] 未知 BGM key: %s" % music_key)

## 终章演出 / 章节结算开始时调用：一次性收掉「战斗 BGM」（Boss + 尸潮）。
## Boss/尸潮 BGM 挂在本 autoload 下、**不随场景释放**，而 AudioStreamPlayer 在
## `get_tree().paused` 期间照常出声（播放由 AudioServer 驱动）→ 若不收，
## 结算页的 summary_music 与 ED 的 l3d_ed 会与它叠着响（用户 2026-09-26 实测
## 「结算里 Tank BGM 与防守战 BGM 同时播放」）。Host 调用会经 _announce_music
## 广播，Client 端一并收。
func stop_battle_music() -> void:
	stop_boss_music(false)
	_stop_horde_music()


## 每帧调用：Boss 全灭（tank 组空 + 监视列表全灭）→ 收 Boss BGM。
func _update_boss_music() -> void:
	if not _boss_music_active:
		return
	if _count_alive_tanks() > 0:
		return
	## ⚠ 先剔已释放引用再 filter：数组里含 **已释放 Object** 时，带类型标注的 lambda
	## 参数转换会失败（`Cannot convert argument 1 from Object to Object`，2026-10-11 教训）。
	_boss_music_watchlist = _prune_freed_nodes(_boss_music_watchlist)
	_boss_music_watchlist = _boss_music_watchlist.filter(func(e: Node2D) -> bool:
		return e.get("_is_dead") != true and e.get("_is_dying") != true)
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
	## 防守战不读「尸潮狂暴」开关：它的狂暴是剧本演出的一部分（2026-10-31）
	_horde_berserk = active
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
	_warn_if_spawn_visible(pos, "common")

	var enemy = _enemy_scene.instantiate()
	enemy.global_position = pos
	## 僵尸变体：按关卡池权重随机选一种，注入外观与数值。
	## 必须在 add_child 之前（enemy._ready() 里 _refresh_sprite 用到 walk_texture）。
	## 注入逻辑统一在 ZombieVariant.apply_to_enemy —— Host 生成与联机 Client 重建共用同一份。
	if not _zombie_pool.is_empty():
		var zv_res: Resource = _pick_zombie_variant()
		if zv_res:
			var zv := zv_res as ZombieVariant
			if zv:
				zv.apply_to_enemy(enemy)
				# Host 侧登记：联机 spawn 快照经 enemy.get_network_variant_id() 反查白名单 id 下发。
				enemy.variant_data = zv
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
	## ★尸潮/防守战窗口内刷出的敌人（2026-10-31 修复）：
	##   · **目标锁定**只看窗口（`_horde_rage`）—— 这是「尸潮感」的来源，不能被狂暴开关影响；
	##   · **狂暴形态**只看 `_horde_berserk`（附加参数可关，防守战恒开）。
	## 顺序不能反：`set_rage` 依赖 `_refresh_sprite` 已就绪（add_child 之后）。
	if _horde_rage:
		if _horde_berserk:
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
	_warn_if_spawn_visible(pos, "special")

	var enemy = _enemy_scene.instantiate()
	enemy.global_position = pos
	# 注入必须全部发生在 add_child 之前：enemy._ready() 里 _refresh_sprite 就要用 walk_texture。
	# 注入逻辑统一在 SpecialEnemyData.apply_to_enemy —— Host 生成与联机 Client 重建共用同一份。
	data.apply_to_enemy(enemy)
	# Host 侧登记：联机 spawn 快照经 enemy.get_network_special_id() 反查白名单 id 下发。
	enemy.special_data = data
	enemy.initial_facing = facing if facing >= 0 else _calc_facing_toward_player(pos)
	decor_layer.add_child(enemy)
	# 入树后再进组：同屏互斥计数（_update_specials）依赖本组。
	enemy.add_to_group("special_enemies")
	## ★Boss 级特感（ネメシス / バイオゲラス / ブラックタイガー，2026-10-19）：
	## 与タイラント同级 —— 额外入 tank_enemies：
	##   · `_count_alive_tanks()` 统计 → 与坦克共用「同屏最多一只 Boss」；
	##   · 子弹/背刺按 Boss 规则结算（即死 ×、必杀 ×）；
	##   · `play_boss_music` 复用 Boss BGM 与「Boss 灭后接回尸潮」的既有链路。
	if data.boss_tier:
		enemy.add_to_group("tank_enemies")
		tank_spawned.emit(String(data.id))
		play_boss_music(enemy)

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
	## 锚点 = 本批刷怪的目标玩家（L4D 式偏好"落单 / 走得远"的那位），
	## 不再是固定的座位 0（主机）—— 见 pick_spawn_anchor 的成因注释。
	var player: Node2D = pick_spawn_anchor()
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
		## 带内目标数按真人数放大（2026-09-25）：这里是散兵/尸潮/事件批的**共同闸门**，
		## 只放大 FrontSpawner 内部而不放大这道闸门 = 倍率被原地掐死（1 人和 4 人一样稀）。
		var target: int = Players.scale_spawn_count(int(fs.get("target_ahead")))
		# 前方带里已经够了 → 一只都不刷（这是"别太密"的主要闸门）
		if ahead >= target:
			return out
		want = mini(want, target - ahead)

	var placed: Array[Vector2] = []
	for _i: int in range(want):
		var pos: Vector2 = Vector2.ZERO
		if fs:
			pos = fs.pick_ahead_position(player)
		if pos == Vector2.ZERO:
			# FrontSpawner 被禁用 / 找不到合适点时，退回旧的作者刷新点逻辑
			pos = _pick_spawn_position(player, _get_nearby_spawn_points(player, _get_valid_spawn_points(player, decor_layer)), 0)
			if pos == Vector2.ZERO:
				break
		if not _batch_accepts(placed, pos):
			continue   ## 本批这个角已经放了 3 只 → 跳过，别堆成一坨
		var enemy: Node2D = spawn_enemy(_add_spawn_scatter(pos), decor_layer, -1)
		if enemy:
			out.append(enemy)
			placed.append(pos)
	return out


## ★尸潮入场（L4D 模型，2026-10-24）：一次性把整波敌人放到「前方屏外」与「背后屏外」。
##
## 与 `spawn_ahead_batch` 的关键差别：**不过任何数量闸门 / 附近闸 / 带内目标**。
## 尸潮是「事件」，不是「补位」—— 被闸门掐掉就变成"峰值潮水没来"，玩家只会觉得卡。
## 落点找不到时宁缺不挤（返回实际落地数，由 SpawnManager 打日志）。
func spawn_mob_batch(front_count: int, behind_count: int) -> int:
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		return 0
	var player: Node2D = pick_spawn_anchor()
	if player == null:
		return 0
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs == null:
		return 0
	var spawned: int = 0
	var placed: Array[Vector2] = []
	## 先落地"背后"那一批：玩家此刻正朝前看，背后涌来的存在感最强（L4D 的 75%）。
	for _i: int in range(maxi(behind_count, 0)):
		var back_pos: Vector2 = fs.pick_behind_position(player)
		if back_pos == Vector2.ZERO:
			continue
		if not _batch_accepts(placed, back_pos):
			continue
		if spawn_enemy(_add_spawn_scatter(back_pos), decor_layer, -1) != null:
			spawned += 1
			placed.append(back_pos)
	for _i: int in range(maxi(front_count, 0)):
		var front_pos: Vector2 = fs.pick_ahead_position(player)
		if front_pos == Vector2.ZERO:
			continue
		if not _batch_accepts(placed, front_pos):
			continue
		if spawn_enemy(_add_spawn_scatter(front_pos), decor_layer, -1) != null:
			spawned += 1
			placed.append(front_pos)
	if spawned > 0:
		debug_event("MOB 落地 %d 只（前 %d / 后 %d）" % [spawned, front_count, behind_count])
	return spawned


## ★尸潮补位取点（2026-10-31 用户需求：尸潮时直接在玩家画面外补点）。
## 与 `spawn_mob_batch` 的分工：那个是**入场那一波**（固定前/后比例，讲观感），
## 这个是**峰值期间的持续补位**（讲"无论如何都补得上"）。
## 取点顺序：前方 → 背后 → **360° 环带**。前两条保持"从前面压过来 / 背后包抄"的观感，
## 环带是兜底 —— 地图没有作者点位、玩家又跑得飞快时，只有它能保证每批都落地。
func spawn_horde_surround(count: int, front_ratio: float = 0.6) -> int:
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		return 0
	var player: Node2D = pick_spawn_anchor()
	if player == null:
		return 0
	var total: int = maxi(count, 0)
	if total <= 0:
		return 0
	var fs: Node = get_node_or_null("FrontSpawner")
	var front_n: int = int(round(float(total) * clampf(front_ratio, 0.0, 1.0)))
	var spawned: int = 0
	var placed: Array[Vector2] = []
	for i: int in range(total):
		var pos: Vector2 = Vector2.ZERO
		if fs != null:
			if i < front_n:
				pos = fs.pick_ahead_position(player)
				if pos == Vector2.ZERO:
					pos = fs.pick_behind_position(player)
			else:
				pos = fs.pick_behind_position(player)
				if pos == Vector2.ZERO:
					pos = fs.pick_ahead_position(player)
			if pos == Vector2.ZERO and fs.has_method("pick_surround_position"):
				pos = fs.call("pick_surround_position", player)
		if pos == Vector2.ZERO:
			continue
		if not _batch_accepts(placed, pos):
			continue
		if spawn_enemy(_add_spawn_scatter(pos), decor_layer, -1) != null:
			spawned += 1
			placed.append(pos)
	return spawned


## 威胁圈内存活敌人数（**含已经贴脸的**）—— 供 SpawnManager 的预算闸门使用。
## 旧口径只数 360~560px 环带，敌人走近就"离开名额"，是原地打不完的根源之一。
func count_threat_near_players() -> int:
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs != null and fs.has_method("count_threat"):
		return int(fs.call("count_threat"))
	return 0


# ── 作者区域缓存（2026-10-30 混合补位）──
## 用 instance_id 而不是 Node 引用做缓存键：换图后旧场景会被释放，
## 直接比较 Node 引用可能踩到"已释放实例"。
var _zone_cache_scene_id: int = 0
var _zone_cache: Array[SpawnZone] = []


func _refresh_zone_cache() -> void:
	var tree: SceneTree = get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	var scene_id: int = scene.get_instance_id() if scene != null else 0
	if scene_id == _zone_cache_scene_id:
		return
	_zone_cache_scene_id = scene_id
	_zone_cache.clear()
	if scene == null:
		return
	var nodes: Array = []
	_collect_spawn_nodes(scene, nodes)
	for sp: Node in nodes:
		if sp is SpawnZone and (sp as SpawnZone).enabled:
			_zone_cache.append(sp as SpawnZone)


## 当前地图是否有**启用中的** SpawnZone。
## 缓存按场景实例失效 —— SpawnZone 是作者摆放的，运行时不动态增删；
## 换图/重载会换场景实例，下一次查询自动重扫。
func has_enabled_spawn_zones() -> bool:
	_refresh_zone_cache()
	for zone: SpawnZone in _zone_cache:
		if is_instance_valid(zone) and zone.enabled:
			return true
	return false


## 当前玩家附近是否有可覆盖的 SpawnZone：区域中心到最近玩家的距离 ≤ 区域半径 + radius。
## 混合补位用它区分「玩家在区域覆盖范围内（区域先补，屏外只补到下限）」
## 和「地图虽然有区域、但玩家这一带没有（屏外照旧补满迟滞带）」。
func has_spawn_zone_near_players(radius: float = 600.0) -> bool:
	_refresh_zone_cache()
	for zone: SpawnZone in _zone_cache:
		if not is_instance_valid(zone) or not zone.enabled:
			continue
		var d: float = nearest_player_distance(zone.global_position)
		if d <= zone.get_zone_radius() + maxf(radius, 0.0):
			return true
	return false


## 区域覆盖判定半径 = 当前威胁圈半径（由 DirectorConfig 注入 FrontSpawner，默认 600）。
func _zone_probe_radius() -> float:
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs != null and fs.get("threat_radius") != null:
		return maxf(0.0, float(fs.get("threat_radius")))
	return 600.0


## ★区域游荡者（wanderers）：在玩家四周（屏外、360° 整圈）铺一层徘徊的丧尸。
##
## 为什么要这个（2026-10-24 用户实测「进图跑 10 秒一只丧尸都没有」）：
##   1. 当时的地图**没有任何 SpawnZone / SpawnPoint**（街道图实测 0 个）→ 作者点路径全程失效；
##   2. 只剩"前方扇区 360~560px"这一条取点路径 → 街道图一拐弯就取不到点，预算花不出去；
##   3. L4D 的区域本来就是"已经有一群在晃"，不是等你走到才从正前方刷出来。
## 这三个叠加的结果就是"路上空无一人，只有特感"。本函数补的就是这一层人口。
## ★2026-10-30：玩家附近有 SpawnZone 覆盖时走混合补位 —— 游荡者只补到屏外下限，
## 局部密度交给区域，避免"区域补一批 + 游荡者再补到 6 只"叠加；
## 地图有区域但玩家这一带没有覆盖时，仍按常驻目标补，走廊不会空。
func seed_wanderers(count: int) -> int:
	## 总开关关闭 / 本局「强制不加压」→ 一只都不铺（否则"进图先铺 6~9 只"仍是画面外补怪）。
	if not refill_allowed():
		return 0
	var decor_layer: Node = _find_decor_layer()
	if decor_layer == null:
		return 0
	## ★密度自适应（2026-10-24 用户提议）：先数威胁圈里已有多少，只补差额。
	## 效果：某个角落一直空 → 补到目标；某片已经一堆 → 一只都不加。
	## 这比"固定补 N 只"稳定得多，也不会在窄图里越堆越挤。
	var target: int = Players.scale_area_count(maxi(wander_target_near, 1))
	if has_enabled_spawn_zones() and has_spawn_zone_near_players(_zone_probe_radius()):
		target = mini(target, Players.scale_ambient_count(maxi(offscreen_refill_min, 0)))
	var threat: int = count_threat_near_players()
	var deficit: int = target - threat
	if deficit <= 0:
		return 0
	var want: int = mini(maxi(count, 0), deficit)
	if want <= 0:
		return 0
	var player: Node2D = pick_spawn_anchor()
	if player == null:
		return 0
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs == null or not fs.has_method("pick_open_position"):
		return 0
	var spawned: int = 0
	for _i: int in range(want):
		var pos: Vector2 = fs.call("pick_open_position", player)
		if pos == Vector2.ZERO:
			break
		if spawn_enemy(pos, decor_layer, -1) != null:
			spawned += 1
	if spawned > 0:
		print("[Director] 区域游荡者 +%d（附近 %d/%d ⇒ 目标 %d / 锚点=%s）" % [
			spawned, threat, threat + spawned, target, player.name])
	return spawned


## 换区补游荡者：按"队伍累计净位移"近似 L4D 的 Active Area Set 换区。
## 逐帧位移超过 64px 视为传送/换图（不计入），避免一次切场景就把整段距离攒满。
func _update_wander_advance(players: Array[Node2D]) -> void:
	var best: float = _sample_team_advance(players)
	## 关卡进度（2026-10-25）：与游荡者/Boss 发牌共用同一份位移采样，不重复遍历玩家。
	_update_progress(players, best)
	## Boss 发牌按里程推进（与游荡者补层共用同一份位移采样）
	## ★2026-10-24 用户实测「防守战里刷了女巫 / 打完一只又来一只」：发牌原先不看全局状态，
	## 防守战、剧本事件、安全屋、非刷怪图里照样按走位里程发牌。必须只在"正常行军"时发。
	if boss_deck_enabled and best > 0.0 and _can_deal_boss():
		_boss_trail += best
		if _boss_trail >= _boss_next_anchor:
			_boss_next_anchor = _boss_trail + boss_deck_step
			_deal_boss_card()
	## 游荡者补层同样只在正常行军时进行（防守战期间补游荡者＝往阵地上堆怪）；
	## 本局「强制不加压」时也停手（2026-10-31）。
	if not refill_allowed():
		return
	if not l4d_pacing or wander_seed_step <= 0.0 or not _can_deal_boss():
		return
	_wander_advance += best
	if _wander_advance >= wander_seed_step:
		_wander_advance = 0.0
		seed_wanderers(Players.scale_area_count(wander_seed_refill))


## 关卡进度推进（2026-10-25）：交给 ProgressTracker 估计，再把结果推给紧张度。
## 只走一个入口 —— 换图/伪造进度时都从这里同步，避免"tracker 变了、紧张度没变"。
func _update_progress(players: Array[Node2D], advance: float) -> void:
	if progress_tracker == null or not is_instance_valid(progress_tracker):
		return
	if not progress_enabled:
		## 旧行为（恒定 0.3）：只在缓存对不上时补一次，不每帧写。
		_sync_progress_to_intensity()
		return
	progress_tracker.call("update", players, advance)
	_sync_progress_to_intensity()


## 现在能不能发牌 / 补游荡者：正常行军才算。
## 排除：防守战与剧本事件（director_suspended / EventManager 事件中）、非刷怪图、安全屋。
func _can_deal_boss() -> bool:
	if director_suspended:
		return false
	var em: Node = get_node_or_null("EventManager")
	if em != null and em.has_method("is_scripted_event_active") \
		and bool(em.call("is_scripted_event_active")):
		return false
	if not _is_spawn_map():
		return false
	var tree: SceneTree = get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene != null and _scene_is_safe_room(scene):
		return false
	return true


## 队伍本帧净位移：取"走得最远那位"，逐帧 >64px 视为传送/换图，不计入。
func _sample_team_advance(players: Array[Node2D]) -> float:
	if _wander_positions.size() > 16:
		_wander_positions.clear()
	var best: float = 0.0
	for p: Node2D in players:
		if not is_instance_valid(p):
			continue
		var tid: int = p.get_instance_id()
		var last: Variant = _wander_positions.get(tid)
		if last is Vector2:
			var d: float = p.global_position.distance_to(last)
			if d > 0.0 and d < 64.0:
				best = maxf(best, d)
		_wander_positions[tid] = p.global_position
	return best


## 喘息期「走远即结束」：进喘息那一刻记下每人位置，之后看"走得最远那位"的净位移；
## 到 `relax_advance` 就提前结束喘息（走得快 = 节奏走得快，不必干等满 cooldown_max）。
func _update_relax_advance(players: Array[Node2D], phase: StringName) -> void:
	if not l4d_pacing or phase != &"cooldown":
		if not _relax_anchor.is_empty():
			_relax_anchor.clear()
		return
	## 快照必须覆盖当前全体玩家：换图 / 复活 / 换人后 instance_id 全变，
	## 留着旧快照会让 `matched < size` 恒真 → 永远重新计时（走远提前结束失效）。
	var matched: int = 0
	for p: Node2D in players:
		if is_instance_valid(p) and _relax_anchor.has(p.get_instance_id()):
			matched += 1
	if matched < players.size() or _relax_anchor.is_empty():
		_relax_anchor.clear()
		for p: Node2D in players:
			if is_instance_valid(p):
				_relax_anchor[p.get_instance_id()] = p.global_position
		return
	var best: float = 0.0
	for p: Node2D in players:
		if not is_instance_valid(p):
			continue
		var last: Variant = _relax_anchor.get(p.get_instance_id())
		if last is Vector2:
			best = maxf(best, p.global_position.distance_to(last))
	if relax_advance > 0.0 and best >= relax_advance:
		var pc: Node = get_node_or_null("PacingController")
		if pc != null and pc.has_method("force_build"):
			print("[Director] 喘息期已前进 %.0fpx（阈值 %.0f）→ 提前结束喘息" % [best, relax_advance])
			pc.call("force_build")


func spawn_horde(count: int, decor_layer: Node) -> int:
	## 兼容旧调用：只关心生成数量。
	return spawn_horde_nodes(count, decor_layer).size()


## 与 spawn_horde 相同，但返回生成出来的敌人节点数组。
## 防守战需要逐个给新敌人锁定玩家目标，因此必须拿到节点本身。
func spawn_horde_nodes(count: int, decor_layer: Node) -> Array[Node2D]:
	var spawned_nodes: Array[Node2D] = []
	## 锚点同 spawn_ahead_batch（多人：偏好落单/走得远的玩家）。
	var player: Node2D = pick_spawn_anchor()
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


## 固定刷怪点的落点判据（2026-09-26 实测修正）。
##
## ⚠ 与普通刷怪**故意不同**：**不受作者禁刷层（NoSpawn）否决**。
## 依据：学校内部图里作者摆的 4 个 `HoldoutSpawnPoint` 全部落在 NoSpawn 区域内
## （5811/65704 格），若沿用 `_is_walkable`（含禁刷层判定）→ 4 个点全被否 → 每只都退回
## 屏幕外刷法 = 用户实测的「刷怪点没起效」。语义上：**显式摆下的点位是比区域标记更强的意图**；
## 作者若想废掉某个点，用该节点的 `enabled = false`。
## 仍然保留：①必须在有效图块上（`_is_inside_map`）②不被现有敌人占住 ③由调用方
## 通过物理探测（mask 1|4|8）排除墙/玩家/敌人。
func is_holdout_spot_ok(global_pos: Vector2) -> bool:
	if not _is_inside_map(global_pos):
		return false
	if _is_occupied_by_enemy(global_pos):
		return false
	return true


## 轮转均分（纯函数，便于单测）：把 `count` 个单位分给 `point_count` 个点，
## 返回每个单位对应的**点位索引**序列。
##   例：count=5 / point_count=3 → [0,1,2,0,1]（点数 2、2、1）；
##       count=5 / point_count=1 → [0,0,0,0,0]（只有 1 个点就全放它）；
##       `wave_index` 轮转起点 → 每批"多出来的那一只"换点（避免永远同一个点多一只）。
func distribute_point_indices(count: int, point_count: int, wave_index: int = 0) -> Array[int]:
	var out: Array[int] = []
	if count <= 0 or point_count <= 0:
		return out
	var start: int = posmod(wave_index, point_count)
	for i: int in range(count):
		out.append((start + i) % point_count)
	return out


## 固定刷怪点条目 → 坐标。
## 兼容两种格式：`{"pos": Vector2, "allow_in_view": bool}`（HoldoutMachine 2026-10-03 起）
## 与裸 `Vector2`（老调用 / 直接手填坐标的场合）。
static func _holdout_entry_pos(entry: Variant) -> Vector2:
	if entry is Dictionary:
		var v: Variant = (entry as Dictionary).get("pos", Vector2.ZERO)
		return v if v is Vector2 else Vector2.ZERO
	return entry if entry is Vector2 else Vector2.ZERO


## 固定刷怪点条目 → 是否「玩家画面内也照常刷」。
## 裸 `Vector2` 视为 false —— 保持 2026-09-26 起的旧行为（画面内点位本批屏蔽）。
static func _holdout_entry_allow_in_view(entry: Variant) -> bool:
	if entry is Dictionary:
		return bool((entry as Dictionary).get("allow_in_view", false))
	return false


## 固定刷怪点条目 → 出生演出配置（空 Dictionary = 不演出）。
## 裸 `Vector2` / 老格式一律返回空 —— 老地图行为零变化。
static func _holdout_entry_performance(entry: Variant) -> Dictionary:
	if entry is Dictionary:
		var cfg: Variant = (entry as Dictionary).get("entry", null)
		if cfg is Dictionary:
			return cfg
	return {}


## 出生演出执行器（2026-10-22）。preload 常量而非 class_name —— 与项目既有做法一致，
## 避免新增 class_name 后需要编辑器重扫全局类缓存。
const ENTRY_PERFORMER := preload("res://script/director/enemy_entry_performance.gd")


## 给刚生成的敌人挂上出生演出：冻结 AI → 跳/落到落点 → 落地僵直 → 交还。
## `landing` 由 `_resolve_entry_landing` **事先**解析并传入 —— 与「起点免障碍」共用同一份
## 判据，杜绝"起点放行了、演出却因落点站不住而跳过 → 敌人被留在墙里"。
## `landing` 不是 Vector2 = 没有配置 / 落点站不住 → 整段跳过，敌人退回旧行为。
func _play_entry_performance(enemy: Node2D, cfg: Dictionary, landing: Variant) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if cfg.is_empty():
		return
	if not (landing is Vector2):
		var raw: Variant = cfg.get("to", Vector2.ZERO)
		if raw is Vector2:
			print("[Director] 出生演出落点 (%d,%d) 找不到可站空位 → 跳过演出"
				% [int((raw as Vector2).x), int((raw as Vector2).y)])
		return
	var play_cfg: Dictionary = cfg.duplicate()
	play_cfg["to"] = landing as Vector2
	var performer: Node = ENTRY_PERFORMER.new()
	performer.name = "EntryPerformance"
	performer.configure(play_cfg)
	enemy.add_child(performer)


## 出生演出的**落点**二次可站校验（判据与固定点刷怪同款：
## 图块碰撞 + 物理探测 1|4|8 + `is_holdout_spot_ok`）。返回 null = 没有配置 / 找不到空位。
func _resolve_entry_landing(cfg: Dictionary, probe_node: Node2D) -> Variant:
	if cfg.is_empty() or probe_node == null:
		return null
	var landing: Variant = cfg.get("to", null)
	if not (landing is Vector2):
		return null
	return SPOT_RESOLVER.find_near(
		probe_node, landing as Vector2, ENEMY_SPOT_PROBE_RADIUS,
		Callable(self, "is_holdout_spot_ok"))


## 「点位带出生演出 + 落点站得住」→ 允许**忽略起点障碍**（2026-10-27 用户需求）。
## 语义：演出本身就是"从别处跳/落过来"，起点只决定起飞位置，不需要站得住 ——
## 敌人可以从墙里、屋顶上、围栏内侧起跳，落地时已经在空地上。
## ★落点不可用必须返回 false：否则起点免检 + 演出被跳过 = 敌人留在墙里 (dead end)。
static func entry_ignores_origin_obstacle(cfg: Dictionary, landing: Variant) -> bool:
	return not cfg.is_empty() and landing is Vector2


## 防守战**固定刷怪点**批（2026-09-26 用户需求）：把 count 只敌人**轮转均分**到 positions 上。
##   例：5 只 / 3 点 → 2、2、1；`wave_index` 让每批的起点轮转（避免永远同一个点多一只）。
##
## 「生成时就避开墙 / 玩家 / 敌人」：每个落点先过 `SpawnSpotResolver.find_near`
##   （①图块碰撞（同步读 TileData）②物理探测 mask 1|4|8 = 图块角色层 + 玩家 + 敌人
##    ③`_is_walkable` 的地图范围闸与作者禁刷层），挪到最近的可站空位。
##   连空位都找不到的那一只**退回屏幕外刷法**（宁可不从作者点出，也不能出现在墙里），
##   并打一条告警，方便作者照着修点位。
##
## ★2026-10-27 用户需求：**点位带出生演出时，起点不查障碍** ——
##   演出是"从别处跳/落过来"，起点只是起飞位置，压墙 / 屋顶 / 围栏上都允许，
##   敌人会直接表演出来并落到（已单独校验过可站的）落点。
##   前提 = 落点站得住；落点不可用则退回上面那条老路径（先挪空位再刷），
##   绝不允许"起点免检但演出被跳过"把敌人留在墙里。
##
## 倍率：调用方（EventManager）传入的 count 已在按真人数放大之后，因此天然继承倍率。
func spawn_horde_nodes_at_positions(points: Array, count: int, decor_layer: Node,
		wave_index: int = 0) -> Array[Node2D]:
	var spawned_nodes: Array[Node2D] = []
	var point_count: int = points.size()
	if point_count <= 0 or count <= 0 or decor_layer == null:
		return spawned_nodes
	var probe_node: Node2D = _spot_probe_node(decor_layer)
	var assignment: Array[int] = distribute_point_indices(count, point_count, wave_index)
	## 玩家画面内 / 近旁的屏蔽判据（FrontSpawner 持有视野矩形与半径配置）。
	var fs: Node = get_node_or_null("FrontSpawner")
	var fell_back: int = 0
	var blocked_swapped: int = 0
	var origin_ignored: int = 0
	for i: int in range(count):
		var entry: Variant = points[assignment[i]]
		var point: Vector2 = _holdout_entry_pos(entry)
		## ★「玩家画面内 / 近旁的点位 → 本批暂时屏蔽」（2026-09-26 用户需求）：
		## 该只改走屏幕外刷法 —— 供给不断，也绝不会出现在玩家眼前。
		## 单机与联机同规则（判据本身按"全体玩家"取并集）。
		## ★2026-10-03 用户需求：点位自身可勾 `allow_in_view` **跳过这层屏蔽**
		##（想做"眼睁睁看着丧尸从走廊尽头涌出来"的表演型点位）。
		if not _holdout_entry_allow_in_view(entry) \
				and fs != null and fs.has_method("is_holdout_point_blocked") \
				and bool(fs.call("is_holdout_point_blocked", point)):
			blocked_swapped += 1
			var swapped: Array[Node2D] = spawn_horde_nodes(1, decor_layer)
			spawned_nodes.append_array(swapped)
			continue
		## 出生演出配置与落点先解析（`null` 落点 = 没有配置 / 落点站不住）。
		var entry_cfg: Dictionary = _holdout_entry_performance(entry)
		var landing: Variant = _resolve_entry_landing(entry_cfg, probe_node)
		var pos_v: Variant = null
		if entry_ignores_origin_obstacle(entry_cfg, landing):
			## ★起点免障碍：直接用作者摆的坐标（可能压在墙/屋顶上），演出会把它带走。
			pos_v = point
			origin_ignored += 1
		elif probe_node != null:
			pos_v = SPOT_RESOLVER.find_near(
				probe_node, point, ENEMY_SPOT_PROBE_RADIUS,
				Callable(self, "is_holdout_spot_ok"))
		if not (pos_v is Vector2):
			var fallback: Array[Node2D] = spawn_horde_nodes(1, decor_layer)
			fell_back += fallback.size()
			spawned_nodes.append_array(fallback)
			continue
		var enemy: Node2D = spawn_enemy(pos_v as Vector2, decor_layer, -1)
		if enemy != null:
			spawned_nodes.append(enemy)
			## 出生演出（2026-10-22）：配置挂在刷怪点上，逐只播放；不配就完全不影响。
			_play_entry_performance(enemy, entry_cfg, landing)
	if blocked_swapped > 0:
		print("[Director] 固定刷怪点 %d 只被「玩家画面/近旁」暂时屏蔽 → 改走屏幕外刷法（本批 %d 只，点位 %d 个）"
			% [blocked_swapped, count, point_count])
	if origin_ignored > 0:
		print("[Director] 固定刷怪点 %d 只带出生演出 → 起点忽略障碍，从作者点位直接起跳/坠落"
			% origin_ignored)
	if fell_back > 0:
		push_warning("[Director] 固定刷怪点有 %d 只找不到空位，已退回屏幕外刷法（%d 个点位，请检查是否压墙/被占）"
			% [fell_back, point_count])
	return spawned_nodes


## 物理探测用的节点：必须是已入树的 Node2D（Director 是纯 Node，没有 World2D）。
## 优先用敌人容器 DecorLayer，退回任一玩家。
func _spot_probe_node(decor_layer: Node) -> Node2D:
	var layer := decor_layer as Node2D
	if layer != null and is_instance_valid(layer) and layer.is_inside_tree():
		return layer
	var player: Node2D = _find_player()
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		return player
	return null




## 刷怪取点的**唯一可见性闸门**：该点是否不在任一玩家视野内（多人取矩形并集，含余量）。
## 与 FrontSpawner.pick_ahead_position 内部判据同源。
## ⚠ 2026-09-25 用户实测「偶发贴脸刷怪」——真根因是**并集缺失 + 距离量错了对象**：
## 作者点回退（_pick_spawn_position）与「玩家外围随机取点」（_find_walkable_near_player）
## **完全不查任何人的视野**，唯一的安全条件是 _get_valid_spawn_points 里的
## `dist >= spawn_min_dist(400)`，而那个距离是**只对锚点玩家**量的
## （`player.global_position.distance_to(sp.global_position)`，player = pick_spawn_anchor()）。
## 于是「锚点 = 跑在前面的那位」时，一个离锚点 500px（通过筛选）、却离**另一名玩家**
## 只有 120px 的点会被直接采用 → 怪刷在另一名玩家脸上（主机/客户端两个方向都会发生）。
##
## 注：`spawn_min_dist` 取 400 恰好等于可视矩形角点距离 √(320²+240²)=400，
## 所以"只比欧氏距离"对**单人、且以被比较者为中心**的视野是够用的 ——
## 漏洞不在"欧氏 vs 矩形"，而在**比较对象**：
##   · 锚点可能是任何一个玩家（pick_spawn_anchor 偏好落单/走得远/移动中者）；
##   · 另一名玩家的视野从头到尾没参与判定。
## FrontSpawner 缺失属病态配置：放行并只告警一次（宁可维持旧行为，也不要整图停刷）。
var _spawn_gate_missing_warned: bool = false


func _spawn_pos_is_hidden(pos: Vector2) -> bool:
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs == null or not fs.has_method("is_offscreen_for_all"):
		if not _spawn_gate_missing_warned:
			_spawn_gate_missing_warned = true
			printerr("[Director] FrontSpawner 缺失 → 刷怪屏外闸门失效（本局只告警一次）")
		return true
	return bool(fs.call("is_offscreen_for_all", pos))


## 生成自检：落点若落在任一玩家**真实可视矩形**内 → 打一条醒目告警。
## 挂在 spawn_enemy / spawn_special_enemy 这两个唯一汇聚点上，
## 一次覆盖所有刷怪路径（尸潮 / 前方补位 / 作者点 / 区域补齐 / 防守战事件批 / 特感 / Boss）。
func _warn_if_spawn_visible(pos: Vector2, kind: String) -> void:
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs == null or not fs.has_method("is_visible_to_any_player_exact"):
		return
	if not bool(fs.call("is_visible_to_any_player_exact", pos)):
		return
	## 用**全体实体**（含倒地/濒死）算最近距离：倒地的队友照样能看见怪刷在自己脸上。
	var best: float = INF
	for e: Node2D in Players.all_entities():
		if is_instance_valid(e):
			best = minf(best, pos.distance_to(e.global_position))
	print("[SpawnWarn] ★贴脸刷怪 kind=%s pos=(%d,%d) 最近玩家=%.0fpx（该点在玩家实际画面内）" % [
		kind, int(pos.x), int(pos.y), best])


func _pick_spawn_position(player: Node2D, spawn_points: Array, spawned_count: int) -> Vector2:
	## 作者生成点：按优先级顺序找一个**不在任一玩家视野内**的点（找不到返回 ZERO 交给调用方回退）。
	if not spawn_points.is_empty():
		for i: int in range(spawn_points.size()):
			var sp: Node2D = spawn_points[(spawned_count + i) % spawn_points.size()] as Node2D
			if not is_instance_valid(sp):
				continue
			var cand: Vector2 = (sp as SpawnZone).get_random_position() if sp is SpawnZone else sp.global_position
			if _spawn_pos_is_hidden(cand):
				return cand
		return Vector2.ZERO
	return _find_walkable_near_player(player)


func _add_spawn_scatter(pos: Vector2) -> Vector2:
	## 散步 + 避开现有敌人碰撞体（间距 28px）。若附近都不可用，保留已验证的原始位置。
	## ⚠ 2026-09-25：散点发生在**屏外判定之后**，这里复检一次可见性 ——
	## ±36 抖动会把"刚离开屏幕"的点重新拉近（余量从 64 压到 28 以内），
	## 在客户端分辨率 / 相机前瞻存在差异时可能露出画面。属防守性收紧，不单独构成贴脸根因。
	for _attempt: int in range(20):
		var scattered: Vector2 = pos + Vector2(randf_range(-36, 36), randf_range(-36, 36))
		if not _spawn_pos_is_hidden(scattered):
			continue
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


## 当前关卡进度（0~1）。没有 ProgressTracker / 关掉 progress_enabled 时回退旧的 0.3。
func get_progress() -> float:
	if not progress_enabled or progress_tracker == null or not is_instance_valid(progress_tracker):
		return 0.3
	return float(progress_tracker.call("get_progress"))


## 手动设定进度（0~1，负数恢复自动）。剧本事件/调试可用；跨图重置回自动。
func set_progress(ratio: float) -> void:
	if progress_tracker != null and is_instance_valid(progress_tracker):
		progress_tracker.call("set_forced", ratio)
	if intensity_tracker and intensity_tracker.has_method("set_progress"):
		intensity_tracker.set_progress(get_progress())


## 把当前进度推给 IntensityTracker。`force` = 忽略变化阈值（初始化 / 换图时用）。
## 阈值 0.01：进度是缓变量，每帧都推没有意义（热路径上少一次跨脚本调用）。
func _sync_progress_to_intensity(force: bool = false) -> void:
	if intensity_tracker == null or not intensity_tracker.has_method("set_progress"):
		return
	var p: float = get_progress()
	if not force and absf(p - _progress_cache) < 0.01:
		return
	_progress_cache = p
	intensity_tracker.set_progress(p)


func set_combat(active: bool) -> void:
	if intensity_tracker and intensity_tracker.has_method("set_combat"):
		intensity_tracker.set_combat(active)


# ═══════════════════════════════════════
# 内部 — 玩家/场景查找
# ═══════════════════════════════════════

## 上一次"生成图判定"的结果（-1 = 未初始化）。用于只在该判定翻转时打一条日志 ——
## 安全屋/静默图不刷怪这件事没有别的可观测点，出问题时只能靠这行确认判成了什么。
var _last_spawn_verdict: int = -1
## ── 生成图判定缓存（2026-10-08 性能）──
## `_is_spawn_map()` 每帧在 _process 顶部调用；旧实现每次都对场景路径 `to_lower()` 并
## 对每个关键字再 `to_lower()` 一次做子串搜索 —— 全是每帧重复的字符串运算。
## 判定只取决于「场景路径 + 关键字表 + auto_spawn_enabled」，这些在一张图内不变；
## 按「场景路径」缓存结果，换图（路径变化）自动重算。
## 哨兵：绝不可能等于任何真实 `scene_file_path`（后者恒以 "res://" 开头）。
const _SCENE_PATH_SENTINEL: String = "<unset>"
var _spawn_map_cache_path: String = _SCENE_PATH_SENTINEL
var _spawn_map_cache_verdict: bool = false
## 关键字小写化缓存（首用时构造一次）
var _spawn_kw_lower: PackedStringArray = PackedStringArray()
var _safe_kw_lower: PackedStringArray = PackedStringArray()


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
	var tree: SceneTree = get_tree()
	if not tree or not tree.current_scene:
		return false
	var scene_path_raw: String = tree.current_scene.scene_file_path
	if scene_path_raw == _spawn_map_cache_path:
		return _spawn_map_cache_verdict
	var verdict: bool = _evaluate_spawn_map_uncached(scene_path_raw)
	_spawn_map_cache_path = scene_path_raw
	_spawn_map_cache_verdict = verdict
	return verdict


func _evaluate_spawn_map_uncached(scene_path_raw: String) -> bool:
	if not auto_spawn_enabled:
		return false
	var scene_path: String = scene_path_raw.to_lower()
	if _spawn_kw_lower.is_empty() and not spawn_map_keywords.is_empty():
		for kw: String in spawn_map_keywords:
			_spawn_kw_lower.append(kw.to_lower())
	if _safe_kw_lower.is_empty() and not safe_room_keywords.is_empty():
		for kw: String in safe_room_keywords:
			_safe_kw_lower.append(kw.to_lower())
	# 白名单：指定了关键字则必须匹配
	if spawn_map_keywords.size() > 0:
		var matched: bool = false
		for kw: String in _spawn_kw_lower:
			if kw in scene_path:
				matched = true
				break
		if not matched:
			return false
	# 黑名单：安全屋不生成
	for kw: String in _safe_kw_lower:
		if kw in scene_path:
			return false
	return true


## 当前场景是否为「安全屋」（按 `safe_room_keywords` 匹配场景路径）。
## 与 `_evaluate_spawn_map` 的差别：**不看** auto_spawn_enabled / spawn_map_keywords ——
## 那两个是「要不要刷怪」的闸门，可能被本图的 DirectorConfig 覆盖；
## 而「是不是安全屋」只取决于地图名，用于触发「中场休息收尾」（见 _reset_live_combat_state）。
func _scene_is_safe_room(scene: Node) -> bool:
	if scene == null or not is_instance_valid(scene):
		return false
	var scene_path: String = scene.scene_file_path.to_lower()
	for kw: String in safe_room_keywords:
		if kw.is_empty():
			continue
		if kw.to_lower() in scene_path:
			return true
	return false


## 场景配置刷新入口（由 GameInit 在联机会话下调用）。
## ⚠ 为什么需要：`_process` 在联机客户端**整体早退**，`_check_scene_change` 从来不跑
## → 客户端的 `current_config` 恒为 null → `play_boss_music` / `_play_horde_music`
## 第一行 `stream == null` 就 return，A6 广播过来的 BGM 全成 no-op；防守战 BGM 也永远
## 拿不到「Boss 正在播」这个状态去上闸（用户实测「多人下 Tank BGM 与防守战 BGM 同时播放」）。
## 幂等：同一场景重复调用会在 `scene == _last_scene` 处早退。
func refresh_scene_config() -> void:
	_check_scene_change()


func _check_scene_change() -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var scene: Node = tree.current_scene
	if scene == _last_scene:
		return
	_last_scene = scene
	## ★Boss BGM 绝不跨图（2026-10-19 用户要求「切换场景时坦克音乐也要停止」）：
	## 坦克实体属于本场景，换图（含同图重建）后旧坦克随场景释放 —— 若 BGM 继续播，
	## 就是"场上没有 Boss 却响 Boss 曲"。放在缓存清理之前，让本帧后续的
	## `_update_boss_music()` 看到的是已停止状态。
	## ⚠ 尸潮 BGM **不能**在这里停：尸潮跨图是本项目既定设计（Pacing 阶段不随换图重置），
	## 停尸潮只由 phase=cooldown / 全灭冻结 / 进安全屋 / 回标题负责。
	if _boss_music_active:
		stop_boss_music(false)
		print("[Director] 场景切换：Boss BGM 已停止（坦克不跨图）")
	# 场景切换 → 失效生成图判定缓存 + 关键字小写缓存（新图配置可能不同）
	_spawn_map_cache_path = _SCENE_PATH_SENTINEL
	_spawn_kw_lower.clear()
	_safe_kw_lower.clear()
	# 场景切换 → 清空 TileMapLayer 缓存（旧引用已释放）
	_tilemap_cache.clear()
	_tilemap_cache_ready = false
	# 场景切换 → 同步清空禁刷怪层缓存（NoSpawnLayer）
	_no_spawn_layers.clear()
	_no_spawn_cache_ready = false
	## ★场景切换 → 关卡进度归零（2026-10-25）：进度是**每张图**的度量，
	## 跨图继承会让"新图刚进门就 0.9 进度"（Tank 闸门/紧张度全乱）。
	## 出口节点与起点在 ProgressTracker 第一次 update 时再解析（那时玩家已就位）。
	if progress_tracker != null and is_instance_valid(progress_tracker):
		progress_tracker.call("reset_for_scene", scene)
		_sync_progress_to_intensity(true)
	## ★场景切换（含**同图传送**，如第三关矿洞钥匙门：目标场景 = 本图自己，同样会建新实例）
	## → 清掉只指向**旧场景已释放节点**的引用集合（2026-10-12 修「尸潮切图时主机端节点报错」）。
	## `_horde_locked_enemies` 存的是旧场景敌人节点；旧实例被释放后这些引用**悬垂**，
	## 若残留到新场景再被遍历/操作即报错。这里只做**引用清理**，不动 pacing 语义
	##（遵守 2026-09-23「换图不重置 pacing」教训）；`_horde_rage` 是否残留由
	## 安全屋收尾（`_reset_live_combat_state`）负责，普通图保持既有行为。
	## ⚠ **绝不能**用 `arr.filter(func(e: Node2D) -> bool: ...)`：数组含**已释放 Object** 时，
	## 带类型标注的 lambda 参数转换会失败（`Cannot convert argument 1 from Object to Object`
	## → filter 返回空 Array → 再赋值回 Array[Node2D] 二次报错，2026-10-11 用户实测主机端崩溃）。
	_horde_locked_enemies = _prune_freed_nodes(_horde_locked_enemies)
	_boss_music_watchlist = _prune_freed_nodes(_boss_music_watchlist)
	## 子节点 EventManager 也持有敌人引用集合（防守战 target_lock），同款清理。
	var em_reset: Node = get_node_or_null("EventManager")
	if em_reset and em_reset.has_method("prune_scene_switched_references"):
		em_reset.call("prune_scene_switched_references")
	# 场景切换 → 复位前方补位记账（09-27 实测修复）：_batch_player_pos 里存的是**旧图玩家的
	# instance_id**，字典非空会让新图的 _max_advance 查不到坐标恒返回 0 → 必须真实走满
	# advance_step 才开始补位。表现就是用户报的「从安全屋/换图出来后前面怪很少、很迟」
	# （单机同样受影响，联机因锚点常落在远端玩家身上而更明显）。
	var fs_reset: Node = get_node_or_null("FrontSpawner")
	if fs_reset and fs_reset.has_method("reset_batch_tracking"):
		fs_reset.call("reset_batch_tracking")
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
		## ★开场立即刷怪（2026-09-27 用户需求，图级开关）：勾了的图不停在喘息阶段，
		## 直接 build + 放开前方补位的时间闸门 → 进图即有敌人。
		## ⚠ 没勾的图**不动 pacing**（换图重置 pacing 会踩 2026-09-23 的坑，见下方注释）。
		if bool(cfg.get("spawn_immediate_on_start")):
			_apply_immediate_spawn_start()
	else:
		print("[Director] no DirectorConfig in scene, using defaults")
		## ★没配 DirectorConfig 的图也要重置节奏状态（2026-10-31）：
		## 否则会把上一张图的「首波已过 / 距上一波多久」带过来 —— 首波会被跳过、
		## 甚至被上一张图的硬间隔闸压住。首波区间清零 = 退回 build_min/max。
		var pc_def: Node = get_node_or_null("PacingController")
		if pc_def != null and pc_def.has_method("reset_for_new_map"):
			pc_def.set("first_build_min", 0.0)
			pc_def.set("first_build_max", 0.0)
			pc_def.call("reset_for_new_map")
	## ★进入安全屋 = 本局的中场休息（2026-10-03 用户实测：「安全屋里尸潮音乐还没结束」
	## 「出安全屋后直接尸潮」）：必须在这里把门外那一波尸潮彻底收掉 ——
	## 停尸潮/Boss BGM、解除狂暴与目标锁定、Pacing 回 cooldown 并重掷时长、
	## 复位剧本事件与防守战挂起。
	## ⚠ 放在 `_apply_config` **之后**：重掷 cooldown 时长要用本图配的参数。
	## ⚠ 这是 2026-09-23「换图不要重置 pacing」教训的**唯一例外** ——
	##   那次事故的成因是"普通图开场被强制回 cooldown → 开场静默 20~35s"，
	##   而安全屋本身就不刷怪（`spawn_map=false`），强制回 cooldown 零副作用。
	if _scene_is_safe_room(scene):
		_reset_live_combat_state()
		print("[Director] 进入安全屋：本局战斗状态已收尾（尸潮/Boss BGM 停止、节奏回喘息、狂暴与目标锁定解除）")
	## ★进图先铺一层「区域游荡者」（2026-10-24 用户实测「进图跑 10 秒一只丧尸都没有」）：
	## 本项目地图没有 SpawnZone/SpawnPoint，且街道/走廊图一拐弯就取不到前方点，
	## 所以"一片区域里有丧尸在晃"必须由导演主动预置，而不是等玩家走到才从前方刷。
	## 安全屋 / 不刷怪的图跳过。放在安全屋收尾之后：收尾会把阶段打回喘息，不能被打扰。
	if refill_allowed() and l4d_pacing and wander_seed_max > 0 \
			and not _scene_is_safe_room(scene) and _is_spawn_map():
		_wander_advance = 0.0
		_wander_positions.clear()
		var seed_n: int = randi_range(mini(wander_seed_min, wander_seed_max),
			maxi(wander_seed_min, wander_seed_max))
		seed_wanderers(Players.scale_area_count(seed_n))
	## ⚠ 这里**不要**重置 pacing 阶段（2026-09-23 实测教训）：
	## 开场强制回 cooldown 会把"地图开局立即 build（SpawnManager 立刻散兵刷怪）"变成
	## "开局静默 20~35s"，联机 features / weapon 两个场景因此拿不到开场那批敌人而失败。
	## 团灭复活的重置由 _freeze_for_death + _resume_after_death 负责（不依赖换图钩子）：
	## 冻结时重掷 cooldown，黑屏-重载期间 _process 早退（计时不推进），复活后第一帧再收一次。


## 开场立即刷怪（图级开关 spawn_immediate_on_start）：
## ① 跳出喘息阶段直接 build —— SpawnManager 进 build 时会把散兵计时清零，第一批立刻落地；
## ② 让前方补位的时间闸门（距上批间隔 / 前进距离）一次性放行。
## ⚠ 只在勾了开关的图上调用：其它图不碰 pacing（换图重置 pacing 是 2026-09-23 的坑）。
func _apply_immediate_spawn_start() -> void:
	var pc: Node = get_node_or_null("PacingController")
	## ★尸潮进行中不要强推 build（2026-10-24 用户实测「传送后尸潮刚结束又立刻来一次」）：
	## 传送往往发生在尸潮还没打完的时候。此处无条件 force_build 会把 phase 从 peak/fade
	## 直接拉回 build，而强度仍被残余敌人撑着 → 下一帧就再次越过峰值阈值 →
	## 再发一次尸潮 + 再响一次预警音。玩家听到的就是「尸潮音乐刚停、预警音又来」。
	## 只在"干净开局"（不在峰值/余韵、且没有尸潮窗口）时才跳阶段。
	var sm: Node = get_node_or_null("SpawnManager")
	var horde_running: bool = sm != null and sm.has_method("is_horde_active") \
		and bool(sm.call("is_horde_active"))
	var phase: StringName = &"cooldown"
	if pc != null and pc.has_method("get_phase_name"):
		phase = pc.call("get_phase_name")
	if horde_running or phase == &"peak" or phase == &"fade":
		print("[Director] 开场立即刷怪跳过：尸潮仍在进行（phase=%s horde=%s）" % [phase, horde_running])
		return
	if pc and pc.has_method("force_build"):
		pc.call("force_build")
	var fs: Node = get_node_or_null("FrontSpawner")
	if fs and fs.has_method("prime_immediate_spawn"):
		fs.call("prime_immediate_spawn")
	print("[Director] 开场立即刷怪：跳过喘息，直接 build + 前方补位放行")


## 收敛一个「节点引用集合」：剔除所有已释放（freed）的引用，返回仍有效的 Node2D 数组。
## ⚠ 必须**无类型迭代**：源数组里可能含已释放 Object，若写 `for e: Node2D in src`
## 或 `src.filter(func(e: Node2D)...)`，元素到 Node2D 的类型转换会失败并抛
## `Cannot convert argument 1 from Object to Object`（2026-10-11 用户实测主机端崩溃）。
## 遍历变量保持 Variant，仅在确认 `is_instance_valid` 后再 append 到类型化数组。
func _prune_freed_nodes(src: Array) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for e: Variant in src:
		if is_instance_valid(e) and e is Node2D:
			out.append(e as Node2D)
	return out



func _find_director_config(node: Node) -> DirectorConfig:
	if node is DirectorConfig:
		return node as DirectorConfig
	for child: Node in node.get_children():
		var found: DirectorConfig = _find_director_config(child)
		if found:
			return found
	return null


## 把 `l4d_pacing` 统一下发给三个与生成相关的子模块（幂等）。
## 子模块脚本自身的默认值是 false —— 那是给回归 harness 单独实例化时保留旧行为的；
## 实际运行必须与 Director 一致，否则会出现「节奏按新模型走、生成器还按旧模型补位」的错配。
func _apply_l4d_model() -> void:
	for node_name: String in ["PacingController", "SpawnManager", "FrontSpawner"]:
		var sub: Node = get_node_or_null(node_name)
		if sub != null:
			sub.set("l4d_model", l4d_pacing)


## ── 尸潮间隔换算（2026-10-29）──
## FADE 余韵段的大致长度：算「两次尸潮之间的间隔」时要把它从 Build 里扣掉。
## 真实长度由「无交战 2.5s / 兜底 12s」决定，这里取个中间常数就够（不需要精确）。
const FADE_OVERHEAD_SECONDS: float = 6.0


## 尸潮间隔（秒，峰值开始 → 下一次峰值开始）：本图覆盖优先，否则按难度表。
## 这是**无击杀时的基线**：实际间隔会被 `smart_horde_per_kill_sec` 提前。
## 难度表见 Global.difficulty_multipliers 的 horde_interval_min/max。
func _horde_interval_for(cfg: DirectorConfig) -> Vector2:
	if cfg != null and cfg.horde_interval_override_min > 0.0 \
			and cfg.horde_interval_override_max > 0.0:
		return Vector2(
			minf(cfg.horde_interval_override_min, cfg.horde_interval_override_max),
			maxf(cfg.horde_interval_override_min, cfg.horde_interval_override_max))
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("difficulty_horde_interval"):
		var v: Variant = g.call("difficulty_horde_interval")
		if v is Vector2:
			return v
	return Vector2(180.0, 300.0)


## 由「尸潮间隔」反推本图的 Build 时长区间（x=下限，y=上限）。
## 与 `_apply_config` 里 `peak_timeout` / `cooldown_*` 的缩放口径必须一致 ——
## 抽成独立函数是为了让用例能直接断言「各难度实际等多久」。
func resolve_build_range(cfg: DirectorConfig) -> Vector2:
	var t_scale: float = clampf(cfg.pacing_time_scale, 0.2, 2.0)
	var peak_len: float = maxf(5.0, cfg.peak_timeout * t_scale)
	var cd_min: float = maxf(1.0, cfg.cooldown_min * t_scale)
	var cd_max: float = maxf(2.0, cfg.cooldown_max * t_scale)
	var interval: Vector2 = _horde_interval_for(cfg)
	var overhead: float = peak_len + (cd_min + cd_max) * 0.5 + FADE_OVERHEAD_SECONDS
	return Vector2(maxf(30.0, interval.x - overhead), maxf(35.0, interval.y - overhead))


## 两波尸潮之间的硬间隔（秒）。`smart_horde_gap_sec` 为 0 时按「间隔下限 × 0.9」自动取 ——
## **必须随难度缩放**：固定 90s 会把「最高难度 65~95s 一波」直接压成 90s，难度分档就没了。
func resolve_horde_gap(cfg: DirectorConfig) -> float:
	if cfg.smart_horde_gap_sec > 0.0:
		return cfg.smart_horde_gap_sec
	return _horde_interval_for(cfg).x * 0.9


## 首波 BUILD 时长区间（x=下限，y=上限）= `间隔 × smart_horde_first_scale`。
## ⚠ **不扣 overhead**：开场没有峰值/余韵/喘息要先还债，所以第一段 BUILD 的时长
## 就等于玩家从进图到第一波尸潮的等待时间。旧的错误写法有两种，都导致「首波太早」：
##   · 乘在已经扣过 overhead 的 BUILD 上（0.6×）→ 普通只剩 35~59s；
##   · 按 `间隔 − overhead` 算 → 只有 68~103s，仍然到不了 2 分钟。
## 1.0 = 首波在「普通 110~145s」到来（用户 2026-10-31 要求「起码 2 分钟左右」）。
func resolve_first_build_range(cfg: DirectorConfig) -> Vector2:
	var interval: Vector2 = _horde_interval_for(cfg)
	var scale: float = clampf(cfg.smart_horde_first_scale, 0.2, 2.0)
	var lo: float = maxf(cfg.smart_horde_min_sec, interval.x * scale)
	var hi: float = maxf(lo + 1.0, interval.y * scale)
	return Vector2(lo, hi)


## ── 智能尸潮的击杀喂入（2026-10-31 压力表）──
## 用 ChapterStats 的「本章击杀」当输入：换图 / 新局会自动归零。
## 语义（用户 2026-10-31 定）：**杀得越多，尸潮来得越快** —— 每杀给压力条加
## `smart_per_kill_sec` 秒；非 BUILD 段的击杀由 PacingController 自行忽略（防连环尸潮）。
## 0.5s 轮询一次即可（击杀是离散事件，get_totals 每次都会分配字典）。
var _kill_poll_left: float = 0.0
var _kills_seen: int = 0


func _feed_smart_horde_kills(pc: Node, delta: float) -> void:
	if pc == null or not bool(pc.get("smart_horde")):
		return
	_kill_poll_left -= delta
	if _kill_poll_left > 0.0:
		return
	_kill_poll_left = 0.5
	var cs: Node = get_node_or_null("/root/ChapterStats")
	if cs == null or not cs.has_method("get_totals"):
		return
	var totals: Dictionary = cs.call("get_totals")
	var kills: int = int(totals.get("kills", 0))
	if kills < _kills_seen:
		_kills_seen = kills      ## 换章 / 统计清零 → 重新对齐，不倒扣
		return
	if kills > _kills_seen:
		pc.call("note_kills", kills - _kills_seen)
		_kills_seen = kills


## ── 同批聚堆闸（2026-10-29 用户实测「一个小拐角堆一堆丧尸」）──
## 去重窗口（RECENT_SPAWN_RADIUS 48px / 2s）只防"同一个点被反复用"，
## 一批 8 只仍然可以全挤在 48px 里。这里按**本批**再限一次：
## 某个 96px 半径内本批最多 3 只，超了就跳过这只（宁缺不挤，下一批再补）。
const BATCH_CLUSTER_RADIUS: float = 96.0
const BATCH_CLUSTER_MAX: int = 3


func _batch_accepts(placed: Array, pos: Vector2) -> bool:
	var near: int = 0
	for p: Variant in placed:
		if (p as Vector2).distance_to(pos) < BATCH_CLUSTER_RADIUS:
			near += 1
			if near >= BATCH_CLUSTER_MAX:
				return false
	return true


func _apply_config(cfg: DirectorConfig) -> void:
	auto_spawn_enabled = cfg.spawn_enabled
	spawn_min_dist = cfg.spawn_min_dist
	var pc: Node = get_node_or_null("PacingController")
	if pc:
		_copy_props(cfg, pc, ["build_min", "build_max", "peak_timeout",
			"cooldown_min", "cooldown_max", "peak_intensity_threshold", "cooldown_intensity_threshold",
			"peak_sustain", "fade_quiet_sec", "fade_timeout"])
		## L4D 模型开关：配置里的名字是 l4d_pacing，节奏控制器里叫 l4d_model。
		pc.set("l4d_model", cfg.l4d_pacing)
		## 智能尸潮（2026-10-31 重做：击杀驱动的压力表）：节奏改由「时间 + 击杀 + 安静」
		## 三条来源共同填充一个进度条决定；目标时长仍由难度间隔表反推。
		pc.set("smart_horde", cfg.smart_horde_enabled)
		pc.set("smart_per_kill_sec", cfg.smart_horde_per_kill_sec)
		pc.set("smart_idle_mult", cfg.smart_horde_idle_mult)
		pc.set("smart_min_sec", cfg.smart_horde_min_sec)
		pc.set("smart_gap_sec", resolve_horde_gap(cfg))
		## 停用字段仍转发一次：旧场景若存过值不会因为不再 set 而残留上一张图的状态。
		pc.set("smart_base_sec", cfg.smart_horde_base_sec)
		pc.set("smart_max_sec", cfg.smart_horde_max_sec)
		## 换图 = 新的一张图：压力表清零、首波计数归零、硬间隔计时重置。
		if pc.has_method("reset_for_new_map"):
			pc.call("reset_for_new_map")
		## 附加参数 + 紧张度系数：开局显式对齐一次（`_sync_horde_modifiers` 之后只在变化时写）。
		var g_mod: Node = get_node_or_null("/root/Global")
		if g_mod != null:
			pc.set("no_horde", bool(g_mod.call("horde_modifier", "no_horde")))
			pc.set("intensity_gain", float(g_mod.call("difficulty_intensity_pressure")))
			_mod_cache_no_horde = bool(pc.get("no_horde"))
			_mod_cache_pressure_gain = float(pc.get("intensity_gain"))
		## ★节奏时长按「地图尺度」打折（2026-10-24）：本作一章几分钟就跑完，
		## L4D 那套按十几分钟一章标定的秒数直接照搬 → 一张图只够 1~2 个循环。
		## 只缩这四个时长；peak_sustain / fade_quiet_sec 是体感下限，不缩。
		var t_scale: float = clampf(cfg.pacing_time_scale, 0.2, 2.0)
		var peak_len: float = maxf(5.0, cfg.peak_timeout * t_scale)
		var cd_min: float = maxf(1.0, cfg.cooldown_min * t_scale)
		var cd_max: float = maxf(2.0, cfg.cooldown_max * t_scale)
		pc.set("peak_timeout", peak_len)
		pc.set("cooldown_min", cd_min)
		pc.set("cooldown_max", cd_max)
		## ★Build 时长改由「尸潮间隔（难度表 / 本图覆盖）」反推（2026-10-29 用户定稿，
		## 2026-10-31 抽成 `resolve_build_range()` 以便被用例直接校验）：
		## 间隔 = Build + 峰值 + 余韵 + 喘息，所以 Build 要把后三段的期望值扣掉。
		var build_range: Vector2 = resolve_build_range(cfg)
		pc.set("build_min", build_range.x)
		pc.set("build_max", build_range.y)
		## 首波单独给时长（2026-10-31）：用户实测首波 35~59s 太早，普通要 2 分钟左右。
		var first_range: Vector2 = resolve_first_build_range(cfg)
		pc.set("first_build_min", first_range.x)
		pc.set("first_build_max", first_range.y)
	l4d_pacing = cfg.l4d_pacing
	relax_advance = cfg.relax_advance
	## 画面外补怪总开关（2026-10-29）：本节点与 SpawnManager 各持一份 ——
	## Director 用它决定是否驱动 FrontSpawner/游荡者，SpawnManager 用它决定预算/喘息是否发货。
	offscreen_refill_enabled = cfg.offscreen_refill_enabled
	offscreen_refill_min = maxi(0, cfg.offscreen_refill_min)
	offscreen_refill_max = maxi(offscreen_refill_min, cfg.offscreen_refill_max)
	var sm_gate: Node = get_node_or_null("SpawnManager")
	if sm_gate != null:
		sm_gate.set("offscreen_refill_enabled", offscreen_refill_enabled)
		sm_gate.set("offscreen_refill_min", offscreen_refill_min)
		sm_gate.set("offscreen_refill_max", offscreen_refill_max)
	wander_seed_min = cfg.wander_seed_min
	wander_seed_max = cfg.wander_seed_max
	wander_seed_step = cfg.wander_seed_step
	wander_seed_refill = cfg.wander_seed_refill
	wander_target_near = cfg.wander_target_near
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
		## L4D 模型：FrontSpawner 退化为「取点器」，不再自己补位（见其 l4d_model 注释）。
		fs.set("l4d_model", cfg.l4d_pacing)
		fs.set("threat_radius", cfg.threat_radius)
	_copy_props(cfg, self, ["recycle_enabled", "recycle_interval", "recycle_dist", "recycle_clear_corpses"])
	## ── 关卡进度（2026-10-25）──
	progress_enabled = cfg.progress_enabled
	progress_length_px = maxf(cfg.progress_length_px, 0.0)
	if progress_tracker != null and is_instance_valid(progress_tracker):
		progress_tracker.set("enabled", progress_enabled)
		progress_tracker.set("route_length_override", progress_length_px)
		## 重新起算：本图配置的参考路程要在"解析出口"之前生效
		progress_tracker.call("reset_for_scene", get_tree().current_scene if get_tree() else null)
		_sync_progress_to_intensity(true)
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
	holdout_tank_demand_interval = maxf(cfg.holdout_tank_demand_interval, 0.0)
	# 换图重置：常规 Tank 冷却从本关开始时起算；防守战计时在防守战开启时再重置。
	_tank_cooldown_left = randf_range(tank_cooldown_min, tank_cooldown_max)
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0
	# ── Boss 发牌（第二批）：本图里程从头算，牌堆重洗 ──
	boss_deck_enabled = cfg.boss_deck_enabled
	boss_deck_step = maxf(cfg.boss_deck_step, 300.0)
	boss_deck_first_ratio = clampf(cfg.boss_deck_first_ratio, 0.3, 1.0)
	boss_deck_nothing_weight = maxi(cfg.boss_deck_nothing_weight, 1)
	boss_deck_max_tanks = maxi(cfg.boss_deck_max_tanks, 0)
	boss_deck_max_witches = maxi(cfg.boss_deck_max_witches, 0)
	tank_spawn_pos_min = clampf(cfg.tank_spawn_pos_min, 0.0, 0.95)
	tank_spawn_pos_max = clampf(cfg.tank_spawn_pos_max, tank_spawn_pos_min + 0.05, 1.0)
	tank_no_repeat_maps = cfg.tank_no_repeat_maps
	if cfg.witch_data != null:
		_witch_data = cfg.witch_data
	elif _witch_data == null and ResourceLoader.exists(DEFAULT_WITCH_PATH):
		_witch_data = load(DEFAULT_WITCH_PATH) as SpecialEnemyData
	_reset_boss_deck()
	## ── 物品投放（2026-10-25）：位置口径与降级投放参数由地图覆盖 ──
	var im: Node = get_node_or_null("ItemManager")
	if im:
		im.set("drop_visible_max", cfg.item_drop_visible_max)
		im.set("drop_threat_radius", cfg.item_drop_threat_radius)
		im.set("fail_safe_hp_ratio", cfg.item_fail_safe_hp_ratio)
		im.set("fail_safe_low_hp_sec", cfg.item_fail_safe_low_hp_sec)
		im.set("fail_safe_cooldown", cfg.item_fail_safe_cooldown)
	var sm: Node = get_node_or_null("SpawnManager")
	if sm:
		_copy_props(cfg, sm, ["scatter_min", "scatter_max",
			"scatter_interval_min", "scatter_interval_max",
			"horde_total_min", "horde_total_max",
			"horde_batch_size", "horde_batch_interval",
			"horde_duration_min", "horde_duration_max", "max_active_common",
			"build_budget_min", "build_budget_max",
			"build_batch_min", "build_batch_max",
			"build_interval_min", "build_interval_max",
			"mob_size_min", "mob_size_max", "mob_behind_ratio", "mob_size_floor",
			"relax_target", "relax_interval", "build_threat_limit"])
		sm.set("l4d_model", cfg.l4d_pacing)
	print("[Director] config applied: spawn=%s cooldown=%.0f-%.0fs" % [cfg.spawn_enabled, cfg.cooldown_min, cfg.cooldown_max])


func _copy_props(src: Object, dst: Object, props: Array[String]) -> void:
	for prop: String in props:
		var val = src.get(prop)
		if val != null and prop in dst:
			dst.set(prop, val)


func _find_player() -> Node2D:
	## 走每帧缓存（见 _cached_all_entities）：一帧内多处调用不再各自 all_entities() 新分配。
	var players: Array[Node2D] = _cached_all_entities()
	return players[0] if not players.is_empty() else null


# ═══════════════════════════════════════
# 玩家运动实测（2026-09-26）
# ═══════════════════════════════════════
## 【为什么需要】Host 侧对**远端玩家**只镜像 position/facing/moving/walking，
## **从不写 `velocity`** → 旧 `_player_speed()` 读到的恒为 0。而它喂给三条关键判定：
##   ① `pick_spawn_anchor` 的「移动系数」（静止玩家降权 IDLE_WEIGHT=0.25）；
##   ② `FrontSpawner._team_front_dir`（前方扇区取哪个方向）；
##   ③ `players_moving()` / `_any_player_moving()`（静止闸；`spawn_when_idle=false` 时
##      全队被判"静止"= **一只都不刷**）。
## 于是「主机站着不动、客户机推进」或「客户机才是走得最远那位」时，前方补位会按主机
## 算、甚至被静止闸掐死 —— 表现就是多人下某些图**一开始不刷、很久才迟刷、回头才刷
## 一些、总量比单机少**（2026-09-26 用户实测：学校内部 / 矿洞 / 实验室走廊）。
## 改为**按位置差实测**速度与方向（单机与联机同一套口径），`velocity` 仅作补充 ——
## 单机下两者一致，不会改变单机行为。
const MOTION_SMOOTH: float = 0.35    ## 速度平滑系数（抗单帧抖动）
const MOTION_EPS: float = 8.0        ## 低于此速度视为静止（px/s）
const MOTION_STEP_EPS: float = 0.5   ## 单帧位移大于此值才更新方向（px）
## 单帧位移超过此值视为**传送**（调试键 Ctrl+R / 换图就位 / 复活归位），
## 不参与速度与方向统计 —— 否则一次 500px 瞬移会把速度冲到上万，锚点权重被它独占十来帧。
const MOTION_TELEPORT_STEP: float = 64.0
var _motion_prev: Dictionary = {}    ## instance_id -> Vector2 上一帧位置
var _motion_speed: Dictionary = {}   ## instance_id -> float 平滑速度（px/s）
var _motion_dir: Dictionary = {}     ## instance_id -> Vector2 单位方向


## 每帧由 _process 调用：记录各玩家位移 → 平滑速度与方向。
## 同时清理已离场玩家，避免字典无限增长（换图/掉线）。
func sample_player_motion(players: Array[Node2D], delta: float) -> void:
	if delta <= 0.0:
		return
	var seen: Dictionary = {}
	for p: Node2D in players:
		if p == null or not is_instance_valid(p):
			continue
		var id: int = p.get_instance_id()
		seen[id] = true
		var pos: Vector2 = p.global_position
		var prev: Variant = _motion_prev.get(id)
		if prev is Vector2:
			var step: Vector2 = pos - (prev as Vector2)
			var moved: float = step.length()
			if moved > MOTION_TELEPORT_STEP:
				## 传送：只重置基线，不污染速度/方向
				_motion_speed[id] = 0.0
			else:
				var inst: float = moved / delta
				var old: float = float(_motion_speed.get(id, 0.0))
				_motion_speed[id] = inst if old <= 0.0 else lerpf(old, inst, MOTION_SMOOTH)
				if moved > MOTION_STEP_EPS:
					_motion_dir[id] = step.normalized()
		_motion_prev[id] = pos
	for id: Variant in _motion_prev.keys():
		if not seen.has(id):
			_motion_prev.erase(id)
			_motion_speed.erase(id)
			_motion_dir.erase(id)


## 玩家速度（px/s）= max(实测位移速度, velocity 字段)。
## 单机走 velocity（精确，且与实测一致）；联机远端走实测（velocity 恒 0）。
func player_speed(p: Node2D) -> float:
	if p == null or not is_instance_valid(p):
		return 0.0
	var measured: float = float(_motion_speed.get(p.get_instance_id(), 0.0))
	var v: Variant = p.get("velocity")
	var field: float = (v as Vector2).length() if v is Vector2 else 0.0
	return maxf(measured, field)


## 玩家前进方向（单位向量）：实测位移方向优先（联机远端唯一可用来源），
## 静止时退回 velocity，仍不可用则返回 ZERO（由调用方决定兜底）。
func player_motion_dir(p: Node2D) -> Vector2:
	if p == null or not is_instance_valid(p):
		return Vector2.ZERO
	var id: int = p.get_instance_id()
	if float(_motion_speed.get(id, 0.0)) >= MOTION_EPS:
		var d: Variant = _motion_dir.get(id)
		if d is Vector2:
			return d as Vector2
	var v: Variant = p.get("velocity")
	if v is Vector2 and (v as Vector2).length() >= MOTION_EPS:
		return (v as Vector2).normalized()
	return Vector2.ZERO


# ═══════════════════════════════════════
# 多人刷怪锚点（2026-09-23 实测修复）
# ═══════════════════════════════════════

## 旧实现：生成 / 回收 / 附近闸全部以 `_find_player()`（= Players.all_entities()[0]，即座位 0
## 的主机玩家）为圆心。多人实测暴露两个后果：
##   ① 客户端跑在前面时，按"主机屏外"算出的取点正落在**客户端视野内** → 客户端看到"脸上刷怪"；
##   ② 追客户端的丧尸一旦离主机超过 recycle_dist 就被回收 → 前线敌人凭空消失。
## 对照 L4D 导演（Infected 一律刷在**幸存者**视野外、按**幸存者**距离回收；Wanderer 刷在队伍
## 前方，且更"照顾"走在前面/落单的那个 —— 见 left4dead.fandom.com/wiki/The_Director），
## 这里统一改为「以玩家为单位」的锚点集合：锚点决定"刷给谁 / 距离带以谁为准"，
## 判定（视野外 / 回收）则对**全体**玩家取并集。

## 队伍前进方向（单位向量）= 各玩家**实测**运动方向的合向量（无人在动时返回 ZERO）。
## 2026-09-26：不能只读 velocity —— Host 侧远端玩家的 velocity 恒为 0，
## 只读 velocity 会让"客户机在前方推进"这一最常见的组合拿不到方向。
func team_forward_dir(players: Array[Node2D]) -> Vector2:
	var sum: Vector2 = Vector2.ZERO
	for p: Node2D in players:
		if p == null or not is_instance_valid(p):
			continue
		sum += player_motion_dir(p)
	if sum.length() < 0.001:
		return Vector2.ZERO
	return sum.normalized()


func spawn_reference_players() -> Array[Node2D]:
	## 可作为刷怪/回收基准的玩家：存活且非濒死。联机 Host = 全体座位，单机 = 唯一玩家。
	## ⚠ 返回**共享的每帧缓存数组**（见 _cached_reference_players）——调用方只读遍历，
	##   不得 append/erase（会污染同一帧其它调用者拿到的同一份数组）。
	return _cached_reference_players()


func pick_spawn_anchor(teammates: Array[Node2D] = []) -> Node2D:
	## 本批刷怪以谁为圆心 —— L4D 式偏好「落单 / 走得远 / **移动中**」的玩家
	## （玩家观感 = "怪基本多刷在走得远的那个玩家那"）。
	## 权重 = 移动系数 × (1 + 与最近队友的距离/400 + 速度/150)，再按权重**随机**挑选。
	##
	## ⚠ 移动系数是必需的（2026-09-23 实测复盘）：只用"落单度 + 速度"时，
	## "主机原地不动、客户端跑在前面"这一最常见的组合里两人**落单度相同**，
	## 静止主机仍能分到 ~43% 的刷怪 → 客户端前方照样断供。
	## 现在静止玩家降权到 0.25（保留少量压力，不至于队友那边一只不刷）。
	const IDLE_WEIGHT: float = 0.25
	## teammates 由 Director._process 传入（同一帧的玩家集合只算一次）；
	## 留空则自行获取 —— 兼容其它调用点（FrontSpawner / 回归 harness）。
	var list: Array[Node2D] = teammates if not teammates.is_empty() else spawn_reference_players()
	if list.is_empty():
		return _find_player()
	if list.size() == 1:
		return list[0]
	## 队伍前进方向（2026-09-26）：用**实测**运动求和，联机远端同样有效。
	var fwd: Vector2 = team_forward_dir(list)
	var centroid: Vector2 = Vector2.ZERO
	for p: Node2D in list:
		centroid += p.global_position
	centroid /= float(list.size())
	var weights: Array[float] = []
	var total: float = 0.0
	for p: Node2D in list:
		var speed: float = _player_speed(p)
		var base: float = 1.0 if speed >= MOTION_EPS else IDLE_WEIGHT
		## 「队伍前方偏移」项（2026-09-26 多人实测修复）：锚点决定"刷给谁 / 距离带以谁为准"，
		## 而"锚点前方"要再过**全体玩家视野并集** —— 锚点若落在队伍后方，那一带正好在
		## 前方队友的视野里 → 采样全被否掉 → 该批一只不刷（多人下走廊图稀疏的根因之一）。
		## 把沿前进方向的靠前程度计入权重后，锚点自然落在推进最前方的人身上。
		var ahead_offset: float = 0.0
		if fwd != Vector2.ZERO:
			ahead_offset = maxf((p.global_position - centroid).dot(fwd), 0.0)
		var w: float = base * (1.0 + _player_isolation(p, list) / 400.0 + speed / 150.0
			+ ahead_offset / 300.0)
		weights.append(w)
		total += w
	if total <= 0.0:
		return list[0]
	var roll: float = randf() * total
	var acc: float = 0.0
	for i: int in range(list.size()):
		acc += weights[i]
		if roll <= acc:
			return list[i]
	return list[list.size() - 1]


func players_moving() -> bool:
	## 是否**任一**玩家在移动 —— 多人下"主机站着不动"不应切断正在推进的客户端的补位。
	for p: Node2D in spawn_reference_players():
		if _player_speed(p) >= 20.0:
			return true
	return false


func nearest_player_distance(from: Vector2) -> float:
	## 到**最近**玩家的距离（L4D："幸存者走出范围才回收"）。没有玩家时返回 INF。
	var best: float = INF
	for p: Node2D in spawn_reference_players():
		var d: float = from.distance_to(p.global_position)
		if d < best:
			best = d
	return best


func _player_isolation(p: Node2D, list: Array[Node2D]) -> float:
	## 与最近队友的距离：越大越"落单"（L4D 导演更愿意把压力给掉队/带头的人）。
	var best: float = INF
	for other: Node2D in list:
		if other == p:
			continue
		var d: float = p.global_position.distance_to(other.global_position)
		if d < best:
			best = d
	return 0.0 if best == INF else best


func _player_speed(p: Node2D) -> float:
	return player_speed(p)


## 附近闸（2026-09-17 用户需求）：附近敌人 ≥ 阈值且玩家静止 → 暂停刷怪
## （散兵/事件批统一入口 spawn_ahead_batch 调用）。参数挂 FrontSpawner
## （nearby_gate_count / nearby_gate_radius，由 DirectorConfig 注入）；玩家开始移动立即放行。
## 防守战走 spawn_horde_nodes 路径，不经本闸（守家蹲点不能断怪）。
func _nearby_spawn_blocked() -> bool:
	var fs: Node = get_node_or_null("FrontSpawner")
	var gate: int = int(fs.get("nearby_gate_count")) if fs else 10
	if gate <= 0:
		return false
	## 多人（2026-09-23）：任一玩家在移动就放行 —— 主机站着不动不应掐断正在推进的客户端的补位。
	if players_moving():
		return false
	var refs: Array[Node2D] = spawn_reference_players()
	if refs.is_empty():
		return false
	var radius: float = float(fs.get("nearby_gate_radius")) if fs else 600.0
	var r2: float = radius * radius
	var count: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		var ep: Vector2 = e.global_position
		## 任一玩家半径内即计入（去重：同一只只算一次）。
		for p: Node2D in refs:
			if ep.distance_squared_to(p.global_position) <= r2:
				count += 1
				break
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


## 掉落物落点是否可用（2026-09-25）：复用刷怪的"可行走"判定 —— 含地图范围闸、
## 作者禁刷层、图块碰撞多边形。供武器/治疗品掉落避墙（用户实测：换武器时掉落物
## 偶尔卡进墙壁里，旧实现只做与其它掉落物的间距避让）。
func is_drop_spot_free(global_pos: Vector2) -> bool:
	return _is_walkable(global_pos)


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
# 开局附加参数（2026-10-31 用户需求）
# ═══════════════════════════════════════
## 难度选择界面下方的三个开关，随存档/检查点走。这里只做**读取 + 分发**，
## 真正的判定落在各自的消费点（节奏控制器 / 刷怪管理器 / 本方狂暴分支）。

## 尸潮狂暴是否开启。关掉只影响**形态切换**（不变红、不吃クリムゾンヘッド的速度加成），
## 尸潮本身、BGM、预警音照常。
func _berserk_enabled() -> bool:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("horde_modifier"):
		return true
	return bool(g.call("horde_modifier", "berserk"))


## 附加参数「关闭尸潮」当前值（节奏控制器据此跳过峰值）。
func _horde_disabled() -> bool:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("horde_modifier"):
		return false
	return bool(g.call("horde_modifier", "no_horde"))


## 附加参数「强制不加压」当前值（**只看本局设置**，不含地图级开关）。
func _pressure_disabled() -> bool:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("horde_modifier"):
		return false
	return bool(g.call("horde_modifier", "no_build_pressure"))


## 是否允许「持续供水」= 地图级 `offscreen_refill_enabled` ∧ 本局「强制不加压」未开。
## 管的是：FrontSpawner 补位、进图/换区游荡者。
## **不管**：尸潮、特感、Boss、作者摆的 SpawnZone（那些是事件与地图内容，不是加压）。
func refill_allowed() -> bool:
	if not offscreen_refill_enabled:
		return false
	return not _pressure_disabled()


## 每帧把附加参数同步进节奏控制器 —— **只在值变化时写**，避免每帧 set 属性。
## 顺带刷新「紧张度 → 压力」的难度系数：玩家可能在存档点中途改难度。
var _mod_cache_no_horde: bool = false
var _mod_cache_pressure_gain: float = -1.0


func _sync_horde_modifiers(pc: Node) -> void:
	if pc == null:
		return
	var g: Node = get_node_or_null("/root/Global")
	if g == null:
		return
	var no_horde: bool = bool(g.call("horde_modifier", "no_horde"))
	if no_horde != _mod_cache_no_horde:
		_mod_cache_no_horde = no_horde
		pc.set("no_horde", no_horde)
		print("[Director] 附加参数：关闭尸潮 = %s" % ("开" if no_horde else "关"))
	var gain: float = float(g.call("difficulty_intensity_pressure"))
	if not is_equal_approx(gain, _mod_cache_pressure_gain):
		_mod_cache_pressure_gain = gain
		pc.set("intensity_gain", gain)


# ═══════════════════════════════════════
# 特感编排（SpecialEnemyData：ハンター 等）
# ═══════════════════════════════════════

## 特感/坦克的概率倍率：**单人受难度、多人受人数**（2026-10-13 用户需求）。
## 直接复用 `Players.spawn_scale()`（= 人数表 ×（n≤1 时）难度倍率）——该函数语义
## 恰好就是「单人有难度、多人有人数」，无需另建表。缺 Players 时回退 1.0。
## 用于：缩短特感/坦克冷却（÷倍率）、放宽紧张度门槛（÷倍率）、放宽同屏上限。
func _special_rate_scale() -> float:
	var players: Node = get_node_or_null("/root/Players")
	if players == null or not players.has_method("spawn_scale"):
		return 1.0
	return maxf(0.5, float(players.call("spawn_scale")))


## ★加压闸：只看**玩家状态**（怜悯机制）。
## ⚠ 2026-10-29 晚删除了旧的第一条「简单难度单人几乎不增压、特感/Boss 基本不出现」——
##   难度现在只调血量/伤害/尸潮规模，**特感与 Boss 在简单难度也会出现**（不再整段缺席）。
func is_pressure_blocked() -> bool:
	if mercy_hp_ratio <= 0.0:
		return false
	for p: Node2D in spawn_reference_players():
		if not is_instance_valid(p):
			continue
		if p.get("_is_dying") == true:
			return true
		var mx: Variant = p.get("max_hp")
		var cur: Variant = p.get("current_hp")
		if mx == null or cur == null:
			continue
		var m: float = float(mx)
		if m > 0.0 and float(cur) / m < mercy_hp_ratio:
			return true
	return false


func _update_specials(delta: float, player: Node2D, current_phase: StringName) -> void:
	## 简单难度（单人）/ 怜悯期：不加压 —— 不刷特感。
	if is_pressure_blocked():
		return
	## 特感低频高压编排：紧张度门槛 + 随机冷却 + 同屏上限（special_max_alive）。
	## 池空 = 本关未启用特感，直接待机；尸潮（peak）期间计时冻结，不与尸潮叠加施压。
	if _special_pool.is_empty():
		return
	if current_phase == &"peak":
		return
	## ★概率随难度/人数上调（2026-10-13 用户需求：单人受难度、多人受人数）。
	## 倍率同时作用于「同屏上限」与「紧张度门槛」；冷却在刷出后按 ÷倍率 重掷。
	var rate: float = _special_rate_scale()
	# 同屏上限（2026-09-16 修复）：此前写死「有任意一只存活特感就不刷」，把地图 Inspector
	# 配的 special_max_alive=2/3 彻底架空 —— 叠加 Hunter β 正面免疫导致的高存活率，
	# 表现为「很少有特感出现」（用户实测反馈）。现在按本关卡配置计数放行。
	## 名额用作者配置值（2026-10-25）：旧式 ×rate 在单人 0.5 时把 2 压成 1，叠加占位就彻底不出特感。
	var cap: int = maxi(special_max_alive, 1)
	var alive_specials: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("special_enemies"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		## ★女巫**不占特感同屏名额**（2026-10-25 用户实测「基本见不到其他特感」）：
		## 她是守在原地不追人的静态威胁，spawn_special_enemy 也会把她加进 special_enemies。
		## 算进名额时，一只没被惊动的女巫就能长期占掉一格 → 其他特感被饿死。
		if e.get("witch_enabled") == true:
			continue
		alive_specials += 1
	if alive_specials >= cap:
		return
	# 第一只特感的登场延迟（_apply_config 掷 first_delay_min~max）
	if _special_first_delay_left > 0.0:
		_special_first_delay_left -= delta
		return
	# 冷却：每刷出一只后重掷 cooldown_min~max
	if _special_cooldown_left > 0.0:
		_special_cooldown_left -= delta
		return
	# 紧张度门槛：玩家压力不足时特感不登场（特感是压力放大器，不是开场惊喜）。
	# 门槛按 ÷倍率 放宽：难度/人数越高越容易够到。
	## 2026-10-25：门槛不再除以难度倍率（单人 0.5 时 0.1/0.5=0.2，平静期强度只有约 0.2 → 特感永远够不到）。
	if get_intensity() < special_intensity_threshold:
		return

	var data: SpecialEnemyData = _pick_special_enemy(not _boss_on_field())
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
		_special_cooldown_left = randf_range(special_cooldown_min, special_cooldown_max) / rate


## 场上是否已有「Boss 级」敌人（含 T-002 与 Boss 级特感）。
## 原作 #603 的开关[388][395][1714][1715][1870] 就是「重点敌人在场 → 本帧不再增援」。
## Boss 级特感入的是 tank_enemies 组，所以与坦克共用这一判据。
func _boss_on_field() -> bool:
	return _count_alive_tanks() > 0


func _pick_special_enemy(allow_boss: bool = true) -> SpecialEnemyData:
	## 按 weight 从关卡特感池随机选一种（weight=0 的不会被选中）。空池返回 null。
	## `allow_boss=false`（场上已有 Boss）→ 跳过 boss_tier 条目，
	## 保证同屏最多一只 Boss 级敌人（原作「重点敌人互斥」）。
	if _special_pool.is_empty():
		return null
	var total: float = 0.0
	for v: Resource in _special_pool:
		var d: SpecialEnemyData = v as SpecialEnemyData
		if d == null:
			continue
		## 女巫只由 Boss 发牌放置（2026-10-24）：她不是"会追人的特感"，
		## 混在特感池里会变成"行军/防守战途中突然冒出个女巫"。
		if d.witch_enabled:
			continue
		if not allow_boss and d.boss_tier:
			continue
		total += maxf(float(d.weight), 0.0)
	if total <= 0.0:
		## 兼容旧语义：池里全是 0 权重时取第一个（作者用它做定点测试）；
		## 但「当前不允许 Boss」时不能把 Boss 条目当兜底 → 直接不刷。
		if allow_boss:
			var first: SpecialEnemyData = _special_pool[0] as SpecialEnemyData
			if first != null and not first.witch_enabled:
				return first
		return null
	var roll: float = randf() * total
	for v: Resource in _special_pool:
		var d: SpecialEnemyData = v as SpecialEnemyData
		if d == null:
			continue
		if d.witch_enabled:
			continue
		if not allow_boss and d.boss_tier:
			continue
		roll -= maxf(float(d.weight), 0.0)
		if roll <= 0.0:
			return d
	return null


# ═══════════════════════════════════════
# Tank 编排（タイラント T-002）
# ═══════════════════════════════════════

## Tank 双通道编排：常规通道（tank_enabled）+ 防守战通道（holdout_tank_enabled）。
##
## 两条通道频率独立 —— 对齐原作：普通关卡里 Tank 是可选遭遇（拉什开始后才有机会），
## 147 图防守战里则是核心压迫源（早期就登场，菲纳莱必战）。
## 同屏互斥用 tank_max_alive / holdout_tank_max_alive，对应原作「重点敌人互斥」机制。
## ═══ Boss 发牌（L4D 第二批，2026-10-24）═══
## 牌堆 = Tank × tank_weight + 女巫 1 张 + 「无事」N 张，洗牌后逐张发；
## **不允许连续重复**：洗出来的第一张若与上一张相同，就与后面第一张不同的牌对调。
##
## 【tank_weight（2026-10-25）】L4D 的规则是「本章没遇到 Tank → 后续章概率提高」，
## 是**概率**提升而不是强制。这里用"牌堆里多放几张 Tank"表达同一件事；
## 默认 1（与旧行为逐位一致）。上一个可用图刚出过 Tank 时由调用方传 0（不连续两张图都出）。
static func build_boss_bag(last: int, nothing_weight: int, tank_weight: int = 1) -> Array[int]:
	var bag: Array[int] = []
	for _i: int in range(maxi(tank_weight, 0)):
		bag.append(0)
	bag.append(1)
	for _i: int in range(maxi(nothing_weight, 1)):
		bag.append(2)
	bag.shuffle()
	if bag.size() > 1 and bag[0] == last:
		for i: int in range(1, bag.size()):
			if bag[i] != last:
				var tmp: int = bag[0]
				bag[0] = bag[i]
				bag[i] = tmp
				break
	return bag


## 重置牌堆（进图 / 换图时调用）。第一张牌的里程 = step × first_ratio，避免刚进图就遇 Tank。
##
## ★2026-10-25 按 L4D 重做（用户实测「每次战役第一关必定出 Tank，且出现太早」）：
## 旧实现有一条"连续 3 张有效图没 Tank → 本图首张强制 Tank，并把首张锚点提前到 0.6×"的保底，
## 那是"必定出现 + 更早出现"的直接来源。L4D 的官方做法是：
##   · Tank 只在**已走过路程比例**（flow）落在 `spawn_pos_min~spawn_pos_max` 时登场
##     （mission.txt 的 coop_boss_spawning，社区默认 0.2~0.8，官方部分图 0.4~0.8）——
##     所以开局 1/3 段永远不会遇到 Tank；
##   · 本章没遇到 Tank → **后续章概率提高**（不是强制）；
##   · 不允许两张图连着出 Tank（"two tanks in a row without a break" 不会发生）。
## 因此这里：① 删掉强制保底与提前锚点；② 干旱改成"牌堆里多放一张 Tank"；
## ③ 上一个可用图刚出过 Tank（`_prev_map_had_tank`）→ 本图牌堆里不放 Tank 牌。
func _reset_boss_deck() -> void:
	## 干旱计数：只统计"本来会刷怪"的图（安全屋/非刷怪图也会进 _apply_config，
	## 若一并计数，两张图就能凑够阈值 → 保底误触发，2026-10-25 用户实测）。
	if _deck_initialized:
		var tree0: SceneTree = get_tree()
		var scene0: Node = tree0.current_scene if tree0 != null else null
		var eligible: bool = scene0 != null and _is_spawn_map() and not _scene_is_safe_room(scene0)
		if eligible:
			_prev_map_had_tank = _boss_tanks_dealt > 0
			if _boss_tanks_dealt == 0:
				_tank_drought += 1
			else:
				_tank_drought = 0
	_deck_initialized = true
	_boss_deck.clear()
	_boss_deck_last = -1
	_boss_trail = 0.0
	_boss_tanks_dealt = 0
	_boss_witches_dealt = 0
	if not boss_deck_enabled:
		_boss_next_anchor = INF
		_boss_tank_weight = 0
		return
	var first: float = maxf(boss_deck_step * boss_deck_first_ratio, 400.0)
	_boss_next_anchor = first
	## 本图 Tank 牌的张数（0 = 本图不发 Tank 牌）：
	##   · 关闭 Tank / 名额为 0 → 0；
	##   · 上一个可用图刚出过 Tank → 0（不连续两张图都出，L4D 同规则）；
	##   · 连续 ≥2 张图没出 → 2 张（概率提升，但不是强制）。
	var tank_cards: int = 0
	if boss_deck_max_tanks > 0 and tank_enabled:
		if tank_no_repeat_maps and _prev_map_had_tank:
			print("[Director] Boss 发牌：上一张图刚出过 Tank → 本图不放 Tank 牌（不连续）")
		else:
			tank_cards = 1 if _tank_drought < 2 else 2
			if _tank_drought >= 2:
				print("[Director] Boss 发牌：连续 %d 张图没出 Tank → 牌堆加一张 Tank 牌（概率提升）" % _tank_drought)
	_boss_deck = build_boss_bag(-1, boss_deck_nothing_weight, tank_cards)
	_boss_tank_weight = tank_cards
	print("[Director] Boss 发牌：每 %.0fpx 一张，首张在 %.0fpx（无事权重 %d / Tank 牌 %d 张）" % [
		boss_deck_step, first, boss_deck_nothing_weight, tank_cards])


## 当前场景属于**第几关**（1 = 第一关；认不出返回 -1）。
## ⚠ 不能用 `level_scenes` 下标：第一关占了「开头安全屋 / 街道 / 结尾安全屋」三张图，
## 按下标判断会把街道当成第二张图 → 第一关的街道照样放 Tank（正是用户实测的现象）。
static func _chapter_number_of(scene_path: String) -> int:
	var campaign_script: GDScript = load("res://script/campaign_data.gd") as GDScript
	if campaign_script != null and campaign_script.has_method("chapter_number_for_scene"):
		return int(campaign_script.call("chapter_number_for_scene", scene_path))
	return -1


func _current_chapter_number() -> int:
	var tree: SceneTree = get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene == null:
		return -1
	return _chapter_number_of(scene.scene_file_path)


## 第一关（章节号 1）的 Tank 额外跳过率：
## 简单/普通 = 1.0（完全不出，留给第二关）；困难 0.6；专家 0.3。
## ⚠ 这里用 `Global.selected_difficulty` 而不是 `Players.spawn_scale()`：
## 后者在多人局里是"按人数"的倍率（2~3），拿它当难度代理会把多人普通局误判成专家。
func _tank_first_level_skip_chance() -> float:
	if _current_chapter_number() != 1:
		return 0.0
	var diff: int = int(Global.selected_difficulty)
	if diff <= 1:
		return 1.0      ## 简单 / 普通
	if diff == 2:
		return 0.6      ## 困难
	return 0.3          ## 专家


func _deal_boss_card() -> void:
	if _boss_deck.is_empty():
		_boss_deck = build_boss_bag(_boss_deck_last, boss_deck_nothing_weight, _boss_tank_weight)
	if _boss_deck.is_empty():
		return
	var card: int = _boss_deck.pop_front()
	_boss_deck_last = card
	match card:
		0:
			_deal_tank_card()
		1:
			_deal_witch_card()
		_:
			print("[Director] Boss 发牌：无事（里程 %.0fpx / 牌堆剩 %d 张）" % [
				_boss_trail, _boss_deck.size()])


func _deal_tank_card() -> void:
	## ★L4D flow 闸（2026-10-25 用户实测「Tank 出现太早、太快」）：
	## L4D 用 `coop_boss_spawning.spawn_pos_min/max` 约束 Tank 的**出场路程比例**，
	## 即"走到本图 X% 之后才允许，超过 Y% 就本图作罢"。对齐后的行为：
	##   · 太早 → 牌**留在队首**等下一次锚点（不让 Tank 提前，也不当作无事浪费掉）；
	##   · 太晚（快到出口/安全门）→ 本图放弃 Tank，避免"安全门前糊脸一只 Tank"。
	var prog: float = get_progress()
	if prog < tank_spawn_pos_min:
		_boss_deck.push_front(0)
		_boss_next_anchor = _boss_trail + maxf(boss_deck_step * 0.5, 600.0)
		print("[Director] Boss 发牌：Tank 太早（进度 %.2f < %.2f）→ 推迟到下一锚点（里程 %.0fpx）" % [
			prog, tank_spawn_pos_min, _boss_next_anchor])
		return
	if prog > tank_spawn_pos_max:
		print("[Director] Boss 发牌：Tank 太晚（进度 %.2f > %.2f）→ 本图放弃 Tank" % [
			prog, tank_spawn_pos_max])
		return
	## ★难度概率（2026-10-25 用户需求「接近 L4D：低难度更少遇 Tank」）：
	## 用 Players.spawn_scale()（简单 0.5 / 普通 0.75 / 困难 1.0 / 最高 1.25）当难度代理，
	## 换算成跳过率 —— 普通难度约有 4 成半 Tank 牌被当成"无事"。
	## L4D 里 Tank 是低概率事件，不是每张牌都兑现。
	## ★2026-10-31：系数 0.8 → 0.72，整体再降一档（用户实测「Tank 概率有点高」）。
	var diff_scale: float = Players.spawn_scale()
	var skip_chance: float = clampf(1.0 - 0.72 * diff_scale, 0.0, 0.7)
	if skip_chance > 0.0 and randf() < skip_chance:
		print("[Director] Boss 发牌：Tank（难度跳过 %.0f%%，视为无事）" % (skip_chance * 100.0))
		return
	## ★关卡深度闸（2026-10-31 用户实测）：普通难度「尽量第二关才见到 Tank」。
	## 第一张图额外加一道跳过率 —— 难度越低越接近"完全不出"；
	## 困难/专家仍保留小概率（"运气不好就第一关撞上"）。
	var first_skip: float = _tank_first_level_skip_chance()
	if first_skip >= 1.0:
		print("[Director] Boss 发牌：Tank（第一关 + 本难度不出，视为无事）")
		return
	if first_skip > 0.0 and randf() < first_skip:
		print("[Director] Boss 发牌：Tank（第一关跳过 %.0f%%）" % (first_skip * 100.0))
		return
	## 简单难度（单人）/ 怜悯期：不兑现 Tank 牌（牌已消耗，等同"无事"）。
	if is_pressure_blocked():
		print("[Director] Boss 发牌：Tank（简单难度/怜悯期，跳过）")
		return
	## 硬上限：一张图最多 N 只（用户实测「一图四只坦克」）。
	if _boss_tanks_dealt >= boss_deck_max_tanks:
		print("[Director] Boss 发牌：Tank（本图名额已满 %d/%d，跳过）" % [
			_boss_tanks_dealt, boss_deck_max_tanks])
		return
	if not tank_enabled or _tank_data == null:
		print("[Director] Boss 发牌：Tank（本图 Tank 已关闭，跳过）")
		return
	if _count_alive_tanks() > 0:
		print("[Director] Boss 发牌：Tank（场上已有 Tank，跳过）")
		return
	var player: Node2D = pick_spawn_anchor()
	if player != null and _spawn_tank(_tank_data, player):
		_boss_tanks_dealt += 1
		debug_event("★Tank 登场（进度 %.2f / 里程 %.0fpx）" % [prog, _boss_trail])
		print("[Director] Boss 发牌：★Tank 登场（本图第 %d/%d 只 / 里程 %.0fpx）" % [
			_boss_tanks_dealt, boss_deck_max_tanks, _boss_trail])


func _deal_witch_card() -> void:
	## 女巫出现频率下调（2026-10-25 用户反馈偏高）：一部分"女巫牌"直接作废。
	## ★2026-10-29 晚：难度不再参与（只按人数）—— 单人恒 50%，人越多越少跳过。
	var skip: float = clampf(0.5 + 0.3 * (1.0 - Players.spawn_scale()), 0.1, 0.9)
	if randf() < skip:
		print("[Director] Boss 发牌：女巫（难度跳过 %.0f%%，视为无事）" % (skip * 100.0))
		return
	if _boss_witches_dealt >= boss_deck_max_witches:
		print("[Director] Boss 发牌：女巫（本图名额已满 %d/%d，跳过）" % [
			_boss_witches_dealt, boss_deck_max_witches])
		return
	if _witch_data == null:
		print("[Director] Boss 发牌：女巫（无资源，跳过）")
		return
	## 场上已有女巫就不再放（用户实测「防守战里还刷了女巫」的观感来源之一）。
	if _count_alive_witches() > 0:
		print("[Director] Boss 发牌：女巫（场上已有，跳过）")
		return
	var decor_layer: Node = _find_decor_layer()
	var player: Node2D = pick_spawn_anchor()
	var fs: Node = get_node_or_null("FrontSpawner")
	if decor_layer == null or player == null or fs == null:
		return
	## 女巫放在前方（玩家会先"看到"她，再决定绕还是打）——L4D 的 Witch 就是这样被发现的。
	var pos: Vector2 = fs.pick_ahead_position(player)
	if pos == Vector2.ZERO:
		pos = player.global_position + Vector2.RIGHT.rotated(randf() * TAU) * 520.0
	var witch: Node2D = spawn_special_enemy(_add_spawn_scatter(pos), _witch_data, decor_layer, -1)
	if witch != null:
		## 女巫**不**永久豁免回收（2026-10-25）：她走远后应被清掉，
		## 否则在单场景多楼层地图里会一直留着占地。坦克才豁免（它本来会追人）。
		_boss_witches_dealt += 1
		debug_event("女巫放置（进度 %.2f）" % get_progress())
		print("[Director] Boss 发牌：★女巫放置（本图第 %d/%d 只 / 里程 %.0fpx）" % [
			_boss_witches_dealt, boss_deck_max_witches, _boss_trail])


## 场上存活的女巫数（SpecialEnemyData.witch_enabled 标记）。
func _count_alive_witches() -> int:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	var n: int = 0
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		if e.get("witch_enabled") == true:
			n += 1
	return n


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
	## ★Boss 发牌开启时，常规 Tank 的「冷却 + 强度门槛」通道停用（2026-10-24 第二批）：
	## 发牌才是常规出场的唯一途径。两条通道并存会变成"发牌来一只 + 冷却又塞一只"。
	## 防守战通道（_update_holdout_tank）不受影响。
	if boss_deck_enabled:
		return
	## ★去掉「peak 期间冻结」（2026-10-13 用户需求：最终章前也该能遇到坦克）。
	## 旧实现要求 `intensity ≥ tank_intensity_threshold(0.6)` **且** 非 peak，而强度 ≥0.6
	## 几乎恰好落在 peak —— 两条件近乎互斥 → 常规坦克基本刷不出来（用户实测）。
	## 现在 peak 不再排除（Tank 与尸潮并存本就是原作的高压场面）。紧张度门槛接下一条。
	## 概率随难度/人数上调（同特感：单人受难度、多人受人数）。
	var rate: float = _special_rate_scale()
	if _count_alive_tanks() > 0:
		return
	if _tank_cooldown_left > 0.0:
		_tank_cooldown_left -= delta
		return
	# Tank 门槛比特感高：局面吃力时才出场。按 ÷倍率 放宽（难度/人数越高越易触发）。
	if get_intensity() < tank_intensity_threshold / rate:
		return
	if _spawn_tank(_tank_data, player):
		_tank_cooldown_left = randf_range(tank_cooldown_min, tank_cooldown_max) / rate


func _update_holdout_tank(delta: float, player: Node2D) -> void:
	if not holdout_tank_enabled or _holdout_tank_data == null:
		return
	## 防守战 Tank 也随难度/人数上调（2026-10-13）：缩短首只延迟与冷却。
	var rate: float = _special_rate_scale()
	if _count_alive_tanks() >= maxi(holdout_tank_max_alive, 1):
		return
	# 首只延迟：防守战开始后先给一段预热，再上 Tank
	if _holdout_tank_first_left > 0.0:
		_holdout_tank_first_left -= delta
		return
	if _holdout_tank_cooldown_left > 0.0:
		_holdout_tank_cooldown_left -= delta
		return
	## 生成失败后的短退避（2026-10-25）：旧实现失败时不设冷却 → 每帧重试，
	## 且每次重试都要跑 36 次取点（卡顿 + 日志刷屏）。需求模式下玩家还会误以为导演在努力。
	if _holdout_tank_retry_left > 0.0:
		_holdout_tank_retry_left -= delta
		return
	## 需求模式（机器要靠杀 Tank 推进）允许"屏内兜底取点"：
	## 宁可坦克在屏幕边缘出现，也不能让门永远不开。
	var relaxed: bool = holdout_tank_demand > 0
	if _spawn_tank(_holdout_tank_data, player, relaxed):
		_holdout_tank_cooldown_left = _holdout_cooldown_for(rate)
		return
	_holdout_tank_retry_left = 2.0
	if relaxed:
		print("[Director] 防守战 Tank 生成失败（需求 %d 只）→ 2s 后重试" % holdout_tank_demand)


## 防守战 Tank 的下一段冷却。
## 环境压力模式 = 配置的 90~150s ÷ 难度/人数倍率（原行为）；
## **需求模式**（`holdout_tank_demand > 0`）= 收紧到 `holdout_tank_demand_interval`（±20% 抖动）——
## 此时 Tank 是「开门条件」，不是可选的压力事件（L4D 终局也是打完一只顶一只，没有长冷却）。
func _holdout_cooldown_for(rate: float) -> float:
	var base: float = randf_range(
		minf(holdout_tank_cooldown_min, holdout_tank_cooldown_max),
		maxf(holdout_tank_cooldown_min, holdout_tank_cooldown_max)) / maxf(rate, 0.1)
	## interval = 0 表示作者主动关掉需求模式（退回环境冷却），不要解释成「立即生成」。
	if holdout_tank_demand > 0 and holdout_tank_demand_interval > 0.0:
		base = minf(base, randf_range(holdout_tank_demand_interval * 0.8, holdout_tank_demand_interval))
	return base


## 生成一只 Tank。与特感共用 spawn_special_enemy（Tank 也是 SpecialEnemyData），
## 但额外入 "tank_enemies" 组供 count 用，并广播信号给 HUD（Boss 登场提示）。
func _spawn_tank(data: SpecialEnemyData, player: Node2D, allow_visible_fallback: bool = false) -> bool:
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
	## 兜底（仅防守战需求模式传 true）：放开「必须在屏外」——
	## 终局场地（列车台）可能整张图都在屏内，严格取点会永远失败 → 门永远不开。
	if pos == Vector2.ZERO and allow_visible_fallback:
		pos = _find_any_walkable_near(player)
	if pos == Vector2.ZERO:
		return false
	# facing：让 Tank 登场时面朝玩家（压迫感）
	var facing: int = _calc_facing_toward_player(pos)
	var tank: Node2D = spawn_special_enemy(pos, data, decor_layer, facing)
	if tank == null:
		return false
	tank.add_to_group("tank_enemies")
	## ★坦克不参与「离得太远就回收」（2026-10-24 用户实测「坦克没打死，上二楼一会又出来一只」）：
	## recycle 会把被甩在身后的坦克清掉 → `_count_alive_tanks()` 归零 → 发牌/冷却立刻再放一只。
	## 玩家看到的就是"同一只坦克反复出现"。豁免后它留在场上，新坦克被名额挡住。
	tank.set("recycle_exempt", true)
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
## `tank_demand` = 这场防守战需要玩家杀掉几只 Tank 才能推进（0 = 不靠 Tank 推进）。
## 机器侧（HoldoutMachine）在 KILL_COUNT + KillFilter.TANK 时传 `kill_target`。
func notify_holdout_started(tank_demand: int = 0) -> void:
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0
	_holdout_tank_retry_left = 0.0
	holdout_tank_demand = maxi(tank_demand, 0)
	if holdout_tank_demand > 0:
		print("[Director] 防守战 Tank 需求 %d 只 → 冷却改用需求间隔 %.0fs" % [
			holdout_tank_demand, holdout_tank_demand_interval])


## 防守战结束时调用：清掉冷却，避免残留计时影响下一次防守战。
## 机器每杀一只 Tank 就更新"还剩几只"（剩 0 = 门开了，导演恢复常规节奏）。
func set_holdout_tank_demand(count: int) -> void:
	holdout_tank_demand = maxi(count, 0)


func notify_holdout_finished() -> void:
	_holdout_tank_first_left = holdout_tank_first_delay
	_holdout_tank_cooldown_left = 0.0
	_holdout_tank_retry_left = 0.0
	holdout_tank_demand = 0


# ═══════════════════════════════════════
# 回收（离玩家太远的敌人清除）
# ═══════════════════════════════════════

func _update_recycle(delta: float) -> void:
	## 对应原作 #506「★☆敵の回収設定☆★」：把离玩家太远的敌人收回。
	##
	## 没有回收时（实测学校地图 60 秒）：被甩在身后的敌人只增不减（0 → 28 只），
	## 全场存活 29 秒即顶满上限 50 → 前方补位被"全场存活已达上限"永久掐断
	## （用户报的"前面刷得多、后面越来越少"），同时它们还在继续跑 A*（用户报的卡顿）。
	## 死亡动画中（_is_dying）不参与回收 —— 播完变尸体后下一轮按尸体清。
	##
	## ⚠ 回收基准必须是**全体玩家**（2026-09-23 实测修复）：旧实现用单一玩家（座位 0 = 主机），
	## 于是追着跑在前面的客户端的丧尸，一旦离主机超过 recycle_dist 就被回收 ——
	## 玩家观感是"前线怪凭空消失"。L4D 的规则是"幸存者**走出范围**才回收"，
	## 即按到**最近**玩家的距离判定。
	if not recycle_enabled:
		return
	var refs: Array[Node2D] = spawn_reference_players()
	if refs.is_empty():
		return
	_recycle_timer += delta
	if _recycle_timer < recycle_interval:
		return
	_recycle_timer = 0.0

	## 尸潮期间用收紧后的回收距离（见 PEAK_RECYCLE_SCALE 的成因说明）。
	## ⚠ current_phase 只在 _process 里是局部变量；这里从 PacingController 直接读
	##（枚举值 1 = PEAK，与 _process 里的 match 同口径）。
	var clear_dist: float = recycle_dist
	var pc: Node = get_node_or_null("PacingController")
	if pc != null and int(pc.get("current_phase")) == 1:
		clear_dist = recycle_dist * PEAK_RECYCLE_SCALE

	var cleared_alive: int = 0
	var cleared_corpses: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("recycle_exempt") == true:
			continue
		if e.get("_is_dying") == true:
			continue
		## 离任一玩家在回收距离内 → 保留（多人：取"最近玩家"的距离）。
		var keep: bool = false
		for p: Node2D in refs:
			if e.global_position.distance_to(p.global_position) <= clear_dist:
				keep = true
				break
		if keep:
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

func _update_combat_state(players: Array) -> void:
	## 「任一存活玩家附近 500px 内有敌人」= 队伍在战斗中（2026-09-24 多玩家口径）。
	## 旧实现只盯座位 0（主机）→ 主机蹲在后方时全队被判"脱战"，战斗因子恒 0.2，
	## 紧张度被人为压低、尸潮来得更晚（与"刷怪只围绕主机"属同一族问题）。
	var tree: SceneTree = get_tree()
	if not tree:
		return
	## 先 `is_instance_valid` 后 `as`（freed-cast 家族铁律）。
	var list: Array[Node2D] = []
	for value: Variant in players:
		if not is_instance_valid(value):
			continue
		var p: Node2D = value as Node2D
		if p != null:
			list.append(p)
	var enemies: Array = tree.get_nodes_in_group("enemy")
	var in_combat: bool = false
	for e: Node2D in enemies:
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		var epos: Vector2 = e.global_position
		for p: Node2D in list:
			if p.global_position.distance_to(epos) < 500.0:
				in_combat = true
				break
		if in_combat:
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


## 兜底取点（只给「防守战必须交付 Tank」用）：不看屏外/前方，只要站得下且没敌人。
## ⚠ 不要给常规刷怪用 —— 那会让敌人直接出现在玩家脸上。
func _find_any_walkable_near(player: Node2D, min_dist: float = 180.0,
		max_dist: float = 420.0) -> Vector2:
	if player == null or not is_instance_valid(player):
		return Vector2.ZERO
	for _i: int in range(48):
		var ang: float = randf() * TAU
		var dist: float = randf_range(min_dist, maxf(max_dist, min_dist + 40.0))
		var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(ang) * dist
		if _is_footprint_walkable(pos) and not _is_occupied_by_enemy(pos):
			return pos
	return Vector2.ZERO


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
		## 屏外闸（2026-09-25 补）：这里过去只查"可行走/无怪/近期没用过"，而距离下限
		## `spawn_min_dist` 是**只对锚点玩家**量的、且完全不查并集 —— 锚点偏好"跑得最远
		## 的那位"，另一名玩家完全可能就站在采样点旁边 → 怪刷在他脸上。
		if not _spawn_pos_is_hidden(pos):
			continue
		if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
			return pos
	return Vector2.ZERO


func _update_ambient_zones(delta: float) -> void:
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
		var dist: float = nearest_player_distance(zone.global_position)
		if dist < zone.ambient_min_player_dist:
			continue
		if zone.poll_ambient_timer(delta) == false:
			continue

		## 区域保底 / 上限都按**血量比例**吃难度（2026-10-29 三次定稿）：
		## 简单铺得少、最高铺得多；只动这两个数，不动作者摆的 zone 位置。
		var zone_cap: int = maxi(0, Players.scale_area_count(zone.max_spawns))
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
		var target_count: int = mini(Players.scale_area_count(zone.ambient_budget), zone_cap)
		var shortage: int = maxi(0, target_count - current_count)
		if shortage <= 0:
			continue
		## ★区域已有敌人的位置：交给 pick_spread_position 做"最大最小距离"分散采样，
		## 避免一口气全堆在区域同一角（用户实测「都堆在一块」）。
		var avoid: Array = []
		for enemy: Node2D in tree.get_nodes_in_group("enemy"):
			if not is_instance_valid(enemy):
				continue
			if enemy.get("_is_dying") == true or enemy.get("_is_dead") == true:
				continue
			if enemy.global_position.distance_to(zone.global_position) <= zone.get_zone_radius():
				avoid.append(enemy.global_position)
		var ok_cb: Callable = Callable(self, "_zone_point_ok").bind(zone)
		for _i: int in range(shortage):
			var pos: Vector2 = zone.pick_spread_position(ok_cb, avoid)
			if pos == Vector2.ZERO:
				break
			var zone_count_after: int = _count_enemies_in_zone(zone)
			if zone_count_after >= zone_cap:
				break
			var enemy: Node2D = spawn_enemy(pos, decor_layer, _get_spawn_facing(zone))
			if enemy == null:
				break
			avoid.append(pos)


## 区域落点判定（SpawnZone 用）：脚印可行走 + 屏外 + 离玩家够远 + 未被占用。
func _zone_point_ok(pos: Vector2, zone: SpawnZone) -> bool:
	if zone != null and nearest_player_distance(pos) < zone.ambient_min_player_dist:
		return false
	# 必须在屏幕之外：区域是作者摆的"刷在哪里"，但"何时刷"仍要避开玩家视野。
	var fs_node: Node = get_node_or_null("FrontSpawner")
	if fs_node and fs_node.get("enabled") == true and not fs_node.is_offscreen_for_all(pos):
		return false
	if not _is_footprint_walkable(pos):
		return false
	if _is_occupied_by_enemy(pos) or _was_recently_used(pos):
		return false
	return true


## ★落点脚印判定（2026-10-24 用户实测「SpawnZone 覆盖到墙就刷进墙里」）：
## 单点可走 ≠ 站得下 —— 敌人碰撞体约 24×24，中心正好贴着墙边时身体会有一半插在墙里。
## 额外检查四角，任一角被墙/家具占住就算不合格。也用于屏外补位与游荡者预铺。
func _is_footprint_walkable(global_pos: Vector2, half: Vector2 = Vector2(10.0, 10.0)) -> bool:
	if not _is_walkable(global_pos):
		return false
	return (_is_walkable(global_pos + Vector2(-half.x, -half.y))
		and _is_walkable(global_pos + Vector2(half.x, -half.y))
		and _is_walkable(global_pos + Vector2(-half.x, half.y))
		and _is_walkable(global_pos + Vector2(half.x, half.y)))


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


# ═══════════════════════════════════════
# 调试面板（F3，2026-10-25）
# ═══════════════════════════════════════
##
## 【为什么面板只读、数据由导演侧组装】导演的决策依据散在 5 个子模块里（阶段/紧张度/预算/
## 名额/牌堆/投放）。面板自己去翻私有字段等于把耦合搬进 UI；`debug_snapshot()` 是唯一取数口，
## 面板只做排版 —— 将来加字段只改这里。

const DEBUG_PANEL_KEY := KEY_F3

var _debug_panel: Node = null
var _debug_events: Array[String] = []


func _toggle_debug_panel() -> void:
	if not bool(Global.get("debug_enabled")):
		return
	if _debug_panel == null or not is_instance_valid(_debug_panel):
		var panel: CanvasLayer = CanvasLayer.new()
		panel.name = "DirectorDebugPanel"
		panel.set_script(load("res://script/director/director_debug_panel.gd"))
		panel.call("setup", self)
		add_child(panel)
		_debug_panel = panel
	_debug_panel.call("toggle")


## 记一条事件到面板的「最近事件」（环形缓冲 7 条）。
## 关键决策（阶段切换 / Boss 登场 / 尸潮规模 / 投放）都往这里写一行，
## 现场复现时不用再去翻刷屏的 print。
func debug_event(text: String) -> void:
	var t: float = Time.get_ticks_msec() / 1000.0
	_debug_events.append("%6.1fs %s" % [t, text])
	while _debug_events.size() > 7:
		_debug_events.pop_front()


## 面板取数口：把「决策输入 + 已经发生的决定」一次性打包。
func debug_snapshot() -> Dictionary:
	var tree: SceneTree = get_tree()
	var scene: Node = tree.current_scene if tree != null else null
	var pc: Node = get_node_or_null("PacingController")
	var sm: Node = get_node_or_null("SpawnManager")
	var im: Node = get_node_or_null("ItemManager")

	var phase: StringName = &"?"
	var elapsed: float = 0.0
	var duration: float = 0.0
	if pc != null:
		if pc.has_method("get_phase_name"):
			phase = pc.call("get_phase_name")
		elapsed = float(pc.get("phase_elapsed"))
		duration = float(pc.get("phase_duration"))

	var raw: float = 0.0
	var combat: bool = false
	if intensity_tracker != null and is_instance_valid(intensity_tracker):
		if intensity_tracker.has_method("get_raw_intensity"):
			raw = float(intensity_tracker.call("get_raw_intensity"))
		combat = bool(intensity_tracker.get("in_combat"))

	## 智能尸潮压力表（2026-10-31）：现场排查「为什么还不来尸潮」就看这三项。
	var smart: Dictionary = {}
	if pc != null and pc.has_method("smart_debug"):
		smart = pc.call("smart_debug")

	var pt: Dictionary = {}
	if progress_tracker != null and is_instance_valid(progress_tracker):
		pt = progress_tracker.call("get_debug")

	var item_debug: Dictionary = {}
	if im != null and im.has_method("get_debug"):
		item_debug = im.call("get_debug")

	var budget: int = 0
	var max_common: int = 40
	if sm != null:
		if sm.get("_budget_left") != null:
			budget = int(sm.get("_budget_left"))
		if sm.get("max_active_common") != null:
			max_common = int(sm.get("max_active_common"))

	return {
		"scene": scene.scene_file_path.get_file() if scene != null else "-",
		"phase": String(phase),
		"phase_left": duration - elapsed,
		"phase_duration": duration,
		"horde_progress": float(smart.get("progress", 0.0)),
		"horde_target": float(smart.get("target", 0.0)),
		"horde_kills": int(smart.get("kills", 0)),
		"horde_per_kill": float(smart.get("per_kill_sec", 0.0)),
		"horde_since_peak": float(smart.get("since_peak", -1.0)),
		"horde_gap": float(smart.get("gap", 0.0)),
		"horde_build_index": int(smart.get("build_index", 0)),
		## 开局附加参数（2026-10-31）：F3 里能直接看出这局被改成了什么。
		"mod_berserk": _berserk_enabled(),
		"mod_no_horde": _horde_disabled(),
		"mod_no_pressure": _pressure_disabled(),
		"intensity": get_intensity(),
		"intensity_raw": raw,
		"in_combat": combat,
		"progress": get_progress(),
		"progress_has_exit": bool(pt.get("has_exit", false)),
		"progress_exit": str((pt.get("exit", Vector2.ZERO) as Vector2).round()),
		"trail": float(pt.get("trail", 0.0)),
		"alive": _count_alive_enemies(),
		"active_cap": Players.scaled_active_cap(max_common),
		"threat": count_threat_near_players(),
		"budget": budget,
		"specials_alive": _count_alive_specials(),
		"specials_max": special_max_alive,
		"specials_first_left": _special_first_delay_left,
		"specials_cool_left": _special_cooldown_left,
		"mercy": is_pressure_blocked(),
		"pressure_blocked": is_pressure_blocked(),
		"deck_size": _boss_deck.size(),
		"deck": str(_boss_deck),
		"deck_tank_cards": _boss_tank_weight,
		"tanks_dealt": _boss_tanks_dealt,
		"tanks_max": boss_deck_max_tanks,
		"witches_dealt": _boss_witches_dealt,
		"witches_max": boss_deck_max_witches,
		"boss_trail": _boss_trail,
		"boss_next_anchor": -1.0 if is_inf(_boss_next_anchor) else _boss_next_anchor,
		"tank_pos_min": tank_spawn_pos_min,
		"tank_pos_max": tank_spawn_pos_max,
		"tank_drought": _tank_drought,
		"prev_map_had_tank": _prev_map_had_tank,
		## 防守战 Tank 供给（2026-10-25）：现场排查「第二只为什么不来」就看这四项
		"holdout_tank_enabled": holdout_tank_enabled,
		"holdout_tank_demand": holdout_tank_demand,
		"holdout_tank_interval": holdout_tank_demand_interval,
		"holdout_tank_cooldown": _holdout_tank_cooldown_left,
		"holdout_tank_first": _holdout_tank_first_left,
		"holdout_tank_retry": _holdout_tank_retry_left,
		"item_last": str(item_debug.get("last_drop", "-")),
		"item_last_age": float(item_debug.get("last_drop_age", 0.0)),
		"item_check_left": float(item_debug.get("check_left", 0.0)),
		"fail_safe_ready_in": float(item_debug.get("fail_safe_ready_in", 0.0)),
		"fail_safe_low_hp": float(item_debug.get("fail_safe_low_hp", 0.0)),
		"fail_safe_downed": bool(item_debug.get("fail_safe_downed", false)),
		"fail_safe_last": str(item_debug.get("fail_safe_last", "")),
		"recycle_alive": _recycle_cleared,
		"recycle_corpse": _recycle_corpses,
		"boss_music": _boss_music_active,
		"events": _debug_events.duplicate(),
	}


## 场上存活特感数（不含女巫 —— 她不吃特感名额，见 `_update_specials` 的说明）。
func _count_alive_specials() -> int:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	var n: int = 0
	for e: Node in tree.get_nodes_in_group("special_enemies"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if e.get("witch_enabled") == true:
			continue
		n += 1
	return n
